# frozen_string_literal: true

module Pcrd
  module Migration
    # Drives the full migrate flow: setup, concurrent backfill + WAL apply, and
    # the streaming monitor, with cleanup guaranteed. Extracted from the CLI so
    # the orchestration is testable on its own and free of Thor.
    #
    # The CLI stays a thin adapter: it runs preflight, confirms with the
    # operator, installs signal traps that call #request_stop, and renders the
    # result. All progress output goes through an injected Reporter.
    #
    # #run assumes preflight has passed and the operator has confirmed; it
    # returns an outcome symbol (:completed | :interrupted | :backfill_only) and
    # raises Pcrd::Error subclasses (Replication::Error, Connection::Error, ...)
    # for the CLI to translate.
    class Orchestrator
      LAG_CHECK_INTERVAL = 2 # seconds between lag readings in streaming mode

      def initialize(config:, options: {}, reporter: Reporter::Console.new)
        @config   = config
        @options  = Options.normalize(options)
        @reporter = reporter
        @mutex    = Mutex.new
        @stop     = false
      end

      # Safe to call from a signal handler / another thread.
      def request_stop
        @mutex.synchronize { @stop = true }
        @backfill_engine&.stop!
        @reporter.info("\nStopping...")
      end

      def run
        @source_pool = Connection::Client.new(@config.source)
        @target_pool = Connection::Client.new(@config.target)
        @checkpoint  = Checkpoint::Store.new(@config.migrate.checkpoint_db)
        setup        = Schema::Setup.new(source_pool: @source_pool, target_pool: @target_pool, config: @config)

        report_session_settings
        acquire_lock!

        start_lsn = prepare_replication(setup)
        start_streaming(start_lsn) unless backfill_only?

        return :interrupted if run_backfill == :interrupted

        if backfill_only?
          @reporter.info("Run `pcrd verify` to check row counts, then `pcrd cutover` when ready.")
          return :backfill_only
        end

        stream_until_stopped
      ensure
        cleanup
      end

      private

      def stopped?
        @mutex.synchronize { @stop }
      end

      def backfill_only?
        @options[:"backfill-only"]
      end

      def report_session_settings
        s = @source_pool.session_settings
        @reporter.info(
          "Session: application_name=#{s['application_name']}, lock_timeout=#{s['lock_timeout']}, " \
          "idle_in_transaction=#{s['idle_in_transaction_session_timeout']}, " \
          "statement_timeout=#{s['statement_timeout']}"
        )
      end

      def acquire_lock!
        @migration_lock = AdvisoryLock.new(pool: @source_pool, name: @config.migrate.replication_slot)
        return if @migration_lock.try_acquire

        raise Pcrd::Error,
              "Another pcrd migration is already running against slot " \
              "'#{@config.migrate.replication_slot}'. Wait for it to finish, or stop it before retrying."
      end

      # Ensures (or, on resume, validates) the slot/publication and target
      # tables, returning the LSN streaming should start from.
      def prepare_replication(setup)
        if @options[:resume]
          unless backfill_only?
            setup.validate_resumable!(
              pub_name: @config.migrate.publication, slot_name: @config.migrate.replication_slot
            )
          end
          start_lsn = @checkpoint.backfill_start_lsn || "0/0"
          @reporter.info("\nResuming migration from LSN #{start_lsn}...")
          return start_lsn
        end

        start_lsn = "0/0"
        unless backfill_only?
          @reporter.info("\nCreating publication and replication slot...")
          start_lsn = setup.create_publication_and_slot(
            pub_name: @config.migrate.publication, slot_name: @config.migrate.replication_slot
          )
          @checkpoint.set_backfill_start_lsn(start_lsn)
          @checkpoint.set_publication(@config.migrate.publication)
          @checkpoint.set_replication_slot(@config.migrate.replication_slot)
          @reporter.success("  Slot created at LSN #{start_lsn}.")
        end

        @reporter.info("\nCreating target tables...")
        setup.create_target_tables(force_overwrite: @options[:"force-overwrite"])
        @reporter.success("  Target tables created.")
        start_lsn
      end

      # Starts the WAL consumer and the apply worker on its own target
      # connection (Connection::Client is single-connection and unsafe to share
      # with backfill's writes).
      def start_streaming(start_lsn)
        repl_conn = Connection::Replication.new(@config.source)
        @parser   = Replication::Pgoutput::Parser.new
        @consumer = Replication::Consumer.new(
          repl_conn: repl_conn, parser: @parser,
          slot_name: @config.migrate.replication_slot,
          pub_name:  @config.migrate.publication, start_lsn: start_lsn
        )
        @reporter.info("\nStarting WAL consumer...")
        @consumer.start
        @reporter.success("  Streaming from #{start_lsn}.")

        @apply_pool  = Connection::Client.new(@config.target)
        apply_engine = Apply::Engine.new(
          target_pool: @apply_pool, config: @config, parser: @parser,
          source_schema: read_source_schema
        )
        @apply_worker = Apply::Worker.new(
          engine: apply_engine, queue: @consumer.queue,
          # Acknowledge to the source only after the txn is durably applied and
          # checkpointed, so WAL is not released prematurely.
          on_committed: lambda { |lsn|
            @checkpoint.set_lsn(lsn)
            @consumer.advance_lsn(lsn)
          }
        )
        @apply_worker.start
        @reporter.success("  Applying WAL concurrently with backfill.")
      end

      # Runs backfill concurrently with the apply worker. Returns :interrupted
      # if it stopped early, otherwise nil.
      def run_backfill
        @backfill_engine = Backfill::Engine.new(
          source_pool: @source_pool, target_pool: @target_pool,
          config: @config, checkpoint: @checkpoint
        )

        if (rps = @config.migrate.max_rows_per_second)
          @reporter.info("\nStarting backfill (throttled to #{format_count(rps)} rows/s)...")
        else
          @reporter.info("\nStarting backfill...")
        end

        results = @backfill_engine.run(on_batch: method(:report_batch))
        @reporter.info("")

        results.each do |r|
          status = r.stopped_early ? " (interrupted)" : ""
          @reporter.success("  #{r.table_name}: #{format_count(r.rows_copied)} rows " \
                            "in #{r.batch_count} batches#{status}")
        end

        if @apply_worker&.failed?
          raise Replication::Error, "Apply worker stopped: #{@apply_worker.error.message}"
        end

        if results.any?(&:stopped_early) || stopped?
          @reporter.warn("\nInterrupted. Resume with --resume.")
          return :interrupted
        end

        @reporter.success("\nBackfill complete.")
        nil
      end

      def stream_until_stopped
        @reporter.info("Entering streaming mode. Press Ctrl-C to stop.\n")
        lag_monitor    = Monitor::Lag.new(source_pool: @source_pool, slot_name: @config.migrate.replication_slot)
        last_lag_check = 0.0

        loop do
          break if stopped?

          if @apply_worker.failed?
            raise Replication::Error, "Apply worker stopped: #{@apply_worker.error.message}"
          end
          if @consumer.failed? && @consumer.queue.empty?
            raise Replication::Error, "WAL consumer stopped: #{@consumer.last_error.message}"
          end

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if now - last_lag_check >= LAG_CHECK_INTERVAL
            render_lag(lag_monitor)
            last_lag_check = now
          end
          sleep 0.1
        end

        @reporter.info("")
        if stopped?
          @reporter.warn("Migration interrupted. Resume with:")
          @reporter.warn("  pcrd migrate --config #{@options[:config] || Config::DEFAULT_CONFIG_FILE} --resume")
        end
        :completed
      end

      def render_lag(lag_monitor)
        lag       = lag_monitor.lag_bytes
        threshold = @config.migrate.lag_threshold_bytes
        metrics   = "queue: #{@consumer.queue_depth}  applied: #{@apply_worker.last_applied_lsn || '—'}"
        ready     = lag && lag <= threshold ? "  #{@reporter.green('✓ Ready for cutover')}" : ""
        @reporter.status("  Lag: #{lag_monitor.summary}  |  #{metrics}#{ready}   ")
      end

      def read_source_schema
        reader = Schema::Reader.new(@source_pool)
        (@config.migrate&.tables || []).each_with_object({}) do |table, h|
          h[table.name] = {
            columns:    reader.read(table.name),
            pk_columns: reader.primary_key_columns(table.name)
          }
        end
      end

      def report_batch(stats)
        rps = stats[:duration_ms] > 0 ? (stats[:row_count] * 1000.0 / stats[:duration_ms]).round : 0
        @reporter.status(
          "  #{stats[:table]}  batch #{stats[:batch_num]}  " \
          "#{format_count(stats[:rows_so_far])} rows  #{format_count(rps)} rows/s    "
        )
      end

      # Stop the producer first so the queue is finite, then let the worker
      # drain what's left before closing its connection.
      def cleanup
        @consumer&.stop rescue nil
        @apply_worker&.stop rescue nil
        @apply_pool&.close rescue nil
        @checkpoint&.close rescue nil
        @migration_lock&.release rescue nil
        @source_pool&.close rescue nil
        @target_pool&.close rescue nil
      end

      def format_count(n)
        n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      end
    end
  end
end

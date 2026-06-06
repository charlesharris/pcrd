# frozen_string_literal: true

require "thor"
require "pastel"

module Pcrd
  class CLI < Thor
    PASTEL = Pastel.new

    def self.exit_on_failure?
      true
    end

    class_option :config, type: :string, aliases: "-c",
                          desc: "Path to migration YAML config (required for all commands)"

    map %w[--version -v] => :version
    desc "--version, -v", "Show pcrd version"
    def version
      say "pcrd #{Pcrd::VERSION}"
    end

    desc "analyze", "Analyze column padding for source tables"
    long_desc <<~DESC
      Reads the source table schema and reports the current column layout alongside
      the optimal column ordering for minimal padding waste. Estimates bytes saved
      per row and total storage reclaimed at current row count.

      With --compare-target, also connects to the target cluster and shows a
      side-by-side diff: type changes, renames, added/dropped columns, and the
      padding delta between source and target schemas.

      This command is read-only and requires no migration to be in progress.
    DESC
    method_option :table, type: :string, aliases: "-t",
                          desc: "Analyze a specific table only (default: all tables in config)"
    method_option :"compare-target", type: :boolean, default: false,
                  desc: "Compare source and target schemas side-by-side"
    def analyze
      config = load_config!
      Commands::Analyze.new(config, options).run
    rescue Commands::Analyze::Error => e
      raise Thor::Error, "ERROR: #{e.message}"
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    end

    desc "migrate", "Start or resume the migration"
    long_desc <<~DESC
      Runs preflight checks, creates the replication slot and publication on source,
      creates the target table with the new schema, then runs backfill and streaming
      concurrently until the operator triggers cutover.

      The process is resumable: if interrupted, re-run with --resume to pick up
      from the last completed backfill batch.

      Use --preflight-only to validate the config and source data without starting
      the migration. Use --backfill-only to copy existing rows without starting
      the WAL streaming consumer.
    DESC
    method_option :resume, type: :boolean, default: false,
                  desc: "Resume an interrupted migration from the last checkpoint"
    method_option :"preflight-only", type: :boolean, default: false,
                  desc: "Run preflight checks and print DDL only; do not start migration"
    method_option :"backfill-only", type: :boolean, default: false,
                  desc: "Copy existing rows only; do not start WAL streaming consumer"
    method_option :"dry-run", type: :boolean, default: false,
                  desc: "Print preflight report and target DDL without touching either cluster"
    method_option :yes, type: :boolean, default: false, aliases: "-y",
                  desc: "Skip the confirmation prompt before starting migration"
    method_option :"force-overwrite", type: :boolean, default: false,
                  desc: "Drop and recreate target tables if they already exist"
    def migrate
      config         = load_config!
      preflight_only = options[:"preflight-only"] || options[:"dry-run"]

      unless preflight_only
        raise Thor::Error,
              "ERROR: migrate requires a 'target' section in your config.\n\n" \
              "Use --preflight-only to validate without a target connection." if config.target.nil?

        raise Thor::Error,
              "ERROR: migrate requires a 'migrate' section in your config." if config.migrate.nil?
      end

      result = Preflight.new(config, options).run
      Output::PreflightPrinter.new.print(result)

      if preflight_only
        exit(result.passed ? 0 : 1)
        return
      end

      unless result.passed
        raise Thor::Error, "Preflight failed. Fix the issue(s) above before running migrate."
      end

      unless options[:yes]
        answer = ask("Proceed with migration? [y/N]")
        return unless answer.strip.downcase == "y"
      end

      source_pool = Connection::Pool.new(config.source)
      target_pool = Connection::Pool.new(config.target)
      checkpoint  = Checkpoint::Store.new(config.migrate.checkpoint_db)
      setup       = Schema::Setup.new(source_pool: source_pool, target_pool: target_pool, config: config)

      s = source_pool.session_settings
      say "Session: application_name=#{s['application_name']}, lock_timeout=#{s['lock_timeout']}, " \
          "idle_in_transaction=#{s['idle_in_transaction_session_timeout']}, " \
          "statement_timeout=#{s['statement_timeout']}"

      # Prevent two concurrent migrations against the same slot from corrupting
      # checkpoint/LSN progress and fighting over the replication slot.
      migration_lock = AdvisoryLock.new(pool: source_pool, name: config.migrate.replication_slot)
      unless migration_lock.try_acquire
        raise Thor::Error,
              "Another pcrd migration is already running against slot " \
              "'#{config.migrate.replication_slot}'. Wait for it to finish, or stop it before retrying."
      end

      # ── Setup (skipped on --resume) ────────────────────────────────────
      if options[:resume]
        unless options[:"backfill-only"]
          setup.validate_resumable!(
            pub_name:  config.migrate.publication,
            slot_name: config.migrate.replication_slot
          )
        end
        start_lsn = checkpoint.backfill_start_lsn || "0/0"
        say "\nResuming migration from LSN #{start_lsn}..."
      else
        unless options[:"backfill-only"]
          say "\nCreating publication and replication slot..."
          start_lsn = setup.create_publication_and_slot(
            pub_name:  config.migrate.publication,
            slot_name: config.migrate.replication_slot
          )
          checkpoint.set_backfill_start_lsn(start_lsn)
          checkpoint.set_publication(config.migrate.publication)
          checkpoint.set_replication_slot(config.migrate.replication_slot)
          say "  Slot created at LSN #{start_lsn}.", :green
        else
          start_lsn = "0/0"
        end

        say "\nCreating target tables..."
        setup.create_target_tables(force_overwrite: options[:"force-overwrite"])
        say "  Target tables created.", :green
      end

      # ── WAL consumer + concurrent apply (streaming mode only) ──────────
      # The consumer streams WAL into a bounded queue; the apply worker drains
      # it on its own connection, concurrently with backfill, so the source
      # slot keeps advancing instead of retaining WAL for the whole backfill.
      consumer     = nil
      apply_worker = nil
      apply_pool   = nil

      unless options[:"backfill-only"]
        repl_conn = Connection::Replication.new(config.source)
        parser    = Replication::Pgoutput::Parser.new
        consumer  = Replication::Consumer.new(
          repl_conn:  repl_conn,
          parser:     parser,
          slot_name:  config.migrate.replication_slot,
          pub_name:   config.migrate.publication,
          start_lsn:  start_lsn
        )
        say "\nStarting WAL consumer..."
        consumer.start
        say "  Streaming from #{start_lsn}.", :green

        # Apply runs on its own target connection — Connection::Pool wraps a
        # single PG connection and must not be shared with backfill's writes.
        apply_pool   = Connection::Pool.new(config.target)
        apply_engine = Apply::Engine.new(
          target_pool:   apply_pool,
          config:        config,
          parser:        parser,
          source_schema: read_source_schema(source_pool, config)
        )
        apply_worker = Apply::Worker.new(
          engine: apply_engine,
          queue:  consumer.queue,
          # Acknowledge to the source only after the transaction is durably
          # applied and checkpointed, so WAL is not released prematurely.
          on_committed: lambda { |lsn|
            checkpoint.set_lsn(lsn)
            consumer.advance_lsn(lsn)
          }
        )
        apply_worker.start
        say "  Applying WAL concurrently with backfill.", :green
      end

      # ── Backfill (runs concurrently with the apply worker) ─────────────
      backfill_engine = Backfill::Engine.new(
        source_pool: source_pool,
        target_pool: target_pool,
        config:      config,
        checkpoint:  checkpoint
      )

      stop_requested = false
      trap("INT")  { stop_requested = true; backfill_engine.stop!; say "\nStopping..." }
      trap("TERM") { stop_requested = true; backfill_engine.stop! }

      if (rps = config.migrate.max_rows_per_second)
        say "\nStarting backfill (throttled to #{format_count(rps)} rows/s)..."
      else
        say "\nStarting backfill..."
      end
      bf_results = backfill_engine.run(on_batch: method(:print_batch_progress))
      say ""

      bf_results.each do |r|
        status = r.stopped_early ? " (interrupted)" : ""
        say "  #{r.table_name}: #{format_count(r.rows_copied)} rows in #{r.batch_count} batches#{status}", :green
      end

      # An apply failure during backfill must abort, not be silently ignored.
      if apply_worker&.failed?
        raise Replication::Error, "Apply worker stopped: #{apply_worker.error.message}"
      end

      if bf_results.any?(&:stopped_early) || stop_requested
        say "\nInterrupted. Resume with --resume.", :yellow
        return
      end

      say "\nBackfill complete.", :green

      if options[:"backfill-only"]
        say "Run `pcrd verify` to check row counts, then `pcrd cutover` when ready."
        return
      end

      # ── Streaming mode: the worker keeps applying; we monitor lag ──────
      say "Entering streaming mode. Press Ctrl-C to stop.\n"

      lag_monitor = Monitor::Lag.new(
        source_pool: source_pool,
        slot_name:   config.migrate.replication_slot
      )

      lag_check_interval = 2
      last_lag_check     = 0

      # Re-register SIGINT for the streaming phase so Ctrl-C breaks the loop cleanly.
      trap("INT")  { stop_requested = true; say "\n\nStopping after current event..." }
      trap("TERM") { stop_requested = true }

      loop do
        break if stop_requested

        # Surface a dead worker or consumer instead of spinning forever.
        if apply_worker.failed?
          raise Replication::Error, "Apply worker stopped: #{apply_worker.error.message}"
        end
        if consumer.failed? && consumer.queue.empty?
          raise Replication::Error, "WAL consumer stopped: #{consumer.last_error.message}"
        end

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if now - last_lag_check >= lag_check_interval
          lag = lag_monitor.lag_bytes
          threshold = config.migrate.lag_threshold_bytes
          if lag && lag <= threshold
            $stdout.print "\r  Lag: #{lag_monitor.summary}  #{PASTEL.green("✓ Ready for cutover")}   "
          else
            $stdout.print "\r  Lag: #{lag_monitor.summary}   "
          end
          $stdout.flush
          last_lag_check = now
        end
        sleep 0.1
      end

      say ""
      if stop_requested
        say "Migration interrupted. Resume with:", :yellow
        say "  pcrd migrate --config #{options[:config] || Config::DEFAULT_CONFIG_FILE} --resume", :yellow
      end
    rescue Replication::Error => e
      raise Thor::Error, "ERROR: #{e.message}\n\nReplication stopped. Resume with --resume once the cause is resolved."
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    rescue RuntimeError => e
      raise Thor::Error, "ERROR: #{e.message}"
    ensure
      # Stop the producer first so the queue is finite, then let the worker
      # drain what's left before closing its connection.
      consumer&.stop rescue nil
      apply_worker&.stop rescue nil
      apply_pool&.close rescue nil
      checkpoint&.close rescue nil
      migration_lock&.release rescue nil
      source_pool&.close rescue nil
      target_pool&.close rescue nil
    end

    desc "status", "Show current migration phase and replication lag"
    long_desc <<~DESC
      Reads the checkpoint database and queries pg_replication_slots to show:
      current phase, backfill progress, replication lag in bytes and estimated
      seconds, and whether the migration is ready for cutover.
    DESC
    def status
      config = load_config!
      Commands::Status.new(config, options).run
    rescue Config::LoadError => e
      raise Thor::Error, "ERROR: #{e.message}"
    end

    desc "cutover", "Trigger the cutover sequence"
    long_desc <<~DESC
      Drains remaining replication lag to zero, advances sequences on the target
      cluster, runs row-count verification, and prints a cutover report.

      The application must be in maintenance mode before running this command.
      Use --maintenance-confirmed to skip the interactive confirmation prompt.

      After this command completes, update DATABASE_URL to point at the target
      cluster and restart the application.
    DESC
    method_option :"maintenance-confirmed", type: :boolean, default: false,
                  desc: "Skip interactive confirmation that the app is in maintenance mode"
    def cutover
      config = load_config!

      unless options[:"maintenance-confirmed"]
        say "\nThe application must be in maintenance mode before continuing."
        say "Maintenance mode options:"
        say "  pgBouncer:  PAUSE <database>"
        say "  Kubernetes: kubectl scale --replicas=0 deployment/app"
        say "  Rails:      enable maintenance middleware"
        say ""
        answer = ask("Is the application in maintenance mode? [y/N]")
        return unless answer.strip.downcase == "y"
      end

      source_pool = Connection::Pool.new(config.source)
      target_pool = Connection::Pool.new(config.target)
      printer     = Output::CutoverPrinter.new

      say "\nRunning cutover sequence..."
      orchestrator = Cutover::Orchestrator.new(
        source_pool: source_pool,
        target_pool: target_pool,
        config:      config
      )

      result = orchestrator.run(on_progress: ->(msg) { say "  #{msg}" })

      printer.print(result)

      source_pool.close
      target_pool.close

      exit(result.passed ? 0 : 1)
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    end

    desc "verify", "Compare row counts and spot-check rows across clusters"
    long_desc <<~DESC
      Compares row counts on source and target for each migrated table, then
      spot-checks a random sample of rows field-by-field. Reports any mismatches.

      Safe to run at any point after backfill completes.
    DESC
    method_option :"sample-size", type: :numeric, default: 1_000,
                  desc: "Number of rows to spot-check per table"
    method_option :"post-cutover", type: :boolean, default: false,
                  desc: "Post-cutover mode: compare against the now-live target cluster"
    def verify
      config  = load_config!
      result  = Commands::Verify.new(config, options).run
      Output::CutoverPrinter.new.print_verify(result)
      exit(result.passed ? 0 : 1)
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    rescue RuntimeError => e
      raise Thor::Error, "ERROR: #{e.message}"
    end

    desc "demo SUBCOMMAND", "Set up and seed a demo database for testing and demonstration"
    subcommand "demo", Commands::Demo

    desc "cleanup", "Drop replication slot, publication, and checkpoint"
    long_desc <<~DESC
      Drops the replication slot and publication on the source cluster and deletes
      the local checkpoint database. Run this after the application has been
      successfully cut over to the target cluster and you no longer need to roll back.

      With --drop-source, also drops the source tables. This is irreversible and
      requires typing the table name to confirm.
    DESC
    method_option :"drop-source", type: :boolean, default: false,
                  desc: "Also drop source tables after cleanup (irreversible; requires confirmation)"
    def cleanup
      config = load_config!
      Commands::Cleanup.new(config, options).run
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    rescue RuntimeError => e
      raise Thor::Error, "ERROR: #{e.message}"
    end

    private

    # Resolves the config file path and returns a loaded Config::Root.
    # Falls back to pcrd.config.yml in the current directory if --config is omitted.
    # Raises Thor::Error with a clear message if the file cannot be loaded.
    def load_config!
      path = options[:config] || default_config_path
      Config::Loader.load(path)
    rescue Config::LoadError => e
      raise Thor::Error, "ERROR: #{e.message}"
    end

    def default_config_path
      default = Config::DEFAULT_CONFIG_FILE
      return default if File.exist?(default)

      raise Thor::Error,
            "ERROR: No config file found.\n\n" \
            "Create pcrd.config.yml in the current directory, or pass --config path/to/config.yml\n\n" \
            "Run `pcrd help migrate` for configuration documentation."
    end

    def require_config!
      load_config!
    end

    # Reads source columns + PK for every migrated table, keyed by table name.
    # Built once before the apply worker starts so it can run on its own thread.
    def read_source_schema(source_pool, config)
      reader = Schema::Reader.new(source_pool)
      (config.migrate&.tables || []).each_with_object({}) do |table, h|
        h[table.name] = {
          columns:    reader.read(table.name),
          pk_columns: reader.primary_key_columns(table.name)
        }
      end
    end

    def print_batch_progress(stats)
      rps = stats[:duration_ms] > 0 ? (stats[:row_count] * 1000.0 / stats[:duration_ms]).round : 0
      $stdout.print "\r  #{stats[:table]}  batch #{stats[:batch_num]}  " \
                    "#{format_count(stats[:rows_so_far])} rows  #{format_count(rps)} rows/s    "
      $stdout.flush
    end

    def format_count(n)
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end
  end
end

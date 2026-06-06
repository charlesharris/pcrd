# frozen_string_literal: true

require "pastel"

module Pcrd
  module Commands
    # Displays the current migration state from the checkpoint database and
    # (optionally) queries the live replication slot for current lag.
    #
    # Reads entirely from local state (checkpoint SQLite) so it works without
    # an active connection to source or target. If source is reachable, also
    # shows live replication lag and estimated time to cutover readiness.
    class Status
      PASTEL = Pastel.new

      PHASE_LABELS = {
        new:       "not started",
        backfill:  "backfill in progress",
        streaming: "streaming (catchup phase)",
        cutover:   "cutover complete"
      }.freeze

      def initialize(config, options = {})
        @config  = config
        @options = Options.normalize(options)
      end

      def run
        checkpoint_path = @config.migrate&.checkpoint_db || "./pcrd_checkpoint.sqlite3"

        unless File.exist?(checkpoint_path)
          puts
          puts "  #{PASTEL.yellow("No checkpoint found at #{checkpoint_path}")}"
          puts "  Run `pcrd migrate` to start the migration."
          puts
          return
        end

        store = Checkpoint::Store.new(checkpoint_path)
        print_status(store)
        store.close
      end

      private

      def print_status(store)
        phase   = store.phase
        started = store.started_at
        lsn     = store.lsn

        puts
        puts PASTEL.bold("Migration status")
        puts PASTEL.dim("─" * 60)
        puts

        puts "  Phase:    #{PASTEL.bold(phase_label(phase))}"
        puts "  Started:  #{started || PASTEL.dim("unknown")}"
        puts "  LSN:      #{lsn || PASTEL.dim("none")}" if lsn
        puts

        tables = @config.migrate&.tables || []
        if tables.any?
          puts "  #{PASTEL.bold("Tables:")}"
          tables.each { |t| print_table_status(store, t.name) }
          puts
        end

        print_live_lag(store)
      end

      def print_table_status(store, table_name)
        stats = store.batch_stats(table: table_name)
        last_key = store.last_completed_key(table: table_name)

        total_rows = stats[:total_rows]
        batches    = stats[:batch_count]
        rps        = stats[:avg_rows_per_sec]

        if batches.zero?
          puts "    #{PASTEL.dim("○")}  #{table_name}  #{PASTEL.dim("not started")}"
        else
          rps_label = rps > 0 ? "  #{PASTEL.dim("avg #{format_count(rps.to_i)} rows/sec")}" : ""
          puts "    #{PASTEL.green("✓")}  #{table_name}  " \
               "#{format_count(total_rows)} rows copied  " \
               "(#{batches} batch#{batches == 1 ? '' : 'es'})#{rps_label}"
          puts "       last key: #{last_key.inspect}" if last_key && @options[:verbose]
        end
      end

      def print_live_lag(store)
        return unless @config.source && @config.migrate&.replication_slot

        source_pool = Connection::Client.new(@config.source)
        lag_monitor = Monitor::Lag.new(
          source_pool: source_pool,
          slot_name:   @config.migrate.replication_slot
        )

        lag = lag_monitor.lag_bytes
        threshold = @config.migrate&.lag_threshold_bytes || 1_048_576

        if lag.nil?
          puts "  #{PASTEL.dim("Replication slot not found or not active")}"
        elsif lag == 0
          puts "  #{PASTEL.green("Replication lag: 0 bytes")}  #{PASTEL.green("✓ Ready for cutover")}"
        elsif lag <= threshold
          puts "  Replication lag: #{PASTEL.green(lag_monitor.summary)}  #{PASTEL.green("✓ Ready for cutover")}"
        else
          puts "  Replication lag: #{lag_monitor.summary}"
        end

        lsn = lag_monitor.confirmed_lsn
        puts "  Confirmed LSN:   #{lsn}" if lsn

        source_pool.close
      rescue Connection::Error
        puts "  #{PASTEL.dim("(source not reachable — showing checkpoint data only)")}"
      end

      def phase_label(phase)
        PHASE_LABELS[phase] || phase.to_s
      end

      def format_count(n)
        n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      end
    end
  end
end

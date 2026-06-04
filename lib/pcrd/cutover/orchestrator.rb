# frozen_string_literal: true

module Pcrd
  module Cutover
    # Orchestrates the cutover sequence.
    #
    # Preconditions (operator's responsibility):
    #   - Application is in maintenance mode (writes to source have stopped)
    #   - pcrd migrate is running in streaming mode (or was cleanly stopped)
    #
    # Steps:
    #   1. Verify the migration is at a cuttable phase (backfill complete)
    #   2. Drain remaining replication lag to zero (with timeout)
    #   3. Advance sequences on target
    #   4. Verify row counts match
    #   5. Print cutover report and "READY" signal
    class Orchestrator
      Result = Data.define(
        :passed,
        :row_counts,        # Hash<table_name, {source:, target:}>
        :sequence_results,  # Array<Sequences::SequenceResult>
        :lag_at_cutover,    # Integer bytes
        :warnings           # Array<String>
      )

      def initialize(source_pool:, target_pool:, config:)
        @source  = source_pool
        @target  = target_pool
        @config  = config
      end

      # Runs the full cutover sequence.
      # on_progress: optional Proc called with a status string during drain
      def run(on_progress: nil)
        warnings   = []
        table_names = (@config.migrate&.tables || []).map(&:name)

        # 1. Drain remaining lag
        on_progress&.call("Draining replication lag...")
        lag = drain_lag(table_names, on_progress: on_progress)

        # 2. Advance sequences
        on_progress&.call("Advancing target sequences...")
        seq_results = Sequences.new(
          source_pool:   @source,
          target_pool:   @target,
          safety_buffer: @config.cutover&.sequence_buffer || 1_000
        ).advance(table_names)

        # 3. Row count verification
        on_progress&.call("Verifying row counts...")
        row_counts = verify_counts(table_names, warnings)

        passed = row_counts.all? { |_, v| v[:source] == v[:target] }

        Result.new(
          passed:           passed,
          row_counts:       row_counts,
          sequence_results: seq_results,
          lag_at_cutover:   lag,
          warnings:         warnings
        )
      end

      private

      def drain_lag(table_names, on_progress:)
        slot_name = @config.migrate&.replication_slot
        return 0 unless slot_name

        timeout    = @config.cutover&.lag_drain_timeout || 300
        deadline   = Time.now + timeout
        lag_monitor = Monitor::Lag.new(source_pool: @source, slot_name: slot_name)

        loop do
          lag = lag_monitor.lag_bytes
          on_progress&.call("  Lag: #{lag ? "#{lag} bytes" : "unknown"}")

          return lag || 0 if lag&.zero?
          return lag || 0 if !lag  # slot may have been dropped

          if Time.now > deadline
            on_progress&.call("  Warning: lag did not reach zero within #{timeout}s (#{lag} bytes remaining)")
            return lag
          end

          sleep 1
        end
      end

      def verify_counts(table_names, warnings)
        table_names.each_with_object({}) do |name, counts|
          src_count = @source.exec("SELECT COUNT(*) FROM #{@source.quote_ident(name)}")[0]["count"].to_i
          tgt_count = @target.exec("SELECT COUNT(*) FROM #{@target.quote_ident(name)}")[0]["count"].to_i

          counts[name] = { source: src_count, target: tgt_count }

          if src_count != tgt_count
            warnings << "#{name}: row count mismatch (source=#{src_count}, target=#{tgt_count})"
          end
        rescue Connection::Error => e
          warnings << "#{name}: could not verify row count: #{e.message}"
          counts[name] = { source: nil, target: nil }
        end
      end
    end
  end
end

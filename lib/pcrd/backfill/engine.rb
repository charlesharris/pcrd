# frozen_string_literal: true

module Pcrd
  module Backfill
    # Drives the full backfill loop for all tables in the migration spec.
    #
    # For each table:
    #   1. Reads last_completed_key from the checkpoint store (nil = fresh start)
    #   2. Loops: execute one Batch, record it in checkpoint, call on_batch
    #   3. Stops when the batch returns no rows (end of table) or stop! is called
    #
    # Thread safety: stop! can be called from any thread; the engine checks
    # @stop between batches and exits cleanly after the current batch finishes.
    class Engine
      Result = Data.define(:table_name, :rows_copied, :batch_count, :duration_ms, :stopped_early)

      def initialize(source_pool:, target_pool:, config:, checkpoint:, source_schema: {})
        @source_pool   = source_pool
        @target_pool   = target_pool
        @config        = config
        @checkpoint    = checkpoint
        @source_schema = source_schema  # Hash<table_name, { columns:, pk_columns: }>
        @stop          = false
        @mutex         = Mutex.new
      end

      # Runs backfill for all configured tables.
      #
      # on_batch: optional Proc called after each batch with a stats Hash:
      #   { table:, batch_num:, row_count:, rows_so_far:, duration_ms:, last_key: }
      #
      # Returns Array<Result>.
      def run(on_batch: nil)
        @checkpoint.set_phase(:backfill)
        @checkpoint.set_started_at(Time.now.iso8601)

        @config.migrate.tables.map do |table_config|
          run_table(table_config, on_batch: on_batch)
        end
      end

      # Signal the engine to stop cleanly after the current batch.
      def stop!
        @mutex.synchronize { @stop = true }
      end

      def stopped?
        @mutex.synchronize { @stop }
      end

      private

      def run_table(table_config, on_batch:)
        table_name   = table_config.name
        schema_info  = @source_schema[table_name] ||
                       fetch_schema(table_name)
        source_cols  = schema_info[:columns]
        pk_cols      = schema_info[:pk_columns]

        transformer = Transform::RowTransformer.new(table_config, source_cols)

        batch_runner = Batch.new(
          source_pool: @source_pool,
          target_pool: @target_pool,
          transformer: transformer,
          table_name:  table_name,
          pk_columns:  pk_cols,
          batch_size:  @config.migrate.batch_size
        )

        last_key    = @checkpoint.last_completed_key(table: table_name)
        batch_num   = @checkpoint.batch_stats(table: table_name)[:batch_count]
        rows_so_far = @checkpoint.total_rows_copied(table: table_name)
        t_start     = monotonic_ms

        loop do
          break if stopped?

          result = batch_runner.execute(after_key: last_key)
          break unless result  # empty page — end of table

          batch_num   += 1
          rows_so_far += result[:row_count]
          last_key     = result[:end_key]

          @checkpoint.record_batch(
            table:       table_name,
            start_key:   result[:start_key],
            end_key:     result[:end_key],
            row_count:   result[:row_count],
            duration_ms: result[:duration_ms]
          )

          on_batch&.call(
            table:       table_name,
            batch_num:   batch_num,
            row_count:   result[:row_count],
            rows_so_far: rows_so_far,
            duration_ms: result[:duration_ms],
            last_key:    last_key
          )
        end

        Result.new(
          table_name:    table_name,
          rows_copied:   rows_so_far,
          batch_count:   batch_num,
          duration_ms:   monotonic_ms - t_start,
          stopped_early: stopped?
        )
      end

      def fetch_schema(table_name)
        reader = Schema::Reader.new(@source_pool)
        {
          columns:    reader.read(table_name),
          pk_columns: reader.primary_key_columns(table_name)
        }
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end
    end
  end
end

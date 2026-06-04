# frozen_string_literal: true

module Pcrd
  module Backfill
    # Executes one backfill batch: SELECT a page of rows from source,
    # transform them, and COPY to target.
    #
    # Returns a result hash with row_count, duration_ms, start_key, end_key.
    # Returns nil when the source page is empty (signals end-of-table to Engine).
    class Batch
      # PostgreSQL COPY TEXT format: tab-delimited, \N for NULL.
      # Using text format avoids CSV quoting edge cases and is marginally faster.
      NULL_MARKER = "\\N"
      DELIMITER   = "\t"

      def initialize(source_pool:, target_pool:, transformer:, table_name:,
                     pk_columns:, batch_size:, schema_name: "public")
        @source_pool = source_pool
        @target_pool = target_pool
        @transformer  = transformer
        @table_name   = table_name
        @pk_columns   = pk_columns
        @batch_size   = batch_size
        @schema_name  = schema_name
        @quoted_table = "#{source_pool.quote_ident(schema_name)}.#{source_pool.quote_ident(table_name)}"
      end

      # Copies one page starting after `after_key`.
      # after_key: nil (first page), a scalar, or an Array for composite PKs.
      #
      # Returns Hash or nil.
      def execute(after_key:)
        t0   = monotonic_ms
        rows = fetch_source_rows(after_key)
        return nil if rows.empty?

        transformed = rows.map { |r| @transformer.transform(r) }
        copy_to_target(transformed)

        duration_ms = monotonic_ms - t0

        {
          row_count:   rows.size,
          duration_ms: duration_ms,
          start_key:   extract_key(rows.first),
          end_key:     extract_key(rows.last)
        }
      end

      private

      # ── source SELECT ────────────────────────────────────────────────────

      def fetch_source_rows(after_key)
        src_cols  = @transformer.source_column_names_kept
        col_list  = src_cols.map { |c| @source_pool.quote_ident(c) }.join(", ")
        pk_quoted = @pk_columns.map { |c| @source_pool.quote_ident(c) }.join(", ")

        if after_key.nil?
          sql    = "SELECT #{col_list} FROM #{@quoted_table} ORDER BY #{pk_quoted} LIMIT $1"
          params = [@batch_size]
        elsif @pk_columns.size == 1
          sql    = "SELECT #{col_list} FROM #{@quoted_table} " \
                   "WHERE #{@source_pool.quote_ident(@pk_columns.first)} > $1 " \
                   "ORDER BY #{pk_quoted} LIMIT $2"
          params = [after_key, @batch_size]
        else
          # Composite PK: row-value comparison
          pk_placeholders = @pk_columns.each_with_index.map { |_, i| "$#{i + 1}" }.join(", ")
          sql    = "SELECT #{col_list} FROM #{@quoted_table} " \
                   "WHERE (#{pk_quoted}) > (#{pk_placeholders}) " \
                   "ORDER BY #{pk_quoted} LIMIT $#{@pk_columns.size + 1}"
          params = Array(after_key) + [@batch_size]
        end

        result = @source_pool.exec(sql, params)
        result.to_a
      end

      # ── target COPY ──────────────────────────────────────────────────────

      def copy_to_target(transformed_rows)
        target_cols = @transformer.target_column_names
        quoted_tgt  = "#{@target_pool.quote_ident(@schema_name)}.#{@target_pool.quote_ident(@table_name)}"
        col_list    = target_cols.map { |c| @target_pool.quote_ident(c) }.join(", ")
        copy_sql    = "COPY #{quoted_tgt} (#{col_list}) FROM STDIN WITH (FORMAT text)"

        @target_pool.copy_data(copy_sql) do |conn|
          transformed_rows.each do |row|
            values = target_cols.map { |col| encode_copy_value(row[col]) }
            conn.put_copy_data(values.join(DELIMITER) + "\n")
          end
        end
      end

      # ── helpers ──────────────────────────────────────────────────────────

      def encode_copy_value(val)
        return NULL_MARKER if val.nil?

        val.to_s
           .gsub("\\", "\\\\")
           .gsub("\t", "\\t")
           .gsub("\n", "\\n")
           .gsub("\r", "\\r")
      end

      def extract_key(pg_row)
        keys = @pk_columns.map { |col| pg_row[col] }
        keys.size == 1 ? keys.first : keys
      end

      def monotonic_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
      end
    end
  end
end

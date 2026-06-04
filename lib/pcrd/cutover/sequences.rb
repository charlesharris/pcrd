# frozen_string_literal: true

module Pcrd
  module Cutover
    # Advances sequences on the target cluster to be safely ahead of the source.
    #
    # Called during cutover after writes on the source have stopped (maintenance
    # mode active). At that point the source sequence is frozen and we can
    # safely compute the correct target value.
    #
    # For each serial/bigserial/identity column in the migrated tables:
    #   1. Read last_value + is_called from the source sequence
    #   2. Read MAX(pk_col) from the source table (covers rolled-back transactions
    #      that consumed sequence values without committing a row)
    #   3. Take the maximum of both + safety_buffer
    #   4. Call setval on the target sequence
    #
    # Returns an Array<SequenceResult> describing every setval performed.
    class Sequences
      SequenceResult = Data.define(
        :table_name,
        :column_name,
        :source_seq_name,
        :target_seq_name,
        :source_last_value,
        :source_max_id,
        :target_value,
        :safety_buffer
      )

      def initialize(source_pool:, target_pool:, safety_buffer: 1_000)
        @source   = source_pool
        @target   = target_pool
        @buffer   = safety_buffer
      end

      # Advances sequences for all serial/identity columns in the given tables.
      # Returns Array<SequenceResult>.
      def advance(table_names)
        results = []
        table_names.each do |table_name|
          sequences_for_table(table_name).each do |col_name, seq_name|
            result = advance_one(table_name, col_name, seq_name)
            results << result if result
          end
        end
        results
      end

      private

      # Returns Hash<column_name, qualified_sequence_name> for all owned sequences.
      # Handles both SERIAL/BIGSERIAL columns and GENERATED ... AS IDENTITY columns.
      def sequences_for_table(table_name)
        result = @source.exec(<<~SQL, [table_name])
          SELECT a.attname                               AS col_name,
                 n.nspname || '.' || seq.relname         AS seq_name
          FROM   pg_depend d
          JOIN   pg_class seq ON seq.oid = d.objid AND seq.relkind = 'S'
          JOIN   pg_namespace n ON n.oid = seq.relnamespace
          JOIN   pg_attribute a
                   ON  a.attrelid = d.refobjid
                   AND a.attnum   = d.refobjsubid
          JOIN   pg_class c ON c.oid = a.attrelid AND c.relname = $1
          WHERE  d.classid    = 'pg_class'::regclass
            AND  d.refclassid = 'pg_class'::regclass
            AND  d.deptype   IN ('a', 'i')
        SQL

        result.each_with_object({}) do |row, h|
          h[row["col_name"]] = row["seq_name"]
        end
      rescue Connection::Error
        {}
      end

      def advance_one(table_name, col_name, source_seq_name)
        # Read source sequence state
        seq_row = @source.exec(
          "SELECT last_value, is_called FROM #{source_seq_name}"
        )[0]
        source_last    = seq_row["last_value"].to_i
        is_called      = seq_row["is_called"] == "t"
        effective_last = is_called ? source_last : source_last - 1

        # Read actual max value in table (accounts for rolled-back allocations)
        quoted_col   = @source.quote_ident(col_name)
        quoted_table = @source.quote_ident(table_name)
        max_row    = @source.exec("SELECT COALESCE(MAX(#{quoted_col}), 0) AS m FROM #{quoted_table}")
        source_max = max_row[0]["m"].to_i

        target_value = [effective_last, source_max].max + @buffer

        # Derive the target sequence name from the source (strip schema, use public.)
        seq_base        = source_seq_name.split(".").last
        target_seq_name = "public.#{seq_base}"

        # Create the sequence on the target if it doesn't already exist.
        # pcrd strips sequences from generated DDL by design; cutover creates them.
        ensure_target_sequence(table_name, col_name, target_seq_name)

        @target.exec("SELECT setval($1, $2)", [target_seq_name, target_value])

        SequenceResult.new(
          table_name:        table_name,
          column_name:       col_name,
          source_seq_name:   source_seq_name,
          target_seq_name:   target_seq_name,
          source_last_value: source_last,
          source_max_id:     source_max,
          target_value:      target_value,
          safety_buffer:     @buffer
        )
      rescue Connection::Error => e
        warn "  Warning: could not advance sequence for #{table_name}.#{col_name}: #{e.message}"
        nil
      end

      def ensure_target_sequence(table_name, col_name, seq_name)
        exists = @target.exec(
          "SELECT 1 FROM pg_class c " \
          "JOIN pg_namespace n ON n.oid = c.relnamespace " \
          "WHERE n.nspname || '.' || c.relname = $1 AND c.relkind = 'S'",
          [seq_name]
        ).ntuples > 0
        return if exists

        qt  = @target.quote_ident(table_name)
        qc  = @target.quote_ident(col_name)
        @target.exec_sql(<<~SQL)
          CREATE SEQUENCE #{seq_name};
          ALTER TABLE #{qt} ALTER COLUMN #{qc} SET DEFAULT nextval('#{seq_name}');
          ALTER SEQUENCE #{seq_name} OWNED BY #{qt}.#{qc};
        SQL
      end
    end
  end
end

# frozen_string_literal: true

module Pcrd
  module Transform
    # Runs pre-migration data validation queries on the source database.
    #
    # For each column in the migration spec that involves a validated cast,
    # Validator queries the source table to confirm no rows would be rejected
    # or silently truncated by the cast. Failures are collected and reported
    # all at once so the operator can fix everything in one pass.
    #
    # Called by the preflight phase before any replication slot is created.
    class Validator
      ValidationFailure = Data.define(:table_name, :column_name, :source_type,
                                      :target_type, :failing_count, :description,
                                      :warn_only)

      def initialize(source_pool)
        @pool = source_pool
      end

      # Validates all columns in table_config against their source schema.
      #
      # source_columns: Array<Schema::Column> from Schema::Reader
      # Returns Array<ValidationFailure> — empty means all checks passed.
      # Raises on unexpected database errors.
      def validate(table_config, source_columns)
        failures = []
        col_index = source_columns.each_with_object({}) { |c, h| h[c.name] = c }

        (table_config.columns || {}).each do |src_name, col_spec|
          next if col_spec.drop || col_spec.type.nil?

          source_col = col_index[src_name.to_s]
          next unless source_col

          safety = TypeMap.cast_safety(source_col.type_name, col_spec.type)
          next if %i[no_op always_safe].include?(safety)

          if safety == :unsupported
            failures << ValidationFailure.new(
              table_name:    table_config.name,
              column_name:   src_name,
              source_type:   source_col.display_type,
              target_type:   col_spec.type,
              failing_count: nil,
              description:   "pcrd does not support this type transition — " \
                             "use a custom transform or perform it separately",
              warn_only:     false
            )
            next
          end

          # :validated — run the data check
          result = run_check(table_config.name, src_name, source_col, col_spec.type)
          failures << result if result
        end

        failures
      end

      private

      def run_check(table_name, col_name, source_col, target_type)
        rule = TypeMap.validated_rule(source_col.type_name, target_type)
        return nil unless rule

        quoted_col   = Sql.quote_ident(col_name.to_s)
        quoted_table = Sql.quote_table(table_name)

        count = if rule[:check_expr] == :varchar_length_check
                  varchar_length_check(quoted_table, quoted_col, target_type)
                elsif rule[:check_expr]
                  expr    = rule[:check_expr].call(quoted_col)
                  result  = @pool.exec("SELECT COUNT(*) FROM #{quoted_table} WHERE #{expr}")
                  result[0]["count"].to_i
                else
                  0  # warn_only rule with no SQL check
                end

        return nil if count.zero? && !rule[:warn_only]

        ValidationFailure.new(
          table_name:    table_name,
          column_name:   col_name.to_s,
          source_type:   source_col.display_type,
          target_type:   target_type,
          failing_count: rule[:check_expr] ? count : nil,
          description:   rule[:description],
          warn_only:     rule[:warn_only]
        )
      end

      def varchar_length_check(quoted_table, quoted_col, target_type)
        max_len = TypeMap.extract_length(target_type)
        return 0 unless max_len

        result = @pool.exec(
          "SELECT COUNT(*) FROM #{quoted_table} WHERE length(#{quoted_col}) > $1",
          [max_len]
        )
        result[0]["count"].to_i
      end
    end
  end
end

# frozen_string_literal: true

module Pcrd
  module Schema
    # Generates CREATE TABLE DDL for the target cluster from a source schema
    # plus a Config::Table migration spec.
    #
    # Column ordering: if table_config.optimize_column_order is true, columns
    # are sorted for minimal padding waste before rendering.
    #
    # Exclusions (by design):
    #   - Foreign key constraints: listed in preflight post-cutover checklist
    #   - Non-PK indexes:          operator creates on target before cutover
    #   - GENERATED/identity:      target uses plain type; sequence advanced at cutover
    #   - nextval() defaults:      referencing source sequence; omitted from DDL
    module DDL
      # Returns a CREATE TABLE SQL string (no trailing semicolon — caller adds
      # one if needed, or passes directly to exec_sql).
      def self.generate(source_columns:, table_config:, primary_key_columns: [],
                        schema_name: "public")
        target_cols = synthesize_target_columns(source_columns, table_config)
        target_pk   = map_pk_through_renames(primary_key_columns, table_config)

        render(target_cols, table_config.name, schema_name, target_pk)
      end

      private_class_method def self.synthesize_target_columns(source_columns, table_config)
        differ  = Differ.new
        entries = differ.diff(source_columns: source_columns, table_config: table_config)
        cols    = differ.target_columns_from_diff(entries)

        if table_config.optimize_column_order
          Packer.new.optimize(cols)
        else
          cols
        end
      end

      private_class_method def self.render(columns, table_name, schema_name, pk_columns)
        name_w = columns.map { |c| Sql.quote_ident(c.name).length }.max.to_i
        type_w = columns.map { |c| c.display_type.length }.max.to_i

        lines = columns.map { |c| column_line(c, name_w, type_w) }
        lines << "  PRIMARY KEY (#{Sql.quote_columns(pk_columns)})" if pk_columns.any?

        "CREATE TABLE #{Sql.quote_table(table_name, schema: schema_name)} (\n#{lines.join(",\n")}\n)"
      end

      private_class_method def self.column_line(col, name_w, type_w)
        parts = ["  #{Sql.quote_ident(col.name).ljust(name_w)}  #{col.display_type.ljust(type_w)}"]
        parts << "NOT NULL" unless col.nullable
        # Omit nextval() defaults — they reference source sequences.
        # Identity columns (GENERATED ALWAYS AS IDENTITY) are also omitted;
        # a plain column is created and the sequence is advanced at cutover.
        if col.default_expr &&
           !col.default_expr.start_with?("nextval(") &&
           !col.default_expr.match?(/\bgenerated\b/i)
          parts << "DEFAULT #{col.default_expr}"
        end
        parts.join("  ").rstrip
      end

      private_class_method def self.map_pk_through_renames(pk_columns, table_config)
        renames = (table_config.columns || {}).each_with_object({}) do |(src, spec), map|
          map[src.to_s] = spec.rename if spec.rename
        end
        pk_columns.map { |col| renames[col] || col }
      end
    end
  end
end

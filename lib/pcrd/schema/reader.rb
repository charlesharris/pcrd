# frozen_string_literal: true

module Pcrd
  module Schema
    class Reader
      TYPALIGN_BYTES = { "c" => 1, "s" => 2, "i" => 4, "d" => 8 }.freeze

      def initialize(pool)
        @pool = pool
      end

      def read(table_name, schema_name: "public")
        rows = @pool.exec(COLUMNS_QUERY, [table_name, schema_name])
        raise TableNotFound, "Table #{schema_name}.#{table_name} not found" if rows.ntuples.zero?

        rows.map { build_column(_1) }
      end

      def table_exists?(table_name, schema_name: "public")
        result = @pool.exec(<<~SQL, [table_name, schema_name])
          SELECT 1
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  c.relname = $1
            AND  n.nspname = $2
            AND  c.relkind = 'r'
        SQL
        result.ntuples > 0
      end

      # Returns an array of column names that form the primary key, in key order.
      def primary_key_columns(table_name, schema_name: "public")
        result = @pool.exec(<<~SQL, [table_name, schema_name])
          SELECT a.attname
          FROM   pg_index i
          JOIN   pg_attribute a ON a.attrelid = i.indrelid
                               AND a.attnum = ANY(i.indkey)
          JOIN   pg_class c     ON c.oid = i.indrelid
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  c.relname = $1
            AND  n.nspname = $2
            AND  i.indisprimary
          ORDER BY array_position(i.indkey, a.attnum)
        SQL
        result.column_values(0)
      end

      # Returns the table's replica identity setting as a single char:
      #   'd' default (primary key)   'n' nothing
      #   'f' full (whole row)        'i' a specific unique index
      # Returns nil if the table is not found. This governs whether UPDATE/DELETE
      # WAL records carry the old-row key columns the apply engine needs.
      def replica_identity(table_name, schema_name: "public")
        result = @pool.exec(<<~SQL, [table_name, schema_name])
          SELECT c.relreplident
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  c.relname = $1
            AND  n.nspname = $2
        SQL
        result.ntuples > 0 ? result[0]["relreplident"] : nil
      end

      # Returns the estimated live row count from pg_class statistics.
      def estimated_row_count(table_name, schema_name: "public")
        result = @pool.exec(<<~SQL, [table_name, schema_name])
          SELECT c.reltuples::bigint
          FROM   pg_class c
          JOIN   pg_namespace n ON n.oid = c.relnamespace
          WHERE  c.relname = $1
            AND  n.nspname = $2
        SQL
        result.ntuples > 0 ? result[0]["reltuples"].to_i : 0
      end

      private

      COLUMNS_QUERY = <<~SQL.freeze
        SELECT
          a.attnum,
          a.attname,
          t.typname,
          format_type(a.atttypid, a.atttypmod) AS formatted_type,
          t.typalign,
          t.typlen,
          NOT a.attnotnull         AS nullable,
          pg_get_expr(d.adbin, d.adrelid) AS default_expr
        FROM   pg_attribute a
        JOIN   pg_class c     ON c.oid = a.attrelid
        JOIN   pg_namespace n ON n.oid = c.relnamespace
        JOIN   pg_type t      ON t.oid = a.atttypid
        LEFT   JOIN pg_attrdef d
               ON  d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE  c.relname = $1
          AND  n.nspname = $2
          AND  a.attnum > 0
          AND  NOT a.attisdropped
        ORDER  BY a.attnum
      SQL

      def build_column(row)
        typlen    = row["typlen"].to_i
        fixed_size = typlen > 0 ? typlen : nil  # -1 = varlena, -2 = C string

        Column.new(
          attnum:         row["attnum"].to_i,
          name:           row["attname"],
          type_name:      row["typname"],
          formatted_type: row["formatted_type"],
          alignment:      TYPALIGN_BYTES.fetch(row["typalign"], 4),
          fixed_size:     fixed_size,
          nullable:       row["nullable"] == "t",
          default_expr:   row["default_expr"]
        )
      end
    end
  end
end

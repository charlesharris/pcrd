# frozen_string_literal: true

module Pcrd
  module Schema
    # Reads the "secondary" schema objects that the load DDL deliberately omits
    # (Schema::DDL creates only the table + primary key). Used by the
    # target-readiness manifest to report and regenerate what must exist on the
    # target before cutover.
    #
    # Works against either cluster — point it at the source to discover objects,
    # at the target to see what already exists.
    class ObjectReader
      Index      = Data.define(:name, :definition, :unique, :columns)
      Constraint = Data.define(:name, :kind, :definition, :columns) # kind: f|u|c
      IdentityColumn = Data.define(:column, :kind) # kind: "identity" | "serial"

      def initialize(pool)
        @pool = pool
      end

      # Non-PK indexes that are not backing a unique/PK constraint (those are
      # reported under #constraints instead, to avoid double-counting).
      def indexes(table_name, schema_name: "public")
        @pool.exec(INDEXES_SQL, [table_name, schema_name]).map do |r|
          Index.new(
            name:       r["index_name"],
            definition: r["definition"],
            unique:     r["indisunique"] == "t",
            columns:    split_list(r["columns"])
          )
        end
      end

      # Foreign-key, unique, and check constraints (not the primary key).
      def constraints(table_name, schema_name: "public")
        @pool.exec(CONSTRAINTS_SQL, [table_name, schema_name]).map do |r|
          Constraint.new(
            name:       r["conname"],
            kind:       r["contype"],
            definition: r["definition"],
            columns:    split_list(r["columns"])
          )
        end
      end

      # Identity (GENERATED ... AS IDENTITY) and serial (nextval default) columns.
      def identity_columns(table_name, schema_name: "public")
        @pool.exec(IDENTITY_SQL, [table_name, schema_name]).map do |r|
          IdentityColumn.new(
            column: r["attname"],
            kind:   r["attidentity"].to_s.empty? ? "serial" : "identity"
          )
        end
      end

      private

      def split_list(str)
        str.to_s.empty? ? [] : str.split(",")
      end

      INDEXES_SQL = <<~SQL.freeze
        SELECT i.relname AS index_name,
               pg_get_indexdef(ix.indexrelid) AS definition,
               ix.indisunique,
               array_to_string(ARRAY(
                 SELECT a.attname
                 FROM   unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord)
                 JOIN   pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum
                 WHERE  k.attnum <> 0
                 ORDER  BY k.ord
               ), ',') AS columns
        FROM   pg_index ix
        JOIN   pg_class i     ON i.oid = ix.indexrelid
        JOIN   pg_class t     ON t.oid = ix.indrelid
        JOIN   pg_namespace n ON n.oid = t.relnamespace
        WHERE  t.relname = $1 AND n.nspname = $2
          AND  NOT ix.indisprimary
          AND  ix.indexrelid NOT IN (
                 SELECT conindid FROM pg_constraint
                 WHERE  conrelid = t.oid AND conindid <> 0
               )
        ORDER  BY i.relname
      SQL

      CONSTRAINTS_SQL = <<~SQL.freeze
        SELECT c.conname,
               c.contype,
               pg_get_constraintdef(c.oid) AS definition,
               array_to_string(ARRAY(
                 SELECT a.attname
                 FROM   unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
                 JOIN   pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
                 ORDER  BY k.ord
               ), ',') AS columns
        FROM   pg_constraint c
        JOIN   pg_class t     ON t.oid = c.conrelid
        JOIN   pg_namespace n ON n.oid = t.relnamespace
        WHERE  t.relname = $1 AND n.nspname = $2
          AND  c.contype IN ('f', 'u', 'c')
        ORDER  BY c.conname
      SQL

      IDENTITY_SQL = <<~SQL.freeze
        SELECT a.attname, a.attidentity
        FROM   pg_attribute a
        JOIN   pg_class t     ON t.oid = a.attrelid
        JOIN   pg_namespace n ON n.oid = t.relnamespace
        LEFT   JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
        WHERE  t.relname = $1 AND n.nspname = $2
          AND  a.attnum > 0 AND NOT a.attisdropped
          AND  (a.attidentity IN ('a', 'd')
                OR pg_get_expr(ad.adbin, ad.adrelid) LIKE 'nextval(%')
        ORDER  BY a.attnum
      SQL
    end
  end
end

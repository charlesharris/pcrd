# frozen_string_literal: true

require "set"

module Pcrd
  module Readiness
    # Builds the target-readiness manifest: for each migrated table, which
    # secondary objects exist on the source, whether the target already has
    # them, and runnable DDL to create the missing ones before cutover.
    #
    # The load DDL (Schema::DDL) creates only table + primary key; indexes,
    # constraints, grants, etc. are deferred so the bulk load is fast. This
    # turns that deferral from tribal knowledge into an explicit checklist.
    #
    # Rename/drop aware: an object referencing a dropped column is reported as
    # not-recreatable; one referencing a renamed column is flagged for manual
    # regeneration (its source DDL is shown commented out) rather than emitting
    # silently-wrong SQL.
    #
    # Sequences/identity are reported as informational — they are restored
    # automatically by `pcrd cutover` (Cutover::Sequences), so the manifest does
    # not emit competing DDL for them.
    class Manifest
      # status: :missing (DDL provided) | :present | :needs_review | :info
      Entry  = Data.define(:category, :name, :status, :detail, :ddl)
      Table  = Data.define(:table_name, :entries)
      Result = Data.define(:tables)

      KIND_LABEL = { "f" => "foreign key", "u" => "unique constraint", "c" => "check constraint" }.freeze

      def initialize(source_pool:, target_pool:, config:)
        @source = source_pool
        @target = target_pool
        @config = config
      end

      def build
        src = Schema::ObjectReader.new(@source)
        tgt = Schema::ObjectReader.new(@target)

        tables = (@config.migrate&.tables || []).map do |table_config|
          Table.new(table_name: table_config.name, entries: entries_for(table_config, src, tgt))
        end

        Result.new(tables: tables)
      end

      private

      def entries_for(table_config, src, tgt)
        name           = table_config.name
        drops, renames = change_maps(table_config)
        present_idx    = tgt.indexes(name).map(&:name).to_set
        present_con    = tgt.constraints(name).map(&:name).to_set

        index_entries(name, src.indexes(name), present_idx, drops, renames) +
          constraint_entries(name, src.constraints(name), present_con, drops, renames) +
          sequence_entries(src.identity_columns(name)) +
          owner_entries(name, src, tgt) +
          grant_entries(name, src, tgt) +
          comment_entries(name, src, tgt, drops, renames)
      end

      def index_entries(table, indexes, present, drops, renames)
        indexes.map do |ix|
          review = review_reason(ix.columns, drops, renames)
          if present.include?(ix.name)
            entry("index", ix.name, :present, "already on target", nil)
          elsif review
            entry("index", ix.name, :needs_review, review, "-- #{review}\n-- #{ix.definition};")
          else
            entry("index", ix.name, :missing, ix.unique ? "unique index" : "index",
                  "#{concurrently(ix.definition)};")
          end
        end
      end

      def constraint_entries(table, constraints, present, drops, renames)
        constraints.map do |c|
          label  = KIND_LABEL[c.kind]
          review = review_reason(c.columns, drops, renames)
          if present.include?(c.name)
            entry("constraint", c.name, :present, "already on target", nil)
          elsif review
            entry("constraint", c.name, :needs_review, review,
                  "-- #{review}\n-- ALTER TABLE #{Sql.quote_table(table)} " \
                  "ADD CONSTRAINT #{Sql.quote_ident(c.name)} #{c.definition};")
          else
            fk_note = c.kind == "f" ? "  -- run after all referenced tables are loaded" : ""
            ddl = "ALTER TABLE #{Sql.quote_table(table)} " \
                  "ADD CONSTRAINT #{Sql.quote_ident(c.name)} #{c.definition};#{fk_note}"
            entry("constraint", c.name, :missing, label, ddl)
          end
        end
      end

      def sequence_entries(identity_columns)
        identity_columns.map do |col|
          entry("sequence", col.column, :info,
                "#{col.kind} column — restored automatically by `pcrd cutover`", nil)
        end
      end

      def owner_entries(table, src, tgt)
        source_owner = src.owner(table)
        return [] unless source_owner

        if source_owner == tgt.owner(table)
          [entry("owner", source_owner, :present, "owner already #{source_owner}", nil)]
        else
          [entry("owner", source_owner, :missing, "set owner to #{source_owner}",
                 "ALTER TABLE #{Sql.quote_table(table)} OWNER TO #{Sql.quote_ident(source_owner)};")]
        end
      end

      def grant_entries(table, src, tgt)
        target = tgt.grants(table).to_h { |g| [g.grantee, g.privileges] }

        src.grants(table).map do |g|
          have = target[g.grantee] || []
          if (g.privileges - have).empty?
            entry("grant", g.grantee, :present, g.privileges.join(", "), nil)
          else
            grantee_sql = g.grantee == "PUBLIC" ? "PUBLIC" : Sql.quote_ident(g.grantee)
            entry("grant", g.grantee, :missing, g.privileges.join(", "),
                  "GRANT #{g.privileges.join(', ')} ON #{Sql.quote_table(table)} TO #{grantee_sql};")
          end
        end
      end

      # Comments are rename-safe: only the column identifier changes, so a
      # renamed column's comment is re-emitted against its target name; dropped
      # columns are skipped.
      def comment_entries(table, src, tgt, drops, renames)
        entries = []

        source_table_comment = src.table_comment(table)
        if source_table_comment
          status = source_table_comment == tgt.table_comment(table) ? :present : :missing
          ddl    = status == :missing ? "COMMENT ON TABLE #{Sql.quote_table(table)} IS #{quote_literal(source_table_comment)};" : nil
          entries << entry("comment", "(table)", status, truncate(source_table_comment), ddl)
        end

        target_comments = tgt.column_comments(table)
        src.column_comments(table).each do |col, comment|
          next if drops.include?(col)

          target_col = renames[col] || col
          if target_comments[target_col] == comment
            entries << entry("comment", target_col, :present, truncate(comment), nil)
          else
            entries << entry("comment", target_col, :missing, truncate(comment),
                             "COMMENT ON COLUMN #{Sql.quote_table(table)}.#{Sql.quote_ident(target_col)} " \
                             "IS #{quote_literal(comment)};")
          end
        end

        entries
      end

      def quote_literal(str)
        "'#{str.gsub("'", "''")}'"
      end

      def truncate(str)
        str.length > 40 ? "#{str[0, 37]}..." : str
      end

      # Injects CONCURRENTLY so the index build does not lock out writes.
      def concurrently(definition)
        definition.sub(/\ACREATE (UNIQUE )?INDEX /, 'CREATE \1INDEX CONCURRENTLY ')
      end

      def review_reason(columns, drops, renames)
        dropped = columns & drops
        return "references dropped column(s): #{dropped.join(', ')} — not recreated" if dropped.any?

        renamed = columns & renames.keys
        if renamed.any?
          pairs = renamed.map { |c| "#{c}->#{renames[c]}" }.join(", ")
          return "references renamed column(s): #{pairs} — regenerate manually"
        end

        nil
      end

      def change_maps(table_config)
        cols    = table_config.columns || {}
        drops   = cols.select { |_, spec| spec.drop }.keys.map(&:to_s)
        renames = cols.each_with_object({}) do |(src, spec), h|
          h[src.to_s] = spec.rename if spec.rename
        end
        [drops, renames]
      end

      def entry(category, name, status, detail, ddl)
        Entry.new(category: category, name: name, status: status, detail: detail, ddl: ddl)
      end
    end
  end
end

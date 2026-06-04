# frozen_string_literal: true

require "set"

module Pcrd
  module Schema
    # Computes the diff between source and target schemas, optionally guided
    # by a migration spec (Config::Table).
    #
    # Two modes:
    #
    #   Synthesis mode (target_columns: nil)
    #     The target schema is synthesized by applying the migration spec to the
    #     source columns. Use this to preview what the target will look like before
    #     the migration has run.
    #
    #   Real-target mode (target_columns: [...])
    #     The target schema comes from a live database query. The spec is used
    #     to understand source→target column name mappings; without a spec,
    #     columns are matched by name.
    class Differ
      # Returns Array<DiffEntry> in source-column order, added columns last.
      #
      # source_columns: Array<Schema::Column>
      # table_config:   Config::Table or nil
      # target_columns: Array<Schema::Column> or nil (triggers synthesis)
      def diff(source_columns:, table_config: nil, target_columns: nil)
        if target_columns.nil?
          synthesize_diff(source_columns, table_config)
        else
          real_diff(source_columns, table_config, target_columns)
        end
      end

      # Extracts target-side columns from a diff for use in padding analysis.
      def target_columns_from_diff(entries)
        entries
          .reject(&:dropped?)
          .map(&:target_column)
          .compact
      end

      private

      # -----------------------------------------------------------------------
      # Synthesis path: build target columns from source + spec
      # -----------------------------------------------------------------------

      def synthesize_diff(source_columns, table_config)
        spec_columns = table_config&.columns || {}
        entries      = []

        source_columns.each do |src|
          col_spec = spec_columns[src.name]

          if col_spec&.drop
            entries << DiffEntry.new(status: :dropped, source_column: src, target_column: nil)
          else
            target = synthesize_column(src, col_spec)
            status = compute_status(src, target, col_spec)
            entries << DiffEntry.new(status: status, source_column: src, target_column: target)
          end
        end

        # Added columns come last.
        (table_config&.add_columns || []).each do |add_col|
          target = build_added_column(add_col)
          entries << DiffEntry.new(status: :added, source_column: nil, target_column: target)
        end

        entries
      end

      def synthesize_column(source_col, col_spec)
        new_name = col_spec&.rename || source_col.name
        new_type = col_spec&.type

        if new_type
          info = TypeRegistry.lookup(new_type)
          Column.new(
            attnum:         source_col.attnum,
            name:           new_name,
            type_name:      info.canonical_name,
            formatted_type: new_type,
            alignment:      info.alignment,
            fixed_size:     info.fixed_size,
            nullable:       source_col.nullable,
            default_expr:   source_col.default_expr
          )
        else
          Column.new(
            attnum:         source_col.attnum,
            name:           new_name,
            type_name:      source_col.type_name,
            formatted_type: source_col.formatted_type,
            alignment:      source_col.alignment,
            fixed_size:     source_col.fixed_size,
            nullable:       source_col.nullable,
            default_expr:   source_col.default_expr
          )
        end
      end

      def build_added_column(add_col)
        info = TypeRegistry.lookup(add_col.type)
        Column.new(
          attnum:         nil,
          name:           add_col.name,
          type_name:      info.canonical_name,
          formatted_type: add_col.type,
          alignment:      info.alignment,
          fixed_size:     info.fixed_size,
          nullable:       true,
          default_expr:   add_col.default
        )
      end

      def compute_status(src, target, col_spec)
        type_changed   = src.type_name != target.type_name ||
                         src.formatted_type.downcase != target.formatted_type.downcase
        name_changed   = src.name != target.name

        if type_changed && name_changed
          :type_and_renamed
        elsif type_changed
          :type_changed
        elsif name_changed
          :renamed
        else
          :unchanged
        end
      end

      # -----------------------------------------------------------------------
      # Real-target path: match live source and target columns
      # -----------------------------------------------------------------------

      def real_diff(source_columns, table_config, target_columns)
        spec_columns  = table_config&.columns || {}
        target_by_name = target_columns.each_with_object({}) { |c, h| h[c.name] = c }
        entries = []
        matched_targets = Set.new

        source_columns.each do |src|
          col_spec    = spec_columns[src.name]
          target_name = col_spec&.rename || src.name

          if col_spec&.drop
            entries << DiffEntry.new(status: :dropped, source_column: src, target_column: nil)
            next
          end

          tgt = target_by_name[target_name]
          if tgt
            matched_targets << tgt.name
            status = compute_status(src, tgt, col_spec)
            entries << DiffEntry.new(status: status, source_column: src, target_column: tgt)
          else
            # Column expected on target but not found — treat as dropped.
            entries << DiffEntry.new(status: :dropped, source_column: src, target_column: nil)
          end
        end

        # Columns present on target but not matched from source are additions.
        target_columns.each do |tgt|
          next if matched_targets.include?(tgt.name)

          entries << DiffEntry.new(status: :added, source_column: nil, target_column: tgt)
        end

        entries
      end
    end
  end
end

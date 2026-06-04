# frozen_string_literal: true

require "set"

module Pcrd
  module Transform
    # Applies a Config::Table migration spec to a single row hash.
    #
    # Handles the structural changes: drops (exclude column), renames (change key),
    # and pass-through for unchanged columns. Does NOT perform Ruby-level type
    # conversion — PostgreSQL coerces values on INSERT/COPY, so string values from
    # the source pass through as-is.
    #
    # Added columns (from add_columns) are NOT included in the transformer output.
    # They are omitted from the INSERT column list so the target database applies
    # their DEFAULT expressions directly.
    #
    # Usage:
    #   transformer = RowTransformer.new(table_config, source_columns)
    #   target_row  = transformer.transform(source_row_hash)
    #   columns     = transformer.target_column_names
    class RowTransformer
      def initialize(table_config, source_columns)
        @source_names = source_columns.map(&:name)
        @drops        = build_drop_set(table_config)
        @renames      = build_rename_map(table_config)
        @target_names = build_target_names
      end

      # Returns a hash of {target_column_name => value} for all non-dropped columns.
      # Values are whatever the pg gem returned (typically String or nil).
      def transform(row_hash)
        @target_names.each_with_object({}).with_index do |(tgt_name, result), i|
          result[tgt_name] = row_hash[@source_names_kept[i]]
        end
      end

      # Ordered list of target column names produced by #transform.
      # Pass this to the backfill engine when constructing INSERT/COPY statements.
      def target_column_names
        @target_names
      end

      # Ordered list of source column names that survive (not dropped).
      def source_column_names_kept
        @source_names_kept
      end

      private

      def build_drop_set(config)
        (config.columns || {}).each_with_object(Set.new) do |(name, spec), set|
          set << name.to_s if spec.drop
        end
      end

      def build_rename_map(config)
        (config.columns || {}).each_with_object({}) do |(name, spec), map|
          map[name.to_s] = spec.rename if spec.rename
        end
      end

      def build_target_names
        @source_names_kept = @source_names.reject { |n| @drops.include?(n) }
        @source_names_kept.map { |n| @renames[n] || n }
      end
    end
  end
end

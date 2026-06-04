# frozen_string_literal: true

module Pcrd
  module Schema
    # Creates target tables from the migration spec.
    # Called at the start of `pcrd migrate` (after preflight passes).
    #
    # In the full streaming flow (Phase 9+), Setup also creates the publication
    # and replication slot on source. For --backfill-only those are skipped.
    class Setup
      def initialize(source_pool:, target_pool:, config:)
        @source_pool = source_pool
        @target_pool = target_pool
        @config      = config
      end

      # Creates all target tables and returns a Hash<table_name, ddl_string>.
      # Raises if a target table already exists (use --force-overwrite to drop first).
      def create_target_tables(force_overwrite: false)
        reader = Reader.new(@source_pool)
        ddls   = {}

        @config.migrate.tables.each do |table_config|
          name        = table_config.name
          source_cols = reader.read(name)
          pk_cols     = reader.primary_key_columns(name)

          ddl = DDL.generate(
            source_columns:      source_cols,
            table_config:        table_config,
            primary_key_columns: pk_cols
          )

          target_reader = Reader.new(@target_pool)
          if target_reader.table_exists?(name)
            if force_overwrite
              @target_pool.exec_sql("DROP TABLE IF EXISTS public.#{name} CASCADE")
            else
              raise "Table '#{name}' already exists on target. " \
                    "Pass --force-overwrite to drop and recreate."
            end
          end

          @target_pool.exec_sql("#{ddl};")
          ddls[name] = ddl
        end

        ddls
      end
    end
  end
end

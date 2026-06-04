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

      # Creates the publication and replication slot on the source.
      # Returns the slot's starting LSN as a "X/Y" string — pass this to the
      # consumer so streaming begins from a point that covers all of backfill.
      def create_publication_and_slot(pub_name:, slot_name:)
        table_list = @config.migrate.tables.map { |t|
          "#{@source_pool.quote_ident("public")}.#{@source_pool.quote_ident(t.name)}"
        }.join(", ")

        @source_pool.exec_sql(
          "CREATE PUBLICATION #{@source_pool.quote_ident(pub_name)} FOR TABLE #{table_list}"
        )

        result = @source_pool.exec(
          "SELECT lsn FROM pg_create_logical_replication_slot($1, 'pgoutput')",
          [slot_name]
        )
        result[0]["lsn"]
      end

      # Drops the publication and replication slot (cleanup phase).
      def drop_publication_and_slot(pub_name:, slot_name:)
        @source_pool.exec_sql(
          "DROP PUBLICATION IF EXISTS #{@source_pool.quote_ident(pub_name)}"
        )
        @source_pool.exec(
          "SELECT pg_drop_replication_slot($1) WHERE EXISTS (" \
          "  SELECT 1 FROM pg_replication_slots WHERE slot_name = $1)",
          [slot_name]
        )
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

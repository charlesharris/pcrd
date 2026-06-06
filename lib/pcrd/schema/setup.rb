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
      # Idempotently ensures the publication and replication slot exist for a
      # fresh migration, returning the slot's starting LSN ("X/Y").
      #
      # A leftover publication from a partial prior run is reused if it covers
      # exactly the configured tables (it is just a definition). A leftover
      # slot is NOT reused: its WAL position is unknown relative to backfill, so
      # we refuse and point the operator at --resume or `pcrd cleanup`.
      def create_publication_and_slot(pub_name:, slot_name:)
        ensure_publication(pub_name)

        if slot_exists?(slot_name)
          raise SetupError, "Replication slot '#{slot_name}' already exists. Resume the existing " \
                            "migration with --resume, or remove it with `pcrd cleanup` to start over."
        end

        result = @source_pool.exec(
          "SELECT lsn FROM pg_create_logical_replication_slot($1, 'pgoutput')",
          [slot_name]
        )
        result[0]["lsn"]
      end

      # Validates that a --resume run has the slot and publication it needs.
      # Raises with a clear message if either is missing.
      def validate_resumable!(pub_name:, slot_name:)
        unless slot_exists?(slot_name)
          raise SetupError, "Cannot resume: replication slot '#{slot_name}' does not exist on the source. " \
                            "Start a fresh migration (without --resume)."
        end

        unless publication_exists?(pub_name)
          raise SetupError, "Cannot resume: publication '#{pub_name}' does not exist on the source. " \
                            "Start a fresh migration (without --resume)."
        end
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
              @target_pool.exec_sql("DROP TABLE IF EXISTS #{Sql.quote_table(name)} CASCADE")
            else
              raise SetupError, "Table '#{name}' already exists on target. " \
                                "Pass --force-overwrite to drop and recreate."
            end
          end

          @target_pool.exec_sql("#{ddl};")
          ddls[name] = ddl
        end

        ddls
      end

      private

      # Creates the publication if absent; reuses it if it already covers exactly
      # the configured tables; raises if it exists but covers a different set.
      def ensure_publication(pub_name)
        configured = @config.migrate.tables.map(&:name).sort

        if publication_exists?(pub_name)
          existing = publication_tables(pub_name).sort
          return if existing == configured

          raise SetupError, "Publication '#{pub_name}' already exists but covers #{existing.inspect}, " \
                            "not the configured tables #{configured.inspect}. " \
                            "Drop it with `pcrd cleanup` or reconcile the config."
        end

        table_list = @config.migrate.tables.map { |t| Sql.quote_table(t.name) }.join(", ")
        @source_pool.exec_sql(
          "CREATE PUBLICATION #{@source_pool.quote_ident(pub_name)} FOR TABLE #{table_list}"
        )
      end

      def publication_exists?(pub_name)
        @source_pool.exec(
          "SELECT 1 FROM pg_publication WHERE pubname = $1", [pub_name]
        ).ntuples.positive?
      end

      def publication_tables(pub_name)
        @source_pool.exec(
          "SELECT tablename FROM pg_publication_tables WHERE pubname = $1", [pub_name]
        ).column_values(0)
      end

      def slot_exists?(slot_name)
        @source_pool.exec(
          "SELECT 1 FROM pg_replication_slots WHERE slot_name = $1", [slot_name]
        ).ntuples.positive?
      end
    end
  end
end

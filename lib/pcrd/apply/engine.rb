# frozen_string_literal: true

module Pcrd
  module Apply
    # Applies transactions from the WAL consumer queue to the target cluster.
    #
    # Each transaction is a Replication::Consumer::Transaction containing a list
    # of Insert/Update/Delete events. Events for tables not in the migration spec
    # are silently skipped (other tables may be in the publication).
    #
    # INSERT events use ON CONFLICT DO UPDATE so they are safe during the
    # backfill/streaming overlap window — if backfill already wrote a row,
    # the WAL replay will update it to the latest version instead of failing.
    #
    # UPDATE events are implemented as upserts (same SQL as INSERT) because:
    #   - The row may not yet exist on the target (if the WAL event precedes
    #     the backfill batch that covers that key range).
    #   - Upsert semantics are always correct here.
    #
    # DELETE events use the primary-key values from old_tuple (key columns).
    class Engine
      # Per-table execution plan built at initialisation time.
      TablePlan = Data.define(
        :table_name,
        :transformer,
        :pk_source_cols,   # Array<String>: pk column names in source schema
        :pk_target_cols,   # Array<String>: pk column names after renames
        :upsert_sql,       # prebuilt SQL string
        :delete_sql        # prebuilt SQL string
      )

      def initialize(target_pool:, config:, parser:, source_schema:)
        @target_pool   = target_pool
        @parser        = parser
        @plans         = build_plans(config, source_schema)
      end

      # Applies one complete transaction to the target inside a single DB transaction.
      # Returns the commit LSN string.
      def apply(txn)
        @target_pool.transaction do
          txn.events.each { |event| apply_event(event) }
        end
        txn.commit_lsn
      end

      private

      def apply_event(event)
        rel  = @parser.relation(event.relation_id)
        return unless rel

        plan = @plans[rel.name]
        return unless plan

        case event
        when Replication::Pgoutput::Messages::Insert
          apply_upsert(plan, event.new_tuple)
        when Replication::Pgoutput::Messages::Update
          apply_upsert(plan, event.new_tuple)
        when Replication::Pgoutput::Messages::Delete
          apply_delete(plan, event.old_tuple)
        end
      end

      def apply_upsert(plan, tuple)
        transformed = plan.transformer.transform(tuple)
        @target_pool.exec(plan.upsert_sql, transformed.values)
      end

      def apply_delete(plan, tuple)
        pk_values = plan.pk_source_cols.map { tuple[_1] }
        @target_pool.exec(plan.delete_sql, pk_values)
      end

      # ── plan building ────────────────────────────────────────────────────

      def build_plans(config, source_schema)
        (config.migrate&.tables || []).each_with_object({}) do |table_config, plans|
          schema = source_schema[table_config.name]
          next unless schema

          source_cols = schema[:columns]
          pk_source   = schema[:pk_columns]
          transformer = Transform::RowTransformer.new(table_config, source_cols)
          pk_target   = map_pk_to_target(pk_source, table_config)
          target_cols = transformer.target_column_names

          plans[table_config.name] = TablePlan.new(
            table_name:     table_config.name,
            transformer:    transformer,
            pk_source_cols: pk_source,
            pk_target_cols: pk_target,
            upsert_sql:     build_upsert_sql(table_config.name, target_cols, pk_target),
            delete_sql:     build_delete_sql(table_config.name, pk_target)
          )
        end
      end

      def map_pk_to_target(pk_source_cols, table_config)
        pk_source_cols.map do |src|
          spec = table_config.columns&.[](src) || table_config.columns&.[](src.to_sym)
          spec&.rename || src
        end
      end

      def build_upsert_sql(table_name, target_cols, pk_target_cols)
        tbl  = Sql.quote_table(table_name)
        cols = Sql.quote_columns(target_cols)
        phs  = target_cols.each_index.map { "$#{_1 + 1}" }.join(", ")
        pk   = Sql.quote_columns(pk_target_cols)

        set_pairs = target_cols
          .reject { |c| pk_target_cols.include?(c) }
          .map    { |c| "#{Sql.quote_ident(c)} = EXCLUDED.#{Sql.quote_ident(c)}" }
          .join(", ")

        if set_pairs.empty?
          "INSERT INTO #{tbl} (#{cols}) VALUES (#{phs}) ON CONFLICT (#{pk}) DO NOTHING"
        else
          "INSERT INTO #{tbl} (#{cols}) VALUES (#{phs}) ON CONFLICT (#{pk}) DO UPDATE SET #{set_pairs}"
        end
      end

      def build_delete_sql(table_name, pk_target_cols)
        tbl  = Sql.quote_table(table_name)
        cond = pk_target_cols.each_with_index
                             .map { |c, i| "#{Sql.quote_ident(c)} = $#{i + 1}" }
                             .join(" AND ")
        "DELETE FROM #{tbl} WHERE #{cond}"
      end
    end
  end
end

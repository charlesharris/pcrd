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

        # Route by schema-qualified relation name. Keying on the bare table name
        # would mis-route events when two schemas hold a same-named table that
        # the publication happens to include.
        plan = @plans[relation_key(rel.namespace, rel.name)]
        return unless plan

        case event
        when Replication::Pgoutput::Messages::Insert
          # INSERT always carries every column ('t'/'n', never 'u'), so the
          # full-row upsert is always safe here.
          apply_upsert(plan, event.new_tuple)
        when Replication::Pgoutput::Messages::Update
          apply_update(plan, event.new_tuple)
        when Replication::Pgoutput::Messages::Delete
          apply_delete(plan, event.old_tuple)
        end
      end

      def apply_upsert(plan, tuple)
        transformed = plan.transformer.transform(tuple)
        @target_pool.exec(plan.upsert_sql, transformed.values)
      end

      # An UPDATE's new tuple may contain :toast sentinels for TOASTed columns
      # whose value did not change — PostgreSQL does not re-send those values.
      # Writing the sentinel through the upsert would corrupt the column with a
      # literal "toast". When no column is unchanged-TOAST, the full-row upsert
      # is correct and idempotent; otherwise we emit a partial UPDATE that sets
      # only the changed columns, leaving the existing target value in place.
      def apply_update(plan, tuple)
        transformed = plan.transformer.transform(tuple)
        if transformed.value?(:toast)
          apply_partial_update(plan, transformed)
        else
          @target_pool.exec(plan.upsert_sql, transformed.values)
        end
      end

      # Builds an UPDATE that excludes unchanged-TOAST columns (and the PK) from
      # the SET list, keyed by primary key. If the row has not been backfilled
      # yet this updates zero rows, which is fine: backfill reads live rows and
      # will copy the current value later, and replayed upserts are idempotent,
      # so the target still converges.
      def apply_partial_update(plan, transformed)
        set_cols = transformed.reject do |col, val|
          val == :toast || plan.pk_target_cols.include?(col)
        end
        return if set_cols.empty? # only PK and unchanged-TOAST columns present

        assignments = set_cols.keys.each_with_index
                              .map { |c, i| "#{Sql.quote_ident(c)} = $#{i + 1}" }
                              .join(", ")
        where = plan.pk_target_cols.each_with_index
                    .map { |c, i| "#{Sql.quote_ident(c)} = $#{set_cols.size + i + 1}" }
                    .join(" AND ")
        sql      = "UPDATE #{Sql.quote_table(plan.table_name)} SET #{assignments} WHERE #{where}"
        pk_vals  = plan.pk_target_cols.map { |c| transformed[c] }
        @target_pool.exec(sql, set_cols.values + pk_vals)
      end

      def apply_delete(plan, tuple)
        pk_values = plan.pk_source_cols.map { tuple[_1] }
        @target_pool.exec(plan.delete_sql, pk_values)
      end

      # ── plan building ────────────────────────────────────────────────────

      # Tables configured today are all in the public schema (there is no
      # per-table schema field yet). When that lands, key off table_config.schema.
      DEFAULT_SCHEMA = "public"

      def relation_key(namespace, name)
        "#{namespace}.#{name}"
      end

      def build_plans(config, source_schema)
        (config.migrate&.tables || []).each_with_object({}) do |table_config, plans|
          schema = source_schema[table_config.name]
          next unless schema

          source_cols = schema[:columns]
          pk_source   = schema[:pk_columns]
          transformer = Transform::RowTransformer.new(table_config, source_cols)
          pk_target   = map_pk_to_target(pk_source, table_config)
          target_cols = transformer.target_column_names

          plans[relation_key(DEFAULT_SCHEMA, table_config.name)] = TablePlan.new(
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

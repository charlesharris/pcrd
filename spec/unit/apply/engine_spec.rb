# frozen_string_literal: true

require "pcrd"

RSpec.describe Pcrd::Apply::Engine do
  M   = Pcrd::Replication::Pgoutput::Messages
  Txn = Pcrd::Replication::Consumer::Transaction

  def col(name, type_name: "int4", formatted_type: "integer",
          alignment: 4, fixed_size: 4, nullable: true, default_expr: nil)
    Pcrd::Schema::Column.new(
      attnum: 1, name: name, type_name: type_name,
      formatted_type: formatted_type, alignment: alignment,
      fixed_size: fixed_size, nullable: nullable, default_expr: default_expr
    )
  end

  def col_spec(type: nil, rename: nil, drop: false)
    Pcrd::Config::ColumnSpec.new(type: type, rename: rename, drop: drop)
  end

  def table_config(name:, columns: {}, add_columns: [])
    Pcrd::Config::Table.new(
      name: name, optimize_column_order: false,
      columns: columns, add_columns: add_columns
    )
  end

  def migrate_config(tables:)
    Pcrd::Config::MigrateConfig.new(
      replication_slot: "s", publication: "p", checkpoint_db: "c.sqlite3",
      batch_size: 1000, lag_threshold_bytes: 1_048_576, tables: tables
    )
  end

  def full_config(tables:)
    src = Pcrd::Config::Connection.new(host: "h", port: 5432, database: "d", user: "u", password: nil)
    Pcrd::Config::Root.new(
      source: src, target: src, migrate: migrate_config(tables: tables),
      analyze: nil, verify: nil, cutover: nil, path: "test"
    )
  end

  def relation(id:, name:, columns:)
    rel_cols = columns.map.with_index do |(col_name, type_oid), i|
      M::RelationColumn.new(flags: i.zero? ? 1 : 0, name: col_name, type_id: type_oid, type_modifier: -1)
    end
    M::Relation.new(id: id, namespace: "public", name: name, replica_identity: "d", columns: rel_cols)
  end

  def make_parser(relations)
    parser = Pcrd::Replication::Pgoutput::Parser.new
    relations.each do |rel|
      parser.instance_variable_get(:@relations)[rel.id] = rel
    end
    parser
  end

  def make_engine(table_configs:, source_cols:, pk_cols:)
    config = full_config(tables: table_configs)
    source_schema = table_configs.each_with_object({}) do |tc, h|
      h[tc.name] = {
        columns: source_cols[tc.name] || [],
        pk_columns: pk_cols[tc.name] || ["id"]
      }
    end
    parser = make_parser(
      table_configs.map.with_index do |tc, i|
        all_cols = (source_cols[tc.name] || []).map { |c| [c.name, 23] }
        relation(id: i + 1, name: tc.name, columns: all_cols)
      end
    )
    [described_class.new(target_pool: pool_double, config: config,
                         parser: parser, source_schema: source_schema),
     parser]
  end

  # Returns a double that records SQL calls
  def pool_double
    pool = instance_double("Pcrd::Connection::Pool")
    @sql_calls = []
    allow(pool).to receive(:exec) do |sql, params|
      @sql_calls << { sql: sql, params: params }
      double("PG::Result", ntuples: 1)
    end
    allow(pool).to receive(:transaction) { |&b| b.call }
    pool
  end

  let(:source_columns) do
    {
      "items" => [
        col("id",    nullable: false),
        col("score", type_name: "int4", formatted_type: "integer"),
        col("label", type_name: "text", formatted_type: "text", alignment: 4, fixed_size: nil)
      ]
    }
  end

  describe "INSERT event" do
    it "generates an INSERT ON CONFLICT upsert" do
      tc = table_config(name: "items")
      engine, parser = make_engine(
        table_configs: [tc],
        source_cols:   source_columns,
        pk_cols:       { "items" => ["id"] }
      )

      rel = parser.relation(1)
      txn = Txn.new(
        begin_msg: nil,
        events: [M::Insert.new(relation_id: 1, new_tuple: { "id" => "7", "score" => "42", "label" => "hi" })],
        commit_lsn: "0/100"
      )

      engine.apply(txn)

      call = @sql_calls.first
      expect(call[:sql]).to match(/INSERT INTO/)
      expect(call[:sql]).to match(/ON CONFLICT.*DO UPDATE SET/)
      expect(call[:params]).to eq ["7", "42", "hi"]
    end

    it "excludes pk columns from the ON CONFLICT SET clause" do
      tc = table_config(name: "items")
      engine, _ = make_engine(
        table_configs: [tc],
        source_cols:   source_columns,
        pk_cols:       { "items" => ["id"] }
      )

      txn = Txn.new(
        begin_msg: nil,
        events: [M::Insert.new(relation_id: 1, new_tuple: { "id" => "1", "score" => "5", "label" => "x" })],
        commit_lsn: "0/200"
      )
      engine.apply(txn)

      set_clause = @sql_calls.first[:sql][/DO UPDATE SET (.+)/, 1]
      expect(set_clause).not_to include('"id"')
      expect(set_clause).to include('"score"')
    end
  end

  describe "with column rename in spec" do
    it "uses the renamed column name in the INSERT" do
      tc = table_config(
        name: "items",
        columns: { "label" => col_spec(rename: "description") }
      )
      engine, _ = make_engine(
        table_configs: [tc],
        source_cols:   source_columns,
        pk_cols:       { "items" => ["id"] }
      )

      txn = Txn.new(
        begin_msg: nil,
        events: [M::Insert.new(relation_id: 1, new_tuple: { "id" => "1", "score" => "5", "label" => "renamed" })],
        commit_lsn: "0/300"
      )
      engine.apply(txn)

      sql = @sql_calls.first[:sql]
      expect(sql).to include('"description"')
      expect(sql).not_to match(/"label"/)
    end
  end

  describe "DELETE event" do
    it "generates a DELETE WHERE pk = $1" do
      tc = table_config(name: "items")
      engine, _ = make_engine(
        table_configs: [tc],
        source_cols:   source_columns,
        pk_cols:       { "items" => ["id"] }
      )

      txn = Txn.new(
        begin_msg: nil,
        events: [M::Delete.new(relation_id: 1, old_tuple: { "id" => "99" })],
        commit_lsn: "0/400"
      )
      engine.apply(txn)

      call = @sql_calls.first
      expect(call[:sql]).to match(/DELETE FROM/)
      expect(call[:sql]).to match(/WHERE.*"id" = \$1/)
      expect(call[:params]).to eq ["99"]
    end
  end

  describe "unknown relation" do
    it "skips events for tables not in the parser cache" do
      tc = table_config(name: "items")
      engine, _ = make_engine(
        table_configs: [tc],
        source_cols:   source_columns,
        pk_cols:       { "items" => ["id"] }
      )

      txn = Txn.new(
        begin_msg: nil,
        events: [M::Insert.new(relation_id: 999, new_tuple: { "id" => "1" })],
        commit_lsn: "0/500"
      )
      engine.apply(txn)
      expect(@sql_calls).to be_empty
    end
  end

  describe "mixed transaction" do
    it "applies multiple events in the same DB transaction" do
      tc = table_config(name: "items")
      engine, _ = make_engine(
        table_configs: [tc],
        source_cols:   source_columns,
        pk_cols:       { "items" => ["id"] }
      )

      events = [
        M::Insert.new(relation_id: 1, new_tuple: { "id" => "1", "score" => "10", "label" => "a" }),
        M::Insert.new(relation_id: 1, new_tuple: { "id" => "2", "score" => "20", "label" => "b" }),
        M::Delete.new(relation_id: 1, old_tuple: { "id" => "3" })
      ]
      txn = Txn.new(begin_msg: nil, events: events, commit_lsn: "0/600")
      engine.apply(txn)

      expect(@sql_calls.length).to eq 3
      expect(@sql_calls.map { _1[:sql] }).to include(a_string_matching(/INSERT/), a_string_matching(/DELETE/))
    end
  end
end

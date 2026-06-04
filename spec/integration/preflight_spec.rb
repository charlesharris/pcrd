# frozen_string_literal: true

require "pcrd"
require_relative "../support/pg_helpers"

RSpec.describe Pcrd::Preflight, :integration do
  def make_config(source: test_source_config, target: nil, tables: [])
    migrate_cfg = tables.any? ? Pcrd::Config::MigrateConfig.new(
      replication_slot:    "pcrd_test_slot",
      publication:         "pcrd_test_pub",
      checkpoint_db:       "./pcrd_test_checkpoint.sqlite3",
      batch_size:          10_000,
      lag_threshold_bytes: 1_048_576,
      tables:              tables
    ) : nil

    Pcrd::Config::Root.new(
      source:  source,
      target:  target,
      migrate: migrate_cfg,
      analyze: nil,
      verify:  nil,
      cutover: nil,
      path:    "test"
    )
  end

  def table_config(name:, columns: {}, add_columns: [])
    Pcrd::Config::Table.new(
      name: name, optimize_column_order: false,
      columns: columns, add_columns: add_columns
    )
  end

  def col_spec(type: nil, rename: nil, drop: false)
    Pcrd::Config::ColumnSpec.new(type: type, rename: rename, drop: drop)
  end

  PREFLIGHT_TABLE_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_preflight_test (
      id      integer NOT NULL,
      name    text,
      score   bigint,
      PRIMARY KEY (id)
    )
  SQL

  around do |example|
    with_table(source_pool, PREFLIGHT_TABLE_DDL, table_name: "pcrd_preflight_test") do
      example.run
    end
  end

  describe "#run" do
    context "with valid source connection and no migrate config" do
      it "passes connection and wal_level checks" do
        config = make_config
        result = described_class.new(config).run
        labels = result.items.map(&:label)
        expect(labels).to include("source connection")
        expect(result.items.find { |i| i.label == "source connection" }.status).to eq :pass
      end

      it "passes wal_level check (dev containers have logical WAL)" do
        config = make_config
        result = described_class.new(config).run
        wal_item = result.items.find { |i| i.label == "wal_level" }
        expect(wal_item).not_to be_nil
        expect(wal_item.status).to eq :pass
      end
    end

    context "with unreachable source" do
      let(:bad_source) do
        Pcrd::Config::Connection.new(
          host: "127.0.0.1", port: 19999,
          database: "no", user: "no", password: nil
        )
      end

      it "fails the source connection check" do
        config = make_config(source: bad_source)
        result = described_class.new(config).run
        conn_item = result.items.find { |i| i.label == "source connection" }
        expect(conn_item.status).to eq :fail
        expect(result.passed).to be false
      end
    end

    context "with a valid table and always-safe type change" do
      let(:tables) { [table_config(name: "pcrd_preflight_test", columns: { "id" => col_spec(type: "bigint") })] }

      it "passes all table checks" do
        config = make_config(tables: tables)
        result = described_class.new(config).run
        fail_items = result.items.select { |i| i.status == :fail }
        expect(fail_items).to be_empty
        expect(result.passed).to be true
      end

      it "includes a primary key check" do
        config = make_config(tables: tables)
        result = described_class.new(config).run
        pk_item = result.items.find { |i| i.label.include?("primary key") }
        expect(pk_item).not_to be_nil
        expect(pk_item.status).to eq :pass
        expect(pk_item.detail).to include("id")
      end

      it "generates DDL for the table" do
        config = make_config(tables: tables)
        result = described_class.new(config).run
        expect(result.ddl_map["pcrd_preflight_test"]).to include("CREATE TABLE")
        expect(result.ddl_map["pcrd_preflight_test"]).to include("bigint")
      end
    end

    context "when a spec column does not exist on source" do
      let(:tables) do
        [table_config(name: "pcrd_preflight_test",
                      columns: { "nonexistent_column" => col_spec(type: "bigint") })]
      end

      it "fails with a clear error about the missing column" do
        config = make_config(tables: tables)
        result = described_class.new(config).run
        spec_item = result.items.find { |i| i.label.include?("column spec") }
        expect(spec_item.status).to eq :fail
        expect(spec_item.detail).to include("nonexistent_column")
      end
    end

    context "when a validated cast would fail" do
      before do
        # Insert a value that overflows integer range
        source_pool.exec(
          "INSERT INTO pcrd_preflight_test (id, name, score) VALUES ($1, $2, $3)",
          [1, "test", 3_000_000_000]
        )
      end

      it "fails data validation for score bigint → integer" do
        tables = [table_config(name: "pcrd_preflight_test",
                               columns: { "score" => col_spec(type: "integer") })]
        config = make_config(tables: tables)
        result = described_class.new(config).run
        val_item = result.items.find { |i| i.label.include?("data validation") }
        expect(val_item&.status).to eq :fail
        expect(val_item.detail).to include("1 row(s) would fail")
      end
    end

    context "result structure" do
      it "includes row_counts for tables" do
        tables = [table_config(name: "pcrd_preflight_test")]
        config = make_config(tables: tables)
        result = described_class.new(config).run
        expect(result.row_counts).to have_key("pcrd_preflight_test")
      end
    end
  end
end

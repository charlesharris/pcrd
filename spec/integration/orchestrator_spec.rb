# frozen_string_literal: true

require "pcrd"
require "tmpdir"
require_relative "../support/pg_helpers"

RSpec.describe Pcrd::Migration::Orchestrator, :integration do
  include PgHelpers

  ORCH_SOURCE_DDL = "CREATE TABLE pcrd_orch_test (id integer PRIMARY KEY, label text)"

  def target_conn
    Pcrd::Config::Connection.new(
      host:     ENV.fetch("PCRD_TEST_TARGET_HOST",     "localhost"),
      port:     ENV.fetch("PCRD_TEST_TARGET_PORT",     "5434").to_i,
      database: ENV.fetch("PCRD_TEST_TARGET_DB",       "pcrd_target"),
      user:     ENV.fetch("PCRD_TEST_TARGET_USER",     "postgres"),
      password: ENV.fetch("PCRD_TEST_TARGET_PASSWORD", "postgres")
    )
  end

  let(:target_pool)     { Pcrd::Connection::Pool.new(target_conn) }
  let(:checkpoint_path) { File.join(Dir.mktmpdir, "orch.sqlite3") }

  let(:config) do
    table = Pcrd::Config::Table.new(
      name: "pcrd_orch_test", optimize_column_order: false,
      columns: { "id" => Pcrd::Config::ColumnSpec.new(type: "bigint", rename: nil, drop: false) },
      add_columns: []
    )
    migrate = Pcrd::Config::MigrateConfig.new(
      replication_slot: "pcrd_orch_slot", publication: "pcrd_orch_pub",
      checkpoint_db: checkpoint_path, batch_size: 100, lag_threshold_bytes: 1, tables: [table]
    )
    Pcrd::Config::Root.new(
      source: test_source_config, target: target_conn, migrate: migrate,
      analyze: nil, verify: nil, cutover: nil, path: "test"
    )
  end

  around do |example|
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_orch_test CASCADE")
    with_table(source_pool, ORCH_SOURCE_DDL, table_name: "pcrd_orch_test") { example.run }
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_orch_test CASCADE")
    target_pool.close
  end

  it "runs the backfill-only path: creates the target table and copies rows" do
    source_pool.exec("INSERT INTO pcrd_orch_test VALUES (1, 'a'), (2, 'b'), (3, 'c')")

    orchestrator = described_class.new(
      config: config,
      options: { :"backfill-only" => true },
      reporter: Pcrd::Reporter::Null.new
    )

    outcome = orchestrator.run

    expect(outcome).to eq(:backfill_only)
    expect(target_pool.exec("SELECT COUNT(*) FROM pcrd_orch_test")[0]["count"].to_i).to eq(3)
    # target id was widened to bigint by the migration spec
    type = target_pool.exec(<<~SQL)[0]["data_type"]
      SELECT data_type FROM information_schema.columns
      WHERE table_name = 'pcrd_orch_test' AND column_name = 'id'
    SQL
    expect(type).to eq("bigint")
  end
end

# frozen_string_literal: true

require "pcrd"
require_relative "../support/pg_helpers"

# Verifies that Commands::Verify compares row *values*, not just existence:
# a row-count match with corrupted data must be reported as a mismatch.
RSpec.describe Pcrd::Commands::Verify, :integration do
  include PgHelpers

  SOURCE_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_verify_test (
      id    integer NOT NULL,
      label text,
      score integer,
      PRIMARY KEY (id)
    )
  SQL

  # Target widens id/score to bigint and renames label -> name.
  TARGET_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_verify_test (
      id    bigint NOT NULL,
      name  text,
      score bigint,
      PRIMARY KEY (id)
    )
  SQL

  def target_config
    Pcrd::Config::Connection.new(
      host:     ENV.fetch("PCRD_TEST_TARGET_HOST",     "localhost"),
      port:     ENV.fetch("PCRD_TEST_TARGET_PORT",     "5434").to_i,
      database: ENV.fetch("PCRD_TEST_TARGET_DB",       "pcrd_target"),
      user:     ENV.fetch("PCRD_TEST_TARGET_USER",     "postgres"),
      password: ENV.fetch("PCRD_TEST_TARGET_PASSWORD", "postgres")
    )
  end

  let(:target_pool) { Pcrd::Connection::Pool.new(target_config) }

  let(:table_config) do
    Pcrd::Config::Table.new(
      name: "pcrd_verify_test",
      optimize_column_order: false,
      columns: {
        "id"    => Pcrd::Config::ColumnSpec.new(type: "bigint", rename: nil,    drop: false),
        "label" => Pcrd::Config::ColumnSpec.new(type: nil,      rename: "name", drop: false),
        "score" => Pcrd::Config::ColumnSpec.new(type: "bigint", rename: nil,    drop: false)
      },
      add_columns: []
    )
  end

  let(:config) do
    migrate = Pcrd::Config::MigrateConfig.new(
      replication_slot: "x", publication: "x", checkpoint_db: ":memory:",
      batch_size: 100, lag_threshold_bytes: 1, tables: [table_config]
    )
    Pcrd::Config::Root.new(
      source: test_source_config, target: target_config, migrate: migrate,
      analyze: nil, verify: Pcrd::Config::VerifyConfig.new(sample_size: 1_000),
      cutover: nil, path: "test"
    )
  end

  around do |example|
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_verify_test CASCADE")
    target_pool.exec_sql(TARGET_DDL)
    with_table(source_pool, SOURCE_DDL, table_name: "pcrd_verify_test") do
      example.run
    end
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_verify_test CASCADE")
    target_pool.close
  end

  def seed_source
    source_pool.exec("INSERT INTO pcrd_verify_test VALUES (1, 'alpha', 10), (2, 'beta', 20), (3, 'gamma', 30)")
  end

  it "passes when transformed values match (including widening + rename)" do
    seed_source
    target_pool.exec("INSERT INTO pcrd_verify_test VALUES (1, 'alpha', 10), (2, 'beta', 20), (3, 'gamma', 30)")

    result = described_class.new(config).run

    expect(result.passed).to be(true)
    expect(result.tables.first.mismatches).to be_empty
  end

  it "reports a field-level mismatch when a target value is corrupted" do
    seed_source
    # Same row count, but row 2's renamed column holds the wrong value.
    target_pool.exec("INSERT INTO pcrd_verify_test VALUES (1, 'alpha', 10), (2, 'WRONG', 20), (3, 'gamma', 30)")

    result = described_class.new(config).run

    expect(result.passed).to be(false)
    mismatches = result.tables.first.mismatches
    expect(mismatches.size).to eq(1)
    expect(mismatches.first).to include("pk=id=2", "col=name", "source=beta", "target=WRONG")
  end
end

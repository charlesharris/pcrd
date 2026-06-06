# frozen_string_literal: true

require "pcrd"
require_relative "../support/pg_helpers"

RSpec.describe "cutover pipeline (integration)", :integration do
  include PgHelpers

  CUTOVER_SOURCE_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_cutover_test (
      id    integer NOT NULL GENERATED ALWAYS AS IDENTITY,
      label text,
      score integer,
      PRIMARY KEY (id)
    )
  SQL

  CUTOVER_TARGET_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_cutover_test (
      id    bigint NOT NULL,
      label text,
      score bigint,
      PRIMARY KEY (id)
    )
  SQL

  let(:target_pool) do
    Pcrd::Connection::Client.new(
      Pcrd::Config::Connection.new(
        host:     ENV.fetch("PCRD_TEST_TARGET_HOST",     "localhost"),
        port:     ENV.fetch("PCRD_TEST_TARGET_PORT",     "5434").to_i,
        database: ENV.fetch("PCRD_TEST_TARGET_DB",       "pcrd_target"),
        user:     ENV.fetch("PCRD_TEST_TARGET_USER",     "postgres"),
        password: ENV.fetch("PCRD_TEST_TARGET_PASSWORD", "postgres")
      )
    )
  end

  def make_config
    src = test_source_config
    tgt = Pcrd::Config::Connection.new(
      host:     ENV.fetch("PCRD_TEST_TARGET_HOST",     "localhost"),
      port:     ENV.fetch("PCRD_TEST_TARGET_PORT",     "5434").to_i,
      database: ENV.fetch("PCRD_TEST_TARGET_DB",       "pcrd_target"),
      user:     ENV.fetch("PCRD_TEST_TARGET_USER",     "postgres"),
      password: ENV.fetch("PCRD_TEST_TARGET_PASSWORD", "postgres")
    )

    tables = [Pcrd::Config::Table.new(
      name: "pcrd_cutover_test",
      optimize_column_order: false,
      columns: {
        "id"    => Pcrd::Config::ColumnSpec.new(type: "bigint",  rename: nil, drop: false),
        "score" => Pcrd::Config::ColumnSpec.new(type: "bigint",  rename: nil, drop: false)
      },
      add_columns: []
    )]

    migrate_cfg = Pcrd::Config::MigrateConfig.new(
      replication_slot: "pcrd_co_slot",
      publication:      "pcrd_co_pub",
      checkpoint_db:    ":memory:",
      batch_size:       100,
      lag_threshold_bytes: 1_048_576,
      tables: tables
    )

    Pcrd::Config::Root.new(
      source: src, target: tgt, migrate: migrate_cfg,
      analyze: nil,
      verify:  Pcrd::Config::VerifyConfig.new(sample_size: 10),
      cutover: Pcrd::Config::CutoverConfig.new(sequence_buffer: 100, lag_drain_timeout: 10),
      path: "test"
    )
  end

  def target_with_table
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_cutover_test CASCADE")
    target_pool.exec_sql(CUTOVER_TARGET_DDL)
    yield
  ensure
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_cutover_test CASCADE")
    target_pool.close
  end

  around do |example|
    with_table(source_pool, CUTOVER_SOURCE_DDL, table_name: "pcrd_cutover_test") do
      target_with_table { example.run }
    end
  end

  def seed_and_copy(count)
    count.times do |i|
      source_pool.exec(
        "INSERT INTO pcrd_cutover_test (label, score) VALUES ($1, $2)",
        ["label_#{i}", i * 10]
      )
    end

    # Bulk-copy matching rows to target (simulates completed backfill)
    rows = source_pool.exec("SELECT id, label, score FROM pcrd_cutover_test").to_a
    rows.each do |row|
      target_pool.exec(
        "INSERT INTO pcrd_cutover_test (id, label, score) VALUES ($1::bigint, $2, $3::bigint)",
        [row["id"], row["label"], row["score"]]
      )
    end
    rows.length
  end

  describe "Cutover::Sequences#advance" do
    it "advances the target sequence to source max + buffer" do
      inserted_count = seed_and_copy(5)
      config = make_config

      seqs = Pcrd::Cutover::Sequences.new(
        source_pool:   source_pool,
        target_pool:   target_pool,
        safety_buffer: 100
      )
      results = seqs.advance(["pcrd_cutover_test"])

      expect(results).not_to be_empty
      result = results.first
      expect(result.table_name).to eq "pcrd_cutover_test"
      expect(result.column_name).to eq "id"
      expect(result.target_value).to eq result.source_max_id + 100
      expect(result.target_value).to be > inserted_count
    end
  end

  describe "Commands::Verify" do
    it "passes when source and target row counts match" do
      seed_and_copy(10)
      config = make_config
      result = Pcrd::Commands::Verify.new(config).run
      expect(result.passed).to be true
    end

    it "fails when source and target row counts differ" do
      seed_and_copy(10)
      # Add extra row to source only
      source_pool.exec("INSERT INTO pcrd_cutover_test (label, score) VALUES ($1, $2)", ["extra", 999])
      config = make_config
      result = Pcrd::Commands::Verify.new(config).run
      expect(result.passed).to be false
      expect(result.tables.first.source_count).to eq 11
      expect(result.tables.first.target_count).to eq 10
    end

    it "returns per-table result structs" do
      seed_and_copy(3)
      config = make_config
      result = Pcrd::Commands::Verify.new(config).run
      expect(result.tables.first.table_name).to eq "pcrd_cutover_test"
      expect(result.tables.first.source_count).to eq 3
      expect(result.tables.first.target_count).to eq 3
    end
  end

  describe "Cutover::Orchestrator" do
    it "passes when counts match and advances sequences" do
      seed_and_copy(5)
      config = make_config

      result = Pcrd::Cutover::Orchestrator.new(
        source_pool: source_pool,
        target_pool: target_pool,
        config:      config
      ).run

      expect(result.passed).to be true
      expect(result.row_counts["pcrd_cutover_test"]).to eq({ source: 5, target: 5 })
      expect(result.sequence_results).not_to be_empty
    end

    it "reports mismatches when counts differ" do
      seed_and_copy(5)
      source_pool.exec("INSERT INTO pcrd_cutover_test (label, score) VALUES ('x', 0)")
      config = make_config

      result = Pcrd::Cutover::Orchestrator.new(
        source_pool: source_pool,
        target_pool: target_pool,
        config:      config
      ).run

      expect(result.passed).to be false
      expect(result.warnings).not_to be_empty
    end
  end
end

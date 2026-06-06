# frozen_string_literal: true

require "pcrd"
require "tmpdir"
require_relative "../support/pg_helpers"

RSpec.describe "Backfill::Engine (integration)", :integration do
  include PgHelpers

  BACKFILL_SOURCE_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_backfill_test (
      id        integer NOT NULL,
      label     text,
      score     integer,
      PRIMARY KEY (id)
    )
  SQL

  BACKFILL_TARGET_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_backfill_test (
      id        bigint  NOT NULL,
      label     text,
      score     bigint,
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

  let(:checkpoint_path) { File.join(Dir.mktmpdir, "test_checkpoint.sqlite3") }
  let(:checkpoint) { Pcrd::Checkpoint::Store.new(checkpoint_path) }

  let(:table_config) do
    Pcrd::Config::Table.new(
      name: "pcrd_backfill_test",
      optimize_column_order: false,
      columns: {
        "id"    => Pcrd::Config::ColumnSpec.new(type: "bigint", rename: nil, drop: false),
        "score" => Pcrd::Config::ColumnSpec.new(type: "bigint", rename: nil, drop: false)
      },
      add_columns: []
    )
  end

  let(:migrate_config) do
    Pcrd::Config::MigrateConfig.new(
      replication_slot: "test", publication: "test",
      checkpoint_db: checkpoint_path, batch_size: 100,
      lag_threshold_bytes: 1_048_576, tables: [table_config]
    )
  end

  let(:config) do
    Pcrd::Config::Root.new(
      source: test_source_config, target: nil, migrate: migrate_config,
      analyze: nil, verify: nil, cutover: nil, path: "test"
    )
  end

  def target_with_table
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_backfill_test CASCADE")
    target_pool.exec_sql(BACKFILL_TARGET_DDL)
    yield
  ensure
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_backfill_test CASCADE")
  end

  around do |example|
    with_table(source_pool, BACKFILL_SOURCE_DDL, table_name: "pcrd_backfill_test") do
      target_with_table { example.run }
    end
    checkpoint.close
    File.delete(checkpoint_path) if File.exist?(checkpoint_path)
    target_pool.close
  end

  def seed_source(count)
    count.times do |i|
      source_pool.exec(
        "INSERT INTO pcrd_backfill_test (id, label, score) VALUES ($1, $2, $3)",
        [i + 1, "row_#{i + 1}", (i + 1) * 10]
      )
    end
  end

  def engine
    @engine ||= Pcrd::Backfill::Engine.new(
      source_pool: source_pool,
      target_pool: target_pool,
      config:      config,
      checkpoint:  checkpoint
    )
  end

  describe "full backfill" do
    it "copies all rows from source to target" do
      seed_source(250)
      engine.run
      count = target_pool.exec("SELECT COUNT(*) FROM pcrd_backfill_test")[0]["count"].to_i
      expect(count).to eq 250
    end

    it "applies type casts (integer → bigint)" do
      seed_source(5)
      engine.run
      rows = target_pool.exec("SELECT id, score FROM pcrd_backfill_test ORDER BY id").to_a
      expect(rows.first["id"]).to eq "1"
      expect(rows.last["id"]).to eq  "5"
    end

    it "returns a Result per table" do
      seed_source(50)
      results = engine.run
      expect(results.length).to eq 1
      expect(results.first.table_name).to eq "pcrd_backfill_test"
      expect(results.first.rows_copied).to eq 50
    end

    it "sets phase to :backfill in the checkpoint" do
      seed_source(10)
      engine.run
      expect(checkpoint.phase).to eq :backfill
    end
  end

  describe "resumption" do
    it "skips already-copied rows and copies only new ones" do
      seed_source(250)

      # Simulate a previous partial run: copy rows 1..100 to target,
      # record the batch in the checkpoint.
      first_100 = source_pool.exec(
        "SELECT id, label, score FROM pcrd_backfill_test ORDER BY id LIMIT 100"
      ).to_a
      last_id = first_100.last["id"]

      first_100.each do |row|
        target_pool.exec(
          "INSERT INTO pcrd_backfill_test (id, label, score) VALUES ($1::bigint, $2, $3::bigint)",
          [row["id"], row["label"], row["score"]]
        )
      end

      checkpoint.record_batch(
        table: "pcrd_backfill_test", start_key: "1", end_key: last_id,
        row_count: 100, duration_ms: 50
      )

      # Resume — engine should pick up from id > 100 and copy rows 101..250
      engine.run
      count = target_pool.exec("SELECT COUNT(*) FROM pcrd_backfill_test")[0]["count"].to_i
      expect(count).to eq 250
    end
  end

  describe "batching" do
    it "uses the configured batch size" do
      seed_source(250)
      engine.run
      stats = checkpoint.batch_stats(table: "pcrd_backfill_test")
      # 250 rows / 100 per batch = 3 batches (100 + 100 + 50)
      expect(stats[:batch_count]).to eq 3
    end

    it "records each batch in the checkpoint" do
      seed_source(50)
      engine.run
      batches = checkpoint.batches(table: "pcrd_backfill_test")
      expect(batches.length).to eq 1
      expect(batches.first[:row_count]).to eq 50
    end
  end

  describe "on_batch callback" do
    it "calls the callback once per batch with stats" do
      seed_source(250)
      calls = []
      engine.run(on_batch: ->(s) { calls << s })
      expect(calls.length).to eq 3
      expect(calls.first[:table]).to eq "pcrd_backfill_test"
      expect(calls.first[:batch_num]).to eq 1
      expect(calls.map { _1[:row_count] }.sum).to eq 250
    end
  end

  describe "empty table" do
    it "completes immediately with 0 rows copied" do
      results = engine.run
      expect(results.first.rows_copied).to eq 0
      expect(results.first.batch_count).to eq 0
    end
  end

  describe "throttling" do
    it "copies every row and paces to max_rows_per_second" do
      seed_source(200)

      throttled = Pcrd::Config::MigrateConfig.new(
        replication_slot: "test", publication: "test",
        checkpoint_db: checkpoint_path, batch_size: 100,
        lag_threshold_bytes: 1_048_576, tables: [table_config],
        max_rows_per_second: 500
      )
      cfg = Pcrd::Config::Root.new(
        source: test_source_config, target: nil, migrate: throttled,
        analyze: nil, verify: nil, cutover: nil, path: "test"
      )
      eng = Pcrd::Backfill::Engine.new(
        source_pool: source_pool, target_pool: target_pool, config: cfg, checkpoint: checkpoint
      )

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      eng.run
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      count = target_pool.exec("SELECT COUNT(*) FROM pcrd_backfill_test")[0]["count"].to_i
      expect(count).to eq 200
      # 200 rows at 500 rows/s ≈ 0.4s of enforced pacing; allow slack.
      expect(elapsed).to be >= 0.25
    end
  end
end

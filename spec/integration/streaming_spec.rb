# frozen_string_literal: true

require "pcrd"
require_relative "../support/pg_helpers"

# End-to-end test: INSERT/UPDATE/DELETE on source flow through the consumer +
# apply engine and appear on the target cluster.
#
# Requires:
#   - source_db on port 5433 with wal_level=logical
#   - target_db on port 5434
RSpec.describe "streaming pipeline (integration)", :integration do
  include PgHelpers

  STREAM_SOURCE_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_stream_test (
      id    integer NOT NULL,
      label text,
      score integer,
      PRIMARY KEY (id)
    )
  SQL

  STREAM_TARGET_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_stream_test (
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

  let(:pub_name)  { "pcrd_stream_test_pub" }
  let(:slot_name) { "pcrd_stream_test_slot" }

  let(:table_config) do
    Pcrd::Config::Table.new(
      name: "pcrd_stream_test",
      optimize_column_order: false,
      columns: {
        "id"    => Pcrd::Config::ColumnSpec.new(type: "bigint",  rename: nil, drop: false),
        "score" => Pcrd::Config::ColumnSpec.new(type: "bigint",  rename: nil, drop: false)
      },
      add_columns: []
    )
  end

  let(:migrate_config) do
    Pcrd::Config::MigrateConfig.new(
      replication_slot: slot_name, publication: pub_name,
      checkpoint_db: ":memory:", batch_size: 100,
      lag_threshold_bytes: 1_048_576, tables: [table_config]
    )
  end

  let(:config) do
    src = test_source_config
    Pcrd::Config::Root.new(
      source: src, target: nil, migrate: migrate_config,
      analyze: nil, verify: nil, cutover: nil, path: "test"
    )
  end

  let(:source_schema) do
    reader = Pcrd::Schema::Reader.new(source_pool)
    {
      "pcrd_stream_test" => {
        columns:    reader.read("pcrd_stream_test"),
        pk_columns: reader.primary_key_columns("pcrd_stream_test")
      }
    }
  end

  let(:parser)   { Pcrd::Replication::Pgoutput::Parser.new }
  let(:repl_conn) { Pcrd::Connection::Replication.new(test_source_config) }

  def cleanup_slot
    source_pool.exec(
      "SELECT pg_drop_replication_slot($1) " \
      "WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = $1)",
      [slot_name]
    ) rescue nil
    source_pool.exec_sql("DROP PUBLICATION IF EXISTS #{pub_name}") rescue nil
  end

  def target_with_table
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_stream_test CASCADE")
    target_pool.exec_sql(STREAM_TARGET_DDL)
    yield
  ensure
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_stream_test CASCADE")
    target_pool.close
  end

  around do |example|
    cleanup_slot
    with_table(source_pool, STREAM_SOURCE_DDL, table_name: "pcrd_stream_test") do
      target_with_table { example.run }
    end
    cleanup_slot
  end

  def create_slot_and_consumer
    source_pool.exec_sql(
      "CREATE PUBLICATION #{pub_name} FOR TABLE pcrd_stream_test"
    )
    result = source_pool.exec(
      "SELECT lsn FROM pg_create_logical_replication_slot($1, 'pgoutput')",
      [slot_name]
    )
    start_lsn = result[0]["lsn"]

    consumer = Pcrd::Replication::Consumer.new(
      repl_conn:  repl_conn,
      parser:     parser,
      slot_name:  slot_name,
      pub_name:   pub_name,
      start_lsn:  start_lsn
    )
    consumer.start
    consumer
  end

  def make_apply_engine(consumer)
    Pcrd::Apply::Engine.new(
      target_pool:   target_pool,
      config:        config,
      parser:        consumer.parser,
      source_schema: source_schema
    )
  end

  # Drains committed transactions from the consumer queue and applies them.
  # Exits early after settle_time seconds of inactivity (once at least one
  # transaction has arrived), or after the hard timeout.
  def drain_queue(consumer, apply_engine, timeout: 3, settle: 0.3)
    deadline     = Time.now + timeout
    last_arrival = nil

    while Time.now < deadline
      begin
        txn = consumer.queue.pop(true)
        apply_engine.apply(txn)
        consumer.advance_lsn(txn.commit_lsn)
        last_arrival = Time.now
      rescue ThreadError
        if consumer.failed?
          raise "Consumer thread error: " \
                "#{consumer.last_error&.class}: #{consumer.last_error&.message}"
        end
        break if last_arrival && Time.now - last_arrival > settle
        sleep 0.05
      end
    end
  end

  describe "INSERT" do
    it "applies insert events to the target" do
      consumer     = create_slot_and_consumer
      apply_engine = make_apply_engine(consumer)

      source_pool.exec("INSERT INTO pcrd_stream_test VALUES ($1, $2, $3)", [1, "hello", 99])

      drain_queue(consumer, apply_engine)
      consumer.stop

      rows = target_pool.exec("SELECT id, label, score FROM pcrd_stream_test").to_a
      expect(rows.length).to eq 1
      expect(rows.first["id"]).to eq "1"
      expect(rows.first["label"]).to eq "hello"
      expect(rows.first["score"]).to eq "99"
    end
  end

  describe "UPDATE" do
    it "applies update events to the target" do
      consumer     = create_slot_and_consumer
      apply_engine = make_apply_engine(consumer)

      source_pool.exec("INSERT INTO pcrd_stream_test VALUES ($1, $2, $3)", [1, "before", 10])
      source_pool.exec("UPDATE pcrd_stream_test SET label = $1, score = $2 WHERE id = $3", ["after", 20, 1])

      drain_queue(consumer, apply_engine)
      consumer.stop

      row = target_pool.exec("SELECT label, score FROM pcrd_stream_test WHERE id = 1").first
      expect(row["label"]).to eq "after"
      expect(row["score"]).to eq "20"
    end
  end

  describe "DELETE" do
    it "applies delete events to the target" do
      consumer     = create_slot_and_consumer
      apply_engine = make_apply_engine(consumer)

      # Pre-populate target so DELETE has something to remove
      target_pool.exec("INSERT INTO pcrd_stream_test VALUES ($1::bigint, $2, $3::bigint)", [5, "gone", 50])

      source_pool.exec("INSERT INTO pcrd_stream_test VALUES ($1, $2, $3)", [5, "gone", 50])
      source_pool.exec("DELETE FROM pcrd_stream_test WHERE id = 5")

      drain_queue(consumer, apply_engine)
      consumer.stop

      count = target_pool.exec("SELECT COUNT(*) FROM pcrd_stream_test")[0]["count"].to_i
      expect(count).to eq 0
    end
  end

  describe "multiple events in one transaction" do
    it "applies all events atomically" do
      consumer     = create_slot_and_consumer
      apply_engine = make_apply_engine(consumer)

      source_pool.transaction do
        source_pool.exec("INSERT INTO pcrd_stream_test VALUES ($1, $2, $3)", [1, "a", 1])
        source_pool.exec("INSERT INTO pcrd_stream_test VALUES ($1, $2, $3)", [2, "b", 2])
        source_pool.exec("INSERT INTO pcrd_stream_test VALUES ($1, $2, $3)", [3, "c", 3])
      end

      drain_queue(consumer, apply_engine)
      consumer.stop

      count = target_pool.exec("SELECT COUNT(*) FROM pcrd_stream_test")[0]["count"].to_i
      expect(count).to eq 3
    end
  end

  describe "Apply::Worker (concurrent apply)" do
    it "applies streamed events on its own thread and acknowledges the LSN" do
      consumer = create_slot_and_consumer

      # The worker must apply on a connection it does not share with the
      # assertions below (Connection::Client wraps a single PG connection).
      worker_pool  = Pcrd::Connection::Client.new(
        Pcrd::Config::Connection.new(
          host:     ENV.fetch("PCRD_TEST_TARGET_HOST",     "localhost"),
          port:     ENV.fetch("PCRD_TEST_TARGET_PORT",     "5434").to_i,
          database: ENV.fetch("PCRD_TEST_TARGET_DB",       "pcrd_target"),
          user:     ENV.fetch("PCRD_TEST_TARGET_USER",     "postgres"),
          password: ENV.fetch("PCRD_TEST_TARGET_PASSWORD", "postgres")
        )
      )
      apply_engine = Pcrd::Apply::Engine.new(
        target_pool:   worker_pool,
        config:        config,
        parser:        consumer.parser,
        source_schema: source_schema
      )
      acked  = []
      worker = Pcrd::Apply::Worker.new(
        engine: apply_engine, queue: consumer.queue,
        on_committed: ->(lsn) { acked << lsn; consumer.advance_lsn(lsn) }
      )
      worker.start

      source_pool.exec("INSERT INTO pcrd_stream_test VALUES ($1, $2, $3)", [1, "hello", 99])
      source_pool.exec("INSERT INTO pcrd_stream_test VALUES ($1, $2, $3)", [2, "world", 7])

      deadline = Time.now + 5
      sleep 0.05 until acked.size >= 2 || Time.now > deadline

      consumer.stop
      worker.stop

      expect(worker.failed?).to be(false)
      expect(acked.size).to be >= 2
      rows = target_pool.exec("SELECT id, label, score FROM pcrd_stream_test ORDER BY id").to_a
      expect(rows.map { |r| r["label"] }).to eq(%w[hello world])

      # Observability metrics (P1.5): streaming read position and drained queue.
      expect(consumer.last_received_lsn).to match(%r{\A[0-9A-F]+/[0-9A-F]+\z})
      expect(consumer.queue_depth).to eq(0)
      expect(worker.last_applied_lsn).to eq(consumer.last_received_lsn)
    ensure
      worker_pool&.close
    end
  end
end

# frozen_string_literal: true

require "pcrd"
require_relative "../support/pg_helpers"

RSpec.describe Pcrd::Readiness::Manifest, :integration do
  include PgHelpers

  READINESS_SOURCE_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_readiness_test (
      id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      email  text,
      status text,
      org_id integer
    )
  SQL

  # Target load schema: table + PK only, renamed status -> state. No secondary
  # objects yet (that is what the manifest is for).
  READINESS_TARGET_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_readiness_test (
      id     bigint PRIMARY KEY,
      email  text,
      state  text,
      org_id bigint
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

  let(:config) do
    table = Pcrd::Config::Table.new(
      name: "pcrd_readiness_test", optimize_column_order: false,
      columns: { "status" => Pcrd::Config::ColumnSpec.new(type: nil, rename: "state", drop: false) },
      add_columns: []
    )
    migrate = Pcrd::Config::MigrateConfig.new(
      replication_slot: "x", publication: "x", checkpoint_db: ":memory:",
      batch_size: 100, lag_threshold_bytes: 1, tables: [table]
    )
    Pcrd::Config::Root.new(
      source: test_source_config, target: target_config, migrate: migrate,
      analyze: nil, verify: nil, cutover: nil, path: "test"
    )
  end

  subject(:manifest) do
    described_class.new(source_pool: source_pool, target_pool: target_pool, config: config).build
  end

  def seed_source_objects
    source_pool.exec_sql("CREATE INDEX idx_readiness_email ON pcrd_readiness_test (email)")
    source_pool.exec_sql("CREATE INDEX idx_readiness_status ON pcrd_readiness_test (status)")
    source_pool.exec_sql("ALTER TABLE pcrd_readiness_test ADD CONSTRAINT chk_readiness_status CHECK (status IS NOT NULL)")
    source_pool.exec_sql("GRANT SELECT ON pcrd_readiness_test TO PUBLIC")
    source_pool.exec_sql("COMMENT ON TABLE pcrd_readiness_test IS 'people'")
    source_pool.exec_sql("COMMENT ON COLUMN pcrd_readiness_test.email IS 'contact email'")
    source_pool.exec_sql("COMMENT ON COLUMN pcrd_readiness_test.status IS 'lifecycle'")
  end

  around do |example|
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_readiness_test CASCADE")
    target_pool.exec_sql(READINESS_TARGET_DDL)
    with_table(source_pool, READINESS_SOURCE_DDL, table_name: "pcrd_readiness_test") do
      seed_source_objects
      example.run
    end
    target_pool.exec_sql("DROP TABLE IF EXISTS pcrd_readiness_test CASCADE")
    target_pool.close
  end

  def entry(name)
    manifest.tables.first.entries.find { |e| e.name == name }
  end

  it "emits CREATE INDEX CONCURRENTLY for an index on an unchanged column" do
    e = entry("idx_readiness_email")
    expect(e.status).to eq(:missing)
    expect(e.ddl).to include("CREATE INDEX CONCURRENTLY idx_readiness_email")
    expect(e.ddl).to end_with(";")
  end

  it "flags an index on a renamed column for manual review" do
    e = entry("idx_readiness_status")
    expect(e.status).to eq(:needs_review)
    expect(e.detail).to include("renamed column(s): status->state")
    expect(e.ddl).to start_with("--") # commented out, not runnable
  end

  it "flags a constraint on a renamed column for manual review" do
    e = entry("chk_readiness_status")
    expect(e.status).to eq(:needs_review)
  end

  it "marks an index already present on the target" do
    target_pool.exec_sql("CREATE INDEX idx_readiness_email ON pcrd_readiness_test (email)")
    expect(entry("idx_readiness_email").status).to eq(:present)
  end

  it "reports the identity column as restored at cutover" do
    e = entry("id")
    expect(e.category).to eq("sequence")
    expect(e.status).to eq(:info)
    expect(e.detail).to include("cutover")
  end

  it "emits a GRANT for a privilege present only on the source" do
    e = entry("PUBLIC")
    expect(e.category).to eq("grant")
    expect(e.status).to eq(:missing)
    expect(e.ddl).to eq("GRANT SELECT ON public.pcrd_readiness_test TO PUBLIC;")
  end

  it "reports the owner (same on both clusters here)" do
    e = manifest.tables.first.entries.find { |x| x.category == "owner" }
    expect(e).not_to be_nil
    expect(e.status).to eq(:present)
  end

  it "emits COMMENT ON TABLE for a missing table comment" do
    e = entry("(table)")
    expect(e.category).to eq("comment")
    expect(e.status).to eq(:missing)
    expect(e.ddl).to eq("COMMENT ON TABLE public.pcrd_readiness_test IS 'people';")
  end

  it "emits COMMENT ON COLUMN for an unchanged column" do
    e = entry("email")
    expect(e.category).to eq("comment")
    expect(e.ddl).to eq("COMMENT ON COLUMN public.pcrd_readiness_test.email IS 'contact email';")
  end

  it "re-emits a renamed column's comment against the target column name" do
    # status -> state; comments are rename-safe (only the identifier changes).
    e = entry("state")
    expect(e.category).to eq("comment")
    expect(e.status).to eq(:missing)
    expect(e.ddl).to eq("COMMENT ON COLUMN public.pcrd_readiness_test.state IS 'lifecycle';")
  end
end

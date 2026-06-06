# frozen_string_literal: true

require "pcrd"
require_relative "../support/pg_helpers"

RSpec.describe Pcrd::Schema::Setup, :integration do
  include PgHelpers

  SETUP_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_setup_test (id integer PRIMARY KEY, label text)
  SQL

  let(:slot_name) { "pcrd_setup_test_slot" }
  let(:pub_name)  { "pcrd_setup_test_pub" }

  let(:config) do
    table = Pcrd::Config::Table.new(
      name: "pcrd_setup_test", optimize_column_order: false, columns: {}, add_columns: []
    )
    migrate = Pcrd::Config::MigrateConfig.new(
      replication_slot: slot_name, publication: pub_name, checkpoint_db: ":memory:",
      batch_size: 100, lag_threshold_bytes: 1, tables: [table]
    )
    Pcrd::Config::Root.new(
      source: test_source_config, target: nil, migrate: migrate,
      analyze: nil, verify: nil, cutover: nil, path: "test"
    )
  end

  subject(:setup) do
    described_class.new(source_pool: source_pool, target_pool: source_pool, config: config)
  end

  def drop_objects
    source_pool.exec(
      "SELECT pg_drop_replication_slot($1) WHERE EXISTS " \
      "(SELECT 1 FROM pg_replication_slots WHERE slot_name = $1)", [slot_name]
    )
    source_pool.exec_sql("DROP PUBLICATION IF EXISTS #{pub_name}")
  end

  around do |example|
    drop_objects
    with_table(source_pool, SETUP_DDL, table_name: "pcrd_setup_test") { example.run }
    drop_objects
  end

  describe "#create_publication_and_slot" do
    it "creates the publication and slot and returns a starting LSN" do
      lsn = setup.create_publication_and_slot(pub_name: pub_name, slot_name: slot_name)
      expect(lsn).to match(%r{\A[0-9A-F]+/[0-9A-F]+\z})
    end

    it "refuses to recreate an existing slot" do
      setup.create_publication_and_slot(pub_name: pub_name, slot_name: slot_name)
      expect {
        setup.create_publication_and_slot(pub_name: pub_name, slot_name: slot_name)
      }.to raise_error(/slot '#{slot_name}' already exists/)
    end

    it "reuses a leftover publication that matches the configured tables" do
      setup.create_publication_and_slot(pub_name: pub_name, slot_name: slot_name)
      source_pool.exec("SELECT pg_drop_replication_slot($1)", [slot_name]) # leave the publication

      expect {
        setup.create_publication_and_slot(pub_name: pub_name, slot_name: slot_name)
      }.not_to raise_error
    end

    it "rejects a publication that covers different tables" do
      source_pool.exec_sql("CREATE TABLE pcrd_setup_other (id int PRIMARY KEY)")
      source_pool.exec_sql("CREATE PUBLICATION #{pub_name} FOR TABLE pcrd_setup_other")

      expect {
        setup.create_publication_and_slot(pub_name: pub_name, slot_name: slot_name)
      }.to raise_error(/already exists but covers/)
    ensure
      source_pool.exec_sql("DROP TABLE IF EXISTS pcrd_setup_other CASCADE")
    end
  end

  describe "#validate_resumable!" do
    it "passes when slot and publication exist" do
      setup.create_publication_and_slot(pub_name: pub_name, slot_name: slot_name)
      expect { setup.validate_resumable!(pub_name: pub_name, slot_name: slot_name) }.not_to raise_error
    end

    it "raises when the slot is missing" do
      expect {
        setup.validate_resumable!(pub_name: pub_name, slot_name: slot_name)
      }.to raise_error(/Cannot resume.*slot '#{slot_name}' does not exist/m)
    end
  end
end

# frozen_string_literal: true

require "pcrd"
require "tmpdir"
require "stringio"

RSpec.describe Pcrd::Commands::Cleanup do
  def make_config(checkpoint_db:, slot: "pcrd_test_slot", pub: "pcrd_test_pub")
    src = Pcrd::Config::Connection.new(
      host: "localhost", port: 5432, database: "d", user: "u", password: nil
    )
    migrate = Pcrd::Config::MigrateConfig.new(
      replication_slot: slot, publication: pub,
      checkpoint_db: checkpoint_db, batch_size: 1000,
      lag_threshold_bytes: 1_048_576, tables: []
    )
    Pcrd::Config::Root.new(
      source: src, target: nil, migrate: migrate,
      analyze: nil, verify: nil, cutover: nil, path: "test"
    )
  end

  let(:tmpdir)     { Dir.mktmpdir }
  let(:db_path)    { File.join(tmpdir, "checkpoint.sqlite3") }
  let(:output)     { StringIO.new }

  after { FileUtils.rm_rf(tmpdir) }

  def run_cleanup(config, drop_source: false)
    described_class.new(config, { "drop-source" => drop_source }).run(output: output)
    output.string
  end

  context "checkpoint deletion" do
    it "deletes the checkpoint file if it exists" do
      File.write(db_path, "")
      config = make_config(checkpoint_db: db_path)

      # Mock source connection to avoid real DB calls
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:exec)
        .and_return(double("result", ntuples: 0))
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:exec_sql)
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:quote_ident) { |_, n| "\"#{n}\"" }
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:close)

      run_cleanup(config)
      expect(File.exist?(db_path)).to be false
    end

    it "does not raise when the checkpoint does not exist" do
      config = make_config(checkpoint_db: File.join(tmpdir, "no_checkpoint.sqlite3"))

      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:exec)
        .and_return(double("result", ntuples: 0))
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:exec_sql)
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:quote_ident) { |_, n| "\"#{n}\"" }
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:close)

      expect { run_cleanup(config) }.not_to raise_error
    end
  end

  context "when source connection fails" do
    it "prints a warning and continues rather than raising" do
      File.write(db_path, "")
      config = make_config(checkpoint_db: db_path)

      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:exec)
        .and_raise(Pcrd::Connection::Error, "connection refused")
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:close)

      result = run_cleanup(config)
      expect(result).to include("Could not connect")
    end
  end

  context "output" do
    it "prints a completion message" do
      config = make_config(checkpoint_db: db_path)

      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:exec)
        .and_return(double("result", ntuples: 0))
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:exec_sql)
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:quote_ident) { |_, n| "\"#{n}\"" }
      allow_any_instance_of(Pcrd::Connection::Pool).to receive(:close)

      result = run_cleanup(config)
      expect(result).to include("Cleanup complete")
    end
  end
end

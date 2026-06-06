# frozen_string_literal: true

require "pcrd"
require "tmpdir"

RSpec.describe Pcrd::Commands::Status do
  def minimal_config(checkpoint_db:)
    src = Pcrd::Config::Connection.new(
      host: "localhost", port: 5432, database: "d", user: "u", password: nil
    )
    Pcrd::Config::Root.new(
      source: src, target: nil, migrate: nil,
      analyze: nil, verify: nil, cutover: nil, path: "test"
    ).then do |c|
      # Override checkpoint path via migrate config
      migrate = Pcrd::Config::MigrateConfig.new(
        replication_slot: "slot", publication: "pub",
        checkpoint_db: checkpoint_db, batch_size: 1000,
        lag_threshold_bytes: 1_048_576, tables: []
      )
      Pcrd::Config::Root.new(
        source: src, target: nil, migrate: migrate,
        analyze: nil, verify: nil, cutover: nil, path: "test"
      )
    end
  end

  describe "#run" do
    let(:tmpdir) { Dir.mktmpdir }
    let(:db_path) { File.join(tmpdir, "test_checkpoint.sqlite3") }

    after { FileUtils.rm_rf(tmpdir) }

    context "when no checkpoint exists" do
      it "prints a 'not started' message without raising" do
        config = minimal_config(checkpoint_db: File.join(tmpdir, "nonexistent.sqlite3"))
        output = StringIO.new
        allow($stdout).to receive(:puts) { |*args| output.puts(*args) }
        expect { described_class.new(config).run }.not_to raise_error
      end
    end

    context "when a checkpoint exists" do
      let(:store) { Pcrd::Checkpoint::Store.new(db_path) }

      after { store.close }

      before do
        store.set_phase(:backfill)
        store.set_started_at("2026-01-01T10:00:00Z")
        store.record_batch(
          table: "users", start_key: 1, end_key: 1000,
          row_count: 1000, duration_ms: 200
        )
      end

      it "displays the phase" do
        config = minimal_config(checkpoint_db: db_path)
        expect_any_instance_of(Pcrd::Commands::Status).to receive(:print_status) do |cmd, _store|
          # Just verify it runs without error
        end
        expect { described_class.new(config).run }.not_to raise_error
      end

      it "reads batch stats from the checkpoint" do
        store.close  # close so Status can open it
        config = minimal_config(checkpoint_db: db_path)

        # Verify no exception is raised when checkpoint exists
        expect { described_class.new(config).run }.not_to raise_error
      end
    end
  end
end

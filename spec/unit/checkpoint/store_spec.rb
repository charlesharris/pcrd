# frozen_string_literal: true

require "pcrd"
require "tmpdir"

RSpec.describe Pcrd::Checkpoint::Store do
  subject(:store) { described_class.new(db_path) }

  let(:db_path) { File.join(Dir.mktmpdir, "test_checkpoint.sqlite3") }

  after { store.close; File.delete(db_path) if File.exist?(db_path) }

  describe "phase" do
    it "returns :new for a fresh store" do
      expect(store.phase).to eq :new
    end

    it "persists phase changes" do
      store.set_phase(:backfill)
      expect(store.phase).to eq :backfill
    end

    it "can transition through phases" do
      store.set_phase(:backfill)
      store.set_phase(:streaming)
      expect(store.phase).to eq :streaming
    end
  end

  describe "LSN tracking" do
    it "returns nil for a fresh store" do
      expect(store.lsn).to be_nil
      expect(store.backfill_start_lsn).to be_nil
    end

    it "persists LSN" do
      store.set_lsn("0/3FA2C100")
      expect(store.lsn).to eq "0/3FA2C100"
    end

    it "persists backfill start LSN separately from current LSN" do
      store.set_backfill_start_lsn("0/1A000000")
      store.set_lsn("0/2B000000")
      expect(store.backfill_start_lsn).to eq "0/1A000000"
      expect(store.lsn).to eq "0/2B000000"
    end

    it "rejects a malformed LSN rather than persisting garbage" do
      expect { store.set_lsn("__error__:boom") }.to raise_error(ArgumentError, /invalid LSN/)
      expect { store.set_lsn(nil) }.to raise_error(ArgumentError, /invalid LSN/)
      expect(store.lsn).to be_nil
    end
  end

  describe "batch recording" do
    it "returns nil for last_completed_key on a fresh store" do
      expect(store.last_completed_key(table: "listings")).to be_nil
    end

    it "records a batch and returns its end_key" do
      store.record_batch(table: "listings", start_key: 1, end_key: 10_000,
                         row_count: 10_000, duration_ms: 250)
      expect(store.last_completed_key(table: "listings")).to eq 10_000
    end

    it "returns the most recent end_key when multiple batches are recorded" do
      store.record_batch(table: "listings", start_key: 1,      end_key: 10_000, row_count: 10_000, duration_ms: 200)
      store.record_batch(table: "listings", start_key: 10_001, end_key: 20_000, row_count: 10_000, duration_ms: 210)
      expect(store.last_completed_key(table: "listings")).to eq 20_000
    end

    it "tracks batches for different tables independently" do
      store.record_batch(table: "users",    start_key: 1, end_key: 500,  row_count: 500,  duration_ms: 50)
      store.record_batch(table: "listings", start_key: 1, end_key: 1000, row_count: 1000, duration_ms: 100)
      expect(store.last_completed_key(table: "users")).to eq 500
      expect(store.last_completed_key(table: "listings")).to eq 1000
    end

    it "handles composite (array) keys" do
      composite_key = [42, "abc"]
      store.record_batch(table: "t", start_key: [1, "a"], end_key: composite_key,
                         row_count: 10, duration_ms: 5)
      expect(store.last_completed_key(table: "t")).to eq composite_key
    end
  end

  describe "batch_stats" do
    before do
      store.record_batch(table: "listings", start_key: 1,     end_key: 10_000, row_count: 10_000, duration_ms: 200)
      store.record_batch(table: "listings", start_key: 10_001, end_key: 20_000, row_count: 10_000, duration_ms: 250)
    end

    it "returns the correct batch count" do
      expect(store.batch_stats(table: "listings")[:batch_count]).to eq 2
    end

    it "returns the total rows copied" do
      expect(store.batch_stats(table: "listings")[:total_rows]).to eq 20_000
    end

    it "returns an average rows-per-second estimate" do
      expect(store.batch_stats(table: "listings")[:avg_rows_per_sec]).to be > 0
    end

    it "returns zeros for a table with no batches" do
      stats = store.batch_stats(table: "other_table")
      expect(stats[:batch_count]).to eq 0
      expect(stats[:total_rows]).to eq 0
    end
  end

  describe "total_rows_copied" do
    it "returns 0 for a fresh store" do
      expect(store.total_rows_copied(table: "listings")).to eq 0
    end

    it "sums rows across all batches" do
      store.record_batch(table: "listings", start_key: 1,     end_key: 5_000, row_count: 5_000,  duration_ms: 100)
      store.record_batch(table: "listings", start_key: 5_001, end_key: 9_000, row_count: 4_000,  duration_ms: 80)
      expect(store.total_rows_copied(table: "listings")).to eq 9_000
    end
  end

  describe "persistence" do
    it "survives closing and reopening" do
      store.set_phase(:backfill)
      store.set_lsn("0/1234")
      store.record_batch(table: "t", start_key: 1, end_key: 100, row_count: 100, duration_ms: 10)
      store.close

      reopened = described_class.new(db_path)
      expect(reopened.phase).to eq :backfill
      expect(reopened.lsn).to eq "0/1234"
      expect(reopened.last_completed_key(table: "t")).to eq 100
      reopened.close
    end
  end
end

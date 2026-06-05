# frozen_string_literal: true

require "sqlite3"
require "json"

module Pcrd
  module Checkpoint
    # SQLite-backed store for migration progress.
    #
    # Tracks two things:
    #   1. Metadata (phase, LSN watermark, start time) — key/value rows
    #   2. Completed batches — one row per successfully copied batch,
    #      with start/end key, row count, duration, and timestamp.
    #
    # The per-batch log is what makes resumption safe and auditable:
    # on resume, `last_completed_key` returns the highest end_key and
    # the backfill skips straight past it. It also powers throughput
    # stats and ETA estimates.
    class Store
      # A PostgreSQL LSN is two hex segments joined by a slash, e.g. "16/B374D848".
      LSN_FORMAT = /\A[0-9A-Fa-f]+\/[0-9A-Fa-f]+\z/

      SCHEMA_SQL = <<~SQL.freeze
        CREATE TABLE IF NOT EXISTS metadata (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS batches (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          table_name   TEXT    NOT NULL,
          start_key    TEXT    NOT NULL,
          end_key      TEXT    NOT NULL,
          row_count    INTEGER NOT NULL,
          duration_ms  INTEGER NOT NULL,
          completed_at TEXT    NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_batches_table
          ON batches (table_name, id DESC);
      SQL

      def initialize(path)
        @path = path
        @db   = SQLite3::Database.new(path)
        @db.results_as_hash = true
        @db.busy_timeout = 5_000
        @db.execute_batch(SCHEMA_SQL)
        # Backfill (recording batches) and the apply worker (recording LSN) hit
        # this store from two threads at once. SQLite3::Database is a single
        # connection, so serialize every @db access through one mutex. The lock
        # is taken only at the lowest level (get_meta/set_meta and the batch
        # methods) so the public wrappers never re-enter it.
        @mutex = Mutex.new
      end

      def close
        @mutex.synchronize { @db.close unless @db.closed? }
      end

      # ── phase & LSN metadata ─────────────────────────────────────────────

      def phase
        val = get_meta("phase")
        val ? val.to_sym : :new
      end

      def set_phase(phase)
        set_meta("phase", phase.to_s)
      end

      def lsn
        get_meta("current_lsn")
      end

      def set_lsn(lsn)
        unless lsn.is_a?(String) && lsn.match?(LSN_FORMAT)
          raise ArgumentError, "invalid LSN: #{lsn.inspect}"
        end

        set_meta("current_lsn", lsn)
      end

      def backfill_start_lsn
        get_meta("backfill_start_lsn")
      end

      def set_backfill_start_lsn(lsn)
        set_meta("backfill_start_lsn", lsn)
      end

      def started_at
        get_meta("started_at")
      end

      def set_started_at(ts)
        set_meta("started_at", ts)
      end

      # ── batch tracking ───────────────────────────────────────────────────

      # Record a successfully completed batch.
      # Keys are JSON-encoded to support multi-column primary keys.
      def record_batch(table:, start_key:, end_key:, row_count:, duration_ms:)
        @mutex.synchronize do
          @db.execute(
            "INSERT INTO batches (table_name, start_key, end_key, row_count, duration_ms, completed_at) " \
            "VALUES (?, ?, ?, ?, ?, ?)",
            [table.to_s,
             JSON.generate(start_key),
             JSON.generate(end_key),
             row_count.to_i,
             duration_ms.to_i,
             Time.now.iso8601]
          )
        end
      end

      # Returns the end_key of the last completed batch for a table, decoded from JSON.
      # Returns nil if no batches have been recorded for this table (fresh start).
      def last_completed_key(table:)
        row = @mutex.synchronize do
          @db.get_first_row(
            "SELECT end_key FROM batches WHERE table_name = ? ORDER BY id DESC LIMIT 1",
            [table.to_s]
          )
        end
        row ? JSON.parse(row["end_key"]) : nil
      end

      # Returns aggregate stats for a table's completed batches.
      def batch_stats(table:)
        row = @mutex.synchronize do
          @db.get_first_row(
            "SELECT COUNT(*) AS cnt, SUM(row_count) AS total_rows, " \
            "AVG(CAST(row_count AS REAL) / NULLIF(duration_ms, 0) * 1000) AS avg_rps " \
            "FROM batches WHERE table_name = ?",
            [table.to_s]
          )
        end
        {
          batch_count:    row["cnt"].to_i,
          total_rows:     row["total_rows"].to_i,
          avg_rows_per_sec: row["avg_rps"]&.round(1) || 0.0
        }
      end

      # All completed batches for a table, newest first.
      def batches(table:, limit: 100)
        rows = @mutex.synchronize do
          @db.execute(
            "SELECT * FROM batches WHERE table_name = ? ORDER BY id DESC LIMIT ?",
            [table.to_s, limit]
          )
        end
        rows.map do |row|
          {
            id:           row["id"].to_i,
            table_name:   row["table_name"],
            start_key:    JSON.parse(row["start_key"]),
            end_key:      JSON.parse(row["end_key"]),
            row_count:    row["row_count"].to_i,
            duration_ms:  row["duration_ms"].to_i,
            completed_at: row["completed_at"]
          }
        end
      end

      def total_rows_copied(table:)
        row = @mutex.synchronize do
          @db.get_first_row(
            "SELECT COALESCE(SUM(row_count), 0) AS total FROM batches WHERE table_name = ?",
            [table.to_s]
          )
        end
        row["total"].to_i
      end

      private

      def get_meta(key)
        row = @mutex.synchronize do
          @db.get_first_row("SELECT value FROM metadata WHERE key = ?", [key])
        end
        row ? row["value"] : nil
      end

      def set_meta(key, value)
        @mutex.synchronize do
          @db.execute(
            "INSERT INTO metadata (key, value) VALUES (?, ?) " \
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value.to_s]
          )
        end
      end
    end
  end
end

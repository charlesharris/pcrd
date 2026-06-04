# frozen_string_literal: true

module Pcrd
  module Monitor
    # Queries the source database for replication lag on a named slot.
    #
    # Lag is reported in bytes (WAL bytes the slot has not yet confirmed).
    # A rolling window of recent readings is maintained so callers can
    # compute rate-of-change and estimated time to zero.
    class Lag
      WINDOW_SIZE = 10  # readings to keep for trend analysis

      Reading = Data.define(:bytes, :taken_at)

      def initialize(source_pool:, slot_name:)
        @pool      = source_pool
        @slot_name = slot_name
        @history   = []
      end

      # Queries the current lag in bytes. Returns nil if the slot is not found.
      def lag_bytes
        result = @pool.exec(<<~SQL, [@slot_name])
          SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)::bigint AS lag
          FROM   pg_replication_slots
          WHERE  slot_name = $1
        SQL

        return nil if result.ntuples.zero?

        bytes = result[0]["lag"].to_i
        record(bytes)
        bytes
      rescue Connection::Error
        nil
      end

      # Returns the confirmed_flush_lsn for the slot as a "X/Y" string.
      def confirmed_lsn
        result = @pool.exec(<<~SQL, [@slot_name])
          SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = $1
        SQL
        result.ntuples > 0 ? result[0]["confirmed_flush_lsn"] : nil
      rescue Connection::Error
        nil
      end

      # Returns bytes/second rate of lag change (negative = lag is shrinking).
      # Returns nil if fewer than 2 readings available.
      def trend_bytes_per_sec
        return nil if @history.size < 2

        oldest = @history.first
        newest = @history.last
        elapsed = newest.taken_at - oldest.taken_at
        return nil if elapsed <= 0

        (newest.bytes - oldest.bytes) / elapsed
      end

      # Estimated seconds until lag reaches zero at current trend.
      # Returns nil if trend is not converging (positive or unknown).
      def eta_seconds
        trend = trend_bytes_per_sec
        return nil unless trend&.negative?

        current = @history.last&.bytes
        return nil unless current

        -(current / trend).ceil
      end

      # Human-readable lag summary string.
      def summary
        bytes = lag_bytes
        return "unknown (slot not found)" if bytes.nil?

        parts = ["#{format_bytes(bytes)} behind"]
        eta   = eta_seconds
        parts << "ETA ~#{format_duration(eta)}" if eta
        parts.join("  ")
      end

      private

      def record(bytes)
        @history << Reading.new(bytes: bytes, taken_at: Time.now.to_f)
        @history = @history.last(WINDOW_SIZE)
      end

      def format_bytes(n)
        return "#{n} B" if n < 1024
        return "#{(n / 1024.0).round(1)} KB" if n < 1_048_576
        return "#{(n / 1_048_576.0).round(1)} MB" if n < 1_073_741_824

        "#{(n / 1_073_741_824.0).round(2)} GB"
      end

      def format_duration(secs)
        return "#{secs}s" if secs < 60
        return "#{(secs / 60.0).ceil}m" if secs < 3600

        "#{(secs / 3600.0).ceil}h"
      end
    end
  end
end

# frozen_string_literal: true

require "pg"

module Pcrd
  module Connection
    # Manages a PostgreSQL logical replication connection.
    #
    # Opened with replication: 'database' so the server accepts streaming
    # replication protocol commands. Use open → start_replication, then
    # poll with get_copy_data / respond with put_copy_data.
    class Replication
      # START_REPLICATION is replication-protocol SQL, not ordinary SQL: the
      # slot name and LSN are interpolated as bare tokens, so they must be
      # validated rather than quoted. Slot names follow PostgreSQL's own rule
      # (lowercase letters, digits, underscore; max 63). LSN is the standard
      # hex/hex form. Both are config/checkpoint-derived, so validate them.
      SLOT_NAME_RE = /\A[a-z0-9_]{1,63}\z/
      LSN_RE       = %r{\A[0-9A-Fa-f]{1,8}/[0-9A-Fa-f]{1,8}\z}

      def initialize(config)
        @config = config
        @conn   = nil
      end

      def open
        @conn = PG.connect(
          host:             @config.host,
          port:             @config.port,
          dbname:           @config.database,
          user:             @config.user,
          password:         @config.password,
          application_name: "pcrd-replication",
          replication:      "database"
        )
        self
      rescue PG::ConnectionBad, PG::Error => e
        raise Error, "Replication connection failed to " \
                     "#{@config.host}:#{@config.port}/#{@config.database}: #{e.message}"
      end

      # Sends START_REPLICATION and enters COPY streaming mode.
      # Uses send_query + get_result (not exec) so the CopyBoth response is
      # handled correctly and the connection is left in streaming copy mode.
      def start_replication(slot_name:, pub_name:, start_lsn: "0/0")
        validate_slot_name!(slot_name)
        validate_lsn!(start_lsn)
        pub_id = pub_name.gsub("'", "''")

        @conn.send_query(
          "START_REPLICATION SLOT #{slot_name} LOGICAL #{start_lsn} " \
          "(proto_version '1', publication_names '#{pub_id}')"
        )
        @conn.get_result   # reads CopyBothResponse; puts connection in copy mode
        self
      rescue PG::Error => e
        raise Error, "START_REPLICATION failed: #{e.message}"
      end

      # Waits up to `timeout` seconds for data on the replication socket.
      # Returns true if data is available, false if the timeout expired.
      def wait_readable(timeout)
        @conn.socket_io.wait_readable(timeout)
      end

      # Returns a String (message bytes), nil (no data yet), or false (stream ended).
      # Call after wait_readable returns true, or after consume_input.
      def get_copy_data
        @conn.consume_input
        @conn.get_copy_data(true)
      rescue PG::Error => e
        raise Error, e.message
      end

      # Sends a client message (keepalive response) to the server.
      def put_copy_data(data)
        @conn.put_copy_data(data)
      rescue PG::Error => e
        raise Error, e.message
      end

      def close
        @conn&.finish
        @conn = nil
      end

      def connected?
        @conn && !@conn.finished?
      end

      private

      def validate_slot_name!(slot_name)
        return if slot_name.to_s.match?(SLOT_NAME_RE)

        raise Error,
              "Invalid replication slot name #{slot_name.inspect}: must be 1-63 " \
              "characters of lowercase letters, digits, or underscores."
      end

      def validate_lsn!(lsn)
        return if lsn.to_s.match?(LSN_RE)

        raise Error, "Invalid start LSN #{lsn.inspect}: expected hex/hex form like \"0/0\"."
      end
    end
  end
end

# frozen_string_literal: true

require "pg"

module Pcrd
  module Connection
    class Client
      # Conservative per-session defaults applied to every connection.
      #
      #   application_name                     — identifies pcrd in pg_stat_activity
      #   lock_timeout=5s                      — fail fast instead of blocking
      #                                          production behind a lock (DDL etc.)
      #   idle_in_transaction_session_timeout  — release locks if a transaction is
      #     =60s                                 left open idle (e.g. a stalled tool)
      #   statement_timeout=0                  — DISABLED on purpose: backfill COPY
      #                                          and large batches run for a long
      #                                          time and must not be killed
      #
      # Override per pool via `settings:`; values are GUC strings (units allowed).
      DEFAULT_SESSION_SETTINGS = {
        "application_name"                    => "pcrd",
        "lock_timeout"                        => "5s",
        "idle_in_transaction_session_timeout" => "60s",
        "statement_timeout"                   => "0"
      }.freeze

      attr_reader :session_settings

      def initialize(config, settings: {})
        @config           = config
        @session_settings = DEFAULT_SESSION_SETTINGS.merge(settings)
        @conn             = nil
      end

      # For parameterized queries (SELECT, INSERT with $1 placeholders).
      def exec(sql, params = [])
        connection.exec_params(sql, params)
      rescue PG::Error => e
        reset_connection!
        raise Error, e.message
      end

      # For DDL and multi-statement SQL where no parameter substitution is needed.
      def exec_sql(sql)
        connection.exec(sql)
      rescue PG::Error => e
        reset_connection!
        raise Error, e.message
      end

      # For COPY ... FROM STDIN. Yields the raw PG::Connection so the caller
      # can call conn.put_copy_data(line) inside the block.
      def copy_data(sql)
        connection.copy_data(sql) { yield connection }
      rescue PG::Error => e
        # A failed COPY can leave the connection mid-COPY or in an aborted
        # transaction; reset it like exec/exec_sql so the next call is usable.
        reset_connection!
        raise Error, e.message
      end

      def quote_ident(name)
        connection.quote_ident(name)
      end

      def escape_literal(val)
        connection.escape_literal(val.to_s)
      end

      def transaction
        exec("BEGIN")
        result = yield
        exec("COMMIT")
        result
      rescue StandardError
        exec("ROLLBACK") rescue nil
        raise
      end

      def close
        @conn&.close
        @conn = nil
      end

      def connected?
        @conn && !@conn.finished?
      end

      # libpq options string that applies the session settings at connect time
      # (-c key=value), so they are in force for the very first statement.
      # application_name is excluded here — it is passed as the dedicated
      # connect parameter because a -c value is overridden by libpq's
      # fallback_application_name.
      def session_options
        @session_settings
          .reject { |key, _| key == "application_name" }
          .map    { |key, value| "-c #{key}=#{value}" }
          .join(" ")
      end

      private

      def connection
        @conn = connect unless connected?
        @conn
      end

      def connect
        PG.connect(
          host:    @config.host,
          port:    @config.port,
          dbname:  @config.database,
          user:    @config.user,
          password: @config.password,
          application_name: @session_settings["application_name"],
          options: session_options
        )
      rescue PG::ConnectionBad => e
        raise Error, "Cannot connect to #{@config.host}:#{@config.port}/#{@config.database}: #{e.message}"
      end

      def reset_connection!
        # If the connection is in an aborted transaction, attempt a rollback
        # so subsequent commands on the same connection can proceed.
        @conn&.exec("ROLLBACK") rescue nil
      end
    end
  end
end

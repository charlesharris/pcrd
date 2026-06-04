# frozen_string_literal: true

require "pg"

module Pcrd
  module Connection
    class Pool
      def initialize(config)
        @config = config
        @conn   = nil
      end

      # For parameterized queries (SELECT, INSERT with $1 placeholders).
      def exec(sql, params = [])
        connection.exec_params(sql, params)
      rescue PG::Error => e
        raise Error, e.message
      end

      # For DDL and multi-statement SQL where no parameter substitution is needed.
      def exec_sql(sql)
        connection.exec(sql)
      rescue PG::Error => e
        raise Error, e.message
      end

      # For COPY ... FROM STDIN. Yields the raw PG::Connection so the caller
      # can call conn.put_copy_data(line) inside the block.
      def copy_data(sql)
        connection.copy_data(sql) { yield connection }
      rescue PG::Error => e
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
          password: @config.password
        )
      rescue PG::ConnectionBad => e
        raise Error, "Cannot connect to #{@config.host}:#{@config.port}/#{@config.database}: #{e.message}"
      end
    end
  end
end

# frozen_string_literal: true

require "pastel"

module Pcrd
  module Commands
    # Drops the replication publication and slot on source, and deletes the
    # local checkpoint database.
    #
    # Run this after the application has been successfully migrated to the target
    # cluster and you're confident you won't need to roll back. The source tables
    # themselves are NOT touched unless --drop-source is passed.
    #
    # Timeline recommendation:
    #   - Verify the app is healthy on the target cluster
    #   - Wait a few days (or a week) as a rollback window
    #   - Then run `pcrd cleanup`
    #   - Optionally run `pcrd cleanup --drop-source` weeks later
    class Cleanup
      PASTEL = Pastel.new

      def initialize(config, options = {})
        @config  = config
        @options = Options.normalize(options)
      end

      def run(output: $stdout)
        output.puts
        output.puts PASTEL.bold("Cleanup")
        output.puts PASTEL.dim("─" * 60)
        output.puts

        drop_slot_and_pub(output)
        drop_checkpoint(output)
        drop_source_tables(output) if @options[:"drop-source"]

        output.puts
        output.puts "  #{PASTEL.green("✓")}  Cleanup complete."
        output.puts
      end

      private

      def drop_slot_and_pub(output)
        return unless @config.source && @config.migrate

        slot = @config.migrate.replication_slot
        pub  = @config.migrate.publication

        pool = Connection::Client.new(@config.source)

        # Drop replication slot
        result = pool.exec(
          "SELECT pg_drop_replication_slot($1) " \
          "WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = $1)",
          [slot]
        )
        if result.ntuples > 0
          output.puts "  #{PASTEL.green("✓")}  Dropped replication slot: #{slot}"
        else
          output.puts "  #{PASTEL.dim("·")}  Replication slot not found (already dropped): #{slot}"
        end

        # Drop publication
        pool.exec_sql("DROP PUBLICATION IF EXISTS #{pool.quote_ident(pub)}")
        output.puts "  #{PASTEL.green("✓")}  Dropped publication: #{pub}"

        pool.close
      rescue Connection::Error => e
        output.puts "  #{PASTEL.yellow("⚠")}  Could not connect to source to drop slot/publication: #{e.message}"
        output.puts "     Drop manually: SELECT pg_drop_replication_slot('#{slot}');"
        output.puts "                    DROP PUBLICATION IF EXISTS #{pub};"
      end

      def drop_checkpoint(output)
        path = @config.migrate&.checkpoint_db || "./pcrd_checkpoint.sqlite3"

        if File.exist?(path)
          File.delete(path)
          output.puts "  #{PASTEL.green("✓")}  Deleted checkpoint: #{path}"
        else
          output.puts "  #{PASTEL.dim("·")}  Checkpoint not found (already deleted): #{path}"
        end
      end

      def drop_source_tables(output)
        return unless @config.source && @config.migrate

        table_names = @config.migrate.tables.map(&:name)

        output.puts
        output.puts "  #{PASTEL.yellow("⚠")}  Dropping source tables: #{table_names.join(', ')}"
        output.puts "  #{PASTEL.yellow("This is irreversible.")} Type the first table name to confirm:"

        input = $stdin.gets&.strip
        unless input == table_names.first
          output.puts "  #{PASTEL.red("Aborted.")} No tables were dropped."
          return
        end

        pool = Connection::Client.new(@config.source)
        table_names.each do |name|
          pool.exec_sql("DROP TABLE IF EXISTS public.#{pool.quote_ident(name)} CASCADE")
          output.puts "  #{PASTEL.green("✓")}  Dropped source table: #{name}"
        end
        pool.close
      rescue Connection::Error => e
        output.puts "  #{PASTEL.red("✗")}  Failed to drop source tables: #{e.message}"
      end
    end
  end
end

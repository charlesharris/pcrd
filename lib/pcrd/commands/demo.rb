# frozen_string_literal: true

require "thor"

module Pcrd
  module Commands
    class Demo < Thor
      def self.exit_on_failure?
        true
      end

      class_option :config, type: :string, aliases: "-c",
                            desc: "Path to migration YAML config (default: pcrd.config.yml)"

      desc "setup", "Create demo schema on the source database"
      long_desc <<~DESC
        Creates three tables on the source database: users, agents, and listings.

        The listings table is intentionally ordered with booleans and smallints
        interleaved among 8-byte columns to demonstrate the padding analysis
        feature of `pcrd analyze`.

        Any existing demo tables are dropped and recreated.

        If no pcrd.config.yml exists in the current directory, a sample config
        is written automatically — edit the host/port values to match your setup.
      DESC
      def setup
        config = load_config!
        pool   = Pcrd::Connection::Client.new(config.source)

        say "Connecting to #{config.source.host}:#{config.source.port}/#{config.source.database}..."

        say "Dropping existing demo tables (if any)..."
        pool.exec_sql(Pcrd::Demo::Schema::DROP_SQL)

        say "Creating users table..."
        pool.exec_sql(Pcrd::Demo::Schema::USERS_DDL)

        say "Creating agents table..."
        pool.exec_sql(Pcrd::Demo::Schema::AGENTS_DDL)

        say "Creating listings table (with intentionally poor column ordering)..."
        pool.exec_sql(Pcrd::Demo::Schema::LISTINGS_DDL)
        pool.exec_sql(Pcrd::Demo::Schema::LISTINGS_FK_DDL)

        pool.close

        write_sample_config unless config_file_exists?

        say ""
        say "Done. Run `pcrd demo seed` to populate with sample data.", :green
        say "Then run `pcrd analyze` to see the column padding analysis.", :green
      rescue Pcrd::Connection::Error => e
        raise Thor::Error, "Connection failed: #{e.message}"
      rescue Pcrd::Config::LoadError => e
        raise Thor::Error, e.message
      end

      desc "seed", "Generate sample data in the demo schema"
      long_desc <<~DESC
        Populates the demo tables with realistic fake data.

        Generates users and agents proportional to the listing count, then
        generates the requested number of listings referencing those agents.

        The data is seeded with a fixed random seed for reproducibility — running
        seed twice with the same --rows value produces the same rows (useful for
        testing). Pass --seed to override.
      DESC
      method_option :rows, type: :numeric, default: 50_000,
                    desc: "Number of listing rows to generate (users and agents scale proportionally)"
      method_option :seed, type: :numeric, default: 42,
                    desc: "Random seed for reproducible data generation"
      def seed
        config    = load_config!
        pool      = Pcrd::Connection::Client.new(config.source)
        generator = Pcrd::Demo::Generator.new(pool, seed: options[:seed])

        say "Seeding demo database at #{config.source.host}/#{config.source.database}..."
        say ""

        counts = generator.generate(listing_count: options[:rows])

        pool.close

        say ""
        say "Seeding complete:", :green
        say "  users:    #{format_count(counts[:users])}"
        say "  agents:   #{format_count(counts[:agents])}"
        say "  listings: #{format_count(counts[:listings])}"
        say ""
        say "Run `pcrd analyze` to see the column padding report."
      rescue Pcrd::Connection::Error => e
        raise Thor::Error, "Connection failed: #{e.message}"
      rescue Pcrd::Config::LoadError => e
        raise Thor::Error, e.message
      end

      desc "reset", "Drop all demo tables (non-destructive: data only, not config)"
      def reset
        config = load_config!
        pool   = Pcrd::Connection::Client.new(config.source)

        say "Dropping demo tables on #{config.source.host}/#{config.source.database}..."
        pool.exec_sql(Pcrd::Demo::Schema::DROP_SQL)
        pool.close

        say "Done.", :green
      rescue Pcrd::Connection::Error => e
        raise Thor::Error, "Connection failed: #{e.message}"
      rescue Pcrd::Config::LoadError => e
        raise Thor::Error, e.message
      end

      private

      def load_config!
        path = options[:config] || default_config_path
        Pcrd::Config::Loader.load(path)
      end

      def default_config_path
        default = Pcrd::Config::DEFAULT_CONFIG_FILE
        return default if File.exist?(default)

        # Demo setup can run without a config — we'll write one if absent.
        # Fall back to a temporary in-memory config using defaults.
        write_sample_config
        default
      end

      def config_file_exists?
        File.exist?(Pcrd::Config::DEFAULT_CONFIG_FILE)
      end

      def write_sample_config
        path = Pcrd::Config::DEFAULT_CONFIG_FILE
        if File.exist?(path)
          say "  (#{path} already exists — not overwriting)"
        else
          File.write(path, Pcrd::Demo::Schema::SAMPLE_CONFIG)
          say "  Wrote sample config to #{path} — edit host/port values to match your setup.", :cyan
        end
      end

      def format_count(n)
        n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      end
    end
  end
end

# frozen_string_literal: true

require "thor"

module Pcrd
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    class_option :config, type: :string, aliases: "-c",
                          desc: "Path to migration YAML config (required for all commands)"

    desc "analyze", "Analyze column padding for source tables"
    long_desc <<~DESC
      Reads the source table schema and reports the current column layout alongside
      the optimal column ordering for minimal padding waste. Estimates bytes saved
      per row and total storage reclaimed at current row count.

      With --compare-target, also connects to the target cluster and shows a
      side-by-side diff: type changes, renames, added/dropped columns, and the
      padding delta between source and target schemas.

      This command is read-only and requires no migration to be in progress.
    DESC
    method_option :table, type: :string, aliases: "-t",
                          desc: "Analyze a specific table only (default: all tables in config)"
    method_option :"compare-target", type: :boolean, default: false,
                  desc: "Compare source and target schemas side-by-side"
    def analyze
      config = load_config!
      Commands::Analyze.new(config, options).run
    rescue Commands::Analyze::Error => e
      raise Thor::Error, "ERROR: #{e.message}"
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    end

    desc "migrate", "Start or resume the migration"
    long_desc <<~DESC
      Runs preflight checks, creates the replication slot and publication on source,
      creates the target table with the new schema, then runs backfill and streaming
      concurrently until the operator triggers cutover.

      The process is resumable: if interrupted, re-run with --resume to pick up
      from the last completed backfill batch.

      Use --preflight-only to validate the config and source data without starting
      the migration. Use --backfill-only to copy existing rows without starting
      the WAL streaming consumer.
    DESC
    method_option :resume, type: :boolean, default: false,
                  desc: "Resume an interrupted migration from the last checkpoint"
    method_option :"preflight-only", type: :boolean, default: false,
                  desc: "Run preflight checks and print DDL only; do not start migration"
    method_option :"backfill-only", type: :boolean, default: false,
                  desc: "Copy existing rows only; do not start WAL streaming consumer"
    method_option :"dry-run", type: :boolean, default: false,
                  desc: "Print preflight report and target DDL without touching either cluster"
    method_option :yes, type: :boolean, default: false, aliases: "-y",
                  desc: "Skip the confirmation prompt before starting migration"
    method_option :"force-overwrite", type: :boolean, default: false,
                  desc: "Drop and recreate target tables if they already exist"
    def migrate
      config  = load_config!
      preflight_only = options[:"preflight-only"] || options[:"dry-run"]

      result  = Preflight.new(config, options).run
      Output::PreflightPrinter.new.print(result)

      if preflight_only
        exit(result.passed ? 0 : 1)
        return
      end

      unless result.passed
        raise Thor::Error, "Preflight failed. Fix the issue(s) above before running migrate."
      end

      unless options[:yes]
        answer = ask("Proceed with migration? [y/N]")
        return unless answer.strip.downcase == "y"
      end

      source_pool = Connection::Pool.new(config.source)
      target_pool = Connection::Pool.new(config.target)
      checkpoint  = Checkpoint::Store.new(config.migrate.checkpoint_db)

      # Create target tables (skip if resuming and they already exist)
      unless options[:resume]
        say "\nCreating target tables..."
        setup = Schema::Setup.new(source_pool: source_pool, target_pool: target_pool, config: config)
        setup.create_target_tables(force_overwrite: options[:"force-overwrite"])
        say "  Target tables created.", :green
      end

      say "\nStarting backfill..."
      engine = Backfill::Engine.new(
        source_pool: source_pool,
        target_pool: target_pool,
        config:      config,
        checkpoint:  checkpoint
      )

      trap("INT")  { engine.stop!; say "\nStopping after current batch..." }
      trap("TERM") { engine.stop! }

      results = engine.run(on_batch: method(:print_batch_progress))

      say ""
      results.each do |r|
        status = r.stopped_early ? " (interrupted)" : ""
        say "  #{r.table_name}: #{format_count(r.rows_copied)} rows in " \
            "#{r.batch_count} batches#{status}", :green
      end

      if results.any?(&:stopped_early)
        say "\nBackfill interrupted. Resume with --resume.", :yellow
      else
        say "\nBackfill complete.", :green
        if options[:"backfill-only"]
          say "Run `pcrd verify` to check row counts, then `pcrd cutover` when ready."
        else
          say "Streaming not yet implemented — coming in a future phase.", :yellow
        end
      end

      checkpoint.close
      source_pool.close
      target_pool.close
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    rescue RuntimeError => e
      raise Thor::Error, "ERROR: #{e.message}"
    end

    desc "status", "Show current migration phase and replication lag"
    long_desc <<~DESC
      Reads the checkpoint database and queries pg_replication_slots to show:
      current phase, backfill progress, replication lag in bytes and estimated
      seconds, and whether the migration is ready for cutover.
    DESC
    def status
      require_config!
      say "status: not yet implemented", :yellow
    end

    desc "cutover", "Trigger the cutover sequence"
    long_desc <<~DESC
      Drains remaining replication lag to zero, advances sequences on the target
      cluster, runs row-count verification, and prints a cutover report.

      The application must be in maintenance mode before running this command.
      Use --maintenance-confirmed to skip the interactive confirmation prompt.

      After this command completes, update DATABASE_URL to point at the target
      cluster and restart the application.
    DESC
    method_option :"maintenance-confirmed", type: :boolean, default: false,
                  desc: "Skip interactive confirmation that the app is in maintenance mode"
    def cutover
      require_config!
      say "cutover: not yet implemented", :yellow
    end

    desc "verify", "Compare row counts and spot-check rows across clusters"
    long_desc <<~DESC
      Compares row counts on source and target for each migrated table, then
      spot-checks a random sample of rows field-by-field. Reports any mismatches.

      Safe to run at any point after backfill completes.
    DESC
    method_option :"sample-size", type: :numeric, default: 1_000,
                  desc: "Number of rows to spot-check per table"
    method_option :"post-cutover", type: :boolean, default: false,
                  desc: "Post-cutover mode: compare against the now-live target cluster"
    def verify
      require_config!
      say "verify: not yet implemented", :yellow
    end

    desc "demo SUBCOMMAND", "Set up and seed a demo database for testing and demonstration"
    subcommand "demo", Commands::Demo

    desc "cleanup", "Drop replication slot, publication, and checkpoint"
    long_desc <<~DESC
      Drops the replication slot and publication on the source cluster and deletes
      the local checkpoint database. Run this after the application has been
      successfully cut over to the target cluster and you no longer need to roll back.

      With --drop-source, also drops the source tables. This is irreversible and
      requires typing the table name to confirm.
    DESC
    method_option :"drop-source", type: :boolean, default: false,
                  desc: "Also drop source tables after cleanup (irreversible; requires confirmation)"
    def cleanup
      require_config!
      say "cleanup: not yet implemented", :yellow
    end

    private

    # Resolves the config file path and returns a loaded Config::Root.
    # Falls back to pcrd.config.yml in the current directory if --config is omitted.
    # Raises Thor::Error with a clear message if the file cannot be loaded.
    def load_config!
      path = options[:config] || default_config_path
      Config::Loader.load(path)
    rescue Config::LoadError => e
      raise Thor::Error, "ERROR: #{e.message}"
    end

    def default_config_path
      default = Config::DEFAULT_CONFIG_FILE
      return default if File.exist?(default)

      raise Thor::Error,
            "ERROR: No config file found.\n\n" \
            "Create pcrd.config.yml in the current directory, or pass --config path/to/config.yml\n\n" \
            "Run `pcrd help migrate` for configuration documentation."
    end

    def require_config!
      load_config!
    end

    def print_batch_progress(stats)
      rps = stats[:duration_ms] > 0 ? (stats[:row_count] * 1000.0 / stats[:duration_ms]).round : 0
      $stdout.print "\r  #{stats[:table]}  batch #{stats[:batch_num]}  " \
                    "#{format_count(stats[:rows_so_far])} rows  #{format_count(rps)} rows/s    "
      $stdout.flush
    end

    def format_count(n)
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end
  end
end

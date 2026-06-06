# frozen_string_literal: true

require "thor"
require "pastel"

module Pcrd
  class CLI < Thor
    PASTEL = Pastel.new

    def self.exit_on_failure?
      true
    end

    class_option :config, type: :string, aliases: "-c",
                          desc: "Path to migration YAML config (required for all commands)"

    map %w[--version -v] => :version
    desc "--version, -v", "Show pcrd version"
    def version
      say "pcrd #{Pcrd::VERSION}"
    end

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
      config         = load_config!
      preflight_only = options[:"preflight-only"] || options[:"dry-run"]

      unless preflight_only
        raise Thor::Error,
              "ERROR: migrate requires a 'target' section in your config.\n\n" \
              "Use --preflight-only to validate without a target connection." if config.target.nil?

        raise Thor::Error,
              "ERROR: migrate requires a 'migrate' section in your config." if config.migrate.nil?
      end

      result = Preflight.new(config, options).run
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

      orchestrator = Migration::Orchestrator.new(config: config, options: options)
      trap("INT")  { orchestrator.request_stop }
      trap("TERM") { orchestrator.request_stop }
      orchestrator.run
    rescue Replication::Error => e
      raise Thor::Error, "ERROR: #{e.message}\n\nReplication stopped. Resume with --resume once the cause is resolved."
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    rescue Pcrd::Error => e
      raise Thor::Error, "ERROR: #{e.message}"
    end

    desc "status", "Show current migration phase and replication lag"
    long_desc <<~DESC
      Reads the checkpoint database and queries pg_replication_slots to show:
      current phase, backfill progress, replication lag in bytes and estimated
      seconds, and whether the migration is ready for cutover.
    DESC
    def status
      config = load_config!
      Commands::Status.new(config, options).run
    rescue Config::LoadError => e
      raise Thor::Error, "ERROR: #{e.message}"
    end

    desc "readiness", "Report target objects (indexes, constraints) to add before cutover"
    long_desc <<~DESC
      The load schema created by `pcrd migrate` is intentionally minimal — just
      the table and its primary key — so the bulk copy is fast. This command
      compares the source and target and reports the secondary objects that must
      be added to the target before cutover: non-PK indexes and foreign-key,
      unique, and check constraints. It prints runnable DDL (CREATE INDEX
      CONCURRENTLY / ALTER TABLE ADD CONSTRAINT) for the missing ones.

      Objects that reference dropped or renamed columns are flagged for manual
      review rather than auto-generated. Sequences and identity columns are
      listed for reference but are restored automatically by `pcrd cutover`.

      Read-only; safe to run any time after backfill.
    DESC
    def readiness
      config = load_config!
      result = Commands::Readiness.new(config, options).run
      Output::ReadinessPrinter.new.print(result)
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    rescue Pcrd::Error => e
      raise Thor::Error, "ERROR: #{e.message}"
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
      config = load_config!

      unless options[:"maintenance-confirmed"]
        say "\nThe application must be in maintenance mode before continuing."
        say "Maintenance mode options:"
        say "  pgBouncer:  PAUSE <database>"
        say "  Kubernetes: kubectl scale --replicas=0 deployment/app"
        say "  Rails:      enable maintenance middleware"
        say ""
        answer = ask("Is the application in maintenance mode? [y/N]")
        return unless answer.strip.downcase == "y"
      end

      source_pool = Connection::Client.new(config.source)
      target_pool = Connection::Client.new(config.target)
      printer     = Output::CutoverPrinter.new

      say "\nRunning cutover sequence..."
      orchestrator = Cutover::Orchestrator.new(
        source_pool: source_pool,
        target_pool: target_pool,
        config:      config
      )

      result = orchestrator.run(on_progress: ->(msg) { say "  #{msg}" })

      printer.print(result)

      source_pool.close
      target_pool.close

      exit(result.passed ? 0 : 1)
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
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
      config  = load_config!
      result  = Commands::Verify.new(config, options).run
      Output::CutoverPrinter.new.print_verify(result)
      exit(result.passed ? 0 : 1)
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    rescue Pcrd::Error => e
      raise Thor::Error, "ERROR: #{e.message}"
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
      config = load_config!
      Commands::Cleanup.new(config, options).run
    rescue Connection::Error => e
      raise Thor::Error, "Connection failed: #{e.message}"
    rescue Pcrd::Error => e
      raise Thor::Error, "ERROR: #{e.message}"
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
  end
end

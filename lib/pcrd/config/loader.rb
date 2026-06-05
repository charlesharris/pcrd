# frozen_string_literal: true

require "yaml"

module Pcrd
  module Config
    MIGRATE_DEFAULTS = {
      batch_size: 10_000,
      lag_threshold_bytes: 1_048_576,        # 1 MB
      checkpoint_db: "./pcrd_checkpoint.sqlite3"
    }.freeze

    VERIFY_DEFAULTS  = { sample_size: 1_000 }.freeze
    CUTOVER_DEFAULTS = { sequence_buffer: 1_000, lag_drain_timeout: 300 }.freeze

    class Loader
      # Returns a Config::Root. Raises Config::LoadError on any problem.
      def self.load(path)
        new(path).load
      end

      def initialize(path)
        @path = path
      end

      def load
        raw  = read_file
        data = parse_yaml(raw)
        validate!(data)
        build(data)
      end

      private

      def read_file
        File.read(@path)
      rescue Errno::ENOENT
        raise LoadError, "Config file not found: #{@path}"
      rescue Errno::EACCES
        raise LoadError, "Cannot read config file (permission denied): #{@path}"
      end

      def parse_yaml(raw)
        YAML.safe_load(raw, symbolize_names: true)
      rescue Psych::SyntaxError => e
        raise LoadError, "Config file has invalid YAML: #{e.message}"
      end

      def validate!(data)
        result = Schema::DEFINITION.call(data)
        return if result.success?

        messages = result.errors.messages.map do |msg|
          "  #{msg.path.join(".")}: #{msg.text}"
        end
        raise LoadError, "Config file is invalid:\n#{messages.join("\n")}"
      end

      def build(data)
        Root.new(
          source:   build_connection(data[:source], env_prefix: "SOURCE"),
          target:   data[:target] ? build_connection(data[:target], env_prefix: "TARGET") : nil,
          migrate:  data[:migrate] ? build_migrate(data[:migrate]) : nil,
          analyze:  data[:analyze] ? build_analyze(data[:analyze]) : nil,
          verify:   data[:verify]  ? build_verify(data[:verify])   : nil,
          cutover:  data[:cutover] ? build_cutover(data[:cutover]) : nil,
          path:     @path
        )
      end

      def build_connection(raw, env_prefix:)
        password = raw[:password] ||
                   ENV["PCRD_#{env_prefix}_PASSWORD"] ||
                   nil  # falls back to .pgpass / PGPASSWORD at connection time
        Connection.new(
          host:     raw[:host],
          port:     raw.fetch(:port, 5432),
          database: raw[:database],
          user:     raw[:user],
          password: password
        )
      end

      def build_migrate(raw)
        slot_base = derive_slot_base(raw[:tables])
        MigrateConfig.new(
          replication_slot:    raw.fetch(:replication_slot, "pcrd_#{slot_base}"),
          publication:         raw.fetch(:publication,        "pcrd_pub_#{slot_base}"),
          checkpoint_db:       raw.fetch(:checkpoint_db,      MIGRATE_DEFAULTS[:checkpoint_db]),
          batch_size:          raw.fetch(:batch_size,          MIGRATE_DEFAULTS[:batch_size]),
          lag_threshold_bytes: raw.fetch(:lag_threshold_bytes, MIGRATE_DEFAULTS[:lag_threshold_bytes]),
          tables:              (raw[:tables] || []).map { build_table(_1) }
        )
      end

      def build_table(raw)
        Table.new(
          name:                  raw[:name],
          optimize_column_order: raw.fetch(:optimize_column_order, false),
          columns:               build_column_specs(raw[:columns] || {}),
          add_columns:           (raw[:add_columns] || []).map { build_add_column(_1) }
        )
      end

      def build_column_specs(raw_columns)
        raw_columns.transform_keys(&:to_s).transform_values do |spec|
          spec ||= {}
          validate_column_spec!(spec)
          ColumnSpec.new(
            type:   spec[:type]&.to_s,
            rename: spec[:rename]&.to_s,
            drop:   spec.fetch(:drop, false)
          )
        end
      end

      def validate_column_spec!(spec)
        return unless spec[:drop] && (spec[:type] || spec[:rename])

        raise LoadError,
              "A column spec cannot combine `drop: true` with `type` or `rename`"
      end

      def build_add_column(raw)
        AddColumn.new(
          name:    raw[:name],
          type:    raw[:type],
          default: raw[:default]
        )
      end

      def build_analyze(raw)
        AnalyzeConfig.new(tables: raw[:tables]&.map(&:to_s))
      end

      def build_verify(raw)
        VerifyConfig.new(
          sample_size: raw.fetch(:sample_size, VERIFY_DEFAULTS[:sample_size])
        )
      end

      def build_cutover(raw)
        CutoverConfig.new(
          sequence_buffer:    raw.fetch(:sequence_buffer,    CUTOVER_DEFAULTS[:sequence_buffer]),
          lag_drain_timeout:  raw.fetch(:lag_drain_timeout,  CUTOVER_DEFAULTS[:lag_drain_timeout])
        )
      end

      # Derives a short stable name for the replication slot / publication
      # from the first table name when not explicitly configured.
      def derive_slot_base(tables)
        first = tables&.first&.dig(:name)
        first ? first.gsub(/\W/, "_").downcase : "migration"
      end
    end
  end
end

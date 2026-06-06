# frozen_string_literal: true

module Pcrd
  module Commands
    class Analyze
      class Error < Pcrd::Error; end

      def initialize(config, options = {})
        @config  = config
        @options = Options.normalize(options)
      end

      def run
        validate_config!

        source_pool = Connection::Pool.new(@config.source)
        reader      = Schema::Reader.new(source_pool)
        packer      = Schema::Packer.new
        printer     = Output::AnalyzePrinter.new

        if compare_target?
          run_compare(reader, packer, printer)
        else
          run_source_only(reader, packer, printer)
        end

        source_pool.close
      end

      private

      def compare_target?
        @options[:"compare-target"]
      end

      def run_source_only(reader, packer, printer)
        tables_to_analyze.each do |table_name|
          columns   = reader.read(table_name)
          row_count = reader.estimated_row_count(table_name)
          report    = packer.report(columns)

          printer.print_table_report(
            table_name: table_name,
            row_count:  row_count,
            report:     report
          )
        end
      end

      def run_compare(reader, packer, printer)
        validate_compare_config!

        target_pool   = Connection::Pool.new(@config.target)
        target_reader = Schema::Reader.new(target_pool)
        differ        = Schema::Differ.new

        tables_to_analyze.each do |table_name|
          source_cols  = reader.read(table_name)
          row_count    = reader.estimated_row_count(table_name)
          table_config = find_table_config(table_name)

          target_cols, target_is_live = resolve_target_columns(
            table_name, table_config, target_reader, source_cols
          )

          entries = differ.diff(
            source_columns: source_cols,
            table_config:   table_config,
            target_columns: target_cols
          )

          printer.print_diff_report(
            table_name:     table_name,
            row_count:      row_count,
            diff_entries:   entries,
            packer:         packer,
            target_is_live: target_is_live
          )
        end

        target_pool.close
      end

      # Returns [target_columns_or_nil, is_live_boolean].
      # Prefers a live target DB if the table exists; falls back to synthesis.
      def resolve_target_columns(table_name, table_config, target_reader, source_cols)
        if target_reader.table_exists?(table_name)
          [target_reader.read(table_name), true]
        else
          # Synthesize: differ will build target columns from source + spec.
          [nil, false]
        end
      rescue Connection::Error
        # Target DB unreachable — fall back to synthesis.
        [nil, false]
      end

      def tables_to_analyze
        if @options[:table]
          [@options[:table]]
        elsif @config.analyze&.tables&.any?
          @config.analyze.tables
        elsif @config.migrate&.tables&.any?
          @config.migrate.tables.map(&:name)
        else
          raise Error, "Nothing to analyze. Add an 'analyze' or 'migrate' section to your " \
                       "config, or pass --table TABLE_NAME."
        end
      end

      def find_table_config(table_name)
        @config.migrate&.tables&.find { |t| t.name == table_name }
      end

      def validate_config!
        raise Error, "source connection is required for analyze" if @config.source.nil?
      end

      def validate_compare_config!
        raise Error,
              "--compare-target requires a 'target' section in your config" if @config.target.nil?
      end
    end
  end
end

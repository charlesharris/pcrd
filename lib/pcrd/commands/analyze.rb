# frozen_string_literal: true

module Pcrd
  module Commands
    class Analyze
      def initialize(config, options = {})
        @config  = config
        @options = options
      end

      def run
        validate_config!

        pool    = Connection::Pool.new(@config.source)
        reader  = Schema::Reader.new(pool)
        packer  = Schema::Packer.new
        printer = Output::AnalyzePrinter.new

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

        pool.close
      end

      private

      def tables_to_analyze
        if @options["table"]
          [@options["table"]]
        elsif @config.analyze&.tables&.any?
          @config.analyze.tables
        elsif @config.migrate&.tables&.any?
          @config.migrate.tables.map(&:name)
        else
          raise "Nothing to analyze. Add an 'analyze' or 'migrate' section to your config, " \
                "or pass --table TABLE_NAME."
        end
      end

      def validate_config!
        if @config.source.nil?
          raise "source connection is required for analyze"
        end
      end
    end
  end
end

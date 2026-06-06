# frozen_string_literal: true

require "pastel"

module Pcrd
  module Output
    # Renders a Readiness::Manifest::Result: a per-table checklist of secondary
    # objects, followed by a single block of DDL to run on the target before
    # cutover.
    class ReadinessPrinter
      PASTEL = Pastel.new

      ICONS = {
        present:      PASTEL.green("✓"),
        missing:      PASTEL.yellow("+"),
        needs_review: PASTEL.red("!"),
        info:         PASTEL.dim("·")
      }.freeze

      def initialize(output: $stdout)
        @out = output
      end

      def print(result)
        @out.puts
        @out.puts PASTEL.bold("Target readiness")
        @out.puts PASTEL.dim("─" * 70)

        result.tables.each { |table| print_table(table) }

        print_ddl_section(result)
        print_legend
      end

      private

      def print_table(table)
        @out.puts
        @out.puts PASTEL.bold("  #{table.table_name}")
        if table.entries.empty?
          @out.puts "    #{PASTEL.dim('no secondary objects on source')}"
          return
        end

        table.entries.each do |e|
          @out.puts "    #{ICONS[e.status]}  #{e.category.ljust(10)} " \
                    "#{e.name.ljust(28)} #{PASTEL.dim(e.detail)}"
        end
      end

      def print_ddl_section(result)
        ddl = result.tables.flat_map { |t| t.entries }.filter_map(&:ddl)
        return if ddl.empty?

        @out.puts
        @out.puts PASTEL.dim("─" * 70)
        @out.puts
        @out.puts PASTEL.bold("  DDL to run on the target before cutover:")
        @out.puts
        ddl.each { |stmt| @out.puts "    #{stmt}" }
        @out.puts
      end

      def print_legend
        @out.puts PASTEL.dim("─" * 70)
        @out.puts "  #{ICONS[:present]} present   #{ICONS[:missing]} will create   " \
                  "#{ICONS[:needs_review]} needs review   #{ICONS[:info]} handled at cutover"
        @out.puts
      end
    end
  end
end

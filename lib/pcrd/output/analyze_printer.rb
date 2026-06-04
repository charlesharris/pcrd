# frozen_string_literal: true

require "tty-table"
require "pastel"

module Pcrd
  module Output
    class AnalyzePrinter
      PASTEL = Pastel.new

      def initialize(output: $stdout)
        @out = output
      end

      def print_table_report(table_name:, schema_name: "public", row_count:, report:)
        host_label = nil  # optionally set by caller
        heading = "Table: #{schema_name}.#{table_name}"
        heading += "  (#{format_count(row_count)} rows)" if row_count > 0
        @out.puts
        @out.puts PASTEL.bold(heading)
        @out.puts

        if report[:already_optimal]
          @out.puts PASTEL.green("  ✓ Column order is already optimal. No padding waste detected.")
          @out.puts
          print_layout_table(report[:current_layout], title: "Current layout")
          return
        end

        print_layout_table(report[:current_layout], title: "Current layout",
                           highlight_padding: true)

        @out.puts
        print_savings_summary(report, row_count)
        @out.puts
        print_layout_table(report[:optimal_layout], title: "Suggested layout (optimal packing)")
      end

      private

      def print_layout_table(layout_entries, title:, highlight_padding: false)
        @out.puts "  #{PASTEL.bold(title)}:"
        @out.puts

        rows = layout_entries.map do |entry|
          col     = entry.column
          padding = entry.padding_before

          padding_cell = if padding > 0 && highlight_padding
                          PASTEL.yellow("← #{padding} wasted")
                        elsif padding > 0
                          "#{padding} bytes"
                        else
                          "—"
                        end

          [col.name, col.display_type, col.display_alignment, col.display_size, padding_cell]
        end

        table = TTY::Table.new(
          header: ["Column", "Type", "Align", "Size", "Padding before"],
          rows:   rows
        )
        rendered = table.render(:unicode, padding: [0, 1], resize: false) do |renderer|
          renderer.border.separator = :each_row
        end
        rendered.each_line { @out.puts "  #{_1.chomp}" }
      end

      def print_savings_summary(report, row_count)
        saved  = report[:saved_bytes]
        pct    = report[:savings_pct]
        curr   = report[:current_size]
        opt    = report[:optimal_size]

        @out.puts "  #{PASTEL.bold("Padding analysis:")}"
        @out.puts "    Current row overhead (fixed cols + padding):  #{curr} bytes"
        @out.puts "    Optimal row overhead (fixed cols only):        #{opt} bytes"
        @out.puts "    #{PASTEL.yellow("Wasted padding:")}  " \
                  "#{PASTEL.bold("#{saved} bytes/row")}  (#{pct}%)"

        if row_count > 0
          total_mb = (saved * row_count) / (1024.0 * 1024.0)
          scale    = total_mb >= 1024 ? "#{(total_mb / 1024).round(1)} GB" : "#{total_mb.round(1)} MB"
          @out.puts "    At #{format_count(row_count)} rows:  " \
                    "#{PASTEL.bold("~#{scale} reclaimed")} by reordering columns"
        end
      end

      def format_count(n)
        n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      end
    end
  end
end

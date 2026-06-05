# frozen_string_literal: true

require "tty-table"
require "tty-screen"
require "pastel"

module Pcrd
  module Output
    class AnalyzePrinter
      PASTEL = Pastel.new

      STATUS_COLORS = {
        unchanged:        ->(s) { s },
        type_changed:     ->(s) { PASTEL.yellow(s) },
        renamed:          ->(s) { PASTEL.cyan(s) },
        type_and_renamed: ->(s) { PASTEL.yellow(s) },
        dropped:          ->(s) { PASTEL.red(s) },
        added:            ->(s) { PASTEL.green(s) }
      }.freeze

      def initialize(output: $stdout)
        @out = output
      end

      # Single-cluster padding analysis: current layout vs. optimal reordering.
      def print_table_report(table_name:, schema_name: "public", row_count:, report:)
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

      # Cross-cluster diff: source schema vs. target (live or synthesized from spec).
      def print_diff_report(table_name:, schema_name: "public", row_count:,
                            diff_entries:, packer:, target_is_live: false)
        heading = "Table: #{schema_name}.#{table_name}"
        heading += "  (#{format_count(row_count)} rows)" if row_count > 0
        heading += target_is_live ? "  — live source vs. live target" \
                                  : "  — source vs. proposed target (synthesized from spec)"
        @out.puts
        @out.puts PASTEL.bold(heading)
        @out.puts

        print_diff_table(diff_entries)
        @out.puts
        print_diff_padding_summary(diff_entries, packer, row_count)
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

        render_table(["Column", "Type", "Align", "Size", "Padding before"], rows)
      end

      def print_savings_summary(report, row_count)
        saved = report[:saved_bytes]
        pct   = report[:savings_pct]
        curr  = report[:current_size]
        opt   = report[:optimal_size]

        @out.puts "  #{PASTEL.bold("Padding analysis:")}"
        @out.puts "    Current row overhead (fixed cols + padding):  #{curr} bytes"
        @out.puts "    Optimal row overhead (fixed cols only):        #{opt} bytes"
        @out.puts "    #{PASTEL.yellow("Wasted padding:")}  #{PASTEL.bold("#{saved} bytes/row")}  (#{pct}%)"

        return unless row_count > 0

        total_mb = (saved * row_count) / (1024.0 * 1024.0)
        scale    = scale_label(total_mb)
        @out.puts "    At #{format_count(row_count)} rows:  #{PASTEL.bold("~#{scale} reclaimed")} by reordering columns"
      end

      def print_diff_table(diff_entries)
        @out.puts "  #{PASTEL.bold("Schema diff")}  " \
                  "(#{PASTEL.yellow("■")} type changed  " \
                  "#{PASTEL.cyan("■")} renamed  " \
                  "#{PASTEL.red("■")} dropped  " \
                  "#{PASTEL.green("■")} added)"
        @out.puts

        rows = diff_entries.map do |entry|
          colorize = STATUS_COLORS[entry.status]
          src_name = entry.source_column ? colorize.call(entry.source_column.name)         : PASTEL.dim("—")
          src_type = entry.source_column ? colorize.call(entry.source_column.display_type) : PASTEL.dim("—")
          tgt_name = entry.target_column ? colorize.call(entry.target_column.name)         : PASTEL.dim("—")
          tgt_type = entry.target_column ? colorize.call(entry.target_column.display_type) : PASTEL.dim("—")
          [src_name, src_type, tgt_name, tgt_type, colorize.call(entry.status_label)]
        end

        render_table(["Source column", "Source type", "Target column", "Target type", "Change"], rows)
      end

      def print_diff_padding_summary(diff_entries, packer, row_count)
        source_cols = diff_entries.reject(&:added?).map(&:source_column).compact
        target_cols = diff_entries.reject(&:dropped?).map(&:target_column).compact

        src_size    = packer.estimated_row_size(source_cols)
        tgt_size    = packer.estimated_row_size(target_cols)
        src_padding = packer.total_padding(source_cols)
        tgt_padding = packer.total_padding(target_cols)
        delta       = src_size - tgt_size
        delta_pct   = src_size > 0 ? (delta.to_f / src_size * 100).abs.round(1) : 0.0

        @out.puts "  #{PASTEL.bold("Row size comparison (fixed columns + padding):")}"
        @out.puts "    Source: #{src_size} bytes  (#{src_padding} bytes padding)"

        size_line = "    Target: #{tgt_size} bytes  (#{tgt_padding} bytes padding)"
        if delta > 0
          @out.puts size_line + "  #{PASTEL.green("▼ #{delta} bytes smaller  (#{delta_pct}%)")}"
        elsif delta < 0
          @out.puts size_line + "  #{PASTEL.yellow("▲ #{delta.abs} bytes larger  (#{delta_pct}%)")}"
        else
          @out.puts size_line + "  (no change)"
        end

        return unless row_count > 0 && delta != 0

        total_mb = (delta.abs * row_count) / (1024.0 * 1024.0)
        verb     = delta > 0 ? "saved" : "added"
        @out.puts "    At #{format_count(row_count)} rows:  #{PASTEL.bold("~#{scale_label(total_mb)} #{verb}")}"
      end

      def render_table(headers, rows)
        table    = TTY::Table.new(header: headers, rows: rows)
        rendered = table.render(:unicode, padding: [0, 1]) do |r|
          r.border.separator = :each_row
        end
        rendered.each_line { @out.puts "  #{_1.chomp}" }
      end

      def scale_label(mb)
        mb >= 1024 ? "#{(mb / 1024).round(1)} GB" : "#{mb.round(1)} MB"
      end

      def format_count(n)
        n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      end
    end
  end
end

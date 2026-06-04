# frozen_string_literal: true

require "pastel"

module Pcrd
  module Output
    class PreflightPrinter
      PASTEL = Pastel.new

      ICONS = {
        pass: PASTEL.green("✓"),
        fail: PASTEL.red("✗"),
        warn: PASTEL.yellow("⚠"),
        info: PASTEL.dim("·")
      }.freeze

      def initialize(output: $stdout)
        @out = output
      end

      def print(result)
        @out.puts
        @out.puts PASTEL.bold("Preflight check")
        @out.puts PASTEL.dim("─" * 70)
        @out.puts

        result.items.each { |item| print_item(item) }

        @out.puts
        print_ddl_section(result.ddl_map) if result.ddl_map.any?
        print_estimate_section(result.row_counts, result) if result.row_counts.any?
        print_summary(result)
      end

      private

      def print_item(item)
        icon  = ICONS[item.status]
        label = case item.status
                when :fail then PASTEL.red(item.label)
                when :warn then PASTEL.yellow(item.label)
                else item.label
                end

        if item.detail&.include?("\n")
          @out.puts "  #{icon}  #{label}"
          item.detail.each_line do |line|
            @out.puts "     #{PASTEL.dim(line.chomp)}"
          end
        elsif item.detail
          @out.puts "  #{icon}  #{label}  #{PASTEL.dim(item.detail)}"
        else
          @out.puts "  #{icon}  #{label}"
        end
      end

      def print_ddl_section(ddl_map)
        @out.puts PASTEL.dim("─" * 70)
        @out.puts
        @out.puts PASTEL.bold("  Target DDL:")
        @out.puts
        ddl_map.each do |_table, ddl|
          ddl.each_line { @out.puts "    #{_1.chomp}" }
          @out.puts "    ;"
          @out.puts
        end
      end

      def print_estimate_section(row_counts, result)
        return unless result.respond_to?(:passed)

        batch_size = 10_000  # default; real config batch size used by migrate

        @out.puts PASTEL.dim("─" * 70)
        @out.puts
        @out.puts PASTEL.bold("  Estimated backfill:")
        @out.puts

        row_counts.each do |table, count|
          next if count.zero?

          batches   = (count.to_f / batch_size).ceil
          est_mins  = (batches / 100.0).round(1)
          est_label = est_mins >= 60 ? "~#{(est_mins / 60).round(1)}h" : "~#{est_mins}m"

          @out.puts "    #{table}:  #{format_count(count)} rows / " \
                    "#{format_count(batch_size)} per batch = " \
                    "#{format_count(batches)} batches  (#{est_label} at 100 batches/min)"
        end
        @out.puts
      end

      def print_summary(result)
        @out.puts PASTEL.dim("─" * 70)
        @out.puts

        fail_count = result.items.count { |i| i.status == :fail }
        warn_count = result.items.count { |i| i.status == :warn }

        if result.passed
          if warn_count > 0
            @out.puts "  #{PASTEL.green("✓")}  #{PASTEL.bold("All checks passed")}  " \
                      "(#{PASTEL.yellow("#{warn_count} warning(s)")} — review before proceeding)"
          else
            @out.puts "  #{PASTEL.green("✓")}  #{PASTEL.bold("All checks passed.")}"
          end
        else
          @out.puts "  #{PASTEL.red("✗")}  #{PASTEL.bold(PASTEL.red("#{fail_count} check(s) failed."))}  " \
                    "Fix the issue(s) above before running migrate."
        end
        @out.puts
      end

      def format_count(n)
        n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      end
    end
  end
end

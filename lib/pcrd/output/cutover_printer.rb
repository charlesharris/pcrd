# frozen_string_literal: true

require "pastel"

module Pcrd
  module Output
    class CutoverPrinter
      PASTEL = Pastel.new

      def initialize(output: $stdout)
        @out = output
      end

      def print(result)
        @out.puts
        @out.puts PASTEL.bold("Cutover report")
        @out.puts PASTEL.dim("─" * 70)
        @out.puts

        print_row_counts(result.row_counts)
        print_sequences(result.sequence_results)
        print_warnings(result.warnings)
        print_summary(result)
      end

      def print_verify(result)
        @out.puts
        @out.puts PASTEL.bold("Verify results")
        @out.puts PASTEL.dim("─" * 70)
        @out.puts

        result.tables.each do |t|
          src = t.source_count
          tgt = t.target_count

          if src.nil?
            @out.puts "  #{PASTEL.red("✗")}  #{t.table_name}  #{PASTEL.red(t.mismatches.first)}"
            next
          end

          if src == tgt
            suffix = t.mismatches.empty? ? "" : PASTEL.yellow("  (#{t.mismatches.length} spot-check mismatch(es))")
            @out.puts "  #{PASTEL.green("✓")}  #{t.table_name}  " \
                      "#{PASTEL.dim("#{format_count(src)} rows match")}#{suffix}"
          else
            @out.puts "  #{PASTEL.red("✗")}  #{t.table_name}  " \
                      "source=#{format_count(src)}  target=#{format_count(tgt)}  " \
                      "#{PASTEL.red("count mismatch")}"
          end
        end

        @out.puts
        if result.passed
          @out.puts "  #{PASTEL.green("✓")}  #{PASTEL.bold("All tables verified.")}"
        else
          @out.puts "  #{PASTEL.red("✗")}  #{PASTEL.bold(PASTEL.red("Verification failed."))}"
        end
        @out.puts
      end

      private

      def print_row_counts(row_counts)
        @out.puts "  #{PASTEL.bold("Row counts:")}"
        row_counts.each do |table, counts|
          src = counts[:source]
          tgt = counts[:target]

          if src == tgt
            @out.puts "    #{PASTEL.green("✓")}  #{table}  #{format_count(src)} rows"
          else
            @out.puts "    #{PASTEL.red("✗")}  #{table}  " \
                      "source=#{format_count(src)}  target=#{format_count(tgt)}  " \
                      "#{PASTEL.red("MISMATCH")}"
          end
        end
        @out.puts
      end

      def print_sequences(seq_results)
        return if seq_results.empty?

        @out.puts "  #{PASTEL.bold("Sequence advancement:")}"
        seq_results.each do |r|
          @out.puts "    #{PASTEL.green("✓")}  #{r.table_name}.#{r.column_name}  " \
                    "#{PASTEL.dim("setval(#{r.target_seq_name}, #{r.target_value})")}"
          @out.puts "         #{PASTEL.dim("source last_value=#{r.source_last_value}  " \
                    "source max=#{r.source_max_id}  buffer=+#{r.safety_buffer}")}"
        end
        @out.puts
      end

      def print_warnings(warnings)
        return if warnings.empty?

        warnings.each do |w|
          @out.puts "  #{PASTEL.yellow("⚠")}  #{PASTEL.yellow(w)}"
        end
        @out.puts
      end

      def print_summary(result)
        @out.puts PASTEL.dim("─" * 70)
        @out.puts

        if result.passed
          @out.puts "  #{PASTEL.green("✓")}  #{PASTEL.bold("Cutover complete.")}"
          @out.puts
          @out.puts "  #{PASTEL.bold("Next steps:")}"
          @out.puts "    1. Update DATABASE_URL to point at the target cluster"
          @out.puts "    2. Restart the application"
          @out.puts "    3. Run `pcrd verify` to confirm row counts"
          @out.puts "    4. End maintenance mode"
          @out.puts "    5. Run `pcrd cleanup` (days later, when confident)"
        else
          @out.puts "  #{PASTEL.red("✗")}  #{PASTEL.bold("Cutover check failed.")} " \
                    "Review the issues above before switching connection strings."
        end
        @out.puts
      end

      def format_count(n)
        return "?" if n.nil?
        n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      end
    end
  end
end

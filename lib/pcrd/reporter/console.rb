# frozen_string_literal: true

require "pastel"

module Pcrd
  # Progress reporting interface used by long-running orchestration so it does
  # not depend on Thor/CLI output directly. Implementations:
  #   Console — human-facing, colored
  #   Null    — silent (tests, automation)
  #
  # Contract:
  #   info(msg)     plain line
  #   success(msg)  line, styled as success
  #   warn(msg)     line, styled as a warning
  #   status(msg)   transient same-line update (carriage return, no newline)
  #   green(str)    -> styled inline string (for composing a status line)
  module Reporter
    class Console
      def initialize(out: $stdout)
        @out    = out
        @pastel = Pastel.new
      end

      def info(msg = "")
        @out.puts(msg)
      end

      def success(msg)
        @out.puts(@pastel.green(msg))
      end

      def warn(msg)
        @out.puts(@pastel.yellow(msg))
      end

      def status(msg)
        @out.print("\r#{msg}")
        @out.flush
      end

      def green(str)
        @pastel.green(str)
      end
    end
  end
end

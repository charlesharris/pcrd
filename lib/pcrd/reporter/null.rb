# frozen_string_literal: true

module Pcrd
  module Reporter
    # Silent reporter for tests and non-interactive automation.
    class Null
      def info(_msg = "");  end
      def success(_msg);    end
      def warn(_msg);       end
      def status(_msg);     end
      def green(str = "");  str; end
    end
  end
end

# frozen_string_literal: true

module Pcrd
  module Schema
    # Raised when a configured table is not present on the source.
    class TableNotFound < Pcrd::Error; end
  end
end

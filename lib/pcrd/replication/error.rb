# frozen_string_literal: true

module Pcrd
  module Replication
    # Raised when the WAL streaming consumer stops unexpectedly (e.g. the
    # replication connection drops or pgoutput parsing fails). Carries the
    # original error as #cause when available.
    class Error < StandardError; end
  end
end

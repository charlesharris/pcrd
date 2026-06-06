# frozen_string_literal: true

module Pcrd
  module Schema
    # Raised when replication/target setup cannot proceed safely — an existing
    # slot, a mismatched publication, or a target table that already exists.
    class SetupError < Pcrd::Error; end
  end
end

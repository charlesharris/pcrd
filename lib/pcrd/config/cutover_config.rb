# frozen_string_literal: true

module Pcrd
  module Config
    CutoverConfig = Data.define(:sequence_buffer, :lag_drain_timeout)
  end
end

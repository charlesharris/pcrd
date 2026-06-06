# frozen_string_literal: true

module Pcrd
  # Normalizes the options hash once at the boundary so commands can use symbol
  # keys consistently, instead of guarding every read with
  # `options["x"] || options[:"x"]`. Accepts Thor's string-keyed options, a
  # plain symbol hash, or nil.
  module Options
    module_function

    def normalize(opts)
      (opts || {}).to_h.transform_keys(&:to_sym)
    end
  end
end

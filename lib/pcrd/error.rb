# frozen_string_literal: true

module Pcrd
  # Base class for every error pcrd raises on purpose. Catching Pcrd::Error at
  # the CLI boundary turns expected failures into clean messages, while letting
  # genuinely unexpected errors (real bugs) surface with their backtrace.
  class Error < StandardError; end

  # Raised when a command is given a config that lacks something it needs
  # (e.g. no target connection, no tables).
  class ConfigError < Error; end
end

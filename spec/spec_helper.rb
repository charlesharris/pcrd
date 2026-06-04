# frozen_string_literal: true

require "pcrd"
require_relative "support/pg_helpers"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.order = :random
  config.warnings = true
end

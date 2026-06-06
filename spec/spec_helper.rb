# frozen_string_literal: true

require "pcrd"
require_relative "support/pg_helpers"

# Shared aliases for the verbose pgoutput/replication namespaces. Defined once
# here, outside any describe block, so they don't trigger "already initialized
# constant" warnings or leak as per-file top-level constants.
M   = Pcrd::Replication::Pgoutput::Messages
Txn = Pcrd::Replication::Consumer::Transaction

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.order = :random
  config.warnings = true
end

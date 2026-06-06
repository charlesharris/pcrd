# frozen_string_literal: true

require "pcrd"
require_relative "../support/pg_helpers"

RSpec.describe Pcrd::Connection::Pool, :integration do
  include PgHelpers

  def show(pool, name)
    pool.exec("SHOW #{name}")[0][name]
  end

  it "applies the conservative session settings to the live connection" do
    pool = described_class.new(test_source_config)

    expect(show(pool, "application_name")).to eq("pcrd")
    expect(show(pool, "lock_timeout")).to eq("5s")
    expect(show(pool, "statement_timeout")).to eq("0")
    # PostgreSQL normalizes 60s -> "1min" on display.
    expect(show(pool, "idle_in_transaction_session_timeout")).to eq("1min")
  ensure
    pool&.close
  end

  it "honors per-pool overrides" do
    pool = described_class.new(test_source_config, settings: { "application_name" => "pcrd-custom" })
    expect(show(pool, "application_name")).to eq("pcrd-custom")
  ensure
    pool&.close
  end
end

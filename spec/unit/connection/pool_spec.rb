# frozen_string_literal: true

require "spec_helper"

RSpec.describe Pcrd::Connection::Pool do
  let(:config) do
    Pcrd::Config::Connection.new(host: "h", port: 5432, database: "d", user: "u", password: nil)
  end

  describe "session settings" do
    it "applies conservative defaults" do
      settings = described_class.new(config).session_settings
      expect(settings["application_name"]).to eq("pcrd")
      expect(settings["lock_timeout"]).to eq("5s")
      expect(settings["idle_in_transaction_session_timeout"]).to eq("60s")
      expect(settings["statement_timeout"]).to eq("0") # backfill COPY must not be killed
    end

    it "merges overrides over the defaults" do
      pool = described_class.new(config, settings: { "lock_timeout" => "1s" })
      expect(pool.session_settings["lock_timeout"]).to eq("1s")
      expect(pool.session_settings["application_name"]).to eq("pcrd")
    end

    it "builds a libpq options string for the timeouts" do
      opts = described_class.new(config).session_options
      expect(opts).to include("-c lock_timeout=5s")
      expect(opts).to include("-c statement_timeout=0")
      expect(opts).to include("-c idle_in_transaction_session_timeout=60s")
    end

    it "excludes application_name from -c options (passed as a connect param)" do
      # A -c application_name is overridden by libpq's fallback_application_name.
      expect(described_class.new(config).session_options).not_to include("application_name")
    end
  end
end

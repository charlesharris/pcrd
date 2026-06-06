# frozen_string_literal: true

require "spec_helper"

RSpec.describe Pcrd::Error do
  it "is the base for every domain error so the CLI can catch them uniformly" do
    [
      Pcrd::ConfigError,
      Pcrd::Connection::Error,
      Pcrd::Replication::Error,
      Pcrd::Config::LoadError,
      Pcrd::Schema::TableNotFound,
      Pcrd::Schema::SetupError,
      Pcrd::Commands::Analyze::Error
    ].each do |klass|
      expect(klass.ancestors).to include(Pcrd::Error)
    end
  end

  it "does not catch unrelated runtime errors (real bugs surface)" do
    expect(RuntimeError.ancestors).not_to include(Pcrd::Error)
  end
end

# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe Pcrd::Reporter do
  describe Pcrd::Reporter::Console do
    let(:out) { StringIO.new }
    subject(:reporter) { described_class.new(out: out) }

    it "writes plain, success, and warning lines" do
      reporter.info("plain")
      reporter.success("done")
      reporter.warn("careful")
      expect(out.string).to include("plain", "done", "careful")
    end

    it "writes a transient status line with a carriage return and no newline" do
      reporter.status("  Lag: 0 B")
      expect(out.string).to start_with("\r")
      expect(out.string).not_to include("\n")
    end

    it "returns an inline-styled string from #green" do
      expect(reporter.green("x")).to include("x")
    end
  end

  describe Pcrd::Reporter::Null do
    subject(:reporter) { described_class.new }

    it "is silent and returns the string unchanged from #green" do
      expect { reporter.info("x"); reporter.success("y"); reporter.status("z") }.not_to output.to_stdout
      expect(reporter.green("x")).to eq("x")
    end
  end
end

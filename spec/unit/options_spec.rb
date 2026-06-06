# frozen_string_literal: true

require "spec_helper"

RSpec.describe Pcrd::Options do
  describe ".normalize" do
    it "symbolizes string keys" do
      expect(described_class.normalize("force-overwrite" => true)).to eq(:"force-overwrite" => true)
    end

    it "leaves symbol keys alone" do
      expect(described_class.normalize(resume: true)).to eq(resume: true)
    end

    it "treats nil as an empty hash" do
      expect(described_class.normalize(nil)).to eq({})
    end

    it "handles a Thor-style indifferent hash" do
      thor_like = { "sample-size" => 50 }
      expect(described_class.normalize(thor_like)[:"sample-size"]).to eq(50)
    end
  end
end

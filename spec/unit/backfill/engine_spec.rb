# frozen_string_literal: true

require "spec_helper"

RSpec.describe Pcrd::Backfill::Engine do
  describe ".throttle_delay" do
    it "returns 0 when unthrottled" do
      expect(described_class.throttle_delay(10_000, 100, nil)).to eq(0.0)
      expect(described_class.throttle_delay(10_000, 100, 0)).to eq(0.0)
    end

    it "returns the time needed to hold the cap, minus time already spent" do
      # 1000 rows at 1000 rows/s needs 1.0s; the batch took 0.5s → sleep 0.5s.
      expect(described_class.throttle_delay(1000, 500, 1000)).to eq(0.5)
    end

    it "returns 0 when the batch already ran slower than the cap" do
      expect(described_class.throttle_delay(1000, 2000, 1000)).to eq(0.0)
    end

    it "scales with batch size" do
      # 5000 rows at 1000 rows/s needs 5.0s; instantaneous batch → sleep 5.0s.
      expect(described_class.throttle_delay(5000, 0, 1000)).to eq(5.0)
    end
  end
end

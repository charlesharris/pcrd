# frozen_string_literal: true

require "pcrd"
require_relative "../support/pg_helpers"

RSpec.describe Pcrd::AdvisoryLock, :integration do
  include PgHelpers

  it "is exclusive across sessions for the same name" do
    pool_a = Pcrd::Connection::Pool.new(test_source_config)
    pool_b = Pcrd::Connection::Pool.new(test_source_config)
    lock_a = described_class.new(pool: pool_a, name: "spec_slot")
    lock_b = described_class.new(pool: pool_b, name: "spec_slot")

    expect(lock_a.try_acquire).to be(true)
    expect(lock_b.try_acquire).to be(false) # another session holds it

    lock_a.release
    expect(lock_b.try_acquire).to be(true) # released, now free
    lock_b.release
  ensure
    pool_a&.close
    pool_b&.close
  end

  it "does not block different names" do
    pool_a = Pcrd::Connection::Pool.new(test_source_config)
    pool_b = Pcrd::Connection::Pool.new(test_source_config)
    lock_a = described_class.new(pool: pool_a, name: "slot_one")
    lock_b = described_class.new(pool: pool_b, name: "slot_two")

    expect(lock_a.try_acquire).to be(true)
    expect(lock_b.try_acquire).to be(true)
  ensure
    lock_a&.release
    lock_b&.release
    pool_a&.close
    pool_b&.close
  end
end

# frozen_string_literal: true

require "spec_helper"

RSpec.describe Pcrd::Apply::Worker do
  # Records every transaction handed to #apply; optionally raises on one LSN.
  # Anonymous class kept in a let so it never leaks a top-level constant.
  let(:engine_class) do
    Class.new do
      attr_reader :applied

      def initialize(raise_on: nil)
        @applied  = []
        @raise_on = raise_on
        @mutex    = Mutex.new
      end

      def apply(txn)
        raise "apply boom" if txn.commit_lsn == @raise_on

        @mutex.synchronize { @applied << txn.commit_lsn }
      end
    end
  end

  def txn(lsn)
    Pcrd::Replication::Consumer::Transaction.new(begin_msg: nil, events: [], commit_lsn: lsn)
  end

  def wait_until(timeout: 2)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
  end

  it "drains queued transactions and acknowledges each via on_committed" do
    engine = engine_class.new
    queue  = Thread::Queue.new
    acked  = []
    worker = described_class.new(
      engine: engine, queue: queue,
      on_committed: ->(lsn) { acked << lsn }
    )

    worker.start
    queue.push(txn("0/10"))
    queue.push(txn("0/20"))

    wait_until { engine.applied.size == 2 }

    expect(engine.applied).to eq(["0/10", "0/20"])
    expect(acked).to eq(["0/10", "0/20"])
    expect(worker.last_applied_lsn).to eq("0/20")
    expect(worker.failed?).to be(false)
  ensure
    worker&.stop
  end

  it "drains whatever is still queued when stopped" do
    engine = engine_class.new
    queue  = Thread::Queue.new
    worker = described_class.new(engine: engine, queue: queue)

    worker.start
    20.times { |i| queue.push(txn("0/#{i}")) }
    worker.stop # must finish the backlog before returning

    expect(engine.applied.size).to eq(20)
  end

  it "records a fatal apply error and stops processing" do
    engine = engine_class.new(raise_on: "0/20")
    queue  = Thread::Queue.new
    worker = described_class.new(engine: engine, queue: queue)

    worker.start
    queue.push(txn("0/10"))
    queue.push(txn("0/20")) # blows up here
    queue.push(txn("0/30")) # must not be applied

    wait_until { worker.failed? }

    expect(worker.failed?).to be(true)
    expect(worker.error.message).to eq("apply boom")
    expect(engine.applied).to eq(["0/10"])
  ensure
    worker&.stop
  end
end

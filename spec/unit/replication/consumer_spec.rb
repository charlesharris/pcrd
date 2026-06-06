# frozen_string_literal: true

require "spec_helper"

RSpec.describe Pcrd::Replication::Consumer do
  # Minimal stand-in for Connection::Replication. The stream loop calls
  # open/start_replication once, then polls wait_readable + get_copy_data.
  class FakeRepl
    def initialize(on_get_copy_data:)
      @on_get_copy_data = on_get_copy_data
    end

    def open; end
    def start_replication(**); end
    def wait_readable(_timeout) = true
    def get_copy_data = @on_get_copy_data.call
    def put_copy_data(_msg); end
    def close; end
  end

  def build_consumer(repl)
    described_class.new(
      repl_conn: repl,
      parser:    Pcrd::Replication::Pgoutput::Parser.new,
      slot_name: "test_slot",
      pub_name:  "test_pub",
      start_lsn: "0/0"
    )
  end

  def wait_until(timeout: 2)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
  end

  describe "when the stream loop raises" do
    it "records the error, reports #failed?, and enqueues no sentinel" do
      repl     = FakeRepl.new(on_get_copy_data: -> { raise "stream blew up" })
      consumer = build_consumer(repl)

      consumer.start
      wait_until { consumer.failed? }

      expect(consumer.failed?).to be(true)
      expect(consumer.last_error).to be_a(RuntimeError)
      expect(consumer.last_error.message).to eq("stream blew up")
      expect(consumer.queue).to be_empty
    ensure
      consumer&.stop
    end
  end

  describe "when a TRUNCATE arrives for a published table" do
    # Wraps a pgoutput payload in an XLogData ('w') frame: 1 tag + 24-byte
    # header (wal_start, wal_end, ts) that the consumer strips before parsing.
    def xlog(payload)
      "w".b + ([0].pack("Q>") * 3) + payload.b
    end

    it "halts the consumer with a clear error instead of silently ignoring it" do
      truncate = "A#{[1].pack("N")}#{[0].pack("C")}#{[100].pack("N")}"
      frames   = [xlog(truncate)]
      repl     = FakeRepl.new(on_get_copy_data: -> { frames.shift })
      consumer = build_consumer(repl)

      consumer.start
      wait_until { consumer.failed? }

      expect(consumer.failed?).to be(true)
      expect(consumer.last_error).to be_a(Pcrd::Replication::Error)
      expect(consumer.last_error.message).to match(/TRUNCATE received/)
      expect(consumer.queue).to be_empty
    ensure
      consumer&.stop
    end
  end

  describe "when the stream is healthy but idle" do
    it "does not report #failed?" do
      # No data available: return nil so the loop falls through to keepalive.
      repl     = FakeRepl.new(on_get_copy_data: -> { nil })
      consumer = build_consumer(repl)

      consumer.start
      sleep 0.1

      expect(consumer.failed?).to be(false)
      expect(consumer.last_error).to be_nil
    ensure
      consumer&.stop
    end
  end
end

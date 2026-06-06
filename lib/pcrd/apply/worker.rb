# frozen_string_literal: true

module Pcrd
  module Apply
    # Drains buffered transactions from the WAL consumer queue and applies them
    # to the target, in its own thread, concurrently with backfill.
    #
    # This is what makes streaming run *alongside* the bulk copy instead of
    # after it: the consumer fills a bounded queue, this worker empties it, and
    # the source slot can keep advancing so WAL is not retained for the whole
    # backfill.
    #
    # Threading contract:
    #   - The Apply::Engine here MUST use a target connection that is not shared
    #     with backfill — a Connection::Client wraps a single PG connection and is
    #     not safe to use from two threads at once.
    #   - on_committed is invoked (on this thread) after each transaction is
    #     durably applied, with the commit LSN. Wire it to checkpoint + the
    #     consumer's LSN acknowledgement so WAL is only released after apply.
    #
    # Lifecycle:
    #   start            — launch the background thread
    #   stop             — drain whatever is already queued, then exit and join
    #   failed?/error    — surface a fatal apply error to the supervising thread
    #   last_applied_lsn — most recent commit LSN handed to on_committed
    class Worker
      POLL_INTERVAL = 0.05 # seconds to wait when the queue is momentarily empty

      def initialize(engine:, queue:, on_committed: nil)
        @engine       = engine
        @queue        = queue
        @on_committed = on_committed
        @stop         = false
        @mutex        = Mutex.new
        @error        = nil
        @last_lsn     = nil
        @thread       = nil
      end

      def start
        @thread = Thread.new { run_loop }
        self
      end

      # Signals the worker to finish: it keeps applying until the queue is
      # empty, then exits. Joins the thread before returning.
      def stop
        @mutex.synchronize { @stop = true }
        @thread&.join
      end

      def failed?
        @mutex.synchronize { !@error.nil? }
      end

      def last_applied_lsn
        @mutex.synchronize { @last_lsn }
      end

      attr_reader :error

      private

      def run_loop
        loop do
          txn = pop_nonblocking

          if txn
            process(txn)
          elsif stopped?
            break # stop requested and nothing left to drain
          else
            sleep POLL_INTERVAL
          end
        end
      rescue => e
        @mutex.synchronize { @error = e }
      end

      def process(txn)
        @engine.apply(txn)
        @on_committed&.call(txn.commit_lsn)
        @mutex.synchronize { @last_lsn = txn.commit_lsn }
      end

      def pop_nonblocking
        @queue.pop(true)
      rescue ThreadError
        nil
      end

      def stopped?
        @mutex.synchronize { @stop }
      end
    end
  end
end

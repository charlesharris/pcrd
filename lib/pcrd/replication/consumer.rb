# frozen_string_literal: true

module Pcrd
  module Replication
    # Streams WAL messages from a pgoutput logical replication slot and
    # buffers complete transactions onto a Thread::Queue for the apply engine.
    #
    # Protocol (inside each raw message from the server):
    #   0x77 ('w') — XLogData: 1 type + 8 wal_start + 8 wal_end + 8 ts + payload
    #   0x6B ('k') — Primary keepalive: 1 type + 8 wal_end + 8 ts + 1 reply_flag
    #
    # The consumer must respond to keepalives with a StandbyStatusUpdate ('r')
    # within wal_sender_timeout (default 60s) or the server drops the connection.
    #
    # Thread model:
    #   start       — launches a background thread that drives the stream loop
    #   stop        — signals the thread to exit cleanly after the current poll
    #   queue       — Thread::Queue; pop from the apply engine side
    #   advance_lsn — call from apply engine after each applied transaction
    class Consumer
      # A complete buffered transaction ready for the apply engine.
      Transaction = Data.define(:begin_msg, :events, :commit_lsn)

      XLOG_DATA          = 0x77
      KEEPALIVE          = 0x6B
      PG_EPOCH_OFFSET_US = 946_684_800 * 1_000_000
      KEEPALIVE_INTERVAL = 10   # seconds between proactive keepalives to server
      WAIT_TIMEOUT       = 1    # max seconds per wait_readable; limits stop latency

      # Backpressure cap. The queue holds at most this many buffered
      # transactions; once full, the stream loop stops reading new WAL (the
      # server's flow control kicks in) until the apply side drains it. This
      # bounds memory during a long backfill instead of letting the queue grow
      # without limit. Tuned via :max_queue.
      DEFAULT_MAX_QUEUE  = 10_000
      FULL_QUEUE_BACKOFF = 0.05 # seconds to wait between retries when full

      def initialize(repl_conn:, parser:, slot_name:, pub_name:, start_lsn: "0/0",
                     max_queue: DEFAULT_MAX_QUEUE)
        @repl      = repl_conn
        @parser    = parser
        @slot_name = slot_name
        @pub_name  = pub_name
        @start_lsn = start_lsn
        @queue     = SizedQueue.new(max_queue)
        @stop      = false
        @mutex     = Mutex.new
        @conf_lsn  = 0   # last applied LSN (int64); advanced by apply engine
        @last_received_lsn = nil # commit LSN of the most recently buffered txn
        @thread    = nil
      end

      attr_reader :queue, :parser, :last_error

      # Commit LSN of the most recent transaction buffered onto the queue, for
      # observability ("how far has streaming read?"). nil until the first txn.
      def last_received_lsn
        @mutex.synchronize { @last_received_lsn }
      end

      # Number of buffered transactions waiting to be applied (backpressure gauge).
      def queue_depth
        @queue.size
      end

      # Opens the replication connection and starts the background thread.
      def start
        @repl.open
        @repl.start_replication(slot_name: @slot_name, pub_name: @pub_name, start_lsn: @start_lsn)
        @thread = Thread.new { stream_loop }
        self
      end

      # Signals the consumer to stop after the current poll cycle.
      def stop
        @mutex.synchronize { @stop = true }
        @thread&.join(5)
        @repl.close
      end

      def stopped?
        @mutex.synchronize { @stop }
      end

      # True if the streaming thread exited because of an error. The apply
      # side polls this when the queue drains empty so a dead consumer
      # surfaces as a failure instead of looking like "caught up and idle".
      def failed?
        @mutex.synchronize { !@last_error.nil? }
      end

      # Called by the apply engine after a transaction has been applied.
      # Updates the LSN we report back to the server (WAL reclaim point).
      def advance_lsn(lsn_string)
        int = lsn_to_int(lsn_string)
        @mutex.synchronize { @conf_lsn = [@conf_lsn, int].max }
      end

      private

      def stream_loop
        @current_begin  = nil
        @current_events = []
        last_keepalive  = monotonic

        loop do
          # Short wait so stop! is noticed within WAIT_TIMEOUT seconds.
          break if stopped?

          if @repl.wait_readable(WAIT_TIMEOUT)
            # Drain all messages available right now in one pass.
            loop do
              raw = @repl.get_copy_data
              break if raw.nil? || raw == false
              dispatch(raw)
            end
          end

          # Send proactive keepalive if nothing has been received recently.
          if monotonic - last_keepalive >= KEEPALIVE_INTERVAL
            send_status
            last_keepalive = monotonic
          end
        end
      rescue => e
        # Record the failure and let the thread exit. We deliberately do NOT
        # enqueue anything: a malformed transaction here would be applied as a
        # no-op and its sentinel "LSN" checkpointed, hiding the failure. The
        # apply loop detects the dead consumer via #failed? once the queue
        # drains and raises Replication::Error.
        @mutex.synchronize { @last_error = e }
      end

      def dispatch(raw)
        tag = raw.getbyte(0)

        case tag
        when XLOG_DATA
          # Header: 1 tag + 8 wal_start + 8 wal_end + 8 ts = 25 bytes
          payload = raw.b[25..]
          handle_pgoutput(@parser.parse(payload))

        when KEEPALIVE
          # Bytes 1-8: wal_end; byte 17: reply_requested
          reply_needed = raw.getbyte(17) == 1
          send_status if reply_needed
        end
      end

      def handle_pgoutput(msg)
        case msg
        when Pgoutput::Messages::Begin
          @current_begin  = msg
          @current_events = []

        when Pgoutput::Messages::Insert,
             Pgoutput::Messages::Update,
             Pgoutput::Messages::Delete
          @current_events << msg

        when Pgoutput::Messages::Commit
          unless @current_events.empty?
            enqueue(Transaction.new(
              begin_msg:  @current_begin,
              events:     @current_events.dup,
              commit_lsn: msg.lsn
            ))
          end
          @current_begin  = nil
          @current_events = []

        when Pgoutput::Messages::Truncate
          reject_truncate(msg)

        # Relation and Type are cached by the parser; no action needed here.
        end
      end

      # pcrd does not replicate TRUNCATE: silently ignoring it would leave the
      # target diverged from the source with no signal. Halt loudly so the
      # operator can truncate the target deliberately and resume. The
      # publication only covers migrated tables, so any TRUNCATE is relevant.
      def reject_truncate(msg)
        names = msg.relation_ids.map do |id|
          (r = @parser.relation(id)) ? "#{r.namespace}.#{r.name}" : "oid:#{id}"
        end
        raise Error,
              "TRUNCATE received for #{names.join(", ")}. pcrd does not replicate " \
              "TRUNCATE; the target would silently diverge. Migration halted — " \
              "truncate the target manually if intended, then resume."
      end

      # Pushes a transaction onto the bounded queue. If the queue is full the
      # apply side is behind, so we wait — but keep answering the server with
      # keepalives so it does not drop us past wal_sender_timeout while we
      # apply backpressure. Returns early if stop is requested.
      def enqueue(txn)
        loop do
          return if stopped?

          begin
            @queue.push(txn, true) # non-blocking; raises ThreadError when full
            @mutex.synchronize { @last_received_lsn = txn.commit_lsn }
            return
          rescue ThreadError
            send_status
            sleep FULL_QUEUE_BACKOFF
          end
        end
      end

      # Sends a StandbyStatusUpdate to keep the connection alive and
      # tell the server which LSN we have confirmed applying.
      #   'r' tag + write_lsn (8) + flush_lsn (8) + apply_lsn (8) + ts (8) + reply (1)
      def send_status
        lsn = @mutex.synchronize { @conf_lsn }
        now = ((Time.now.to_f * 1_000_000).to_i - PG_EPOCH_OFFSET_US)
        msg = "r".b + [lsn, lsn, lsn, now, 0].pack("Q>Q>Q>q>C")
        @repl.put_copy_data(msg)
      rescue Connection::Error
        nil  # connection may be closing; ignore
      end

      def lsn_to_int(str)
        return 0 unless str&.include?("/")
        high, low = str.split("/").map { _1.to_i(16) }
        (high << 32) | low
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end

# frozen_string_literal: true

module Pcrd
  module Replication
    module Pgoutput
      # Errors raised by the parser.
      class ParseError < StandardError; end
      class UnknownMessage < ParseError; end

      # Decodes raw pgoutput binary messages into Messages::* structs.
      #
      # The parser is stateful: it maintains a relation cache so that
      # Insert/Update/Delete messages (which only carry a relation OID) can be
      # enriched with column names from the most recently seen Relation message
      # for that OID. Always feed the stream in LSN order; Relation messages
      # always arrive before the first DML for a table.
      #
      # Input: raw bytes starting at the pgoutput type tag (i.e. after stripping
      # the 25-byte XLogData header from the replication stream wrapper).
      #
      # PostgreSQL epoch reference: timestamps in pgoutput are microseconds
      # since 2000-01-01 00:00:00 UTC (not the Unix epoch).
      class Parser
        # Offset in seconds from Unix epoch (1970-01-01) to PG epoch (2000-01-01).
        PG_EPOCH_OFFSET = 946_684_800

        # pgoutput message type tags → handler method names.
        HANDLERS = {
          "B" => :decode_begin,
          "C" => :decode_commit,
          "R" => :decode_relation,
          "I" => :decode_insert,
          "U" => :decode_update,
          "D" => :decode_delete,
          "T" => :decode_type,
          "O" => :decode_origin,
          "A" => :decode_truncate,
          "M" => :decode_logical_message
        }.freeze

        def initialize
          @relations = {}  # OID → Messages::Relation
        end

        # Parse one raw pgoutput message payload.
        # Returns the appropriate Messages::* struct.
        def parse(data)
          cur = Cursor.new(data)
          tag = cur.read_char

          handler = HANDLERS[tag]
          raise UnknownMessage, "Unknown pgoutput tag: #{tag.inspect} (0x#{tag.ord.to_s(16)})" unless handler

          send(handler, cur)
        end

        # Expose the relation cache for testing and for the WAL consumer.
        def relation(oid)
          @relations[oid]
        end

        private

        # ── message decoders ────────────────────────────────────────────────

        def decode_begin(cur)
          Messages::Begin.new(
            lsn:         lsn_string(cur.read_uint64),
            commit_time: pg_time(cur.read_int64),
            xid:         cur.read_uint32
          )
        end

        def decode_commit(cur)
          Messages::Commit.new(
            flags:       cur.read_uint8,
            lsn:         lsn_string(cur.read_uint64),
            end_lsn:     lsn_string(cur.read_uint64),
            commit_time: pg_time(cur.read_int64)
          )
        end

        def decode_relation(cur)
          id               = cur.read_uint32
          namespace        = cur.read_string
          name             = cur.read_string
          replica_identity = cur.read_char
          col_count        = cur.read_uint16

          columns = col_count.times.map do
            Messages::RelationColumn.new(
              flags:         cur.read_uint8,
              name:          cur.read_string,
              type_id:       cur.read_uint32,
              type_modifier: cur.read_int32
            )
          end

          rel = Messages::Relation.new(
            id: id, namespace: namespace, name: name,
            replica_identity: replica_identity, columns: columns
          )
          @relations[id] = rel
          rel
        end

        def decode_type(cur)
          Messages::Type.new(
            id:        cur.read_uint32,
            namespace: cur.read_string,
            name:      cur.read_string
          )
        end

        def decode_insert(cur)
          relation_id = cur.read_uint32
          cur.read_char  # always 'N' (new tuple)
          Messages::Insert.new(
            relation_id: relation_id,
            new_tuple:   read_tuple(cur, relation_id)
          )
        end

        def decode_update(cur)
          relation_id = cur.read_uint32
          indicator   = cur.read_char  # 'K', 'O', or 'N'

          old_tuple = nil
          if indicator == "K" || indicator == "O"
            old_tuple = read_tuple(cur, relation_id)
            indicator = cur.read_char  # consume 'N'
          end
          # indicator is now 'N'

          Messages::Update.new(
            relation_id: relation_id,
            old_tuple:   old_tuple,
            new_tuple:   read_tuple(cur, relation_id)
          )
        end

        def decode_delete(cur)
          relation_id = cur.read_uint32
          cur.read_char  # 'K' or 'O'
          Messages::Delete.new(
            relation_id: relation_id,
            old_tuple:   read_tuple(cur, relation_id)
          )
        end

        def decode_origin(cur)
          Messages::Origin.new(
            lsn:  lsn_string(cur.read_uint64),
            name: cur.read_string
          )
        end

        def decode_truncate(cur)
          rel_count   = cur.read_uint32
          option_bits = cur.read_uint8
          rel_ids     = rel_count.times.map { cur.read_uint32 }
          Messages::Truncate.new(option_bits: option_bits, relation_ids: rel_ids)
        end

        def decode_logical_message(cur)
          flags       = cur.read_uint8
          lsn         = lsn_string(cur.read_uint64)
          prefix      = cur.read_string
          content_len = cur.read_uint32
          content     = cur.read_bytes(content_len)
          Messages::LogicalMessage.new(flags: flags, lsn: lsn, prefix: prefix, content: content)
        end

        # ── tuple data ──────────────────────────────────────────────────────

        # Reads TupleData and returns Hash<column_name, value>.
        # Uses the cached Relation to map column positions to names.
        def read_tuple(cur, relation_id)
          col_count = cur.read_uint16
          relation  = @relations[relation_id]

          # A DML message must be preceded by its Relation message in the stream.
          # If it is not, inventing positional names ("col_0", ...) would route
          # and apply garbage silently. Fail loudly instead so the consumer
          # surfaces a replication error rather than corrupting the target.
          unless relation
            raise ParseError,
                  "No cached Relation for OID #{relation_id}; cannot decode tuple. " \
                  "The Relation message was missed or the stream is out of order."
          end

          col_count.times.each_with_object({}) do |i, hash|
            col_kind = cur.read_char
            col_name = relation.columns[i]&.name || "col_#{i}"

            value = case col_kind
                    when "n" then nil        # SQL NULL
                    when "u" then :toast     # unchanged TOAST value
                    when "t"
                      len = cur.read_uint32
                      cur.read_bytes(len).then do |bytes|
                        bytes.encode("UTF-8", "binary", invalid: :replace, undef: :replace)
                      end
                    else
                      raise ParseError, "Unknown tuple column kind: #{col_kind.inspect}"
                    end

            hash[col_name] = value
          end
        end

        # ── helpers ─────────────────────────────────────────────────────────

        def lsn_string(int64)
          "%X/%X" % [int64 >> 32, int64 & 0xFFFF_FFFF]
        end

        def pg_time(microseconds)
          secs = PG_EPOCH_OFFSET + microseconds / 1_000_000
          usec = microseconds % 1_000_000
          Time.at(secs, usec, :microsecond).utc
        end

        # ── cursor (private byte reader) ─────────────────────────────────────

        # Sequential binary cursor. All integer reads are big-endian.
        # String reads consume until the next null byte.
        class Cursor
          def initialize(data)
            @data = data.b   # force binary encoding for safe byte ops
            @pos  = 0
          end

          def read_char
            c = @data[@pos]
            @pos += 1
            c
          end

          def read_uint8
            b = @data.getbyte(@pos)
            @pos += 1
            b
          end

          def read_int8
            b = @data[@pos, 1].unpack1("c")
            @pos += 1
            b
          end

          def read_uint16
            v = @data[@pos, 2].unpack1("n")
            @pos += 2
            v
          end

          def read_int16
            v = @data[@pos, 2].unpack1("s>")
            @pos += 2
            v
          end

          def read_uint32
            v = @data[@pos, 4].unpack1("N")
            @pos += 4
            v
          end

          def read_int32
            v = @data[@pos, 4].unpack1("l>")
            @pos += 4
            v
          end

          def read_uint64
            v = @data[@pos, 8].unpack1("Q>")
            @pos += 8
            v
          end

          def read_int64
            v = @data[@pos, 8].unpack1("q>")
            @pos += 8
            v
          end

          # Reads a null-terminated string. Returns UTF-8 (replacing bad bytes).
          def read_string
            null_pos = @data.index("\x00", @pos)
            raise ParseError, "Unterminated string at offset #{@pos}" unless null_pos

            bytes = @data[@pos, null_pos - @pos]
            @pos  = null_pos + 1
            bytes.encode("UTF-8", "binary", invalid: :replace, undef: :replace)
          end

          def read_bytes(n)
            bytes = @data[@pos, n]
            @pos += n
            bytes
          end

          def eof?
            @pos >= @data.bytesize
          end

          def pos
            @pos
          end
        end
        private_constant :Cursor
      end
    end
  end
end

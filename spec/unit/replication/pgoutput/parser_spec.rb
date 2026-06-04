# frozen_string_literal: true

require "pcrd"

# Binary fixtures are constructed from first principles using pack format strings
# that mirror the PostgreSQL pgoutput protocol specification exactly.
# This makes the tests self-documenting and avoids a dependency on a live database.
#
# Pack format reference (all integers are big-endian):
#   "C"  = uint8      "c"  = int8
#   "n"  = uint16     "s>" = int16
#   "N"  = uint32     "l>" = int32
#   "Q>" = uint64     "q>" = int64

RSpec.describe Pcrd::Replication::Pgoutput::Parser do
  subject(:parser) { described_class.new }

  M = Pcrd::Replication::Pgoutput::Messages

  # Null-terminated string helper
  def s(str) = str + "\x00"

  # PG epoch offset (seconds from 1970-01-01 to 2000-01-01)
  PG_EPOCH_OFFSET = 946_684_800

  # ── Begin ─────────────────────────────────────────────────────────────────

  describe "Begin message" do
    let(:lsn_int)    { 0x0000_0001_3FA2_C100 }
    let(:commit_us)  { 1_000_000 }   # 1 second after PG epoch
    let(:xid)        { 4321 }

    let(:bytes) do
      "B" +
        [lsn_int].pack("Q>") +
        [commit_us].pack("q>") +
        [xid].pack("N")
    end

    subject(:msg) { parser.parse(bytes) }

    it "returns a Begin struct" do
      expect(msg).to be_a(M::Begin)
    end

    it "decodes the LSN as hex string" do
      expect(msg.lsn).to eq "1/3FA2C100"
    end

    it "decodes commit_time as a UTC Time" do
      expected = Time.at(PG_EPOCH_OFFSET + 1).utc
      expect(msg.commit_time).to eq expected
    end

    it "decodes the XID" do
      expect(msg.xid).to eq 4321
    end
  end

  # ── Commit ────────────────────────────────────────────────────────────────

  describe "Commit message" do
    let(:bytes) do
      "C" +
        [0].pack("C") +            # flags = 0
        [0x100].pack("Q>") +       # commit LSN
        [0x200].pack("Q>") +       # end LSN
        [2_000_000].pack("q>")     # commit time (2s after PG epoch)
    end

    subject(:msg) { parser.parse(bytes) }

    it "returns a Commit struct" do
      expect(msg).to be_a(M::Commit)
    end

    it "decodes flags, lsn, end_lsn" do
      expect(msg.flags).to eq 0
      expect(msg.lsn).to eq "0/100"
      expect(msg.end_lsn).to eq "0/200"
    end

    it "decodes commit_time" do
      expect(msg.commit_time).to eq Time.at(PG_EPOCH_OFFSET + 2).utc
    end
  end

  # ── Relation ──────────────────────────────────────────────────────────────

  describe "Relation message" do
    let(:rel_oid)  { 12345 }

    let(:bytes) do
      "R" +
        [rel_oid].pack("N") +          # relation OID
        s("public") +                  # namespace
        s("listings") +                # table name
        "d" +                          # replica identity = DEFAULT
        [2].pack("n") +                # 2 columns
        # column 0: id (part of replica identity)
        [1].pack("C") +                # flags = 1 (key column)
        s("id") +
        [23].pack("N") +               # int4 OID
        [-1].pack("l>") +              # no type modifier
        # column 1: name (not in replica identity)
        [0].pack("C") +                # flags = 0
        s("name") +
        [25].pack("N") +               # text OID
        [-1].pack("l>")
    end

    subject(:msg) { parser.parse(bytes) }

    it "returns a Relation struct" do
      expect(msg).to be_a(M::Relation)
    end

    it "decodes OID, namespace, table name, and replica identity" do
      expect(msg.id).to eq 12345
      expect(msg.namespace).to eq "public"
      expect(msg.name).to eq "listings"
      expect(msg.replica_identity).to eq "d"
    end

    it "decodes both columns" do
      expect(msg.columns.length).to eq 2
    end

    it "decodes the key column (flags = 1)" do
      col = msg.columns[0]
      expect(col.name).to eq "id"
      expect(col.flags).to eq 1
      expect(col.type_id).to eq 23
      expect(col.type_modifier).to eq(-1)
    end

    it "decodes a non-key column" do
      col = msg.columns[1]
      expect(col.name).to eq "name"
      expect(col.flags).to eq 0
    end

    it "caches the relation by OID" do
      parser.parse(bytes)
      expect(parser.relation(12345)).to be_a(M::Relation)
      expect(parser.relation(12345).name).to eq "listings"
    end
  end

  # ── Insert (with prior Relation) ──────────────────────────────────────────

  describe "Insert message" do
    let(:rel_oid) { 99 }

    before do
      # Feed Relation first so parser knows the column layout
      rel_bytes = "R" +
        [rel_oid].pack("N") +
        s("public") + s("users") + "d" +
        [2].pack("n") +
        [1].pack("C") + s("id") + [23].pack("N") + [-1].pack("l>") +
        [0].pack("C") + s("email") + [25].pack("N") + [-1].pack("l>")
      parser.parse(rel_bytes)
    end

    let(:bytes) do
      # Encode column values as TupleData
      id_bytes    = "42"
      email_bytes = "alice@example.com"

      "I" +
        [rel_oid].pack("N") +
        "N" +                            # new tuple indicator
        [2].pack("n") +                  # 2 columns
        "t" + [id_bytes.bytesize].pack("N") + id_bytes +
        "t" + [email_bytes.bytesize].pack("N") + email_bytes
    end

    subject(:msg) { parser.parse(bytes) }

    it "returns an Insert struct" do
      expect(msg).to be_a(M::Insert)
    end

    it "has the correct relation_id" do
      expect(msg.relation_id).to eq rel_oid
    end

    it "decodes column values by name" do
      expect(msg.new_tuple["id"]).to eq "42"
      expect(msg.new_tuple["email"]).to eq "alice@example.com"
    end
  end

  # ── Insert with NULL ──────────────────────────────────────────────────────

  describe "Insert with a NULL column" do
    let(:rel_oid) { 77 }

    before do
      rel_bytes = "R" + [rel_oid].pack("N") + s("public") + s("t") + "d" +
        [2].pack("n") +
        [1].pack("C") + s("id") + [23].pack("N") + [-1].pack("l>") +
        [0].pack("C") + s("notes") + [25].pack("N") + [-1].pack("l>")
      parser.parse(rel_bytes)
    end

    let(:bytes) do
      "I" + [rel_oid].pack("N") + "N" +
        [2].pack("n") +
        "t" + [1].pack("N") + "7" +
        "n"   # NULL for notes
    end

    it "sets NULL columns to nil" do
      msg = parser.parse(bytes)
      expect(msg.new_tuple["id"]).to eq "7"
      expect(msg.new_tuple["notes"]).to be_nil
    end
  end

  # ── Insert with unchanged TOAST ───────────────────────────────────────────

  describe "Insert with an unchanged TOAST value" do
    let(:rel_oid) { 55 }

    before do
      rel_bytes = "R" + [rel_oid].pack("N") + s("public") + s("t") + "d" +
        [2].pack("n") +
        [1].pack("C") + s("id") + [23].pack("N") + [-1].pack("l>") +
        [0].pack("C") + s("big_text") + [25].pack("N") + [-1].pack("l>")
      parser.parse(rel_bytes)
    end

    let(:bytes) do
      "I" + [rel_oid].pack("N") + "N" +
        [2].pack("n") +
        "t" + [1].pack("N") + "1" +
        "u"   # unchanged TOAST
    end

    it "sets unchanged TOAST values to :toast" do
      msg = parser.parse(bytes)
      expect(msg.new_tuple["big_text"]).to eq :toast
    end
  end

  # ── Update (no old tuple) ─────────────────────────────────────────────────

  describe "Update message (DEFAULT replica identity, no old tuple)" do
    let(:rel_oid) { 88 }

    before do
      rel_bytes = "R" + [rel_oid].pack("N") + s("public") + s("items") + "d" +
        [2].pack("n") +
        [1].pack("C") + s("id") + [23].pack("N") + [-1].pack("l>") +
        [0].pack("C") + s("val") + [25].pack("N") + [-1].pack("l>")
      parser.parse(rel_bytes)
    end

    let(:bytes) do
      "U" + [rel_oid].pack("N") +
        "N" +  # no old tuple indicator — straight to new tuple
        [2].pack("n") +
        "t" + [2].pack("N") + "42" +
        "t" + [3].pack("N") + "new"
    end

    subject(:msg) { parser.parse(bytes) }

    it "returns an Update struct" do
      expect(msg).to be_a(M::Update)
    end

    it "has nil old_tuple when there is no old tuple" do
      expect(msg.old_tuple).to be_nil
    end

    it "decodes the new tuple" do
      expect(msg.new_tuple["id"]).to eq "42"
      expect(msg.new_tuple["val"]).to eq "new"
    end
  end

  # ── Update (FULL replica identity, with old tuple) ────────────────────────

  describe "Update message with old tuple (FULL replica identity)" do
    let(:rel_oid) { 33 }

    before do
      rel_bytes = "R" + [rel_oid].pack("N") + s("public") + s("items") + "f" +
        [2].pack("n") +
        [1].pack("C") + s("id") + [23].pack("N") + [-1].pack("l>") +
        [0].pack("C") + s("val") + [25].pack("N") + [-1].pack("l>")
      parser.parse(rel_bytes)
    end

    let(:bytes) do
      "U" + [rel_oid].pack("N") +
        "O" +  # old tuple follows
        [2].pack("n") +
        "t" + [2].pack("N") + "42" +
        "t" + [3].pack("N") + "old" +
        "N" +  # new tuple follows
        [2].pack("n") +
        "t" + [2].pack("N") + "42" +
        "t" + [3].pack("N") + "new"
    end

    subject(:msg) { parser.parse(bytes) }

    it "decodes old_tuple" do
      expect(msg.old_tuple["val"]).to eq "old"
    end

    it "decodes new_tuple" do
      expect(msg.new_tuple["val"]).to eq "new"
    end
  end

  # ── Delete ────────────────────────────────────────────────────────────────

  describe "Delete message" do
    let(:rel_oid) { 44 }

    before do
      rel_bytes = "R" + [rel_oid].pack("N") + s("public") + s("items") + "d" +
        [1].pack("n") +
        [1].pack("C") + s("id") + [23].pack("N") + [-1].pack("l>")
      parser.parse(rel_bytes)
    end

    let(:bytes) do
      "D" + [rel_oid].pack("N") +
        "K" +  # key tuple
        [1].pack("n") +
        "t" + [3].pack("N") + "999"
    end

    subject(:msg) { parser.parse(bytes) }

    it "returns a Delete struct" do
      expect(msg).to be_a(M::Delete)
    end

    it "decodes the old (key) tuple" do
      expect(msg.old_tuple["id"]).to eq "999"
    end
  end

  # ── Type ──────────────────────────────────────────────────────────────────

  describe "Type message" do
    let(:bytes) do
      "T" +
        [16384].pack("N") +    # custom type OID
        s("public") +
        s("my_enum")
    end

    subject(:msg) { parser.parse(bytes) }

    it "returns a Type struct" do
      expect(msg).to be_a(M::Type)
    end

    it "decodes OID, namespace, name" do
      expect(msg.id).to eq 16384
      expect(msg.namespace).to eq "public"
      expect(msg.name).to eq "my_enum"
    end
  end

  # ── Origin ────────────────────────────────────────────────────────────────

  describe "Origin message" do
    let(:bytes) { "O" + [0x500].pack("Q>") + s("my_origin") }

    it "returns an Origin struct with lsn and name" do
      msg = parser.parse(bytes)
      expect(msg).to be_a(M::Origin)
      expect(msg.lsn).to eq "0/500"
      expect(msg.name).to eq "my_origin"
    end
  end

  # ── Truncate ──────────────────────────────────────────────────────────────

  describe "Truncate message" do
    let(:bytes) do
      "A" +
        [2].pack("N") +     # 2 relations
        [3].pack("C") +     # option_bits: CASCADE | RESTART_IDENTITY
        [100].pack("N") +   # relation OID 1
        [200].pack("N")     # relation OID 2
    end

    subject(:msg) { parser.parse(bytes) }

    it "returns a Truncate struct" do
      expect(msg).to be_a(M::Truncate)
    end

    it "decodes option_bits and relation_ids" do
      expect(msg.option_bits).to eq 3
      expect(msg.relation_ids).to eq [100, 200]
    end
  end

  # ── Logical message (PG14+) ───────────────────────────────────────────────

  describe "LogicalMessage (M tag)" do
    let(:content) { "hello".b }
    let(:bytes) do
      "M" +
        [1].pack("C") +            # flags = 1 (transactional)
        [0x300].pack("Q>") +       # LSN
        s("my_app") +              # prefix
        [content.bytesize].pack("N") +
        content
    end

    subject(:msg) { parser.parse(bytes) }

    it "returns a LogicalMessage struct" do
      expect(msg).to be_a(M::LogicalMessage)
    end

    it "decodes all fields" do
      expect(msg.flags).to eq 1
      expect(msg.lsn).to eq "0/300"
      expect(msg.prefix).to eq "my_app"
      expect(msg.content).to eq "hello".b
    end
  end

  # ── Error handling ────────────────────────────────────────────────────────

  describe "unknown message tag" do
    it "raises UnknownMessage" do
      expect { parser.parse("Z" + "\x00" * 4) }
        .to raise_error(Pcrd::Replication::Pgoutput::UnknownMessage, /tag: "Z"/)
    end
  end

  # ── LSN formatting ────────────────────────────────────────────────────────

  describe "LSN formatting" do
    it "formats a zero LSN as 0/0" do
      bytes = "B" + [0].pack("Q>") + [0].pack("q>") + [0].pack("N")
      expect(parser.parse(bytes).lsn).to eq "0/0"
    end

    it "formats a high-word LSN correctly" do
      # 0x0000000100000000 = 1/0
      bytes = "B" + [0x1_0000_0000].pack("Q>") + [0].pack("q>") + [0].pack("N")
      expect(parser.parse(bytes).lsn).to eq "1/0"
    end

    it "formats a typical LSN like 1/3FA2C100" do
      lsn = (1 << 32) | 0x3FA2C100
      bytes = "B" + [lsn].pack("Q>") + [0].pack("q>") + [0].pack("N")
      expect(parser.parse(bytes).lsn).to eq "1/3FA2C100"
    end
  end

  # ── Timestamp ────────────────────────────────────────────────────────────

  describe "timestamp decoding" do
    it "maps 0 microseconds to 2000-01-01 00:00:00 UTC (PG epoch)" do
      bytes = "B" + [0].pack("Q>") + [0].pack("q>") + [0].pack("N")
      expect(parser.parse(bytes).commit_time).to eq Time.utc(2000, 1, 1)
    end

    it "maps 1_000_000 microseconds to 2000-01-01 00:00:01 UTC" do
      bytes = "B" + [0].pack("Q>") + [1_000_000].pack("q>") + [0].pack("N")
      expect(parser.parse(bytes).commit_time).to eq Time.utc(2000, 1, 1, 0, 0, 1)
    end

    it "preserves microsecond precision" do
      bytes = "B" + [0].pack("Q>") + [1_500_000].pack("q>") + [0].pack("N")
      t = parser.parse(bytes).commit_time
      expect(t.usec).to eq 500_000
    end
  end

  # ── Column-name fallback when Relation not in cache ───────────────────────

  describe "tuple with no cached Relation" do
    it "falls back to positional column names (col_0, col_1)" do
      # Insert without a preceding Relation message
      bytes = "I" + [999].pack("N") + "N" +
        [2].pack("n") +
        "t" + [1].pack("N") + "a" +
        "t" + [1].pack("N") + "b"
      msg = parser.parse(bytes)
      expect(msg.new_tuple.keys).to eq %w[col_0 col_1]
    end
  end
end

# frozen_string_literal: true

require "pcrd"

RSpec.describe Pcrd::Connection::Replication do
  let(:config) do
    Pcrd::Config::Connection.new(host: "h", port: 5432, database: "d", user: "u", password: nil)
  end

  subject(:repl) { described_class.new(config) }

  # validate_slot_name!/validate_lsn! run before any libpq call, so these
  # exercise the guards without a live replication connection.
  describe "#start_replication token validation" do
    it "rejects a slot name with illegal characters before touching the wire" do
      expect { repl.start_replication(slot_name: "bad-slot!", pub_name: "p") }
        .to raise_error(Pcrd::Connection::Error, /Invalid replication slot name/)
    end

    it "rejects an uppercase slot name" do
      expect { repl.start_replication(slot_name: "MySlot", pub_name: "p") }
        .to raise_error(Pcrd::Connection::Error, /Invalid replication slot name/)
    end

    it "rejects an over-long slot name" do
      expect { repl.start_replication(slot_name: "a" * 64, pub_name: "p") }
        .to raise_error(Pcrd::Connection::Error, /Invalid replication slot name/)
    end

    it "rejects a malformed start LSN" do
      expect { repl.start_replication(slot_name: "good_slot", pub_name: "p", start_lsn: "not-an-lsn") }
        .to raise_error(Pcrd::Connection::Error, /Invalid start LSN/)
    end

    it "passes validation for a valid slot/LSN and escapes the publication name" do
      fake = instance_double(PG::Connection)
      allow(fake).to receive(:send_query)
      allow(fake).to receive(:get_result)
      repl.instance_variable_set(:@conn, fake)

      repl.start_replication(slot_name: "pcrd_slot_1", pub_name: "p's pub", start_lsn: "1A/3FA2C100")

      expect(fake).to have_received(:send_query)
        .with(a_string_matching(%r{START_REPLICATION SLOT pcrd_slot_1 LOGICAL 1A/3FA2C100}))
      expect(fake).to have_received(:send_query)
        .with(a_string_matching(/publication_names 'p''s pub'/))
    end
  end
end

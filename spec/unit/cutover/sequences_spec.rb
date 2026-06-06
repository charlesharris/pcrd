# frozen_string_literal: true

require "pcrd"

RSpec.describe Pcrd::Cutover::Sequences do
  def make_pool(exec_results: {}, quote_results: {})
    pool = instance_double("Pcrd::Connection::Client")

    allow(pool).to receive(:exec) do |sql, params = []|
      key = sql.strip.split.first(3).join(" ").downcase
      mock_result = exec_results[key] || exec_results[sql.strip] || double("PGResult", to_a: [], ntuples: 0)
      mock_result
    end

    allow(pool).to receive(:quote_ident) { |name| "\"#{name}\"" }
    pool
  end

  describe "#advance" do
    context "when the table has no owned sequences" do
      it "returns an empty array" do
        source = make_pool(exec_results: {
          "select a.attname" => double("PGResult", each_with_object: {})
        })
        target = make_pool

        # seq discovery returns nothing
        allow(source).to receive(:exec).and_return(double("r", each_with_object: {}, to_a: []))

        seqs = described_class.new(source_pool: source, target_pool: target)
        expect(seqs.advance(["orders"])).to eq []
      end
    end
  end

  describe "SequenceResult" do
    it "is a Data.define struct with the expected fields" do
      r = Pcrd::Cutover::Sequences::SequenceResult.new(
        table_name: "t", column_name: "id",
        source_seq_name: "public.t_id_seq", target_seq_name: "public.t_id_seq",
        source_last_value: 1000, source_max_id: 999,
        target_value: 2000, safety_buffer: 1000
      )
      expect(r.target_value).to eq 2000
      expect(r.safety_buffer).to eq 1000
    end
  end
end

# frozen_string_literal: true

require "spec_helper"

RSpec.describe Pcrd::Sql do
  describe ".quote_ident" do
    it "leaves a safe lowercase identifier bare" do
      expect(described_class.quote_ident("user_id")).to eq("user_id")
      expect(described_class.quote_ident("_x9")).to eq("_x9")
    end

    it "quotes a mixed-case identifier (would otherwise fold to lowercase)" do
      expect(described_class.quote_ident("MyColumn")).to eq('"MyColumn"')
    end

    it "quotes a reserved word" do
      expect(described_class.quote_ident("order")).to eq('"order"')
      expect(described_class.quote_ident("select")).to eq('"select"')
    end

    it "quotes identifiers with spaces or special characters" do
      expect(described_class.quote_ident("weird name")).to eq('"weird name"')
      expect(described_class.quote_ident("a-b")).to eq('"a-b"')
    end

    it "escapes embedded double quotes" do
      expect(described_class.quote_ident('a"b')).to eq('"a""b"')
    end

    it "accepts symbols" do
      expect(described_class.quote_ident(:label)).to eq("label")
    end
  end

  describe ".quote_table" do
    it "defaults to the public schema" do
      expect(described_class.quote_table("things")).to eq("public.things")
    end

    it "qualifies with a non-public schema" do
      expect(described_class.quote_table("things", schema: "billing")).to eq("billing.things")
    end

    it "quotes each part independently when needed" do
      expect(described_class.quote_table("Orders", schema: "My Schema"))
        .to eq('"My Schema"."Orders"')
    end
  end

  describe ".quote_columns" do
    it "joins quoted columns with commas" do
      expect(described_class.quote_columns(%w[id order name])).to eq('id, "order", name')
    end
  end
end

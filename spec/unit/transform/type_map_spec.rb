# frozen_string_literal: true

require "pcrd"

RSpec.describe Pcrd::Transform::TypeMap do
  describe ".cast_safety" do
    # ── always-safe widening casts ──────────────────────────────────────────
    context "integer widening" do
      it { expect(described_class.cast_safety("int2", "integer")).to eq :always_safe }
      it { expect(described_class.cast_safety("int2", "bigint")).to  eq :always_safe }
      it { expect(described_class.cast_safety("int4", "bigint")).to  eq :always_safe }
      it { expect(described_class.cast_safety("int4", "int8")).to    eq :always_safe }
    end

    context "float widening" do
      it { expect(described_class.cast_safety("float4", "double precision")).to eq :always_safe }
      it { expect(described_class.cast_safety("int4",   "real")).to            eq :always_safe }
      it { expect(described_class.cast_safety("int8",   "float8")).to          eq :always_safe }
    end

    context "numeric widening" do
      it { expect(described_class.cast_safety("int4",   "numeric")).to         eq :always_safe }
      it { expect(described_class.cast_safety("int8",   "numeric")).to         eq :always_safe }
    end

    context "timestamp widening" do
      it { expect(described_class.cast_safety("date",      "timestamp")).to    eq :always_safe }
      it { expect(described_class.cast_safety("date",      "timestamptz")).to  eq :always_safe }
      it { expect(described_class.cast_safety("timestamp", "timestamptz")).to  eq :always_safe }
    end

    context "string widening" do
      it { expect(described_class.cast_safety("varchar", "text")).to           eq :always_safe }
      it { expect(described_class.cast_safety("bpchar",  "text")).to           eq :always_safe }
    end

    # ── no-op (same type) ───────────────────────────────────────────────────
    context "no-op casts" do
      it { expect(described_class.cast_safety("int4",      "integer")).to      eq :no_op }
      it { expect(described_class.cast_safety("int8",      "bigint")).to       eq :no_op }
      it { expect(described_class.cast_safety("bool",      "boolean")).to      eq :no_op }
      it { expect(described_class.cast_safety("timestamp", "timestamp")).to    eq :no_op }
      it { expect(described_class.cast_safety("text",      "text")).to         eq :no_op }
    end

    # ── validated (may lose data) ───────────────────────────────────────────
    context "narrowing integer casts" do
      it { expect(described_class.cast_safety("int8", "integer")).to           eq :validated }
      it { expect(described_class.cast_safety("int8", "smallint")).to          eq :validated }
      it { expect(described_class.cast_safety("int4", "smallint")).to          eq :validated }
    end

    context "float precision loss" do
      it { expect(described_class.cast_safety("float8", "real")).to            eq :validated }
    end

    context "timezone stripping" do
      it { expect(described_class.cast_safety("timestamptz", "timestamp")).to  eq :validated }
    end

    context "text to varchar (length constraint)" do
      it { expect(described_class.cast_safety("text",    "varchar(255)")).to   eq :validated }
      it { expect(described_class.cast_safety("varchar", "varchar(10)")).to    eq :validated }
    end

    context "numeric to integer (truncation)" do
      it { expect(described_class.cast_safety("numeric", "int8")).to           eq :validated }
      it { expect(described_class.cast_safety("numeric", "int4")).to           eq :validated }
    end

    # ── unsupported ─────────────────────────────────────────────────────────
    context "unsupported casts" do
      it { expect(described_class.cast_safety("bytea",  "text")).to            eq :unsupported }
      it { expect(described_class.cast_safety("json",   "int4")).to            eq :unsupported }
      it { expect(described_class.cast_safety("bool",   "int4")).to            eq :unsupported }
    end
  end

  describe ".validated_rule" do
    it "returns a rule for int8 → int4" do
      rule = described_class.validated_rule("int8", "integer")
      expect(rule).not_to be_nil
      expect(rule[:from]).to eq "int8"
      expect(rule[:warn_only]).to be false
    end

    it "returns a warn-only rule for float8 → float4" do
      rule = described_class.validated_rule("float8", "real")
      expect(rule[:warn_only]).to be true
      expect(rule[:check_expr]).to be_nil
    end

    it "returns nil for always-safe casts" do
      expect(described_class.validated_rule("int4", "bigint")).to be_nil
    end
  end

  describe ".extract_length" do
    it "extracts N from varchar(N)" do
      expect(described_class.extract_length("varchar(255)")).to eq 255
    end

    it "extracts N from character varying(N)" do
      expect(described_class.extract_length("character varying(100)")).to eq 100
    end

    it "returns nil for types without a length parameter" do
      expect(described_class.extract_length("text")).to be_nil
      expect(described_class.extract_length("bigint")).to be_nil
    end
  end

  describe ".known_target?" do
    it { expect(described_class.known_target?("bigint")).to     be true }
    it { expect(described_class.known_target?("varchar(100)")).to be true }
    it { expect(described_class.known_target?("numeric(10,2)")).to be true }
    it { expect(described_class.known_target?("funkytype")).to  be false }
  end
end

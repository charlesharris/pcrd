# frozen_string_literal: true

require "pcrd"
require_relative "../support/pg_helpers"

RSpec.describe Pcrd::Schema::Reader, :integration do
  subject(:reader) { described_class.new(source_pool) }

  MIXED_TABLE_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_test_mixed (
      id          integer          NOT NULL,
      active      boolean          NOT NULL DEFAULT true,
      score       smallint,
      created_at  timestamp        NOT NULL DEFAULT now(),
      price       double precision,
      label       varchar(100),
      notes       text,
      PRIMARY KEY (id)
    )
  SQL

  around do |example|
    with_table(source_pool, MIXED_TABLE_DDL, table_name: "pcrd_test_mixed") { example.run }
  end

  describe "#read" do
    subject(:columns) { reader.read("pcrd_test_mixed") }

    it "returns one Column per table column" do
      expect(columns.length).to eq 7
    end

    it "preserves definition order" do
      expect(columns.map(&:name)).to eq %w[id active score created_at price label notes]
    end

    it "assigns correct alignment for integer (4-byte)" do
      id_col = columns.find { |c| c.name == "id" }
      expect(id_col.alignment).to eq 4
      expect(id_col.fixed_size).to eq 4
    end

    it "assigns correct alignment for boolean (1-byte)" do
      active_col = columns.find { |c| c.name == "active" }
      expect(active_col.alignment).to eq 1
      expect(active_col.fixed_size).to eq 1
    end

    it "assigns correct alignment for smallint (2-byte)" do
      score_col = columns.find { |c| c.name == "score" }
      expect(score_col.alignment).to eq 2
      expect(score_col.fixed_size).to eq 2
    end

    it "assigns correct alignment for timestamp (8-byte)" do
      ts_col = columns.find { |c| c.name == "created_at" }
      expect(ts_col.alignment).to eq 8
      expect(ts_col.fixed_size).to eq 8
    end

    it "marks variable-length columns with nil fixed_size" do
      label_col = columns.find { |c| c.name == "label" }
      notes_col = columns.find { |c| c.name == "notes" }
      expect(label_col.fixed_size).to be_nil
      expect(notes_col.fixed_size).to be_nil
    end

    it "marks nullable columns correctly" do
      expect(columns.find { |c| c.name == "id"     }.nullable).to be false
      expect(columns.find { |c| c.name == "score"  }.nullable).to be true
    end

    it "captures default expression" do
      active_col = columns.find { |c| c.name == "active" }
      expect(active_col.default_expr).to eq "true"
    end

    it "raises an error for a non-existent table" do
      expect { reader.read("no_such_table_xyz") }.to raise_error(RuntimeError, /not found/)
    end
  end

  describe "#table_exists?" do
    it "returns true for an existing table" do
      expect(reader.table_exists?("pcrd_test_mixed")).to be true
    end

    it "returns false for a non-existent table" do
      expect(reader.table_exists?("no_such_table_xyz")).to be false
    end
  end

  describe "#primary_key_columns" do
    it "returns the primary key column names" do
      expect(reader.primary_key_columns("pcrd_test_mixed")).to eq ["id"]
    end
  end

  describe "#estimated_row_count" do
    it "returns an integer (may be 0 on a fresh table)" do
      expect(reader.estimated_row_count("pcrd_test_mixed")).to be_a Integer
    end
  end
end

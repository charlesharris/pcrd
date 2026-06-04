# frozen_string_literal: true

require "pcrd"

RSpec.describe Pcrd::Transform::RowTransformer do
  def source_col(name)
    Pcrd::Schema::Column.new(
      attnum: 1, name: name, type_name: "int4", formatted_type: "integer",
      alignment: 4, fixed_size: 4, nullable: false, default_expr: nil
    )
  end

  def col_spec(type: nil, rename: nil, drop: false)
    Pcrd::Config::ColumnSpec.new(type: type, rename: rename, drop: drop)
  end

  def table_config(columns: {}, add_columns: [])
    Pcrd::Config::Table.new(
      name: "test", optimize_column_order: false,
      columns: columns, add_columns: add_columns
    )
  end

  let(:source_columns) { %w[id active price status notes].map { source_col(_1) } }

  subject(:transformer) do
    described_class.new(table_config(columns: spec_columns), source_columns)
  end

  context "with no spec changes" do
    let(:spec_columns) { {} }

    it "passes all columns through unchanged" do
      row = { "id" => "1", "active" => "t", "price" => "9.99", "status" => "open", "notes" => "hi" }
      expect(transformer.transform(row)).to eq row
    end

    it "returns all source column names as target column names" do
      expect(transformer.target_column_names).to eq %w[id active price status notes]
    end
  end

  context "with a rename" do
    let(:spec_columns) { { "price" => col_spec(rename: "list_price") } }

    it "uses the new key name in the output" do
      row = { "id" => "1", "active" => "t", "price" => "100.00", "status" => "ok", "notes" => "" }
      result = transformer.transform(row)
      expect(result).to have_key("list_price")
      expect(result).not_to have_key("price")
      expect(result["list_price"]).to eq "100.00"
    end

    it "reflects the rename in target_column_names" do
      expect(transformer.target_column_names).to include("list_price")
      expect(transformer.target_column_names).not_to include("price")
    end
  end

  context "with a dropped column" do
    let(:spec_columns) { { "notes" => col_spec(drop: true) } }

    it "excludes the dropped column from output" do
      row = { "id" => "1", "active" => "t", "price" => "1.00", "status" => "x", "notes" => "drop me" }
      expect(transformer.transform(row)).not_to have_key("notes")
    end

    it "excludes the dropped column from target_column_names" do
      expect(transformer.target_column_names).not_to include("notes")
    end

    it "preserves remaining columns" do
      row = { "id" => "1", "active" => "t", "price" => "1.00", "status" => "x", "notes" => "n" }
      result = transformer.transform(row)
      expect(result.keys).to eq %w[id active price status]
    end
  end

  context "with a type change only" do
    let(:spec_columns) { { "id" => col_spec(type: "bigint") } }

    it "passes the value through unchanged (PG handles the cast on INSERT)" do
      row = { "id" => "42", "active" => "t", "price" => "1.00", "status" => "x", "notes" => "" }
      expect(transformer.transform(row)["id"]).to eq "42"
    end
  end

  context "with combined rename and type change" do
    let(:spec_columns) { { "price" => col_spec(type: "numeric(18,4)", rename: "list_price_precise") } }

    it "renames and passes the value through" do
      row = { "id" => "1", "active" => "t", "price" => "99.50", "status" => "ok", "notes" => "" }
      result = transformer.transform(row)
      expect(result["list_price_precise"]).to eq "99.50"
      expect(result).not_to have_key("price")
    end
  end

  context "with multiple changes" do
    let(:spec_columns) do
      {
        "id"     => col_spec(type: "bigint"),
        "active" => col_spec(rename: "is_active"),
        "notes"  => col_spec(drop: true)
      }
    end

    it "applies all transformations in one pass" do
      row = { "id" => "7", "active" => "f", "price" => "5.00", "status" => "x", "notes" => "nope" }
      result = transformer.transform(row)
      expect(result.keys).to eq %w[id is_active price status]
      expect(result["id"]).to eq "7"
      expect(result["is_active"]).to eq "f"
    end
  end

  describe "#source_column_names_kept" do
    let(:spec_columns) { { "notes" => col_spec(drop: true) } }

    it "lists source names in order, excluding dropped columns" do
      expect(transformer.source_column_names_kept).to eq %w[id active price status]
    end
  end

  context "column ordering in output" do
    let(:spec_columns) { { "active" => col_spec(rename: "is_active"), "notes" => col_spec(drop: true) } }

    it "preserves the source column order in the output (minus drops)" do
      row = { "id" => "1", "active" => "t", "price" => "1", "status" => "x", "notes" => "n" }
      expect(transformer.transform(row).keys).to eq %w[id is_active price status]
    end
  end
end

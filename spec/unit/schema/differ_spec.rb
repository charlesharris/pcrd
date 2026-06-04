# frozen_string_literal: true

require "pcrd"

RSpec.describe Pcrd::Schema::Differ do
  subject(:differ) { described_class.new }

  # Helper: build a minimal Schema::Column
  def col(name, type_name: "int4", formatted_type: "integer", alignment: 4, fixed_size: 4)
    Pcrd::Schema::Column.new(
      attnum: 1, name: name, type_name: type_name,
      formatted_type: formatted_type, alignment: alignment,
      fixed_size: fixed_size, nullable: true, default_expr: nil
    )
  end

  def bool_col(name) = col(name, type_name: "bool", formatted_type: "boolean", alignment: 1, fixed_size: 1)
  def text_col(name) = col(name, type_name: "text", formatted_type: "text", alignment: 4, fixed_size: nil)
  def bigint_col(name) = col(name, type_name: "int8", formatted_type: "bigint", alignment: 8, fixed_size: 8)

  def column_spec(type: nil, rename: nil, drop: false)
    Pcrd::Config::ColumnSpec.new(type: type, rename: rename, drop: drop)
  end

  def add_col(name:, type:, default: nil)
    Pcrd::Config::AddColumn.new(name: name, type: type, default: default)
  end

  def table_config(columns: {}, add_columns: [])
    Pcrd::Config::Table.new(
      name: "test",
      optimize_column_order: false,
      columns: columns,
      add_columns: add_columns
    )
  end

  describe "#diff (synthesis mode)" do
    context "with no spec" do
      it "marks all columns as unchanged" do
        entries = differ.diff(source_columns: [col("id"), col("name")], table_config: nil)
        expect(entries.map(&:status)).to all eq :unchanged
      end

      it "synthesizes target columns that mirror the source" do
        entries = differ.diff(source_columns: [col("id")], table_config: nil)
        expect(entries.first.target_column.name).to eq "id"
        expect(entries.first.target_column.type_name).to eq "int4"
      end
    end

    context "with a type change" do
      let(:spec) { table_config(columns: { "id" => column_spec(type: "bigint") }) }

      it "marks the column as type_changed" do
        entries = differ.diff(source_columns: [col("id")], table_config: spec)
        expect(entries.first.status).to eq :type_changed
      end

      it "builds the target column with the new type" do
        entries = differ.diff(source_columns: [col("id")], table_config: spec)
        expect(entries.first.target_column.formatted_type).to eq "bigint"
        expect(entries.first.target_column.alignment).to eq 8
        expect(entries.first.target_column.fixed_size).to eq 8
      end
    end

    context "with a rename" do
      let(:spec) { table_config(columns: { "old_name" => column_spec(rename: "new_name") }) }

      it "marks the column as renamed" do
        entries = differ.diff(source_columns: [col("old_name")], table_config: spec)
        expect(entries.first.status).to eq :renamed
      end

      it "uses the new name on the target column" do
        entries = differ.diff(source_columns: [col("old_name")], table_config: spec)
        expect(entries.first.target_column.name).to eq "new_name"
        expect(entries.first.source_column.name).to eq "old_name"
      end
    end

    context "with a combined rename and type change" do
      let(:spec) do
        table_config(columns: {
          "price" => column_spec(type: "numeric(18,4)", rename: "price_precise")
        })
      end

      it "marks the column as type_and_renamed" do
        entries = differ.diff(source_columns: [col("price")], table_config: spec)
        expect(entries.first.status).to eq :type_and_renamed
      end

      it "applies both the new name and new type" do
        entries = differ.diff(source_columns: [col("price")], table_config: spec)
        tgt = entries.first.target_column
        expect(tgt.name).to eq "price_precise"
        expect(tgt.formatted_type).to eq "numeric(18,4)"
      end
    end

    context "with a dropped column" do
      let(:spec) { table_config(columns: { "old_col" => column_spec(drop: true) }) }

      it "marks the column as dropped" do
        entries = differ.diff(source_columns: [col("old_col")], table_config: spec)
        expect(entries.first.status).to eq :dropped
      end

      it "has a nil target_column for dropped entries" do
        entries = differ.diff(source_columns: [col("old_col")], table_config: spec)
        expect(entries.first.target_column).to be_nil
      end
    end

    context "with added columns" do
      let(:spec) { table_config(add_columns: [add_col(name: "updated_at", type: "timestamptz")]) }

      it "appends an :added entry at the end" do
        entries = differ.diff(source_columns: [col("id")], table_config: spec)
        expect(entries.last.status).to eq :added
      end

      it "has a nil source_column for added entries" do
        entries = differ.diff(source_columns: [col("id")], table_config: spec)
        expect(entries.last.source_column).to be_nil
      end

      it "builds the target column from the add spec" do
        entries = differ.diff(source_columns: [col("id")], table_config: spec)
        tgt = entries.last.target_column
        expect(tgt.name).to eq "updated_at"
        expect(tgt.formatted_type).to eq "timestamptz"
        expect(tgt.alignment).to eq 8
      end
    end

    context "with a realistic multi-change spec" do
      let(:source_cols) do
        [col("id"), col("active", type_name: "bool", formatted_type: "boolean", alignment: 1, fixed_size: 1),
         col("list_price"), col("status_code"), col("legacy_notes", type_name: "text", formatted_type: "text", alignment: 4, fixed_size: nil)]
      end

      let(:spec) do
        table_config(
          columns: {
            "id"           => column_spec(type: "bigint"),
            "list_price"   => column_spec(type: "numeric(18,4)", rename: "list_price_precise"),
            "status_code"  => column_spec(rename: "listing_status"),
            "legacy_notes" => column_spec(drop: true)
          },
          add_columns: [add_col(name: "updated_at", type: "timestamptz")]
        )
      end

      it "produces the correct statuses in order" do
        entries = differ.diff(source_columns: source_cols, table_config: spec)
        expect(entries.map(&:status)).to eq [
          :type_changed,
          :unchanged,
          :type_and_renamed,
          :renamed,
          :dropped,
          :added
        ]
      end

      it "preserves source column order with added columns last" do
        entries = differ.diff(source_columns: source_cols, table_config: spec)
        source_names = entries.reject(&:added?).map(&:source_name)
        expect(source_names.compact).to eq %w[id active list_price status_code legacy_notes]
        expect(entries.last.status).to eq :added
      end
    end
  end

  describe "#diff (real-target mode)" do
    let(:source) { [col("id"), col("name"), col("old_col")] }
    let(:target) { [bigint_col("id"), col("name"), col("new_col")] }

    it "matches columns by name when no spec is given" do
      entries = differ.diff(source_columns: source, table_config: nil, target_columns: target)
      matched = entries.find { |e| e.source_name == "id" }
      expect(matched.status).to eq :type_changed
    end

    it "marks unmatched source columns as dropped" do
      entries = differ.diff(source_columns: source, table_config: nil, target_columns: target)
      expect(entries.find { |e| e.source_name == "old_col" }.status).to eq :dropped
    end

    it "marks unmatched target columns as added" do
      entries = differ.diff(source_columns: source, table_config: nil, target_columns: target)
      expect(entries.find { |e| e.target_name == "new_col" }.status).to eq :added
    end
  end

  describe "#target_columns_from_diff" do
    it "returns only non-dropped target columns" do
      entries = differ.diff(
        source_columns: [col("id"), col("old")],
        table_config: table_config(columns: { "old" => column_spec(drop: true) })
      )
      cols = differ.target_columns_from_diff(entries)
      expect(cols.map(&:name)).to eq ["id"]
    end
  end

  describe "DiffEntry helpers" do
    it "reports renamed? correctly" do
      entry = Pcrd::Schema::DiffEntry.new(
        status: :renamed, source_column: col("a"), target_column: col("b")
      )
      expect(entry.renamed?).to be true
      expect(entry.type_changed?).to be false
    end

    it "reports type_changed? for :type_and_renamed" do
      entry = Pcrd::Schema::DiffEntry.new(
        status: :type_and_renamed, source_column: col("a"), target_column: col("b")
      )
      expect(entry.type_changed?).to be true
      expect(entry.renamed?).to be true
    end
  end
end

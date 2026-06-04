# frozen_string_literal: true

require "pcrd"

RSpec.describe Pcrd::Schema::Packer do
  subject(:packer) { described_class.new }

  def col(name, alignment:, fixed_size:)
    Pcrd::Schema::Column.new(
      attnum: 1, name: name, type_name: "test", formatted_type: "test",
      alignment: alignment, fixed_size: fixed_size,
      nullable: true, default_expr: nil
    )
  end

  let(:bigint)   { col("ts",      alignment: 8, fixed_size: 8)  }
  let(:int)      { col("qty",     alignment: 4, fixed_size: 4)  }
  let(:smallint) { col("smol",    alignment: 2, fixed_size: 2)  }
  let(:bool)     { col("flag",    alignment: 1, fixed_size: 1)  }
  let(:text)     { col("note",    alignment: 4, fixed_size: nil) }

  describe "#optimize" do
    it "puts 8-byte columns first, then 4, 2, 1, then variable" do
      cols = [bool, text, smallint, int, bigint]
      expect(packer.optimize(cols).map(&:name)).to eq %w[ts qty smol flag note]
    end

    it "preserves relative order within each alignment tier" do
      a = col("a", alignment: 4, fixed_size: 4)
      b = col("b", alignment: 4, fixed_size: 4)
      c = col("c", alignment: 4, fixed_size: 4)
      expect(packer.optimize([c, a, b]).map(&:name)).to eq %w[c a b]
    end

    it "places all variable-length columns last" do
      t1 = col("t1", alignment: 4, fixed_size: nil)
      t2 = col("t2", alignment: 4, fixed_size: nil)
      expect(packer.optimize([t1, int, t2]).map(&:name)).to eq %w[qty t1 t2]
    end

    it "returns empty array for empty input" do
      expect(packer.optimize([])).to eq []
    end
  end

  describe "#layout" do
    it "assigns offset 0 to the first column with no padding" do
      entries = packer.layout([bigint])
      expect(entries.first.offset).to eq 0
      expect(entries.first.padding_before).to eq 0
    end

    it "inserts padding before a 2-byte column following a 1-byte column" do
      # After bool at offset 0 (1 byte), smallint needs 2-byte align → 1 byte padding
      entries = packer.layout([bool, smallint])
      expect(entries[1].padding_before).to eq 1
      expect(entries[1].offset).to eq 2
    end

    it "inserts padding before an 8-byte column following mixed smaller columns" do
      # bool(1) + smallint(2) + 1pad = offset 4; then bigint needs 8-byte: 4 bytes padding
      entries = packer.layout([bool, smallint, bigint])
      bigint_entry = entries.last
      expect(bigint_entry.padding_before).to eq 4
      expect(bigint_entry.offset).to eq 8
    end

    it "inserts no padding between consecutive same-alignment columns" do
      a = col("a", alignment: 8, fixed_size: 8)
      b = col("b", alignment: 8, fixed_size: 8)
      entries = packer.layout([a, b])
      expect(entries[1].padding_before).to eq 0
      expect(entries[1].offset).to eq 8
    end

    it "aligns variable-length column header to 4 bytes" do
      # After bool (offset 1), varlena needs 4-byte align → 3 bytes padding
      entries = packer.layout([bool, text])
      expect(entries[1].padding_before).to eq 3
    end
  end

  describe "#estimated_row_size" do
    it "returns 0 for empty column list" do
      expect(packer.estimated_row_size([])).to eq 0
    end

    it "returns the column size for a single fixed column with no padding" do
      expect(packer.estimated_row_size([bigint])).to eq 8
    end

    it "includes padding bytes in the estimate" do
      # bool(1) + 1pad + smallint(2) = 4
      expect(packer.estimated_row_size([bool, smallint])).to eq 4
    end

    it "is less for optimally ordered columns" do
      badly_ordered  = [bool, bigint, bool, bigint]
      well_ordered   = packer.optimize(badly_ordered)
      expect(packer.estimated_row_size(well_ordered))
        .to be < packer.estimated_row_size(badly_ordered)
    end
  end

  describe "#total_padding" do
    it "returns 0 for a perfectly packed layout" do
      cols = [bigint, bigint, int, int, smallint, bool, bool]
      expect(packer.total_padding(packer.optimize(cols))).to eq 0
    end

    it "counts all padding bytes for a poorly ordered layout" do
      # bool(1) then bigint: 7 bytes padding
      expect(packer.total_padding([bool, bigint])).to eq 7
    end
  end

  describe "#report" do
    let(:mixed_cols) { [bool, bigint, smallint, int, text] }

    it "returns a hash with current and optimal columns" do
      r = packer.report(mixed_cols)
      expect(r[:current_columns]).to eq mixed_cols
      expect(r[:optimal_columns]).to eq packer.optimize(mixed_cols)
    end

    it "reports saved bytes > 0 for a poorly ordered column set" do
      expect(packer.report(mixed_cols)[:saved_bytes]).to be > 0
    end

    it "reports already_optimal: true when columns are already in optimal order" do
      optimal = packer.optimize(mixed_cols)
      expect(packer.report(optimal)[:already_optimal]).to be true
    end

    it "reports savings_pct as a float between 0 and 100" do
      pct = packer.report(mixed_cols)[:savings_pct]
      expect(pct).to be_between(0.0, 100.0)
    end
  end
end

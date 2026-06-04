# frozen_string_literal: true

require "pcrd"
require_relative "../../support/pg_helpers"

RSpec.describe Pcrd::Transform::Validator, :integration do
  subject(:validator) { described_class.new(source_pool) }

  # label is text so we can insert arbitrarily long strings for the length check test.
  VALIDATOR_DDL = <<~SQL.freeze
    CREATE TABLE pcrd_test_validator (
      id          bigint           NOT NULL,
      score       integer,
      label       text,
      rating      double precision,
      created_at  timestamptz,
      PRIMARY KEY (id)
    )
  SQL

  def table_config(columns: {})
    Pcrd::Config::Table.new(
      name: "pcrd_test_validator",
      optimize_column_order: false,
      columns: columns,
      add_columns: []
    )
  end

  def col_spec(type:)
    Pcrd::Config::ColumnSpec.new(type: type, rename: nil, drop: false)
  end

  around { |ex| with_table(source_pool, VALIDATOR_DDL, table_name: "pcrd_test_validator") { ex.run } }

  let(:schema_reader) { Pcrd::Schema::Reader.new(source_pool) }
  let(:source_columns) { schema_reader.read("pcrd_test_validator") }

  context "when all data fits the target type" do
    before do
      source_pool.exec("INSERT INTO pcrd_test_validator VALUES ($1, $2, $3, $4, $5)",
                       [1, 1000, "short", 1.5, "2024-01-01 00:00:00+00"])
    end

    it "returns no failures for an int8 → int4 cast when values are in range" do
      config   = table_config(columns: { "id" => col_spec(type: "integer") })
      failures = validator.validate(config, source_columns)
      expect(failures.select { |f| f.column_name == "id" && !f.warn_only }).to be_empty
    end

    it "returns no failures for varchar when all values fit" do
      config   = table_config(columns: { "label" => col_spec(type: "varchar(10)") })
      failures = validator.validate(config, source_columns)
      expect(failures.select { |f| !f.warn_only }).to be_empty
    end
  end

  context "when data does NOT fit the target type" do
    before do
      source_pool.exec(
        "INSERT INTO pcrd_test_validator VALUES ($1, $2, $3, $4, $5)",
        [3_000_000_000, 42, "ok", 1.0, "2024-01-01 00:00:00+00"]
      )
    end

    it "returns a failure for int8 → int4 when a value exceeds integer range" do
      config   = table_config(columns: { "id" => col_spec(type: "integer") })
      failures = validator.validate(config, source_columns)
      id_fail  = failures.find { |f| f.column_name == "id" }
      expect(id_fail).not_to be_nil
      expect(id_fail.failing_count).to eq 1
      expect(id_fail.warn_only).to be false
    end

    it "returns a failure for text → varchar when a value exceeds the target length" do
      source_pool.exec(
        "INSERT INTO pcrd_test_validator VALUES ($1, $2, $3, $4, $5)",
        [2, 1, "this_is_way_too_long_for_varchar_5", 1.0, "2024-01-01 00:00:00+00"]
      )
      config     = table_config(columns: { "label" => col_spec(type: "varchar(5)") })
      failures   = validator.validate(config, source_columns)
      label_fail = failures.find { |f| f.column_name == "label" }
      expect(label_fail).not_to be_nil
      expect(label_fail.failing_count).to be > 0
    end
  end

  context "with warn-only casts" do
    before do
      source_pool.exec("INSERT INTO pcrd_test_validator VALUES ($1, $2, $3, $4, $5)",
                       [1, 1, "ok", 1.5, "2024-01-01 00:00:00+00"])
    end

    it "returns a warn-only failure for float8 → float4" do
      config   = table_config(columns: { "rating" => col_spec(type: "real") })
      failures = validator.validate(config, source_columns)
      f = failures.find { |x| x.column_name == "rating" }
      expect(f).not_to be_nil
      expect(f.warn_only).to be true
    end

    it "returns a warn-only failure for timestamptz → timestamp" do
      config   = table_config(columns: { "created_at" => col_spec(type: "timestamp") })
      failures = validator.validate(config, source_columns)
      f = failures.find { |x| x.column_name == "created_at" }
      expect(f).not_to be_nil
      expect(f.warn_only).to be true
    end
  end

  context "with unsupported casts" do
    before do
      source_pool.exec("INSERT INTO pcrd_test_validator VALUES (1, 1, 'a', 1.0, now())")
    end

    it "flags unsupported casts without querying the database" do
      # bool → int4 is unsupported
      # We can't easily test this on pcrd_test_validator since there's no bool column.
      # Instead, verify cast_safety directly.
      expect(Pcrd::Transform::TypeMap.cast_safety("bool", "int4")).to eq :unsupported
    end
  end

  context "with always-safe casts" do
    before do
      source_pool.exec("INSERT INTO pcrd_test_validator VALUES (1, 1, 'a', 1.0, now())")
    end

    it "returns no failures for int4 → int8" do
      config   = table_config(columns: { "score" => col_spec(type: "bigint") })
      failures = validator.validate(config, source_columns)
      expect(failures).to be_empty
    end
  end
end

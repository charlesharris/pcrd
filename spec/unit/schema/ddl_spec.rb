# frozen_string_literal: true

require "pcrd"

RSpec.describe Pcrd::Schema::DDL do
  def col(name, type_name: "int4", formatted_type: "integer",
          alignment: 4, fixed_size: 4, nullable: true, default_expr: nil)
    Pcrd::Schema::Column.new(
      attnum: 1, name: name, type_name: type_name,
      formatted_type: formatted_type, alignment: alignment,
      fixed_size: fixed_size, nullable: nullable, default_expr: default_expr
    )
  end

  def table_config(name: "things", columns: {}, add_columns: [], optimize: false)
    Pcrd::Config::Table.new(
      name: name, optimize_column_order: optimize,
      columns: columns, add_columns: add_columns
    )
  end

  def col_spec(type: nil, rename: nil, drop: false)
    Pcrd::Config::ColumnSpec.new(type: type, rename: rename, drop: drop)
  end

  def add_col(name:, type:, default: nil)
    Pcrd::Config::AddColumn.new(name: name, type: type, default: default)
  end

  let(:source_columns) do
    [
      col("id",         type_name: "int4",  formatted_type: "integer",   nullable: false),
      col("active",     type_name: "bool",  formatted_type: "boolean",   alignment: 1, fixed_size: 1),
      col("price",      type_name: "int4",  formatted_type: "integer",   nullable: false),
      col("notes",      type_name: "text",  formatted_type: "text",      alignment: 4, fixed_size: nil),
      col("created_at", type_name: "timestamp", formatted_type: "timestamp", alignment: 8, fixed_size: 8,
          default_expr: "now()"),
    ]
  end

  describe ".generate" do
    context "with no spec changes" do
      subject(:ddl) do
        described_class.generate(source_columns: source_columns,
                                 table_config: table_config)
      end

      it "produces a CREATE TABLE statement" do
        expect(ddl).to start_with("CREATE TABLE public.things (")
        expect(ddl).to end_with(")")
      end

      it "includes all source columns" do
        %w[id active price notes created_at].each do |name|
          expect(ddl).to include(name)
        end
      end

      it "marks NOT NULL columns" do
        expect(ddl).to match(/id\s+integer\s+NOT NULL/)
        expect(ddl).to match(/price\s+integer\s+NOT NULL/)
      end

      it "includes DEFAULT expressions" do
        expect(ddl).to include("DEFAULT now()")
      end

      it "omits DEFAULT for nullable columns without a default" do
        expect(ddl).not_to match(/active.*DEFAULT/)
      end
    end

    context "with a type change" do
      subject(:ddl) do
        described_class.generate(
          source_columns: source_columns,
          table_config: table_config(columns: { "id" => col_spec(type: "bigint") })
        )
      end

      it "uses the target type for the changed column" do
        expect(ddl).to match(/id\s+bigint/)
      end

      it "keeps NOT NULL from the source column" do
        expect(ddl).to match(/id\s+bigint\s+NOT NULL/)
      end
    end

    context "with a rename" do
      subject(:ddl) do
        described_class.generate(
          source_columns: source_columns,
          table_config: table_config(columns: { "notes" => col_spec(rename: "description") })
        )
      end

      it "uses the new column name" do
        expect(ddl).to include("description")
        expect(ddl).not_to match(/\bnotes\b/)
      end
    end

    context "with a dropped column" do
      subject(:ddl) do
        described_class.generate(
          source_columns: source_columns,
          table_config: table_config(columns: { "notes" => col_spec(drop: true) })
        )
      end

      it "excludes the dropped column" do
        expect(ddl).not_to match(/\bnotes\b/)
      end
    end

    context "with an added column" do
      subject(:ddl) do
        described_class.generate(
          source_columns: source_columns,
          table_config: table_config(
            add_columns: [add_col(name: "updated_at", type: "timestamptz", default: "now()")]
          )
        )
      end

      it "includes the added column" do
        expect(ddl).to include("updated_at")
      end

      it "includes the default for the added column" do
        expect(ddl).to include("DEFAULT now()")
      end
    end

    context "with a PRIMARY KEY" do
      subject(:ddl) do
        described_class.generate(
          source_columns: source_columns,
          table_config: table_config,
          primary_key_columns: ["id"]
        )
      end

      it "includes a PRIMARY KEY constraint" do
        expect(ddl).to include("PRIMARY KEY (id)")
      end
    end

    context "with a renamed PRIMARY KEY column" do
      subject(:ddl) do
        described_class.generate(
          source_columns: source_columns,
          table_config: table_config(columns: { "id" => col_spec(rename: "listing_id") }),
          primary_key_columns: ["id"]
        )
      end

      it "uses the renamed column name in the PRIMARY KEY constraint" do
        expect(ddl).to include("PRIMARY KEY (listing_id)")
        expect(ddl).not_to match(/PRIMARY KEY.*\bid\b/)
      end
    end

    context "with optimize_column_order: true" do
      let(:mixed_source) do
        [
          col("id",         type_name: "int4", formatted_type: "integer", alignment: 4, fixed_size: 4),
          col("flag",       type_name: "bool", formatted_type: "boolean", alignment: 1, fixed_size: 1),
          col("created_at", type_name: "timestamp", formatted_type: "timestamp", alignment: 8, fixed_size: 8),
        ]
      end

      subject(:ddl) do
        described_class.generate(
          source_columns: mixed_source,
          table_config: table_config(optimize: true)
        )
      end

      it "puts 8-byte columns before 4-byte columns" do
        created_at_pos = ddl.index("created_at")
        id_pos         = ddl.index("id")
        expect(created_at_pos).to be < id_pos
      end
    end

    context "with a custom schema name" do
      subject(:ddl) do
        described_class.generate(source_columns: source_columns,
                                 table_config: table_config,
                                 schema_name: "migrations")
      end

      it "uses the given schema name" do
        expect(ddl).to start_with("CREATE TABLE migrations.things")
      end
    end

    context "with reserved-word and mixed-case identifiers" do
      let(:tricky_columns) do
        [
          col("id",    type_name: "int4", formatted_type: "integer", nullable: false),
          col("order", type_name: "int4", formatted_type: "integer"),
          col("MyCol", type_name: "text", formatted_type: "text", alignment: 4, fixed_size: nil)
        ]
      end

      subject(:ddl) do
        described_class.generate(
          source_columns:      tricky_columns,
          table_config:        table_config(name: "select"),
          primary_key_columns: ["id"]
        )
      end

      it "quotes reserved words and mixed-case names but not safe ones" do
        expect(ddl).to start_with('CREATE TABLE public."select" (')
        expect(ddl).to match(/"order"\s+integer/)
        expect(ddl).to match(/"MyCol"\s+text/)
        expect(ddl).to match(/^  id\s+integer\s+NOT NULL/)
        expect(ddl).to include("PRIMARY KEY (id)")
      end
    end

    context "with nextval() default (identity column)" do
      let(:id_with_sequence) do
        [col("id", type_name: "int4", formatted_type: "integer",
             nullable: false, default_expr: "nextval('things_id_seq'::regclass)")]
      end

      subject(:ddl) do
        described_class.generate(source_columns: id_with_sequence, table_config: table_config)
      end

      it "omits the nextval() default" do
        expect(ddl).not_to include("nextval")
        expect(ddl).not_to include("DEFAULT")
      end
    end
  end
end

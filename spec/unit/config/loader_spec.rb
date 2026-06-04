# frozen_string_literal: true

require "pcrd"

FIXTURES = File.expand_path("../../support/fixtures", __dir__)

RSpec.describe Pcrd::Config::Loader do
  describe ".load" do
    context "with a full config" do
      subject(:config) { described_class.load("#{FIXTURES}/full_config.yml") }

      it "returns a Config::Root" do
        expect(config).to be_a(Pcrd::Config::Root)
      end

      it "records the file path" do
        expect(config.path).to end_with("full_config.yml")
      end

      describe "source connection" do
        it "parses host, port, database, user" do
          expect(config.source).to have_attributes(
            host: "source.db.example.com",
            port: 5432,
            database: "myapp_production",
            user: "pcrd_replication",
            password: nil
          )
        end
      end

      describe "target connection" do
        it "parses target" do
          expect(config.target).to have_attributes(
            host: "target.db.example.com",
            database: "myapp_production"
          )
        end
      end

      describe "migrate config" do
        subject(:migrate) { config.migrate }

        it "has explicit slot and publication names" do
          expect(migrate.replication_slot).to eq("pcrd_listings")
          expect(migrate.publication).to eq("pcrd_pub_listings")
        end

        it "has batch_size and lag_threshold_bytes" do
          expect(migrate.batch_size).to eq(5_000)
          expect(migrate.lag_threshold_bytes).to eq(524_288)
        end

        it "parses two tables" do
          expect(migrate.tables.length).to eq(2)
        end

        describe "listings table" do
          subject(:table) { migrate.tables.first }

          it "has the correct name and optimize flag" do
            expect(table.name).to eq("listings")
            expect(table.optimize_column_order).to be(true)
          end

          it "parses type change for id" do
            expect(table.columns["id"]).to have_attributes(type: "bigint", rename: nil, drop: false)
          end

          it "parses combined type change and rename" do
            expect(table.columns["list_price"]).to have_attributes(
              type: "numeric(18,4)",
              rename: "list_price_precise"
            )
          end

          it "parses rename-only" do
            expect(table.columns["status_code"]).to have_attributes(
              type: nil,
              rename: "listing_status"
            )
          end

          it "parses drop" do
            expect(table.columns["legacy_notes"]).to have_attributes(drop: true)
          end

          it "parses add_columns" do
            expect(table.add_columns.length).to eq(1)
            expect(table.add_columns.first).to have_attributes(
              name: "updated_at",
              type: "timestamptz",
              default: "now()"
            )
          end
        end
      end

      describe "analyze config" do
        it "parses table list" do
          expect(config.analyze.tables).to eq(%w[listings users])
        end
      end

      describe "verify config" do
        it "uses the configured sample size" do
          expect(config.verify.sample_size).to eq(500)
        end
      end

      describe "cutover config" do
        it "parses sequence_buffer and lag_drain_timeout" do
          expect(config.cutover).to have_attributes(
            sequence_buffer: 2_000,
            lag_drain_timeout: 600
          )
        end
      end
    end

    context "with a minimal config (source only)" do
      subject(:config) { described_class.load("#{FIXTURES}/minimal_config.yml") }

      it "returns a Config::Root with nil optional sections" do
        expect(config.target).to be_nil
        expect(config.migrate).to be_nil
        expect(config.analyze).to be_nil
        expect(config.verify).to be_nil
        expect(config.cutover).to be_nil
      end

      it "defaults source port to 5432" do
        expect(config.source.port).to eq(5432)
      end
    end

    context "with defaults applied" do
      let(:path) do
        write_fixture(<<~YAML)
          source:
            host: localhost
            database: app
            user: postgres
          migrate:
            tables:
              - name: orders
        YAML
      end

      it "derives replication slot name from first table" do
        expect(described_class.load(path).migrate.replication_slot).to eq("pcrd_orders")
      end

      it "derives publication name from first table" do
        expect(described_class.load(path).migrate.publication).to eq("pcrd_pub_orders")
      end

      it "applies default batch_size" do
        expect(described_class.load(path).migrate.batch_size).to eq(10_000)
      end

      it "applies default lag_threshold_bytes" do
        expect(described_class.load(path).migrate.lag_threshold_bytes).to eq(1_048_576)
      end

      it "applies default checkpoint_db" do
        expect(described_class.load(path).migrate.checkpoint_db).to eq("./pcrd_checkpoint.sqlite3")
      end

      it "applies default verify sample_size" do
        path_with_verify = write_fixture(<<~YAML)
          source:
            host: localhost
            database: app
            user: postgres
          verify: {}
        YAML
        expect(described_class.load(path_with_verify).verify.sample_size).to eq(1_000)
      end
    end

    context "with a password in the environment" do
      it "reads PCRD_SOURCE_PASSWORD for source" do
        path = write_fixture(<<~YAML)
          source:
            host: localhost
            database: app
            user: postgres
        YAML
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("PCRD_SOURCE_PASSWORD").and_return("s3cr3t")

        expect(described_class.load(path).source.password).to eq("s3cr3t")
      end

      it "prefers an inline password over the environment variable" do
        path = write_fixture(<<~YAML)
          source:
            host: localhost
            database: app
            user: postgres
            password: inline_password
        YAML
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("PCRD_SOURCE_PASSWORD").and_return("env_password")

        expect(described_class.load(path).source.password).to eq("inline_password")
      end
    end

    context "with an invalid config" do
      it "raises LoadError when the file is missing" do
        expect { described_class.load("/no/such/file.yml") }
          .to raise_error(Pcrd::Config::LoadError, /not found/)
      end

      it "raises LoadError when the YAML is malformed" do
        path = write_fixture("source:\n  host: [\nbad yaml")
        expect { described_class.load(path) }
          .to raise_error(Pcrd::Config::LoadError, /invalid YAML/)
      end

      it "raises LoadError when required source fields are missing" do
        path = write_fixture("source:\n  host: localhost\n")
        expect { described_class.load(path) }
          .to raise_error(Pcrd::Config::LoadError, /invalid/)
      end

      it "raises LoadError when a column spec combines drop with type" do
        path = write_fixture(<<~YAML)
          source:
            host: localhost
            database: app
            user: postgres
          migrate:
            tables:
              - name: orders
                columns:
                  amount:
                    type: bigint
                    drop: true
        YAML
        expect { described_class.load(path) }
          .to raise_error(Pcrd::Config::LoadError, /drop.*type/)
      end
    end
  end

  # Writes a temp YAML fixture and returns the path.
  def write_fixture(content)
    require "tempfile"
    file = Tempfile.new(["pcrd_test", ".yml"])
    file.write(content)
    file.close
    file.path
  end
end

# frozen_string_literal: true

require "pg"

module PgHelpers
  def source_pool
    @source_pool ||= Pcrd::Connection::Pool.new(test_source_config)
  end

  def test_source_config
    Pcrd::Config::Connection.new(
      host:     ENV.fetch("PCRD_TEST_SOURCE_HOST",     "localhost"),
      port:     ENV.fetch("PCRD_TEST_SOURCE_PORT",     "5433").to_i,
      database: ENV.fetch("PCRD_TEST_SOURCE_DB",       "pcrd_source"),
      user:     ENV.fetch("PCRD_TEST_SOURCE_USER",     "postgres"),
      password: ENV.fetch("PCRD_TEST_SOURCE_PASSWORD", "postgres")
    )
  end

  # Creates a table in the test database, runs the block, then drops it.
  def with_table(pool, ddl, table_name:, schema: "public")
    pool.exec("DROP TABLE IF EXISTS #{schema}.#{table_name} CASCADE")
    pool.exec(ddl)
    yield
  ensure
    pool.exec("DROP TABLE IF EXISTS #{schema}.#{table_name} CASCADE")
  end

  def pg_available?
    PG.connect(
      host:    ENV.fetch("PCRD_TEST_SOURCE_HOST",     "localhost"),
      port:    ENV.fetch("PCRD_TEST_SOURCE_PORT",     "5433").to_i,
      dbname:  ENV.fetch("PCRD_TEST_SOURCE_DB",       "pcrd_source"),
      user:    ENV.fetch("PCRD_TEST_SOURCE_USER",     "postgres"),
      password: ENV.fetch("PCRD_TEST_SOURCE_PASSWORD", "postgres")
    ).close
    true
  rescue PG::Error
    false
  end
end

RSpec.configure do |config|
  config.include PgHelpers, :integration

  config.before(:suite) do
    if RSpec.world.filtered_examples.values.flatten.any? { |e| e.metadata[:integration] }
      unless PgHelpers.instance_method(:pg_available?).bind_call(Object.new)
        warn "\n[pcrd] Integration tests skipped: PostgreSQL not available at localhost:5433\n" \
             "       Start with: docker compose -f dev/docker-compose.yml up -d\n\n"
      end
    end
  end

  config.around(:each, :integration) do |example|
    if pg_available?
      example.run
    else
      skip "PostgreSQL not available (start dev/docker-compose.yml)"
    end
  end
end

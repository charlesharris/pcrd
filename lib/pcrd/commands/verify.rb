# frozen_string_literal: true

module Pcrd
  module Commands
    # Compares row counts and spot-checks random rows between source and target.
    #
    # Safe to run at any time after backfill completes. Does not modify either cluster.
    class Verify
      MismatchError = Class.new(StandardError)

      Result = Data.define(:passed, :tables)
      TableResult = Data.define(:table_name, :source_count, :target_count,
                                :sample_size, :mismatches)

      def initialize(config, options = {})
        @config  = config
        @options = options
      end

      def run
        validate_config!

        source_pool = Connection::Pool.new(@config.source)
        target_pool = Connection::Pool.new(@config.target)
        sample_size = @options["sample-size"] || @options[:"sample-size"] ||
                      @config.verify&.sample_size || 1_000

        table_results = (@config.migrate&.tables || []).map do |table_config|
          verify_table(source_pool, target_pool, table_config, sample_size)
        end

        source_pool.close
        target_pool.close

        Result.new(
          passed: table_results.all? { |r| r.mismatches.empty? && r.source_count == r.target_count },
          tables: table_results
        )
      end

      private

      def verify_table(source_pool, target_pool, table_config, sample_size)
        table_name = table_config.name
        src_count = source_pool.exec("SELECT COUNT(*) FROM #{Sql.quote_table(table_name)}")[0]["count"].to_i
        tgt_count = target_pool.exec("SELECT COUNT(*) FROM #{Sql.quote_table(table_name)}")[0]["count"].to_i

        mismatches = []

        if src_count == tgt_count && src_count > 0
          mismatches = spot_check(source_pool, target_pool, table_config, sample_size)
        end

        TableResult.new(
          table_name:   table_name,
          source_count: src_count,
          target_count: tgt_count,
          sample_size:  [sample_size, src_count].min,
          mismatches:   mismatches
        )
      rescue Connection::Error => e
        TableResult.new(
          table_name:   table_name,
          source_count: nil,
          target_count: nil,
          sample_size:  0,
          mismatches:   ["Connection error: #{e.message}"]
        )
      end

      # Samples source rows, transforms each into its expected target shape, and
      # compares the values field-by-field against the matching target row.
      # This is what catches a transform that silently corrupts data — a row
      # count match alone does not.
      def spot_check(source_pool, target_pool, table_config, sample_size)
        table_name  = table_config.name
        reader      = Schema::Reader.new(source_pool)
        source_cols = reader.read(table_name)
        pk_cols     = reader.primary_key_columns(table_name)
        return [] if pk_cols.empty?

        transformer = Transform::RowTransformer.new(table_config, source_cols)
        pk_target   = map_pk_to_target(pk_cols, table_config)

        sample_rows = sample_source_rows(source_pool, table_name, sample_size)
        return [] if sample_rows.empty?

        target_table = Sql.quote_table(table_name)
        conditions   = pk_target.each_with_index
                                .map { |col, i| "#{Sql.quote_ident(col)} = $#{i + 1}" }
                                .join(" AND ")

        mismatches = []
        sample_rows.each do |src_row|
          expected  = transformer.transform(src_row) # { target_col => value }
          pk_values = pk_cols.map { |col| src_row[col] }
          pk_desc   = pk_cols.zip(pk_values).map { |c, v| "#{c}=#{v}" }.join(",")

          tgt_row = target_pool.exec(
            "SELECT * FROM #{target_table} WHERE #{conditions}", pk_values
          ).first

          if tgt_row.nil?
            mismatches << "pk=#{pk_desc}: row missing on target"
            next
          end

          expected.each do |col, exp_val|
            act_val = tgt_row[col]
            next if values_equal?(exp_val, act_val)

            mismatches << "pk=#{pk_desc} col=#{col}: " \
                          "source=#{redact(exp_val)} target=#{redact(act_val)}"
          end
        end

        mismatches
      end

      # Samples up to sample_size rows cheaply. ORDER BY random() sorts the whole
      # table; instead use TABLESAMPLE SYSTEM (page-level random) for large
      # tables and a plain LIMIT for small ones. Oversample then cap so an
      # unlucky page selection still tends to fill the sample.
      def sample_source_rows(pool, table_name, sample_size)
        quoted = Sql.quote_table(table_name)
        est    = Schema::Reader.new(pool).estimated_row_count(table_name)

        if est <= sample_size
          return pool.exec("SELECT * FROM #{quoted} LIMIT $1", [sample_size]).to_a
        end

        pct  = [[sample_size * 100.0 / est * 3.0, 0.01].max, 100.0].min
        rows = pool.exec(
          "SELECT * FROM #{quoted} TABLESAMPLE SYSTEM (#{pct.round(6)}) LIMIT $1",
          [sample_size]
        ).to_a

        # TABLESAMPLE can under-fill on small/unlucky page layouts; fall back.
        rows.empty? ? pool.exec("SELECT * FROM #{quoted} LIMIT $1", [sample_size]).to_a : rows
      end

      def map_pk_to_target(pk_source_cols, table_config)
        pk_source_cols.map do |src|
          spec = table_config.columns&.[](src) || table_config.columns&.[](src.to_sym)
          spec&.rename || src
        end
      end

      # Values come back from libpq as strings (or nil) on both sides, so a
      # textual comparison correctly treats e.g. int4 99 and int8 99 as equal
      # while still catching genuinely different values.
      def values_equal?(expected, actual)
        return true if expected.nil? && actual.nil?
        return false if expected.nil? || actual.nil?

        expected.to_s == actual.to_s
      end

      def redact(val)
        return "NULL" if val.nil?

        str = val.to_s
        str.length > 60 ? "#{str[0, 57]}..." : str
      end

      def validate_config!
        raise "source connection required" if @config.source.nil?
        raise "target connection required for verify" if @config.target.nil?
        raise "no tables configured" if (@config.migrate&.tables || []).empty?
      end
    end
  end
end

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
          verify_table(source_pool, target_pool, table_config.name, sample_size)
        end

        source_pool.close
        target_pool.close

        Result.new(
          passed: table_results.all? { |r| r.mismatches.empty? && r.source_count == r.target_count },
          tables: table_results
        )
      end

      private

      def verify_table(source_pool, target_pool, table_name, sample_size)
        src_count = source_pool.exec("SELECT COUNT(*) FROM #{source_pool.quote_ident(table_name)}")[0]["count"].to_i
        tgt_count = target_pool.exec("SELECT COUNT(*) FROM #{target_pool.quote_ident(table_name)}")[0]["count"].to_i

        mismatches = []

        if src_count == tgt_count && src_count > 0
          # Spot-check: sample random rows by primary key range
          mismatches = spot_check(source_pool, target_pool, table_name, sample_size)
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

      def spot_check(source_pool, target_pool, table_name, sample_size)
        # Sample primary key values from source using ORDER BY random() LIMIT n
        pk_reader = Schema::Reader.new(source_pool)
        pk_cols   = pk_reader.primary_key_columns(table_name)
        return [] if pk_cols.empty?

        quoted_table    = source_pool.quote_ident(table_name)
        pk_select       = pk_cols.map { source_pool.quote_ident(_1) }.join(", ")

        sample_ids = source_pool.exec(
          "SELECT #{pk_select} FROM #{quoted_table} ORDER BY random() LIMIT $1",
          [sample_size]
        ).to_a

        return [] if sample_ids.empty?

        mismatches = []
        sample_ids.each do |id_row|
          conditions = pk_cols.each_with_index.map { |col, i|
            "#{source_pool.quote_ident(col)} = $#{i + 1}"
          }.join(" AND ")
          pk_values = pk_cols.map { id_row[_1] }

          src_row = source_pool.exec("SELECT * FROM #{quoted_table} WHERE #{conditions}", pk_values).first
          tgt_row = target_pool.exec("SELECT * FROM #{target_pool.quote_ident(table_name)} WHERE #{conditions}", pk_values).first

          next if src_row.nil? && tgt_row.nil?

          if src_row.nil? || tgt_row.nil?
            mismatches << "pk=#{pk_values.join(',')} exists on #{src_row.nil? ? 'target only' : 'source only'}"
          end
        end

        mismatches
      end

      def validate_config!
        raise "source connection required" if @config.source.nil?
        raise "target connection required for verify" if @config.target.nil?
        raise "no tables configured" if (@config.migrate&.tables || []).empty?
      end
    end
  end
end

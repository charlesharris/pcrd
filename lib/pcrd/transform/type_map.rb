# frozen_string_literal: true

require "set"

module Pcrd
  module Transform
    # Registry of known PostgreSQL type transitions and their safety classification.
    #
    # Works with pg's internal type_name values (int4, int8, bool, etc.) for the
    # source side, and normalizes user-facing spec strings (bigint, timestamptz)
    # to the same internal names for matching.
    #
    # Safety levels:
    #   :no_op        — source and target are the same type; nothing to do
    #   :always_safe  — widening cast; no possible data loss; no validation needed
    #   :validated    — cast may lose data; Validator must run a pre-migration check
    #   :unsupported  — pcrd cannot handle this cast; user must provide a custom transform
    module TypeMap
      # Maps user-facing type strings in migration specs to pg internal type names.
      SPEC_TO_PG = {
        "bigint"                       => "int8",
        "int8"                         => "int8",
        "integer"                      => "int4",
        "int4"                         => "int4",
        "int"                          => "int4",
        "smallint"                     => "int2",
        "int2"                         => "int2",
        "real"                         => "float4",
        "float4"                       => "float4",
        "double precision"             => "float8",
        "float8"                       => "float8",
        "boolean"                      => "bool",
        "bool"                         => "bool",
        "text"                         => "text",
        "date"                         => "date",
        "timestamp"                    => "timestamp",
        "timestamp without time zone"  => "timestamp",
        "timestamptz"                  => "timestamptz",
        "timestamp with time zone"     => "timestamptz",
        "time"                         => "time",
        "time without time zone"       => "time",
        "timetz"                       => "timetz",
        "time with time zone"          => "timetz",
        "numeric"                      => "numeric",
        "decimal"                      => "numeric",
        "money"                        => "money",
        "uuid"                         => "uuid",
        "json"                         => "json",
        "jsonb"                        => "jsonb",
        "bytea"                        => "bytea",
        "oid"                          => "oid",
      }.freeze

      # Always-safe casts: pure widening, no possible data loss.
      # Keys are [pg_source_type, pg_target_type].
      ALWAYS_SAFE_PAIRS = Set.new([
        %w[int2 int4],
        %w[int2 int8],
        %w[int4 int8],
        %w[int2 float4],
        %w[int4 float4],
        %w[int2 float8],
        %w[int4 float8],
        %w[int8 float8],
        %w[float4 float8],
        %w[int2 numeric],
        %w[int4 numeric],
        %w[int8 numeric],
        %w[float4 numeric],
        %w[float8 numeric],
        %w[date timestamp],
        %w[date timestamptz],
        %w[timestamp timestamptz],
        %w[bpchar text],    # char(n)    → text
        %w[varchar text],   # varchar(n) → text
        %w[bpchar varchar], # char(n)    → varchar(m) — validated below if m < n
        %w[name text],
        %w[json jsonb],
      ]).freeze

      # Validated casts: may lose data; Validator generates SQL to check.
      # Values include: :description, :check_expr (a Proc → SQL fragment), :warn_only.
      VALIDATED_RULES = [
        {
          from: "int8", to: "int4",
          description: "values must fit in integer range [-2,147,483,648 … 2,147,483,647]",
          check_expr: ->(col) { "#{col} NOT BETWEEN -2147483648 AND 2147483647" },
          warn_only: false
        },
        {
          from: "int8", to: "int2",
          description: "values must fit in smallint range [-32,768 … 32,767]",
          check_expr: ->(col) { "#{col} NOT BETWEEN -32768 AND 32767" },
          warn_only: false
        },
        {
          from: "int4", to: "int2",
          description: "values must fit in smallint range [-32,768 … 32,767]",
          check_expr: ->(col) { "#{col} NOT BETWEEN -32768 AND 32767" },
          warn_only: false
        },
        {
          from: "float8", to: "float4",
          description: "precision will be reduced (double precision → real); some values may differ",
          check_expr: nil,
          warn_only: true
        },
        {
          from: "timestamptz", to: "timestamp",
          description: "timezone information will be discarded",
          check_expr: nil,
          warn_only: true
        },
        {
          from: "numeric", to: "int8",
          description: "fractional parts will be truncated; values must be whole numbers",
          check_expr: ->(col) { "#{col} <> floor(#{col})" },
          warn_only: false
        },
        {
          from: "numeric", to: "int4",
          description: "fractional parts truncated; values must fit in integer range",
          check_expr: ->(col) { "floor(#{col}) NOT BETWEEN -2147483648 AND 2147483647 OR #{col} <> floor(#{col})" },
          warn_only: false
        },
        # text/varchar → varchar(n): length check — handled separately via varchar_length_check
        {
          from: "text",    to: "varchar",  description: "all values must fit within target length", check_expr: :varchar_length_check, warn_only: false },
        {
          from: "varchar", to: "varchar",  description: "all values must fit within target length", check_expr: :varchar_length_check, warn_only: false },
        {
          from: "varchar", to: "bpchar",   description: "all values must fit within target length", check_expr: :varchar_length_check, warn_only: false },
        {
          from: "text",    to: "bpchar",   description: "all values must fit within target length", check_expr: :varchar_length_check, warn_only: false },
      ].freeze

      # Returns the safety classification for a source→target type transition.
      #
      # source_pg_type:    pg internal type name from Schema::Column#type_name
      # target_type_str:   type string from the migration spec (e.g. "bigint", "varchar(255)")
      def self.cast_safety(source_pg_type, target_type_str)
        src = source_pg_type.to_s.strip
        tgt_pg, tgt_base = normalize_target(target_type_str)

        # Same base type: usually no-op, but varchar/char with a length constraint
        # on the target still needs validation (values may exceed the new limit).
        if src == tgt_pg || (src == tgt_base && tgt_pg.nil?)
          if %w[bpchar varchar].include?(src) && extract_length(target_type_str)
            return :validated
          end
          return :no_op
        end

        return :always_safe if ALWAYS_SAFE_PAIRS.include?([src, tgt_base])

        # varchar → varchar(m): validated (length comparison handled by Validator)
        if %w[bpchar varchar].include?(src) && %w[varchar bpchar].include?(tgt_base)
          tgt_len = extract_length(target_type_str)
          return :always_safe if tgt_len.nil?   # → text (already covered above)
          return :validated
        end

        validated = VALIDATED_RULES.find { |r| r[:from] == src && r[:to] == tgt_base }
        return :validated if validated

        :unsupported
      end

      # Returns the validated rule for a source→target pair, or nil.
      def self.validated_rule(source_pg_type, target_type_str)
        _, tgt_base = normalize_target(target_type_str)
        VALIDATED_RULES.find { |r| r[:from] == source_pg_type && r[:to] == tgt_base }
      end

      # Returns true if a target type string refers to a known type.
      def self.known_target?(type_str)
        _, base = normalize_target(type_str)
        SPEC_TO_PG.value?(base) || %w[varchar bpchar].include?(base)
      end

      # Extracts the length parameter from a varchar(N) / char(N) type string.
      # Returns nil if not parameterized.
      def self.extract_length(type_str)
        return nil unless type_str
        m = type_str.match(/\((\d+)/)
        m ? m[1].to_i : nil
      end

      private_class_method def self.normalize_target(type_str) # rubocop:disable Metrics/MethodLength
        s = type_str.to_s.strip.downcase
        base = s.split("(").first.strip

        # Parameterized varchar/char: keep base separate
        if s.start_with?("character varying", "varchar")
          return [nil, "varchar"]
        end
        if s.start_with?("character(", "char(", "bpchar")
          return [nil, "bpchar"]
        end

        pg = SPEC_TO_PG[s] || SPEC_TO_PG[base]
        [pg, pg || base]
      end
    end
  end
end

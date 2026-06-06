# frozen_string_literal: true

module Pcrd
  module Schema
    # Maps PostgreSQL type name strings (as they appear in migration specs)
    # to the physical storage properties needed for padding analysis and
    # synthetic column construction.
    #
    # Used when building target Schema::Column objects from a migration spec
    # without a real target DB connection.
    module TypeRegistry
      TypeInfo = Data.define(:canonical_name, :alignment, :fixed_size)

      # Fixed-size types with exact mappings.
      FIXED = {
        # 8-byte, 8-byte aligned
        "bigint"                       => TypeInfo.new(canonical_name: "bigint",            alignment: 8, 
fixed_size: 8),
        "int8"                         => TypeInfo.new(canonical_name: "bigint",            alignment: 8, 
fixed_size: 8),
        "double precision"             => TypeInfo.new(canonical_name: "double precision",  alignment: 8, 
fixed_size: 8),
        "float8"                       => TypeInfo.new(canonical_name: "double precision",  alignment: 8, 
fixed_size: 8),
        "timestamp"                    => TypeInfo.new(canonical_name: "timestamp",         alignment: 8, 
fixed_size: 8),
        "timestamp without time zone"  => TypeInfo.new(canonical_name: "timestamp",         alignment: 8, 
fixed_size: 8),
        "timestamptz"                  => TypeInfo.new(canonical_name: "timestamptz",       alignment: 8, 
fixed_size: 8),
        "timestamp with time zone"     => TypeInfo.new(canonical_name: "timestamptz",       alignment: 8, 
fixed_size: 8),
        "interval"                     => TypeInfo.new(canonical_name: "interval",          alignment: 8, 
fixed_size: 16),
        "money"                        => TypeInfo.new(canonical_name: "money",             alignment: 8, 
fixed_size: 8),
        # 4-byte, 4-byte aligned
        "integer"                      => TypeInfo.new(canonical_name: "integer",           alignment: 4, 
fixed_size: 4),
        "int4"                         => TypeInfo.new(canonical_name: "integer",           alignment: 4, 
fixed_size: 4),
        "int"                          => TypeInfo.new(canonical_name: "integer",           alignment: 4, 
fixed_size: 4),
        "real"                         => TypeInfo.new(canonical_name: "real",              alignment: 4, 
fixed_size: 4),
        "float4"                       => TypeInfo.new(canonical_name: "real",              alignment: 4, 
fixed_size: 4),
        "date"                         => TypeInfo.new(canonical_name: "date",              alignment: 4, 
fixed_size: 4),
        "time"                         => TypeInfo.new(canonical_name: "time",              alignment: 4, 
fixed_size: 8),
        "time without time zone"       => TypeInfo.new(canonical_name: "time",              alignment: 4, 
fixed_size: 8),
        "oid"                          => TypeInfo.new(canonical_name: "oid",               alignment: 4, 
fixed_size: 4),
        # 2-byte, 2-byte aligned
        "smallint"                     => TypeInfo.new(canonical_name: "smallint",          alignment: 2, 
fixed_size: 2),
        "int2"                         => TypeInfo.new(canonical_name: "smallint",          alignment: 2, 
fixed_size: 2),
        # 1-byte, 1-byte aligned
        "boolean"                      => TypeInfo.new(canonical_name: "boolean",           alignment: 1, 
fixed_size: 1),
        "bool"                         => TypeInfo.new(canonical_name: "boolean",           alignment: 1, 
fixed_size: 1),
        "\"char\""                     => TypeInfo.new(canonical_name: "\"char\"",          alignment: 1, 
fixed_size: 1),
      }.freeze

      # Variable-length types (varlena): 4-byte aligned header, variable content.
      VARIABLE = %w[
        text varchar character\ varying bytea json jsonb xml
        numeric decimal cidr inet macaddr tsvector tsquery
        character char
      ].freeze

      # Prefixes that indicate a parameterized variable-length type,
      # e.g. "varchar(255)", "numeric(10,2)", "char(2)".
      VARIABLE_PREFIXES = %w[
        varchar character\ varying numeric decimal char character
        bit varying varbit
      ].freeze

      # Returns a TypeInfo for the given type string, or a safe variable-length
      # default if the type is unknown. Never raises.
      def self.lookup(type_str)
        normalized = type_str.to_s.strip.downcase

        # Exact match first.
        return FIXED[normalized] if FIXED.key?(normalized)

        # Parameterized variable-length types: varchar(N), numeric(P,S), etc.
        VARIABLE_PREFIXES.each do |prefix|
          if normalized.start_with?(prefix)
            return TypeInfo.new(canonical_name: type_str, alignment: 4, fixed_size: nil)
          end
        end

        # Plain variable-length names.
        VARIABLE.each do |name|
          return TypeInfo.new(canonical_name: type_str, alignment: 4, fixed_size: nil) if normalized == name
        end

        # Unknown type: assume variable-length (safest for padding analysis).
        TypeInfo.new(canonical_name: type_str, alignment: 4, fixed_size: nil)
      end

      def self.known?(type_str)
        normalized = type_str.to_s.strip.downcase
        return true if FIXED.key?(normalized)
        VARIABLE_PREFIXES.any? { |p| normalized.start_with?(p) } ||
          VARIABLE.include?(normalized)
      end
    end
  end
end

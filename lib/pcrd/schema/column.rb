# frozen_string_literal: true

module Pcrd
  module Schema
    class Column
      attr_reader :attnum, :name, :type_name, :formatted_type,
                  :alignment, :fixed_size, :nullable, :default_expr

      # alignment: Integer (1, 2, 4, or 8 bytes)
      # fixed_size: Integer bytes, or nil for variable-length
      def initialize(attnum:, name:, type_name:, formatted_type:,
                     alignment:, fixed_size:, nullable:, default_expr:)
        @attnum         = attnum
        @name           = name
        @type_name      = type_name
        @formatted_type = formatted_type
        @alignment      = alignment
        @fixed_size     = fixed_size
        @nullable       = nullable
        @default_expr   = default_expr
      end

      def variable?
        fixed_size.nil?
      end

      def fixed?
        !variable?
      end

      # Human-readable type string, with common verbose PG names shortened.
      def display_type
        formatted_type
          .sub("character varying", "varchar")
          .sub("character(", "char(")
          .sub("timestamp without time zone", "timestamp")
          .sub("timestamp with time zone", "timestamptz")
          .sub("time without time zone", "time")
          .sub("time with time zone", "timetz")
      end

      def display_size
        fixed_size ? fixed_size.to_s : "variable"
      end

      def display_alignment
        "#{alignment}B"
      end

      def ==(other)
        other.is_a?(Column) && name == other.name && type_name == other.type_name
      end

      def inspect
        "#<Pcrd::Schema::Column #{name}:#{display_type} align=#{alignment} size=#{display_size}>"
      end
    end
  end
end

# frozen_string_literal: true

require "set"

module Pcrd
  # Centralized SQL identifier rendering. Every place that builds SQL (DDL,
  # setup, apply, verify, validation) goes through here so quoting and schema
  # qualification are consistent instead of three different conventions —
  # some of which interpolated identifiers raw and broke on mixed-case,
  # reserved-word, or non-public names.
  #
  # Quoting follows PostgreSQL's own quote_ident(): an identifier that is a
  # safe lowercase word and not a reserved keyword is emitted bare (so normal
  # DDL stays readable), otherwise it is double-quoted with internal quotes
  # doubled. The reserved set is the common subset most likely to appear as a
  # column or table name; anything not lowercase-simple is always quoted, so
  # the only risk from an incomplete set is an unnecessary quote, never a
  # broken statement.
  module Sql
    SAFE_IDENT = /\A[a-z_][a-z0-9_$]*\z/

    RESERVED = %w[
      all analyse analyze and any array as asc asymmetric authorization
      between binary both case cast check collate column constraint create
      cross current_catalog current_date current_role current_time
      current_timestamp current_user default deferrable desc distinct do else
      end except false fetch for foreign from grant group having ilike in
      initially inner intersect into is isnull join lateral leading left like
      limit localtime localtimestamp natural not notnull null offset on only or
      order outer overlaps placing primary references returning right select
      session_user similar some symmetric table tablesample then to trailing
      true union unique user using variadic verbose when where window with
    ].to_set.freeze

    module_function

    # Quotes an identifier only when PostgreSQL would require it.
    def quote_ident(name)
      str = name.to_s
      return str if str.match?(SAFE_IDENT) && !RESERVED.include?(str)

      %("#{str.gsub('"', '""')}")
    end

    # Fully-qualified, quoted "schema.table".
    def quote_table(name, schema: "public")
      "#{quote_ident(schema)}.#{quote_ident(name)}"
    end

    # Comma-joined list of quoted column identifiers.
    def quote_columns(names)
      names.map { |n| quote_ident(n) }.join(", ")
    end
  end
end

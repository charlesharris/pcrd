# frozen_string_literal: true

module Pcrd
  module Config
    # tables: Array<String> of table names, or nil to use migrate.tables
    AnalyzeConfig = Data.define(:tables)
  end
end

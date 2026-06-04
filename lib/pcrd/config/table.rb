# frozen_string_literal: true

module Pcrd
  module Config
    # columns:     Hash<source_column_name, ColumnSpec>
    # add_columns: Array<AddColumn>
    Table = Data.define(:name, :optimize_column_order, :columns, :add_columns)
  end
end

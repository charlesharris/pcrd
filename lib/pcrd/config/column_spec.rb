# frozen_string_literal: true

module Pcrd
  module Config
    # Spec for an existing column. All fields are optional:
    # nil type means keep the current type; nil rename means keep the name;
    # drop: false means keep the column.
    ColumnSpec = Data.define(:type, :rename, :drop)
  end
end

# frozen_string_literal: true

module Pcrd
  module Config
    MigrateConfig = Data.define(
      :replication_slot,
      :publication,
      :checkpoint_db,
      :batch_size,
      :lag_threshold_bytes,
      :tables,
      :max_rows_per_second
    ) do
      # max_rows_per_second is optional (nil = unthrottled). Defaulting it here
      # keeps existing callers and configs without the key working.
      def initialize(max_rows_per_second: nil, **rest)
        super(max_rows_per_second: max_rows_per_second, **rest)
      end
    end
  end
end

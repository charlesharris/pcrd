# frozen_string_literal: true

module Pcrd
  module Config
    MigrateConfig = Data.define(
      :replication_slot,
      :publication,
      :checkpoint_db,
      :batch_size,
      :lag_threshold_bytes,
      :tables
    )
  end
end

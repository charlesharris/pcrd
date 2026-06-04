# frozen_string_literal: true

require "dry-schema"

module Pcrd
  module Config
    module Schema
    # Validates a YAML config hash (already natively typed by YAML.safe_load).
    # Uses Dry::Schema.define (no coercion) since YAML gives us real Ruby types.
    DEFINITION = Dry::Schema.define do
      required(:source).hash do
        required(:host).filled(:string)
        optional(:port).value(:integer, gt?: 0, lt?: 65_536)
        required(:database).filled(:string)
        required(:user).filled(:string)
        optional(:password).maybe(:string)
      end

      optional(:target).hash do
        required(:host).filled(:string)
        optional(:port).value(:integer, gt?: 0, lt?: 65_536)
        required(:database).filled(:string)
        required(:user).filled(:string)
        optional(:password).maybe(:string)
      end

      optional(:migrate).hash do
        optional(:replication_slot).filled(:string)
        optional(:publication).filled(:string)
        optional(:checkpoint_db).filled(:string)
        optional(:batch_size).value(:integer, gt?: 0)
        optional(:lag_threshold_bytes).value(:integer, gt?: 0)
        optional(:tables).array(:hash) do
          required(:name).filled(:string)
          optional(:optimize_column_order).value(:bool)
          # columns: dynamic keys (column names) — validated structurally in Loader
          optional(:columns).value(:hash)
          optional(:add_columns).array(:hash) do
            required(:name).filled(:string)
            required(:type).filled(:string)
            optional(:default).maybe(:string)
          end
        end
      end

      optional(:analyze).hash do
        # nil means "use tables from migrate section"
        optional(:tables).array(:string)
      end

      optional(:verify).hash do
        optional(:sample_size).value(:integer, gt?: 0)
      end

      optional(:cutover).hash do
        optional(:sequence_buffer).value(:integer, gteq?: 0)
        optional(:lag_drain_timeout).value(:integer, gt?: 0)
      end
    end
    end  # module Schema
  end
end

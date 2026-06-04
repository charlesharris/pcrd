# frozen_string_literal: true

module Pcrd
  module Schema
    # Analyzes column alignment and computes optimal ordering to minimize padding waste.
    #
    # PostgreSQL stores columns in definition order. Each column must start at an
    # address aligned to its type's natural alignment boundary. When a small-aligned
    # column (e.g. bool, 1 byte) precedes a large-aligned column (e.g. timestamp,
    # 8 bytes), PostgreSQL inserts padding bytes to satisfy the alignment requirement
    # of the larger type. Reordering columns largest-alignment-first eliminates this
    # waste entirely for fixed-size columns.
    #
    # Variable-length columns (text, varchar, numeric, etc.) have a 4-byte aligned
    # varlena header. Their actual content length is not predictable, so we count only
    # the header for padding estimates and place them last where they contribute no
    # cross-column alignment overhead.
    class Packer
      # A single entry in a layout: the column plus the padding bytes inserted
      # before it to satisfy its alignment requirement.
      LayoutEntry = Data.define(:column, :offset, :padding_before)

      # Returns columns in optimal order: 8-byte → 4-byte → 2-byte → 1-byte → variable.
      # Within each alignment tier, preserves the original column order.
      def optimize(columns)
        fixed    = columns.select(&:fixed?)
        variable = columns.select(&:variable?)
        sorted_fixed = fixed.sort_by.with_index { |c, i| [-c.alignment, -c.fixed_size, i] }
        sorted_fixed + variable
      end

      # Computes the per-column layout (offset and padding before each column).
      # Returns Array<LayoutEntry>.
      def layout(columns)
        offset  = 0
        entries = []

        columns.each do |col|
          align   = col.fixed? ? col.alignment : 4  # varlena header is 4-byte aligned
          padding = padding_needed(offset, align)
          entries << LayoutEntry.new(column: col, offset: offset + padding, padding_before: padding)
          offset  += padding + (col.fixed? ? col.fixed_size : 4)  # count header only for varlena
        end

        entries
      end

      # Estimated bytes consumed by fixed-length columns plus alignment padding.
      # Variable-length columns contribute 4 bytes each (header only).
      def estimated_row_size(columns)
        layout(columns).sum do |e|
          e.padding_before + (e.column.fixed? ? e.column.fixed_size : 4)
        end
      end

      # Total wasted padding bytes across all columns.
      def total_padding(columns)
        layout(columns).sum(&:padding_before)
      end

      # Returns a report hash comparing current vs optimal layout.
      def report(columns)
        optimal_order = optimize(columns)

        current_size  = estimated_row_size(columns)
        optimal_size  = estimated_row_size(optimal_order)
        saved_bytes   = current_size - optimal_size
        pct           = current_size > 0 ? (saved_bytes.to_f / current_size * 100).round(1) : 0.0

        {
          current_columns:  columns,
          optimal_columns:  optimal_order,
          current_layout:   layout(columns),
          optimal_layout:   layout(optimal_order),
          current_size:     current_size,
          optimal_size:     optimal_size,
          saved_bytes:      saved_bytes,
          savings_pct:      pct,
          already_optimal:  saved_bytes.zero?
        }
      end

      private

      def padding_needed(offset, alignment)
        (alignment - (offset % alignment)) % alignment
      end
    end
  end
end

# frozen_string_literal: true

module Pcrd
  module Schema
    # One row in a schema diff: describes the relationship between a source column
    # and its counterpart on the target.
    #
    # status values:
    #   :unchanged       — column exists on both sides with the same name and type
    #   :type_changed    — same name, different type
    #   :renamed         — different name, same type
    #   :type_and_renamed — different name AND different type
    #   :dropped         — exists on source, absent from target (per spec)
    #   :added           — absent from source, new column on target (per spec)
    DiffEntry = Data.define(:status, :source_column, :target_column) do
      def source_name = source_column&.name
      def target_name = target_column&.name

      def type_changed? = %i[type_changed type_and_renamed].include?(status)
      def renamed?      = %i[renamed type_and_renamed].include?(status)
      def dropped?      = status == :dropped
      def added?        = status == :added

      def status_label
        case status
        when :unchanged        then "unchanged"
        when :type_changed     then "type changed"
        when :renamed          then "renamed"
        when :type_and_renamed then "renamed + type changed"
        when :dropped          then "dropped"
        when :added            then "added"
        end
      end
    end
  end
end

# frozen_string_literal: true

module Pcrd
  module Replication
    module Pgoutput
      # Immutable structs for each pgoutput message type.
      # Produced by Parser#parse; consumed by the WAL consumer (Phase 9).
      #
      # Tuple data (new_tuple / old_tuple) is a Hash<column_name, value> where:
      #   value = String  — column value in text format
      #   value = nil     — SQL NULL
      #   value = :toast  — unchanged TOASTed value (not re-sent by server)
      module Messages
        # One column description inside a Relation message.
        RelationColumn = Data.define(
          :flags,         # Integer: bit 0 set = part of replica identity key
          :name,          # String: column name
          :type_id,       # Integer: OID of the column data type
          :type_modifier  # Integer: atttypmod (-1 means no modifier)
        )

        # B — transaction begin
        # lsn: String "X/Y" — final LSN of the transaction
        # commit_time: Time (UTC)
        # xid: Integer — transaction ID
        Begin = Data.define(:lsn, :commit_time, :xid)

        # C — transaction commit
        # lsn: String "X/Y" — commit LSN
        # end_lsn: String "X/Y" — LSN after the end of the transaction record
        # commit_time: Time (UTC)
        Commit = Data.define(:flags, :lsn, :end_lsn, :commit_time)

        # R — relation (table schema snapshot)
        # id: Integer — relation OID
        # namespace: String — schema name (empty for pg_catalog)
        # name: String — table name
        # replica_identity: String — one of 'd', 'n', 'f', 'i'
        # columns: Array<RelationColumn>
        Relation = Data.define(:id, :namespace, :name, :replica_identity, :columns)

        # T — data type
        Type = Data.define(:id, :namespace, :name)

        # I — INSERT
        Insert = Data.define(:relation_id, :new_tuple)

        # U — UPDATE
        # old_tuple is nil unless REPLICA IDENTITY is FULL or INDEX
        Update = Data.define(:relation_id, :old_tuple, :new_tuple)

        # D — DELETE
        # old_tuple contains either the key columns or all columns depending on REPLICA IDENTITY
        Delete = Data.define(:relation_id, :old_tuple)

        # O — origin (the replication origin this transaction came from)
        Origin = Data.define(:lsn, :name)

        # A — TRUNCATE (PG 11+)
        # option_bits: Integer — 1 = CASCADE, 2 = RESTART IDENTITY
        Truncate = Data.define(:option_bits, :relation_ids)

        # M — logical decoding message (PG 14+)
        LogicalMessage = Data.define(:flags, :lsn, :prefix, :content)
      end
    end
  end
end

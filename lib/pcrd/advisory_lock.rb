# frozen_string_literal: true

module Pcrd
  # A PostgreSQL session-level advisory lock used to stop two `pcrd migrate`
  # processes from running against the same replication slot at once — which
  # would corrupt checkpoint/LSN progress and fight over the slot.
  #
  # The lock is taken on the source database (where the slot and publication
  # live, the truly shared resource) and is keyed by the slot name. Being
  # session-level, it is released by #release or automatically when the
  # connection closes, so a crashed run does not leave it stuck.
  class AdvisoryLock
    NAMESPACE = "pcrd-migrate"

    def initialize(pool:, name:)
      @pool = pool
      @name = name
      @held = false
    end

    # Tries to take the lock without blocking. Returns true if acquired, false
    # if another session already holds it.
    def try_acquire
      row = @pool.exec("SELECT pg_try_advisory_lock(hashtext($1)::bigint) AS locked", [key])
      @held = (row[0]["locked"] == "t")
      @held
    end

    # Releases the lock if held. Best-effort: a closed connection has already
    # dropped it.
    def release
      return unless @held

      @pool.exec("SELECT pg_advisory_unlock(hashtext($1)::bigint)", [key])
      @held = false
    rescue Connection::Error
      nil
    end

    def held?
      @held
    end

    private

    def key
      "#{NAMESPACE}:#{@name}"
    end
  end
end

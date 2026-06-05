# P0 plan — correctness & safety

These are the issues that can corrupt data, lose data, or stall a migration
while reporting success. Each was confirmed against the current source (not the
external review's snapshot). Ordered by impact × severity, with dependencies
noted. Items 1 and 2 share the streaming/apply contract, so 1 is sequenced
first to give 2 a clean foundation. Item 3 is independent and may be done in
parallel.

---

## 1. Harden WAL-consumer error handling; remove the sentinel LSN  *(start here)*

**Severity: high — silent stall.** Refs: review #24, #23.

`Replication::Consumer#stream_loop` catches all errors and pushes a fake
transaction whose `commit_lsn` is `"__error__:<message>"`. The CLI apply loop
never inspects `consumer.last_error`; it applies the empty transaction, calls
`advance_lsn` (which parses the sentinel to `0`), and `checkpoint.set_lsn`
stores the garbage string. The queue is then empty forever, so a **dead
consumer is indistinguishable from "caught up and idle"** — the migration
appears healthy while replication is actually dead.

**Why first:** self-contained, high severity, and it fixes the consumer↔apply
error contract that issue 2's concurrency rework will build on. Cheaper to fix
now than to re-do during the rework.

Tasks:
- Consumer: on rescue, store `@last_error` (under mutex) and let the thread
  exit. Stop enqueuing the sentinel transaction. Add `failed?`.
- CLI apply loop: when the queue drains empty, raise a domain error if the
  consumer has failed, surfacing the original message. Stop using
  `rescue ThreadError` as control flow.
- Add `Pcrd::Replication::Error` domain error; convert it to a clean
  `Thor::Error` at the CLI boundary.
- `Checkpoint::Store#set_lsn`: reject malformed LSNs (defense in depth).
- Tests: unit test that a stream error sets `failed?`/`last_error` and enqueues
  no sentinel; update `streaming_spec` `drain_queue` to assert on `failed?`.

---

## 2. Apply WAL concurrently with backfill, with a bounded queue + backpressure

**Severity: high — OOM / unbounded WAL retention.** Refs: review #1, #2, #14.

The CLI starts the consumer before backfill but only drains `consumer.queue`
*after* backfill finishes. The queue is an unbounded `Thread::Queue`, so every
transaction received during a multi-hour backfill is held in memory, and the
source slot retains WAL until apply begins. This contradicts the README's
"concurrently with backfill" claim and is an OOM risk under write load.

Depends on: item 1 (clean consumer/apply error contract).

Tasks:
- Run an apply worker concurrently with backfill (thread or interleaved loop).
- Bound the queue and apply backpressure (consumer blocks/throttles when full),
  or spool to a durable checkpoint file. Decide and document which.
- Acknowledge (`advance_lsn`) only after durable apply.
- Surface queue depth, last received LSN, last applied LSN.
- If concurrency is deliberately deferred, rename the model to
  "backfill-then-catch-up" in the README and document WAL-retention cost.
- Integration test: sustained writes during a backfill do not grow the queue
  without bound and do not stall.

---

## 3. Make `verify` compare row values, not just existence

**Severity: high — corrupt data passes verification.** Refs: review #4, #5.

`Commands::Verify#spot_check` fetches the source and target rows for sampled
PKs but only branches on `nil` — it never compares column values, despite the
CLI docs promising a "field-by-field" check. A transform bug can silently
corrupt every row and still pass.

Independent of items 1–2; can run in parallel.

Tasks:
- Run sampled source rows through `RowTransformer` to get the expected target
  shape; fetch target rows by mapped target PK; compare values after
  normalization. Report mismatched columns (redacted/truncated).
- Replace `ORDER BY random()` with keyset/`TABLESAMPLE`/hash-mod sampling for
  large tables.
- Tests: a deliberately wrong transform is caught; type-changed columns
  (e.g. int→bigint) compare equal after normalization.

---

## 4. Centralize identifier quoting + schema qualification

**Severity: medium-high — wrong/failed SQL on unusual identifiers or
non-public schema.** Refs: review #3, #11, #44, #33.

Three different quoting conventions coexist: `Backfill::Batch` and
`Apply::Engine#qi` quote; `Schema::DDL.render` and `Schema::Setup` interpolate
raw and hardcode `public`. `Apply::Engine` quotes but does not schema-qualify,
so it relies on `search_path`. Mixed-case/reserved/multi-schema names break or
target the wrong relation.

Best done after item 1 settles; touches many files mechanically.

Tasks:
- Add one identifier helper: `quote_table(schema, table)`, `quote_column`,
  `quote_columns`. Route DDL, Setup, Apply, Verify, Validator through it.
- Make `schema` a first-class per-table config field (default `public`).
- Fully qualify every relation, or set `search_path` explicitly per connection.
- Tests: mixed-case and reserved-word identifiers; a non-public schema table.

---

## 5. Preflight replication-safety fixes

**Severity: low-medium — misleading checks / unguarded delete path.**
Refs: review #45, #8.

- `Preflight#check_replication_slots` computes `needed = tables.length`, but
  setup creates exactly **one** slot for all tables. Fix the needed count to 1
  per migration.
- Preflight does not verify replica identity. The common PK case is fine
  (default identity ships the PK for deletes), so add a check that warns/fails
  only when a migrated table has `REPLICA IDENTITY NOTHING` or a PK-changing
  transform that would break delete matching.

Tasks:
- Correct slot-count arithmetic and message.
- Add a replica-identity preflight check scoped to the unsafe cases.
- Tests: slot-count check passes with one free slot for N tables; a
  `REPLICA IDENTITY NOTHING` table is flagged.

---

### Suggested execution order
1 → (2 ∥ 3) → 4 → 5. Item 3 can start immediately alongside 1.

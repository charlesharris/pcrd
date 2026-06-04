# pcrd — Implementation Plan

---

## Guiding Principles

- **Build vertically, not horizontally.** Each phase delivers a working, testable CLI command rather than a horizontal layer. Prefer shipping `pcrd analyze` completely before touching the replication code.
- **Real databases in tests.** Integration tests spin up actual PostgreSQL instances (Docker). No mocking the `pg` gem — the protocol behavior is too subtle.
- **Fail loudly.** Every phase that touches production data validates preconditions and halts with a clear error rather than proceeding with bad assumptions.
- **Defer polish.** TTY progress bars and colored output come last. The underlying logic must be solid first.

---

## Gem Dependencies

| Gem | Purpose |
|---|---|
| `pg` | PostgreSQL client; replication connections via `PG::Connection` with `replication: 'database'` |
| `thor` | CLI framework |
| `sqlite3` | Checkpoint store |
| `tty-table` | Tabular output for `analyze` |
| `tty-progressbar` | Live progress bars for backfill and lag meter |
| `pastel` | Terminal colors |
| `zeitwerk` | Autoloading (standard in modern Ruby gems) |
| `dry-schema` | Config YAML validation with typed coercion |
| `rspec` | Test framework |
| `faker` | Data generation for example seeder |

Development / test only:
| Gem | Purpose |
|---|---|
| `docker-api` | Spin up PG containers in integration tests |
| `database_cleaner-active_record` | Test isolation in Rails example app |

---

## Project Structure

```
pcrd/
├── exe/
│   └── pcrd                          # CLI entry point (shebang, requires gem)
├── lib/
│   └── pcrd/
│       ├── version.rb
│       ├── cli.rb                    # Thor root command
│       ├── config/
│       │   ├── loader.rb             # YAML → Config::Root struct
│       │   ├── schema.rb             # dry-schema validation
│       │   └── structs.rb            # Config::Root, Source, Target, Table, Column
│       ├── connection/
│       │   ├── pool.rb               # Thin wrapper around PG::Connection
│       │   └── replication.rb        # Opens replication=database connection
│       ├── schema/
│       │   ├── reader.rb             # Queries pg_attribute/pg_type/pg_class
│       │   ├── column.rb             # Value object: name, type, alignment, nullable, default
│       │   ├── packer.rb             # Padding optimizer algorithm
│       │   ├── differ.rb             # Source vs target schema diff
│       │   └── ddl.rb                # Generates CREATE TABLE DDL from config + source schema
│       ├── transform/
│       │   ├── type_map.rb           # Safe/validated cast registry
│       │   ├── row_transformer.rb    # Applies spec to a hash row
│       │   └── validator.rb          # Pre-migration data validation pass
│       ├── replication/
│       │   ├── publication.rb        # CREATE / DROP PUBLICATION
│       │   ├── slot.rb               # CREATE / DROP REPLICATION SLOT
│       │   ├── consumer.rb           # Replication connection loop
│       │   └── pgoutput/
│       │       ├── parser.rb         # Dispatches raw bytes to message types
│       │       └── messages.rb       # Begin, Commit, Relation, Insert, Update, Delete, Type
│       ├── backfill/
│       │   ├── engine.rb             # Keyset-paginated copy loop
│       │   └── batch.rb              # Single batch: SELECT → transform → COPY
│       ├── apply/
│       │   └── engine.rb             # Writes streaming events to target (INSERT/UPDATE/DELETE)
│       ├── checkpoint/
│       │   ├── store.rb              # SQLite adapter
│       │   └── schema.sql            # CREATE TABLE statements for checkpoint DB
│       ├── monitor/
│       │   └── lag.rb                # Polls pg_replication_slots; computes lag + ETA
│       ├── cutover/
│       │   ├── orchestrator.rb       # Drain → verify → sequence advance → report
│       │   └── sequences.rb          # setval automation
│       ├── commands/
│       │   ├── analyze.rb            # pcrd analyze logic
│       │   ├── migrate.rb            # pcrd migrate logic (orchestrates all phases)
│       │   ├── status.rb             # pcrd status logic
│       │   ├── cutover.rb            # pcrd cutover logic
│       │   ├── verify.rb             # pcrd verify logic
│       │   └── cleanup.rb            # pcrd cleanup logic
│       └── output/
│           ├── analyze_printer.rb    # Formats analyze output (tty-table)
│           └── progress.rb           # Backfill + lag progress bars
├── spec/
│   ├── spec_helper.rb
│   ├── support/
│   │   ├── pg_helpers.rb             # Start/stop PG containers, create test databases
│   │   └── fixtures/                 # Sample YAML configs, schema snapshots
│   ├── unit/
│   │   ├── schema/
│   │   ├── transform/
│   │   ├── replication/pgoutput/
│   │   └── backfill/
│   └── integration/
│       ├── analyze_spec.rb
│       ├── migrate_spec.rb
│       └── cutover_spec.rb
├── examples/
│   └── listings_migration/
│       ├── docker-compose.yml
│       ├── migration.yml
│       ├── runbook.md
│       └── rails_app/                # Full Rails app (own Gemfile, etc.)
├── pcrd.gemspec
├── Gemfile
└── README.md
```

---

## Phase 0 — Project Scaffolding

**Goal:** Empty but runnable gem with `pcrd help` working.

**Steps:**

1. `bundle gem pcrd --exe --no-coc --no-mit` — generates skeleton
2. Edit `pcrd.gemspec` — fill metadata, add runtime dependencies
3. Replace generated CLI stub with Thor root command in `lib/pcrd/cli.rb`
4. Add Zeitwerk autoloader in `lib/pcrd.rb`
5. Set up RSpec: `spec/spec_helper.rb`, `.rspec`
6. Add Docker Compose for development in `dev/docker-compose.yml`:
   - `source_db`: postgres:16, port 5433, `wal_level=logical`
   - `target_db`: postgres:16, port 5434
7. Confirm `bundle exec pcrd help` prints command list

**Done criteria:** `pcrd help` works; `bundle exec rspec` runs (0 examples).

---

## Phase 1 — Config Loading

**Goal:** Load and validate a YAML migration config; expose typed structs to all downstream code.

**Files:** `config/loader.rb`, `config/schema.rb`, `config/structs.rb`

**Key implementation notes:**

- Use `dry-schema` to validate the YAML and coerce types. Fail with field-level error messages (not a raw YAML parse exception) so operators can fix config mistakes quickly.
- Passwords must not be in the YAML. `loader.rb` reads `PCRD_SOURCE_PASSWORD` / `PCRD_TARGET_PASSWORD` env vars (or falls back to `~/.pgpass`) and injects them into the connection config struct.
- The `columns:` block in each table spec is a hash keyed by *source* column name. This is important — the transformer always maps from the source name, even for renames.
- Parse `add_columns` as an ordered array (insertion order matters for DDL).

**Data structures:**

```ruby
Config::Root       source:, target:, options:, tables:
Config::Connection host:, port:, database:, user:, password:
Config::Options    batch_size:, lag_threshold_bytes:, replication_slot:,
                   publication:, checkpoint_db:
Config::Table      name:, columns:, add_columns:, optimize_column_order:
Config::Column     type:, rename:, drop:  # all optional; nil = unchanged
Config::AddColumn  name:, type:, default:
```

**Tests:** Unit tests with fixture YAML files covering: valid config, missing required fields, unknown type cast, password from env var.

**Done criteria:** `Config::Loader.load("migration.yml")` returns a `Config::Root`; invalid configs raise with a clear message.

---

## Phase 2 — Connection Management

**Goal:** Reliable PG connections for source (normal + replication) and target.

**Files:** `connection/pool.rb`, `connection/replication.rb`

**Key implementation notes:**

- `pool.rb` wraps `PG::Connection` with automatic reconnect on `PG::ConnectionBad`. Keep it simple — this is not a full connection pool, just a single connection with retry.
- `replication.rb` opens a second connection to source with `dbname: ..., replication: 'database'`. This is a separate protocol mode — it cannot run normal SQL. The caller switches between the two as needed.
- Expose a `Connection::Manager` that takes a `Config::Root` and vends `#source`, `#target`, `#source_replication`.

**Tests:** Integration test: connect to both Docker PG instances, run `SELECT 1`, assert success. Test reconnect on simulated disconnect.

**Done criteria:** `Connection::Manager.new(config).source.exec("SELECT version()")` works against both dev containers.

---

## Phase 3 — Schema Reader and Padding Analyzer

**Goal:** Read a table's schema from a live database; compute optimal column ordering; implement `pcrd analyze` (source only).

**Files:** `schema/reader.rb`, `schema/column.rb`, `schema/packer.rb`, `commands/analyze.rb`, `output/analyze_printer.rb`

**Key implementation notes:**

**Schema::Reader** queries:
```sql
SELECT a.attnum, a.attname, a.atttypid, a.atttypmod, a.attnotnull,
       a.atthasdef, pg_get_expr(d.adbin, d.adrelid) AS default_expr,
       t.typname, t.typalign, t.typlen
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_type t ON t.oid = a.atttypid
LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE c.relname = $1
  AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = $2)
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY a.attnum
```

`t.typalign` values map to alignment bytes: `'c'` → 1, `'s'` → 2, `'i'` → 4, `'d'` → 8.

**Schema::Packer** algorithm:
1. Separate fixed-size columns from variable-length (`typlen = -1`)
2. Sort fixed-size columns by alignment descending (8 → 4 → 2 → 1)
3. Append variable-length columns after (their headers are 4-byte aligned but content is variable)
4. Compute estimated row size for both orderings by summing sizes + padding gaps
5. Padding gap before column N = `(alignment - (current_offset % alignment)) % alignment`

**Output::AnalyzePrinter** uses `tty-table` to render the column layout table and a summary line. Keep the printer as a pure formatter — it takes a data struct, not a database connection.

**Tests:**
- Unit: packer algorithm with a hand-crafted column list; assert ordering and estimated savings match expected values
- Integration: run `analyze` against a real table in the dev source container; assert output includes column names

**Done criteria:** `pcrd analyze --config dev.yml --table listings` prints the current layout, suggested reorder, and savings estimate.

---

## Phase 4 — Schema Diff and `analyze --compare-target`

**Goal:** Compare source and target schemas side-by-side accounting for the migration spec.

**Files:** `schema/differ.rb`, updates to `commands/analyze.rb` and `output/analyze_printer.rb`

**Key implementation notes:**

**Schema::Differ** takes:
- `source_columns` — from `Schema::Reader` on source
- `target_columns` — from `Schema::Reader` on target (may be empty if target table doesn't exist yet)
- `table_config` — the `Config::Table` spec

It produces a diff array, one entry per column in the *union* of source and target, with status: `:unchanged`, `:type_changed`, `:renamed`, `:added`, `:dropped`.

When `--compare-target` is used without a running migration (target table doesn't exist yet), the differ synthesizes the "expected target" by applying the migration spec to the source schema. This lets operators preview what the target will look like before running `migrate`.

**Tests:** Unit tests covering: type change, rename, add, drop, unchanged — all combinations present in the diff output.

**Done criteria:** `pcrd analyze --config dev.yml --compare-target` shows a side-by-side table and padding delta between source and target schemas.

---

## Phase 5 — Type Transformer

**Goal:** Stateless row transformation: apply type casts, renames, drops, and defaults.

**Files:** `transform/type_map.rb`, `transform/row_transformer.rb`, `transform/validator.rb`

**Key implementation notes:**

**Transform::TypeMap** is a registry of cast rules:
```ruby
ALWAYS_SAFE = {
  %w[integer bigint] => ->(v) { v },           # pg gem returns integers natively
  %w[integer numeric] => ->(v) { v.to_d },
  %w[varchar text] => ->(v) { v },
  # ...
}

VALIDATED = {
  %w[bigint integer] => {
    validate: ->(v) { v.between?(-2**31, 2**31 - 1) },
    cast: ->(v) { v },
    error: "value %d exceeds integer range"
  },
  # ...
}
```

**Transform::RowTransformer** takes a `Config::Table` at construction time and exposes `#transform(row_hash) → row_hash`. It:
1. Skips dropped columns
2. Applies rename (changes the key)
3. Applies type cast (changes the value)
4. Injects defaults for added columns (static value or `nil` for `now()` — the target DB computes these on insert via column default)

The row hash uses source column names as keys on input, target column names as keys on output.

**Transform::Validator** runs `SELECT` queries on the source to check validated cast constraints before migration starts. For each validated cast, it runs a `COUNT(*)` query for out-of-range values:
```sql
SELECT COUNT(*) FROM listings WHERE user_id > 2147483647 OR user_id < -2147483648
```
Reports the count and a sample of failing rows.

**Tests:**
- Unit: `RowTransformer` with a fixture row covering all transformation types
- Unit: `Validator` with stub PG results (or real DB) for validated cast check
- Unit: `TypeMap` — every always-safe cast; every validated cast boundary

**Done criteria:** `RowTransformer.new(table_config).transform({"id" => 42, "active" => true, ...})` returns the correctly transformed hash.

---

## Phase 6 — DDL Generation and Preflight

**Goal:** Generate `CREATE TABLE` DDL for target from source schema + migration spec; implement all preflight checks.

**Files:** `schema/ddl.rb`, `commands/migrate.rb` (preflight section)

**Key implementation notes:**

**Schema::DDL** takes `source_columns` + `Config::Table` and generates:
```sql
CREATE TABLE public.listings (
  id bigint NOT NULL,
  list_price_cents integer NOT NULL,
  ...
  updated_at timestamptz DEFAULT now()
);
```

Column order: if `optimize_column_order: true`, pass through `Schema::Packer` first.

DDL does **not** include:
- Foreign key constraints (listed in post-cutover checklist output)
- Indexes (listed separately — operator adds these to target before cutover)

Preflight checks (in order, halt on first failure):
1. Source connection valid; `wal_level = logical`
2. Target connection valid; target table does not exist (or `--force-overwrite`)
3. `max_replication_slots` headroom ≥ 1
4. All source columns referenced in config actually exist
5. All type casts are in `TypeMap` (no unknown casts)
6. **Every migrated table has a primary key or unique not-null index** — required for upsert semantics during the backfill/streaming overlap window. Halt with a clear error and explanation if missing; this is a known footgun in online schema change tooling.
7. Run `Transform::Validator` for all validated casts — report failures and halt
8. Estimate row count and projected backfill duration at default batch size; print and confirm

**Tests:**
- Unit: DDL generation with `optimize_column_order: true` and `false`; spot-check column order in output
- Integration: preflight against dev containers with intentionally broken config; assert each check produces the right error message

**Done criteria:** `pcrd migrate --config dev.yml --preflight-only` prints the preflight report (or halts with errors) without starting the migration.

---

## Phase 7 — Checkpoint Store

**Goal:** SQLite-backed store for per-batch progress, LSN watermark, and migration phase.

**Files:** `checkpoint/store.rb`, `checkpoint/schema.sql`

**Schema:**

```sql
CREATE TABLE IF NOT EXISTS metadata (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- Keys: phase, start_lsn, current_lsn, started_at, table_name

CREATE TABLE IF NOT EXISTS batches (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name   TEXT NOT NULL,
  start_key    TEXT NOT NULL,   -- JSON-encoded composite key for multi-column PKs
  end_key      TEXT NOT NULL,
  row_count    INTEGER NOT NULL,
  duration_ms  INTEGER NOT NULL,
  completed_at TEXT NOT NULL    -- ISO8601
);
```

**Interface:**

```ruby
store = Checkpoint::Store.new("pcrd_checkpoint.sqlite3")
store.phase                          # => :backfill
store.set_phase(:streaming)
store.record_batch(table:, start_key:, end_key:, row_count:, duration_ms:)
store.last_completed_key(table:)     # => last end_key, or nil (fresh start)
store.lsn                            # => "0/3FA2C100"
store.set_lsn("0/3FA2C100")
store.batch_stats(table:)            # => { count:, total_rows:, avg_rows_per_sec: }
```

**Tests:** Unit tests — record batches, resume from last key, phase transitions.

**Done criteria:** A fresh store initializes correctly; a store with recorded batches returns the correct `last_completed_key` for resumption.

---

## Phase 8 — Backfill Engine

**Goal:** Copy all existing rows from source to target with transformation; resumable via checkpoint.

**Files:** `backfill/engine.rb`, `backfill/batch.rb`

**Key implementation notes:**

**Backfill::Batch** executes one batch:
1. `SELECT` from source: `WHERE id > $last_key ORDER BY id LIMIT $batch_size`
2. Pass each row through `RowTransformer`
3. Write to target using `COPY` via `PG::Connection#copy_data` — significantly faster than individual INSERTs for bulk load
4. Record batch in checkpoint store

**Backfill::Engine** drives the loop:
1. Read `last_completed_key` from checkpoint (nil if fresh start)
2. Loop: run batch, checkpoint, advance key, check stop signal
3. Detect completion: batch returns 0 rows
4. On completion: record `backfill_lsn` = LSN at time backfill finished (from `SELECT pg_current_wal_lsn()` on source)

The stop signal is a thread-safe flag (checked between batches) so the WAL consumer thread can request a clean shutdown without killing mid-batch.

Multi-column primary keys: the "key" is a JSON-encoded array. The `WHERE` clause becomes `WHERE (col1, col2) > ($1, $2)` (PostgreSQL supports row-value comparisons).

**Tests:**
- Integration: seed source with 50,000 rows; run backfill; assert target has 50,000 rows with correct types
- Integration: interrupt mid-backfill (kill after 10 batches); resume; assert no rows duplicated or missed

**Done criteria:** `pcrd migrate --config dev.yml --backfill-only` (temporary flag) copies all rows with type transformation, supports `--resume`, and reports progress.

---

## Phase 9 — pgoutput Protocol Parser

**Goal:** Decode raw `pgoutput` binary messages into Ruby structs.

**Files:** `replication/pgoutput/parser.rb`, `replication/pgoutput/messages.rb`

**Key implementation notes:**

The `pg` gem delivers replication messages as raw strings. The pgoutput protocol prefixes each message with a 1-byte type tag.

**Messages to implement:**

```ruby
module Pcrd::Replication::Pgoutput
  Begin   = Data.define(:final_lsn, :commit_time, :xid)
  Commit  = Data.define(:lsn, :end_lsn, :commit_time)
  Relation = Data.define(:id, :namespace, :name, :replica_identity, :columns)
  RelationColumn = Data.define(:flags, :name, :type_id, :atttypmod)
  Insert  = Data.define(:relation_id, :new_row)   # new_row: Array of typed values
  Update  = Data.define(:relation_id, :old_row, :new_row)
  Delete  = Data.define(:relation_id, :old_row)
  Type    = Data.define(:id, :namespace, :name)
end
```

**Parser** is a single `#parse(message_bytes)` method:
```ruby
def parse(bytes)
  tag = bytes[0]
  data = bytes[1..]
  case tag
  when 'B' then parse_begin(data)
  when 'C' then parse_commit(data)
  when 'R' then parse_relation(data)
  when 'I' then parse_insert(data)
  when 'U' then parse_update(data)
  when 'D' then parse_delete(data)
  when 'T' then parse_type(data)
  else raise UnknownMessageType, "tag=#{tag.inspect}"
  end
end
```

Binary decoding uses `String#unpack1` / `#unpack` — document the format string for each message type against the PostgreSQL protocol spec. Timestamps are microseconds since 2000-01-01 (PG epoch), not Unix epoch — convert accordingly.

Tuple data (`TupleData`) for Insert/Update/Delete: columns are encoded as `'n'` (null), `'u'` (unchanged toast), or `'t'` (text) with a length prefix. Parse each column against the `Relation` message's column list (cached by relation_id).

**Tests:**
- Unit: capture real pgoutput bytes (from a throwaway integration test) and assert they parse to the correct struct fields. Store the raw bytes as fixtures — this makes the unit tests fast and deterministic.
- Test each message type independently.

**Done criteria:** A fixture byte string for each message type parses to the correct struct with correct field values.

---

## Phase 10 — WAL Consumer and Apply Engine

**Goal:** Stream WAL changes from source, transform, and apply to target; handle backfill/streaming overlap.

**Files:** `replication/consumer.rb`, `apply/engine.rb`

**Key implementation notes:**

**Replication::Consumer** runs in its own thread:
1. Open replication connection
2. `START_REPLICATION SLOT $slot LOGICAL $start_lsn (proto_version '1', publication_names '$pub')`
3. Loop reading messages from the connection:
   - Keepalive messages: respond with standby status update (advance `confirmed_flush_lsn`)
   - Data messages: decode via `Pgoutput::Parser`; buffer into current transaction
   - On `Commit`: enqueue the complete transaction to an in-process queue (`Thread::Queue`)
4. The `start_lsn` is:
   - During backfill: the slot's `confirmed_flush_lsn` at slot creation time (capture all changes from the start)
   - After backfill: the `backfill_lsn` recorded by the backfill engine

**Overlap handling:** The consumer always starts before backfill. During backfill, committed transactions pile up in the queue. The backfill engine signals completion by writing `backfill_lsn` to the checkpoint. After that, the apply engine processes the queue from oldest to newest. Because backfill uses `INSERT ... ON CONFLICT DO UPDATE` (upsert), rows inserted by both backfill and WAL replay are handled correctly — WAL wins for concurrent updates.

**Apply::Engine** reads from the consumer's queue and applies to target:
- `Insert` → `INSERT INTO target (...) VALUES (...) ON CONFLICT (pk) DO UPDATE SET ...`
- `Update` → `UPDATE target SET ... WHERE pk = ...`
- `Delete` → `DELETE FROM target WHERE pk = ...`

Apply runs in a tight loop, batching multiple changes into a single transaction when the queue has backlog (improves throughput under heavy load).

After applying each transaction, advance `confirmed_flush_lsn` to tell the source it can reclaim WAL.

**Lag Monitor** (in `monitor/lag.rb`):
- Polls `SELECT slot_name, confirmed_flush_lsn, pg_current_wal_lsn(), pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes FROM pg_replication_slots WHERE slot_name = $1` every 2 seconds
- Maintains a rolling window of lag readings to compute rate of change and ETA

**Tests:**
- Integration: seed source, start consumer + apply, INSERT/UPDATE/DELETE on source, assert changes appear on target within 5 seconds
- Integration: simulate backfill/streaming overlap — write rows during backfill, assert they appear correctly on target after overlap resolution

**Done criteria:** `pcrd migrate --config dev.yml` runs to the catchup phase with a live lag meter.

---

## Phase 11 — Cutover, Sequences, and Verify

**Goal:** Implement the full cutover sequence, sequence automation, and verification.

**Files:** `cutover/orchestrator.rb`, `cutover/sequences.rb`, `commands/cutover.rb`, `commands/verify.rb`

**Key implementation notes:**

**Cutover::Sequences** for each table with a serial/bigserial/identity column:
1. `SELECT last_value, is_called FROM {table}_{col}_seq` on source
2. `SELECT MAX({col}) FROM {table}` on source
3. `target_value = [last_value (if is_called), max_col].max + safety_buffer`
4. `SELECT setval('{table}_{col}_seq', $target_value)` on target
5. Log: `setval('listings_id_seq', 800000142) -- source last_value=800000141, source max=800000139`

Sequence discovery: query `pg_sequences` joined to `pg_depend` to find sequences owned by columns in the migrated tables. Don't require explicit config — auto-detect all owned sequences.

**Cutover::Orchestrator** sequence:
1. Confirm migration is in `:catchup` or `:ready` phase (from checkpoint)
2. Confirm operator has acknowledged maintenance mode is active (interactive prompt or `--maintenance-confirmed` flag)
3. Poll until lag = 0 (max wait: configurable, default 5 minutes; error if exceeded)
4. Run row count verification: `SELECT COUNT(*) FROM listings` on both clusters; assert within tolerance (default: must match exactly)
5. Run `Cutover::Sequences` for all tables
6. Print cutover report (counts, sequence setvals, FK constraints to add, indexes to verify)
7. Print: `✓ Ready. Switch DATABASE_URL to target cluster and restart application.`
8. Wait for operator to run `pcrd verify --post-cutover` (optional)

**Commands::Verify** (`pcrd verify`):
- Row count: `SELECT COUNT(*) FROM each_table`
- Spot-check: `SELECT * FROM listings WHERE id IN (SELECT id FROM listings ORDER BY random() LIMIT $sample_size)` — compare each row field-by-field with target, reporting mismatches

**Tests:**
- Integration: full end-to-end — seed source, run migrate, run cutover, assert all sequences advanced correctly, assert verify passes

**Done criteria:** `pcrd cutover --config dev.yml --maintenance-confirmed` runs the full sequence and prints the cutover report.

---

## Phase 12 — `pcrd status` and `pcrd cleanup`

**Goal:** Implement the remaining CLI commands.

**Files:** `commands/status.rb`, `commands/cleanup.rb`

**`pcrd status`** reads checkpoint store + queries `pg_replication_slots` live:
```
Migration: listings_v2  |  Phase: streaming  |  Started: 2h 14m ago
Backfill:  800,000,000 rows  |  100% complete  |  avg 45,231 rows/sec
Replication lag:  1.2 MB  |  ~3s  |  ↓ trending down
Ready for cutover: not yet (lag threshold: 1 MB)
```

**`pcrd cleanup`**:
1. Drop replication slot: `SELECT pg_drop_replication_slot($slot)` on source
2. Drop publication: `DROP PUBLICATION $pub` on source
3. Delete checkpoint SQLite file
4. If `--drop-source`: `DROP TABLE $table` on source (requires typing table name to confirm)

**Done criteria:** Both commands work against a running or completed migration.

---

## Phase 13 — Docker Compose Example + Data Generator

**Goal:** A self-contained example that demonstrates the full migration workflow.

**Location:** `examples/listings_migration/`

**Files:**

```
examples/listings_migration/
├── docker-compose.yml        # source_db, target_db, rails_app services
├── migration.yml             # pcrd config for the example migration
├── seed/
│   ├── Gemfile               # standalone seeder (faker, pg)
│   └── generate.rb           # usage: ruby generate.rb --rows 1_000_000
├── runbook.md                # step-by-step operator guide
└── rails_app/
    ├── Gemfile
    ├── config/database.yml
    ├── db/
    │   ├── schema.rb
    │   └── seeds.rb
    └── app/models/...
```

**docker-compose.yml** services:
- `source_db`: postgres:16 on port 5433; `wal_level=logical`; initialized with source schema
- `target_db`: postgres:16 on port 5434; no schema (pcrd creates it)
- `rails_app`: the example app, connecting to `source_db`

**Data generator** (`seed/generate.rb`):
- Accepts `--rows N` and `--tables listings,users,agents` (comma-separated)
- Seeds related tables in dependency order (users → agents → listings)
- Uses multi-row `INSERT` in batches of 1,000 for speed
- Provides realistic data via Faker: addresses, prices, timestamps, names
- Prints progress and estimated time

**Example migration spec** (`migration.yml`):
- `listings.id`: `integer → bigint`
- `listings.list_price`: `numeric(10,2) → numeric(18,4)` (rename + type)
- `listings.status_code`: rename to `listing_status`
- `listings.old_notes`: drop
- Add `listings.updated_at: timestamptz`
- `optimize_column_order: true`
- `users.id`: `integer → bigint`

**Rails app** has a controller that reads/writes listings so you can demonstrate the app staying live during the migration (via `SHOW PROCESS LIST` on source during backfill).

**Runbook** (`runbook.md`) walks through:
1. `docker compose up`
2. `ruby seed/generate.rb --rows 500_000`
3. `pcrd analyze --config migration.yml`
4. `pcrd migrate --config migration.yml`
5. Watch `pcrd status` in a second terminal
6. `pcrd analyze --config migration.yml --compare-target`
7. Put Rails app in maintenance mode
8. `pcrd cutover --config migration.yml --maintenance-confirmed`
9. Update `DATABASE_URL` in `docker-compose.yml` to `target_db`, restart `rails_app`
10. `pcrd verify --config migration.yml`

**Done criteria:** A fresh checkout can run the complete runbook end-to-end.

---

## Phase 14 — Polish and README

**Goal:** Production-quality error messages, help text, and documentation.

**Tasks:**

- Audit all error paths — every user-visible exception should have an actionable message
- Ensure `--help` text on every command is complete and accurate
- Write `README.md` covering: installation, quick start, full command reference, source DB requirements, limitations
- Ensure `pcrd migrate` handles `SIGINT` (Ctrl-C) gracefully: finish current batch, write checkpoint, drop to a clean exit with a "Resume with --resume" message
- Add a `--dry-run` flag to `migrate` that runs preflight + prints the DDL it would execute without touching the target
- Integration test coverage for all failure modes in the design doc's §12 table

**Done criteria:** A developer who has not read the design doc can install the gem, read the README, and run the example successfully.

---

## Milestone Summary

| Phase | Deliverable | CLI command unlocked |
|---|---|---|
| 0 | Gem skeleton | `pcrd help` |
| 1–2 | Config + connections | — |
| 3 | Schema reader + packer | `pcrd analyze` (source) |
| 4 | Schema differ | `pcrd analyze --compare-target` |
| 5–6 | Transformer + DDL + preflight | `pcrd migrate --preflight-only` |
| 7–8 | Checkpoint + backfill | `pcrd migrate` (backfill only) |
| 9–10 | pgoutput parser + streaming | `pcrd migrate` (full) |
| 11 | Cutover + verify | `pcrd cutover`, `pcrd verify` |
| 12 | Status + cleanup | `pcrd status`, `pcrd cleanup` |
| 13 | Example + data generator | Full runbook |
| 14 | Polish + README | — |

---

## Notes

- `--preflight-only` and `--backfill-only` flags on `pcrd migrate` are first-class features, not dev scaffolding. `--preflight-only` is useful for operators who want to validate a config before a maintenance window; `--backfill-only` is useful for staged migrations and debugging.
- The primary key requirement is enforced at preflight with a clear error. This is a known footgun — tables without PKs silently corrupt data during online schema changes when backfill and streaming overlap. Surface it loudly.

*Document status: approved for implementation.*

# pcrd — PostgreSQL Column Rewrite Daemon

**Design Document**

---

## 1. Problem Statement

PostgreSQL's `ALTER TABLE ... ALTER COLUMN ... TYPE` acquires an `AccessExclusiveLock` and rewrites the entire table before releasing it. On large tables this means minutes to hours of complete read/write blackout — unacceptable for production systems where availability is required.

Common scenarios that trigger this problem:

- **Integer ID overflow** — a table that started with `id integer` (~2.1B max) is approaching the limit and needs `id bigint`. Every second of downtime during the ALTER is a second of writes lost.
- **Precision changes** — `numeric(10,2)` → `numeric(18,4)` for financial data as requirements evolve.
- **Type corrections** — `varchar(255)` → `text`, `timestamp` → `timestamptz`, etc.
- **Structural cleanup** — column renames, dropping dead columns, reordering columns to eliminate padding waste.

pcrd solves this by building the new schema on a separate PostgreSQL cluster using logical replication, keeping it continuously synchronized, and enabling a cutover that requires only seconds of application downtime.

---

## 2. Goals

- **Zero-schema-lock migrations** — the source database runs normally throughout; no `AccessExclusiveLock` held for more than milliseconds at cutover.
- **Cross-cluster operation** — source and target are separate PostgreSQL servers; the tool does not require being on the same host or cluster.
- **Type transformation** — rewrite column types during replication (widening casts are automatic; lossy casts require explicit opt-in and a validation pass).
- **Full schema change support** — column type changes, renames, additions, drops, and reordering in a single migration spec.
- **Column padding analysis** — standalone command to analyze a table's column alignment and estimate space savings from reordering, with no migration required.
- **Operator-controlled cutover** — the tool signals readiness; the operator triggers cutover at an appropriate time (e.g. low-traffic window). The tool never cuts over automatically.
- **Resumable** — a migration can be interrupted and resumed without restarting from scratch (checkpointed backfill, replication slot persists).
- **No source-side extensions required** — uses PostgreSQL's built-in `pgoutput` logical replication protocol (available in PG 10+).

## 3. Non-Goals

- **Automatic application cutover** — pcrd does not manage connection strings, pgBouncer, load balancers, or deployment systems. Cutover coordination is the operator's responsibility.
- **Schema-identical replication** — pcrd is not a general-purpose replication tool. If you want an exact replica with no changes, use Postgres's built-in streaming replication or logical replication subscriptions.
- **DDL replication** — changes made to the source schema after `pcrd migrate` starts are not automatically applied to the target. The migration spec is fixed at start time.
- **MySQL / other databases** — PostgreSQL only.
- **Minimum PG version below 10** — logical replication (`pgoutput`) requires PG 10+. PG 14+ is recommended for improved logical replication stability.

---

## 4. Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Source Cluster                                                      │
│                                                                      │
│  ┌──────────────┐   WAL (pgoutput)   ┌───────────────────────────┐  │
│  │  live table  │ ─────────────────► │  replication slot         │  │
│  │  (old schema)│                    │  publication               │  │
│  └──────────────┘                    └───────────────────────────┘  │
│         │                                        │                   │
│         │ bulk copy (backfill)                   │ streaming WAL     │
└─────────┼────────────────────────────────────────┼───────────────────┘
          │                                        │
          ▼                                        ▼
┌─────────────────────────────────────────────────────────────────────┐
│  pcrd process                                                        │
│                                                                      │
│  ┌─────────────┐   ┌──────────────┐   ┌──────────────────────────┐  │
│  │  Backfill   │   │  WAL Consumer│   │  Type Transformer        │  │
│  │  Engine     │   │  (pgoutput   │   │  (cast rules, renames,   │  │
│  │  (keyset    │   │   parser)    │   │   add/drop columns)      │  │
│  │   paginate) │   └──────┬───────┘   └──────────────────────────┘  │
│  └──────┬──────┘          │                        │                 │
│         └─────────────────┴────────────────────────┘                │
│                                    │                                 │
│                           ┌────────▼────────┐                       │
│                           │  Apply Engine   │                       │
│                           │  (writes to     │                       │
│                           │   target)       │                       │
│                           └────────┬────────┘                       │
│                                    │                                 │
│  ┌───────────────┐   ┌─────────────▼──────────┐                     │
│  │  Lag Monitor  │   │  Checkpoint Store       │                     │
│  │  (replication │   │  (backfill progress,    │                     │
│  │   lag, ETA)   │   │   LSN watermark)        │                     │
│  └───────────────┘   └────────────────────────┘                     │
└─────────────────────────────────────────────────────────────────────┘
          │
          ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Target Cluster                                                      │
│                                                                      │
│  ┌──────────────┐                                                    │
│  │  live table  │  ← same name, new schema                          │
│  │  (new schema)│                                                    │
│  └──────────────┘                                                    │
└─────────────────────────────────────────────────────────────────────┘
```

### Component Descriptions

**Backfill Engine** — copies existing rows from source to target in batches using keyset pagination (e.g. `WHERE id > $last_id ORDER BY id LIMIT 10000`). Works on the primary key or a unique not-null index. Applies type casts and schema transforms to each row before writing. Writes checkpoint after each batch so resumption skips already-copied rows.

**WAL Consumer** — opens a logical replication connection to the source, starts `START_REPLICATION` against the replication slot, and streams `pgoutput` protocol messages. Decodes `Begin`, `Commit`, `Relation`, `Insert`, `Update`, `Delete` messages. Buffers full transactions before applying (to apply atomically on the target).

**Type Transformer** — applies the migration spec to each row/change event: casts column types, applies renames (maps old column names to new), drops excluded columns, inserts defaults for added columns. Stateless — same input always produces same output.

**Apply Engine** — writes transformed rows and change events to the target using batched `COPY` (for backfill) and `INSERT/UPDATE/DELETE` (for streaming events). Uses a connection pool sized to the configured concurrency.

**Lag Monitor** — periodically queries `pg_replication_slots` on the source and compares `confirmed_flush_lsn` against `pg_current_wal_lsn()`. Tracks lag in bytes and estimated seconds. Displayed in the CLI progress output; gatekeeps cutover.

**Checkpoint Store** — a SQLite database tracking per-batch progress: each completed batch is recorded with its start key, end key, row count, duration, and timestamp. This provides auditable completeness (no key range gaps), enables targeted resumption after type-cast errors in a specific batch, and supplies the throughput data (rows/sec per batch) used for ETA estimation. The current LSN watermark, migration phase, and start time are stored as metadata rows in the same database.

---

## 5. Migration Phases

### Phase 1: Preflight

- Verify source and target connections
- Check `wal_level = logical` on source
- Check target is writable and table does not already exist (or prompt)
- Validate migration spec: all referenced columns exist, all type casts are known
- **Verify each migrated table has a primary key or unique not-null index.** The apply engine uses upsert semantics (`INSERT ... ON CONFLICT DO UPDATE`) during the backfill/streaming overlap window. Without a primary key or unique constraint on the target table, this is not possible and the migration cannot proceed. This requirement must be surfaced clearly — in practice, tables without primary keys are the source of subtle data corruption bugs during online schema changes, and we learned this the hard way.
- Run type safety checks (see §6)
- Estimate table size and projected duration
- Report and require explicit confirmation before proceeding

### Phase 2: Setup

- Create a `PUBLICATION` on the source covering the target tables
- Create a logical replication slot (`pg_create_logical_replication_slot`) — this is the point of no return for WAL retention on source
- Generate and execute `CREATE TABLE` DDL on target with new schema
- Initialize checkpoint file

### Phase 3: Backfill

- Copy all existing rows in batches, keyset-paginated by primary key
- Apply type transformer to each row
- Checkpoint after each batch (configurable batch size, default 10,000 rows)
- Runs concurrently with Phase 4 once started — the WAL consumer buffers events that arrive during backfill and applies them after backfill catches up to the current LSN

### Phase 4: Streaming

- WAL consumer runs throughout phases 3–5
- Events that arrive during backfill are buffered (in memory, up to a configurable limit; spills to disk beyond that)
- Once backfill completes, buffered events are replayed in order
- Normal streaming resumes from current WAL position

### Phase 5: Catchup

- Display live lag meter (bytes behind, estimated seconds)
- Block cutover signal until lag drops below threshold (default: < 1MB / < 5s estimated)
- Operator observes and decides when to trigger cutover

### Phase 6: Cutover (operator-triggered)

Cutover requires the application to be in maintenance mode before `pcrd cutover` is run. pcrd does not enforce this — it is the operator's responsibility. Once `pcrd cutover` is invoked, it assumes writes to the source have stopped.

**Procedure:**

1. Operator puts application into maintenance mode (see below)
2. Operator runs `pcrd cutover --config migration.yml`
3. pcrd drains remaining WAL events — polls until lag reaches zero
4. pcrd advances sequences on target (see §13)
5. pcrd runs row-count verification across all migrated tables
6. pcrd prints cutover report and "READY — switch application to target cluster"
7. Operator updates `DATABASE_URL` (or equivalent) and restarts application against target
8. Operator confirms application is healthy, then ends maintenance mode
9. Source cluster remains running and untouched until `pcrd cleanup` is run

**Maintenance mode approaches by setup:**

| Setup | Approach |
|---|---|
| **Rails + Rack** | Add `Rack::Maintenance` middleware (or equivalent) controlled by a file flag or env var. Set the flag before running `pcrd cutover`; clear it after the app restarts against target. |
| **Rails + pgBouncer** | Run `PAUSE <database>` on pgBouncer. This queues new queries without returning errors. Run `RESUME` after cutover. Cleanest approach — no application changes needed. |
| **Kubernetes** | Scale the application deployment to 0 replicas (`kubectl scale --replicas=0`). Scale back up with new `DATABASE_URL` env var after cutover. |
| **Heroku / similar PaaS** | Enable maintenance mode (`heroku maintenance:on`); update `DATABASE_URL` config var; restart (`heroku restart`); disable maintenance mode. |
| **Reverse proxy (nginx/haproxy)** | Return 503 from upstream health check to drain connections, then re-route to new cluster after cutover. |

The pgBouncer `PAUSE` approach is preferred when available — it queues rather than rejects requests, and the pause duration is typically under 10 seconds, making it transparent to most clients.

### Phase 7: Verify

- Row count comparison (source vs. target)
- Checksum spot-check: random sample of N rows compared across source and target
- Reports any discrepancies

### Phase 8: Cleanup (separate command, run later)

- Drop replication slot and publication on source
- Optionally drop source tables (requires explicit `--drop-source` flag; never done automatically)
- Delete checkpoint file

---

## 6. Type Safety Rules

pcrd categorizes type changes into three classes:

### Always-safe (automatic)

No data validation required. These are pure widening casts with no possible data loss:

| From | To |
|---|---|
| `smallint` | `integer`, `bigint`, `numeric`, `real`, `double precision` |
| `integer` | `bigint`, `numeric`, `real`, `double precision` |
| `real` | `double precision` |
| `char(n)` | `varchar(n)`, `text` |
| `varchar(n)` | `text`, `varchar(m)` where m > n |
| `timestamp` | `timestamptz` (with explicit timezone setting) |
| `date` | `timestamp`, `timestamptz` |

### Validated (require a validation pass)

pcrd runs a pre-migration check to confirm no data would be truncated or rejected. Proceeds automatically if validation passes; errors with details if not:

| From | To | Validation check |
|---|---|---|
| `bigint` | `integer` | All values within [-2^31, 2^31-1] |
| `numeric(p,s)` | `numeric(p2,s2)` | All values fit in new precision/scale |
| `text` / `varchar` | `varchar(n)` | All values len ≤ n |
| `double precision` | `real` | Precision loss acceptable (warn only by default) |
| `text` | `integer` / `bigint` / `numeric` | All values parse as target type |
| `timestamptz` | `timestamp` | Explicit acknowledgment of timezone loss |

### Unsupported (rejected)

Changes that are non-trivial to validate or semantically ambiguous (e.g. `bytea` → `text`, `json` → `jsonb` without inspection). These require a custom transform function to be specified in the migration spec, or must be handled outside pcrd.

---

## 7. Column Padding Analysis

PostgreSQL stores tuple data in definition order. Each column is aligned to its type's natural alignment boundary, which can introduce padding bytes between columns.

**Alignment rules:**

| Alignment | Types |
|---|---|
| 8 bytes | `bigint`, `double precision`, `timestamp`, `timestamptz`, `interval`, `money` |
| 4 bytes | `integer`, `real`, `date`, `oid`, `xid`, `numeric` header, `varchar`/`text` header |
| 2 bytes | `smallint` |
| 1 byte | `boolean`, `char` |
| Variable | `text`, `varchar`, `bytea`, `json`, `jsonb`, `arrays` (4-byte aligned header) |

**Optimal column order:** sort by decreasing alignment — 8-byte, then 4-byte, then 2-byte, then 1-byte, then variable-length. This minimizes padding by ensuring each column starts at an already-aligned offset.

### `pcrd analyze` output example

By default, `analyze` connects to the source and reports the current layout alongside the optimal reordering:

```
Table: public.listings (source)
Columns: 14  |  Estimated row size (current): 87 bytes  |  With padding: 104 bytes

Current order:
  id              integer         4-byte   offset 0    size 4
  active          boolean         1-byte   offset 4    size 1    [3 bytes padding after]
  price           numeric(12,2)   4-byte   offset 8    size 8
  title           text            variable offset 16   size var
  created_at      timestamptz     8-byte   offset var  size 8    [0-7 bytes padding before]
  ...

Suggested order (optimized):
  id              integer         4-byte
  price           numeric(12,2)   4-byte
  created_at      timestamptz     8-byte
  ...
  active          boolean         1-byte

Estimated savings: 17 bytes/row  (16.3%)
At 800,000,000 rows: ~12.7 GB reclaimed
```

With `--compare-target`, `analyze` also connects to the target cluster and shows the current schemas side-by-side, including type differences, renames, added/dropped columns, and the padding analysis for each:

```
Table: public.listings
                        SOURCE                      TARGET
  id              integer    (4-byte)     bigint          (8-byte)  [type change]
  active          boolean    (1-byte)     active          (1-byte)
  list_price      numeric(10,2)           list_price_cents integer   [renamed + type change]
  legacy_notes    text                    —                          [dropped]
  —                                       updated_at timestamptz    [added]

  Source row size (w/ padding):  104 bytes
  Target row size (w/ padding):   88 bytes  (-15.4%)
  At 800,000,000 rows: ~11.9 GB smaller on target
```

The `analyze` command (both modes) is read-only and requires no migration to be in progress.

---

## 8. Configuration

Migrations are specified in a YAML file passed via `--config`:

```yaml
source:
  host: db-primary.old.example.com
  port: 5432
  database: myapp_production
  user: pcrd_replication
  # password: via PCRD_SOURCE_PASSWORD env var or .pgpass

target:
  host: db-primary.new.example.com
  port: 5432
  database: myapp_production
  user: pcrd_writer
  # password: via PCRD_TARGET_PASSWORD env var or .pgpass

options:
  batch_size: 10_000          # rows per backfill batch
  lag_threshold_bytes: 1_048_576  # 1MB — gate for cutover readiness
  replication_slot: pcrd_listings_v2
  publication: pcrd_pub_listings_v2
  checkpoint_db: ./pcrd_checkpoint.sqlite3

tables:
  - name: listings
    optimize_column_order: true   # reorder columns for padding efficiency
    columns:
      id:
        type: bigint              # integer → bigint (always-safe)
      price_cents:
        rename: list_price_cents  # rename only, type unchanged
      price_currency:
        type: varchar(3)          # varchar(255) → varchar(3) (validated)
      legacy_notes:
        drop: true
    add_columns:
      - name: updated_at
        type: timestamptz
        default: "now()"

  - name: users
    columns:
      id:
        type: bigint
```

---

## 9. CLI Commands

```
pcrd analyze  --config migration.yml [--table TABLE] [--compare-target]
              Analyze column padding for source tables. No migration started.
              Outputs current layout, suggested reorder, and estimated space savings.
              With --compare-target: connects to target cluster and shows source vs.
              target schemas side-by-side, including all type changes and padding delta.

pcrd migrate  --config migration.yml [--resume]
              Start (or resume) the migration. Runs preflight, setup, backfill,
              and streaming. Stays running until operator triggers cutover or
              process is interrupted (resumable).

pcrd status   --config migration.yml
              Show current migration phase, replication lag, backfill progress,
              and estimated time to cutover readiness. Read-only.

pcrd cutover  --config migration.yml
              Trigger cutover sequence (must be in catchup/ready phase).
              Pauses source writes, drains lag, confirms parity, then signals
              operator to switch connection strings.

pcrd verify   --config migration.yml [--sample-size N]
              Compare row counts and spot-check N random rows across clusters.
              Safe to run at any point after backfill completes.

pcrd cleanup  --config migration.yml [--drop-source]
              Drop replication slot, publication, and checkpoint file.
              With --drop-source: also drops source tables (requires confirmation).
```

---

## 10. Source Database Requirements

The source PostgreSQL user needs:

```sql
-- Replication permission
ALTER ROLE pcrd_replication REPLICATION;

-- Read access to migrated tables
GRANT SELECT ON TABLE listings, users TO pcrd_replication;

-- Create publication (requires superuser or pg_monitor in PG14+)
-- Or have a superuser create it and grant usage
GRANT CREATE ON DATABASE myapp_production TO pcrd_replication;
```

`postgresql.conf` on source must have:
```
wal_level = logical
max_replication_slots = <current + number of pcrd migrations>
max_wal_senders = <current + number of pcrd migrations>
```

---

## 11. Replication Protocol Details

pcrd uses the `pgoutput` logical replication plugin (built into PostgreSQL since version 10). No extensions are required on the source server.

### Connection setup

```
PG connection with replication=database parameter
→ CREATE_REPLICATION_SLOT slot_name LOGICAL pgoutput NOEXPORT_SNAPSHOT
→ START_REPLICATION SLOT slot_name LOGICAL start_lsn (proto_version '1', publication_names 'pub_name')
```

### Message types decoded

| Byte | Message | Purpose |
|---|---|---|
| `B` | Begin | Transaction start; carries final LSN and commit timestamp |
| `C` | Commit | Transaction committed; advance confirmed LSN |
| `R` | Relation | Table schema snapshot; cached for column name/type lookup |
| `I` | Insert | New row data |
| `U` | Update | Before/after row data (identity columns + changed columns) |
| `D` | Delete | Deleted row identity (requires REPLICA IDENTITY on source table) |
| `T` | Type | Custom type OID definition |

### Backfill / streaming overlap

The replication slot is created before backfill starts. This ensures that all WAL changes during backfill are retained and can be replayed. The backfill engine records the LSN at which it completes each batch. Once backfill finishes, the WAL consumer replays from `backfill_start_lsn` up to current, then transitions to normal streaming. This means each row is guaranteed to be written at least once (and the WAL consumer's upsert semantics handle any duplicates from the overlap window).

### REPLICA IDENTITY

`DELETE` events only carry the replica identity columns (default: primary key). For `UPDATE` events, pcrd can work with the default identity. If a table has no primary key, `REPLICA IDENTITY FULL` must be set on the source table to enable DELETE support.

---

## 12. Failure Modes and Recovery

| Scenario | Behavior |
|---|---|
| pcrd process dies during backfill | Resume with `--resume`; skips already-checkpointed batches; replication slot retains WAL |
| Target cluster unreachable | pcrd retries with backoff; WAL accumulates in replication slot on source; operator must monitor source disk if outage is extended |
| Source WAL disk pressure | Operator can pause by stopping pcrd (slot retains position); or run `pcrd cleanup` to abort and free the slot |
| Replication slot consumed by another subscriber | Preflight checks slot existence; `pcrd status` warns if slot is being consumed by unexpected clients |
| Type validation failure during backfill | Hard stop with row details; operator fixes data or adjusts migration spec; resume after fix |
| Cutover fails mid-sequence | Source continues (maintenance mode still active); target may be slightly behind; operator extends maintenance window; re-run `pcrd cutover` to retry from the drain step |

---

## 13. Known Limitations

- **Sequences** — Sequence advancement is automated as part of the `cutover` command. After writes stop, pcrd queries each sequence's `last_value` on source, computes `MAX(id)` on source (to account for rolled-back transactions that consumed sequence values), takes the higher of the two, adds a configurable safety buffer (default: +1000), and runs `setval` on the target. The cutover report logs the exact `setval` calls made for the audit trail. Sequences for added columns with `DEFAULT nextval(...)` are initialized on the target from 1 unless an explicit seed value is given in the migration spec.
- **Foreign keys** — inter-table foreign key constraints on the target should be deferred or added post-cutover. pcrd creates the target table without FK constraints by default; they are listed in the post-cutover checklist.
- **Large objects** — `pg_largeobject` data is not replicated via logical replication. Tables referencing large object OIDs must be handled separately.
- **Generated columns** — PostgreSQL does not include generated column values in WAL. pcrd will define generated columns on the target identically; the values are computed by the target database.
- **DDL changes during migration** — if a column is added or dropped on the source after the migration starts, the WAL consumer will encounter `Relation` messages that differ from the migration spec. pcrd will halt with a clear error rather than silently corrupt data.
- **Partitioned tables** — partitioned tables are supported but each partition must be listed individually in the migration spec. Automatic partition discovery is a planned future feature.
- **Primary key required** — every migrated table must have a primary key or unique not-null index on both source and target. This is a hard requirement: the apply engine uses upsert semantics to handle the backfill/streaming overlap window, and without a unique constraint there is no safe way to deduplicate rows that appear in both the bulk copy and the WAL stream. Preflight will halt with a clear error for any table missing this constraint.

---

## 14. Example Scenario

See `examples/` for a complete Docker Compose setup demonstrating:

- Source PostgreSQL cluster with a `listings` table at scale (seeded with configurable row count)
- Target PostgreSQL cluster
- Rails application connecting to source
- Migration config for: `id integer → bigint`, `list_price numeric(10,2) → numeric(18,4)`, column rename, column reorder with padding optimization
- Step-by-step runbook for running the migration, monitoring lag, and cutting over with zero application errors

---

*Document status: draft — pending review before implementation begins.*

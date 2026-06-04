# pcrd — PostgreSQL Column Rewrite Daemon

**Pronounced "Picard."** Zero-downtime cross-cluster PostgreSQL migrations using logical replication.

pcrd migrates large tables to a new PostgreSQL cluster with column type changes, renames, additions, drops, and column reordering — without locking your source database for more than a few seconds at cutover.

---

## The Problem

`ALTER TABLE t ALTER COLUMN id TYPE bigint` on a 500M-row table acquires an `AccessExclusiveLock` and rewrites every row while holding it. That means minutes to hours of complete read/write blackout — unacceptable in production.

pcrd solves this by building the new schema on a separate cluster using logical replication, streaming all changes from source to target continuously, and then cutting over with only a brief maintenance window (seconds, not hours).

---

## How It Works

```
Source cluster                pcrd                    Target cluster
──────────────                ────                    ──────────────
live table        ─WAL─────►  WAL consumer           new schema table
(old types)                   type transformer   ──►  (new types)
     │            ─bulk──────► backfill engine    ──►
     │                         lag monitor
     │                         cutover (brief lock)
     │
App  ──── DATABASE_URL ────────────────────────────► switch here
```

**Phases:**
1. **Preflight** — validate connections, WAL level, type cast safety, PK existence
2. **Setup** — create publication + replication slot on source; DDL on target
3. **Backfill** — bulk copy existing rows via keyset-paginated `COPY`, checkpointed
4. **Streaming** — consume WAL events, transform, apply to target concurrently with backfill
5. **Catchup** — monitor replication lag; display live lag meter
6. **Cutover** — operator-triggered; drain lag to zero, advance sequences, signal ready
7. **Verify** — row count + spot-check comparison
8. **Cleanup** — drop replication slot, publication, archive source tables

---

## Features

- **Zero schema lock** — source database runs normally throughout; `AccessExclusiveLock` held only for milliseconds at cutover
- **Cross-cluster** — source and target are separate PostgreSQL servers; works for version upgrades, cloud provider migrations, hardware changes
- **Type transformation** — widening casts (int→bigint, varchar→text, timestamp→timestamptz) are automatic; narrowing casts require an explicit pre-migration data validation pass
- **Column padding optimizer** — analyzes column alignment and estimates space savings from reordering; integrated into the migration flow
- **Resumable** — SQLite checkpoint stores per-batch progress; `pcrd migrate --resume` picks up from the last completed batch
- **No source extensions required** — uses PostgreSQL's built-in `pgoutput` logical replication (PG 10+)

---

## Requirements

- Ruby 3.2+
- PostgreSQL 10+ on source (with `wal_level = logical`)
- PostgreSQL 10+ on target
- Source user must have `REPLICATION` attribute and `SELECT` on migrated tables

---

## Installation

```bash
gem install pcrd          # once published
# or, from source:
git clone https://github.com/charris/pcrd
cd pcrd
bundle install
```

---

## Quick Start

### 1. Start the demo environment

```bash
docker compose -f dev/docker-compose.yml up -d
```

This starts two PostgreSQL 16 containers:
- **source_db** on port 5433 (with `wal_level=logical`)
- **target_db** on port 5434

### 2. Create the demo schema and data

```bash
# Create tables on source (intentionally poor column ordering for demo)
pcrd demo setup

# Seed with 50,000 rows (users → agents → listings)
pcrd demo seed --rows 50000
```

### 3. Analyze column padding

```bash
# Shows current column layout and how much space can be saved by reordering
pcrd analyze

# Compare source vs. proposed target schema side-by-side
pcrd analyze --compare-target
```

### 4. Run the migration

```bash
# Check everything looks right first
pcrd migrate --preflight-only

# Run the full migration (backfill + streaming)
pcrd migrate --yes

# Or backfill only (no WAL streaming)
pcrd migrate --backfill-only --yes
```

### 5. Cut over

```bash
# Once lag is near zero, put the app in maintenance mode, then:
pcrd cutover --maintenance-confirmed   # (coming in Phase 10)
```

---

## Configuration

pcrd looks for `pcrd.config.yml` in the current directory by default. Pass `--config path/to/file.yml` to override.

```yaml
# pcrd.config.yml

source:
  host: db-primary.old.example.com
  port: 5432
  database: myapp_production
  user: pcrd_replication
  # password: via PCRD_SOURCE_PASSWORD env var or ~/.pgpass

target:
  host: db-primary.new.example.com
  port: 5432
  database: myapp_production
  user: pcrd_writer
  # password: via PCRD_TARGET_PASSWORD env var or ~/.pgpass

migrate:
  # replication_slot and publication default to pcrd_<first_table> if omitted
  batch_size: 10_000
  lag_threshold_bytes: 1_048_576   # 1 MB — gate for cutover readiness
  checkpoint_db: ./pcrd_checkpoint.sqlite3

  tables:
    - name: listings
      optimize_column_order: true   # reorder columns for padding efficiency
      columns:
        id:
          type: bigint              # integer → bigint (always safe)
        list_price:
          type: numeric(18,4)
          rename: list_price_precise
        status_code:
          rename: listing_status
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

analyze:
  tables:
    - listings
    - users

verify:
  sample_size: 1_000

cutover:
  sequence_buffer: 1_000      # added to max(id) when advancing target sequences
  lag_drain_timeout: 300      # seconds to wait for lag to reach zero
```

**Password handling:** Never put passwords in the YAML file. Use:
- `PCRD_SOURCE_PASSWORD` environment variable
- `PCRD_TARGET_PASSWORD` environment variable
- `~/.pgpass` file (standard PostgreSQL password file)

---

## CLI Reference

### `pcrd analyze`

Analyze column padding for source tables. Read-only.

```bash
pcrd analyze [--config FILE] [--table TABLE] [--compare-target]
```

- `--table TABLE` — analyze only this table (default: all tables in config)
- `--compare-target` — connect to target and show source vs. target side-by-side, including type changes, renames, added/dropped columns, and padding delta

**Example output:**
```
Table: public.listings  (50,000 rows)

  Current layout:
  ┌─────────────────────┬──────────────────┬───────┬──────────┬────────────────┐
  │ Column              │ Type             │ Align │ Size     │ Padding before │
  ├─────────────────────┼──────────────────┼───────┼──────────┼────────────────┤
  │ id                  │ integer          │ 4B    │ 4        │ —              │
  │ active              │ boolean          │ 1B    │ 1        │ —              │
  │ listed_at           │ timestamp        │ 8B    │ 8        │ ← 1 wasted     │
  ...

  Padding analysis:
    Current row overhead (fixed cols + padding):  104 bytes
    Optimal row overhead (fixed cols only):         84 bytes
    Wasted padding:  20 bytes/row  (19.2%)
    At 50,000 rows:  ~1.0 MB reclaimed by reordering columns
```

---

### `pcrd migrate`

Run the migration. Preflight → setup → backfill → streaming.

```bash
pcrd migrate [--config FILE] [--preflight-only] [--backfill-only] [--dry-run]
             [--resume] [--yes] [--force-overwrite]
```

- `--preflight-only` — run all safety checks and print target DDL; do not start migration
- `--dry-run` — same as `--preflight-only`
- `--backfill-only` — copy existing rows only; do not start WAL streaming
- `--resume` — resume an interrupted migration from the last checkpoint
- `--yes` — skip the confirmation prompt
- `--force-overwrite` — drop and recreate target tables if they already exist

**Preflight checks performed:**
1. Source and target connectivity
2. `wal_level = logical` on source
3. `max_replication_slots` headroom
4. Source tables exist; row count estimate
5. Primary key present on every migrated table (required for upsert semantics)
6. Target tables do not already exist
7. All spec column names exist on source; all type casts are known
8. Data validation for validated casts (bigint→int range, text→varchar(n) length, etc.)

**Supported type changes:**

| Always safe (no validation) | Validated (data check required) |
|---|---|
| `smallint → integer/bigint` | `bigint → integer` |
| `integer → bigint` | `text/varchar → varchar(n)` |
| `float4 → float8` | `float8 → float4` (warn only) |
| `varchar(n) → text` | `timestamptz → timestamp` (warn only) |
| `timestamp → timestamptz` | `numeric → integer/bigint` |
| `date → timestamp/timestamptz` | |
| `integer/bigint → numeric` | |

---

### `pcrd demo`

Set up and seed a demo database for testing.

```bash
pcrd demo setup  [--config FILE]
pcrd demo seed   [--config FILE] [--rows N] [--seed N]
pcrd demo reset  [--config FILE]
```

- `demo setup` — creates `users`, `agents`, and `listings` tables on source; writes a sample `pcrd.config.yml` if none exists. The `listings` table is intentionally ordered with poor column alignment to demonstrate the padding optimizer.
- `demo seed --rows N` — generates realistic fake data (N listings, proportional users and agents). Default: 50,000 rows. Reproducible with `--seed`.
- `demo reset` — drops all demo tables.

---

### `pcrd cutover` *(coming soon)*

Trigger the cutover sequence after lag reaches near-zero.

```bash
pcrd cutover [--config FILE] [--maintenance-confirmed]
```

The application must be in maintenance mode before running this command. See [Cutover Procedure](#cutover-procedure) below.

---

### `pcrd verify` *(coming soon)*

Compare row counts and spot-check rows across clusters.

```bash
pcrd verify [--config FILE] [--sample-size N]
```

---

### `pcrd status` *(coming soon)*

Show current migration phase, backfill progress, and live replication lag.

---

### `pcrd cleanup` *(coming soon)*

Drop replication slot, publication, and checkpoint. Optionally drop source tables.

---

## Cutover Procedure

When the lag meter shows "✓ Ready for cutover":

1. **Put the application in maintenance mode.** Options depending on your stack:

   | Stack | Approach |
   |---|---|
   | **pgBouncer** | `PAUSE <database>` — queues connections instead of rejecting them |
   | **Rails + Rack** | Enable maintenance middleware via file flag or env var |
   | **Kubernetes** | `kubectl scale --replicas=0 deployment/app` |
   | **Heroku** | `heroku maintenance:on` |

2. **Run cutover:** `pcrd cutover --maintenance-confirmed`  
   pcrd drains remaining lag to zero, advances target sequences, and verifies row counts.

3. **Switch connection strings:** Update `DATABASE_URL` (or equivalent) to point at the target cluster.

4. **Restart the application.**

5. **Verify:** `pcrd verify` — confirms row counts match across clusters.

6. **End maintenance mode** once the application is healthy on the target cluster.

7. **Cleanup** (days later, when confident): `pcrd cleanup`

**Rollback:** Never cut over → old cluster keeps running unchanged. No data is lost.

---

## Column Padding Analysis

PostgreSQL stores columns in definition order. Each column is aligned to its type's natural boundary, which wastes bytes when small-alignment columns (bool, smallint) appear between large-alignment columns (bigint, timestamp).

**Alignment rules:**
- 8 bytes: `bigint`, `float8`, `timestamp`, `timestamptz`
- 4 bytes: `integer`, `float4`, `date`, `numeric`/`text` headers
- 2 bytes: `smallint`
- 1 byte: `boolean`, `char`

**Optimal ordering:** 8-byte → 4-byte → 2-byte → 1-byte → variable-length

Since pcrd rewrites the table anyway during migration, column reordering is free — set `optimize_column_order: true` in the table config and pcrd applies the optimal ordering automatically.

The `pcrd analyze` command shows the current waste and estimated space reclaimed at current row count.

---

## Source Database Requirements

```sql
-- Grant replication capability
ALTER ROLE pcrd_replication REPLICATION;

-- Grant read access to migrated tables
GRANT SELECT ON TABLE listings, users TO pcrd_replication;

-- Allow publication creation (superuser or pg_monitor in PG14+)
GRANT CREATE ON DATABASE myapp_production TO pcrd_replication;
```

`postgresql.conf` must have:
```
wal_level = logical
max_replication_slots = <current + number of concurrent pcrd migrations>
max_wal_senders      = <current + number of concurrent pcrd migrations>
```

---

## Development

```bash
git clone https://github.com/charris/pcrd
cd pcrd
bundle install

# Start dev PostgreSQL containers
docker compose -f dev/docker-compose.yml up -d

# Run tests
bundle exec rspec

# Run integration tests only
bundle exec rspec spec/integration/

# Run a quick end-to-end demo
pcrd demo setup
pcrd demo seed --rows 10000
pcrd analyze
pcrd migrate --preflight-only
pcrd migrate --backfill-only --yes
```

### Test environment

Integration tests require both containers from `dev/docker-compose.yml`. Override connection details with environment variables:

```bash
PCRD_TEST_SOURCE_HOST=localhost PCRD_TEST_SOURCE_PORT=5433 \
PCRD_TEST_SOURCE_DB=pcrd_source PCRD_TEST_SOURCE_USER=postgres \
PCRD_TEST_SOURCE_PASSWORD=postgres \
PCRD_TEST_TARGET_HOST=localhost PCRD_TEST_TARGET_PORT=5434 \
PCRD_TEST_TARGET_DB=pcrd_target PCRD_TEST_TARGET_USER=postgres \
PCRD_TEST_TARGET_PASSWORD=postgres \
bundle exec rspec
```

---

## Architecture Notes

### Why cross-cluster?

Running source and target as separate PostgreSQL servers supports more than just schema changes:
- **Version upgrades**: migrate from PG 14 to PG 16 with zero downtime
- **Cloud migrations**: move from on-premise to RDS, from AWS to GCP, etc.
- **Hardware changes**: move to larger instances without downtime
- **Schema changes**: the original use case — column type changes, renames, reordering

### Why pgoutput?

`pgoutput` is PostgreSQL's built-in logical replication plugin (available since PG 10). No extensions are required on the source server. This makes pcrd work with managed PostgreSQL services (RDS, Cloud SQL, etc.) that restrict extension installation.

### Backfill / streaming overlap

The replication slot is created before backfill starts. This ensures all WAL changes during backfill are retained. The WAL consumer runs concurrently with backfill, buffering events. When backfill completes, the apply engine replays buffered events before transitioning to live streaming. Because the apply engine uses `INSERT ... ON CONFLICT DO UPDATE`, rows that appear in both the bulk copy and the WAL stream are handled correctly — WAL wins.

### Primary key requirement

Every migrated table must have a primary key or unique not-null index. This is a hard requirement: without a unique key, the apply engine cannot safely handle the backfill/streaming overlap window (it cannot know whether a WAL insert is a concurrent new write or a duplicate of something already bulk-copied).

---

## Known Limitations

- **Sequences** — target sequences are advanced as part of `pcrd cutover`. The command computes `max(id)` on source and calls `setval` on target with a configurable safety buffer.
- **Foreign keys** — FK constraints on the target are listed in the preflight output but not automatically created. Add them post-cutover.
- **Non-PK indexes** — like FK constraints, these are listed in the preflight report. Create them on the target before cutover for query performance.
- **Large objects** — `pg_largeobject` data is not replicated via logical replication.
- **Generated columns** — pcrd creates these without the GENERATED clause; values are recomputed by the target database.
- **DDL during migration** — if a column is added or dropped on the source after the migration starts, pcrd halts with a clear error rather than silently corrupting data.
- **Partitioned tables** — supported but each partition must be listed individually in the config.

---

## Project Status

| Phase | Status | Description |
|---|---|---|
| Config loading | ✅ | YAML config, typed structs, env-var passwords |
| Schema reader | ✅ | pg_attribute query, column metadata |
| Padding analyzer | ✅ | Optimal column ordering, space savings estimate |
| `pcrd analyze` | ✅ | Source-only and --compare-target |
| Type transformer | ✅ | Cast safety rules, data validation |
| DDL generation | ✅ | CREATE TABLE from spec + source schema |
| Preflight | ✅ | All 8 safety checks |
| `pcrd migrate --preflight-only` | ✅ | Full preflight report + DDL preview |
| Checkpoint store | ✅ | SQLite per-batch progress tracking |
| Backfill engine | ✅ | Keyset-paginated COPY, resumable |
| `pcrd migrate --backfill-only` | ✅ | Full backfill with progress display |
| pgoutput parser | ✅ | All message types, binary protocol |
| WAL consumer | ✅ | Background thread, transaction buffering |
| Apply engine | ✅ | Upsert/update/delete on target |
| `pcrd migrate` (full) | ✅ | Backfill + streaming + lag meter |
| `pcrd demo setup/seed` | ✅ | Demo database with realistic schema |
| `pcrd cutover` | 🔜 | Phase 10 |
| `pcrd verify` | 🔜 | Phase 10 |
| `pcrd status` | 🔜 | Phase 11 |
| `pcrd cleanup` | 🔜 | Phase 11 |
| Docker Compose example | 🔜 | Phase 12 |
| Full polish + README | 🔜 | Phase 13 |

---

## License

MIT

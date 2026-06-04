# pcrd Configuration Reference

pcrd looks for `pcrd.config.yml` in the current directory. Override with `--config path/to/file.yml`.

Run `pcrd demo setup` to write a sample config automatically.

---

## Top-Level Structure

```yaml
source:    { ... }   # required: source PostgreSQL connection
target:    { ... }   # required for migrate/cutover/verify
migrate:   { ... }   # required for migrate; optional for analyze
analyze:   { ... }   # optional: tables to analyze and compare
verify:    { ... }   # optional: spot-check settings
cutover:   { ... }   # optional: cutover timing and sequence buffer
```

---

## `source` and `target`

Connection details for the source (old cluster) and target (new cluster).

```yaml
source:
  host:     db.old.example.com   # required
  port:     5432                  # optional, default: 5432
  database: myapp_production      # required
  user:     pcrd_replication      # required

target:
  host:     db.new.example.com
  port:     5432
  database: myapp_production      # same database name on both clusters
  user:     pcrd_writer
```

**Passwords** — never put passwords in the config file. Use:
- `PCRD_SOURCE_PASSWORD` environment variable
- `PCRD_TARGET_PASSWORD` environment variable
- `~/.pgpass` standard PostgreSQL password file

---

## `migrate`

Describes all the changes to make during the migration.

```yaml
migrate:
  # Optional: auto-derived from the first table name if not set.
  # Example: for table "listings" → slot "pcrd_listings", pub "pcrd_pub_listings"
  replication_slot: pcrd_listings_v2
  publication:      pcrd_pub_listings_v2

  # Where to store per-batch progress for resumability.
  # Default: ./pcrd_checkpoint.sqlite3
  checkpoint_db: ./pcrd_checkpoint.sqlite3

  # Rows copied per backfill batch. Larger = fewer round trips but more memory.
  # Default: 10,000
  batch_size: 10_000

  # Replication lag in bytes below which pcrd shows "✓ Ready for cutover".
  # Default: 1,048,576 (1 MB)
  lag_threshold_bytes: 1_048_576

  tables:
    - { ... }   # one entry per table to migrate
```

### `tables`

Each table in the list represents one table to migrate. Tables are processed in the order listed; for referential integrity, list referenced tables before tables that reference them (but note that FK constraints are not enforced on the target during migration).

#### The most important rule: **only specify what changes**

The `columns:` map only needs entries for columns you want to modify. Any column not listed is migrated automatically:
- **Same name** — copied as-is
- **Same type** — no conversion
- **Same NOT NULL** — preserved
- **Same DEFAULT** — preserved (except `nextval()` sequence defaults, which are recreated at cutover)
- **Same column position** — unless `optimize_column_order: true`

This means for a table with 20 columns where only `id` needs to change from `integer` to `bigint`, your config is just:

```yaml
- name: orders
  columns:
    id:
      type: bigint
```

The other 19 columns require no configuration at all.

#### Full table spec

```yaml
tables:
  - name: listings                  # required: table name (same on source and target)

    # Reorder columns for minimal padding waste (see "Column Padding" below).
    # Since pcrd rewrites the table anyway, reordering is free.
    # Default: false
    optimize_column_order: true

    # Map of source column name → change spec.
    # ONLY include columns you want to change. Omitted columns are copied as-is.
    columns:
      # Change type only (column keeps its name)
      id:
        type: bigint

      # Rename only (column keeps its type)
      status_code:
        rename: listing_status

      # Change type AND rename in one step
      list_price:
        type: numeric(18,4)
        rename: list_price_precise

      # Drop a column (it will not appear on the target)
      legacy_notes:
        drop: true

      # Explicitly copy unchanged (equivalent to omitting this entry entirely)
      # created_at:           ← no entry needed; omitting = copy as-is

    # New columns to add to the target (not present on source).
    # Added columns appear after all source columns (before optimize reordering).
    add_columns:
      - name: updated_at
        type: timestamptz
        default: "now()"      # SQL expression; applied as column DEFAULT

      - name: migrated_flag
        type: boolean
        default: "false"

      - name: notes
        type: text            # nullable, no default = NULL for backfilled rows
```

#### Column change rules

| Combination | Effect |
|---|---|
| `type: X` only | Same column name, new type |
| `rename: Y` only | New column name, same type |
| `type: X, rename: Y` | New name AND new type in one step |
| `drop: true` | Column is excluded from target schema entirely |
| `drop: true` + anything else | **Error** — `drop` cannot be combined with `type` or `rename` |
| No entry for the column | Copied to target exactly as-is |

---

## Supported Type Changes

pcrd classifies every type transition as **always safe**, **validated** (data check required), or **unsupported**.

### Always safe — applied automatically, no validation

These are pure widening casts with no possible data loss:

| Source type | Target type(s) |
|---|---|
| `smallint` | `integer`, `bigint`, `real`, `double precision`, `numeric` |
| `integer` | `bigint`, `real`, `double precision`, `numeric` |
| `bigint` | `double precision`, `numeric` |
| `real` | `double precision` |
| `varchar(n)` | `text`, `varchar(m)` where m ≥ n |
| `char(n)` | `text`, `varchar` |
| `date` | `timestamp`, `timestamptz` |
| `timestamp` | `timestamptz` |
| Any same-base type with wider parameters | e.g., `numeric(10,2)` → `numeric(18,4)` |

### Validated — pcrd runs a data check before starting

If the check finds data that would fail the cast, pcrd halts with details. Fix the data (or the spec), then rerun.

| Source → Target | What pcrd checks |
|---|---|
| `bigint → integer` | All values within [-2,147,483,648 … 2,147,483,647] |
| `bigint/integer → smallint` | All values within [-32,768 … 32,767] |
| `text/varchar → varchar(n)` | All values have length ≤ n |
| `numeric → integer/bigint` | All values are whole numbers and fit in range |
| `float8 → float4` | Warn only — precision may be reduced |
| `timestamptz → timestamp` | Warn only — timezone info will be discarded |

### Unsupported

These require a custom transform (not yet supported): `bytea → text`, `json → jsonb` (without inspection), `bool → integer`, etc.

---

## `analyze`

Controls which tables `pcrd analyze` examines. Optional — if omitted, pcrd uses the tables from `migrate.tables`.

```yaml
analyze:
  # Tables to include in analyze output.
  # Omit entirely to analyze all tables in migrate.tables.
  tables:
    - listings
    - users
    - agents
```

---

## `verify`

Controls `pcrd verify` spot-check behavior.

```yaml
verify:
  # Number of rows to randomly sample per table for field-by-field comparison.
  # Default: 1,000
  sample_size: 1_000
```

---

## `cutover`

Controls timing and safety margins for `pcrd cutover`.

```yaml
cutover:
  # Added to max(pk_col) when calling setval on target sequences.
  # A buffer guards against any writes that might slip through during the
  # very brief transition between reads and the sequence being set.
  # Default: 1,000
  sequence_buffer: 1_000

  # Maximum seconds to wait for replication lag to reach zero during cutover.
  # If lag doesn't reach zero within this window, cutover proceeds anyway with
  # a warning (the remaining lag is small enough to be tolerated).
  # Default: 300 (5 minutes)
  lag_drain_timeout: 300
```

---

## Column Padding Optimization

Setting `optimize_column_order: true` on a table tells pcrd to reorder columns in the target schema so that fixed-size columns are sorted by alignment (8-byte → 4-byte → 2-byte → 1-byte → variable-length). This eliminates alignment padding waste.

Since pcrd rewrites the table from scratch anyway, the reordering is free — it has no performance cost compared to a migration without reordering.

Use `pcrd analyze` to preview the savings before running the migration:

```bash
pcrd analyze                  # current layout + suggested order + savings estimate
pcrd analyze --compare-target # side-by-side source vs. proposed target
```

---

## Common Scenarios

### 1. Integer ID overflow (the most common use case)

Every integer column can hold up to ~2.1 billion values. When you're approaching that limit:

```yaml
migrate:
  tables:
    - name: orders
      columns:
        id:
          type: bigint
    - name: order_items
      columns:
        id:
          type: bigint
        order_id:
          type: bigint   # foreign key column must match the referenced PK type
```

### 2. Rename a column with no type change

```yaml
migrate:
  tables:
    - name: listings
      columns:
        status_code:
          rename: listing_status    # all other columns copied unchanged
```

### 3. Widen a numeric type for financial precision

```yaml
migrate:
  tables:
    - name: transactions
      columns:
        amount:
          type: numeric(18,4)   # was numeric(10,2)
          rename: amount_precise
```

### 4. Clean up a table: drop dead columns, add a new one, reorder for padding

```yaml
migrate:
  tables:
    - name: users
      optimize_column_order: true   # free: reorders for minimal padding waste
      columns:
        id:
          type: bigint
        old_field_1:
          drop: true
        old_field_2:
          drop: true
      add_columns:
        - name: updated_at
          type: timestamptz
          default: "now()"
```

### 5. Upgrade timestamp precision to include timezone

```yaml
migrate:
  tables:
    - name: events
      columns:
        created_at:
          type: timestamptz   # was timestamp; data is preserved, tz info added
        updated_at:
          type: timestamptz
```

> **Note:** `timestamp → timestamptz` is always safe (the timestamp value is preserved, the column gains timezone awareness). The reverse (`timestamptz → timestamp`) is validated and warns about timezone loss.

### 6. Minimal config — just copy tables with no changes

If you want to migrate tables to a new cluster without any schema changes (e.g. for a version upgrade or hardware migration), the column spec can be empty:

```yaml
migrate:
  tables:
    - name: users         # all columns copied exactly as-is
    - name: orders        # all columns copied exactly as-is
    - name: order_items   # all columns copied exactly as-is
```

---

## What pcrd Does NOT Change (Without Being Asked)

- **Column NOT NULL constraints** — preserved from source
- **Column DEFAULT expressions** — preserved from source (except `nextval()`, handled at cutover)
- **Indexes** — not created on target; listed in the preflight checklist for the operator to add
- **Foreign key constraints** — not created on target; listed in the preflight checklist
- **Triggers** — not copied to target
- **Row-level security policies** — not copied to target
- **Column comments** — not copied to target
- **Table partitioning** — partitioned tables must be listed partition-by-partition

---

## Generated DDL Preview

Run `pcrd migrate --preflight-only` (or `--dry-run`) to see the exact `CREATE TABLE` SQL that pcrd will execute on the target before starting the migration. This lets you verify the schema is exactly what you expect before committing.

```bash
pcrd migrate --config migration.yml --preflight-only
```

The preflight output includes:
- All safety check results (connections, WAL level, PK existence, type cast validation)
- The generated `CREATE TABLE` DDL for each migrated table
- Estimated backfill duration (at current table size and default batch size)

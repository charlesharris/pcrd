# Migration Runbook: Listings Table — integer → bigint

**Scenario:** The `listings` table is approaching the integer ID limit (~2.1 billion rows). We need to widen `id` and `agent_id` to `bigint`, improve the precision of `list_price`, add timezone awareness to timestamps, and clean up column ordering to reduce storage overhead — all with no application downtime.

**Tools:** pcrd, Docker Compose

**Estimated time:** ~15 minutes for a 100,000-row dataset; scales linearly with data volume.

---

## Prerequisites

- Docker and Docker Compose installed
- pcrd installed (`gem install pcrd` or `bundle exec ruby exe/pcrd`)
- Run all commands from the `examples/listings_migration/` directory

---

## Step 1 — Start the environment

```bash
docker compose up -d
```

Wait for all services to be healthy:

```bash
docker compose ps
```

Expected output: all three services showing `healthy` or `running`.

---

## Step 2 — Create the schema and seed data

The Rails app is running but the database has no tables yet. Use pcrd's demo commands to set up the schema and populate it with realistic data.

```bash
# Create the tables on source_db (intentionally poor column ordering for demo)
pcrd demo setup --config migration.yml

# Seed with 100,000 listings (adjust --rows as needed)
pcrd demo seed --config migration.yml --rows 100000
```

`demo seed` generates proportional users and agents automatically. Output:
```
Seeding demo database at localhost/myapp_production...

  Generating 500 users...
  Generating 100 agents...
  Generating 100,000 listings...

Seeding complete:
  users:    500
  agents:   100
  listings: 100,000
```

---

## Step 3 — Verify the app is live

```bash
curl http://localhost:3000/health | jq
```

Expected:
```json
{
  "status": "ok",
  "database": "myapp_production",
  "listing_count": 100000,
  "user_count": 500,
  "agent_count": 100
}
```

The `/stats` endpoint shows the current ID column type — this is how you'll confirm the migration worked:

```bash
curl http://localhost:3000/stats | jq .tables.listings.id_type
# → "integer"  (source cluster, old schema)
```

---

## Step 4 — Analyze the current schema

Before migrating, look at the column padding waste and the proposed schema changes.

```bash
# Current layout + suggested reordering + space savings
pcrd analyze --config migration.yml

# Side-by-side: source schema vs. what the target will look like
pcrd analyze --config migration.yml --compare-target
```

Note the padding analysis output — the `listings` table has booleans and smallints scattered between 8-byte timestamp and float8 columns, wasting ~20 bytes/row. With `optimize_column_order: true` in the config, pcrd reorders them automatically.

---

## Step 5 — Preflight check

Verify all safety checks pass before starting the migration.

```bash
PCRD_SOURCE_PASSWORD=postgres PCRD_TARGET_PASSWORD=postgres \
  pcrd migrate --config migration.yml --preflight-only
```

Expected: all checks show `✓`. The output also shows the generated DDL for each target table — review it to confirm the schema changes are exactly what you want.

Key things to look for:
- `listings.id: integer → bigint` (always safe)
- `listings.list_price → list_price_precise: numeric(10,2) → numeric(18,4)` (rename + type)
- `listings.listed_at: timestamp → timestamptz` (always safe)
- Column reordering: 8-byte columns (timestamps, float8) moved to front
- `updated_at timestamptz DEFAULT now()` added

---

## Step 6 — Start the migration

In a **separate terminal**, keep a watch on the health endpoint to confirm the app stays live throughout:

```bash
# Terminal 2: watch the app stay live during migration
watch -n 2 "curl -s http://localhost:3000/health | jq .listing_count"
```

Back in **Terminal 1**, start the migration:

```bash
PCRD_SOURCE_PASSWORD=postgres PCRD_TARGET_PASSWORD=postgres \
  pcrd migrate --config migration.yml --yes
```

The migration runs through these phases automatically:
1. Creates the replication publication and slot on source
2. Creates target tables with the new schema
3. **Backfill** — copies all existing rows via `COPY`, batch by batch
4. **Streaming** — applies concurrent writes from the WAL stream
5. Shows a live lag meter once backfill completes

Watch the backfill progress:
```
  listings  batch 1  10,000 rows  48,309 rows/s
  listings  batch 2  20,000 rows  47,621 rows/s
  ...
```

Leave `pcrd migrate` running. It stays up streaming changes from source to target.

---

## Step 7 — Monitor lag (optional, from a third terminal)

```bash
# Terminal 3: check migration status at any time
PCRD_SOURCE_PASSWORD=postgres \
  pcrd status --config migration.yml
```

Once backfill completes, the migrate output shows:
```
  Lag: 512 bytes  ~0s  ↓ trending down  ✓ Ready for cutover
```

---

## Step 8 — Write a test row (demonstrate live writes during migration)

While `pcrd migrate` is running, create a new listing to confirm writes continue working and are replicated to the target:

```bash
curl -s -X POST http://localhost:3000/listings \
  -H "Content-Type: application/json" \
  -d '{"listing": {"list_price": 750000, "bedrooms": 3, "address_line1": "123 Test St", "city": "San Francisco", "state_code": "CA", "zip_code": "94105"}}' \
  | jq .id
```

This row will appear on the target cluster via WAL replication — no special handling needed.

---

## Step 9 — Cutover

When the lag meter shows "✓ Ready for cutover" and you're ready to switch:

### 9a — Enable maintenance mode

Stop the app and restart with maintenance mode on:

```bash
# Docker Compose approach: set MAINTENANCE_MODE and restart
docker compose stop rails_app
docker compose run -d -e MAINTENANCE_MODE=true -p 3000:3000 rails_app
```

Verify maintenance mode is active:
```bash
curl http://localhost:3000/health
# → 503 {"status":"maintenance","message":"..."}
```

### 9b — Run cutover

```bash
PCRD_SOURCE_PASSWORD=postgres PCRD_TARGET_PASSWORD=postgres \
  pcrd cutover --config migration.yml --maintenance-confirmed
```

Expected output:
```
Running cutover sequence...
  Draining replication lag...
  Advancing target sequences...
  Verifying row counts...

Cutover report
──────────────────────────────────────────────────────────

  Row counts:
    ✓  users     500 rows
    ✓  agents    100 rows
    ✓  listings  100,001 rows   ← includes the test row from step 8

  Sequence advancement:
    ✓  users.id      setval(public.users_id_seq, 1500)
    ✓  agents.id     setval(public.agents_id_seq, 1100)
    ✓  listings.id   setval(public.listings_id_seq, 101001)

  ✓  Cutover complete.

  Next steps:
    1. Update DATABASE_URL to point at the target cluster
    2. Restart the application
    3. Run `pcrd verify` to confirm row counts
    4. End maintenance mode
    5. Run `pcrd cleanup` (days later, when confident)
```

You can also stop `pcrd migrate` now (Ctrl-C in Terminal 1).

---

## Step 10 — Switch to the target cluster

Update docker-compose.yml to point the Rails app at `target_db`:

```yaml
# In docker-compose.yml, change the rails_app environment:
DATABASE_URL: postgres://postgres:postgres@target_db/myapp_production
MAINTENANCE_MODE: "false"
```

Then restart the app:
```bash
docker compose stop rails_app
docker compose up -d rails_app
```

---

## Step 11 — Verify

```bash
# Health check — confirms DB is reachable and counts are correct
curl http://localhost:3000/health | jq

# Stats — the key test: id_type should now be "bigint"
curl http://localhost:3000/stats | jq .tables.listings.id_type
# → "bigint"   ← migration confirmed!

# Row count verification across both clusters
PCRD_SOURCE_PASSWORD=postgres PCRD_TARGET_PASSWORD=postgres \
  pcrd verify --config migration.yml
```

Expected verify output:
```
  ✓  users     500 rows match
  ✓  agents    100 rows match
  ✓  listings  100,001 rows match

  ✓  All tables verified.
```

---

## Step 12 — Cleanup (days later)

Once the app has been running successfully on the target cluster for a comfortable rollback window:

```bash
PCRD_SOURCE_PASSWORD=postgres \
  pcrd cleanup --config migration.yml
```

This drops the replication slot and publication on source, and deletes the checkpoint file. The source tables remain untouched.

To also drop the source tables (irreversible):
```bash
pcrd cleanup --config migration.yml --drop-source
```

---

## Rollback

If anything goes wrong before cleanup, rollback is trivial — the source cluster is untouched throughout. Simply:

1. Stop the app (if it was switched to target)
2. Update `DATABASE_URL` back to `source_db`
3. Restart the app
4. Run `pcrd cleanup` to drop the slot and free WAL retention on source

The target cluster can be discarded (drop the container and its volume).

---

## What the Migration Demonstrates

| Aspect | Source (old) | Target (new) |
|---|---|---|
| `listings.id` type | `integer` | `bigint` |
| `listings.list_price` | `numeric(10,2)` | `numeric(18,4)` (renamed `list_price_precise`) |
| `listings.listed_at` | `timestamp` | `timestamptz` |
| Column ordering | Random (bool/smallint interspersed) | Optimized (8B→4B→2B→1B→variable) |
| `updated_at` | Not present | Added with `DEFAULT now()` |
| App downtime | None during migration | Brief maintenance window at cutover |
| Data loss | None | None |

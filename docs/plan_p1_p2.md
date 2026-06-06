# P1 / P2 plan — production readiness & maintainability

P1 makes the tool robust enough to point at a production cluster. P2 is
maintainability that lowers the cost of everything else. Within each tier,
ordered by impact × severity and by dependency. None of these are "it's
broken" — they are "make it safe to operate" and "make it easy to change."

> **P1 status: complete** (branch `p1-production-readiness`).
> P1.1 ✅ connection safety · P1.2 ✅ advisory lock · P1.3 ✅ idempotent
> setup/resume · P1.4 ✅ throttling · P1.5 ✅ live metrics · P1.6 ✅ (scoped to
> the routing fix; full multi-schema deferred) · P1.7 ✅ readiness manifest
> (indexes/constraints/grants/owner/comments; sequences via cutover).
>
> **P2 status: complete** (branch `p2-maintainability`). Done in dependency
> order: P2.2 ✅ domain errors · P2.4 ✅ reporter · P2.1 ✅ Migration::Orchestrator
> extraction · P2.3 ✅ option normalization · P2.5 ✅ Connection::Pool→Client ·
> P2.6 ✅ CI + rubocop (grandfathered todo) + spec-constant footgun fix.

---

## P1 — production readiness

### P1.1 Conservative per-connection safety settings
**Highest safety-per-effort.** Refs: review #41.
Set `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`,
and `application_name` on every connection. A migration must never take a lock
that stalls production traffic indefinitely. Cheap, isolated, high value.
- Set in `Connection::Pool` (and the replication connection where applicable).
- Make defaults conservative and visible in config; log them at startup.

### P1.2 Advisory lock against concurrent runs
**Prevents corruption from a double-run.** Refs: review #42.
Two `pcrd migrate` processes against the same slot/checkpoint can corrupt
progress. Take a `pg_advisory_lock` (keyed on migration/slot name) and/or a
checkpoint-DB lock at startup; fail fast with a clear message if held.

### P1.3 Idempotent setup / resume for slots & publications
**Operational robustness.** Refs: review #13, #14, #43.
`create_publication_and_slot` uses plain `CREATE`; a partial prior run makes
re-run fail. Preflight should detect an existing slot/publication and whether
it matches this migration; setup should support explicit `--resume`/`--force`
semantics and store slot/publication metadata in the checkpoint.
- Clarify resume LSN source (slot confirmed position vs. checkpoint LSN).
- Reject/repair an invalid checkpointed LSN (ties to P0.1).

### P1.4 Throttling / rate limiting
**Protects the source under load.** Refs: review #40, #39.
Backfill runs as fast as it can. Add `max_rows_per_second`, inter-batch sleep,
and optional dynamic throttling based on replication lag / target load. Surface
the effective rate. (Optional: table-level concurrency — currently sequential,
which is a defensible safety choice; document it.)

### P1.5 Status & observability metrics
**Makes long migrations operable.** Refs: review #1, #2, #14, #18.
Depends on P0.2 (bounded queue gives a real queue-depth signal).
Report queue depth, last received/applied LSN, WAL retained bytes, estimated
catch-up time. Offer estimated vs. exact `COUNT(*)` modes in verify/status so
large-table counts are not silently expensive.

### P1.6 Schema support beyond `public`
**Unblocks real multi-schema databases.** Refs: review #11, #12, #35.
Depends on P0.4 (centralized quoting/qualification).

**Scoped down (decision):** only the collision-safe apply routing (#12) was
done — `Apply::Engine` now keys plans by schema-qualified `namespace.name`
using the pgoutput relation namespace, so a same-named table in another schema
can no longer mis-route. ✅

The **full feature** (#11 — migrating non-`public` tables: a per-table
`schema:` config field threaded through reader/DDL/setup/backfill/verify/
validator/preflight, plus a schema-qualified publication) is **deferred** until
a real non-public use case exists. Agreed config shape when it lands: a
separate `schema:` field per table (default `public`), source and target
sharing the schema. Report unsupported relation kinds (partitioned/foreign/
matview, #35) in preflight at that time.

### P1.7 Final DDL / target-readiness manifest
**Prevents an incomplete cutover.** Refs: review #7, #15, #16, #17.
Largest, mostly additive. Separate "minimal load DDL" from "final target DDL."
Generate post-load DDL/checklist for non-PK indexes (built concurrently),
FKs, check/unique constraints, sequences & identity restoration, grants, owner,
comments, RLS, triggers, partitions, replica identity. Validate expected
objects exist before cutover. Note: the current DDL already intentionally
defers these — this item is about emitting the manifest and validating it, not
inlining everything.

---

## P2 — maintainability

### P2.1 Extract migration orchestration out of `CLI#migrate`
**Unlocks testing of everything streaming-related.** Refs: review #22.
Move the orchestration into `Migration::Orchestrator` (or `Commands::Migrate`);
keep the Thor method a thin adapter. Best done after the P0 streaming rework
(P0.1/P0.2) settles so the extracted shape is the final one.

### P2.2 Domain error classes
**Replaces broad `rescue`/`raise "string"`.** Refs: review #23, #34.
Formalize the error hierarchy started in P0.1 (`Replication::Error`): add
`Schema::TableNotFound`, etc. Preserve original class/backtrace in debug logs.

### P2.3 Normalize CLI option handling
**Removes string/symbol key duplication.** Refs: review #25.
Normalize Thor options once into a typed options struct passed to commands
(kills `options["force-overwrite"] || options[:"force-overwrite"]`).

### P2.4 Structured logger interface
**Enables automation / decouples output from CLI.** Refs: review #28.
Add a logger; make the human progress UI one renderer over machine-readable
events.

### P2.5 Rename `Connection::Pool` → `Connection::Client`
**Truth in naming; avoids thread-safety mistakes.** Refs: review #21, #27.
It wraps a single `PG::Connection`, not a pool. Rename (or implement a real
pool if/when concurrency needs it).

### P2.6 CI + rubocop + integration tests against real Postgres
**Catches regressions in the risky paths.** Refs: review #47, #48.
GitHub Actions with a Postgres service container. Cover int→bigint, renames,
drops, composite PKs, deletes/updates during backfill, interrupted resume, slot
cleanup, verify mismatch detection, non-public schema. Add a formatting check.

---

### Suggested execution order
P1.1 → P1.2 → P1.3 → P1.4 → P1.5 → P1.6 → P1.7, then
P2.1 → P2.2 → P2.3 → P2.4 → P2.5 → P2.6.
Cross-tier dependencies: P1.5 needs P0.2; P1.6 needs P0.4; P2.1 should follow
the P0 streaming rework.

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-06-10

### Added

- Initial release.
- Zero-downtime cross-cluster PostgreSQL migrations via logical replication.
- Column type changes, renames, additions, drops, and reordering with padding optimization.
- Preflight validation (connections, WAL level, type cast safety, PK existence).
- Keyset-paginated, checkpointed `COPY` backfill engine.
- Concurrent WAL streaming + apply engine with TOAST/TRUNCATE handling.
- Replication lag monitoring and brief-lock cutover orchestration.
- `pcrd` CLI built on Thor.

[Unreleased]: https://github.com/charlesharris/pcrd/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/charlesharris/pcrd/releases/tag/v0.1.0

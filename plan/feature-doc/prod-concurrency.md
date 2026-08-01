# Production concurrency — design spec

Approved design, 2026-08-01. Extends `mcp-server.md` + `minilog-db.md`
for a production machine serving ~20 concurrent MCP connections:
requests stay timely while one load runs, and the in-memory log DB
cannot bloat the server. Supersedes two earlier decisions where noted:
the single-threaded accept loop (mcp-server.md) and the single-slot
minilog DB (minilog-db.md).

## Status

Design approved; implementation not started.

## Implementation board

### Done

*(none yet)*

### In progress

*(none yet)*

### Todo

- **DB cache** · `src/MiniLog.hx` · single slot → keyed cache
  (key = sorted matched paths), TTL freshness, global LRU budget,
  load dedup, per-entry mutex.
- **Tool contract** · `src/Mcp.hx` · `load_log_db` returns `db` id +
  `cached`/`ageSeconds`; `query_log_db` gains optional `db` argument;
  schemas/descriptions updated.
- **Worker pool** · `src/Mcp.hx` · accept loop feeds a
  `sys.thread.Deque`; 4 workers; per-socket 10 s timeout.
- **Docs + live verification** · specs/doc/ sync; parallel-curl
  exercise on the running server.

## Decisions (settled with the user, 2026-08-01)

- **Shared cache keyed by content** — same log-set loaded by any number
  of users = one DB in memory. No sessions, no `Mcp-Session-Id`; the
  server stays stateless above the cache.
- **Global cache budget 512 MiB** with LRU eviction — matches the
  systemd unit's `MemoryMax=512M`.
- **Fixed worker pool of 4** + per-socket read timeout; duplicate
  concurrent loads dedupe onto one in-flight load.

## DB cache (`src/MiniLog.hx`)

The single slot becomes a keyed cache of read-only `:memory:` DBs:

- **Key**: the sorted list of matched log paths (one entry per distinct
  log-set).
- **Entry**: `{key, db connection, bytes, loadedAt, lastUsed, per-file
  size/mtime at load, mutex}`.
- **Freshness**: `FRESH_TTL = 60 s`. A younger hit is served as-is with
  `cached: true` and `ageSeconds` in the load result; an older entry is
  reloaded in place. Bounds staleness during live incidents without
  reload-per-request churn.
- **Budget**: `CACHE_MAX_BYTES = 512 MiB` total (sum of entries'
  `bytes`). Before a load is inserted, LRU entries (by `lastUsed`) are
  evicted until the new total fits. An entry whose mutex is held (query
  in flight) is skipped for the next-coldest.
- **Load dedup**: an in-flight key set guarded by the cache mutex; a
  request for a key already loading waits (condition-wait) and then
  serves the fresh entry — including its `isError` outcome when the
  load failed. A failed load never enters the cache.
- **Per-entry mutex** serializes queries on one DB (queries are
  milliseconds; contention invisible) and makes each sqlite connection
  single-threaded by construction.
- Per-load bounds unchanged: `MAX_DB_BYTES = 100 MiB` split across the
  matched files; ingest/sanitize/classification rules unchanged.

## Tool contract change (`src/Mcp.hx`)

The one externally visible change — with several DBs alive,
`query_log_db` must say which:

- `load_log_db {match}` result gains `db` (short id of the cache
  entry), `cached: Bool`, and `ageSeconds` when served from cache.
- `query_log_db {sql, ?db}` — `db` optional; omitted → the most
  recently loaded entry (today's behavior for single-topic use).
  Unknown or evicted id → `isError` "db evicted or unknown — call
  load_log_db again".
- `tools/list` schemas and descriptions updated so LLM clients pass the
  id naturally.

## Worker pool (`src/Mcp.hx`)

- The accept loop stays single: bind 127.0.0.1, accept, push the socket
  onto a `sys.thread.Deque`.
- `POOL_SIZE = 4` worker threads: pop → `readRequest` → `handle` →
  respond → close. At most 4 requests in flight; the rest queue in the
  Deque. 20 users queue only when 4 multi-second loads collide — rare
  once the cache absorbs repeats.
- `SOCKET_TIMEOUT = 10 s` (`setTimeout`) on every accepted socket — a
  stalled client burns one worker for at most 10 s (closes a deferred
  finding from the final whole-branch review).
- Per-request try/catch stays; a worker survives any request.

## Thread-safety audit

- `Tools` — stateless per call (`Cron.parseDir` runs fresh each time);
  `Flock`/`Pgrep` spawn separate processes. Safe unmodified.
- `MiniLog` — cache-level mutex for map/LRU/in-flight bookkeeping;
  per-entry mutex for queries and reloads.
- `Mcp.handle` — pure function; workers call it concurrently.

## Constants

Compile-time, per repo convention (no config knobs): `POOL_SIZE = 4`,
`CACHE_MAX_BYTES = 536870912` (512 MiB), `FRESH_TTL = 60` s,
`SOCKET_TIMEOUT = 10` s.

## Verification (no new test code — user rule)

- Existing suites stay green on both targets (`haxe test.hxml`,
  `haxe test-native.hxml && ./bin/test/TestMain`); single-DB behavior
  must be preserved where existing checks exercise it.
- Live, against the running server: a parallel curl storm (~20
  concurrent load+query mixes over distinct and repeated log-sets)
  confirming — one real load per distinct set (`cached: true` on
  repeats), memory plateaus under the unit's `MemoryMax`, queries keep
  answering while a load runs, and a deliberately stalled connection
  times out after ~10 s without blocking others.

## Out of scope

- Sessions / per-user isolation (content-keyed sharing replaces them).
- Async or evented IO; more than one accept loop.
- Cross-request rate limiting or auth beyond the existing Bearer key.
- Persistent/spill-to-disk caches — memory-only, dies with the process.

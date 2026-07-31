# Minilog database — design spec

Approved design, 2026-07-31. Extends `mcp-server.md` with two tools: the
server loads the recent tails of hint-selected logs into a temporary
queryable sqlite database, and the LLM client analyzes them with read-only
SQL. Motivation: log files run ~2 GB and very old content is irrelevant
during debugging — a ~100 MB database of recent entries is enough to fetch
relevant details, and SQL beats repeated tail/search round-trips for real
analysis (counts, grouping, level filtering, time-slicing by insert order).

## Status

Design approved; implementation not started. Implements on top of the MCP
server from `mcp-server.md` (itself not yet built) — one implementation
plan covers both specs, minilog phases after the server phases.

## Decisions (settled with the user, 2026-07-31)

- Log selection: **server matches a hint string** —
  `load_log_db {match}`, case-insensitive substring against every
  allowlist path. ("Identify based on prompt": the client LLM turns the
  prompt into the hint; the server resolves the hint to files.)
- Query interface: **raw read-only SELECT** — full sqlite power; the DB is
  a throwaway copy, worst case is a bad query on temp data.
- Lifecycle: **single slot, in-memory** (`sqlite :memory:`) held by the
  server process; each load replaces the previous DB wholesale; dies with
  the process. No files, no ids, no TTL.
- Schema: **one row per log entry** — continuation lines folded into their
  parent entry, the same rule the watcher uses.

## Engine facts (verified 2026-07-31)

- hxcpp bundles sqlite 3.23.1 statically
  (`.haxelib/hxcpp/4,3,2/project/thirdparty/sqlite-3.23.1`,
  `hxcpp.StaticSqlite`); `sys.db.Sqlite` on the cpp target adds **zero
  external dependencies** to the binary.
- The Haxe interpreter (eval) has **no sqlite** — `sys.db.Sqlite.open`
  throws "Not implemented for this platform". MiniLog tests are therefore
  native-only (see Testing).

## Tools (MCP server grows to six)

- `load_log_db {match: string}` — case-insensitive substring matched
  against every allowlist path (cron.d-derived logPaths ∪ `logs` ∪
  `services`, per `mcp-server.md`). All matching files load; no match →
  `isError` result listing the allowlist paths so the model can pick a
  better hint. Result:
  `{files: [{path, bytesLoaded, entries, truncated, error?}],
  totalEntries}` — `truncated: true` means the file exceeded its share and
  only the recent tail is in the DB.
- `query_log_db {sql: string}` — exactly one read-only SELECT against the
  loaded DB. Guard: the trimmed statement must start with `SELECT`
  (case-insensitive) and contain no `;` except trailing. sqlite errors
  (bad SQL, unknown column) pass through as `isError` text — the model
  fixes its SQL and retries. Query before any load → `isError`
  "call load_log_db first".

## Ingestion

New module `src/MiniLog.hx`: owns the single sqlite connection, exposes
`load(paths, budget)` and `query(sql)`; the MCP tool layer calls it.

- Budget `MAX_DB_BYTES = 100 MiB` total, split evenly across matched
  files. Each file contributes its **tail** share, read sequentially in
  64 KiB chunks — O(budget), never O(file); plan 02's no-full-scan rule
  stands.
- A share starting mid-line skips to the first newline (same rule as
  first-sight `LogTail.poll`); an unterminated final line is dropped (same
  as `lastLines`).
- Entry folding: a line without an `info`/`warn`/`error` prefix is a
  continuation — appended to the previous entry's body, level inherited.
  The level-prefix rule is extracted from `LogTail` into one public static
  helper both modules call (the only touch to existing code).
- All inserts in one transaction; unreadable matched file → skipped and
  reported per-file in the load result, load continues; every file
  failing → `isError`.

## Schema

```sql
CREATE TABLE entries(
  id INTEGER PRIMARY KEY,   -- global insert order
  path TEXT,                -- source log file
  seq INTEGER,              -- entry number within its file
  level TEXT,               -- info | warn | error
  body TEXT,                -- entry text incl. folded continuation lines
  byteOffset INTEGER        -- entry start offset in the source file
);
CREATE INDEX idx_level ON entries(level);
```

## Bounds

Compile-time constants, no knobs:

- `MAX_DB_BYTES = 100 MiB` ingest budget (per-file share = budget ÷ match
  count).
- `QUERY_MAX_ROWS = 200`, `QUERY_MAX_CHARS = 64 KiB` per query result —
  whichever trips first; the result notes truncation so the model refines
  with `WHERE`/`LIMIT`/aggregates instead of paging blindly.
- RAM: `:memory:` DB ≈ ingested bytes + sqlite overhead — roughly
  100–150 MB process peak while loaded, bounded.

## Single-threaded implication

`load_log_db` at full budget takes seconds (sequential read + one insert
transaction); the accept loop serves nothing meanwhile. Accepted: one
debugging client on localhost, one-shot flow — no threads for a
non-problem. Stated here so nobody "fixes" it casually.

## Error handling summary

All model-recoverable cases are `isError` tool results: no hint match
(lists allowlist), query before load, non-SELECT / multi-statement
rejected, sqlite message passthrough, per-file read failures in the load
report. Protocol/auth/transport errors are unchanged from
`mcp-server.md`.

## Testing

- **Native-only test group** (interpreter has no sqlite; the group is
  compiled/run only in `test-native.hxml`): entry folding incl.
  continuations from a `produce-log.sh error` fixture; budget split and
  `truncated` flags on a sparse large fixture with bytes-read ≤ share
  asserted; torn first/final line handling; SELECT happy path;
  non-SELECT and multi-statement rejected; row/char caps trip;
  query-before-load error; unreadable-file skip.
- `Mcp.handle` protocol tests and the rest of the tool layer stay
  two-target as specced in `mcp-server.md`; `tools/list` count updates to
  six.
- `haxe test.hxml` (interp) stays green without sqlite.

## Out of scope

- FTS5 / full-text indexes (LIKE over ≤100 MB is fast enough one-shot).
- Multiple concurrent DBs, ids, TTL/eviction, persistence across restarts.
- Timestamps parsed from log bodies (the format guarantees only level
  prefixes; insert order + seq is the time proxy).
- Any write access to source logs; the DB is a throwaway copy.

# MCP server — design spec

> Extended by `minilog-db.md` (2026-07-31): two more tools —
> `load_log_db` / `query_log_db` — load hint-selected log tails into a
> temporary in-memory sqlite database for SQL analysis. The server there
> grows to six tools and gains one piece of process state (the single DB
> slot).
>
> Extended by `prod-concurrency.md` (2026-08-01) for ~20 concurrent
> production users: the single-threaded accept loop below is superseded
> by a 4-worker pool with per-socket timeouts, and `query_log_db` gains
> an optional `db` argument. Statelessness is preserved — still no
> sessions.
>
> Related: `service-health.md` (2026-08-01) — the supervisor gains an
> error-only JSONL detections file for Sheriffs. Its `check_health` MCP
> tool was deferred by the user before implementation; the MCP tool set
> stays at six.

Approved design, 2026-07-31. Supersedes `cron-agent.md`: instead of the
binary calling an LLM itself (embedded curl agent loop), the binary exposes
its cron/log knowledge as **MCP tools** over authenticated HTTP, and any
MCP-capable client owns the LLM. The tool layer planned there
(`src/Pgrep.hx`, `LogTail.lastLines`, get_running_crons, tail_log) survives
unchanged as MCP tools; `Llm.hx` and the agent loop are dropped, never
built.

## Status

Implemented 2026-07-31 per `plan/06-mcp-server-implementation.md`. Board
below tracks this spec's tasks (minilog tasks live in `minilog-db.md`).
Curl-level protocol verification done (see Verified below); Claude Code
and llama.cpp client checks are manual exercises left for the user.

## Implementation board

### Done

- **Task 1 — Pgrep probe** · `src/Pgrep.hx`, `test/TestMain.hx` ·
  `pgrep -f` liveness probe, argv exec, ambiguous → false. Note: brief's
  bash-comment holder pattern was broken (bash tail-exec drops it);
  tests hold markers via `exec -a`.
- **Task 2 — LogTail.lastLines** · `src/LogTail.hx` · `classify` public;
  `lastLines(path, n)` reads only the final 64 KiB chunk; `poll`
  untouched.
- **Task 3 — Tools listing** · `src/Tools.hx` · allowlist
  (cron ∪ config, deduped), `get_running_crons` (flock/pgrep liveness +
  nextFire), `list_logs` (size/mtime/source).

- **Task 4 — tail_log + search_log** · `src/Tools.hx` · allowlist-guarded,
  bounded (last 4 MiB), case-insensitive substring, newest first;
  129 checks green both targets.

- **Task 5 — Mcp envelope** · `src/Mcp.hx` · auth-first Bearer check,
  JSON-RPC 2.0, initialize/ping/tools-list, pure `handle()` seam;
  148 checks green both targets.

- **Task 6 — tools/call dispatch** · `src/Mcp.hx` · four tools wired,
  `isError` results for model-recoverable failures; 158 checks green
  both targets.

- **Task 10 — HTTP serve loop + `Main mcp`** · `src/Mcp.hx`,
  `src/Main.hx` · 127.0.0.1 accept loop, config (`mcp.port`/`mcp.apiKey`
  required, `logs` allowlist), usage line. Interp 160 / native 192 checks
  green, review approved.

- **Task 11 — docs sync + manual verification** · doc/, README,
  CLAUDE.md, `test/mcp-config.json` · curl-level protocol verification
  done (see Verified below); Claude Code and llama.cpp client checks are
  manual exercises left for the user.

### In progress

*(none)*

### Todo

*(none)*

### Verified

Curl-level protocol check, 2026-07-31 (`./bin/Main mcp test/fixtures/cron.d
test/mcp-config.json`, `Authorization: Bearer dev-key-change-me`):

- `initialize` → `protocolVersion: "2025-03-26"`, `capabilities: {tools:{}}`.
- `tools/list` → all six tool schemas.
- `tools/call get_running_crons` → the 7 fixture entries (5 from
  `edge-cases`, 2 from `log-producer`), each with schedule/command/logPath/
  nextFire/running.
- `tools/call load_log_db {match:"failing"}` after seeding
  `test/live/failing.log` via `test/produce-log.sh error 20 0` →
  `{files:[{path:.../failing.log, bytesLoaded:948, entries:20,
  truncated:false, error:null}], totalEntries:20}`.
- `tools/call query_log_db {sql:"SELECT level, count(*) AS n FROM entries
  GROUP BY level"}` → `1 error / 15 info / 4 warn` (20 rows total,
  matching the load).

Server killed after (`pgrep`/port check confirmed no process left
listening on 8990).

Final-review fix, same day: `Content-Length` now counts UTF-8 bytes
(hxcpp `String.length` is UTF-16 code units — non-ASCII error strings
were under-declared and would truncate at strict clients). Re-verified
over curl on an em-dash error path: declared 133 = measured 133 bytes,
JSON parses. Suites after all fixes: interp 160, native 197, 0 failures.

Claude Code client check, 2026-08-01 — done:

- `claude mcp add --transport http cron-mcp http://127.0.0.1:8990/mcp
  --header "Authorization: Bearer …"` (local scope); `claude mcp list`
  reports **✔ Connected** — Claude Code's own MCP client completes the
  initialize handshake against the hand-rolled server.
- Headless session (`claude -p … --allowedTools
  "mcp__cron-mcp__get_running_crons"`) called the tool and reported all
  7 fixture entries with schedule, logPath, and running flags.
- Second session drove the minilog flow end to end:
  `load_log_db {match:"failing"}` → 40 entries / 1896 bytes / not
  truncated; `query_log_db` group-by-level → 2 error / 30 info / 8 warn
  (sums to 40); a follow-up SELECT returned both error entries' bodies
  **with their indented stack-trace continuation lines folded in** —
  the continuation rule verified through a real LLM client.
- Server killed after; port 8990 confirmed closed. The `cron-mcp` entry
  stays in Claude Code's local config (`claude mcp remove cron-mcp` to
  drop it).

**Open for the user**: the llama.cpp client configuration exercise —
manual, needs a locally running llama.cpp with an MCP-capable client.

## Goal

- MCP endpoint that can query `.log` files for better LLM context.
- Report currently running cron jobs.
- Authenticated with an API key.
- No SDK — the MCP protocol subset is hand-rolled (zero-dependency rule).
- LLM client configuration verified against a locally running llama.cpp
  model (manual exercise; see Testing).

## Decisions (settled with the user, 2026-07-31)

- MCP **replaces** the embedded agent loop from `cron-agent.md`.
- Transport: **Streamable HTTP, localhost only** (`127.0.0.1:<port>`),
  plain JSON responses, no SSE, no sessions.
- Tools: `get_running_crons`, `list_logs`, `tail_log`, `search_log`.
- Log scope: cron logs from the cron.d mapping + non-cron logs as
  **specific configured paths** (no directory globs).
- Integration: new subcommand **`Main mcp`** — standalone process, no
  coupling to the supervisor.
- End-to-end protocol check via **Claude Code as MCP client**; llama.cpp
  LLM configuration is a manual, documented exercise.

## Architecture

`Main mcp <cron.d-dir> <config.json>` — standalone single-threaded server:
blocking accept loop on `127.0.0.1:<port>` (`sys.net.Socket`), one HTTP
request per connection, respond, close (`Connection: close`; no
keep-alive). Every `tools/call` parses cron.d fresh (`Cron.parseDir`,
read-only, cheap) and probes live (`Flock.held`, `Pgrep.alive`) — no state
between requests, no coupling to the supervisor. Read-only with respect to
the system: parses cron.d, probes locks (`flock -n`) and processes
(`pgrep -f`), reads log tails — never executes or writes anything a cron
entry owns.

**Files**:

- `src/Mcp.hx` (new) — HTTP request parsing, JSON-RPC 2.0, MCP methods,
  tool schemas as constants. Core seam: `Mcp.handle(method, path, headers,
  body):Response` — a pure function; the socket loop around it stays thin.
- `src/Tools.hx` (new) — the four tool functions against `Cron.parseDir` +
  allowlist.
- `src/Pgrep.hx` (new) — process probe, mirrors `src/Flock.hx`:
  `pgrep -f -- <needle>`, exit 0 = running, 1 = not, anything else
  (127 no pgrep, …) = unknown → false.
- `src/LogTail.hx` — add `lastLines(path, n)` sharing the 64 KiB
  chunk discipline (`poll` returns counts, not lines; it stays untouched).
- `src/Main.hx` — subcommand dispatch + usage line.

## Config

Same `config.json` the supervisor uses, two new keys:

```json
{
  "mcp":  { "port": 8990, "apiKey": "..." },
  "logs": [ "/var/log/postgresql/postgresql-16-main.log" ]
}
```

- `mcp.port` and `mcp.apiKey` are **required** for the `mcp` subcommand —
  no default key, refuse to start without one (message + exit 1).
  *Amended 2026-08-01: the key may instead come from the
  `LOG_WATCHER_API_KEY` environment variable (`mcp.apiKey` wins when both
  are set) so systemd's `EnvironmentFile`/`.env` can hold the secret —
  see `deploy/.env.example` and `doc/install.md`. No key from either
  source still refuses to start.*
- `logs` — non-cron log allowlist: specific absolute paths only.
- Log allowlist = cron.d-derived logPaths ∪ `logs` ∪ `services`.

## MCP protocol subset (hand-rolled)

JSON-RPC 2.0 over `POST /mcp`. Methods:

- `initialize` — returns protocolVersion (echo the client's if known, else
  `"2025-03-26"`) and `capabilities: {"tools": {}}`.
- `notifications/initialized` — accepted, HTTP 202, no body.
- `tools/list` — the four tool schemas.
- `tools/call` — dispatch to `src/Tools.hx`.
- `ping` — empty result.

Stateless: no `Mcp-Session-Id` (optional per spec). `GET /mcp` → 405.

## Auth

`Authorization: Bearer <apiKey>` checked on **every** request before the
body is parsed; absent/mismatch → 401. Localhost-only bind keeps key and
traffic on the box; remote access later = reverse proxy with TLS in front,
not this codebase.

## Tools

- `get_running_crons` `{}` → array of `{schedule, command, logPath,
  nextFire, running}`. `running`: flocked entry → `Flock.held(lockPath)`;
  un-flocked → `Pgrep.alive(needle)` with needle = the command's first
  token starting with `/` (the script path; falls back to the first
  token). Ambiguous probe → `false`, the same safe-direction degrade as
  `Flock.held`.
- `list_logs` `{}` → allowlist enumerated: `{path, sizeBytes, mtime,
  source: "cron"|"config"}` (`mtime` = unix seconds). A
  configured-but-missing file is listed with `sizeBytes` and `mtime`
  null.
- `tail_log` `{path, lines?}` — lines default 20, cap 200; last complete
  newline-terminated lines via `LogTail.lastLines` (≤ 64 KiB tail chunk,
  torn final line dropped).
- `search_log` `{path, pattern, maxMatches?}` — **plain substring,
  case-insensitive, no regex**. Scans at most the last `SEARCH_CAP =
  4 MiB`, newest matches first; maxMatches default 20, cap 100; each match
  = `{byteOffset, line}`. The result notes when the cap truncated the
  window ("searched last 4 MiB only").

All bounds are compile-time constants (KISS — no knobs nobody asked for).
Plan 02's scale rule stands: never a full scan of a 2 GB log; everything
bounded. A path outside the allowlist → tool result with `isError: true`
and a plain-text reason (MCP convention; model-recoverable, not a protocol
error).

## Error handling

Per-connection try/catch — one bad request never kills the accept loop.

- Unparseable HTTP → 400. Body over 64 KiB → 413.
- Bad JSON / bad JSON-RPC envelope → `-32700` / `-32600`.
- Unknown method → `-32601`.
- Unknown tool or malformed tool arguments → `isError: true` tool result.
- Auth failure → 401, always checked first.
- Startup failures (port taken, missing apiKey, unreadable config) →
  message + exit 1.

## Testing

Zero-dep, no live LLM in the suite (plain asserts in `test/TestMain.hx`,
interp + native, same as everything else):

- **`Mcp.handle` driven directly** (pure function, no sockets): auth
  reject; initialize; tools/list; each tool's happy and error paths;
  malformed JSON-RPC. JSON assertions parse back, never string-compare
  (anonymous-object field order differs between interp and hxcpp).
- **Tool layer** exactly as planned in `cron-agent.md` Phase 1: fixture
  cron dirs; a real flock holder flips `running`; the pgrep self-match
  footgun check (nonsense needle → false); `lastLines` bounds proven on
  the sparse ~2 GB fixture (≤ CHUNK bytes read).
- **One socket smoke test**: server on an ephemeral port in a thread, one
  real HTTP POST round-trip.
- **Protocol check against a real client** (manual, recorded here when
  done): `claude mcp add --transport http cron-mcp
  http://127.0.0.1:8990/mcp --header "Authorization: Bearer <key>"`, then
  ask Claude Code to list running crons and tail the failing fixture log.
- **llama.cpp**: manual configuration exercise against a locally running
  llama.cpp model, documented here when done — explicitly out of automated
  scope (an MCP-capable client bridging llama.cpp is not this repo's
  code).

## Out of scope

- SSE streaming, sessions, keep-alive connections.
- TLS (reverse proxy's job) and non-localhost binds.
- Regex search, full-file scans, unbounded results.
- Any write/execute action derived from cron entries.
- MCP resources/prompts capabilities — tools only.

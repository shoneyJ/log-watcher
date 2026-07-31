# MCP server — design spec

Approved design, 2026-07-31. Supersedes `cron-agent.md`: instead of the
binary calling an LLM itself (embedded curl agent loop), the binary exposes
its cron/log knowledge as **MCP tools** over authenticated HTTP, and any
MCP-capable client owns the LLM. The tool layer planned there
(`src/Pgrep.hx`, `LogTail.lastLines`, get_running_crons, tail_log) survives
unchanged as MCP tools; `Llm.hx` and the agent loop are dropped, never
built.

## Status

Design approved; implementation not started. Implementation phases follow
in a separate planning step.

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

# Features

As-built behavior per module. Source references are the ground truth;
this file states what they do without reading them.

## Tail reader — `src/LogTail.hx`

One `poll(path, state, now)` call per watched log per interval:

- Reads at most **CHUNK = 64 KiB** of new tail bytes per poll; a file is
  never scanned front to back (the 10 × 2 GB constraint from plan 02).
- **First sight**: reading starts at `size − CHUNK` (or 0 for small files);
  a partial first line is read as a continuation, which is acceptable.
- **Rotation**: inode change (logrotate rename/recreate) or size below the
  stored offset (truncate) → restart from offset 0 and forget the last level.
- **Burst**: if more than CHUNK bytes are unread, the offset jumps to
  `size − CHUNK` — only the tail matters for the alert rule.
- **Torn final line**: only complete, newline-terminated lines are judged;
  a trailing partial line waits for its newline on a later poll.
- **Classification** (relaxed rule, shared via `LogTail.classifyLoose`):
  lines are sanitized (`Tools.sanitize`: ANSI/C0 stripped), then the level
  comes from the `info` / `warn` / `error` prefix or from a level token
  after a leading timestamp (`2026-07-22T15:40:00 - error: …`); any other
  line is a continuation and inherits the previous entry's level.
- The file handle is opened and closed **inside** the poll, so a held
  descriptor never pins a rotated 2 GB file on disk. If the file shrinks
  between `stat` and read, the poll returns empty and the next one re-syncs.
- Per-file state (`TailState`): offset, inode, last level, clock of the last
  complete lines — memory stays O(watched files), not O(file size).
- `now` is injected, so tests drive synthetic time.

## Alert rule and watch modes — `src/Watcher.hx`

- **The alert rule**: the last complete entry is `error` **and** no new
  complete lines arrived for `quietPeriod`.
- **Service mode** (`live = true`): prints `ALERT <path>` once when the rule
  trips and `CLEAR <path>` when a non-error entry later arrives.
- **Cron mode** (`live = false`): the supervisor drives it. `done(now)` is
  true after `quietPeriod` of silence since the last write — or since
  activation, if the log never produced content. `result()` is one of:
  - `Ok` — content arrived, final entry not error
  - `ErrorFinal` — final entry is error → alert
  - `Miss` — the log never produced content during the window

## Cron parser — `src/Cron.hx`

- `parseDir(dir)` is **read-only** and the directory is always a parameter,
  so tests and the demo run on fixture dirs without root. Files with a dot
  in the name and subdirectories are ignored (matching cron's own rule);
  comments, blank lines, and environment assignments are skipped.
- Job lines are cron.d format: `minute hour dom month dow user command`.
  `@hourly`/`@daily`/`@midnight`/`@weekly`/`@monthly`/`@yearly`/`@annually`
  expand to 5-field expressions; `@reboot` is skipped (no activation time).
- **Watchability convention**: the log path is the first redirection target
  (`>`, `>>`, `2>`, `2>>`, `&>`, `&>>`) ending in `.log` and containing no
  `$`. Entries without one — no redirect, pipe, `$VAR` path — are recorded
  as skipped with a reason, never a parse failure. Malformed lines and
  unreadable files are likewise skipped and reported; the parser can never
  take down the supervisor.
- **Flock note**: a command whose first token is `flock` (or `*/flock`)
  additionally yields `lockPath` — the first `/`-starting token after
  `flock`, before any `-c` (option arguments like `-w 600` are skipped
  naturally). Un-flocked commands get `lockPath = null`.
- `nextFire(expr, from)` returns the next fire time strictly after `from`
  at minute resolution, or `null` if none within 366 days (or the
  expression is invalid). Supports ranges, lists, steps, month/day names,
  `7` as Sunday, and the vixie quirk: when **both** dom and dow are
  restricted, the day matches when _either_ does (OR, not AND).

## Flock probe — `src/Flock.hx`

- `Flock.held(path)`: is an exclusive lock currently held? Shells out to
  util-linux flock: `FileSystem.exists(path) && Sys.command("flock",
["-n", path, "true"]) == 1`.
- Only exit 1 (`-n` conflict) means held; every ambiguous outcome —
  unreadable lock file (exit 66), no flock binary (127) — reports "free",
  so the supervisor falls back to watching normally, the safe direction.
- The `exists()` guard keeps the probe read-only (`flock -n` would
  `O_CREAT` a missing lock file), and a missing file is not held anyway.

## Supervisor — `src/Supervisor.hx`

- A **single-threaded event loop** (supersedes the thread-per-watch design
  in plans 02/04). `run()` ticks with the real clock every 0.25 s;
  `tick(now)` takes injected time, so the whole lifecycle is unit-testable.
- **Rescan** every `rescanInterval`: a cheap mtime signature over the
  cron.d directory gates the reparse — unchanged directory, no work.
  New entries are scheduled, changed ones rescheduled; removed entries lose
  their pending activation, while an already active watch finishes its
  window (the job may still be running).
- Entries redirecting to the **same log collapse into one watch** whose
  next fire is the minimum over their schedules — two watchers never tail
  the same file. The collapsed `lockPath` is kept only when every entry
  agrees on it; any disagreement clears it to null (always watch).
- **Skip-locked windows**: a watch with a `lockPath` is probed once within
  2 s (`PROBE_LEAD`) _before_ its fire time — probing at activation would
  see the job's own just-acquired lock. If the probe found the lock held,
  activation reports `SKIP-LOCKED`, recomputes the next fire, and creates
  no watcher (the previous run is still going; this fire won't produce
  output). No probe taken — e.g. the supervisor started past the fire —
  means the watch runs as before. The `SCHEDULE` line notes the lock:
  `SCHEDULE …: */20 * * * * (flock /var/run/test.lock)`.
- **Activation → completion**: at `nextFire` a cron-mode `Watcher` is
  created and polled while due; when `done()`, the completion is recorded
  (`DONE … ok` / `ERROR-final` plus an `ALERT` line / `missed`), the
  watcher is removed, and the next fire is recomputed. The **kill-self
  guarantee** holds by construction: a completed watch is an object that is
  dropped, and file handles only exist inside a single `LogTail.poll` call.
- **Mid-window startup**: on the first scan, a scheduled log whose mtime is
  within `quietPeriod` of now is activated immediately instead of waiting
  for the next fire.
- Service logs from the config are watched continuously for the
  supervisor's lifetime.
- **Detections sink** (service-health): with the optional `detections`
  config key set, every rule hit — a cron window ending `error-final`, a
  service log tripping the alert rule — appends one JSON line
  (`ts`, `path`, `source`, `event`, sanitized `lastError`) to that file,
  open-append-close per line (logrotate-safe). Error events only: no
  ok/clear/missed lines — the file exists to tell the Sheriff something
  is wrong and where to look (`cat`/`tail -f` it). Sink failures are
  reported to stdout and never take the supervisor down.

## CLI and config — `src/Main.hx`

- `Main watch <logfile> [quietPeriod=10] [pollInterval=2]` — one continuous
  service watch.
- `Main run <cron.d-dir> [config.json]` — the supervisor. JSON keys, all
  optional: `pollInterval` (default 2), `quietPeriod` (10),
  `rescanInterval` (60), `services` — log paths watched continuously,
  each a plain string or a `{ "path": … }` object — and `detections`,
  the error-events JSONL sink path (absent → journal only).
- All output goes to stdout via `Util.say` (println + flush, so it is
  visible immediately when redirected).

## Test and demo tooling — `test/`

- `test/TestMain.hx` — zero-dependency plain asserts, 12 test groups: tail
  basics / torn line / rotation, an O(chunk) proof on a sparse ~2 GB
  fixture, the producer fixture, cron parsing fixtures, `nextFire`, the
  flock probe, the watcher state machine, and supervisor lifecycle +
  mid-window activation + skip-locked windows. Lock tests hold a real
  flock deterministically (`flock <file> -c "echo ready; cat"` — reading
  `ready` proves acquisition, closing stdin releases), no sleeps. Run with
  `haxe test.hxml` (interpreter) or
  `haxe test-native.hxml && ./bin/test/TestMain` (native — required before
  calling work done).
- `test/produce-log.sh [FINAL_LEVEL] [LINES] [INTERVAL_SECS]` —
  deterministic fake producer: warn every 4th line, info otherwise, final
  entry at FINAL_LEVEL; an `error` final appends two indented continuation
  lines to exercise the continuation rule.
- `test/demo.sh` — ~2.5 min end-to-end run of the supervisor against
  `test/fixtures/cron.d/`, showing SKIP lines for edge-case entries, an
  `ok` completion, an `ERROR-final` completion with its ALERT, and a
  `missed` window.
- `test/fixtures/cron.d/` — `log-producer` (two watchable entries; also
  installable as a real `/etc/cron.d` file) and `edge-cases` (malformed and
  non-watchable variants).

## MCP server — `src/Mcp.hx`, `src/Tools.hx`, `src/MiniLog.hx`, `src/Pgrep.hx`

- `Main mcp <cron.d-dir> <config.json>` — standalone subcommand, no
  coupling to the supervisor. `config.json` needs `mcp.port`, and the API
  key comes from `mcp.apiKey` or, when that is absent, the
  `LOG_WATCHER_API_KEY` environment variable (systemd `EnvironmentFile`
  / `.env` — see `deploy/`); no key from either source refuses to start.
  `logs` (specific absolute paths) and `services` widen the log
  allowlist alongside the cron.d-derived paths.
- **Auth**: every request needs `Authorization: Bearer <apiKey>`, checked
  before the body is parsed — mismatch or absent → 401.
- **Transport**: `Mcp.serve(port)` is a blocking accept loop on
  `127.0.0.1:<port>` (`sys.net.Socket`), one HTTP request per connection,
  `Connection: close`, no keep-alive, no SSE, no sessions. A per-connection
  try/catch means one bad request never kills the loop; body over
  `BODY_MAX = 64 KiB` → 413.
- **Protocol**: JSON-RPC 2.0 over `POST /mcp`, hand-rolled (no SDK).
  `Mcp.handle(req):HttpResp` is a pure function — the socket loop around it
  is thin and the whole protocol is testable without sockets.
  `initialize` (echoes protocol version `2025-03-26`, `capabilities:
  {tools:{}}`); `notifications/initialized` and any other request with no
  `id` → 202 with no body; `ping` → empty result; `tools/list` → the six
  tool schemas; `tools/call` → dispatch to `src/Tools.hx` / `src/MiniLog.hx`.
  Bad JSON → `-32700`; missing `method` → `-32600`; unknown method →
  `-32601`.
- **Tools** (`src/Tools.hx`, allowlist = cron.d logPaths ∪ config `logs` ∪
  `services`, deduped):
  - `get_running_crons {}` — every cron.d entry's schedule, command,
    logPath, `nextFire`, and `running` (flocked entry → `Flock.held`;
    un-flocked → `Pgrep.alive` against the command's first `/`-starting
    token). An ambiguous probe reports not-running, same safe direction as
    `Flock.held`.
  - `list_logs {}` — every allowlisted path with `sizeBytes`, `mtime`
    (unix seconds), `source` (`"cron"` or `"config"`); a missing file gets
    null size/mtime instead of an error.
  - `tail_log {path, lines?}` — last complete lines via
    `LogTail.lastLines` (≤ 64 KiB tail chunk, torn final line dropped);
    `lines` defaults to 20, capped at 200.
  - `search_log {path, pattern, maxMatches?}` — plain substring,
    case-insensitive, no regex, over at most the last `SEARCH_CAP = 4 MiB`
    of the file; matches come back newest-first as `{byteOffset, line}`;
    `maxMatches` defaults to 20, capped at 100.
  - `load_log_db {match}` — case-insensitive substring against every
    allowlisted path; every match loads into the minilog DB (see below);
    no match → `isError` listing the known paths.
  - `query_log_db {sql}` — one read-only SELECT against the loaded DB.
  - A path outside the allowlist, or any other model-recoverable failure
    (missing args, unknown tool, empty pattern, missing file), comes back
    as a tool result with `isError: true` and a plain-text reason — never
    a JSON-RPC protocol error.
- **Minilog DB** (`src/MiniLog.hx`) — a single-slot `sys.db.Sqlite`
  `:memory:` connection held by the server process; `load()` closes and
  replaces any previous slot wholesale (dies with the process, no ids, no
  TTL). `MAX_DB_BYTES = 100 MiB` total budget split evenly across matched
  files, each read tail-first in 64 KiB chunks. Every line is sanitized
  before classification and storage (`Tools.sanitize`: ANSI sequences and
  C0 control bytes stripped, tab kept — raw control bytes would make the
  JSON tool output invalid); levels come from the strict prefix rule
  (`LogTail.classify`) or, failing that, from a level token after a
  leading timestamp (`2026-07-22T15:40:00 - error: …`); remaining
  unmatched lines fold into their parent entry as continuations. Table
  `entries(id, path, seq, level, body, byteOffset)` plus `idx_level`. Every
  file failing to read → `isError`; a partial failure is reported per-file
  in the load result and the load continues. `query()` guards to exactly
  one statement starting with `SELECT` (case-insensitive) and no internal
  `;`; sqlite errors pass through as `isError` text; results cap at
  `QUERY_MAX_ROWS = 200` rows / `QUERY_MAX_CHARS = 64 KiB`, whichever trips
  first, with a `truncated` flag. A query before any `load_log_db` →
  `isError` "call load_log_db first".
- **Process probe** (`src/Pgrep.hx`) — `pgrep -f -- <needle>`; exit 0 =
  running, exit 1 = not, anything else (127 no pgrep, …) = unknown →
  reports not running.
- **Native-only note**: hxcpp bundles sqlite statically, so the minilog
  tools work in the compiled binary; the Haxe interpreter has no sqlite
  binding, so `MiniLog`'s own tests run only under `test-native.hxml` (the
  rest of the MCP layer — `Mcp.handle`, `Tools` — is tested on both
  targets).

# Service health detections — design spec

Approved design, 2026-08-01 (amended same day: the `check_health` MCP
tool is **deferred** — this iteration builds only the detections file).
A log whose **last entry is an error with nothing after it** indicates
an affected service (the project's founding rule); the always-running
supervisor records every such detection in a local JSONL file the
Sheriff can `cat`.

Source problem (ticket): Sheriffs notice stalled services only by
manually inspecting logs — e.g. `inventoryService.log` ends with an
`error` entry and nothing follows. Detection within ≤5 minutes, 100%
of monitored logs covered.

## Status

Implemented 2026-08-01. Verified live twice: (1) a timestamped-format
service log ending in an error produced exactly one detection line — a
log the strict prefix rule would have ignored; (2) on the deployed
systemd services with real cron: the `*/5` fixture window fired
04:35:00, the job's final error landed 04:35:23, the supervisor wrote
the JSONL line 04:35:34 — 11 s detection latency vs the 5-minute KPI —
while the healthy window in the same minute wrote nothing (pure
signal). Deployment gotcha captured in `deploy/log-watcher.local.service`:
the stock unit's `ProtectHome=true` hides `/home`, so home-dir logs
read as missing — the local variant relaxes it to `read-only`. Suites
green both targets (interp 166 / native 207).

## Implementation board

### Done

- **Relaxed classification in the watcher** · `LogTail.classifyLoose`
  (strict prefix OR level-after-timestamp; callers sanitize) — used by
  `LogTail.poll`, minilog ingest, and the sink; MiniLog's private copy
  removed.
- **Detections JSONL sink** · `Supervisor.detect()` on cron
  `error-final` and service `alert` transitions; config key
  `detections` (Main.loadConfig); `StateDirectory=log-watcher` +
  `detections` path in the deploy samples.
- **Docs + live verification** · features.md/install.md synced;
  timestamped error-final log → one JSONL line, `cat` verified.

### In progress

*(none)*

### Todo

*(none)*

## Decisions (settled with the user, 2026-08-01)

- **Detection-only stands.** Any notification delivery — Slack, mail,
  webhooks, anything outside the MCP server — is **out of scope**.
- **The supervisor is the detector of record**: the always-running
  `log-watcher` process — which already ticks only actively-running
  cron job logs plus the continuous service logs — applies the rule
  ("last entry is error, no further log recorded") and **appends error
  events only** to a local JSONL file with a timestamp. The file
  exists for one purpose: tell the Sheriff that something is wrong and
  where to look. No ok/clear/missed lines, no bookkeeping.
- **`check_health` MCP endpoint: removed for now** (user, 2026-08-01).
  The earlier tool design (four states over the allowlist, stat+chunk
  verdicts, `detectedAt` enrichment) is recorded in this file's git
  history and can return as its own iteration. Until then Sheriffs
  read the detections file directly; adding its path to the config
  `logs` list also makes it reachable through the existing
  `tail_log`/`search_log`/`load_log_db` tools.
- **Monitored set = what the supervisor watches**: cron.d-derived logs
  (during their windows) ∪ `services` (continuously). To cover
  `inventoryService.log`, list it under `services`. Query-only `logs`
  entries are not health-monitored — they have no watcher.

## Watcher classification (prerequisite)

The watcher's current rule is the strict line prefix
(`info`/`warn`/`error`). Real service logs put a timestamp first
(`2026-07-22T15:40:00 - error: …`) — under the strict rule every line
is a continuation and **no detection would ever fire** for exactly the
logs the ticket cares about. Therefore the relaxed classification
(sanitize ANSI/control bytes, then strict prefix OR level after a
leading timestamp token — today private to `MiniLog.classifyLine`)
becomes the shared rule, used by `LogTail.poll` (the watcher),
minilog ingest, and the sink. Consequence: deployments watching
timestamped logs start alerting on them — that is the point; plain
prefix logs behave exactly as before.

## Detections file (JSONL)

The supervisor (`Main run`) gains one append-only sink, enabled by a
new optional config key `detections` (absolute file path; absent →
today's behavior, journal only). **Error states only — the file's sole
purpose is to tell the Sheriff that something is wrong and where to
look.** One JSON line per rule hit, flushed immediately:

```json
{"ts":"2026-08-01T03:20:00+02:00","path":"/var/log/inventoryService.log","source":"service","event":"alert","lastError":"error 2026-08-01T03:15:12 upload failed"}
```

- Written: a cron window ending `error-final`; a service log tripping
  the alert rule (`alert`). Each line carries the timestamp, the log
  path (where to look), and the sanitized final error line (what it
  said).
- **Not written**: ok completions, clears, missed windows, any
  bookkeeping — recovery is visible in the service log itself and in
  the journal; the file stays pure signal.
- Sheriffs `cat`/`tail -f` the file — every line is an incident
  pointer. Adding the file's path to the config `logs` list makes the
  same history queryable through the existing MCP tools.
- Deployment: `/var/lib/log-watcher/detections.jsonl` via systemd
  `StateDirectory=log-watcher` (the one exception to "the process
  writes nothing"; `ProtectSystem=strict` stays, StateDirectory is the
  sanctioned writable spot). Growth is one line per incident — tiny;
  the supervisor opens-appends-closes per line, so logrotate is safe.

## KPI mapping (from the ticket)

- *100% coverage* — every supervisor-watched log is covered; coverage
  is config (`services` + cron.d), not code.
- *Detection ≤5 min* — the verdict lands in the file the moment the
  quiet period elapses (default 10 s for services; a cron window
  completes within quietPeriod of its last write) — far inside 5 min.
- *Fewer manual inspections / MTTD* — one `cat` (or one MCP query over
  the file) replaces reading N logs; `lastError` starts the diagnosis.
- *No outage undetected due to missing activity* — cron `missed`
  windows and long-silence detection stay visible in the journal;
  file-based `stale` reporting is deferred with `check_health`.

## Out of scope

- **Any notification delivery** — Slack, mail, webhook, exec hooks, or
  documenting external notifier setups. The file is written; reading
  it is the Sheriff's side.
- **`check_health` MCP tool** — deferred (removed from this iteration
  by the user).
- Root-cause analysis, self-healing, restarts (per the ticket).
- Performance metrics (CPU/memory/latency).
- The supervisor's journal ALERT/DONE output — unchanged.

## Verification (no new test code — user rule)

- Existing suites stay green on both targets (the relaxed watcher rule
  must keep every existing strict-prefix check passing; fixture logs
  use plain prefixes).
- Live, with the supervisor running and `detections` configured: the
  fixture cron's `failing.log` window completes → exactly one
  `error-final` line appears in the file (verified by `cat` — and
  nothing appears for healthy windows); a timestamped-format service
  log ending in an error trips an `alert` line (proving the relaxed
  rule end to end); logrotate-style truncation of the file between
  events loses nothing (open-append-close per line).

# Implementation phases

Ordered roadmap from the designs in plans 01–03 to a working watcher. Each
phase is small enough to review and commit on its own, and each defines
"done" as something runnable — no phase is complete on code alone.

## Status

- [x] Phase 1 — Tail reader core
- [x] Phase 2 — Watch loop & alert rule
- [x] Phase 3 — Cron parser + nextFire
- [x] Phase 4 — Supervisor & lifecycles
- [x] Phase 5 — End-to-end validation & deployment notes

All phases implemented in one pass; tests: `haxe test.hxml` (interp) and
`haxe test-native.hxml && ./bin/test/TestMain` (native), demo:
`./test/demo.sh`. One deliberate deviation, noted under Phase 4: the
supervisor is a single-threaded loop, not thread-per-watch.

## Ground rules (every phase)

- **Zero dependencies**: stdlib only, for runtime and tests. Config parsing
  uses `haxe.Json`; tests are plain assertions in `test/TestMain.hx` run via
  `haxe test.hxml` — no test framework haxelib.
- **Two-target verification**: iterate on the interpreter
  (`haxe test.hxml`), but a phase is only done after `haxe build.hxml`
  compiles and the native binary passes the same checks.
- **Docs move with code**: when a phase lands, tick its checkbox above and
  update README/CLAUDE.md if commands changed; refresh `.dev/commit.md` for
  the user's manual commit.

## Testing base (exists — shared by all phases)

- `test/produce-log.sh` — fake log producer. Emits level-prefixed lines to
  **stdout**; the caller's redirection decides the log file, which is the
  same contract the cron parser extracts from cron.d entries (plan 03).
  `produce-log.sh [FINAL_LEVEL] [LINES] [INTERVAL_SECS]` — deterministic
  body (warn every 4th line, info otherwise), final entry at FINAL_LEVEL,
  and when that is `error`, two indented continuation lines follow to
  exercise plan 02's continuation rule.
- `test/fixtures/cron.d/log-producer` — real cron.d-format file, used two
  ways: as a parser fixture (tests point the cron.d dir parameter at
  `test/fixtures/cron.d/`) and as the live cron (`sudo cp` to
  `/etc/cron.d/`, see the file header). Two entries: `healthy.log` every
  minute ending `info` (never alerts); `failing.log` every 5 minutes ending
  `error` (alerts after the quiet period, with gaps long enough to observe
  kill-self). Absolute paths, no `$VAR`s, per the watchability convention.
- `test/live/` — where the cron entries write; gitignored.

## Phase 1 — Tail reader core

The pure tail-reading logic from plan 02, with no loop around it yet.

**Files**: `src/LogTail.hx`, `test/TestMain.hx`, `test.hxml`,
`test/fixtures/`

**Deliverable**: one poll = `stat` the file → seek to the stored offset (or
`EOF − 64 KB` on first sight) → split into complete lines (torn final line
held back until its newline arrives) → classify each line's level
(`info`/`warn`/`error` prefix; unprefixed lines inherit the previous
entry's level) → update the per-file state record (offset, inode, timestamp
of last new line, level of last entry). Rotation: inode change or
size < stored offset → reopen from 0. The file handle is opened per poll
and closed before returning.

**Done when**:
- Fixture tests pass: level classification, continuation lines (fixtures
  generated with `test/produce-log.sh error …`), torn final line, rotation
  by rename and by truncate.
- A sparse ~2 GB fixture (created by seeking, no real disk cost) is polled
  and the bytes read are ≤ the chunk size — proving O(chunk), not O(file).

## Phase 2 — Watch loop & alert rule

One log watched end to end, continuously (the service-log lifecycle).

**Files**: `src/Watcher.hx`, `src/Main.hx` (CLI wiring)

**Deliverable**: a poll loop calling LogTail every `poll_interval`. Alert
state when the last complete entry is `error` **and** `quiet_period` has
elapsed with no new lines; flagged once to stdout (detection only), cleared
when new lines arrive. Config record per plan 02 (`path`, `mode`,
`poll_interval`, `quiet_period`) loaded from a JSON file via `haxe.Json`.

**Done when**:
- Unit tests cover the state machine: error→silence flags after quiet
  period; error→info never flags; flag clears on new activity.
- Scripted demo: `test/produce-log.sh` writes into `test/live/` while the
  watcher runs — `… error N >> file.log` flags after the quiet period, a
  following `… info N >> file.log` run clears it, observable in stdout.

## Phase 3 — Cron parser + nextFire

Plan 03 in full, as a standalone module — no supervisor yet.

**Files**: `src/Cron.hx`, `test/fixtures/cron.d/` (exists with
`log-producer`; this phase adds malformed and non-watchable variants),
tests in `test/TestMain.hx`

**Deliverable**: parse a cron.d **directory passed as a parameter** (never
hardcoded `/etc/cron.d`): skip comments/blank/env lines; from each job line
extract the 5 schedule fields, user, command, and the log path from output
redirection (`>`, `>>`, `2>`, `2>>`, `&>`, `&>>`). Watchability convention:
`.log` redirect required; pipes, `$VAR` paths, or no redirect → reported
once, never fatal. `nextFire(expr, from)` supporting ranges, lists, steps,
month/day names, `@` aliases, and the dom/dow OR quirk.

**Done when**: the plan 03 Testing checklist passes against fixture dirs
without root — redirection variants, skipped lines, `nextFire` correctness
incl. the OR quirk, non-watchable reporting, malformed lines skipped.

## Phase 4 — Supervisor & lifecycles

Everything joins up: threads, scheduling, discovery, kill-self.

**Files**: `src/Supervisor.hx`, `src/Main.hx`

**Deliverable**: one `sys.thread.Thread` per watch. Service watchers run
for the supervisor's lifetime. Cron watchers are spawned at `nextFire` time
and complete on the quiet period (plan 02's completion option 2; the
process-liveness check is a stretch, added only if quiet-period detection
proves insufficient). **Kill-self guarantee**: on completion the supervisor
joins the thread and confirms nothing of the watch remains.

> *As implemented (supersedes the thread design above and plan 02's process
> model): the supervisor is a single-threaded loop (`src/Supervisor.hx`)
> polling all active watches each tick — simpler than thread-per-watch and
> sufficient for 10 logs at O(chunk) per poll. The kill-self guarantee holds
> by construction: a completed cron watch is an object that is dropped, and
> file handles exist only inside a single `LogTail.poll` call.* The cron.d dir
is rescanned every 60 s, mtime-gated: new entry → schedule; changed →
reschedule; removed → cancel pending activation (a live watch finishes its
window). Entries redirecting to the same log collapse into one watch; on
startup mid-window, activate immediately.

**Done when**: integration test pointing the supervisor at
`test/fixtures/cron.d/` (jobs = `test/produce-log.sh`) shows — thread count
back to baseline after a job's watch completes; a newly dropped cron file
picked up within one rescan; a removed file's pending activation cancelled.
Optionally verified against the live install (`sudo cp` the fixture to
`/etc/cron.d/`) with real cron firing the jobs.

## Phase 5 — End-to-end validation & deployment notes

**Files**: demo script under `test/`, README, CLAUDE.md, deployment notes

**Deliverable**: a demo running the full sizing target — 10 sparse ~2 GB
logs with live producers — where every rule is observable: error-final
detection, rotation survival, cron activation and kill-self. Measure bytes
read per poll and steady-state memory. Write the deployment note (the
watcher's user needs read access to the cron.d dir and the log paths).
Bring README quickstart and CLAUDE.md commands up to final reality (test
command, demo command).

**Done when**: the demo script runs green on this machine and the docs
match what actually exists.

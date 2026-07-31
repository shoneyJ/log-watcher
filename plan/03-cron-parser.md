# Cron parser

## Objective

Cron-driven watches need **zero hand-written config**. A cron.d entry
already carries everything the watcher needs — the schedule, the script it
runs, and (via output redirection) the log file it writes. Parsing
`/etc/cron.d` therefore *generates* the watcher configs. A system engineer
drops a new cron file into `/etc/cron.d` and log-watcher starts covering it
without a restart or a config edit.

> Supersedes the `cron_match` field from `02-what-gets-monitored.md`: there
> the hand-written config pointed at a cron entry; here the direction is
> inverted — parsed cron entries produce the config. Hand-written entries
> remain only for service logs and for per-job overrides.

## Input: the /etc/cron.d format

Each file in `/etc/cron.d` contains, line by line:

- comments (`#`) and blank lines — skipped
- environment assignments (`SHELL=`, `PATH=`, `MAILTO=`) — skipped (the
  parser never executes anything, so the environment is irrelevant)
- job lines: `minute hour dom month dow user command`
  (cron.d has the extra `user` field, unlike user crontabs)

What the parser extracts from a job line:

| Field | Used for |
| --- | --- |
| 5 schedule fields | computing the next activation time |
| `user` | informational; recorded with the job |
| command (script) | process-liveness check in completion detection (plan 02) |
| redirection target | **the log path** — from `>`, `>>`, `2>`, `2>>`, `&>`, `&>>` |

> Extended by `05-flock-aware-watching.md`: from watchable commands the
> parser additionally extracts a sixth field — the flock lock file path —
> feeding the supervisor's skip-locked rule.

**Watchability convention**: an entry is watchable only if its command
redirects stdout/stderr to a file path ending in `.log`. Entries without
such a redirection (no redirect, pipe to `logger`, `$VAR` in the path) are
recorded and reported once as "not watchable" — never a parse failure.

## Generated config

Every watchable entry yields the plan-02 config record:
`path` (from redirection), `mode=cron`, schedule (parsed, replacing
`cron_match`), `poll_interval` / `quiet_period` from global defaults.
A hand-written override keyed by log path may adjust the defaults (e.g. a
longer `quiet_period` for a slow job); parsed fields win for schedule and
path.

If several cron entries redirect into the **same log file**, they collapse
into one watch whose activation is the union of the schedules — two watchers
must never tail the same file.

## Schedule computation

- Support the standard 5-field syntax: numbers, `*`, ranges (`1-5`), lists
  (`1,5,9`), steps (`*/10`, `1-30/5`). Month/day names (`jan`, `mon`) and
  `@hourly`/`@daily`/`@weekly`/`@monthly`/`@yearly` aliases are cheap to add
  — include them. `@reboot` is out of scope (no meaningful activation time).
- Standard cron quirk to honor: when **both** dom and dow are restricted,
  the job fires when *either* matches (OR, not AND).
- The deliverable is a single function: `nextFire(expr, from): timestamp`,
  used by the supervisor to schedule watcher activation.

## Discovery of new/changed cron files

- Rescan `/etc/cron.d` every 60 s — the same cadence cron itself uses.
  Cheap check first: directory + per-file mtimes; reparse only what changed.
- New entry → generate config, schedule next activation.
- Changed schedule → recompute pending activation.
- Removed entry → cancel its pending activation; a watcher currently inside
  its window is left to finish normally (the job may still be running).
- Malformed lines or unreadable files: skip, report once, keep parsing the
  rest. The parser must never take down the supervisor.

## Design constraints

- **Read-only**: the parser only reads cron files; it never writes them or
  executes commands found in them.
- **The cron.d path is a parameter** (default `/etc/cron.d`). This is what
  makes the parser testable with fixture directories and lets the demo run
  unprivileged.
- Runs with whatever permissions the watcher process has; requires read
  access to the cron.d directory and to the discovered log paths — document
  the expected user/group in the deployment notes when they exist.

## Testing

Unit-test the parser against fixture cron files, no root and no real
`/etc/cron.d`:

- valid job lines incl. all redirection variants → correct log path
- env lines, comments, blank lines → skipped
- ranges/lists/steps/aliases and the dom/dow OR quirk → correct `nextFire`
- non-watchable entries (no redirect, pipe, `$VAR` path) → reported, not fatal
- malformed lines → skipped without aborting the file

## Out of scope

- User crontabs (`crontab -l`), `/etc/crontab`, anacron, systemd timers —
  `/etc/cron.d` only (consistent with plan 02).
- `@reboot` entries.
- Expanding shell variables or resolving `tee`-style pipelines to find the
  log path — plain redirection only.

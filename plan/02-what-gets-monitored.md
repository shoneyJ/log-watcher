# What gets monitored

## Objective

A host has many `.log` files. The watcher monitors only the configured set,
applying the core rule from the README to each: **if the last entry in a log
is `error` and no further entries arrive, that log is in an alert state**
(emitting the alert is out of scope — the watcher only has to detect and
flag the condition).

## Log sources and their lifecycles

Two kinds of producers write the logs, and they need different watcher
lifecycles:

| Source           | Producer lifetime                        | Watcher lifecycle                                                                                 |
| ---------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------- |
| **Service log**  | Long-running daemon, writes indefinitely | Continuous: watch from watcher startup until shutdown                                             |
| **Cron job log** | Short-lived process on a schedule        | **Alive only when needed**: start watching at the job's scheduled time, stop when the job is done |

### "Alive only when needed" (cron logs)

- The schedule is not duplicated by hand: the watcher **parses `/etc/cron.d`**
  (fields: minute hour dom month dow user command) and computes each job's
  next activation time.
- The config maps a watched log file to its cron entry (match on a command
  substring), since cron entries don't declare where their output lands.
- At activation time, the supervisor spawns a per-job watcher (thread or
  child process).
- Completion, decided in order of preference:
  1. the job's process is gone **and** no new lines for a quiet period, or
  2. no new lines for a configurable quiet period after last write.
- Completed with no `error` as the final entry → all good, nothing reported.
- **Kill-self guarantee**: once the job is judged complete, the per-job
  watcher must fully terminate — no thread, process, or open file handle
  belonging to that job's watch may remain. The supervisor verifies reaping
  (join the thread / wait on the child) rather than trusting it.

## Configuration

One config file read at startup, one entry per watched log:

- `path` — the log file (e.g. `/var/log/file.log`)
- `mode` — `service` | `cron`
- `cron_match` — command substring identifying the `/etc/cron.d` entry
  (cron mode only)
- `poll_interval` — tail-check period (default a few seconds)
- `quiet_period` — silence window used both for "job is done" (cron mode)
  and for "last error was final" (the alert rule)

## Scale and performance constraints

Sizing target: **10 log files, ~2 GB each.**

- **Never read a file front to back.** 2 GB × 10 rules out full scans:
  `stat` the file, seek to a stored offset (or near EOF on first sight) and
  read only the tail chunk (e.g. last 64 KB) to find the latest complete
  lines.
- Keep a small per-file state record: last offset, last inode, timestamp of
  last new line, level of last entry. Memory stays O(watched files), not
  O(file size).
- **Log rotation must not blind the watcher**: if the inode changes or the
  size shrinks below the stored offset (logrotate moved/truncated the file),
  reopen and restart from the beginning of the new file.
- Tolerate a torn final line (writer mid-append): only judge complete,
  newline-terminated lines.
- File handles are opened per poll and closed after, so a held descriptor
  never pins a rotated 2 GB file on disk.

## Process model

- One supervisor process: loads config, parses `/etc/cron.d`, owns the
  schedule, spawns/reaps per-log watchers.
- Service-log watchers run for the supervisor's lifetime; cron-log watchers
  exist only inside their job's window (see kill-self guarantee above).
- hxcpp supports `sys.thread.Thread` — threads inside the one process are
  the simpler first choice; child processes only if isolation proves
  necessary.

## Edge cases to handle

- Log file absent at activation time (job not started yet, or logs elsewhere):
  retry until the quiet period expires, then record a miss.
- Job overruns its expected window: the watcher follows the log, not the
  clock — it stays alive while lines keep arriving.
- Entries that match none of the `info`/`warn`/`error` prefixes (stack
  traces, multi-line output): treat as continuation of the previous entry's
  level.
- Watcher restarts mid-window: on startup, if a cron job's window is
  currently open, start its watcher immediately instead of waiting for the
  next activation.

## In scope

- Monitoring 10 `.log` files of ~2 GB each within the constraints above.
- Parsing/reading `/etc/cron.d` to drive "alive only when needed".

## Out of scope

- Any form of alerting mechanism (per README).
- Other schedule sources (`crontab -l` of users, systemd timers) — only
  `/etc/cron.d` for now.
- Remote/aggregated logs; everything is local files.

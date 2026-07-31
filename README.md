## Log Watcher

Applications / services or a process bump logs with prefix such as 'info', 'warn' and 'error'.
These logs resides in path such as

```bash
ls /var/log/file.log
```

Log watcher reads the tail of log files in short periods.
If the last log is of type 'error' and no other log entries exits, then it needs to be alerted.

## Tech stack

- Haxe transpiling to C++.

## Build, test, run

```bash
haxe build.hxml                              # native binary -> bin/Main
haxe test.hxml                               # test suite (interpreter, fast)
haxe test-native.hxml && ./bin/test/TestMain # same suite, native
./test/demo.sh                               # end-to-end demo (~2.5 min)

./bin/Main watch /var/log/file.log           # watch one log continuously
./bin/Main run /etc/cron.d                   # supervisor: cron-driven watches
```

## Deployment

The watcher only needs **read** access: to the cron.d directory and to the
watched log files (on Debian/Ubuntu, membership in the `adm` group typically
covers `/var/log`). It never writes to or executes anything from cron
entries; detections go to stdout.

## Documentation

Current as-built facts — feature documentation, mermaid diagrams, and the
repository file tree — live in [doc/](doc/).

## Plan

Design documents, in order — later plans supersede earlier ones where noted:

1. [Toolchain and development environment](plan/01.md) — Haxe → C++ pipeline, system requirements, setup and verification.
2. [What gets monitored](plan/02-what-gets-monitored.md) — watcher lifecycles for service vs cron logs, scale constraints (10 × 2 GB), kill-self guarantee.
3. [Cron parser](plan/03-cron-parser.md) — parsing `/etc/cron.d` to generate watcher config from each entry's log redirection.
4. [Implementation phases](plan/04-implementation-phases.md) — ordered roadmap from design to working watcher, with per-phase verification.
5. [Flock-aware watching](plan/05-flock-aware-watching.md) — flock-wrapped cron entries also yield their lock file; a window whose lock is still held at fire time is skipped.

Per-feature design docs live in [plan/feature-doc/](plan/feature-doc/), one file per feature — currently the [MCP server spec](plan/feature-doc/mcp-server.md) (cron/log tools over authenticated localhost HTTP; supersedes the embedded-agent plan in `cron-agent.md`) and the [minilog database spec](plan/feature-doc/minilog-db.md) (recent log tails loaded into a temporary sqlite DB for SQL analysis).

## out of scope

- any form of alerting mechanism.

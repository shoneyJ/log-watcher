# Log Watcher

One small native binary that catches the failure classic monitoring misses:
**a service or cron job that died with an error as its last words.** No
metrics endpoint, no exporter, no agent framework — it reads the tails of
the log files you already have.

## Why a devops team installs this

- **Detects silent deaths.** The rule: last log entry is `error` and
  nothing follows for a quiet period → the process stalled or crashed
  after failing. Measured detection latency on a live box: ~11 seconds
  after the last write.
- **Zero operational surface.** One statically-self-contained binary
  (~3 MB, libc/libstdc++ only — sqlite compiled in), no language runtime,
  no database server, no agents to babysit. Runs as an unprivileged
  system user in hardened systemd units, **read-only toward your system**:
  it never writes to, executes, or modifies anything it monitors.
- **Zero config for cron jobs.** It parses `/etc/cron.d` and derives what
  to watch from each entry's own `>> /var/log/x.log` redirection — new
  cron jobs are picked up on the next rescan, nothing to register. Cron
  logs are watched *only during their firing windows*; `flock`-guarded
  jobs are probed so overlapping runs don't false-alarm.
- **An incident trail you can `cat`.** Every detection appends one
  timestamped JSON line — path, event, the actual final error message —
  to a local JSONL file. Error events only, no noise. On-call triage
  starts with `tail /var/lib/log-watcher/detections.jsonl`.
- **LLM-assisted debugging built in.** A localhost-only, Bearer-token MCP
  API exposes six tools (which cron jobs run right now, list/tail/search
  logs, load recent tails into a temporary in-memory sqlite DB and query
  it with SQL). Developers SSH-tunnel in and ask Claude Code — or any MCP
  client — "is anything failing?", "count errors per level in the last
  100 MB", "tail the inventory service log".
- **Sane on big logs.** Every read is a bounded tail chunk (64 KiB;
  search capped at the last 4 MiB) — designed for 10 × 2 GB logs; a poll
  never scans a file front to back, and rotation (rename or truncate) is
  detected via inode/size.
- **Log-format tolerant.** Levels are read from `info`/`warn`/`error`
  prefixes or from timestamped app-log lines
  (`2026-07-22T15:40:00 - error: …`); ANSI color codes are handled.

Deliberately **not** in the box: notification delivery (no Slack/mail —
the JSONL file and journal are the interface; ship them with whatever
you already use), self-healing/restarts, metrics. Detection only.

## Tech stack

- Haxe transpiled to C++ (hxcpp) into a native Linux binary; zero
  runtime dependencies beyond libc/libstdc++, zero build dependencies
  beyond Haxe 4.3 + g++ (+ `just` for the recipes).

## Build, test, run

Recipes run with [`just`](https://github.com/casey/just) (`sudo apt install just`);
`just --list` shows the menu. The underlying hxml files work directly too.

```bash
just             # release build -> bin/Main        (haxe build.hxml)
just debug       # same with -debug symbols
just portable    # static libstdc++/libgcc for mixed-distro fleets
just test        # test suite, interpreter (fast)   (haxe test.hxml)
just test-native # same suite compiled native
just demo        # end-to-end demo (~2.5 min)
just package     # versioned tar.gz in .releases/ (binary + deploy/ + install guide)
just install     # -> /usr/local/bin/log-watcher; sudo-prompts for the copy only (just install /opt to relocate)
just cross-build # target-distro binary via container (deploy/Containerfile.rocky9)
just setup       # server setup: binary + user + /opt/log-watcher config + systemd units
just enable      # start both services (refuses while the API key is the sample)
just verify      # unit status + authenticated MCP ping
just uninstall   # remove services + binary; config/user kept (append `purge` for full wipe)
just clean       # drop bin/

./bin/Main watch /var/log/file.log           # watch one log continuously
./bin/Main run /etc/cron.d                   # supervisor: cron-driven watches
./bin/Main mcp /etc/cron.d config.json       # MCP server: cron/log tools over HTTP
```

## Install on a server

Full guide for system admins: **[doc/install.md](doc/install.md)** —
system requirements, build, systemd setup, and how developers then use
the MCP tools for day-to-day debugging and on-call (SSH tunnel +
Claude Code or any MCP client).

Short version:

```bash
git clone https://github.com/shoneyJ/log-watcher.git && cd log-watcher
haxelib newrepo && haxelib install hxcpp
just && just setup            # build; then binary + user + /opt/log-watcher config + units
sudoedit /opt/log-watcher/config.json   # services, logs
sudoedit /opt/log-watcher/.env          # LOG_WATCHER_API_KEY
just enable && just verify
```

Samples live in [deploy/](deploy/): `config.sample.json`,
`.env.example` (the MCP API key), and the two systemd units.

**System requirements (runtime):** Linux x86_64 with glibc/libstdc++,
`flock` + `pgrep` in PATH, read access to `/etc/cron.d` and the logs —
no language runtime, no database packages (sqlite is compiled in).
Building needs Haxe 4.3.x + g++ (see the guide).

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

Per-feature design docs live in [plan/feature-doc/](plan/feature-doc/), one file per feature — currently the [MCP server spec](plan/feature-doc/mcp-server.md) (cron/log tools over authenticated localhost HTTP; supersedes the embedded-agent plan in `cron-agent.md`), the [minilog database spec](plan/feature-doc/minilog-db.md) (recent log tails loaded into a temporary sqlite DB for SQL analysis), the [production concurrency spec](plan/feature-doc/prod-concurrency.md) (worker pool + content-keyed DB cache for ~20 concurrent users — approved, not yet built), and the [service health spec](plan/feature-doc/service-health.md) (the supervisor records error-final detections in a JSONL file Sheriffs can `cat`; the check_health MCP tool is deferred — implemented).

## out of scope

- any form of alerting mechanism.

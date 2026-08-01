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

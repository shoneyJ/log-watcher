# Log Watcher

One small native binary that catches the failure classic monitoring misses:
**a service or cron job that died with an error as its last words.** No
metrics endpoint, no exporter, no agent framework — it reads the tails of
the log files you already have.

## Key Features

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
  it with SQL). Anyone running services or cron jobs on a Linux box can
  SSH-tunnel in and ask Claude Code — or any MCP client — "is anything
  failing?", "which cron jobs are running right now?", "count errors per
  level across the last 100 MB of any watched log".
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
entries; detections go to stdout and, when configured, the JSONL
detections file.

## Configuring and Running the MCP Server

One config file drives both services (`/opt/log-watcher/config.json`;
sample: [deploy/config.sample.json](deploy/config.sample.json)):

```json
{
  "services":   ["/var/log/myservice/app.log"],
  "logs":       ["/var/log/postgresql/postgresql-16-main.log"],
  "detections": "/var/lib/log-watcher/detections.jsonl",
  "mcp":        { "port": 8990 }
}
```

- `services` — logs watched continuously; `logs` — extra logs queryable
  over MCP only. The MCP allowlist = cron.d-derived logs ∪ both lists;
  nothing outside it is reachable through the API.
- The API key lives in `/opt/log-watcher/.env`
  (`LOG_WATCHER_API_KEY=$(openssl rand -hex 32)`, root:log-watcher 640),
  loaded by the systemd unit — the config file stays world-readable.

Run it:

```bash
sudo systemctl enable --now log-watcher-mcp     # or: just enable (both units)
# ad hoc, without systemd:
LOG_WATCHER_API_KEY=... log-watcher mcp /etc/cron.d /opt/log-watcher/config.json
```

The server binds **127.0.0.1 only**; every request needs
`Authorization: Bearer <key>`. From a workstation, tunnel and attach any
MCP client:

```bash
ssh -N -L 8990:127.0.0.1:8990 your-server &
claude mcp add --transport http cron-mcp http://127.0.0.1:8990/mcp \
  --header "Authorization: Bearer <key>"
```

Tools: `get_running_crons`, `list_logs`, `tail_log`, `search_log`,
`load_log_db`, `query_log_db`. Full protocol and config reference:
[doc/install.md](doc/install.md), [plan/feature-doc/mcp-server.md](plan/feature-doc/mcp-server.md).

## Documentation

As-built documentation (`doc/` — always describes what exists now):

- [doc/README.md](doc/README.md) — project facts + index
- [doc/features.md](doc/features.md) — feature documentation per module
- [doc/diagrams.md](doc/diagrams.md) — mermaid diagrams
- [doc/file-tree.md](doc/file-tree.md) — annotated repository file tree
- [doc/install.md](doc/install.md) — server installation guide (requirements, systemd, Rocky/RHEL, cross-building)
- [doc/server-testing.md](doc/server-testing.md) — live-server validation guide
- [CLAUDE.md](CLAUDE.md) — contributor/agent instructions and repo conventions

Design history (`plan/` — read in order, later docs supersede earlier where noted):

- [plan/01.md](plan/01.md) — toolchain and environment
- [plan/02-what-gets-monitored.md](plan/02-what-gets-monitored.md) — watcher lifecycles, scale constraints
- [plan/03-cron-parser.md](plan/03-cron-parser.md) — cron.d parsing → watcher config
- [plan/04-implementation-phases.md](plan/04-implementation-phases.md) — phased roadmap (complete)
- [plan/05-flock-aware-watching.md](plan/05-flock-aware-watching.md) — flock probe + skip-locked windows
- [plan/06-mcp-server-implementation.md](plan/06-mcp-server-implementation.md) — task-by-task MCP implementation plan

Per-feature design docs (`plan/feature-doc/`, one file per feature):

- [mcp-server.md](plan/feature-doc/mcp-server.md) — MCP server over authenticated localhost HTTP (implemented)
- [minilog-db.md](plan/feature-doc/minilog-db.md) — temporary in-memory sqlite over recent log tails (implemented)
- [service-health.md](plan/feature-doc/service-health.md) — error-only JSONL detections file (implemented)
- [prod-concurrency.md](plan/feature-doc/prod-concurrency.md) — worker pool + keyed DB cache for ~20 users (approved, not built)
- [cron-agent.md](plan/feature-doc/cron-agent.md) — embedded LLM agent loop (superseded by mcp-server.md)

# Repository file tree

Annotated tree of the working repo. Directories marked *(gitignored)* exist
locally but are not committed.

```
log-watcher/
├── README.md                        what it does, build/test/run, deployment
├── CLAUDE.md                        contributor/agent instructions, repo conventions
├── justfile                         entry point: release/debug/test/package/install
├── build.hxml                       native build: src/ → generated C++ → bin/Main
├── test.hxml                        test suite on the Haxe interpreter (fast)
├── test-native.hxml                 same suite compiled native → bin/test/TestMain
├── .gitignore
├── doc/                             as-built facts (this folder)
│   ├── README.md                    project facts + index
│   ├── features.md                  feature documentation per module
│   ├── diagrams.md                  mermaid diagrams
│   ├── file-tree.md                 this tree
│   ├── install.md                   server installation guide (sysadmin + developer usage)
│   └── server-testing.md            live-server validation guide
├── .dockerignore                    keeps container build context small (.haxelib rides along)
├── deploy/                          server installation samples
│   ├── config.sample.json           documented config (supervisor + mcp + logs)
│   ├── .env.example                 LOG_WATCHER_API_KEY for the MCP unit
│   ├── log-watcher.service          systemd unit: supervisor
│   ├── log-watcher-mcp.service      systemd unit: MCP server (EnvironmentFile=.env)
│   └── Containerfile.rocky9         cross-build: binary linked against Rocky 9 glibc
├── plan/                            design history — read in order, later plans
│   │                                supersede earlier ones where noted
│   ├── 01.md                        toolchain: Haxe → C++ (hxcpp), env setup
│   ├── 02-what-gets-monitored.md    lifecycles, 10 × 2 GB constraints, kill-self
│   ├── 03-cron-parser.md            cron.d parsing generates watcher config
│   ├── 04-implementation-phases.md  five phases, all complete
│   ├── 05-flock-aware-watching.md   flock note + skip-locked windows
│   ├── 06-mcp-server-implementation.md  task-by-task plan for the MCP specs
│   └── feature-doc/                 per-feature docs, one file per feature
│       ├── cron-agent.md            embedded LLM agent — superseded by mcp-server.md
│       ├── mcp-server.md            MCP server design spec (tools over authed HTTP)
│       ├── minilog-db.md            temp sqlite DB of recent log tails (extends MCP)
│       ├── prod-concurrency.md      20-user production: worker pool + keyed DB cache
│       └── service-health.md        supervisor's error-only JSONL detections for Sheriffs
├── src/
│   ├── Main.hx                      CLI entry: `watch`, `run`, `mcp`
│   ├── LogTail.hx                   chunked tail reader + line classification
│   ├── Watcher.hx                   per-log alert state machine (service/cron)
│   ├── Cron.hx                      read-only cron.d parser + nextFire()
│   ├── Flock.hx                     held(): flock(1) lock probe
│   ├── Supervisor.hx                single-threaded event loop
│   ├── Util.hx                      say(): println + flush
│   ├── Mcp.hx                       MCP/JSON-RPC envelope + HTTP serve loop
│   ├── Tools.hx                     MCP tool layer: allowlist, crons, tail/search
│   ├── MiniLog.hx                   single-slot :memory: sqlite log DB (load/query)
│   └── Pgrep.hx                     alive(): pgrep -f liveness probe
├── test/
│   ├── TestMain.hx                  zero-dependency plain-assert suite
│   ├── produce-log.sh               deterministic fake log producer
│   ├── demo.sh                      end-to-end demo (~2.5 min)
│   ├── demo-config.json             supervisor config used by the demo
│   ├── mcp-config.json              MCP server demo config (port 8990)
│   ├── fixtures/
│   │   └── cron.d/                  committed parser fixtures
│   │       ├── log-producer         two watchable entries (healthy/failing)
│   │       └── edge-cases           malformed + non-watchable variants
│   ├── live/                        (gitignored) logs written by demo/live cron
│   └── tmp/                         (gitignored) test-suite scratch files
├── .dev/                            (gitignored except README.md) dev-local
│   │                                AI-tooling symlinks + commit.md
│   └── README.md                    how to recreate the links per machine
├── .claude/                         local Claude Code settings (settings.local.json,
│                                    gitignored)
├── .haxelib/                        (gitignored) project-local haxelib repo (hxcpp)
├── .releases/                       (gitignored) versioned archives from `just package`
└── bin/                             (gitignored) generated C++, objects, binaries
```

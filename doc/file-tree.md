# Repository file tree

Annotated tree of the working repo. Directories marked *(gitignored)* exist
locally but are not committed.

```
log-watcher/
├── README.md                        what it does, build/test/run, deployment
├── CLAUDE.md                        contributor/agent instructions, repo conventions
├── build.hxml                       native build: src/ → generated C++ → bin/Main
├── test.hxml                        test suite on the Haxe interpreter (fast)
├── test-native.hxml                 same suite compiled native → bin/test/TestMain
├── .gitignore
├── doc/                             as-built facts (this folder)
│   ├── README.md                    project facts + index
│   ├── features.md                  feature documentation per module
│   ├── diagrams.md                  mermaid diagrams
│   ├── file-tree.md                 this tree
│   └── server-testing.md            live-server validation guide
├── plan/                            design history — read in order, later plans
│   │                                supersede earlier ones where noted
│   ├── 01.md                        toolchain: Haxe → C++ (hxcpp), env setup
│   ├── 02-what-gets-monitored.md    lifecycles, 10 × 2 GB constraints, kill-self
│   ├── 03-cron-parser.md            cron.d parsing generates watcher config
│   ├── 04-implementation-phases.md  five phases, all complete
│   ├── 05-flock-aware-watching.md   flock note + skip-locked windows
│   └── feature-doc/                 per-feature docs, one file per feature
│       ├── cron-agent.md            embedded LLM agent — superseded by mcp-server.md
│       ├── mcp-server.md            MCP server design spec (tools over authed HTTP)
│       └── minilog-db.md            temp sqlite DB of recent log tails (extends MCP)
├── src/
│   ├── Main.hx                      CLI entry: `watch` and `run`
│   ├── LogTail.hx                   chunked tail reader + line classification
│   ├── Watcher.hx                   per-log alert state machine (service/cron)
│   ├── Cron.hx                      read-only cron.d parser + nextFire()
│   ├── Flock.hx                     held(): flock(1) lock probe
│   ├── Supervisor.hx                single-threaded event loop
│   └── Util.hx                      say(): println + flush
├── test/
│   ├── TestMain.hx                  zero-dependency plain-assert suite
│   ├── produce-log.sh               deterministic fake log producer
│   ├── demo.sh                      end-to-end demo (~2.5 min)
│   ├── demo-config.json             supervisor config used by the demo
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
└── bin/                             (gitignored) generated C++, objects, binaries
```

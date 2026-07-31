# Documentation

Current, as-built facts about log-watcher. Unlike `plan/` (design history,
read in supersession order), this folder always describes what exists now —
update it in the same change as the code.

- [features.md](features.md) — feature documentation per module
- [diagrams.md](diagrams.md) — mermaid diagrams (components, lifecycles, tick loop)
- [file-tree.md](file-tree.md) — annotated repository file tree
- [server-testing.md](server-testing.md) — hands-on validation on a real server with live cron

## Project facts

- **What it does**: tails configured log files in short periods and flags a
  log whose last complete entry is `error` with nothing after it for a quiet
  period. Detection only — any alerting mechanism is out of scope. All
  detections go to stdout.
- **Tech stack**: Haxe 4.3.x transpiled to C++ via hxcpp into a native
  binary (`bin/Main`). Zero dependencies at runtime (libc/libstdc++ only)
  and zero haxelib dependencies beyond hxcpp (build only).
- **Log format assumption**: entries are prefixed `info` / `warn` / `error`;
  unprefixed lines (stack traces, wrapped output) are continuations that
  inherit the previous entry's level.
- **Two watch lifecycles**:
  - *Service logs* — watched continuously for the watcher's lifetime.
  - *Cron logs* — "alive only when needed": a watch activates at the cron
    entry's next fire time, ends after a quiet period, and is then dropped
    entirely (kill-self guarantee).
- **Zero hand-written cron config**: the supervisor parses a cron.d-format
  directory (a parameter, `/etc/cron.d` in production) and derives each
  watch's log path from the entry's own output redirection.
- **Flock-aware**: a `flock`-wrapped cron command also yields its lock
  file; the supervisor probes it shortly before each fire and skips the
  window (`SKIP-LOCKED`) when the lock is still held — a previous run is
  still going, so this fire won't produce output. Ambiguous probes
  (unreadable lock, no flock binary) fall back to watching normally.
- **Scale target**: 10 logs × ~2 GB. Every poll reads at most a 64 KiB tail
  chunk — never a full scan. Rotation is detected via inode change or size
  shrink; file handles live only inside a single poll call.
- **Defaults**: poll interval 2 s, quiet period 10 s, cron.d rescan 60 s;
  the supervisor loop ticks every 0.25 s.
- **Deployment**: read access only — to the cron.d directory, the watched
  logs (on Debian/Ubuntu the `adm` group typically covers `/var/log`), and
  ideally the flock lock files; the lock probe also needs util-linux
  `flock` in `PATH`. The watcher never writes to or executes anything found
  in cron entries.
- **CLI**:
  - `./bin/Main watch <logfile> [quietPeriod] [pollInterval]` — one continuous watch
  - `./bin/Main run <cron.d-dir> [config.json]` — supervisor (cron + services)
- **Build / test / demo**: `haxe build.hxml` (native binary),
  `haxe test.hxml` (suite on the interpreter),
  `haxe test-native.hxml && ./bin/test/TestMain` (same suite native),
  `./test/demo.sh` (end-to-end, ~2.5 min).
- **Status**: all five implementation phases of `plan/04` are complete.

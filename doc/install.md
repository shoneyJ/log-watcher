# Server installation guide

For system admins installing log-watcher on a server so developers can
use it for day-to-day debugging and on-call duties. Everything below
assumes Ubuntu 24.04 / Debian 12; for Rocky Linux / RHEL-family
machines see [Other distributions](#other-distributions--rocky-linux--rhel-family)
at the end.

Repository: <https://github.com/shoneyJ/log-watcher>

## System requirements

**Runtime** (the deployed binary):

- Linux x86_64, glibc + libstdc++ (standard on any Debian/Ubuntu/RHEL
  base) — the binary is native and self-contained, no runtime language
  or framework.
- `flock` (util-linux) and `pgrep` (procps) in `PATH` — present on
  every stock distro; used read-only for lock/process probes.
- Read access to `/etc/cron.d` and to the watched log files (on
  Debian/Ubuntu the `adm` group typically covers `/var/log`).
- Memory: the supervisor stays in a few MB; the MCP server peaks at
  roughly 100–150 MB while a minilog database is loaded (bounded by
  design). Disk: the binary (~5 MB); nothing is written at runtime.
- One free localhost TCP port for the MCP server (default 8990). The
  server binds 127.0.0.1 only — it is never reachable from the network.

**Build** (only on the machine that compiles it; the server itself
never needs a toolchain if you copy the binary over):

- Haxe 4.3.x + neko (`sudo apt install haxe`), g++, and
  [`just`](https://github.com/casey/just) (`sudo apt install just`) for
  the build recipes — the raw `haxe *.hxml` commands work without it.
- hxcpp via `haxelib newrepo && haxelib install hxcpp` from the repo
  root (project-local, no global state). sqlite is bundled statically
  by hxcpp — no external database packages.

## Install

```bash
# 1. Build (on the server, or a build box with same-or-older glibc — see
#    "Other distributions" below for the glibc caveat and Rocky Linux steps)
git clone https://github.com/shoneyJ/log-watcher.git
cd log-watcher
haxelib newrepo && haxelib install hxcpp
just                               # release build -> bin/Main
just test-native                   # optional: suite must be green

# 2. Binary — the recipe elevates only the copy itself (sudo prompt),
#    so the build tree never becomes root-owned. Don't run `sudo just`.
just install                       # -> /usr/local/bin/log-watcher (`just install /opt` to relocate)

# 3. User + config + units, in one go (each step also exists as its own
#    recipe: setup-user / setup-config / setup-units; nothing is started
#    yet, and existing config/.env are never overwritten)
just setup

# 4. Edit the config and set a real key
sudoedit /opt/log-watcher/config.json   # services (watched) + logs (MCP-queryable)
sudoedit /opt/log-watcher/.env          # LOG_WATCHER_API_KEY=$(openssl rand -hex 32)

# 5. Start (refuses while the key is still the sample value)
just enable

# 6. Verify: unit status + authenticated MCP ping on the configured port
just verify                             # -> {"jsonrpc":"2.0","id":1,"result":{}}
journalctl -u log-watcher -n 20         # SCHEDULE lines for watchable cron entries
```

The recipes wrap exactly the commands you'd type (user creation, copies
into `/opt/log-watcher/`, `.env` permissions root:log-watcher 640, unit
install + daemon-reload) — read the `justfile` to see or bypass them.

**Machine-local overrides**: gitignored `deploy/*.local.*` files win
during setup — `config.local.json` and `.env.local` are synced to
`/opt/log-watcher/` on every `just setup-config` (samples only fill
gaps and never overwrite), and a `deploy/<unit>.local.service` is
installed instead of the stock unit by `just setup-units` (e.g. to
relax `ProtectHome` when a queryable log lives under `/home`). Keep
machine specifics there instead of editing tracked files.

**Uninstall**: `just uninstall` stops and removes the services and the
binary but keeps `/opt/log-watcher/` (your config + key) and the
service user; `just uninstall /usr/local purge` wipes those too.

The two services are independent — run either alone: `log-watcher`
(detection to the journal) without the MCP server, or `log-watcher-mcp`
(developer tooling) without continuous watching.

**Build box → server without a toolchain on the server**: on the build
box run `just package` — it produces
`.releases/log-watcher-build-<git-hash>-<date>.tar.gz` containing the
binary (as `log-watcher`), the `deploy/` samples, the `justfile`, and
this guide. `scp` it over, unpack, `sudo cp log-watcher
/usr/local/bin/`, then continue from step 3 (`just setup` works from
the unpacked directory if `just` is installed; otherwise the wrapped
commands are in the justfile to copy by hand).

## Configuration reference

`/opt/log-watcher/config.json` (all keys optional except `mcp.port`
for the MCP unit):

| Key | Default | Meaning |
| --- | --- | --- |
| `pollInterval` | 2 | seconds between tail polls |
| `quietPeriod` | 10 | silence window for "job done" / "error is final" |
| `rescanInterval` | 60 | seconds between cron.d rescans (mtime-gated) |
| `services` | `[]` | log paths watched continuously (string or `{"path": …}`) |
| `logs` | `[]` | extra log paths queryable over MCP (not watched) |
| `detections` | — | JSONL file for error events (Sheriff's `cat`-able incident trail; unit provides `/var/lib/log-watcher/` via StateDirectory) |
| `mcp.port` | — | MCP listen port on 127.0.0.1 (required for `mcp`) |
| `mcp.apiKey` | — | Bearer token; prefer `LOG_WATCHER_API_KEY` in `.env` instead |

The MCP log allowlist = logs derived from `/etc/cron.d` redirections ∪
`logs` ∪ `services`. Nothing outside it is readable through the API.

## Developer usage (debugging & on-call)

The MCP port is localhost-only on the server. From your machine, open
an SSH tunnel, then attach any MCP client:

```bash
ssh -N -L 8990:127.0.0.1:8990 your-server &

claude mcp add --transport http cron-mcp http://127.0.0.1:8990/mcp \
  --header "Authorization: Bearer <the key from /opt/log-watcher/.env>"
```

Then in Claude Code, ask things like:

- "Which cron jobs are running right now?" → `get_running_crons`
  (schedules, next fire, flock/pgrep liveness).
- "Tail the postgres log" → `list_logs` + `tail_log`.
- "Find 'timeout' in the app log" → `search_log` (last 4 MiB,
  newest first).
- "Load the failing job's log into the database and count errors per
  level" → `load_log_db` + `query_log_db` (read-only SQL over the last
  ~100 MB of the matched logs — counts, grouping, slicing).

Raw curl works too — the endpoint is plain JSON-RPC 2.0 over HTTP (see
`plan/feature-doc/mcp-server.md` for the protocol subset).

On-call flow that works well: tunnel in, `load_log_db` with a hint
matching the paging service, `query_log_db` for error counts by level,
then `tail_log` the specific log the counts point at.

## Security notes

- The binary is read-only toward the system: it never writes to,
  executes, or modifies anything found in cron entries or logs; the
  minilog database lives in memory and dies with the process.
- The API key crosses only localhost and the SSH tunnel. For anything
  fancier (TLS, LAN exposure), put a reverse proxy in front — that is
  deliberately not this binary's job.
- `.env` is root:log-watcher 640; the config file itself can stay
  world-readable since the key lives in `.env`.
- The systemd units run as an unprivileged system user with
  `ProtectSystem=strict` — the process cannot write anywhere.

## Other distributions — Rocky Linux / RHEL family

The binary, the systemd units, and the cron.d format are identical
(Rocky's cron daemon is cronie — the same `/etc/cron.d` semantics this
project's parser mimics). What changes is how you get the build
toolchain and how log read-access is granted.

### Build procedure changes

- **Haxe has no RHEL-family package.** `dnf` knows nothing about it;
  install the official Linux tarballs from
  <https://haxe.org/download/> (Haxe 4.3.x) and
  <https://nekovm.org/download/> (neko, needed by `haxelib`):

  ```bash
  sudo dnf install gcc-c++ git tar
  sudo tar -xzf haxe-4.3.*-linux64.tar.gz -C /opt && sudo mv /opt/haxe_* /opt/haxe
  sudo tar -xzf neko-*-linux64.tar.gz     -C /opt && sudo mv /opt/neko-* /opt/neko

  # /etc/profile.d/haxe.sh (or your shell rc)
  export PATH="/opt/haxe:/opt/neko:$PATH"
  export HAXE_STD_PATH="/opt/haxe/std"
  export LD_LIBRARY_PATH="/opt/neko:$LD_LIBRARY_PATH"   # libneko for haxelib
  ```

- **`just` comes from EPEL** (or skip it — the raw commands work):

  ```bash
  sudo dnf install epel-release && sudo dnf install just
  # without just: haxe build.hxml / haxe test.hxml / haxe test-native.hxml
  ```

- Everything else is unchanged: `haxelib newrepo && haxelib install
  hxcpp`, then `just` — hxcpp drives `g++` the same way on any distro,
  and sqlite is still compiled in.

- **Don't build on new-glibc, run on old-glibc.** A binary built on
  Ubuntu 24.04 (glibc 2.39) will not start on Rocky 9 (glibc 2.34) —
  glibc is forward-compatible only. Build on the Rocky machine itself,
  on the oldest-glibc box in the fleet, or cross-build (next section),
  and ship with `just package`. Same-or-older glibc on the build box =
  fine.

### Cross-building for a different distribution

Two options, both verified; pick by how exact the target must be.

**1. `just portable` — one binary for mixed fleets.** Builds with
`-static-libstdc++ -static-libgcc` (the `-D portable` define): the
libstdc++/libgcc version coupling disappears entirely, leaving only
glibc dynamic (`ldd` shows just libm/libc/ld-linux). Combine with a
build box whose glibc is as old as the oldest target and the same
binary runs everywhere newer. Cost: ~1 MB larger binary; no behavior
change (native suite green on the portable build).

**2. Container build — exact distro targeting** (recommended when the
target is known). `deploy/Containerfile.rocky9` compiles inside a
`rockylinux:9` image and exports just the binary:

```bash
# from the repo root; .haxelib/ must be populated (hxcpp rides along —
# no network access inside the container)
docker build -f deploy/Containerfile.rocky9 --target out -o dist/rocky9 .
# -> dist/rocky9/log-watcher, glibc symbol ceiling 2.34 (verified with
#    objdump -T | grep GLIBC) — runs on Rocky/RHEL/Alma 9 and anything newer
```

Swap the `FROM` base image to target other distros (`rockylinux:8`,
`debian:11`, …) — always build against the **oldest** glibc you must
support. `podman build` accepts the same file. The Containerfile fetches
the Haxe/neko tarballs itself (pinned versions) and installs only
`gcc-c++` — the host needs nothing but docker/podman.

Not offered: fully static (musl) builds — glibc-dynamic binaries built
against the oldest target cover the fleet without the musl toolchain
detour, and option 1+2 combined already gives one-binary portability.

### Runtime differences

- Packages: `flock` and `pgrep` are in base `util-linux` /
  `procps-ng` — nothing to install.
- **The Debian `adm`-group trick does not apply.** On RHEL-family
  systems flat log files (rsyslog's `/var/log/messages`, most app logs)
  are typically `root:root 600`, and a stock minimal install may write
  only to the journal — flat files exist only where rsyslog or the
  application creates them. Grant read access per log instead of via
  `SupplementaryGroups=adm`:

  ```bash
  sudo setfacl -m u:log-watcher:r /var/log/myservice/app.log
  sudo setfacl -m d:u:log-watcher:r /var/log/myservice/   # future files too
  ```

  (Or configure rsyslog/the app to group-own its logs and put
  `log-watcher` in that group.) The `SupplementaryGroups=adm` line in
  the units is harmless to keep but does nothing here.
- **SELinux is enforcing by default.** The units run in
  `unconfined_service_t`, which can read `var_log_t` — normally no work
  needed. If a service fails oddly, check
  `ausearch -m avc -ts recent`; a mislabeled binary is fixed with
  `restorecon -v /usr/local/bin/log-watcher`.
- Everything else — service user, `/opt/log-watcher/{config.json,.env}`
  permissions, `systemctl enable --now`, the SSH-tunnel developer flow —
  is identical to the Ubuntu steps above.

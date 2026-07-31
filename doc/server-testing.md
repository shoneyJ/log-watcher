# Testing on a real server

Hands-on validation with real cron firing real jobs — the live counterpart
to `test/demo.sh`. Everything below runs as an unprivileged user except
installing the cron file. Substitute three things throughout: your user
(`dev`), the repo path (`/home/dev/log-watcher`), and keep the log/lock
under `/var/tmp` as written or adjust consistently.

## 1. Prerequisites

- Linux with cron running and util-linux `flock` (`flock --version`).
- Read access to `/etc/cron.d` (world-readable by default) and to the
  watched log paths. `/var/tmp` needs nothing special; real `/var/log`
  service logs typically need the `adm` group on Debian/Ubuntu.
- The binary, via either:
  - **Build on the server** (canonical, plan/01): `sudo apt install haxe
    build-essential`, clone the repo, then from its root
    `haxelib newrepo && haxelib install hxcpp && haxe build.hxml`.
  - **Copy from the dev machine**: `bin/Main` is self-contained (libc/
    libstdc++ only) — `scp bin/Main test/produce-log.sh` to the server;
    the target distro must not be older than the build machine's.

## 2. Sanity checks (2 minutes)

```bash
./bin/Main                                   # prints usage, exits 1
flock -n /var/tmp/lw-flock.lock true; echo $?   # 0 = free (also creates the file)
flock /var/tmp/lw-flock.lock -c 'sleep 30' &
flock -n /var/tmp/lw-flock.lock true; echo $?   # 1 = held — the probe's signal
wait
```

## 3. Install the live cron entry

`/etc/cron.d/lw-flock-test` (no dot in the filename, root-owned, 0644 —
cron ignores it otherwise):

```bash
sudo tee /etc/cron.d/lw-flock-test >/dev/null <<'EOF'
# log-watcher live test — remove after testing (doc/server-testing.md)
MAILTO=""
* * * * * dev flock -n /var/tmp/lw-flock.lock -c "/home/dev/log-watcher/test/produce-log.sh info 8 2 >> /var/tmp/lw-flock.log 2>&1"
EOF
sudo chmod 644 /etc/cron.d/lw-flock-test
```

Why this shape: every-minute schedule keeps iterations short; the job
writes 8 lines over ~16 s (well inside the 10 s default quiet period
between lines, well clear of the next fire); `flock -n` makes a locked-out
instance exit silently, which is exactly the situation `SKIP-LOCKED`
models; `MAILTO=""` suppresses cron mail from those exits.

## 4. Run the supervisor

```bash
cd /home/dev/log-watcher
./bin/Main run /etc/cron.d | tee /var/tmp/lw-supervisor.out
```

Expect immediately: `SKIP` lines for the server's non-watchable stock
entries (pipes, no redirect — normal), `SCHEDULE` lines for watchable
ones, and the line under test:

```
SCHEDULE /var/tmp/lw-flock.log: * * * * * (flock /var/tmp/lw-flock.lock)
```

Pointing at the real `/etc/cron.d` is the full end-to-end test (discovery,
rescans, other entries — all read-only). For noise-free output instead,
copy `lw-flock-test` into an empty directory and `run` that; real cron
still fires the `/etc/cron.d` copy, and parsing is independent of who
fires the job.

## 5. Healthy cycle — expected output

Each minute boundary M:

```
M+0s   WATCH /var/tmp/lw-flock.log: activated
M+~26s DONE /var/tmp/lw-flock.log: ok
```

(Job writes until ~M+16 s, quiet period 10 s, then completion. The probe
at M−2 s is silent when the lock is free.)

## 6. Trigger SKIP-LOCKED — the core test

A job's own lock is released while its watch is still active, so a normal
short job never shows `SKIP-LOCKED`. Simulate a wedged previous run by
holding the lock from a second terminal:

```bash
flock /var/tmp/lw-flock.lock -c 'echo held — Ctrl-C to release; sleep 3600'
```

While held, every minute:

```
SKIP-LOCKED /var/tmp/lw-flock.log: /var/tmp/lw-flock.lock still held, window skipped
```

— no `WATCH`, no watcher, and crucially no false
`DONE …: missed` (which is what every one of these windows would have
produced before flock awareness). Cron's own instances die instantly on
`flock -n`. Press Ctrl-C in the holder terminal: the next window goes
back to `WATCH … DONE … ok`.

## 7. Error-final alert

```bash
sudo sed -i 's/info 8 2/error 8 2/' /etc/cron.d/lw-flock-test
```

The 60 s rescan picks up the change (same schedule/log/lock, so no new
`SCHEDULE` line). From the next window:

```
DONE /var/tmp/lw-flock.log: ERROR-final
ALERT /var/tmp/lw-flock.log: cron job finished with error as the last entry
```

`error`-final runs append two indented continuation lines — inherited as
`error`, per the continuation rule. Revert with `sed -i 's/error 8 2/info
8 2/'` and the next window is `ok` again.

## 8. Optional: safe-fallback and discovery checks

- **Unreadable lock (safe direction)**: `sudo chown root:root
  /var/tmp/lw-flock.lock && sudo chmod 600 /var/tmp/lw-flock.lock`. The
  probe can't open it (flock exit 66) → reports "free" → windows are
  **watched, never skipped**; one `flock: cannot open lock file` stderr
  line appears ~2 s before each fire. Note the job itself now also can't
  open its lock, so windows complete as `missed` — expected in this
  contrived state. Restore: `rm -f /var/tmp/lw-flock.lock` (recreated by
  the next job run).
- **Discovery**: install the cron file while the supervisor is already
  running — its `SCHEDULE` line appears within one 60 s rescan, no
  restart. Removal cancels the pending activation silently (no log line);
  an in-flight watch finishes its window.

## 9. Cleanup

```bash
sudo rm /etc/cron.d/lw-flock-test
# Ctrl-C the supervisor
rm -f /var/tmp/lw-flock.lock /var/tmp/lw-flock.log /var/tmp/lw-supervisor.out
```

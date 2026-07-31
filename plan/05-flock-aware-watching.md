# Flock-aware watching

## Objective

Production cron entries commonly guard a job with util-linux `flock` so
overlapping runs can't stampede, e.g. (the committed fixture
`test/fixtures/cron.d/edge-cases`, last entry):

```
*/20 * * * * root flock -w 600 /var/run/test.lock -c "cd /data/scripts; bash /data/scripts/test.sh >> /var/log/test.log 2>&1"
```

The parser already distills such an entry to its essentials — schedule
`*/20 * * * *` and log `/var/log/test.log` (the redirection regex matches
inside the quoted `-c` string). This plan adds the third essential: **note
the flock lock file**, and use it — when the lock is still held as a window
opens, the previous run is still going and the new fire will not produce
output, so that window is not watched at all (no false "missed"
completions, no watcher burning polls on a log that won't move).

> Extends `03-cron-parser.md`: the parser extracts a sixth field, the flock
> lock path, from watchable commands.

## Lock extraction (parser)

A command notes a lock file iff its first token is `flock` or ends with
`/flock`; the lock path is the first following token starting with `/`,
scanning stops at `-c`. No flock option takes an absolute-path value, so
option arguments like `-w 600` are skipped naturally. Un-flocked commands
get `lockPath = null` and behave exactly as before.

Out of scope: `flock` appearing after shell prefixes (`cd x && flock …`),
relative lock paths, and the `flock <fd>` form — the degenerate outcome is
always `lockPath = null` or a probe that reports "free", i.e. the watch
runs as it did before this plan.

## The probe

`Flock.held(path)` shells out to util-linux flock, the same
`flock(LOCK_EX|LOCK_NB)` idiom cronie uses for its own pid file
(reference: `.dev/reference/cronie/src/misc.c`):

```
held(path) = FileSystem.exists(path) && Sys.command("flock", ["-n", path, "true"]) == 1
```

Exit codes (verified against util-linux 2.39.3):

| outcome | exit | meaning |
| --- | --- | --- |
| lock acquired and released | 0 | free |
| `-n` conflict | 1 | **held** |
| lock file unreadable | 66 | unknown |
| no flock binary in PATH | 127 | unknown |

Only exit 1 means held. **Every ambiguous outcome reports "free"**, so the
supervisor falls back to watching normally — the safe failure direction: a
wrong "free" wastes one watch window; a wrong "held" silently skips
detection forever. The `exists()` guard is load-bearing: `flock -n` would
`O_CREAT` a missing lock file, breaking the watcher's read-only stance (and
a missing file means nobody holds it anyway).

## Probe before the fire, not at it

Cron fires on the minute; the job's own flock grabs the lock within
milliseconds. The supervisor activates on its first tick past `nextFire`
(up to 0.25 s later), so probing **at** activation would usually see the
job's own lock and wrongly skip every window. Instead:

- Within `PROBE_LEAD` (2 s) **before** `nextFire`, the tick probes once and
  stores the result on the watch (`lockProbe`).
- At activation, `lockProbe == true` → `SKIP-LOCKED` is reported, the next
  fire is recomputed, and no watcher is created. Otherwise the watch runs
  as before. Both paths reset the probe for the next window.
- No probe taken (supervisor started after the fire passed) → the watch
  runs — pre-plan behavior, safe direction again.
- A free-lock probe holds the lock only for the duration of `true` (~ms),
  two seconds before the job's own attempt — no interference.

Composition rules:

- Same-log entries collapse into one watch (plan 03); the collapsed
  `lockPath` is kept only when **every** entry for that log agrees on it.
  Any disagreement — different locks, or one entry un-flocked — clears it
  to null (always watch): a lock guarding only one of several writers must
  not suppress watching the others.
- Rescans are mtime-gated and leave the schedule untouched when nothing
  changed, so probe state survives; a real cron.d change rebuilds the map
  and at worst one window falls back to watching.
- The mid-window startup path is untouched: a held lock there means the
  job is *currently producing* the log, which is exactly what to watch.

## Accepted tradeoff

`flock -w 600` means a locked-out job may still run up to 10 minutes late
once the previous holder releases. A skipped window is deliberately not
watched until the next scheduled fire — the rule is "locked at fire time →
that window is nobody's to watch", chosen for simplicity over tracking
late starts.

## Deployment note

The probe needs `flock` (util-linux) in `PATH` and read access to existing
lock files. Where either is missing — or the lock file is root-only, as
`/var/run` locks often are — the probe reports "free" (one stderr line
from flock per window in the unreadable case) and the watcher behaves
exactly as it did before this plan.

## Testing

All deterministic, no sleeps, both targets (interp + native):

- Parser: fixture entry yields schedule `*/20 * * * *`, log
  `/var/log/test.log`, lock `/var/run/test.lock`; un-flocked entries yield
  null.
- Probe: missing file → free **and not created**; existing unheld file →
  free; held → held; released → free. The lock is held by
  `flock <file> -c "echo ready; cat"` — reading `ready` proves
  acquisition, closing stdin releases it.
- Supervisor (synthetic time + real lock): held through the pre-fire probe
  → window skipped, no completion, next fire recomputed; free → watched
  and completed normally; no pre-fire tick → watched despite the lock
  (fallback); disagreeing same-log locks → collapsed `lockPath` is null.

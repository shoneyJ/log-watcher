#!/usr/bin/env bash
# End-to-end demo on the committed fixture cron.d (plan/04 phase 5).
# Runs the supervisor against test/fixtures/cron.d while this script plays
# the part of cron: it writes healthy.log the way the real cron entry would
# (via shell redirection). Takes ~2.5 minutes (two * * * * * windows).
#
# Expected in the output:
#   - SKIP lines for the non-watchable/malformed edge-case entries
#   - SCHEDULE /var/log/test.log: */20 * * * * (flock /var/run/test.lock)
#     — the flock-wrapped edge-case entry, lock file noted (plan/05)
#   - DONE ...healthy.log: ok            (info-final content)
#   - DONE ...healthy.log: ERROR-final   + ALERT (error-final content)
#   - possibly DONE ...failing.log: missed (its */5 window with no producer)
#   - possibly DONE /var/log/test.log: missed (if a */20 boundary falls in
#     the run and nothing writes that log on this machine)
set -eu
cd "$(dirname "$0")/.."
test -x bin/Main || { echo "build first: haxe build.hxml"; exit 1; }
mkdir -p test/live
: > test/live/healthy.log
out=test/live/demo-output.txt

./bin/Main run test/fixtures/cron.d test/demo-config.json > "$out" 2>&1 &
sup=$!
trap 'kill $sup 2>/dev/null || true' EXIT
echo "supervisor running (pid $sup), output -> $out"

./test/produce-log.sh info 8 0 >> test/live/healthy.log 2>&1
echo "t+0s: wrote info-final content; waiting through first activation + quiet period"
sleep 75
./test/produce-log.sh error 8 0 >> test/live/healthy.log 2>&1
echo "t+75s: wrote error-final content; waiting through second activation"
sleep 75

kill $sup 2>/dev/null || true
echo "--- supervisor output ---"
cat "$out"

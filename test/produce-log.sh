#!/usr/bin/env bash
# Fake log producer — the testing base for every phase (plan/04).
#
# Emits level-prefixed log lines to STDOUT; the caller's redirection decides
# the log file, which is exactly the contract the cron parser extracts from
# cron.d entries (plan/03). Examples:
#
#   test/produce-log.sh error 12 0 >> test/live/failing.log 2>&1
#   test/produce-log.sh info 500 >> test/fixtures/basic.log
#
# usage: produce-log.sh [FINAL_LEVEL] [LINES] [INTERVAL_SECS]
#   FINAL_LEVEL    level of the last entry: info|warn|error   (default info)
#   LINES          total entries to emit                      (default 10)
#   INTERVAL_SECS  sleep between lines, fractional ok         (default 0)
#
# Output is deterministic apart from timestamps: the body cycles info with a
# warn every 4th line, the final entry is FINAL_LEVEL, and when FINAL_LEVEL
# is 'error' two indented continuation lines follow (stack-trace style) to
# exercise the continuation rule from plan/02.

set -eu

final=${1:-info}
lines=${2:-10}
interval=${3:-0}

for ((i = 1; i < lines; i++)); do
  if ((i % 4 == 0)); then level=warn; else level=info; fi
  echo "$level $(date '+%Y-%m-%dT%H:%M:%S') job step $i of $((lines - 1))"
  if [ "$interval" != "0" ]; then sleep "$interval"; fi
done

echo "$final $(date '+%Y-%m-%dT%H:%M:%S') job finished with status $final"
if [ "$final" = "error" ]; then
  echo "    at fake_job.do_work (produce-log.sh:1)"
  echo "    at fake_job.main (produce-log.sh:1)"
fi

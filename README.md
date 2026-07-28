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

## Plan

Design documents, in order — later plans supersede earlier ones where noted:

1. [Toolchain and development environment](plan/01.md) — Haxe → C++ pipeline, system requirements, setup and verification.
2. [What gets monitored](plan/02-what-gets-monitored.md) — watcher lifecycles for service vs cron logs, scale constraints (10 × 2 GB), kill-self guarantee.
3. [Cron parser](plan/03-cron-parser.md) — parsing `/etc/cron.d` to generate watcher config from each entry's log redirection.

## out of scope

- any form of alerting mechanism.

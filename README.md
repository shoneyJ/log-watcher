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

## out of scope

- any form of alerting mechanism.

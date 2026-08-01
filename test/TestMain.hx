import sys.FileSystem;
import sys.io.File;
import sys.io.FileSeek;
import Watcher.CronResult;

// Zero-dependency test suite (plan 04): run with `haxe test.hxml` (interp)
// and natively via test-native.hxml. Must be run from the repo root.
class TestMain {
	static inline var TMP = "test/tmp";
	static var checks = 0;
	static var failures = 0;
	static var root:String;

	static function main() {
		var cwd = Sys.getCwd();
		root = StringTools.endsWith(cwd, "/") ? cwd : cwd + "/";
		rmrf(TMP);
		FileSystem.createDirectory(TMP);

		testTailBasics();
		testTailTorn();
		testTailRotation();
		testTailSparse2GB();
		testLastLines();
		testProducerFixture();
		testCronParseFixtures();
		testNextFire();
		testFlockProbe();
		testWatcherStateMachine();
		testSupervisorLifecycle();
		testSupervisorMidWindow();
		testSupervisorLockSkip();
		testPgrepProbe();
		testToolsListing();
		testToolsTailSearch();
		testMcpEnvelope();
		testMcpToolCalls();

		#if cpp
		testMiniLogLoad();
		testMiniLogQuery();
		testMiniLogBudget();
		testMcpMinilogTools();
		testMcpSocket();
		#end

		Sys.println('$checks checks, $failures failures');
		Sys.exit(failures == 0 ? 0 : 1);
	}

	// ---- helpers ----

	static function ok(cond:Bool, what:String) {
		checks++;
		if (!cond) {
			failures++;
			Sys.println('FAIL: $what');
		}
	}

	static function eq(got:Dynamic, want:Dynamic, what:String)
		ok(got == want, '$what (got $got, want $want)');

	static function append(path:String, s:String) {
		var fo = File.append(path, true);
		fo.writeString(s);
		fo.close();
	}

	static function rmrf(p:String) {
		if (!FileSystem.exists(p)) return;
		if (FileSystem.isDirectory(p)) {
			for (n in FileSystem.readDirectory(p)) rmrf('$p/$n');
			FileSystem.deleteDirectory(p);
		} else {
			FileSystem.deleteFile(p);
		}
	}

	static function date(y:Int, mo:Int, d:Int, h:Int, mi:Int):Date
		return new Date(y, mo - 1, d, h, mi, 0);

	static function nf(expr:String, from:Date):String {
		var d = Cron.nextFire(expr, from);
		return d == null ? "null" : d.toString();
	}

	// ---- LogTail ----

	static function testTailBasics() {
		var p = '$TMP/basic.log';
		append(p, "info one\ninfo two\nwarn three\n");
		var st = LogTail.newState();
		var r = LogTail.poll(p, st, 100.);
		eq(r.newLines, 3, "basic: three complete lines");
		eq(st.lastLevel, "warn", "basic: last level warn");
		eq(st.lastNewLineAt, 100., "basic: lastNewLineAt stamped");

		append(p, "error boom\n    at stack frame 1\n");
		r = LogTail.poll(p, st, 105.);
		eq(r.newLines, 2, "basic: incremental read");
		eq(st.lastLevel, "error", "basic: continuation inherits error");

		r = LogTail.poll(p, st, 106.);
		eq(r.newLines, 0, "basic: idle poll reads nothing");
		eq(r.bytesRead, 0, "basic: idle poll costs no bytes");
		eq(st.lastNewLineAt, 105., "basic: idle poll keeps timestamp");

		var missing = LogTail.poll('$TMP/absent.log', LogTail.newState(), 1.);
		ok(!missing.exists, "basic: absent file reported");
	}

	static function testTailTorn() {
		var p = '$TMP/torn.log';
		append(p, "info a\n");
		var st = LogTail.newState();
		LogTail.poll(p, st, 1.);
		eq(st.lastLevel, "info", "torn: baseline");

		append(p, "error torn-no-newline");
		var r = LogTail.poll(p, st, 2.);
		eq(r.newLines, 0, "torn: incomplete line held back");
		eq(st.lastLevel, "info", "torn: level unchanged");

		append(p, " completed\n");
		r = LogTail.poll(p, st, 3.);
		eq(r.newLines, 1, "torn: completed line judged");
		eq(st.lastLevel, "error", "torn: level now error");
	}

	static function testTailRotation() {
		// rename + recreate (logrotate default)
		var p = '$TMP/rot.log';
		append(p, "info old content here\n");
		var st = LogTail.newState();
		LogTail.poll(p, st, 1.);
		FileSystem.rename(p, '$p.1');
		File.saveContent(p, "warn fresh file\n");
		var r = LogTail.poll(p, st, 2.);
		eq(r.newLines, 1, "rotation: new file read from start");
		eq(st.lastLevel, "warn", "rotation: level from new file");

		// truncate in place (copytruncate)
		append(p, "info filler filler filler\ninfo more filler content\n");
		LogTail.poll(p, st, 3.);
		File.saveContent(p, "error s\n"); // smaller than stored offset
		r = LogTail.poll(p, st, 4.);
		eq(r.newLines, 1, "truncate: restart from top");
		eq(st.lastLevel, "error", "truncate: level from new content");
	}

	static function testTailSparse2GB() {
		var p = '$TMP/big.log';
		var fo = File.write(p, true);
		fo.seek(2000000000, SeekBegin); // sparse: no real disk usage
		fo.writeString("info tail line\nerror final\n");
		fo.close();
		ok(FileSystem.stat(p).size > 1999999999, "sparse: file is ~2 GB");

		var st = LogTail.newState();
		var r = LogTail.poll(p, st, 1.);
		ok(r.bytesRead <= LogTail.CHUNK, 'sparse: read ${r.bytesRead} bytes <= chunk (O(chunk), not O(file))');
		eq(st.lastLevel, "error", "sparse: last level found at the tail");
		FileSystem.deleteFile(p);
	}

	static function testLastLines() {
		var p = '$TMP/last.log';
		append(p, "info one\ninfo two\nwarn three\nerror four\n");
		var got = LogTail.lastLines(p, 2);
		eq(got.length, 2, "lastLines: two lines");
		eq(got[0], "warn three", "lastLines: order kept");
		eq(got[1], "error four", "lastLines: newest last");

		eq(LogTail.lastLines(p, 10).length, 4, "lastLines: fewer than asked");

		append(p, "torn tail no newline");
		var t = LogTail.lastLines(p, 10);
		eq(t.length, 4, "lastLines: torn final line dropped");
		eq(t[3], "error four", "lastLines: last complete line kept");

		ok(LogTail.lastLines('$TMP/absent.log', 5) == null, "lastLines: missing file null");

		// bounded: sparse ~2GB file, only the final CHUNK is examined
		var big = '$TMP/last-sparse.bin';
		var fo = File.write(big, true);
		fo.seek(2147000000, SeekBegin);
		fo.writeString("info tail-a\ninfo tail-b\n");
		fo.close();
		var lb = LogTail.lastLines(big, 5);
		eq(lb[lb.length - 1], "info tail-b", "lastLines: sparse tail read");
		FileSystem.deleteFile(big);
	}

	static function testProducerFixture() {
		var p = '$TMP/prod.log';
		var code = Sys.command("bash", ["-c", './test/produce-log.sh error 6 0 >> $p 2>&1']);
		eq(code, 0, "producer: script runs");
		var st = LogTail.newState();
		var r = LogTail.poll(p, st, 1.);
		eq(r.newLines, 8, "producer: 5 body + final + 2 continuation lines");
		eq(st.lastLevel, "error", "producer: error-final run");

		Sys.command("bash", ["-c", './test/produce-log.sh info 3 0 >> $p 2>&1']);
		LogTail.poll(p, st, 2.);
		eq(st.lastLevel, "info", "producer: info-final run clears level");
	}

	// ---- Cron ----

	static function testCronParseFixtures() {
		var res = Cron.parseDir("test/fixtures/cron.d");
		eq(res.entries.length, 7, "parse: watchable entries");
		eq(res.skipped.length, 5, "parse: skipped entries");

		// an unreadable cron.d (e.g. /etc/cron.d 700) is reported, never fatal
		var locked = '$TMP/locked-cron.d';
		FileSystem.createDirectory(locked);
		Sys.command("chmod", ["000", locked]);
		var lr = Cron.parseDir(locked);
		Sys.command("chmod", ["755", locked]);
		eq(lr.entries.length, 0, "parse: unreadable dir yields no entries");
		eq(lr.skipped.length, 1, "parse: unreadable dir reported");
		ok(lr.skipped[0].reason.indexOf("unreadable directory") >= 0, "parse: unreadable dir reason");

		var byLog = [for (e in res.entries) e.logPath => e];
		var healthy = byLog.get("/home/shoney/projects/log-watcher/test/live/healthy.log");
		ok(healthy != null, "parse: healthy.log found");
		eq(healthy.schedule, "* * * * *", "parse: healthy schedule");
		eq(healthy.user, "shoney", "parse: healthy user");
		ok(healthy.command.indexOf("produce-log.sh") >= 0, "parse: command kept");
		eq(healthy.lockPath, null, "parse: un-flocked entry has no lock");

		var flocked = byLog.get("/var/log/test.log");
		ok(flocked != null, "parse: flock-wrapped entry watchable");
		eq(flocked.schedule, "*/20 * * * *", "parse: flock schedule");
		eq(flocked.lockPath, "/var/run/test.lock", "parse: flock lock file noted");

		eq(byLog.get("/home/shoney/projects/log-watcher/test/live/failing.log").schedule,
			"*/5 * * * *", "parse: failing schedule");
		ok(byLog.exists("/var/log/backup-errors.log"), "parse: stderr-only 2>> is watchable");
		eq(byLog.get("/var/log/nightly-report.log").schedule, "0 0 * * *", "parse: @daily expanded");
		ok(byLog.exists("/var/log/weekday.log"), "parse: dow name range accepted");

		var reasons = [for (s in res.skipped) s.reason].join(" ; ");
		ok(reasons.indexOf("@reboot") >= 0, "parse: @reboot skipped");
		ok(reasons.indexOf("not watchable") >= 0, "parse: non-watchable reported");
		ok(reasons.indexOf("malformed") >= 0, "parse: malformed reported");
	}

	static function testNextFire() {
		// calendar sanity for the assertions below
		eq(date(2026, 7, 29, 0, 0).getDay(), 3, "calendar: 2026-07-29 is Wednesday");

		eq(nf("*/5 * * * *", date(2026, 7, 29, 10, 3)), date(2026, 7, 29, 10, 5).toString(), "nextFire: steps");
		eq(nf("* * * * *", date(2026, 7, 29, 10, 3)), date(2026, 7, 29, 10, 4).toString(), "nextFire: every minute");
		eq(nf("0 0 * * *", date(2026, 7, 29, 10, 3)), date(2026, 7, 30, 0, 0).toString(), "nextFire: daily midnight");
		eq(nf("30 4 1 * *", date(2026, 7, 29, 10, 3)), date(2026, 8, 1, 4, 30).toString(), "nextFire: dom");
		eq(nf("@hourly", date(2026, 7, 29, 10, 3)), date(2026, 7, 29, 11, 0).toString(), "nextFire: alias");
		eq(nf("0 12 * * mon", date(2026, 7, 29, 10, 3)), date(2026, 8, 3, 12, 0).toString(), "nextFire: dow name");
		eq(nf("15 4 * * mon-fri", date(2026, 8, 1, 10, 0)), date(2026, 8, 3, 4, 15).toString(), "nextFire: name range over weekend");
		eq(nf("0,30 6 * * *", date(2026, 7, 29, 6, 10)), date(2026, 7, 29, 6, 30).toString(), "nextFire: list");
		// vixie OR quirk: dom 13 OR friday — Fri Jul 31 comes first
		eq(nf("0 0 13 * fri", date(2026, 7, 29, 10, 3)), date(2026, 7, 31, 0, 0).toString(), "nextFire: dom/dow OR quirk");
		eq(nf("0 0 13 * *", date(2026, 7, 29, 10, 3)), date(2026, 8, 13, 0, 0).toString(), "nextFire: dom only");
		eq(nf("0 0 29 2 *", date(2026, 7, 29, 0, 0)), "null", "nextFire: no fire within a year");
		eq(nf("61 * * * *", date(2026, 7, 29, 0, 0)), "null", "nextFire: invalid field");
	}

	// ---- Flock ----

	// Deterministic holder, no sleeps: `echo ready` runs only after flock
	// acquires, so readLine() brackets the start of the held interval, and
	// closing stdin ends `cat`, releasing the lock (exitCode() waits).
	static function holdLock(path:String):sys.io.Process {
		var p = new sys.io.Process("flock", [path, "-c", "echo ready; cat"]);
		eq(p.stdout.readLine(), "ready", "flock holder: lock acquired");
		return p;
	}

	static function releaseLock(p:sys.io.Process) {
		p.stdin.close();
		p.exitCode();
		p.close();
	}

	static function testFlockProbe() {
		var p = '$TMP/probe.lock';
		ok(!Flock.held(p), "flock: missing lock file not held");
		ok(!FileSystem.exists(p), "flock: probe did not create the file");

		File.saveContent(p, "");
		ok(!Flock.held(p), "flock: existing unheld file not held");

		var holder = holdLock(p);
		ok(Flock.held(p), "flock: held while holder runs");
		releaseLock(holder);
		ok(!Flock.held(p), "flock: released after holder exits");
	}

	// ---- Pgrep ----

	static function testPgrepProbe() {
		ok(!Pgrep.alive("no-such-needle-zx9q7"), "pgrep: nonsense needle not running");

		var marker = "pgrep-marker-zx9q7";
		var p = new sys.io.Process("bash", ["-c", "echo ready; exec -a " + marker + " cat"]);
		eq(p.stdout.readLine(), "ready", "pgrep holder: started");
		ok(Pgrep.alive(marker), "pgrep: marker process found");
		p.stdin.close();
		p.exitCode();
		p.close();
		ok(!Pgrep.alive(marker), "pgrep: gone after exit");
	}

	// ---- Tools ----

	static function testToolsListing() {
		var dir = '$TMP/tools-cron.d';
		FileSystem.createDirectory(dir);
		var lock = root + 'test/tmp/tools.lock';
		var clog = root + 'test/tmp/tools-cron.log';
		var xlog = root + 'test/tmp/tools-extra.log';
		File.saveContent('$dir/jobs',
			'*/5 * * * * shoney /bin/marker-zq31.sh >> $clog 2>&1\n' +
			'*/20 * * * * root flock -w 600 $lock -c "/bin/other.sh >> $clog 2>&1"\n');
		append(clog, "info hello\n");
		append(xlog, "error boom\n");

		var tools = new Tools(dir, [xlog]);
		var paths = tools.allowedPaths();
		eq(paths.length, 2, "tools: allowlist deduped (two entries, one log + extra)");

		var ll:Dynamic = haxe.Json.parse(tools.listLogs().text);
		eq(ll.length, 2, "list_logs: two rows");
		eq(ll[0].path, clog, "list_logs: cron log first");
		eq(ll[0].source, "cron", "list_logs: cron source");
		eq(ll[1].source, "config", "list_logs: config source");
		ok(ll[0].sizeBytes > 0, "list_logs: size read");

		var missing = new Tools(dir, [root + 'test/tmp/ghost.log']);
		var lm:Dynamic = haxe.Json.parse(missing.listLogs().text);
		ok(lm[1].sizeBytes == null, "list_logs: missing file null size");

		var rc:Dynamic = haxe.Json.parse(tools.getRunningCrons(date(2026, 7, 29, 10, 3)).text);
		eq(rc.length, 2, "running: two entries");
		eq(rc[0].running, false, "running: nothing alive");
		ok((rc[0].nextFire : String).indexOf("10:05") >= 0, "running: nextFire computed");

		// un-flocked: pgrep on the script path
		var mp = new sys.io.Process("bash", ["-c", "echo ready; exec -a /bin/marker-zq31.sh cat"]);
		eq(mp.stdout.readLine(), "ready", "tools marker: started");
		rc = haxe.Json.parse(tools.getRunningCrons(date(2026, 7, 29, 10, 3)).text);
		eq(rc[0].running, true, "running: pgrep finds marker");
		mp.stdin.close(); mp.exitCode(); mp.close();

		// flocked: probe the lock, not pgrep
		var holder = holdLock(lock);
		rc = haxe.Json.parse(tools.getRunningCrons(date(2026, 7, 29, 10, 3)).text);
		eq(rc[1].running, true, "running: flock held = running");
		releaseLock(holder);
		rc = haxe.Json.parse(tools.getRunningCrons(date(2026, 7, 29, 10, 3)).text);
		eq(rc[1].running, false, "running: flock released = not running");
	}

	// ---- Watcher ----

	static function testWatcherStateMachine() {
		var p = '$TMP/svc.log';
		append(p, "info start\n");
		var w = new Watcher(p, 10., 1., true, 1000.);
		w.tick(1000.);
		ok(!w.alerted, "watcher: healthy log no alert");

		append(p, "error crash\n");
		w.tick(1002.);
		ok(!w.alerted, "watcher: error but quiet period not elapsed");
		w.tick(1013.);
		ok(w.alerted, "watcher: error + quiet -> alert");

		append(p, "info recovered\n");
		w.tick(1014.);
		ok(!w.alerted, "watcher: new info entry clears alert");

		// error followed by info within the quiet period never alerts
		append(p, "error blip\n");
		w.tick(1015.);
		append(p, "info fine\n");
		w.tick(1016.);
		w.tick(1040.);
		ok(!w.alerted, "watcher: error followed by info never alerts");
	}

	// ---- Supervisor ----

	static function testSupervisorLifecycle() {
		var cronDir = '$TMP/cron.d';
		FileSystem.createDirectory(cronDir);
		var log1 = root + 'test/tmp/job1.log';
		var log2 = root + 'test/tmp/job2.log';
		File.saveContent('$cronDir/job1', '* * * * * shoney /bin/true >> $log1 2>&1\n');

		var sup = new Supervisor(cronDir, {pollInterval: 1., quietPeriod: 5., rescanInterval: 30., services: []});
		var t0 = date(2026, 7, 29, 10, 0).getTime() / 1000. + 30; // 10:00:30

		sup.tick(t0);
		ok(sup.scheduled.exists(log1), "supervisor: job1 scheduled");
		ok(!sup.active.exists(log1), "supervisor: not active before nextFire");
		var fire = sup.scheduled.get(log1).nextFire;
		eq(Date.fromTime(fire * 1000.).toString(), date(2026, 7, 29, 10, 1).toString(),
			"supervisor: nextFire on the minute");

		sup.tick(fire + 1);
		ok(sup.active.exists(log1), "supervisor: activated at nextFire");

		append(log1, "info working\nerror boom\n");
		sup.tick(fire + 2); // poll picks up content
		sup.tick(fire + 4);
		ok(sup.active.exists(log1), "supervisor: still active while quiet period runs");
		sup.tick(fire + 8); // quiet 6s >= 5s -> complete
		ok(!sup.active.exists(log1), "supervisor: kill-self, watch fully gone");
		eq(sup.completions.length, 1, "supervisor: one completion");
		eq(sup.completions[0].result, CronResult.ErrorFinal, "supervisor: error-final result");

		// a newly dropped cron file is picked up within one rescan
		// (the last rescan ran at fire+1 = t0+31, so the next is due t0+61)
		File.saveContent('$cronDir/job2', '*/2 * * * * shoney /bin/true >> $log2 2>&1\n');
		sup.tick(t0 + 62);
		ok(sup.scheduled.exists(log2), "supervisor: new cron file discovered");

		// a removed file's pending activation is cancelled
		FileSystem.deleteFile('$cronDir/job1');
		sup.tick(t0 + 93);
		ok(!sup.scheduled.exists(log1), "supervisor: removed file cancels pending activation");
		ok(sup.scheduled.exists(log2), "supervisor: other file unaffected");

		// miss: activation with no log activity at all
		sup.tick(sup.scheduled.get(log2).nextFire + 1);
		ok(sup.active.exists(log2), "supervisor: job2 activated");
		sup.tick(sup.scheduled.get(log2).nextFire + 7); // quiet from activation
		eq(sup.completions.length, 2, "supervisor: miss completion recorded");
		eq(sup.completions[1].result, CronResult.Miss, "supervisor: miss result");
	}

	static function testSupervisorMidWindow() {
		var cronDir = '$TMP/cron2.d';
		FileSystem.createDirectory(cronDir);
		var log3 = root + 'test/tmp/mid.log';
		append(log3, "info already running\n"); // mtime = real now
		File.saveContent('$cronDir/mid', '0 0 1 1 * shoney /bin/true >> $log3 2>&1\n');

		var sup = new Supervisor(cronDir, {pollInterval: 1., quietPeriod: 5., rescanInterval: 30., services: []});
		sup.tick(Sys.time()); // real clock: mtime comparison must line up
		ok(sup.active.exists(log3), "supervisor: mid-window log activated at startup");
	}

	// synthetic supervisor time composes with a real flock: the probe asks
	// the OS about the lock, not the clock
	static function testSupervisorLockSkip() {
		var cronDir = '$TMP/cron3.d';
		FileSystem.createDirectory(cronDir);
		var log = root + 'test/tmp/locked.log';
		var lock = root + 'test/tmp/locked.lock';
		File.saveContent('$cronDir/job',
			'* * * * * shoney flock -w 600 $lock -c "/bin/true >> $log 2>&1"\n');

		var sup = new Supervisor(cronDir, {pollInterval: 1., quietPeriod: 5., rescanInterval: 30., services: []});
		var t0 = date(2026, 7, 29, 10, 0).getTime() / 1000. + 30; // 10:00:30
		sup.tick(t0);
		eq(sup.scheduled.get(log).lockPath, lock, "lock-skip: lockPath plumbed into schedule");

		// window 1: lock held through the pre-fire probe -> skipped
		var holder = holdLock(lock);
		var fire = sup.scheduled.get(log).nextFire;
		sup.tick(fire - 1); // probe tick inside PROBE_LEAD
		sup.tick(fire + 1);
		ok(!sup.active.exists(log), "lock-skip: locked window not watched");
		eq(sup.completions.length, 0, "lock-skip: no completion recorded");
		ok(sup.scheduled.get(log).nextFire > fire, "lock-skip: next window rescheduled");
		releaseLock(holder);

		// window 2: lock free -> watched normally, misses (no log activity)
		var fire2 = sup.scheduled.get(log).nextFire;
		sup.tick(fire2 - 1);
		sup.tick(fire2 + 1);
		ok(sup.active.exists(log), "lock-skip: free window watched");
		sup.tick(fire2 + 7); // quiet from activation -> complete
		eq(sup.completions.length, 1, "lock-skip: free window completed");

		// window 3: no pre-fire tick -> no probe -> watches even while locked
		var holder2 = holdLock(lock);
		var fire3 = sup.scheduled.get(log).nextFire;
		sup.tick(fire3 + 1); // straight past the fire
		ok(sup.active.exists(log), "lock-skip: unprobed window falls back to watching");
		releaseLock(holder2);

		// same log, disagreeing locks -> lockPath null (always watch)
		var cronDir2 = '$TMP/cron4.d';
		FileSystem.createDirectory(cronDir2);
		var log2 = root + 'test/tmp/shared.log';
		File.saveContent('$cronDir2/jobs',
			'* * * * * shoney flock /a.lock -c "x >> $log2 2>&1"\n'
			+ '*/2 * * * * shoney flock /b.lock -c "y >> $log2 2>&1"\n');
		var sup2 = new Supervisor(cronDir2, {pollInterval: 1., quietPeriod: 5., rescanInterval: 30., services: []});
		sup2.tick(t0);
		eq(sup2.scheduled.get(log2).lockPath, null, "lock-skip: disagreeing locks collapse to null");
	}

	static function testToolsTailSearch() {
		var dir = '$TMP/tools2-cron.d';
		FileSystem.createDirectory(dir);
		var log = root + 'test/tmp/tools2.log';
		File.saveContent('$dir/jobs', '* * * * * shoney /bin/x.sh >> $log 2>&1\n');
		for (i in 0...30) append(log, 'info line $i\n');
		append(log, "error needle-here\n");

		var tools = new Tools(dir, []);

		var t:Dynamic = haxe.Json.parse(tools.tailLog(log, null).text);
		eq(t.length, 20, "tail_log: default 20");
		eq(t[19], "error needle-here", "tail_log: newest last");
		eq(haxe.Json.parse(tools.tailLog(log, 500).text).length, 31, "tail_log: cap tolerates short file");

		var deny = tools.tailLog("/etc/passwd", 5);
		ok(deny.isError, "tail_log: non-allowlisted path rejected");
		ok(deny.text.indexOf(log) >= 0, "tail_log: rejection lists allowlist");

		var s:Dynamic = haxe.Json.parse(tools.searchLog(log, "NEEDLE", null).text);
		eq(s.matches.length, 1, "search_log: case-insensitive match");
		ok((s.matches[0].line : String).indexOf("needle-here") >= 0, "search_log: line returned");
		eq(s.searchedBytes > 0, true, "search_log: reports window");

		var s2:Dynamic = haxe.Json.parse(tools.searchLog(log, "line", 5).text);
		eq(s2.matches.length, 5, "search_log: maxMatches honored");
		ok((s2.matches[0].line : String).indexOf("line 29") >= 0, "search_log: newest first");

		ok(tools.searchLog(log, "", null).isError, "search_log: empty pattern rejected");

		// ANSI/control bytes in log lines must not reach the JSON output
		// (haxe.Json.stringify does not escape C0 chars -> invalid JSON at clients)
		var esc = String.fromCharCode(27);
		append(log, esc + "[32minfo" + esc + "[39m colored line\n");
		var ct = tools.tailLog(log, 1);
		ok(ct.text.indexOf(esc) < 0, "tail_log: ANSI stripped from output");
		eq(haxe.Json.parse(ct.text)[0], "info colored line", "tail_log: clean line kept");
		var cs = tools.searchLog(log, "colored", null);
		ok(cs.text.indexOf(esc) < 0, "search_log: ANSI stripped from output");
	}

	// ---- MCP ----

	static function mcpReq(m:Mcp, body:String, ?key:String):Dynamic {
		var h = new Map<String, String>();
		h.set("authorization", "Bearer " + (key == null ? "sekrit" : key));
		var r = m.handle({method: "POST", path: "/mcp", headers: h, body: body});
		return {status: r.status, json: r.body == "" ? null : haxe.Json.parse(r.body)};
	}

	static function rpc(method:String, ?params:Dynamic, ?id:Null<Int>):String
		return haxe.Json.stringify({jsonrpc: "2.0", id: id == null ? 1 : id, method: method, params: params == null ? {} : params});

	static function testMcpEnvelope() {
		var dir = '$TMP/mcp-cron.d';
		FileSystem.createDirectory(dir);
		File.saveContent('$dir/jobs', '* * * * * shoney /bin/x.sh >> ' + root + 'test/tmp/mcp.log 2>&1\n');
		var m = new Mcp(new Tools(dir, []), new MiniLog(), "sekrit");

		// auth is checked before anything else
		var noAuth = m.handle({method: "POST", path: "/mcp", headers: new Map(), body: rpc("ping")});
		eq(noAuth.status, 401, "mcp: missing auth 401");
		eq(mcpReq(m, rpc("ping"), "wrong").status, 401, "mcp: wrong key 401");

		var wrongMethod = new Map<String, String>();
		wrongMethod.set("authorization", "Bearer sekrit");
		eq(m.handle({method: "GET", path: "/mcp", headers: wrongMethod, body: ""}).status, 405, "mcp: GET 405");
		eq(m.handle({method: "POST", path: "/other", headers: wrongMethod, body: rpc("ping")}).status, 404, "mcp: wrong path 404");

		var big = StringTools.rpad("x", "x", Mcp.BODY_MAX + 1);
		eq(m.handle({method: "POST", path: "/mcp", headers: wrongMethod, body: big}).status, 413, "mcp: oversized body 413");

		var r = mcpReq(m, rpc("initialize", {protocolVersion: "2025-03-26", capabilities: {}}));
		eq(r.status, 200, "mcp: initialize 200");
		eq(r.json.result.protocolVersion, "2025-03-26", "mcp: protocol version");
		ok(r.json.result.capabilities.tools != null, "mcp: tools capability");
		eq(r.json.result.serverInfo.name, "log-watcher", "mcp: server name");

		var note = mcpReq(m, haxe.Json.stringify({jsonrpc: "2.0", method: "notifications/initialized"}));
		eq(note.status, 202, "mcp: notification 202");

		eq(mcpReq(m, rpc("ping")).json.id, 1, "mcp: ping echoes id");

		var tl = mcpReq(m, rpc("tools/list")).json.result.tools;
		eq(tl.length, 6, "mcp: six tools listed");
		var names = [for (t in (tl : Array<Dynamic>)) (t.name : String)].join(",");
		ok(names.indexOf("get_running_crons") >= 0, "mcp: get_running_crons listed");
		ok(names.indexOf("list_logs") >= 0, "mcp: list_logs listed");
		ok(names.indexOf("tail_log") >= 0, "mcp: tail_log listed");
		ok(names.indexOf("search_log") >= 0, "mcp: search_log listed");
		ok(names.indexOf("load_log_db") >= 0, "mcp: load_log_db listed");
		ok(names.indexOf("query_log_db") >= 0, "mcp: query_log_db listed");

		eq(mcpReq(m, "{not json").json.error.code, -32700, "mcp: parse error");
		eq(mcpReq(m, haxe.Json.stringify({jsonrpc: "2.0", id: 2})).json.error.code, -32600, "mcp: no method");
		eq(mcpReq(m, rpc("bogus/method")).json.error.code, -32601, "mcp: unknown method");
	}

	static function testMcpToolCalls() {
		var dir = '$TMP/mcpc-cron.d';
		FileSystem.createDirectory(dir);
		var log = root + 'test/tmp/mcpc.log';
		File.saveContent('$dir/jobs', '* * * * * shoney /bin/x.sh >> $log 2>&1\n');
		append(log, "info alpha\nerror beta\n");
		var m = new Mcp(new Tools(dir, []), new MiniLog(), "sekrit");

		function call(name:String, args:Dynamic):Dynamic
			return mcpReq(m, rpc("tools/call", {name: name, arguments: args})).json.result;

		var r = call("list_logs", {});
		eq(r.isError, false, "call: list_logs ok");
		eq((haxe.Json.parse(r.content[0].text) : Array<Dynamic>)[0].path, log, "call: list_logs payload");

		r = call("tail_log", {path: log, lines: 1});
		eq(r.isError, false, "call: tail_log ok");
		eq(haxe.Json.parse(r.content[0].text)[0], "error beta", "call: tail_log payload");

		r = call("tail_log", {path: "/etc/passwd"});
		eq(r.isError, true, "call: allowlist rejection isError");

		r = call("search_log", {path: log, pattern: "ALPHA"});
		eq(haxe.Json.parse(r.content[0].text).matches.length, 1, "call: search_log match");

		r = call("get_running_crons", {});
		eq(r.isError, false, "call: get_running_crons ok");
		eq(haxe.Json.parse(r.content[0].text)[0].running, false, "call: not running");

		r = call("no_such_tool", {});
		eq(r.isError, true, "call: unknown tool isError");

		r = call("tail_log", {});
		eq(r.isError, true, "call: missing required arg isError");
	}

	// ---- MiniLog (sqlite is native-only: the interpreter has no sys.db) ----

	#if cpp
	static function testMiniLogLoad() {
		var log = '$TMP/mini.log';
		File.saveContent(log, "info one\nerror boom\n    at frame 1\n    at frame 2\nwarn after\n");
		var mini = new MiniLog();
		ok(!mini.loaded(), "minilog: starts empty");

		var r = mini.load([log]);
		eq(r.isError, false, "minilog: load ok");
		var rep:Dynamic = haxe.Json.parse(r.text);
		eq(rep.totalEntries, 3, "minilog: continuations folded into 3 entries");
		eq(rep.files[0].truncated, false, "minilog: small file not truncated");
		ok(mini.loaded(), "minilog: loaded after load");

		var q = mini.query("SELECT level, body FROM entries WHERE level='error'");
		var rows:Array<Dynamic> = haxe.Json.parse(q.text).rows;
		eq(rows.length, 1, "minilog: one error entry");
		ok((rows[0].body : String).indexOf("at frame 2") >= 0, "minilog: body holds folded continuation");

		// torn final line dropped
		append(log, "error torn-no-newline");
		mini.load([log]);
		var q2 = mini.query("SELECT count(*) AS n FROM entries");
		eq(haxe.Json.parse(q2.text).rows[0].n, 3, "minilog: torn final line not ingested");

		// reload replaces, not appends
		mini.load([log]);
		eq(haxe.Json.parse(mini.query("SELECT count(*) AS n FROM entries").text).rows[0].n, 3, "minilog: reload replaces");

		// unreadable file reported per-file, load continues
		var r3 = mini.load([log, '$TMP/ghost-mini.log']);
		var rep3:Dynamic = haxe.Json.parse(r3.text);
		eq(rep3.files[1].error != null, true, "minilog: missing file reported");
		eq(rep3.totalEntries, 3, "minilog: good file still loaded");

		// all files failing -> isError
		ok(mini.load(['$TMP/ghost-a.log']).isError, "minilog: all-failed load isError");

		// ANSI-colored level prefixes: sanitized before classify AND before
		// the body lands in the DB (control bytes would break the JSON output)
		var esc = String.fromCharCode(27);
		var clog = '$TMP/mini-color.log';
		File.saveContent(clog, esc + "[32minfo" + esc + "[39m colored ok\n"
			+ esc + "[31merror" + esc + "[39m colored boom\n");
		mini.load([clog]);
		var cq = mini.query("SELECT level, body FROM entries ORDER BY id");
		ok(cq.text.indexOf(esc) < 0, "minilog: ANSI stripped from query output");
		var crows:Array<Dynamic> = haxe.Json.parse(cq.text).rows;
		eq(crows.length, 2, "minilog: colored prefixes classified");
		eq(crows[1].level, "error", "minilog: colored error level");
		eq(crows[1].body, "error colored boom", "minilog: clean body stored");
	}

	static function testMiniLogQuery() {
		var mini = new MiniLog();
		ok(mini.query("SELECT 1").isError, "query: before load isError");

		var log = '$TMP/miniq.log';
		var buf = new StringBuf();
		for (i in 0...300) buf.add(i % 10 == 0 ? 'error e$i\n' : 'info i$i\n');
		File.saveContent(log, buf.toString());
		mini.load([log]);

		var q = mini.query("SELECT count(*) AS n FROM entries WHERE level = 'error'");
		eq(haxe.Json.parse(q.text).rows[0].n, 30, "query: aggregate works");

		var all = haxe.Json.parse(mini.query("SELECT body FROM entries").text);
		eq(all.rows.length, MiniLog.QUERY_MAX_ROWS, "query: row cap");
		eq(all.truncated, true, "query: truncation flagged");

		ok(mini.query("DELETE FROM entries").isError, "query: non-SELECT rejected");
		ok(mini.query("SELECT 1; SELECT 2").isError, "query: multi-statement rejected");
		ok(!mini.query("SELECT 1;").isError, "query: trailing semicolon fine");
		ok(mini.query("SELECT nope FROM entries").isError, "query: sqlite error passed through");
		ok((mini.query("SELECT nope FROM entries").text : String).length > 0, "query: error has message");
	}

	static function testMiniLogBudget() {
		var log = '$TMP/minib.log';
		var buf = new StringBuf();
		for (i in 0...200) buf.add('info line-$i\n'); // ~2.6 KB, lines ~13 bytes
		File.saveContent(log, buf.toString());
		var mini = new MiniLog();
		var rep:Dynamic = haxe.Json.parse(mini.load([log], 1024).text);
		eq(rep.files[0].truncated, true, "budget: truncated flagged");
		ok(rep.files[0].bytesLoaded <= 1024, "budget: bytes read <= share");
		var rows:Array<Dynamic> = haxe.Json.parse(mini.query("SELECT body FROM entries ORDER BY id").text).rows;
		ok(rows.length > 0 && rows.length < 200, "budget: only the tail ingested");
		eq(rows[rows.length - 1].body, "info line-199", "budget: newest entry present");
		// share starts mid-line -> that cut-off first line is skipped
		var firstBody:String = rows[0].body;
		ok(StringTools.startsWith(firstBody, "info line-"), "budget: torn first line skipped, first entry complete");
	}

	static function testMcpMinilogTools() {
		var dir = '$TMP/mcpm-cron.d';
		FileSystem.createDirectory(dir);
		var log = root + 'test/tmp/mcpm-app.log';
		File.saveContent('$dir/jobs', '* * * * * shoney /bin/x.sh >> $log 2>&1\n');
		File.saveContent(log, "info fine\nerror kaboom\n");
		var m = new Mcp(new Tools(dir, []), new MiniLog(), "sekrit");

		function call(name:String, args:Dynamic):Dynamic
			return mcpReq(m, rpc("tools/call", {name: name, arguments: args})).json.result;

		var r = call("query_log_db", {sql: "SELECT 1"});
		eq(r.isError, true, "minilog mcp: query before load isError");

		r = call("load_log_db", {match: "no-such-hint"});
		eq(r.isError, true, "minilog mcp: no match isError");
		ok((r.content[0].text : String).indexOf(log) >= 0, "minilog mcp: no-match lists allowlist");

		r = call("load_log_db", {match: "MCPM-APP"});
		eq(r.isError, false, "minilog mcp: hint match case-insensitive");
		eq(haxe.Json.parse(r.content[0].text).totalEntries, 2, "minilog mcp: loaded");

		r = call("query_log_db", {sql: "SELECT level FROM entries WHERE level='error'"});
		eq(r.isError, false, "minilog mcp: query ok");
		eq(haxe.Json.parse(r.content[0].text).rows.length, 1, "minilog mcp: rows");

		eq(call("load_log_db", {}).isError, true, "minilog mcp: missing match isError");
		eq(call("query_log_db", {}).isError, true, "minilog mcp: missing sql isError");
	}

	static function testMcpSocket() {
		var dir = '$TMP/sock-cron.d';
		FileSystem.createDirectory(dir);
		File.saveContent('$dir/jobs', '* * * * * shoney /bin/x.sh >> ' + root + 'test/tmp/sock.log 2>&1\n');
		var m = new Mcp(new Tools(dir, []), new MiniLog(), "sekrit");
		var port = 18990;
		sys.thread.Thread.create(() -> m.serve(port));
		Sys.sleep(0.3); // let the listener bind

		var body = rpc("ping");
		var s = new sys.net.Socket();
		s.connect(new sys.net.Host("127.0.0.1"), port);
		s.output.writeString("POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer sekrit\r\n"
			+ "Content-Type: application/json\r\nContent-Length: " + body.length + "\r\n\r\n" + body);
		var status = s.input.readLine();
		ok(status.indexOf("200") >= 0, "socket: 200 on ping");
		var line = s.input.readLine();
		while (line != "" && line != "\r") line = s.input.readLine(); // skip headers
		var resp = s.input.readAll().toString();
		eq((haxe.Json.parse(resp).result == null), false, "socket: ping result body");
		s.close();
	}
	#end
}

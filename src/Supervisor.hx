import sys.FileSystem;
import Watcher.CronResult;

typedef SupConfig = {
	var pollInterval:Float;
	var quietPeriod:Float;
	var rescanInterval:Float;
	var services:Array<String>; // log paths watched continuously
}

typedef CronWatch = {
	var schedules:Array<String>; // same-log entries collapse into one watch
	var nextFire:Float; // seconds, min over schedules
	var lockPath:Null<String>; // flock note; null unless every entry agrees
	var lockProbe:Null<Bool>; // pre-fire probe result; null = not probed
}

// Single-threaded event loop (supersedes plan 02's thread-per-watch: this is
// simpler and the kill-self guarantee holds by construction — a completed
// cron watch is just an object that is dropped, and file handles only live
// inside a single LogTail.poll call).
class Supervisor {
	// The lock is probed shortly BEFORE the fire, never at it: at fire time
	// the job's own flock has usually grabbed the lock already, so an
	// at-activation probe would wrongly skip every window.
	public static inline var PROBE_LEAD = 2.0;

	public var scheduled(default, null):Map<String, CronWatch> = new Map();
	public var active(default, null):Map<String, Watcher> = new Map();
	public var completions(default, null):Array<{logPath:String, result:CronResult}> = [];

	var services:Array<Watcher> = [];
	var cronDir:String;
	var cfg:SupConfig;
	var lastRescan:Float = Math.NEGATIVE_INFINITY;
	var dirSig:String = null;
	var firstScan = true;

	public function new(cronDir:String, cfg:SupConfig) {
		this.cronDir = cronDir;
		this.cfg = cfg;
		for (p in cfg.services)
			services.push(new Watcher(p, cfg.quietPeriod, cfg.pollInterval, true, 0));
	}

	// `now` in seconds, injected for testability; run() feeds the real clock
	public function tick(now:Float):Void {
		if (now - lastRescan >= cfg.rescanInterval) rescan(now);

		for (logPath => cw in scheduled) {
			if (active.exists(logPath)) continue;
			if (cw.lockPath != null && cw.lockProbe == null
				&& now >= cw.nextFire - PROBE_LEAD && now < cw.nextFire)
				cw.lockProbe = Flock.held(cw.lockPath);
			if (now < cw.nextFire) continue;
			// no probe taken (e.g. started past the fire) leaves locked
			// false, so the watch runs — the safe direction
			var locked = cw.lockProbe == true;
			cw.lockProbe = null; // reset for the next window
			if (locked) {
				Util.say('SKIP-LOCKED $logPath: ${cw.lockPath} still held, window skipped');
				cw.nextFire = computeNext(cw.schedules, now);
			} else {
				Util.say('WATCH $logPath: activated');
				active.set(logPath, new Watcher(logPath, cfg.quietPeriod, cfg.pollInterval, false, now));
			}
		}

		for (w in services)
			if (w.due(now)) w.tick(now);

		var finished = [];
		for (logPath => w in active) {
			if (w.due(now)) w.tick(now);
			if (w.done(now)) finished.push(logPath);
		}
		for (logPath in finished) {
			var res = active.get(logPath).result();
			completions.push({logPath: logPath, result: res});
			Util.say('DONE $logPath: ' + switch res {
				case Ok: "ok";
				case ErrorFinal: "ERROR-final";
				case Miss: "missed (no log activity in the window)";
			});
			if (res == ErrorFinal)
				Util.say('ALERT $logPath: cron job finished with error as the last entry');
			active.remove(logPath); // kill-self: nothing of the watch remains
			var cw = scheduled.get(logPath);
			if (cw != null) cw.nextFire = computeNext(cw.schedules, now);
		}
	}

	function rescan(now:Float):Void {
		lastRescan = now;
		var sig = signature();
		if (sig == dirSig) return; // mtime-gated: nothing changed
		dirSig = sig;

		var res = Cron.parseDir(cronDir);
		for (sk in res.skipped)
			Util.say('SKIP ${sk.srcFile}:${sk.srcLine}: ${sk.reason}');

		var fresh:Map<String, CronWatch> = new Map();
		for (e in res.entries) {
			var cw = fresh.get(e.logPath);
			if (cw == null)
				fresh.set(e.logPath, cw = {schedules: [], nextFire: 0, lockPath: e.lockPath, lockProbe: null});
			else if (cw.lockPath != e.lockPath)
				cw.lockPath = null; // disagreeing writers: always watch
			cw.schedules.push(e.schedule);
		}
		for (logPath => cw in fresh) {
			cw.nextFire = computeNext(cw.schedules, now);
			if (!scheduled.exists(logPath))
				Util.say('SCHEDULE $logPath: ' + cw.schedules.join(" | ")
					+ (cw.lockPath != null ? ' (flock ${cw.lockPath})' : ''));
		}
		// removed entries lose their pending activation here; an already
		// active watch is intentionally left to finish its window
		scheduled = fresh;

		if (firstScan) {
			firstScan = false;
			// restart mid-window: a recently written log is watched now
			for (logPath => cw in scheduled)
				if (!active.exists(logPath) && FileSystem.exists(logPath)) {
					var mtime = FileSystem.stat(logPath).mtime.getTime() / 1000.;
					if (now - mtime <= cfg.quietPeriod) {
						Util.say('WATCH $logPath: activated (mid-window at startup)');
						active.set(logPath, new Watcher(logPath, cfg.quietPeriod, cfg.pollInterval, false, now));
					}
				}
		}
	}

	function computeNext(schedules:Array<String>, now:Float):Float {
		var best = Math.POSITIVE_INFINITY;
		for (expr in schedules) {
			var d = Cron.nextFire(expr, Date.fromTime(now * 1000.));
			if (d != null && d.getTime() / 1000. < best) best = d.getTime() / 1000.;
		}
		return best;
	}

	function signature():String {
		if (!FileSystem.exists(cronDir)) return "";
		var names = FileSystem.readDirectory(cronDir);
		names.sort(Reflect.compare);
		var parts = [];
		for (n in names) {
			if (n.indexOf(".") >= 0) continue;
			var p = cronDir + "/" + n;
			if (FileSystem.isDirectory(p)) continue;
			parts.push(n + ":" + FileSystem.stat(p).mtime.getTime());
		}
		return parts.join("|");
	}

	public function run():Void {
		while (true) {
			tick(Sys.time());
			Sys.sleep(0.25);
		}
	}
}

import LogTail.TailState;

enum CronResult {
	Ok; // completed, last entry not error
	ErrorFinal; // completed with error as the last entry -> alert
	Miss; // log never produced content during the window
}

// One watched log. Service mode (live=true) reports ALERT/CLEAR transitions
// continuously; cron mode is driven by the supervisor via done()/result().
class Watcher {
	public var path(default, null):String;
	public var alerted(default, null):Bool = false;
	public var sawContent(default, null):Bool = false;

	var st:TailState;
	var quietPeriod:Float;
	var pollInterval:Float;
	var live:Bool;
	var activatedAt:Float;
	var lastPollAt:Float = Math.NEGATIVE_INFINITY;

	public function new(path:String, quietPeriod:Float, pollInterval:Float, live:Bool, activatedAt:Float) {
		this.path = path;
		this.quietPeriod = quietPeriod;
		this.pollInterval = pollInterval;
		this.live = live;
		this.activatedAt = activatedAt;
		st = LogTail.newState();
	}

	public function due(now:Float):Bool
		return now - lastPollAt >= pollInterval;

	public function tick(now:Float):Void {
		lastPollAt = now;
		var r = LogTail.poll(path, st, now);
		if (r.newLines > 0) sawContent = true;
		if (!live) return;
		// the alert rule (README): last entry is error and nothing follows
		if (!alerted && sawContent && st.lastLevel == "error"
			&& now - st.lastNewLineAt >= quietPeriod) {
			alerted = true;
			Util.say('ALERT $path: last entry is error, quiet for ${quietPeriod}s');
		} else if (alerted && st.lastLevel != "error") {
			alerted = false;
			Util.say('CLEAR $path: new ${st.lastLevel} entries arrived');
		}
	}

	// cron mode: the job is judged complete after a quiet period — from the
	// last write if the log produced content, else from activation (a miss)
	public function done(now:Float):Bool
		return sawContent
			? now - st.lastNewLineAt >= quietPeriod
			: now - activatedAt >= quietPeriod;

	public function result():CronResult
		return !sawContent ? Miss : (st.lastLevel == "error" ? ErrorFinal : Ok);

	public function lastLevel():String
		return st.lastLevel;
}

import sys.FileSystem;
import sys.io.File;

typedef CronEntry = {
	var schedule:String; // 5-field expression, aliases expanded
	var user:String;
	var command:String; // verbatim, redirections included
	var logPath:String;
	var lockPath:Null<String>; // flock lock file, null for un-flocked commands
	var srcFile:String;
	var srcLine:Int;
}

typedef Skipped = {
	var srcFile:String;
	var srcLine:Int;
	var reason:String;
}

typedef ParseResult = {
	var entries:Array<CronEntry>;
	var skipped:Array<Skipped>;
}

private typedef Fields = {
	var minute:Array<Bool>;
	var hour:Array<Bool>;
	var dom:Array<Bool>;
	var month:Array<Bool>;
	var dow:Array<Bool>;
	var domR:Bool;
	var dowR:Bool;
}

// Read-only parser for a cron.d-format directory (plan 03). The directory
// is always a parameter so tests and demos run on fixtures without root.
class Cron {
	static var aliases = [
		"@hourly" => "0 * * * *",
		"@daily" => "0 0 * * *", "@midnight" => "0 0 * * *",
		"@weekly" => "0 0 * * 0",
		"@monthly" => "0 0 1 * *",
		"@yearly" => "0 0 1 1 *", "@annually" => "0 0 1 1 *",
	];
	static var monthNames = [
		"jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4, "may" => 5, "jun" => 6,
		"jul" => 7, "aug" => 8, "sep" => 9, "oct" => 10, "nov" => 11, "dec" => 12,
	];
	static var dowNames = [
		"sun" => 0, "mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6,
	];
	static var ws = ~/\s+/g;
	static var envLine = ~/^[A-Za-z_][A-Za-z0-9_]*\s*=/;
	static var redirect = ~/(&>>|&>|2>>|2>|>>|>)\s*(\S+)/;

	public static function parseDir(dir:String):ParseResult {
		var res = {entries: [], skipped: []};
		if (!FileSystem.exists(dir)) return res;
		var names = FileSystem.readDirectory(dir);
		names.sort(Reflect.compare);
		for (name in names) {
			if (name.indexOf(".") >= 0) continue; // cron ignores dotted names
			var path = dir + "/" + name;
			if (FileSystem.isDirectory(path)) continue;
			parseFile(path, res);
		}
		return res;
	}

	static function parseFile(path:String, res:ParseResult):Void {
		var content = try File.getContent(path) catch (e:Dynamic) {
			res.skipped.push({srcFile: path, srcLine: 0, reason: "unreadable"});
			return;
		}
		var lineNo = 0;
		for (raw in content.split("\n")) {
			lineNo++;
			var line = StringTools.trim(raw);
			if (line == "" || StringTools.startsWith(line, "#")) continue;
			if (envLine.match(line)) continue;
			parseJob(line, path, lineNo, res);
		}
	}

	static function parseJob(line:String, srcFile:String, srcLine:Int, res:ParseResult):Void {
		function skip(reason:String)
			res.skipped.push({srcFile: srcFile, srcLine: srcLine, reason: reason});

		var tokens = ws.split(line);
		var schedule:String;
		var rest:Array<String>;
		if (StringTools.startsWith(tokens[0], "@")) {
			if (tokens[0] == "@reboot") return skip("@reboot out of scope");
			var expanded = aliases.get(tokens[0]);
			if (expanded == null) return skip("unknown alias " + tokens[0]);
			schedule = expanded;
			rest = tokens.slice(1);
		} else {
			if (tokens.length < 7) return skip("malformed: too few fields");
			schedule = tokens.slice(0, 5).join(" ");
			rest = tokens.slice(5);
		}
		if (parseExpr(schedule) == null) return skip("malformed schedule: " + schedule);
		if (rest.length < 2) return skip("malformed: missing command");
		var command = rest.slice(1).join(" ");
		var logPath = findLog(command);
		if (logPath == null) return skip("not watchable (no plain .log redirection)");
		res.entries.push({
			schedule: schedule, user: rest[0], command: command,
			logPath: logPath, lockPath: findLock(command),
			srcFile: srcFile, srcLine: srcLine,
		});
	}

	// The log path is the first redirection target that is a plain .log path
	// (plan 03 watchability convention: no $VARs, no pipes).
	static function findLog(command:String):Null<String> {
		var s = command;
		while (redirect.match(s)) {
			var target = redirect.matched(2);
			if (StringTools.endsWith(target, ".log") && target.indexOf("$") < 0)
				return target;
			s = redirect.matchedRight();
		}
		return null;
	}

	// A flock-wrapped command notes its lock file: the lock path is the
	// first absolute path after `flock`, before any -c (no flock option
	// takes an absolute-path value, so e.g. `-w 600` is skipped naturally).
	static function findLock(command:String):Null<String> {
		var tokens = ws.split(command);
		if (tokens[0] != "flock" && !StringTools.endsWith(tokens[0], "/flock"))
			return null;
		for (i in 1...tokens.length) {
			if (tokens[i] == "-c") break;
			if (StringTools.startsWith(tokens[i], "/")) return tokens[i];
		}
		return null;
	}

	// Next fire time strictly after `from`, or null if none within a year
	// (also null for an invalid expression).
	public static function nextFire(expr:String, from:Date):Null<Date> {
		var f = parseExpr(expr);
		if (f == null) return null;
		var t = Math.ffloor(from.getTime() / 60000.) * 60000. + 60000.;
		var limit = t + 366. * 24 * 3600 * 1000;
		while (t < limit) {
			var d = Date.fromTime(t);
			if (!f.month[d.getMonth() + 1]) { t += 86400000.; continue; }
			var dayOk = (f.domR && f.dowR)
				? (f.dom[d.getDate()] || f.dow[d.getDay()]) // vixie OR quirk
				: (f.dom[d.getDate()] && f.dow[d.getDay()]);
			if (!dayOk || !f.hour[d.getHours()]) {
				t = Math.ffloor(t / 3600000.) * 3600000. + 3600000.; // next hour
				continue;
			}
			if (!f.minute[d.getMinutes()]) { t += 60000.; continue; }
			return d;
		}
		return null;
	}

	static function parseExpr(expr:String):Null<Fields> {
		var e = StringTools.trim(expr);
		if (StringTools.startsWith(e, "@")) {
			e = aliases.get(e);
			if (e == null) return null;
		}
		var p = ws.split(e);
		if (p.length != 5) return null;
		var minute = parseField(p[0], 0, 59, null);
		var hour = parseField(p[1], 0, 23, null);
		var dom = parseField(p[2], 1, 31, null);
		var month = parseField(p[3], 1, 12, monthNames);
		var dow = parseField(p[4], 0, 7, dowNames);
		if (minute == null || hour == null || dom == null || month == null || dow == null)
			return null;
		if (dow[7]) dow[0] = true; // 7 is Sunday too
		return {
			minute: minute, hour: hour, dom: dom, month: month, dow: dow,
			domR: p[2] != "*", dowR: p[4] != "*",
		};
	}

	static function parseField(spec:String, lo:Int, hi:Int, names:Map<String, Int>):Null<Array<Bool>> {
		var res = [for (_ in 0...hi + 1) false];
		for (part in spec.split(",")) {
			var step = 1;
			var range = part;
			var slash = part.indexOf("/");
			if (slash >= 0) {
				range = part.substr(0, slash);
				var s = Std.parseInt(part.substr(slash + 1));
				if (s == null || s < 1) return null;
				step = s;
			}
			var a:Null<Int>, b:Null<Int>;
			if (range == "*") {
				a = lo; b = hi;
			} else {
				var dash = range.indexOf("-");
				if (dash >= 0) {
					a = value(range.substr(0, dash), names);
					b = value(range.substr(dash + 1), names);
				} else {
					a = value(range, names);
					b = slash >= 0 ? hi : a; // "n/step" means "n-hi/step"
				}
			}
			if (a == null || b == null) return null;
			var ai:Int = a, bi:Int = b;
			if (ai < lo || bi > hi || ai > bi) return null;
			var v = ai;
			while (v <= bi) { res[v] = true; v += step; }
		}
		return res;
	}

	static function value(tok:String, names:Map<String, Int>):Null<Int> {
		var n = Std.parseInt(tok);
		if (n != null) return n;
		if (names == null) return null;
		return names.get(tok.toLowerCase().substr(0, 3));
	}
}

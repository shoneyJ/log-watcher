import sys.FileSystem;
import sys.io.FileSeek;

typedef ToolOut = { isError:Bool, text:String }

// The MCP tool layer: plain functions over Cron.parseDir + the log
// allowlist. Read-only; every probe degrades to "not running" on
// ambiguity (same safe direction as Flock.held).
class Tools {
	var cronDir:String;
	var extraLogs:Array<String>;

	public function new(cronDir:String, extraLogs:Array<String>) {
		this.cronDir = cronDir;
		this.extraLogs = extraLogs;
	}

	static function out(text:String):ToolOut return {isError: false, text: text};
	static function err(text:String):ToolOut return {isError: true, text: text};

	// Log lines can carry ANSI color sequences and stray control bytes;
	// haxe.Json.stringify does not escape C0 chars, so they would produce
	// invalid JSON at the client. Strip sequences, drop other C0 (tab stays).
	static var ansi = ~/\x1B\[[0-9;]*[A-Za-z]/g;

	public static function sanitize(line:String):String {
		var s = ansi.replace(line, "");
		var buf = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			if (c >= 32 || c == 9) buf.addChar(c);
		}
		return buf.toString();
	}

	public static inline var TAIL_DEFAULT = 20;
	public static inline var TAIL_MAX = 200;
	public static inline var SEARCH_CAP = 4194304; // last 4 MiB only
	public static inline var SEARCH_MAX_DEFAULT = 20;
	public static inline var SEARCH_MAX_CAP = 100;

	public function allowedPaths():Array<String> {
		var seen = new Map<String, Bool>();
		var res = [];
		for (e in Cron.parseDir(cronDir).entries)
			if (!seen.exists(e.logPath)) { seen.set(e.logPath, true); res.push(e.logPath); }
		for (p in extraLogs)
			if (!seen.exists(p)) { seen.set(p, true); res.push(p); }
		return res;
	}

	// needle for the un-flocked liveness probe: the command's first
	// /-starting token (the script path), else its first token.
	static function needle(command:String):String {
		var tokens = ~/\s+/g.split(command);
		for (t in tokens) if (StringTools.startsWith(t, "/")) return t;
		return tokens[0];
	}

	public function getRunningCrons(now:Date):ToolOut {
		var rows = [];
		for (e in Cron.parseDir(cronDir).entries) {
			var nf = Cron.nextFire(e.schedule, now);
			rows.push({
				schedule: e.schedule,
				command: e.command,
				logPath: e.logPath,
				nextFire: nf == null ? null : nf.toString(),
				running: e.lockPath != null ? Flock.held(e.lockPath) : Pgrep.alive(needle(e.command)),
			});
		}
		return out(haxe.Json.stringify(rows));
	}

	public function listLogs():ToolOut {
		var cron = new Map<String, Bool>();
		for (e in Cron.parseDir(cronDir).entries) cron.set(e.logPath, true);
		var rows = [];
		for (p in allowedPaths()) {
			var exists = FileSystem.exists(p);
			var st = exists ? FileSystem.stat(p) : null;
			rows.push({
				path: p,
				sizeBytes: exists ? (st.size : Null<Int>) : null,
				mtime: exists ? (st.mtime.getTime() / 1000. : Null<Float>) : null,
				source: cron.exists(p) ? "cron" : "config",
			});
		}
		return out(haxe.Json.stringify(rows));
	}

	function checkPath(path:String):Null<ToolOut> {
		if (allowedPaths().indexOf(path) >= 0) return null;
		return err('unknown log path: $path — known logs: ' + allowedPaths().join(", "));
	}

	public function tailLog(path:String, lines:Null<Int>):ToolOut {
		var bad = checkPath(path);
		if (bad != null) return bad;
		var n = lines == null ? TAIL_DEFAULT : (lines > TAIL_MAX ? TAIL_MAX : (lines < 1 ? 1 : lines));
		var got = LogTail.lastLines(path, n);
		if (got == null) return err('log file missing: $path');
		return out(haxe.Json.stringify([for (l in got) sanitize(l)]));
	}

	public function searchLog(path:String, pattern:String, maxMatches:Null<Int>):ToolOut {
		var bad = checkPath(path);
		if (bad != null) return bad;
		if (pattern == null || pattern == "") return err("empty pattern");
		if (!FileSystem.exists(path)) return err('log file missing: $path');
		var cap = maxMatches == null ? SEARCH_MAX_DEFAULT
			: (maxMatches > SEARCH_MAX_CAP ? SEARCH_MAX_CAP : (maxMatches < 1 ? 1 : maxMatches));
		var size:Int = FileSystem.stat(path).size;
		var start = size > SEARCH_CAP ? size - SEARCH_CAP : 0;
		var lc = pattern.toLowerCase();
		var matches = []; // collected oldest->newest, reversed at the end
		var fi = sys.io.File.read(path, true);
		var offset = start;
		var carry = ""; // partial line across chunk boundary
		try {
			fi.seek(start, FileSeek.SeekBegin);
			while (offset < size) {
				var want = size - offset > LogTail.CHUNK ? LogTail.CHUNK : size - offset;
				var buf = haxe.io.Bytes.alloc(want);
				var got = fi.readBytes(buf, 0, want);
				if (got <= 0) break;
				var text = carry + buf.getString(0, got);
				var lines = text.split("\n");
				carry = lines.pop(); // last piece has no newline yet
				for (line in lines)
					if (line.toLowerCase().indexOf(lc) >= 0)
						matches.push({byteOffset: offset, line: sanitize(line)});
				offset += got;
			}
		} catch (e:haxe.io.Eof) {}
		fi.close();
		matches.reverse(); // newest first
		if (matches.length > cap) matches = matches.slice(0, cap);
		return out(haxe.Json.stringify({
			matches: matches,
			searchedBytes: size - start,
			note: start > 0 ? "searched last 4 MiB only" : "searched whole file",
		}));
	}
}

import sys.FileSystem;
import sys.io.File;
import sys.io.FileSeek;
import haxe.io.Bytes;

typedef TailState = {
	var offset:Int; // next read position (just past the last complete line)
	var ino:Int; // inode at last poll, -1 before first sight
	var lastLevel:String; // level of the last complete entry, "" if none yet
	var lastNewLineAt:Float; // clock (seconds) when complete lines last arrived
}

typedef PollResult = {
	var exists:Bool;
	var newLines:Int;
	var bytesRead:Int;
}

// One poll = read at most CHUNK new tail bytes, judge only complete lines
// (plan 02: never scan a file front to back; torn final line held back).
class LogTail {
	public static inline var CHUNK = 65536;

	public static function newState():TailState
		return {offset: 0, ino: -1, lastLevel: "", lastNewLineAt: 0.0};

	// `now` is injected so tests can drive synthetic time.
	public static function poll(path:String, st:TailState, now:Float):PollResult {
		if (!FileSystem.exists(path)) return {exists: false, newLines: 0, bytesRead: 0};
		var stat = FileSystem.stat(path);
		var size:Int = stat.size;
		if (st.ino == -1) {
			// first sight: start at most CHUNK before EOF; a partial first
			// line is read as a continuation, which is acceptable
			st.ino = stat.ino;
			st.offset = size > CHUNK ? size - CHUNK : 0;
		} else if (stat.ino != st.ino || size < st.offset) {
			// rotation (rename/recreate or truncate): restart from the top
			st.ino = stat.ino;
			st.offset = 0;
			st.lastLevel = "";
		}
		if (size - st.offset > CHUNK) st.offset = size - CHUNK; // burst: jump to tail
		if (size <= st.offset) return {exists: true, newLines: 0, bytesRead: 0};

		var len = size - st.offset;
		var buf = Bytes.alloc(len);
		var got = 0;
		var fi = File.read(path, true);
		try {
			fi.seek(st.offset, SeekBegin);
			got = fi.readBytes(buf, 0, len);
		} catch (e:haxe.io.Eof) {
			got = 0; // shrunk between stat and read; next poll re-syncs
		}
		fi.close();
		if (got <= 0) return {exists: true, newLines: 0, bytesRead: 0};

		// only complete lines count: cut at the last newline, hold the rest
		var nl = got - 1;
		while (nl >= 0 && buf.get(nl) != 10) nl--;
		if (nl < 0) return {exists: true, newLines: 0, bytesRead: got};

		var lines = buf.getString(0, nl + 1).split("\n");
		lines.pop(); // empty piece after the final newline
		st.offset += nl + 1;
		for (line in lines) {
			// relaxed rule (service-health): timestamped app logs must
			// classify too, or their errors never trip the alert rule
			var lv = classifyLoose(Tools.sanitize(line));
			if (lv != null) st.lastLevel = lv; // else continuation: inherits
		}
		if (lines.length > 0) st.lastNewLineAt = now;
		return {exists: true, newLines: lines.length, bytesRead: got};
	}

	public static function classify(line:String):Null<String> {
		if (StringTools.startsWith(line, "info")) return "info";
		if (StringTools.startsWith(line, "warn")) return "warn";
		if (StringTools.startsWith(line, "error")) return "error";
		return null;
	}

	// Real app logs put a timestamp first ("2026-07-22T15:40:00 - error: …");
	// the relaxed rule also accepts the level after a leading token. Callers
	// pass a sanitized line (Tools.sanitize) — ANSI codes hide the prefix.
	static var tsLevel = ~/^\S+\s+-\s+(info|warn|error)\b/;

	public static function classifyLoose(line:String):Null<String> {
		var lv = classify(line);
		if (lv != null) return lv;
		return tsLevel.match(line) ? tsLevel.matched(1) : null;
	}

	// Last <= n complete lines from the final CHUNK bytes of the file.
	// A cut-off first line is acceptable (same as first-sight poll); an
	// unterminated final line is dropped. Null when the file is missing.
	public static function lastLines(path:String, n:Int):Null<Array<String>> {
		if (!FileSystem.exists(path)) return null;
		var size:Int = FileSystem.stat(path).size;
		var start = size > CHUNK ? size - CHUNK : 0;
		var len = size - start;
		if (len <= 0) return [];
		var buf = Bytes.alloc(len);
		var got = 0;
		var fi = File.read(path, true);
		try {
			fi.seek(start, SeekBegin);
			got = fi.readBytes(buf, 0, len);
		} catch (e:haxe.io.Eof) { got = 0; }
		fi.close();
		if (got <= 0) return [];
		var nl = got - 1;
		while (nl >= 0 && buf.get(nl) != 10) nl--;
		if (nl < 0) return [];
		var lines = buf.getString(0, nl + 1).split("\n");
		lines.pop(); // empty piece after the final newline
		if (start > 0 && lines.length > 0) lines.shift(); // cut-off first line
		return lines.length > n ? lines.slice(lines.length - n) : lines;
	}
}

import sys.FileSystem;
import sys.io.File;
import sys.io.FileSeek;
import haxe.io.Bytes;
import Tools.ToolOut;

// Single-slot in-memory sqlite DB of recent log tails
// (feature-doc/minilog-db.md). load() replaces the slot wholesale; the DB
// dies with the process. sqlite is bundled statically by hxcpp — but does
// not exist on the interpreter, so tests are native-only.
class MiniLog {
	public static inline var MAX_DB_BYTES = 104857600; // 100 MiB total budget
	public static inline var QUERY_MAX_ROWS = 200;
	public static inline var QUERY_MAX_CHARS = 65536;

	var db:Null<sys.db.Connection> = null;

	public function new() {}

	public function loaded():Bool return db != null;


	public function load(paths:Array<String>, ?budget:Int):ToolOut {
		if (db != null) db.close();
		db = sys.db.Sqlite.open(":memory:");
		db.request("CREATE TABLE entries(
			id INTEGER PRIMARY KEY, path TEXT, seq INTEGER,
			level TEXT, body TEXT, byteOffset INTEGER)");
		db.request("CREATE INDEX idx_level ON entries(level)");

		var b = budget == null ? MAX_DB_BYTES : budget;
		var share = Std.int(b / paths.length);
		var files = [];
		var total = 0;
		var anyOk = false;
		db.request("BEGIN");
		for (p in paths) {
			var f = ingest(p, share);
			if (f.error == null) { anyOk = true; total += f.entries; }
			files.push(f);
		}
		db.request("COMMIT");
		if (!anyOk) {
			db.close();
			db = null;
			return {isError: true, text: "load_log_db: no file could be read: "
				+ haxe.Json.stringify(files)};
		}
		return {isError: false, text: haxe.Json.stringify({files: files, totalEntries: total})};
	}

	public function query(sql:String):ToolOut {
		if (db == null) return {isError: true, text: "no database loaded — call load_log_db first"};
		var s = StringTools.trim(sql);
		while (StringTools.endsWith(s, ";")) s = StringTools.trim(s.substr(0, s.length - 1));
		if (s.toLowerCase().indexOf("select") != 0)
			return {isError: true, text: "only a single SELECT statement is allowed"};
		if (s.indexOf(";") >= 0)
			return {isError: true, text: "multiple statements are not allowed"};
		var rs = try db.request(s) catch (e:Dynamic)
			return {isError: true, text: 'sql error: $e'};
		var rows:Array<Dynamic> = [];
		var chars = 0;
		var truncated = false;
		for (row in rs) {
			var enc = haxe.Json.stringify(row);
			if (rows.length >= QUERY_MAX_ROWS || chars + enc.length > QUERY_MAX_CHARS) {
				truncated = true;
				break;
			}
			chars += enc.length;
			rows.push(row);
		}
		return {isError: false, text: haxe.Json.stringify({rows: rows, truncated: truncated})};
	}

	function ingest(path:String, share:Int):Dynamic {
		if (!FileSystem.exists(path))
			return {path: path, bytesLoaded: 0, entries: 0, truncated: false, error: "missing"};
		var size:Int = try FileSystem.stat(path).size catch (e:Dynamic)
			return {path: path, bytesLoaded: 0, entries: 0, truncated: false, error: Std.string(e)};
		var start = size > share ? size - share : 0;
		var fi = try File.read(path, true) catch (e:Dynamic)
			return {path: path, bytesLoaded: 0, entries: 0, truncated: false, error: Std.string(e)};

		var seq = 0;
		var curLevel:Null<String> = null;
		var curBody:StringBuf = null;
		var curOffset = 0;
		var lineOffset = start;
		function flush() {
			if (curBody == null) return;
			seq++;
			db.request("INSERT INTO entries(path, seq, level, body, byteOffset) VALUES ("
				+ db.quote(path) + ", " + seq + ", " + db.quote(curLevel == null ? "" : curLevel)
				+ ", " + db.quote(curBody.toString()) + ", " + curOffset + ")");
			curBody = null;
		}

		var read = 0;
		var carry = "";
		var skippedFirst = start == 0; // nothing to skip when reading from the top
		try {
			fi.seek(start, SeekBegin);
			var offset = start;
			while (offset < size) {
				var want = size - offset > LogTail.CHUNK ? LogTail.CHUNK : size - offset;
				var buf = Bytes.alloc(want);
				var got = fi.readBytes(buf, 0, want);
				if (got <= 0) break;
				read += got;
				var text = carry + buf.getString(0, got);
				var lines = text.split("\n");
				carry = lines.pop(); // unterminated tail piece
				for (line in lines) {
					var atOffset = lineOffset;
					lineOffset += line.length + 1;
					if (!skippedFirst) { skippedFirst = true; continue; } // cut-off first line
					// offsets above use the raw length; only the clean copy is
					// classified and stored (ANSI would break level detection
					// and control bytes would break the JSON query output)
					var clean = Tools.sanitize(line);
					var lv = LogTail.classifyLoose(clean);
					if (lv != null) {
						flush();
						curLevel = lv;
						curOffset = atOffset;
						curBody = new StringBuf();
						curBody.add(clean);
					} else if (curBody != null) {
						curBody.add("\n");
						curBody.add(clean); // continuation folded into parent
					}
					// continuation before any prefixed entry: dropped
				}
				lineOffset = offset + got - carry.length;
				offset += got;
			}
		} catch (e:haxe.io.Eof) {}
		fi.close();
		flush(); // carry (torn final line) is intentionally dropped
		return {path: path, bytesLoaded: read, entries: seq, truncated: start > 0, error: null};
	}
}

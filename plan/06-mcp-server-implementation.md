# MCP Server + Minilog DB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `plan/feature-doc/mcp-server.md` + `plan/feature-doc/minilog-db.md` — a `Main mcp` subcommand serving six MCP tools over authenticated localhost HTTP, including a temporary in-memory sqlite database of recent log tails.

**Architecture:** New modules `src/Pgrep.hx` (process probe), `src/Tools.hx` (tool functions over `Cron.parseDir` + allowlist), `src/MiniLog.hx` (sqlite ingest + read-only query), `src/Mcp.hx` (JSON-RPC 2.0 / MCP subset with a pure `handle()` seam + thin socket loop). `src/LogTail.hx` gains `lastLines` and a public `classify`. `src/Main.hx` gains the subcommand.

**Tech Stack:** Haxe 4.3.x → hxcpp native binary. sqlite comes statically from hxcpp (`sys.db.Sqlite`) — zero external deps. Tests: plain asserts in `test/TestMain.hx`.

## Global Constraints

- **Zero dependencies**: Haxe stdlib only; no haxelib beyond hxcpp. No test framework.
- **Two-target tests**: `haxe test.hxml` (interpreter) AND `haxe test-native.hxml && ./bin/test/TestMain` (native). **Exception**: sqlite does not exist on the interpreter — MiniLog test groups and the socket smoke test are wrapped in `#if cpp … #end` and run native-only.
- **Never run `git commit` or `git push`** (repo rule). Each task's last step refreshes `.dev/commit.md` instead; the user commits manually.
- **Bounded reads only** (plan 02): never scan a 2 GB file front to back. Constants: `CHUNK = 65536` (exists), `MAX_DB_BYTES = 104857600` (100 MiB), `SEARCH_CAP = 4194304` (4 MiB), `QUERY_MAX_ROWS = 200`, `QUERY_MAX_CHARS = 65536`, `TAIL_DEFAULT = 20`, `TAIL_MAX = 200`, `SEARCH_MAX_DEFAULT = 20`, `SEARCH_MAX_CAP = 100`, `BODY_MAX = 65536`.
- **JSON assertions parse back** (`haxe.Json.parse`), never string-compare — anonymous-object field order differs between targets.
- Tests run from the repo root; scratch files under `test/tmp` (wiped by TestMain), fixtures under `test/fixtures/cron.d/`.
- Match existing style: tabs, `eq`/`ok` helpers, one test group function per area registered in `main()`.

---

### Task 1: Pgrep probe

**Files:**
- Create: `src/Pgrep.hx`
- Test: `test/TestMain.hx` (add `testPgrepProbe`, register in `main()` after `testFlockProbe()`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Pgrep.alive(needle:String):Bool` — exit 0 = running; 1 = no match; anything else (127 no pgrep, …) = unknown → `false`.

- [ ] **Step 1: Write the failing test**

Add to `test/TestMain.hx` (the holder mirrors `holdLock`: `readLine` brackets the start, closing stdin ends `cat` — no sleeps). The nonsense-needle check guards the self-match footgun (a wrapping shell's cmdline containing the needle):

```haxe
	// ---- Pgrep ----

	static function testPgrepProbe() {
		ok(!Pgrep.alive("no-such-needle-zx9q7"), "pgrep: nonsense needle not running");

		var marker = "pgrep-marker-zx9q7";
		var p = new sys.io.Process("bash", ["-c", 'echo ready; cat # $marker']);
		eq(p.stdout.readLine(), "ready", "pgrep holder: started");
		ok(Pgrep.alive(marker), "pgrep: marker process found");
		p.stdin.close();
		p.exitCode();
		p.close();
		ok(!Pgrep.alive(marker), "pgrep: gone after exit");
	}
```

Register in `main()`: `testPgrepProbe();` after `testFlockProbe();`.

- [ ] **Step 2: Run test to verify it fails**

Run: `haxe test.hxml`
Expected: compile error `Type not found : Pgrep`.

- [ ] **Step 3: Write minimal implementation**

Create `src/Pgrep.hx` — `sys.io.Process` execs argv directly (no wrapping shell, so the probe's own command line never contains the needle):

```haxe
// pgrep(1) probe: is any process whose command line contains `needle`
// alive? Exit 0 = yes; 1 = no; anything else (127 no pgrep, ...) =
// unknown -> report not running, the same safe direction as Flock.held.
class Pgrep {
	public static function alive(needle:String):Bool {
		var p = try new sys.io.Process("pgrep", ["-f", "--", needle])
			catch (e:Dynamic) return false;
		var code = p.exitCode();
		p.close();
		return code == 0;
	}
}
```

- [ ] **Step 4: Run tests on both targets**

Run: `haxe test.hxml && haxe test-native.hxml && ./bin/test/TestMain`
Expected: PASS, 0 failures (baseline suite + 4 new checks).

- [ ] **Step 5: Refresh .dev/commit.md**

Start a fresh message (subject `feat: MCP server with minilog DB (plans feature-doc/mcp-server, minilog-db)`) and note: `src/Pgrep.hx` — pgrep -f probe, argv exec, unknown→false. User commits manually.

---

### Task 2: LogTail.lastLines + public classify

**Files:**
- Modify: `src/LogTail.hx` (make `classify` public; add `lastLines`; `poll` untouched)
- Test: `test/TestMain.hx` (add `testLastLines`, register after `testTailSparse2GB()`)

**Interfaces:**
- Consumes: existing `LogTail.CHUNK`.
- Produces: `LogTail.classify(line:String):Null<String>` (public now); `LogTail.lastLines(path:String, n:Int):Null<Array<String>>` — null when the file is missing; last ≤ n complete newline-terminated lines from the final CHUNK bytes; torn final line dropped; a cut-off first line is acceptable.

- [ ] **Step 1: Write the failing test**

```haxe
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `haxe test.hxml`
Expected: compile error `lastLines` not found on `LogTail`.

- [ ] **Step 3: Implement**

In `src/LogTail.hx`: change `static function classify` to `public static function classify` (only the keyword). Append below `classify`:

```haxe
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
```

- [ ] **Step 4: Run tests on both targets**

Run: `haxe test.hxml && haxe test-native.hxml && ./bin/test/TestMain`
Expected: PASS, 0 failures.

- [ ] **Step 5: Refresh .dev/commit.md**

Add: `src/LogTail.hx` — public classify; lastLines (CHUNK-bounded tail lines).

---

### Task 3: Tools — allowlist, list_logs, get_running_crons

**Files:**
- Create: `src/Tools.hx`
- Test: `test/TestMain.hx` (add `testToolsListing`, register after `testPgrepProbe()`)

**Interfaces:**
- Consumes: `Cron.parseDir(dir).entries` (`CronEntry`: `schedule`, `command`, `logPath`, `lockPath`), `Cron.nextFire(expr, from)`, `Flock.held(path)`, `Pgrep.alive(needle)`.
- Produces:

```haxe
typedef ToolOut = { isError:Bool, text:String }
class Tools {
	public function new(cronDir:String, extraLogs:Array<String>)
	public function allowedPaths():Array<String>            // cron logPaths ∪ extraLogs, deduped, order stable
	public function getRunningCrons(now:Date):ToolOut       // JSON array text
	public function listLogs():ToolOut                      // JSON array text
	// tailLog/searchLog arrive in Task 4
}
```

- [ ] **Step 1: Write the failing test**

Uses the supervisor-test pattern: a generated cron dir under `test/tmp`, a real flock holder, and a marker process whose cmdline contains the entry's script path.

```haxe
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
		var mp = new sys.io.Process("bash", ["-c", "echo ready; cat # /bin/marker-zq31.sh"]);
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `haxe test.hxml`
Expected: compile error `Type not found : Tools`.

- [ ] **Step 3: Implement**

Create `src/Tools.hx`:

```haxe
import sys.FileSystem;

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
}
```

- [ ] **Step 4: Run tests on both targets**

Run: `haxe test.hxml && haxe test-native.hxml && ./bin/test/TestMain`
Expected: PASS, 0 failures.

- [ ] **Step 5: Refresh .dev/commit.md**

Add: `src/Tools.hx` — allowlist, get_running_crons (flock/pgrep liveness + nextFire), list_logs.

---

### Task 4: Tools — tail_log, search_log

**Files:**
- Modify: `src/Tools.hx`
- Test: `test/TestMain.hx` (add `testToolsTailSearch`, register after `testToolsListing()`)

**Interfaces:**
- Consumes: `LogTail.lastLines` (Task 2), `allowedPaths()` (Task 3).
- Produces:

```haxe
public function tailLog(path:String, lines:Null<Int>):ToolOut     // default 20, cap 200
public function searchLog(path:String, pattern:String, maxMatches:Null<Int>):ToolOut // default 20, cap 100
```

- [ ] **Step 1: Write the failing test**

```haxe
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
	}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `haxe test.hxml`
Expected: compile error `tailLog` not found.

- [ ] **Step 3: Implement**

Add to `src/Tools.hx` (inside the class):

```haxe
	public static inline var TAIL_DEFAULT = 20;
	public static inline var TAIL_MAX = 200;
	public static inline var SEARCH_CAP = 4194304; // last 4 MiB only
	public static inline var SEARCH_MAX_DEFAULT = 20;
	public static inline var SEARCH_MAX_CAP = 100;

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
		return out(haxe.Json.stringify(got));
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
			fi.seek(start, SeekBegin);
			while (offset < size) {
				var want = size - offset > LogTail.CHUNK ? LogTail.CHUNK : size - offset;
				var buf = haxe.io.Bytes.alloc(want);
				var got = fi.readBytes(buf, 0, want);
				if (got <= 0) break;
				var text = carry + buf.getString(0, got);
				var lines = text.split("\n");
				carry = lines.pop(); // last piece has no newline yet
				var lineStart = offset - carry.length; // approximation base
				for (line in lines)
					if (line.toLowerCase().indexOf(lc) >= 0)
						matches.push({byteOffset: offset, line: line});
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
```

Note: `byteOffset` is the containing chunk's start offset — good enough to locate the region; the spec's per-entry exact offsets live in the minilog DB, not here. Delete the unused `lineStart` variable if the compiler warns.

- [ ] **Step 4: Run tests on both targets**

Run: `haxe test.hxml && haxe test-native.hxml && ./bin/test/TestMain`
Expected: PASS, 0 failures.

- [ ] **Step 5: Refresh .dev/commit.md**

Add: tail_log + search_log (allowlist-guarded, bounded, case-insensitive substring).

---

### Task 5: Mcp.handle — auth, JSON-RPC envelope, initialize/ping/tools-list

**Files:**
- Create: `src/Mcp.hx`
- Test: `test/TestMain.hx` (add `testMcpEnvelope`, register after `testToolsTailSearch()`)

**Interfaces:**
- Consumes: `Tools` (Task 3/4). MiniLog arrives Task 7 — `Mcp` takes it as `Null<MiniLog>` from day one? **No** — to keep this task self-contained, `Mcp.new(tools:Tools, apiKey:String)`; Task 9 adds the MiniLog parameter.
- Produces:

```haxe
typedef HttpReq = { method:String, path:String, headers:Map<String,String>, body:String }
typedef HttpResp = { status:Int, body:String } // body "" for 202; content-type application/json otherwise
class Mcp {
	public static inline var PROTOCOL = "2025-03-26";
	public static inline var BODY_MAX = 65536;
	public function new(tools:Tools, apiKey:String)
	public function handle(req:HttpReq):HttpResp
}
```

JSON-RPC rules implemented here: auth first (401), POST-only (405), `/mcp` only (404), body cap (413), parse error (-32700), missing `method` (-32600), unknown method (-32601), notification (no `id`) → 202 empty. JSON-RPC errors ride HTTP 200.

- [ ] **Step 1: Write the failing test**

```haxe
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
		var m = new Mcp(new Tools(dir, []), "sekrit");

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
		eq(tl.length, 4, "mcp: four tools listed (six after minilog)");
		var names = [for (t in (tl : Array<Dynamic>)) (t.name : String)].join(",");
		ok(names.indexOf("get_running_crons") >= 0, "mcp: get_running_crons listed");
		ok(names.indexOf("list_logs") >= 0, "mcp: list_logs listed");
		ok(names.indexOf("tail_log") >= 0, "mcp: tail_log listed");
		ok(names.indexOf("search_log") >= 0, "mcp: search_log listed");

		eq(mcpReq(m, "{not json").json.error.code, -32700, "mcp: parse error");
		eq(mcpReq(m, haxe.Json.stringify({jsonrpc: "2.0", id: 2})).json.error.code, -32600, "mcp: no method");
		eq(mcpReq(m, rpc("bogus/method")).json.error.code, -32601, "mcp: unknown method");
	}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `haxe test.hxml`
Expected: compile error `Type not found : Mcp`.

- [ ] **Step 3: Implement**

Create `src/Mcp.hx`:

```haxe
typedef HttpReq = { method:String, path:String, headers:Map<String, String>, body:String }
typedef HttpResp = { status:Int, body:String }

// MCP over Streamable HTTP, hand-rolled subset (feature-doc/mcp-server.md):
// stateless, tools-only, no SSE, no sessions. handle() is a pure function
// so the whole protocol is testable without sockets.
class Mcp {
	public static inline var PROTOCOL = "2025-03-26";
	public static inline var BODY_MAX = 65536;

	var tools:Tools;
	var apiKey:String;

	public function new(tools:Tools, apiKey:String) {
		this.tools = tools;
		this.apiKey = apiKey;
	}

	public function handle(req:HttpReq):HttpResp {
		if (req.headers.get("authorization") != "Bearer " + apiKey)
			return {status: 401, body: haxe.Json.stringify({error: "unauthorized"})};
		if (req.method != "POST") return {status: 405, body: haxe.Json.stringify({error: "POST only"})};
		if (req.path != "/mcp") return {status: 404, body: haxe.Json.stringify({error: "not found"})};
		if (req.body.length > BODY_MAX) return {status: 413, body: haxe.Json.stringify({error: "body too large"})};

		var j:Dynamic = try haxe.Json.parse(req.body) catch (e:Dynamic)
			return rpcError(null, -32700, "parse error");
		var id:Dynamic = j.id;
		var method:String = j.method;
		if (method == null) return rpcError(id, -32600, "invalid request: no method");
		if (id == null) return {status: 202, body: ""}; // notification

		return switch (method) {
			case "initialize": result(id, {
					protocolVersion: PROTOCOL,
					capabilities: {tools: {}},
					serverInfo: {name: "log-watcher", version: "0.1"},
				});
			case "ping": result(id, {});
			case "tools/list": result(id, {tools: toolSchemas()});
			case "tools/call": callTool(id, j.params);
			default: rpcError(id, -32601, 'unknown method: $method');
		}
	}

	function result(id:Dynamic, res:Dynamic):HttpResp
		return {status: 200, body: haxe.Json.stringify({jsonrpc: "2.0", id: id, result: res})};

	function rpcError(id:Dynamic, code:Int, message:String):HttpResp
		return {status: 200, body: haxe.Json.stringify({jsonrpc: "2.0", id: id, error: {code: code, message: message}})};

	// Task 6 replaces this stub with real dispatch.
	function callTool(id:Dynamic, params:Dynamic):HttpResp
		return rpcError(id, -32601, "tools/call not wired yet");

	function toolSchemas():Array<Dynamic> {
		return [
			{name: "get_running_crons",
				description: "List cron.d entries with schedule, command, log path, next fire time, and whether each is running right now.",
				inputSchema: {type: "object", properties: {}}},
			{name: "list_logs",
				description: "List the known log files (path, size, mtime, source).",
				inputSchema: {type: "object", properties: {}}},
			{name: "tail_log",
				description: "Last N complete lines of a known log file.",
				inputSchema: {type: "object", properties: {
					path: {type: "string", description: "log path from list_logs"},
					lines: {type: "integer", description: "default 20, max 200"},
				}, required: ["path"]}},
			{name: "search_log",
				description: "Case-insensitive substring search over the recent tail (last 4 MiB) of a known log file, newest matches first.",
				inputSchema: {type: "object", properties: {
					path: {type: "string", description: "log path from list_logs"},
					pattern: {type: "string"},
					maxMatches: {type: "integer", description: "default 20, max 100"},
				}, required: ["path", "pattern"]}},
		];
	}
}
```

- [ ] **Step 4: Run tests on both targets**

Run: `haxe test.hxml && haxe test-native.hxml && ./bin/test/TestMain`
Expected: PASS, 0 failures.

- [ ] **Step 5: Refresh .dev/commit.md**

Add: `src/Mcp.hx` — JSON-RPC/MCP envelope, auth-first, pure handle() seam.

---

### Task 6: Mcp tools/call dispatch (four tools)

**Files:**
- Modify: `src/Mcp.hx` (replace the `callTool` stub)
- Test: `test/TestMain.hx` (add `testMcpToolCalls`, register after `testMcpEnvelope()`)

**Interfaces:**
- Consumes: `Tools.getRunningCrons/listLogs/tailLog/searchLog` (`ToolOut`).
- Produces: MCP `tools/call` results: `{content: [{type: "text", text: ...}], isError: bool}`. Unknown tool name and malformed arguments are `isError: true` results (model-recoverable), not protocol errors.

- [ ] **Step 1: Write the failing test**

```haxe
	static function testMcpToolCalls() {
		var dir = '$TMP/mcpc-cron.d';
		FileSystem.createDirectory(dir);
		var log = root + 'test/tmp/mcpc.log';
		File.saveContent('$dir/jobs', '* * * * * shoney /bin/x.sh >> $log 2>&1\n');
		append(log, "info alpha\nerror beta\n");
		var m = new Mcp(new Tools(dir, []), "sekrit");

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `haxe test.hxml`
Expected: FAIL — `call: list_logs ok` etc. hit the `tools/call not wired yet` stub (isError path differs: the stub returns a -32601 protocol error, so `.result` is null → test fails).

- [ ] **Step 3: Implement**

Replace the `callTool` stub in `src/Mcp.hx`:

```haxe
	function callTool(id:Dynamic, params:Dynamic):HttpResp {
		if (params == null || params.name == null)
			return rpcError(id, -32600, "tools/call: missing params.name");
		var args:Dynamic = params.arguments == null ? {} : params.arguments;
		var o:ToolOut = try switch ((params.name : String)) {
			case "get_running_crons": tools.getRunningCrons(Date.now());
			case "list_logs": tools.listLogs();
			case "tail_log":
				args.path == null ? {isError: true, text: "tail_log: path is required"}
					: tools.tailLog(args.path, args.lines);
			case "search_log":
				(args.path == null || args.pattern == null)
					? {isError: true, text: "search_log: path and pattern are required"}
					: tools.searchLog(args.path, args.pattern, args.maxMatches);
			case other: {isError: true, text: 'unknown tool: $other'};
		} catch (e:Dynamic) {isError: true, text: 'tool failed: $e'};
		return result(id, {content: [{type: "text", text: o.text}], isError: o.isError});
	}
```

- [ ] **Step 4: Run tests on both targets**

Run: `haxe test.hxml && haxe test-native.hxml && ./bin/test/TestMain`
Expected: PASS, 0 failures.

- [ ] **Step 5: Refresh .dev/commit.md**

Add: tools/call dispatch, isError convention for model-recoverable failures.

---

### Task 7: MiniLog — sqlite ingest (native-only tests)

**Files:**
- Create: `src/MiniLog.hx`
- Test: `test/TestMain.hx` (add `testMiniLogLoad` wrapped in `#if cpp`, register in `main()` inside `#if cpp` after the MCP groups)

**Interfaces:**
- Consumes: `LogTail.classify`, `LogTail.CHUNK`.
- Produces:

```haxe
class MiniLog {
	public static inline var MAX_DB_BYTES = 104857600;
	public static inline var QUERY_MAX_ROWS = 200;
	public static inline var QUERY_MAX_CHARS = 65536;
	public function new()
	public function loaded():Bool
	public function load(paths:Array<String>):ToolOut  // replaces the single :memory: slot
	// query() arrives in Task 8
}
```

Load report JSON: `{files: [{path, bytesLoaded, entries, truncated, error?}], totalEntries}`. Schema per spec: `entries(id INTEGER PRIMARY KEY, path TEXT, seq INTEGER, level TEXT, body TEXT, byteOffset INTEGER)` + `idx_level`.

- [ ] **Step 1: Write the failing test**

```haxe
#if cpp
	// ---- MiniLog (sqlite is native-only: the interpreter has no sys.db) ----

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
	}
#end
```

Note: this test calls `mini.query(...)` which lands in Task 8 — for THIS task, comment those five query lines out with `//` and re-enable them in Task 8 Step 1 (Task 8's step says so). The load-report assertions stand alone.

- [ ] **Step 2: Run test to verify it fails**

Run: `haxe test-native.hxml && ./bin/test/TestMain`
Expected: compile error `Type not found : MiniLog`.
Also run `haxe test.hxml` — must still PASS (group is `#if cpp`-guarded, interpreter unaffected).

- [ ] **Step 3: Implement**

Create `src/MiniLog.hx`:

```haxe
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

	public function load(paths:Array<String>):ToolOut {
		if (db != null) db.close();
		db = sys.db.Sqlite.open(":memory:");
		db.request("CREATE TABLE entries(
			id INTEGER PRIMARY KEY, path TEXT, seq INTEGER,
			level TEXT, body TEXT, byteOffset INTEGER)");
		db.request("CREATE INDEX idx_level ON entries(level)");

		var share = Std.int(MAX_DB_BYTES / paths.length);
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
					var lv = LogTail.classify(line);
					if (lv != null) {
						flush();
						curLevel = lv;
						curOffset = atOffset;
						curBody = new StringBuf();
						curBody.add(line);
					} else if (curBody != null) {
						curBody.add("\n");
						curBody.add(line); // continuation folded into parent
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
```

- [ ] **Step 4: Run tests**

Run: `haxe test.hxml` (interp — unaffected, PASS) and `haxe test-native.hxml && ./bin/test/TestMain`
Expected: native PASS with the load-report checks green (query checks still commented).

- [ ] **Step 5: Refresh .dev/commit.md**

Add: `src/MiniLog.hx` — single-slot :memory: sqlite, budget-split tail ingest, entry folding.

---

### Task 8: MiniLog — read-only query

**Files:**
- Modify: `src/MiniLog.hx`
- Test: `test/TestMain.hx` (re-enable the query lines in `testMiniLogLoad`; add `testMiniLogQuery` in the same `#if cpp` block)

**Interfaces:**
- Consumes: the loaded `db` from Task 7.
- Produces: `MiniLog.query(sql:String):ToolOut` — result JSON `{rows: [...], truncated: bool}`; guards: loaded, single SELECT, no mid-statement `;`; sqlite errors pass through as `isError` text.

- [ ] **Step 1: Write the failing test**

Re-enable the five commented `mini.query` lines in `testMiniLogLoad` (Task 7 Step 1), and add:

```haxe
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `haxe test-native.hxml && ./bin/test/TestMain`
Expected: compile error `query` not found on `MiniLog`.

- [ ] **Step 3: Implement**

Add to `src/MiniLog.hx`:

```haxe
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
```

- [ ] **Step 4: Run tests**

Run: `haxe test.hxml && haxe test-native.hxml && ./bin/test/TestMain`
Expected: PASS on both (interp skips the `#if cpp` groups).

- [ ] **Step 5: Refresh .dev/commit.md**

Add: read-only SELECT query with row/char caps and guard.

---

### Task 9: Mcp gains load_log_db / query_log_db (six tools)

**Files:**
- Modify: `src/Mcp.hx` (constructor takes MiniLog; two schemas; dispatch), `test/TestMain.hx`
- Test: update `new Mcp(...)` call sites from Tasks 5/6 to pass a MiniLog; add `testMcpMinilogTools` inside `#if cpp`; **move the `tools/list` count assertion from 4 to 6** in `testMcpEnvelope`.

**Interfaces:**
- Consumes: `MiniLog.load/query/loaded`, `Tools.allowedPaths`.
- Produces: `Mcp.new(tools:Tools, mini:MiniLog, apiKey:String)` — **breaking change to Task 5's constructor; update both existing test call sites in the same step.** New tools: `load_log_db {match}` (server-side case-insensitive substring against `allowedPaths()`), `query_log_db {sql}`.

- [ ] **Step 1: Write the failing test**

In `testMcpEnvelope` change the tools/list assertion to `eq(tl.length, 6, "mcp: six tools listed");` and add two name checks (`load_log_db`, `query_log_db`). Update the two constructors in `testMcpEnvelope`/`testMcpToolCalls` to `new Mcp(new Tools(dir, []), new MiniLog(), "sekrit")`. Add:

```haxe
#if cpp
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
#end
```

Register in `main()` inside the same `#if cpp` block as the MiniLog groups.

- [ ] **Step 2: Run test to verify it fails**

Run: `haxe test.hxml`
Expected: compile error — `Mcp.new` has two arguments, call sites pass three.

- [ ] **Step 3: Implement**

In `src/Mcp.hx`: add field `var mini:MiniLog;`, constructor becomes

```haxe
	public function new(tools:Tools, mini:MiniLog, apiKey:String) {
		this.tools = tools;
		this.mini = mini;
		this.apiKey = apiKey;
	}
```

Append two entries to `toolSchemas()`:

```haxe
			{name: "load_log_db",
				description: "Load the recent tails of all known logs whose path contains `match` (case-insensitive) into a temporary in-memory sqlite database (table `entries`: path, seq, level, body, byteOffset). Replaces any previously loaded database. 100 MiB total budget split across matched files.",
				inputSchema: {type: "object", properties: {
					match: {type: "string", description: "substring matched against known log paths"},
				}, required: ["match"]}},
			{name: "query_log_db",
				description: "Run one read-only SELECT against the loaded minilog database. Results capped at 200 rows / 64 KiB.",
				inputSchema: {type: "object", properties: {
					sql: {type: "string", description: "a single SELECT statement"},
				}, required: ["sql"]}},
```

Add two cases to `callTool`'s switch (before `case other`):

```haxe
			case "load_log_db":
				if (args.match == null) {isError: true, text: "load_log_db: match is required"};
				else {
					var hint = (args.match : String).toLowerCase();
					var hit = [for (p in tools.allowedPaths()) if (p.toLowerCase().indexOf(hint) >= 0) p];
					hit.length == 0
						? {isError: true, text: "no known log matches '" + args.match
							+ "' — known logs: " + tools.allowedPaths().join(", ")}
						: mini.load(hit);
				}
			case "query_log_db":
				args.sql == null ? {isError: true, text: "query_log_db: sql is required"}
					: mini.query(args.sql);
```

- [ ] **Step 4: Run tests on both targets**

Run: `haxe test.hxml && haxe test-native.hxml && ./bin/test/TestMain`
Expected: PASS on both.

- [ ] **Step 5: Refresh .dev/commit.md**

Add: load_log_db (hint matching) + query_log_db wired; six tools.

---

### Task 10: HTTP socket loop + `Main mcp` subcommand

**Files:**
- Modify: `src/Mcp.hx` (add `serve`), `src/Main.hx` (subcommand + config), `test/TestMain.hx` (add `testMcpSocket` in `#if cpp`)

**Interfaces:**
- Consumes: `Mcp.handle` (Task 5/9).
- Produces: `Mcp.serve(port:Int):Void` — blocking accept loop on 127.0.0.1, one request per connection. `Main mcp <cron.d-dir> <config.json>` — config keys `mcp.port`/`mcp.apiKey` (required) and `logs` (optional array), `services` reused into the allowlist.

- [ ] **Step 1: Write the failing test**

```haxe
#if cpp
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
```

Register inside the `#if cpp` block. (Fixed port 18990: the suite is the only listener on this box's test runs; a bind failure fails loud, not silent.)

- [ ] **Step 2: Run test to verify it fails**

Run: `haxe test-native.hxml && ./bin/test/TestMain`
Expected: compile error `serve` not found on `Mcp`.

- [ ] **Step 3: Implement serve()**

Add to `src/Mcp.hx`:

```haxe
	// Blocking accept loop: one HTTP request per connection, respond,
	// close. Localhost only. A bad request never kills the loop.
	public function serve(port:Int):Void {
		var srv = new sys.net.Socket();
		srv.bind(new sys.net.Host("127.0.0.1"), port);
		srv.listen(4);
		while (true) {
			var c = srv.accept();
			try {
				var resp = handle(readRequest(c));
				var body = resp.body;
				c.output.writeString('HTTP/1.1 ${resp.status} ${statusText(resp.status)}\r\n'
					+ "Content-Type: application/json\r\nConnection: close\r\n"
					+ 'Content-Length: ${body.length}\r\n\r\n' + body);
			} catch (e:Dynamic) {
				try c.output.writeString("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
				catch (_:Dynamic) {}
			}
			try c.close() catch (_:Dynamic) {}
		}
	}

	function readRequest(c:sys.net.Socket):HttpReq {
		var reqLine = StringTools.trim(c.input.readLine());
		var parts = reqLine.split(" ");
		var headers = new Map<String, String>();
		while (true) {
			var line = StringTools.trim(c.input.readLine());
			if (line == "") break;
			var colon = line.indexOf(":");
			if (colon > 0)
				headers.set(line.substr(0, colon).toLowerCase(), StringTools.trim(line.substr(colon + 1)));
		}
		var len = Std.parseInt(headers.get("content-length"));
		if (len == null || len < 0) len = 0;
		if (len > BODY_MAX + 1) len = BODY_MAX + 1; // read enough to trigger 413, no more
		var body = len == 0 ? "" : c.input.read(len).toString();
		return {method: parts[0], path: parts.length > 1 ? parts[1] : "/", headers: headers, body: body};
	}

	static function statusText(code:Int):String return switch (code) {
		case 200: "OK"; case 202: "Accepted"; case 400: "Bad Request";
		case 401: "Unauthorized"; case 404: "Not Found"; case 405: "Method Not Allowed";
		case 413: "Payload Too Large"; default: "Error";
	}
```

- [ ] **Step 4: Wire `Main mcp`**

In `src/Main.hx`, add before the final `else`:

```haxe
		} else if (args.length >= 3 && args[0] == "mcp") {
			var j:Dynamic = haxe.Json.parse(sys.io.File.getContent(args[2]));
			if (j.mcp == null || j.mcp.port == null || j.mcp.apiKey == null) {
				Sys.println("config error: mcp.port and mcp.apiKey are required");
				Sys.exit(1);
			}
			var extra:Array<String> = [];
			if (j.logs != null) for (p in (j.logs : Array<Dynamic>)) extra.push((p : String));
			if (j.services != null) for (s in (j.services : Array<Dynamic>))
				extra.push(Std.isOfType(s, String) ? (s : String) : (s.path : String));
			var mcp = new Mcp(new Tools(args[1], extra), new MiniLog(), (j.mcp.apiKey : String));
			Util.say('mcp server on 127.0.0.1:${j.mcp.port} (${args[1]})');
			mcp.serve((j.mcp.port : Int));
```

And extend the usage block:

```haxe
				Sys.println("  Main mcp <cron.d-dir> <config.json>                 MCP server (127.0.0.1, Bearer auth)");
```

- [ ] **Step 5: Run everything**

Run: `haxe test.hxml && haxe test-native.hxml && ./bin/test/TestMain && haxe build.hxml && ./bin/Main`
Expected: both suites PASS; `./bin/Main` shows the new usage line and exits 1.

- [ ] **Step 6: Refresh .dev/commit.md**

Add: serve() socket loop, Main mcp subcommand, config (mcp.port/apiKey required, logs allowlist).

---

### Task 11: Docs sync + manual verification

**Files:**
- Modify: `doc/features.md`, `doc/file-tree.md`, `doc/README.md`, `README.md`, `CLAUDE.md`, `plan/feature-doc/mcp-server.md`, `plan/feature-doc/minilog-db.md`, `.dev/commit.md`
- Create: `test/mcp-config.json`

**Interfaces:** none — documentation and manual verification.

- [ ] **Step 1: Commit-able demo config**

`test/mcp-config.json`:

```json
{
  "mcp": { "port": 8990, "apiKey": "dev-key-change-me" },
  "logs": []
}
```

- [ ] **Step 2: Manual protocol check with Claude Code**

Run `./bin/Main mcp test/fixtures/cron.d test/mcp-config.json`, then in another terminal:

```bash
claude mcp add --transport http cron-mcp http://127.0.0.1:8990/mcp \
  --header "Authorization: Bearer dev-key-change-me"
```

In a Claude Code session: ask "which cron jobs are running right now?" (expect a get_running_crons call listing the fixture entries), "load the failing log into the database and count entries per level" (expect load_log_db + query_log_db). Record the outcome in `plan/feature-doc/mcp-server.md` and `minilog-db.md` under a "Verified" line. llama.cpp client configuration: manual exercise per spec, record when done.

- [ ] **Step 3: Update docs**

- `doc/features.md`: new "MCP server — `src/Mcp.hx`, `src/Tools.hx`, `src/MiniLog.hx`, `src/Pgrep.hx`" section describing the six tools, auth, bounds, single-slot DB (as-built wording, matching the code).
- `doc/file-tree.md`: add the four new src files + `test/mcp-config.json`.
- `doc/README.md`: add MCP server to project facts + CLI list.
- `README.md`: add `./bin/Main mcp` to the run block.
- `CLAUDE.md`: add the mcp run command to Commands.
- Both feature-doc specs: status → implemented (with date), Verified lines from Step 2.

- [ ] **Step 4: Final full run**

Run: `haxe test.hxml && haxe test-native.hxml && ./bin/test/TestMain && haxe build.hxml`
Expected: PASS everywhere.

- [ ] **Step 5: Final .dev/commit.md**

Complete message covering all tasks; user reviews and commits.

---

## Self-Review (done at write time)

- **Spec coverage**: every mcp-server.md requirement maps to Tasks 1–6, 10 (auth, protocol subset, four tools, bounds, error taxonomy, socket loop, config); every minilog-db.md requirement to Tasks 7–9 (ingest, folding, budget, schema, SELECT guard, caps, single slot, native-only tests); manual checks + docs to Task 11.
- **Placeholders**: none — all steps carry real code.
- **Type consistency**: `ToolOut` defined once (Tools.hx), imported by MiniLog; `Mcp.new` change in Task 9 explicitly updates Task 5/6 call sites; constants live where used (`Tools`, `MiniLog`, `Mcp`).
- **Known deviations from spec text**: search_log's `byteOffset` is chunk-start, not exact line offset (noted in Task 4); spec's exact per-entry offsets are honored where they matter — in the minilog DB.

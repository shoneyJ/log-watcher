typedef HttpReq = { method:String, path:String, headers:Map<String, String>, body:String }
typedef HttpResp = { status:Int, body:String }

// MCP over Streamable HTTP, hand-rolled subset (feature-doc/mcp-server.md):
// stateless, tools-only, no SSE, no sessions. handle() is a pure function
// so the whole protocol is testable without sockets.
class Mcp {
	public static inline var PROTOCOL = "2025-03-26";
	public static inline var BODY_MAX = 65536;

	var tools:Tools;
	var mini:MiniLog;
	var apiKey:String;

	public function new(tools:Tools, mini:MiniLog, apiKey:String) {
		this.tools = tools;
		this.mini = mini;
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

	function callTool(id:Dynamic, params:Dynamic):HttpResp {
		if (params == null || params.name == null)
			return rpcError(id, -32600, "tools/call: missing params.name");
		var args:Dynamic = params.arguments == null ? {} : params.arguments;
		var o:Tools.ToolOut = try switch ((params.name : String)) {
			case "get_running_crons": tools.getRunningCrons(Date.now());
			case "list_logs": tools.listLogs();
			case "tail_log":
				args.path == null ? (cast {isError: true, text: "tail_log: path is required"} : Tools.ToolOut)
					: tools.tailLog(args.path, args.lines);
			case "search_log":
				(args.path == null || args.pattern == null)
					? (cast {isError: true, text: "search_log: path and pattern are required"} : Tools.ToolOut)
					: tools.searchLog(args.path, args.pattern, args.maxMatches);
			case "load_log_db":
				if (args.match == null) (cast {isError: true, text: "load_log_db: match is required"} : Tools.ToolOut)
				else {
					var hint = (args.match : String).toLowerCase();
					var hit = [for (p in tools.allowedPaths()) if (p.toLowerCase().indexOf(hint) >= 0) p];
					hit.length == 0
						? (cast {isError: true, text: "no known log matches '" + args.match
							+ "' — known logs: " + tools.allowedPaths().join(", ")} : Tools.ToolOut)
						: mini.load(hit);
				}
			case "query_log_db":
				args.sql == null ? (cast {isError: true, text: "query_log_db: sql is required"} : Tools.ToolOut)
					: mini.query(args.sql);
			case other: (cast {isError: true, text: 'unknown tool: $other'} : Tools.ToolOut);
		} catch (e:Dynamic) (cast {isError: true, text: 'tool failed: $e'} : Tools.ToolOut);
		return result(id, {content: [{type: "text", text: o.text}], isError: o.isError});
	}

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
				var blen = haxe.io.Bytes.ofString(body).length;
				c.output.writeString('HTTP/1.1 ${resp.status} ${statusText(resp.status)}\r\n'
					+ "Content-Type: application/json\r\nConnection: close\r\n"
					+ 'Content-Length: $blen\r\n\r\n' + body);
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
		];
	}
}

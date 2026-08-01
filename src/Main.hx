import Supervisor.SupConfig;

// -D portable statically links libstdc++/libgcc (glibc stays dynamic), so
// one binary runs across distros with differing libstdc++ versions.
#if portable
@:buildXml("<linker id='exe' exe='g++'><flag value='-static-libstdc++'/><flag value='-static-libgcc'/></linker>")
#end
class Main {
	static function main() {
		var args = Sys.args();
		if (args.length >= 2 && args[0] == "watch") {
			var quiet = args.length >= 3 ? Std.parseFloat(args[2]) : 10.;
			var poll = args.length >= 4 ? Std.parseFloat(args[3]) : 2.;
			var w = new Watcher(args[1], quiet, poll, true, Sys.time());
			Util.say('watching ${args[1]} (quiet ${quiet}s, poll ${poll}s)');
			while (true) {
				w.tick(Sys.time());
				Sys.sleep(poll);
			}
		} else if (args.length >= 2 && args[0] == "run") {
			var cfg:SupConfig = {pollInterval: 2., quietPeriod: 10., rescanInterval: 60., services: []};
			if (args.length >= 3) loadConfig(args[2], cfg);
			Util.say('supervising ${args[1]} (poll ${cfg.pollInterval}s, quiet ${cfg.quietPeriod}s, rescan ${cfg.rescanInterval}s)');
			new Supervisor(args[1], cfg).run();
		} else if (args.length >= 3 && args[0] == "mcp") {
			var j:Dynamic = haxe.Json.parse(sys.io.File.getContent(args[2]));
			// the key may live outside the config file (systemd EnvironmentFile / .env)
			var apiKey:Null<String> = j.mcp != null && j.mcp.apiKey != null
				? (j.mcp.apiKey : String) : Sys.getEnv("LOG_WATCHER_API_KEY");
			if (j.mcp == null || j.mcp.port == null || apiKey == null) {
				Sys.println("config error: mcp.port and an api key (mcp.apiKey or LOG_WATCHER_API_KEY) are required");
				Sys.exit(1);
			}
			var extra:Array<String> = [];
			if (j.logs != null) for (p in (j.logs : Array<Dynamic>)) extra.push((p : String));
			if (j.services != null) for (s in (j.services : Array<Dynamic>))
				extra.push(Std.isOfType(s, String) ? (s : String) : (s.path : String));
			var mcp = new Mcp(new Tools(args[1], extra), new MiniLog(), apiKey);
			Util.say('mcp server on 127.0.0.1:${j.mcp.port} (${args[1]})');
			mcp.serve((j.mcp.port : Int));
		} else {
			Sys.println("usage:");
			Sys.println("  Main watch <logfile> [quietPeriod] [pollInterval]   continuous service watch");
			Sys.println("  Main run <cron.d-dir> [config.json]                 supervisor (cron + services)");
			Sys.println("  Main mcp <cron.d-dir> <config.json>                 MCP server (127.0.0.1, Bearer auth)");
			Sys.exit(1);
		}
	}

	static function loadConfig(path:String, cfg:SupConfig):Void {
		var j:Dynamic = haxe.Json.parse(sys.io.File.getContent(path));
		if (j.pollInterval != null) cfg.pollInterval = j.pollInterval;
		if (j.quietPeriod != null) cfg.quietPeriod = j.quietPeriod;
		if (j.rescanInterval != null) cfg.rescanInterval = j.rescanInterval;
		if (j.detections != null) cfg.detections = j.detections;
		if (j.services != null) {
			var list:Array<Dynamic> = j.services;
			for (s in list)
				cfg.services.push(Std.isOfType(s, String) ? (s : String) : (s.path : String));
		}
	}
}

import Supervisor.SupConfig;

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
		} else {
			Sys.println("usage:");
			Sys.println("  Main watch <logfile> [quietPeriod] [pollInterval]   continuous service watch");
			Sys.println("  Main run <cron.d-dir> [config.json]                 supervisor (cron + services)");
			Sys.exit(1);
		}
	}

	static function loadConfig(path:String, cfg:SupConfig):Void {
		var j:Dynamic = haxe.Json.parse(sys.io.File.getContent(path));
		if (j.pollInterval != null) cfg.pollInterval = j.pollInterval;
		if (j.quietPeriod != null) cfg.quietPeriod = j.quietPeriod;
		if (j.rescanInterval != null) cfg.rescanInterval = j.rescanInterval;
		if (j.services != null) {
			var list:Array<Dynamic> = j.services;
			for (s in list)
				cfg.services.push(Std.isOfType(s, String) ? (s : String) : (s.path : String));
		}
	}
}

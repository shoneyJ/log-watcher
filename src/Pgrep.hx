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

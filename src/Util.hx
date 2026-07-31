class Util {
	// println + flush, so output is visible immediately when redirected
	public static function say(s:String):Void {
		Sys.println(s);
		Sys.stdout().flush();
	}
}

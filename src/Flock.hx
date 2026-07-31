// flock(1) probe: is an exclusive lock currently held on `path`?
// Exit 1 = -n conflict = held; 0 = acquired-and-released = free. Anything
// else (66 unreadable file, 127 no flock binary) = unknown -> report free,
// so the supervisor falls back to watching normally (the safe direction).
// The exists() guard keeps the probe read-only: flock -n would O_CREAT a
// missing lock file, and a missing file means nobody holds it anyway.
class Flock {
	public static function held(path:String):Bool {
		if (!sys.FileSystem.exists(path)) return false;
		return Sys.command("flock", ["-n", path, "true"]) == 1;
	}
}

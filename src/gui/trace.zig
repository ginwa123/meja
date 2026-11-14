// Opt-in tracing: `MEJA_TRACE=1 ./meja-gui db` prints every query, load request and tree rebuild; unset, nothing is printed.
const std = @import("std");

var cached: ?bool = null;

// True when tracing is on. Resolved once, so the hot paths pay a single branch.
pub fn on() bool {
    if (cached) |v| return v;
    const v = std.c.getenv("MEJA_TRACE") != null;
    cached = v;
    return v;
}

// One trace line, prefixed so it is greppable and clearly not an error.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!on()) return;
    std.debug.print("[meja] " ++ fmt ++ "\n", args);
}

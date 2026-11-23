const std = @import("std");
const builtin = @import("builtin");

/// Fails the process once `seconds` have passed, for a check whose frame
/// or wait would otherwise block it for ever.
///
/// ```zig
/// if (checking) try check_watchdog.start(init.io, "services", 20);
/// ```
pub fn start(io: std.Io, check_name: []const u8, seconds: i64) !void {
    const thread = try std.Thread.spawn(.{}, failAfter, .{ io, check_name, seconds });
    thread.detach();
}

fn failAfter(io: std.Io, check_name: []const u8, seconds: i64) void {
    io.sleep(.fromSeconds(seconds), .awake) catch {};
    std.debug.print("{s}: still running after {d} s, so a frame or a wait blocked the host\n", .{ check_name, seconds });
    // libc's exit runs the GPU driver's exit handlers, which wait for the
    // lock a frame blocked in its swap holds.
    if (builtin.link_libc) std.c._exit(1) else std.process.exit(1);
}

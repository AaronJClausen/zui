const zui = @import("zui");

comptime {
    _ = zui.Context(.{ .limits = .{ .string_cache_entries = 1000 } });
}

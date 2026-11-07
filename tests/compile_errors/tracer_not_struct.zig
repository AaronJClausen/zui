const zui = @import("zui");

comptime {
    _ = zui.Context(.{ .features = .{ .Tracer = u32 } });
}

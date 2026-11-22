const zui = @import("zui");

comptime {
    _ = zui.Context(.{ .corner_shapes = .initOne(.chamfer) });
}

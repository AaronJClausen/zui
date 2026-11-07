const zui = @import("zui");

comptime {
    _ = zui.Context(.{ .commands = .initOne(.material) });
}

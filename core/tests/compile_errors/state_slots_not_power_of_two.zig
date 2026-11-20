const zui = @import("zui");

comptime {
    _ = zui.Context(.{ .limits = .{ .state_slots = 1000 } });
}

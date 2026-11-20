const zui = @import("zui");

comptime {
    _ = zui.Context(.{ .Color = [4]u8 });
}

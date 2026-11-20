const zui = @import("zui");

comptime {
    _ = zui.Context(.{ .Sources = u32 });
}

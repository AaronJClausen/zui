const zui = @import("zui");

const AppSources = struct {
    count: u32 = 0,
};

comptime {
    _ = zui.Context(.{ .Sources = AppSources });
}

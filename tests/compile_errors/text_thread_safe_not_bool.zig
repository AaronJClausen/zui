const zui = @import("zui");

const Text = struct {
    pub const zui_thread_safe = 1;

    pub fn zuiMeasure(_: *Text, _: []const u8, _: zui.MeasureKey(u16)) [2]f32 {
        return .{ 0, 0 };
    }
};

comptime {
    _ = zui.Context(.{ .Text = Text });
}

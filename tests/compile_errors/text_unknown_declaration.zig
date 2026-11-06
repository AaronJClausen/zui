const zui = @import("zui");

const Text = struct {
    pub fn zuiMeasure(_: *Text, _: []const u8, _: zui.MeasureKey(u16)) [2]f32 {
        return .{ 0, 0 };
    }
    pub const zui_threadsafe = true;
};

comptime {
    _ = zui.Context(.{ .Text = Text });
}

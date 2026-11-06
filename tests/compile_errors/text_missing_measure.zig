const zui = @import("zui");

const Text = struct {
    pub fn measure(_: *Text, _: []const u8, _: zui.MeasureKey(u16)) [2]f32 {
        return .{ 0, 0 };
    }
};

comptime {
    _ = zui.Context(.{ .Text = Text });
}

const zui = @import("zui");

const Text = struct {
    pub fn zuiMeasure(_: *Text, _: []const u8, _: u16, _: f32) [2]f32 {
        return .{ 0, 0 };
    }
};

comptime {
    _ = zui.Context(.{ .Text = Text });
}

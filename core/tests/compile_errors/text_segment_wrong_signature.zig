const zui = @import("zui");

const Text = struct {
    pub fn zuiMeasure(_: *Text, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @floatFromInt(run.len), key.size };
    }

    pub fn zuiSegment(_: *Text, _: []const u8, _: []u32) void {}
};

comptime {
    _ = zui.Context(.{ .Text = Text });
}

const zui = @import("zui");

const Text = struct {
    pub fn zuiMeasure(_: *Text, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @floatFromInt(run.len), key.size };
    }

    pub fn zuiFingerprint(_: *Text) u32 {
        return 0;
    }
};

comptime {
    _ = zui.Context(.{ .Text = Text });
}

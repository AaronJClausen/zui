const zui = @import("zui");
const zui_test_card = @import("zui_test_card");

const OffscreenRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiSubmit(_: *OffscreenRenderer, _: zui.Surface, _: anytype) !void {}
};

const MeasuringOnly = struct {
    pub fn zuiMeasure(_: *MeasuringOnly, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(run.len)) * key.size / 2, key.size };
    }

    pub fn zuiFingerprint(_: *const MeasuringOnly) u64 {
        return 0;
    }
};

comptime {
    _ = zui_test_card.Text(MeasuringOnly, OffscreenRenderer);
}

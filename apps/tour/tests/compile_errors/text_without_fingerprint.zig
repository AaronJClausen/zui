const zui = @import("zui");
const zui_tour = @import("zui_tour");

const OffscreenRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiSubmit(_: *OffscreenRenderer, _: zui.Surface, _: anytype) !void {}
};

const Unfingerprinted = struct {
    pub fn addFont(_: *Unfingerprinted, _: []const u8) error{InvalidFont}!u16 {
        return 0;
    }

    pub fn zuiMeasure(_: *Unfingerprinted, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(run.len)) * key.size / 2, key.size };
    }
};

comptime {
    _ = zui_tour.Kit(.{ .Renderer = OffscreenRenderer, .FontSystem = Unfingerprinted, .inspector = false, .renderer_name = "nothing" }).Text;
}

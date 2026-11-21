const zui = @import("zui");
const zui_tour = @import("zui_tour");

const OffscreenRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiSubmit(_: *OffscreenRenderer, _: zui.Surface, _: anytype) !void {}
};

comptime {
    _ = zui_tour.Kit(.{ .Renderer = OffscreenRenderer, .FontSystem = u16, .inspector = false, .renderer_name = "nothing" }).Text;
}

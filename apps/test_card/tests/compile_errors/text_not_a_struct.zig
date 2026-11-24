const zui = @import("zui");
const zui_test_card = @import("zui_test_card");

const OffscreenRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiSubmit(_: *OffscreenRenderer, _: zui.Surface, _: anytype) !void {}
};

comptime {
    _ = zui_test_card.Text(u16, OffscreenRenderer);
}

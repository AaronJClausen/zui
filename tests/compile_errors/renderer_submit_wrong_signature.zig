const zui = @import("zui");

const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.library);

    pub fn zuiSubmit(_: *Renderer, _: anytype) !void {}
};

comptime {
    zui.checkRenderer(Renderer);
}

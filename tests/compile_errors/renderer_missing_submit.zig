const zui = @import("zui");

const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.library);
};

comptime {
    zui.checkRenderer(Renderer);
}

const zui = @import("zui");

const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiSubmit(_: *Renderer, _: zui.Surface, _: anytype) !void {}
    pub fn zuiAttachSurface(_: *Renderer, _: zui.Surface) !void {}
};

comptime {
    zui.checkRenderer(Renderer);
}

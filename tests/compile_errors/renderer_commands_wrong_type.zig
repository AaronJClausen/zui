const zui = @import("zui");

const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.library);
    pub const zui_commands = .{ .gradient, .shadow };

    pub fn zuiSubmit(_: *Renderer, _: zui.Surface, _: anytype) !void {}
};

comptime {
    zui.checkRenderer(Renderer);
}

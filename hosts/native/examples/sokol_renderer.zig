const std = @import("std");
const zui = @import("zui");
const zui_host = @import("zui_host");
const zui_sokol = @import("zui_sokol");

/// The sokol renderer as `zui_app` opens one on this host: drawing every
/// command it draws into the host's window, in the fonts of the text it is
/// given, with its overflows counted for the tour's strip.
pub const SokolRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = zui_host.Host.zui_surfaces;
    pub const ImageHandle = zui_sokol.Renderer.ImageHandle;
    pub const MaterialHandle = zui_sokol.Renderer.MaterialHandle;
    pub const zui_commands = zui_sokol.Renderer.zui_commands;
    pub const zui_extended_color = zui_sokol.Renderer.zui_extended_color;

    sokol: zui_sokol.Renderer,
    /// What each frame's pass clears to.
    clear_color: zui.Color = .black,
    /// The sokol renderer's, as of the last frame.
    layer_overflows: u32 = 0,

    pub fn init(self: *SokolRenderer, surface: zui.Surface, text: anytype) !void {
        self.* = .{ .sokol = try .initForSurface(text, surface) };
    }

    pub fn deinit(self: *SokolRenderer) void {
        self.sokol.deinit();
    }

    pub fn zuiSubmit(self: *SokolRenderer, surface: zui.Surface, frame: anytype) !void {
        self.sokol.clear_color = self.clear_color;
        try self.sokol.zuiSubmit(surface, frame);
        self.layer_overflows = self.sokol.layer_overflows;
    }

    pub fn glyphOverflows(self: *const SokolRenderer) u32 {
        return self.sokol.glyphOverflows();
    }
};

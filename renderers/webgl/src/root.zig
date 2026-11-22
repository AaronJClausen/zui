const builtin = @import("builtin");

/// A frame's commands laid out as the triangles, batches, backdrop blurs
/// and materials that WebGL 2 draws.
pub const DrawList = @import("draw_list.zig").DrawList;
/// The glyphs a `DrawList` draws text from, two bytes a texel, as the
/// page's RG8 texture holds them.
pub const GlyphAtlas = @import("zui_glyphs").Atlas(.rg8);

const renderer = @import("renderer.zig");
pub const Renderer = renderer.Renderer;
pub const RendererOn = renderer.RendererOn;
pub const BrowserPage = renderer.BrowserPage;
pub const DrawnFrame = renderer.DrawnFrame;
pub const Image = renderer.Image;
pub const Material = renderer.Material;

test {
    _ = @import("backdrop_blur.zig");
    _ = @import("draw_list.zig");
    _ = renderer;
    if (comptime !builtin.cpu.arch.isWasm()) _ = @import("conformance.zig");
}

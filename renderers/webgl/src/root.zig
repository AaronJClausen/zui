/// A frame's commands laid out as the triangles, batches, backdrop blurs
/// and materials that WebGL 2 draws.
pub const DrawList = @import("draw_list.zig").DrawList;
/// The glyphs a `DrawList` draws text from, two bytes a texel, as the
/// page's RG8 texture holds them.
pub const GlyphAtlas = @import("zui_glyphs").Atlas(.rg8);

const drawing = @import("drawing.zig");
pub const Drawing = drawing.Drawing;
pub const Image = drawing.Image;
pub const Material = drawing.Material;

test {
    _ = @import("backdrop_blur.zig");
    _ = @import("draw_list.zig");
    _ = drawing;
}

//! What font systems and renderers share, so that text is drawn where it
//! was measured: the glyphs a run lays out into, the one pen that places
//! them for measuring and for drawing, the placement a renderer declares,
//! a type-erased handle to a font system's fonts, and the atlas that
//! rasterized glyphs are drawn from.

const fonts = @import("fonts.zig");
const layout = @import("layout.zig");
const pixel_grid = @import("pixel_grid.zig");
const atlas = @import("atlas.zig");

pub const FontId = fonts.FontId;
pub const GlyphId = fonts.GlyphId;
pub const FontMetrics = fonts.FontMetrics;
pub const GlyphBox = fonts.GlyphBox;
pub const Fonts = fonts.Fonts;

pub const Codepoints = @import("codepoints.zig").Codepoints;

pub const Placement = layout.Placement;
pub const PositionedGlyph = layout.PositionedGlyph;
pub const Layout = layout.Layout;
pub const layOut = layout.layOut;
pub const measure = layout.measure;

pub const max_pixel_size = pixel_grid.max_pixel_size;
pub const rasterPixelSize = pixel_grid.rasterPixelSize;
pub const snapToPixel = pixel_grid.snapToPixel;
pub const Edges = pixel_grid.Edges;
pub const GlyphQuad = pixel_grid.GlyphQuad;
pub const GlyphQuads = pixel_grid.GlyphQuads;
pub const glyphQuads = pixel_grid.glyphQuads;

pub const TexelLayout = atlas.TexelLayout;
pub const Atlas = atlas.Atlas;

pub const FontsViolation = @import("conformance.zig").FontsViolation;
pub const expectFontsConform = @import("conformance.zig").expectFontsConform;

/// What a test of a font system or a renderer can lay text out with.
pub const testing = struct {
    pub const BoxFonts = @import("box_fonts.zig").BoxFonts;
};

/// The placement `Renderer` declares as `glyph_placement`, or
/// `.pixel_grid`, which a renderer that declares none draws.
pub fn placementOf(comptime Renderer: type) Placement {
    return if (@hasDecl(Renderer, "glyph_placement")) Renderer.glyph_placement else .pixel_grid;
}

test {
    _ = fonts;
    _ = layout;
    _ = pixel_grid;
    _ = atlas;
    _ = @import("codepoints.zig");
    _ = @import("conformance.zig");
    _ = @import("box_fonts.zig");
}

test "a renderer that declares no placement draws on the pixel grid" {
    const std = @import("std");
    try std.testing.expectEqual(Placement.pixel_grid, placementOf(struct {}));
    try std.testing.expectEqual(Placement{ .cells = .{ 8, 16 } }, placementOf(struct {
        pub const glyph_placement: Placement = .{ .cells = .{ 8, 16 } };
    }));
}

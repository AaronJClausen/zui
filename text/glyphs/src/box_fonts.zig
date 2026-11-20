const fonts = @import("fonts.zig");
const FontId = fonts.FontId;
const GlyphId = fonts.GlyphId;
const FontMetrics = fonts.FontMetrics;
const GlyphBox = fonts.GlyphBox;

/// A font system with no font files, for tests: in each of its fonts every
/// glyph is a solid box, `i` narrow, `W` wide and the rest alike, and
/// font 1 a third wider than font 0.
pub const BoxFonts = struct {
    pub const font_count = 2;
    pub const metrics: FontMetrics = .{ .ascent = 800, .descent = -200, .line_gap = 100 };

    pub fn fontMetrics(_: *const BoxFonts, font: FontId) ?FontMetrics {
        return if (font < font_count) metrics else null;
    }

    pub fn advance(_: *const BoxFonts, font: FontId, codepoint: u21) f32 {
        const width: f32 = switch (codepoint) {
            'i' => 250,
            'W' => 900,
            ' ' => 300,
            else => 500,
        };
        return if (font == 1) width * 4 / 3 else width;
    }

    pub fn glyphIndex(_: *const BoxFonts, _: FontId, codepoint: u21) GlyphId {
        return codepoint;
    }

    pub fn glyphBox(self: *const BoxFonts, font: FontId, glyph: GlyphId, pixel_size: f32) GlyphBox {
        if (glyph == ' ') return .{};
        const scale = metrics.scaleFor(pixel_size);
        const height: u32 = @intFromFloat(@round(700 * scale));
        return .{
            .offset = .{ 0, -@as(i32, @intCast(height)) },
            .width = @intFromFloat(@max(1, @round(self.advance(font, @intCast(glyph)) * scale * 0.8))),
            .height = height,
        };
    }

    pub fn rasterize(_: *const BoxFonts, _: FontId, _: GlyphId, _: f32, box: GlyphBox, coverage: []u8, stride: usize, _: []align(16) u8) bool {
        for (0..box.height) |row| @memset(coverage[row * stride ..][0..box.width], 255);
        return true;
    }
};

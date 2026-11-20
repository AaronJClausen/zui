const std = @import("std");

/// sokol_debugtext's six 8×8 bitmap fonts, as the sokol renderer draws
/// them: a text whose fonts have no face for a `FontId` draws it in the
/// bitmap font of that number, or the last. The page hands over their rows,
/// since they are the stream's application's, not the client's. Memory is
/// reserved by `init`.
///
/// ```zig
/// var bitmap_fonts: BitmapFonts = try .init(gpa);
/// bitmap_fonts.load(sokol_debugtext_rows);
/// ```
pub const BitmapFonts = struct {
    pub const count = 6;
    /// A glyph's height and advance as a fraction of the text size, as the
    /// sokol renderer's default.
    pub const glyph_scale = 0.75;
    pub const glyph_side = 8;
    pub const glyphs_per_font = 256;
    /// The six fonts' rows as sokol_debugtext holds them, in `FontId`
    /// order: for each of a font's 256 glyphs, eight bytes, one per row
    /// from the top, its high bit leftmost.
    pub const font_bytes = count * glyphs_per_font * glyph_side;
    /// Every font's glyphs side by side in a row of their own.
    pub const texture_width = glyphs_per_font * glyph_side;
    pub const texture_height = count * glyph_side;

    /// The fonts' coverage, one byte a texel, 255 where a glyph's bit is
    /// set.
    texels: []u8,
    loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!BitmapFonts {
        return .{ .texels = try gpa.alloc(u8, texture_width * texture_height) };
    }

    pub fn deinit(self: *BitmapFonts, gpa: std.mem.Allocator) void {
        gpa.free(self.texels);
    }

    pub fn load(self: *BitmapFonts, rows: *const [font_bytes]u8) void {
        @memset(self.texels, 0);
        for (0..count) |font| {
            for (0..glyphs_per_font) |glyph| {
                for (0..glyph_side) |line| {
                    const bits = rows[(font * glyphs_per_font + glyph) * glyph_side + line];
                    const row_start = (font * glyph_side + line) * texture_width + glyph * glyph_side;
                    for (0..glyph_side) |x| {
                        if ((bits >> @intCast(7 - x)) & 1 == 1) self.texels[row_start + x] = 255;
                    }
                }
            }
        }
        self.loaded = true;
    }
};

test "a bitmap font's glyph sets its bits and leaves the space clear" {
    var bitmap_fonts: BitmapFonts = try .init(std.testing.allocator);
    defer bitmap_fonts.deinit(std.testing.allocator);
    var rows: [BitmapFonts.font_bytes]u8 = @splat(0);
    const font = 3;
    const letter_a_top_row = (font * BitmapFonts.glyphs_per_font + 'A') * BitmapFonts.glyph_side;
    rows[letter_a_top_row] = 0b1000_0001;
    bitmap_fonts.load(&rows);
    const texel_row = font * BitmapFonts.glyph_side * BitmapFonts.texture_width;
    try std.testing.expectEqual(255, bitmap_fonts.texels[texel_row + 'A' * 8]);
    try std.testing.expectEqual(0, bitmap_fonts.texels[texel_row + 'A' * 8 + 1]);
    try std.testing.expectEqual(255, bitmap_fonts.texels[texel_row + 'A' * 8 + 7]);
    try std.testing.expectEqual(0, std.mem.max(u8, bitmap_fonts.texels[0 .. 'A' * 8]));
}

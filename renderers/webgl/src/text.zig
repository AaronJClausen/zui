const std = @import("std");
const truetype = @import("truetype.zig");
const GlyphAtlas = @import("glyph_atlas.zig").GlyphAtlas;

/// The fonts a stream's text is drawn in, as zui-sokol's `Text` numbers
/// them: `FontId` 0 to 5 are sokol_debugtext's 8×8 bitmap fonts, and the
/// TrueType fonts added follow them, in the order the stream's host added
/// them. The page hands over each font's bytes, since they are the
/// application's, not the client's. Memory is reserved by `init`.
///
/// ```zig
/// var text: Text = try .init(gpa);
/// text.loadBitmapFonts(sokol_debugtext_rows);
/// const room = text.roomForFont(regular_ttf.len).?;
/// @memcpy(room, regular_ttf);
/// const body_font = try text.addTrueTypeFont(regular_ttf.len);
/// ```
pub const Text = struct {
    pub const bitmap_font_count = 6;
    pub const max_truetype_fonts = 8;
    pub const max_font_bytes = 1 << 20;
    /// A bitmap glyph's height and advance as a fraction of the text size,
    /// zui-sokol's `Text.glyph_scale`.
    pub const bitmap_glyph_scale = 0.75;
    pub const bitmap_glyph_side = 8;
    pub const bitmap_glyphs_per_font = 256;
    /// The six fonts' rows as sokol_debugtext holds them, in `FontId`
    /// order: for each of a font's 256 glyphs, eight bytes, one per row
    /// from the top, its high bit leftmost.
    pub const bitmap_font_bytes = bitmap_font_count * bitmap_glyphs_per_font * bitmap_glyph_side;
    /// Every font's glyphs side by side in a row of their own.
    pub const bitmap_texture_width = bitmap_glyphs_per_font * bitmap_glyph_side;
    pub const bitmap_texture_height = bitmap_font_count * bitmap_glyph_side;

    font_bytes: []u8,
    font_bytes_used: usize = 0,
    truetype_fonts: [max_truetype_fonts]truetype.Font = undefined,
    truetype_font_count: u8 = 0,
    scratch: *truetype.Scratch,
    atlas: *GlyphAtlas,
    /// The bitmap fonts' coverage, one byte a texel, 255 where a glyph's
    /// bit is set.
    bitmap_glyph_texels: []u8,
    bitmap_fonts_loaded: bool = false,
    /// Times a frame needed more glyphs than the atlas holds; the ones
    /// that did not fit were left out.
    glyph_overflows: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Text {
        const font_bytes = try gpa.alloc(u8, max_font_bytes);
        errdefer gpa.free(font_bytes);
        // stb_truetype trusts a font's offsets, so bytes that are not a
        // font are read past their end, within this.
        @memset(font_bytes, 0);
        const scratch = try gpa.create(truetype.Scratch);
        errdefer gpa.destroy(scratch);
        scratch.* = try .init(gpa, 256 * 1024);
        errdefer scratch.deinit(gpa);
        const atlas = try GlyphAtlas.create(gpa);
        errdefer gpa.destroy(atlas);
        return .{
            .font_bytes = font_bytes,
            .scratch = scratch,
            .atlas = atlas,
            .bitmap_glyph_texels = try gpa.alloc(u8, bitmap_texture_width * bitmap_texture_height),
        };
    }

    pub fn deinit(self: *Text, gpa: std.mem.Allocator) void {
        gpa.free(self.bitmap_glyph_texels);
        gpa.destroy(self.atlas);
        self.scratch.deinit(gpa);
        gpa.destroy(self.scratch);
        gpa.free(self.font_bytes);
    }

    /// Where to write the next font's `count` bytes, or null when they do
    /// not fit.
    pub fn roomForFont(self: *Text, count: usize) ?[]u8 {
        if (count > self.font_bytes.len - self.font_bytes_used) return null;
        return self.font_bytes[self.font_bytes_used..][0..count];
    }

    /// Adds the font whose `count` bytes were written to `roomForFont`,
    /// returning its `FontId`.
    pub fn addTrueTypeFont(self: *Text, count: usize) error{ InvalidFont, TooManyFonts, FontTooLarge }!u16 {
        if (self.truetype_font_count == max_truetype_fonts) return error.TooManyFonts;
        const data = self.roomForFont(count) orelse return error.FontTooLarge;
        self.truetype_fonts[self.truetype_font_count] = try .init(data, self.scratch);
        self.font_bytes_used += count;
        self.truetype_font_count += 1;
        return bitmap_font_count + self.truetype_font_count - 1;
    }

    /// Null for a bitmap font, or an id no font was added for.
    pub fn trueTypeFont(self: *const Text, font: u16) ?*const truetype.Font {
        if (font < bitmap_font_count) return null;
        const index = font - bitmap_font_count;
        return if (index < self.truetype_font_count) &self.truetype_fonts[index] else null;
    }

    pub fn loadBitmapFonts(self: *Text, rows: *const [bitmap_font_bytes]u8) void {
        @memset(self.bitmap_glyph_texels, 0);
        for (0..bitmap_font_count) |font| {
            for (0..bitmap_glyphs_per_font) |glyph| {
                for (0..bitmap_glyph_side) |line| {
                    const bits = rows[(font * bitmap_glyphs_per_font + glyph) * bitmap_glyph_side + line];
                    const row_start = (font * bitmap_glyph_side + line) * bitmap_texture_width + glyph * bitmap_glyph_side;
                    for (0..bitmap_glyph_side) |x| {
                        if ((bits >> @intCast(7 - x)) & 1 == 1) self.bitmap_glyph_texels[row_start + x] = 255;
                    }
                }
            }
        }
        self.bitmap_fonts_loaded = true;
    }

    /// Text is rasterized at its size in physical pixels, so it is drawn
    /// one texel per pixel, up to the atlas's largest size.
    pub fn rasterPixelSize(size: f32, pixels_per_unit: f32) u16 {
        return @intFromFloat(std.math.clamp(@round(size * pixels_per_unit), 1, GlyphAtlas.max_pixel_size));
    }

    /// Rasterizes every glyph the frame's TrueType text needs before any is
    /// drawn, so the page uploads the atlas at most once per frame. If the
    /// atlas fills up, it starts over with only this frame's glyphs.
    pub fn prepareGlyphs(self: *Text, commands: anytype, pixels_per_unit: f32) void {
        if (self.truetype_font_count == 0) return;
        self.addGlyphs(commands, pixels_per_unit) catch {
            self.atlas.reset();
            self.addGlyphs(commands, pixels_per_unit) catch {
                self.glyph_overflows += 1;
            };
        };
    }

    fn addGlyphs(self: *Text, commands: anytype, pixels_per_unit: f32) error{Full}!void {
        for (commands) |command| switch (command.payload) {
            .text => |line| if (self.trueTypeFont(line.style.font)) |font| {
                const pixel_size = rasterPixelSize(line.style.size, pixels_per_unit);
                var codepoints = truetype.Codepoints.init(line.content);
                while (codepoints.next()) |codepoint| {
                    _ = try self.atlas.findOrAdd(.{ .font = line.style.font, .pixel_size = pixel_size, .codepoint = codepoint }, font);
                }
            },
            else => {},
        };
    }
};

test "a bitmap font's glyph sets its bits and leaves the space clear" {
    var text: Text = try .init(std.testing.allocator);
    defer text.deinit(std.testing.allocator);
    var rows: [Text.bitmap_font_bytes]u8 = @splat(0);
    const font = 3;
    const letter_a_top_row = (font * Text.bitmap_glyphs_per_font + 'A') * Text.bitmap_glyph_side;
    rows[letter_a_top_row] = 0b1000_0001;
    text.loadBitmapFonts(&rows);
    const texel_row = font * Text.bitmap_glyph_side * Text.bitmap_texture_width;
    try std.testing.expectEqual(255, text.bitmap_glyph_texels[texel_row + 'A' * 8]);
    try std.testing.expectEqual(0, text.bitmap_glyph_texels[texel_row + 'A' * 8 + 1]);
    try std.testing.expectEqual(255, text.bitmap_glyph_texels[texel_row + 'A' * 8 + 7]);
    try std.testing.expectEqual(0, std.mem.max(u8, text.bitmap_glyph_texels[0 .. 'A' * 8]));
}

test "bytes that are not a TrueType font are refused, and the room is kept for the next" {
    var text: Text = try .init(std.testing.allocator);
    defer text.deinit(std.testing.allocator);
    const not_a_font = "GET / HTTP/1.1\r\n";
    @memcpy(text.roomForFont(not_a_font.len).?, not_a_font);
    try std.testing.expectError(error.InvalidFont, text.addTrueTypeFont(not_a_font.len));
    try std.testing.expectEqual(0, text.font_bytes_used);
    try std.testing.expectEqual(null, text.roomForFont(Text.max_font_bytes + 1));
    try std.testing.expectEqual(null, text.trueTypeFont(Text.bitmap_font_count));
}

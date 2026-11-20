const std = @import("std");
const zui_glyphs = @import("zui_glyphs");
const zui_truetype = @import("zui_truetype");
const BitmapFonts = @import("zui_webgl").BitmapFonts;
const FontId = zui_glyphs.FontId;
const GlyphId = zui_glyphs.GlyphId;
const FontMetrics = zui_glyphs.FontMetrics;
const GlyphBox = zui_glyphs.GlyphBox;

/// The fonts a stream's text is drawn in, numbered as the sokol renderer's
/// `Text` numbers them: `FontId` 0 to 5 are the bitmap fonts, and the
/// TrueType fonts the page hands over follow them, in the order the
/// stream's host added them, since they are the application's, not the
/// client's. Without them, text past the bitmap fonts is drawn in the last
/// bitmap font. Memory is reserved by `init`.
///
/// ```zig
/// var text: Text = try .init(gpa);
/// const room = text.roomForFont(regular_ttf.len).?;
/// @memcpy(room, regular_ttf);
/// const body_font = try text.addTrueTypeFont(regular_ttf.len);
/// stream.fingerprint = zui_wire.fingerprintOf(&text);
/// draw_list.layOut(frame.commands(), frame.params, &text);
/// ```
pub const Text = struct {
    pub const max_font_bytes = 1 << 20;

    font_bytes: []u8,
    font_bytes_used: usize = 0,
    truetype: zui_truetype.Text = .{},

    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Text {
        const font_bytes = try gpa.alloc(u8, max_font_bytes);
        // stb_truetype trusts a font's offsets, so bytes that are not a
        // font are read past their end, within this.
        @memset(font_bytes, 0);
        return .{ .font_bytes = font_bytes };
    }

    pub fn deinit(self: *Text, gpa: std.mem.Allocator) void {
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
    pub fn addTrueTypeFont(self: *Text, count: usize) error{ InvalidFont, TooManyFonts, FontTooLarge }!FontId {
        const data = self.roomForFont(count) orelse return error.FontTooLarge;
        const font = try self.truetype.addFont(data);
        self.font_bytes_used += count;
        return BitmapFonts.count + font;
    }

    /// As the sokol renderer's `Text` with the same fonts fingerprints
    /// itself, so a stream measured with other fonts is told apart.
    pub fn zuiFingerprint(self: *const Text) u64 {
        var hasher = std.hash.Wyhash.init(BitmapFonts.count);
        hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, self.truetype.addedFontsFingerprint())));
        hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @bitCast(@as(f32, BitmapFonts.glyph_scale))))));
        return hasher.final();
    }

    fn face(self: *const Text, font: FontId) ?*const zui_truetype.Face {
        if (font < BitmapFonts.count) return null;
        return self.truetype.addedFace(font - BitmapFonts.count);
    }

    pub fn fontMetrics(self: *const Text, font: FontId) ?FontMetrics {
        return if (self.face(font)) |found| found.metrics else null;
    }

    pub fn advance(self: *const Text, font: FontId, codepoint: u21) f32 {
        return self.face(font).?.advance(codepoint);
    }

    pub fn glyphIndex(self: *const Text, font: FontId, codepoint: u21) GlyphId {
        return self.face(font).?.glyphIndex(codepoint);
    }

    pub fn glyphBox(self: *const Text, font: FontId, glyph: GlyphId, pixel_size: f32) GlyphBox {
        return self.face(font).?.glyphBox(glyph, pixel_size);
    }

    pub fn rasterize(self: *const Text, font: FontId, glyph: GlyphId, pixel_size: f32, box: GlyphBox, coverage: []u8, stride: usize, scratch: []align(16) u8) bool {
        return self.face(font).?.rasterize(glyph, pixel_size, box, coverage, stride, scratch);
    }
};

test "bytes that are not a TrueType font are refused, and the room is kept for the next" {
    var text: Text = try .init(std.testing.allocator);
    defer text.deinit(std.testing.allocator);
    const not_a_font = "GET / HTTP/1.1\r\n";
    @memcpy(text.roomForFont(not_a_font.len).?, not_a_font);
    try std.testing.expectError(error.InvalidFont, text.addTrueTypeFont(not_a_font.len));
    try std.testing.expectEqual(0, text.font_bytes_used);
    try std.testing.expectEqual(null, text.roomForFont(Text.max_font_bytes + 1));
    try std.testing.expectEqual(null, text.fontMetrics(BitmapFonts.count));
}

test "fonts the page hands over follow the bitmap fonts and conform" {
    var text: Text = try .init(std.testing.allocator);
    defer text.deinit(std.testing.allocator);
    const regular = @import("zui_fonts").atkinson_hyperlegible_regular;
    @memcpy(text.roomForFont(regular.len).?, regular);
    try std.testing.expectEqual(BitmapFonts.count, try text.addTrueTypeFont(regular.len));
    try std.testing.expectEqual(null, text.fontMetrics(BitmapFonts.count - 1));
    try zui_glyphs.expectFontsConform(&text.truetype, std.testing.allocator);
}

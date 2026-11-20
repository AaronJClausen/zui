const std = @import("std");
const stbtt = @import("stb_truetype");

/// What stb_truetype allocates while it rasterizes a glyph, from memory
/// reserved once. Nothing is freed until `reset`, which comes before each
/// glyph.
pub const Scratch = struct {
    bytes: []align(16) u8,
    used: usize = 0,
    /// Allocations refused because the scratch was full; stb_truetype
    /// then leaves the glyph blank.
    refusals: u32 = 0,

    /// stb_truetype writes a scanline of this many bytes without checking
    /// that it was given one, so every other allocation leaves room for it.
    const scanline_reserve = (2 * @import("glyph_atlas.zig").GlyphAtlas.max_raster_side + 1) * @sizeOf(f32);

    pub fn init(gpa: std.mem.Allocator, size: usize) std.mem.Allocator.Error!Scratch {
        return .{ .bytes = try gpa.alignedAlloc(u8, .@"16", size) };
    }

    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }

    pub fn reset(self: *Scratch) void {
        self.used = 0;
    }

    fn allocate(self: *Scratch, size: usize) ?*anyopaque {
        const start = std.mem.alignForward(usize, self.used, 16);
        const reserve: usize = if (size <= scanline_reserve) 0 else scanline_reserve;
        if (start + size + reserve > self.bytes.len) {
            self.refusals += 1;
            return null;
        }
        self.used = start + size;
        return self.bytes[start..].ptr;
    }
};

fn allocate(size: usize, scratch: ?*anyopaque) callconv(.c) ?*anyopaque {
    const owner: *Scratch = @ptrCast(@alignCast(scratch.?));
    return owner.allocate(size);
}

fn pow(base: f64, exponent: f64) callconv(.c) f64 {
    return std.math.pow(f64, base, exponent);
}

fn fmod(dividend: f64, divisor: f64) callconv(.c) f64 {
    return @rem(dividend, divisor);
}

fn cos(angle: f64) callconv(.c) f64 {
    return @cos(angle);
}

fn acos(cosine: f64) callconv(.c) f64 {
    return std.math.acos(cosine);
}

comptime {
    @export(&allocate, .{ .name = "zui_web_stbtt_allocate", .visibility = .hidden });
    @export(&pow, .{ .name = "zui_web_stbtt_pow", .visibility = .hidden });
    @export(&fmod, .{ .name = "zui_web_stbtt_fmod", .visibility = .hidden });
    @export(&cos, .{ .name = "zui_web_stbtt_cos", .visibility = .hidden });
    @export(&acos, .{ .name = "zui_web_stbtt_acos", .visibility = .hidden });
}

/// A TrueType font, as zui-sokol's `truetype.Font` reads and rasterizes
/// it, so its glyphs come out as zui-sokol draws them.
///
/// Sizes follow `ScaleForPixelHeight`: a text size of 16 makes the font's
/// ascent minus its descent 16 units tall.
pub const Font = struct {
    info: stbtt.stbtt_fontinfo,
    /// In font units, like every metric here.
    ascent: f32,
    descent: f32,
    ascii_advances: [128]f32,
    ascii_glyphs: [128]c_int,

    /// `data` and `scratch` must outlive the font: stb_truetype reads the
    /// data in place.
    pub fn init(data: []const u8, scratch: *Scratch) error{InvalidFont}!Font {
        var font: Font = undefined;
        const offset = stbtt.stbtt_GetFontOffsetForIndex(data.ptr, 0);
        if (offset < 0 or stbtt.stbtt_InitFont(&font.info, data.ptr, offset) == 0) return error.InvalidFont;
        font.info.userdata = scratch;
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        stbtt.stbtt_GetFontVMetrics(&font.info, &ascent, &descent, &line_gap);
        if (ascent - descent <= 0) return error.InvalidFont;
        font.ascent = @floatFromInt(ascent);
        font.descent = @floatFromInt(descent);
        for (0..128) |codepoint| {
            font.ascii_glyphs[codepoint] = stbtt.stbtt_FindGlyphIndex(&font.info, @intCast(codepoint));
            font.ascii_advances[codepoint] = font.glyphAdvance(font.ascii_glyphs[codepoint]);
        }
        return font;
    }

    /// Layout units per font unit for text of `size`.
    pub fn scaleFor(self: *const Font, size: f32) f32 {
        return size / (self.ascent - self.descent);
    }

    pub fn glyphFor(self: *const Font, codepoint: u21) c_int {
        if (codepoint < 128) return self.ascii_glyphs[codepoint];
        return stbtt.stbtt_FindGlyphIndex(&self.info, codepoint);
    }

    /// In font units.
    pub fn advance(self: *const Font, codepoint: u21) f32 {
        if (codepoint < 128) return self.ascii_advances[codepoint];
        return self.glyphAdvance(self.glyphFor(codepoint));
    }

    fn glyphAdvance(self: *const Font, glyph: c_int) f32 {
        var advance_width: c_int = 0;
        var left_side_bearing: c_int = 0;
        stbtt.stbtt_GetGlyphHMetrics(&self.info, glyph, &advance_width, &left_side_bearing);
        return @floatFromInt(advance_width);
    }

    pub const GlyphBitmapBox = struct {
        /// From the pen on the baseline to the bitmap's top-left corner, in pixels.
        offset: [2]i32,
        width: u32,
        height: u32,
    };

    /// For a glyph rasterized so the font's ascent minus descent spans
    /// `pixel_size` pixels.
    pub fn glyphBitmapBox(self: *const Font, glyph: c_int, pixel_size: f32) GlyphBitmapBox {
        const scale = self.scaleFor(pixel_size);
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stbtt.stbtt_GetGlyphBitmapBox(&self.info, glyph, scale, scale, &x0, &y0, &x1, &y1);
        return .{ .offset = .{ x0, y0 }, .width = @intCast(@max(0, x1 - x0)), .height = @intCast(@max(0, y1 - y0)) };
    }

    /// Writes the glyph's coverage, one byte per pixel, `stride` bytes per row.
    pub fn rasterize(self: *const Font, glyph: c_int, pixel_size: f32, box: GlyphBitmapBox, output: []u8, stride: usize) void {
        std.debug.assert(output.len >= stride * box.height);
        const scratch: *Scratch = @ptrCast(@alignCast(self.info.userdata.?));
        scratch.reset();
        const scale = self.scaleFor(pixel_size);
        stbtt.stbtt_MakeGlyphBitmap(&self.info, output.ptr, @intCast(box.width), @intCast(box.height), @intCast(stride), scale, scale, glyph);
    }
};

/// The codepoints of UTF-8 text; each invalid byte reads as U+FFFD.
pub const Codepoints = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn init(bytes: []const u8) Codepoints {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Codepoints) ?u21 {
        if (self.index >= self.bytes.len) return null;
        const first = self.bytes[self.index];
        if (first < 0x80) {
            self.index += 1;
            return first;
        }
        const length = std.unicode.utf8ByteSequenceLength(first) catch return self.replace();
        if (self.index + length > self.bytes.len) return self.replace();
        const codepoint = std.unicode.utf8Decode(self.bytes[self.index..][0..length]) catch return self.replace();
        self.index += length;
        return codepoint;
    }

    fn replace(self: *Codepoints) u21 {
        self.index += 1;
        return std.unicode.replacement_character;
    }
};

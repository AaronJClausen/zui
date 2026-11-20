const std = @import("std");
const stbtt = @import("stb_truetype");
const zui_glyphs = @import("zui_glyphs");
const FontMetrics = zui_glyphs.FontMetrics;
const GlyphBox = zui_glyphs.GlyphBox;
const GlyphId = zui_glyphs.GlyphId;

/// What stb_truetype allocates while it rasterizes one glyph, from the
/// bytes the rasterizer's caller reserved. Nothing is freed.
const Scratch = struct {
    bytes: []align(16) u8,
    used: usize = 0,
    /// stb_truetype writes a scanline of this many bytes without checking
    /// that it was given one, so every larger allocation leaves room for it.
    scanline_reserve: usize,
    refusals: u32 = 0,

    fn allocate(self: *Scratch, size: usize) ?*anyopaque {
        const start = std.mem.alignForward(usize, self.used, 16);
        const reserve: usize = if (size <= self.scanline_reserve) 0 else self.scanline_reserve;
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
    @export(&allocate, .{ .name = "zui_truetype_stbtt_allocate", .visibility = .hidden });
    @export(&pow, .{ .name = "zui_truetype_stbtt_pow", .visibility = .hidden });
    @export(&fmod, .{ .name = "zui_truetype_stbtt_fmod", .visibility = .hidden });
    @export(&cos, .{ .name = "zui_truetype_stbtt_cos", .visibility = .hidden });
    @export(&acos, .{ .name = "zui_truetype_stbtt_acos", .visibility = .hidden });
}

/// One TrueType font, read in place by stb_truetype, with what measuring
/// needs most read once. Measuring and rasterizing only read it, so both
/// are safe from many threads at once.
pub const Face = struct {
    info: stbtt.stbtt_fontinfo,
    metrics: FontMetrics,
    ascii_advances: [128]f32,
    ascii_glyphs: [128]c_int,
    /// Of the font's bytes, for a text's fingerprint.
    content_hash: u64,

    /// `data` must outlive the face.
    pub fn init(data: []const u8) error{InvalidFont}!Face {
        var face: Face = undefined;
        const offset = stbtt.stbtt_GetFontOffsetForIndex(data.ptr, 0);
        if (offset < 0 or stbtt.stbtt_InitFont(&face.info, data.ptr, offset) == 0) return error.InvalidFont;
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        stbtt.stbtt_GetFontVMetrics(&face.info, &ascent, &descent, &line_gap);
        if (ascent - descent <= 0) return error.InvalidFont;
        face.metrics = .{ .ascent = @floatFromInt(ascent), .descent = @floatFromInt(descent), .line_gap = @floatFromInt(line_gap) };
        for (0..128) |codepoint| {
            face.ascii_glyphs[codepoint] = stbtt.stbtt_FindGlyphIndex(&face.info, @intCast(codepoint));
            face.ascii_advances[codepoint] = face.glyphAdvance(face.ascii_glyphs[codepoint]);
        }
        face.content_hash = std.hash.Wyhash.hash(0, data);
        return face;
    }

    pub fn glyphIndex(self: *const Face, codepoint: u21) GlyphId {
        if (codepoint < 128) return @intCast(self.ascii_glyphs[codepoint]);
        return @intCast(stbtt.stbtt_FindGlyphIndex(&self.info, codepoint));
    }

    /// In font units.
    pub fn advance(self: *const Face, codepoint: u21) f32 {
        if (codepoint < 128) return self.ascii_advances[codepoint];
        return self.glyphAdvance(@intCast(self.glyphIndex(codepoint)));
    }

    fn glyphAdvance(self: *const Face, glyph: c_int) f32 {
        var advance_width: c_int = 0;
        var left_side_bearing: c_int = 0;
        stbtt.stbtt_GetGlyphHMetrics(&self.info, glyph, &advance_width, &left_side_bearing);
        return @floatFromInt(advance_width);
    }

    /// For the glyph rasterized so the font's ascent minus descent spans
    /// `pixel_size` pixels.
    pub fn glyphBox(self: *const Face, glyph: GlyphId, pixel_size: f32) GlyphBox {
        const scale = self.metrics.scaleFor(pixel_size);
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stbtt.stbtt_GetGlyphBitmapBox(&self.info, @intCast(glyph), scale, scale, &x0, &y0, &x1, &y1);
        return .{ .offset = .{ x0, y0 }, .width = @intCast(@max(0, x1 - x0)), .height = @intCast(@max(0, y1 - y0)) };
    }

    /// Writes the glyph's coverage, one byte per pixel, `stride` bytes per
    /// row, allocating only from `scratch`. False when that ran out, and the
    /// glyph is left blank.
    pub fn rasterize(self: *const Face, glyph: GlyphId, pixel_size: f32, box: GlyphBox, coverage: []u8, stride: usize, scratch: []align(16) u8) bool {
        std.debug.assert(coverage.len >= stride * box.height);
        var allocator: Scratch = .{ .bytes = scratch, .scanline_reserve = (2 * @as(usize, box.width) + 1) * @sizeOf(f32) };
        var info = self.info;
        info.userdata = &allocator;
        const scale = self.metrics.scaleFor(pixel_size);
        stbtt.stbtt_MakeGlyphBitmap(&info, coverage.ptr, @intCast(box.width), @intCast(box.height), @intCast(stride), scale, scale, @intCast(glyph));
        return allocator.refusals == 0;
    }
};

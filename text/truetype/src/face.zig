const std = @import("std");
const stbtt = @import("stb_truetype");
const zui_glyphs = @import("zui_glyphs");
const zui_fonts = @import("zui_fonts");
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
        const heights = typographicHeightsOf(&face.info, data[@intCast(offset)..], @floatFromInt(ascent));
        face.metrics = .{
            .ascent = @floatFromInt(ascent),
            .descent = @floatFromInt(descent),
            .line_gap = @floatFromInt(line_gap),
            .x_height = heights.x_height,
            .cap_height = heights.cap_height,
        };
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

const TypographicHeights = struct { x_height: f32, cap_height: f32 };

/// The OS/2 table's, which version 2 and later carry; else the tops of the
/// `x` and `H` glyphs; else shares of the ascent typical of text faces.
fn typographicHeightsOf(info: *const stbtt.stbtt_fontinfo, font: []const u8, ascent: f32) TypographicHeights {
    if (os2HeightsOf(font)) |heights| return heights;
    const estimated_from_ascent = heightsEstimatedFromAscent(ascent);
    return .{
        .x_height = glyphTopOf(info, 'x') orelse estimated_from_ascent.x_height,
        .cap_height = glyphTopOf(info, 'H') orelse estimated_from_ascent.cap_height,
    };
}

const os2_version_with_heights = 2;
const os2_x_height_offset = 86;
const os2_cap_height_offset = 88;

fn os2HeightsOf(font: []const u8) ?TypographicHeights {
    const table = tableOf(font, "OS/2") orelse return null;
    if (table.len < os2_cap_height_offset + 2) return null;
    if (std.mem.readInt(u16, table[0..2], .big) < os2_version_with_heights) return null;
    const x_height = std.mem.readInt(i16, table[os2_x_height_offset..][0..2], .big);
    const cap_height = std.mem.readInt(i16, table[os2_cap_height_offset..][0..2], .big);
    if (x_height <= 0 or cap_height <= 0) return null;
    return .{ .x_height = @floatFromInt(x_height), .cap_height = @floatFromInt(cap_height) };
}

/// The bytes of the table tagged `tag` in the font that starts at `font[0]`.
fn tableOf(font: []const u8, comptime tag: *const [4]u8) ?[]const u8 {
    const table_record_size = 16;
    const first_record = 12;
    if (font.len < first_record) return null;
    const table_count = std.mem.readInt(u16, font[4..6], .big);
    for (0..table_count) |index| {
        const record_start = first_record + index * table_record_size;
        if (record_start + table_record_size > font.len) return null;
        const record = font[record_start..][0..table_record_size];
        if (!std.mem.eql(u8, record[0..4], tag)) continue;
        const start = std.mem.readInt(u32, record[8..12], .big);
        const length = std.mem.readInt(u32, record[12..16], .big);
        if (@as(u64, start) + length > font.len) return null;
        return font[start..][0..length];
    }
    return null;
}

fn glyphTopOf(info: *const stbtt.stbtt_fontinfo, codepoint: u8) ?f32 {
    const glyph = stbtt.stbtt_FindGlyphIndex(info, codepoint);
    if (glyph == 0) return null;
    var x0: c_int = 0;
    var y0: c_int = 0;
    var x1: c_int = 0;
    var y1: c_int = 0;
    if (stbtt.stbtt_GetGlyphBox(info, glyph, &x0, &y0, &x1, &y1) == 0 or y1 <= 0) return null;
    return @floatFromInt(y1);
}

fn heightsEstimatedFromAscent(ascent: f32) TypographicHeights {
    return .{ .x_height = 0.55 * ascent, .cap_height = 0.75 * ascent };
}

fn expectHeights(expected_x_height: f32, expected_cap_height: f32, font: []const u8) !void {
    const face: Face = try .init(font);
    try std.testing.expectEqual(expected_x_height, face.metrics.x_height);
    try std.testing.expectEqual(expected_cap_height, face.metrics.cap_height);
}

test "each bundled face reports the x-height and cap height of its OS/2 table" {
    try expectHeights(496, 668, zui_fonts.atkinson_hyperlegible_regular);
    try expectHeights(496, 668, zui_fonts.atkinson_hyperlegible_bold);
    try expectHeights(1082, 1349, zui_fonts.liberation_mono_regular);
}

test "a face whose OS/2 table predates the heights takes them from the tops of x and H" {
    for ([_][]const u8{ zui_fonts.atkinson_hyperlegible_regular, zui_fonts.liberation_mono_regular }) |bundled| {
        const font = try std.testing.allocator.dupe(u8, bundled);
        defer std.testing.allocator.free(font);
        const os2 = tableOf(font, "OS/2").?;
        const os2_start = @intFromPtr(os2.ptr) - @intFromPtr(font.ptr);
        std.mem.writeInt(u16, font[os2_start..][0..2], 1, .big);
        try std.testing.expectEqual(null, os2HeightsOf(font));

        const from_os2: Face = try .init(bundled);
        const estimated: Face = try .init(font);
        try std.testing.expectEqual(glyphTopOf(&estimated.info, 'x').?, estimated.metrics.x_height);
        try std.testing.expectEqual(glyphTopOf(&estimated.info, 'H').?, estimated.metrics.cap_height);
        try std.testing.expectApproxEqRel(from_os2.metrics.x_height, estimated.metrics.x_height, 0.03);
        try std.testing.expectApproxEqRel(from_os2.metrics.cap_height, estimated.metrics.cap_height, 0.03);
    }
}

test "a face with neither the heights nor an x or H estimates them from its ascent" {
    try std.testing.expectEqual(TypographicHeights{ .x_height = 550, .cap_height = 750 }, heightsEstimatedFromAscent(1000));
    try std.testing.expectEqual(null, tableOf("too short", "OS/2"));
    const face: Face = try .init(zui_fonts.atkinson_hyperlegible_regular);
    try std.testing.expectEqual(null, glyphTopOf(&face.info, ' '));
}

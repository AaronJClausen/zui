const std = @import("std");
const layout_ = @import("layout.zig");
const Layout = layout_.Layout;
const layOut = layout_.layOut;

/// Text drawn larger than this many pixels is rasterized at this size and
/// scaled up.
pub const max_pixel_size = 160;

/// Text is rasterized at its size in physical pixels, so it is drawn one
/// texel per pixel, up to `max_pixel_size`.
pub fn rasterPixelSize(size: f32, pixels_per_unit: f32) u16 {
    return @intFromFloat(std.math.clamp(@round(size * pixels_per_unit), 1, max_pixel_size));
}

pub fn snapToPixel(value: f32, pixels_per_unit: f32) f32 {
    return @round(value * pixels_per_unit) / pixels_per_unit;
}

/// A rectangle by its edges, in layout units or texture coordinates.
pub const Edges = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

/// Where a glyph is drawn, in layout units, and the part of the atlas it
/// shows, in texture coordinates from 0 to 1.
pub const GlyphQuad = struct {
    position: Edges,
    texture: Edges,
};

/// The quads of a text command's glyphs on the pixel grid, from `next`.
pub fn GlyphQuads(comptime FontSource: type, comptime AtlasType: type) type {
    return struct {
        const Self = @This();

        layout: Layout(FontSource),
        atlas: *const AtlasType,
        origin_x: f32,
        baseline: f32,
        pixel_size: u16,
        units_per_raster_pixel: f32,
        pixels_per_unit: f32,

        /// The next glyph that covers any pixel and is in the atlas. Its
        /// quad reaches half a texel past the glyph's coverage on every
        /// side, into the blank texels the atlas keeps between glyphs: a
        /// filtered sample at the quad's edge is blank, so a pixel whose
        /// centre lies on a turned or scaled glyph's edge looks the same
        /// whether a rasterizer counts it in or out.
        pub fn next(self: *Self) ?GlyphQuad {
            const texel: f32 = 1.0 / @as(f32, AtlasType.side);
            const half_texel_units = 0.5 * self.units_per_raster_pixel;
            while (self.layout.next()) |placed| {
                const glyph = self.atlas.find(.{ .font = placed.font, .pixel_size = self.pixel_size, .codepoint = placed.codepoint }) orelse continue;
                if (glyph.width == 0) continue;
                const left = snapToPixel(self.origin_x + placed.x, self.pixels_per_unit) + @as(f32, @floatFromInt(glyph.offset[0])) * self.units_per_raster_pixel;
                const top = self.baseline + @as(f32, @floatFromInt(glyph.offset[1])) * self.units_per_raster_pixel;
                const texture_left = @as(f32, @floatFromInt(glyph.x)) * texel;
                const texture_top = @as(f32, @floatFromInt(glyph.y)) * texel;
                return .{
                    .position = .{
                        .left = left - half_texel_units,
                        .top = top - half_texel_units,
                        .right = left + @as(f32, @floatFromInt(glyph.width)) * self.units_per_raster_pixel + half_texel_units,
                        .bottom = top + @as(f32, @floatFromInt(glyph.height)) * self.units_per_raster_pixel + half_texel_units,
                    },
                    .texture = .{
                        .left = texture_left - 0.5 * texel,
                        .top = texture_top - 0.5 * texel,
                        .right = texture_left + (@as(f32, @floatFromInt(glyph.width)) + 0.5) * texel,
                        .bottom = texture_top + (@as(f32, @floatFromInt(glyph.height)) + 0.5) * texel,
                    },
                };
            }
            return null;
        }
    };
}

/// A text command's glyphs as `layOut` places them, drawn from `atlas`,
/// which `addFrameGlyphs` filled: the run starts at `bounds.x`, its glyph
/// box is centered down `bounds` with its baseline on a whole pixel, and
/// each glyph starts on a whole pixel. Null when `style.font` is not one of
/// `fonts`, for the renderer to draw in a font of its own.
///
/// ```zig
/// var quads = zui_glyphs.glyphQuads(self.fonts, atlas, line.content, bounds, line.style, pixels_per_unit) orelse return drawOwnFont(line);
/// while (quads.next()) |quad| texturedQuad(quad.position, quad.texture, line.style.color);
/// ```
pub fn glyphQuads(fonts: anytype, atlas: anytype, content: []const u8, bounds: anytype, style: anytype, pixels_per_unit: f32) ?GlyphQuads(@TypeOf(fonts), @typeInfo(@TypeOf(atlas)).pointer.child) {
    const layout = layOut(fonts, content, style, .pixel_grid) orelse return null;
    const metrics = layout.fontMetrics().?;
    const pixel_size = rasterPixelSize(style.size, pixels_per_unit);
    const scale = metrics.scaleFor(style.size);
    const glyph_box_height = (metrics.ascent - metrics.descent) * scale;
    return .{
        .layout = layout,
        .atlas = atlas,
        .origin_x = bounds.x,
        .baseline = snapToPixel(bounds.y + (bounds.height - glyph_box_height) / 2 + metrics.ascent * scale, pixels_per_unit),
        .pixel_size = pixel_size,
        .units_per_raster_pixel = style.size / @as(f32, @floatFromInt(pixel_size)),
        .pixels_per_unit = pixels_per_unit,
    };
}

const BoxFonts = @import("box_fonts.zig").BoxFonts;
const Fonts = @import("fonts.zig").Fonts;
const Atlas = @import("atlas.zig").Atlas;

test "text is rasterized at its size in physical pixels, up to the largest size" {
    try std.testing.expectEqual(32, rasterPixelSize(16, 2));
    try std.testing.expectEqual(max_pixel_size, rasterPixelSize(400, 1));
    try std.testing.expectEqual(1, rasterPixelSize(0, 1));
    try std.testing.expectEqual(10.5, snapToPixel(10.4, 2));
}

test "glyph coverage starts on whole pixels from the run's start, its baseline on a whole pixel, and its quad half a texel wider" {
    const atlas = try Atlas(.rgba8).create(std.testing.allocator);
    defer atlas.destroy(std.testing.allocator);
    const fonts = Fonts.of(&BoxFonts{});
    const Style = struct { font: u16 = 0, size: f32 = 20, letter_spacing: f32 = 0.3 };
    const pixel_size = rasterPixelSize(20, 2);
    for ("Hi W") |codepoint| _ = try atlas.findOrAdd(fonts, .{ .font = 0, .pixel_size = pixel_size, .codepoint = codepoint });
    const bounds = .{ .x = 10.3, .y = 5, .width = 100, .height = 30 };
    var quads = glyphQuads(fonts, atlas, "Hi W", bounds, Style{}, 2).?;
    var layout = layOut(fonts, "Hi W", Style{}, .pixel_grid).?;
    var drawn: u32 = 0;
    while (layout.next()) |placed| {
        if (placed.codepoint == ' ') continue;
        const quad = quads.next().?;
        const half_texel_units = 0.5 * quads.units_per_raster_pixel;
        try std.testing.expectEqual(snapToPixel(bounds.x + placed.x, 2), quad.position.left + half_texel_units);
        const coverage_bottom = quad.position.bottom - half_texel_units;
        try std.testing.expectEqual(@round(coverage_bottom * 2), coverage_bottom * 2);
        drawn += 1;
    }
    try std.testing.expectEqual(null, quads.next());
    try std.testing.expectEqual(3, drawn);
    try std.testing.expectEqual(null, glyphQuads(fonts, atlas, "x", bounds, Style{ .font = 9 }, 2));
}

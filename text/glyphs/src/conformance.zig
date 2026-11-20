const std = @import("std");
const layout = @import("layout.zig");
const Atlas = @import("atlas.zig").Atlas;

pub const FontsViolation = error{
    NoFontZero,
    MetricsInverted,
    NotAdditive,
    LineHeightNotTheFonts,
    GlyphsOutOfStep,
    CellsNotOneCellWide,
    MeasuredOtherwiseThanLaidOut,
    GlyphNotRasterized,
    UnknownFontAnswered,
};

/// What every font system's fonts must do for measuring and drawing to
/// agree, checked on its font 0: a run measures as its parts do, each glyph
/// starts where the one before ends and the last ends at the run's extent,
/// in cells every glyph is one cell, a glyph rasterizes into an atlas, and
/// an id it has no font for is not answered. `text` is a pointer to the
/// font system; one that is also zui's text contract must measure, with
/// `zuiMeasure`, exactly what it lays out for its `placement`.
///
/// ```zig
/// test "the fonts conform" {
///     var text: zui_truetype.Text = .{};
///     try zui_glyphs.expectFontsConform(&text, std.testing.allocator);
/// }
/// ```
pub fn expectFontsConform(text: anytype, gpa: std.mem.Allocator) !void {
    const metrics = text.fontMetrics(0) orelse return error.NoFontZero;
    if (!(metrics.ascent > 0 and metrics.descent <= 0 and metrics.line_gap >= 0)) return error.MetricsInverted;

    const words = [_][]const u8{ "Hello,", " ", "wide", " ", "w\u{f6}rld", "\xff" };
    for ([_]f32{ 0, 1.5 }) |letter_spacing| {
        const key: Key = .{ .size = 17, .letter_spacing = letter_spacing };
        const whole = layout.measure(text, "Hello, wide w\u{f6}rld\xff", key, .pixel_grid).?;
        var summed: f32 = 0;
        for (words) |word| summed += layout.measure(text, word, key, .pixel_grid).?[0];
        if (@abs(whole[0] - summed) > 1e-3 * whole[0]) return error.NotAdditive;
        if (whole[1] != metrics.lineHeight(key.size)) return error.LineHeightNotTheFonts;

        var laid_out = layout.layOut(text, "Hello, wide w\u{f6}rld\xff", key, .pixel_grid).?;
        var end: f32 = 0;
        while (laid_out.next()) |glyph| {
            if (@abs(glyph.x - end) > 1e-3 * whole[0]) return error.GlyphsOutOfStep;
            end = glyph.x + text.advance(0, glyph.codepoint) * metrics.scaleFor(key.size) + letter_spacing;
        }
        if (@abs(end - whole[0]) > 1e-3 * whole[0]) return error.GlyphsOutOfStep;

        const cells = layout.measure(text, "Hello, w\u{f6}rld", key, .{ .cells = .{ 8, 16 } }).?;
        if (cells[0] != 12 * (8 + letter_spacing) or cells[1] != 16) return error.CellsNotOneCellWide;

        const Text = @typeInfo(@TypeOf(text)).pointer.child;
        if (@hasDecl(Text, "zuiMeasure")) {
            const placement: layout.Placement = if (@hasField(Text, "placement")) text.placement else .pixel_grid;
            const laid_out_extent = layout.measure(text, "Hello, wide", key, placement).?;
            if (!std.meta.eql(text.zuiMeasure("Hello, wide", .{ .font = 0, .size = key.size, .letter_spacing = letter_spacing }), laid_out_extent)) return error.MeasuredOtherwiseThanLaidOut;
        }
    }

    const atlas = try Atlas(.rg8).create(gpa);
    defer atlas.destroy(gpa);
    const glyph = atlas.findOrAdd(text, .{ .font = 0, .pixel_size = 32, .codepoint = 'M' }) catch return error.GlyphNotRasterized;
    if (glyph.width == 0 or glyph.height == 0 or atlas.raster_refusals != 0) return error.GlyphNotRasterized;
    var covered = false;
    for (0..glyph.height) |row| {
        for (atlas.texels[(@as(usize, glyph.y) + row) * Atlas(.rg8).side + glyph.x ..][0..glyph.width]) |texel| covered = covered or texel[1] != 0;
    }
    if (!covered) return error.GlyphNotRasterized;

    if (text.fontMetrics(std.math.maxInt(u16)) != null) return error.UnknownFontAnswered;
}

const Key = struct { font: u16 = 0, size: f32, letter_spacing: f32 };

test "the box fonts conform" {
    try expectFontsConform(&@import("box_fonts.zig").BoxFonts{}, std.testing.allocator);
}

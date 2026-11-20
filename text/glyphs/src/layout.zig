const std = @import("std");
const fonts_ = @import("fonts.zig");
const FontId = fonts_.FontId;
const GlyphId = fonts_.GlyphId;
const FontMetrics = fonts_.FontMetrics;
const Codepoints = @import("codepoints.zig").Codepoints;

/// How a renderer places glyphs, which it declares as
/// `pub const glyph_placement: zui_glyphs.Placement`, and a font system
/// lays text out for, so that what is measured is what is drawn.
pub const Placement = union(enum) {
    /// Each glyph at its font's own advance, drawn from coverage
    /// rasterized on the grid of physical pixels.
    pixel_grid,
    /// Every glyph one cell of this size, in layout units, whatever its
    /// font, as a terminal draws.
    cells: [2]f32,
};

/// A glyph of a run, where the layout put it.
pub const PositionedGlyph = struct {
    font: FontId,
    codepoint: u21,
    /// The font's glyph for `codepoint`; in `.cells`, the codepoint.
    glyph: GlyphId,
    /// From the start of the run, along its baseline, in layout units.
    x: f32,
};

/// The glyphs of a run, one after another from `next`, each advancing the
/// pen by its own advance and the letter spacing after it. Without kerning,
/// so a run measures as its parts do wherever it is split. Made by
/// `layOut`.
pub fn Layout(comptime FontSource: type) type {
    return struct {
        const Self = @This();

        fonts: FontSource,
        font: FontId,
        size: f32,
        letter_spacing: f32,
        codepoints: Codepoints,
        spacing: Spacing,
        glyph_count: u32 = 0,
        /// Font units the pen has moved, in `.pixel_grid`.
        units: f32 = 0,

        const Spacing = union(enum) {
            pixel_grid: FontMetrics,
            cells: [2]f32,
        };

        pub fn next(self: *Self) ?PositionedGlyph {
            const codepoint = self.codepoints.next() orelse return null;
            const placed: PositionedGlyph = .{
                .font = self.font,
                .codepoint = codepoint,
                .glyph = switch (self.spacing) {
                    .pixel_grid => if (FontSource == void) unreachable else self.fonts.glyphIndex(self.font, codepoint),
                    .cells => codepoint,
                },
                .x = self.pen(),
            };
            self.advancePen(codepoint);
            return placed;
        }

        /// The run's width and its line's height, laying out every glyph
        /// that `next` has not given yet.
        pub fn extent(self: *Self) [2]f32 {
            while (self.codepoints.next()) |codepoint| self.advancePen(codepoint);
            return .{ self.pen(), switch (self.spacing) {
                .pixel_grid => |metrics| metrics.lineHeight(self.size),
                .cells => |cell_size| cell_size[1],
            } };
        }

        /// The font's metrics in `.pixel_grid`, or null in `.cells`.
        pub fn fontMetrics(self: *const Self) ?FontMetrics {
            return switch (self.spacing) {
                .pixel_grid => |metrics| metrics,
                .cells => null,
            };
        }

        fn pen(self: *const Self) f32 {
            const glyphs: f32 = @floatFromInt(self.glyph_count);
            return switch (self.spacing) {
                .pixel_grid => |metrics| self.units * metrics.scaleFor(self.size) + glyphs * self.letter_spacing,
                .cells => |cell_size| glyphs * (cell_size[0] + self.letter_spacing),
            };
        }

        fn advancePen(self: *Self, codepoint: u21) void {
            if (self.spacing == .pixel_grid) {
                if (FontSource == void) unreachable;
                self.units += self.fonts.advance(self.font, codepoint);
            }
            self.glyph_count += 1;
        }
    };
}

/// `run` laid out in the style `key` names (its `font`, `size` and
/// `letter_spacing`, as zui's `MeasureKey` has them) for `placement`, from
/// `fonts`: a font system, `Fonts`, or `{}` for `.cells` alone. Null when
/// the font is not one of `fonts`.
///
/// ```zig
/// pub fn zuiMeasure(self: *Text, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
///     var layout = zui_glyphs.layOut(self, run, key, self.placement) orelse return .{ 0, key.size };
///     return layout.extent();
/// }
/// ```
pub fn layOut(fonts: anytype, run: []const u8, key: anytype, placement: Placement) ?Layout(@TypeOf(fonts)) {
    const spacing: Layout(@TypeOf(fonts)).Spacing = switch (placement) {
        .pixel_grid => if (@TypeOf(fonts) == void) return null else .{ .pixel_grid = fonts.fontMetrics(key.font) orelse return null },
        .cells => |cell_size| .{ .cells = cell_size },
    };
    return .{
        .fonts = fonts,
        .font = key.font,
        .size = key.size,
        .letter_spacing = key.letter_spacing,
        .codepoints = .init(run),
        .spacing = spacing,
    };
}

/// The extent of `run` as `layOut` lays it out.
pub fn measure(fonts: anytype, run: []const u8, key: anytype, placement: Placement) ?[2]f32 {
    var layout = layOut(fonts, run, key, placement) orelse return null;
    return layout.extent();
}

const BoxFonts = @import("box_fonts.zig").BoxFonts;
const Fonts = fonts_.Fonts;

const Key = struct { font: FontId = 0, size: f32 = 20, letter_spacing: f32 = 0 };

test "a run measures as its words and spaces do, letter spacing after every glyph" {
    const boxes: BoxFonts = .{};
    const key: Key = .{ .letter_spacing = 2 };
    const whole = measure(&boxes, "one two", key, .pixel_grid).?;
    const parts = measure(&boxes, "one", key, .pixel_grid).?[0] + measure(&boxes, " ", key, .pixel_grid).?[0] + measure(&boxes, "two", key, .pixel_grid).?[0];
    try std.testing.expectApproxEqAbs(whole[0], parts, 1e-4);
    try std.testing.expectApproxEqAbs((6 * 500 + 300) * 0.02 + 7 * 2, whole[0], 1e-4);
    try std.testing.expectEqual(BoxFonts.metrics.lineHeight(20), whole[1]);
}

test "each glyph starts where the ones before it end, and the last ends at the extent" {
    const fonts = Fonts.of(&BoxFonts{});
    var layout = layOut(fonts, "Wi W", Key{ .font = 1, .letter_spacing = 1 }, .pixel_grid).?;
    var expected_x: f32 = 0;
    while (layout.next()) |glyph| {
        try std.testing.expectApproxEqAbs(expected_x, glyph.x, 1e-4);
        try std.testing.expectEqual(@as(GlyphId, glyph.codepoint), glyph.glyph);
        expected_x += fonts.advance(1, glyph.codepoint) * BoxFonts.metrics.scaleFor(20) + 1;
    }
    try std.testing.expectApproxEqAbs(expected_x, layout.extent()[0], 1e-4);
}

test "in cells every glyph is one cell wide, whatever its font, and the line one cell tall" {
    const key: Key = .{ .size = 40, .letter_spacing = 8 };
    try std.testing.expectEqual([2]f32{ 4 * 16, 16 }, measure({}, "café", key, .{ .cells = .{ 8, 16 } }).?);
    try std.testing.expectEqual(measure({}, "ab", key, .{ .cells = .{ 8, 16 } }).?[0], measure({}, "a", key, .{ .cells = .{ 8, 16 } }).?[0] + measure({}, "b", key, .{ .cells = .{ 8, 16 } }).?[0]);
    var layout = layOut(&BoxFonts{}, "Wi", key, .{ .cells = .{ 8, 16 } }).?;
    try std.testing.expectEqual(0, layout.next().?.x);
    try std.testing.expectEqual(16, layout.next().?.x);
}

test "a font the fonts do not have, or no fonts on a pixel grid, lays nothing out" {
    try std.testing.expectEqual(null, measure(&BoxFonts{}, "a", Key{ .font = BoxFonts.font_count }, .pixel_grid));
    try std.testing.expectEqual(null, measure({}, "a", Key{}, .pixel_grid));
    try std.testing.expectEqual(null, measure(Fonts.none, "a", Key{}, .pixel_grid));
}

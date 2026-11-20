const std = @import("std");

/// The number a text style names its font by, as zui's `FontId` is by
/// default.
pub const FontId = u16;
/// A glyph's number in its font.
pub const GlyphId = u32;

/// A font's vertical metrics, in font units. Sizes follow
/// `ScaleForPixelHeight`: text of size 16 makes `ascent - descent` 16
/// layout units tall.
pub const FontMetrics = struct {
    /// Above the baseline.
    ascent: f32,
    /// Below the baseline, so negative.
    descent: f32,
    line_gap: f32 = 0,

    /// Layout units per font unit for text of `size`.
    pub fn scaleFor(self: FontMetrics, size: f32) f32 {
        return size / (self.ascent - self.descent);
    }

    pub fn lineHeight(self: FontMetrics, size: f32) f32 {
        return (self.ascent - self.descent + self.line_gap) * self.scaleFor(size);
    }
};

/// The pixels a glyph's coverage covers when it is rasterized at a size.
pub const GlyphBox = struct {
    /// From the pen on the baseline to the top-left corner, in pixels.
    offset: [2]i32 = .{ 0, 0 },
    width: u32 = 0,
    height: u32 = 0,
};

/// A font system's fonts, for a renderer that must not name the font
/// system's type: any value with the methods below, erased behind a
/// pointer. `layOut`, the atlas and `glyphQuads` take either the font
/// system itself or this.
///
/// ```zig
/// // A font system provides, on `*const Self`:
/// pub fn fontMetrics(self: *const Self, font: FontId) ?FontMetrics; // null: not one of its fonts
/// pub fn advance(self: *const Self, font: FontId, codepoint: u21) f32; // font units
/// pub fn glyphIndex(self: *const Self, font: FontId, codepoint: u21) GlyphId;
/// pub fn glyphBox(self: *const Self, font: FontId, glyph: GlyphId, pixel_size: f32) GlyphBox;
/// // Writes one byte of coverage per pixel, `stride` bytes a row, allocating
/// // only from `scratch`; false when that ran out and the glyph is left blank.
/// pub fn rasterize(self: *const Self, font: FontId, glyph: GlyphId, pixel_size: f32, box: GlyphBox, coverage: []u8, stride: usize, scratch: []align(16) u8) bool;
///
/// // A renderer keeps them as:
/// renderer.fonts = zui_glyphs.Fonts.of(&text);
/// ```
pub const Fonts = struct {
    context: ?*const anyopaque,
    functions: *const Functions,
    /// Font ids below this are not these fonts; from it on, they are these
    /// fonts' ids from 0.
    first_font: FontId = 0,

    pub const Functions = struct {
        fontMetrics: *const fn (?*const anyopaque, FontId) ?FontMetrics,
        advance: *const fn (?*const anyopaque, FontId, u21) f32,
        glyphIndex: *const fn (?*const anyopaque, FontId, u21) GlyphId,
        glyphBox: *const fn (?*const anyopaque, FontId, GlyphId, f32) GlyphBox,
        rasterize: *const fn (?*const anyopaque, FontId, GlyphId, f32, GlyphBox, []u8, usize, []align(16) u8) bool,
    };

    /// No fonts at all: a renderer given these draws text only in fonts of
    /// its own.
    pub const none: Fonts = .{ .context = null, .functions = &.{
        .fontMetrics = noFontMetrics,
        .advance = noAdvance,
        .glyphIndex = noGlyphIndex,
        .glyphBox = noGlyphBox,
        .rasterize = noRaster,
    } };

    /// `provider`'s fonts, which must outlive what is made of them. A
    /// provider that declares `glyphFonts` makes its own.
    pub fn of(provider: anytype) Fonts {
        const Provider = @typeInfo(@TypeOf(provider)).pointer.child;
        if (Provider == Fonts) return provider.*;
        if (@hasDecl(Provider, "glyphFonts")) return provider.glyphFonts();
        const erased = struct {
            fn cast(context: ?*const anyopaque) *const Provider {
                return @ptrCast(@alignCast(context.?));
            }
            fn fontMetricsOf(context: ?*const anyopaque, font: FontId) ?FontMetrics {
                return cast(context).fontMetrics(font);
            }
            fn advanceOf(context: ?*const anyopaque, font: FontId, codepoint: u21) f32 {
                return cast(context).advance(font, codepoint);
            }
            fn glyphIndexOf(context: ?*const anyopaque, font: FontId, codepoint: u21) GlyphId {
                return cast(context).glyphIndex(font, codepoint);
            }
            fn glyphBoxOf(context: ?*const anyopaque, font: FontId, glyph: GlyphId, pixel_size: f32) GlyphBox {
                return cast(context).glyphBox(font, glyph, pixel_size);
            }
            fn rasterizeOf(context: ?*const anyopaque, font: FontId, glyph: GlyphId, pixel_size: f32, box: GlyphBox, coverage: []u8, stride: usize, scratch: []align(16) u8) bool {
                return cast(context).rasterize(font, glyph, pixel_size, box, coverage, stride, scratch);
            }
            const functions: Functions = .{
                .fontMetrics = fontMetricsOf,
                .advance = advanceOf,
                .glyphIndex = glyphIndexOf,
                .glyphBox = glyphBoxOf,
                .rasterize = rasterizeOf,
            };
        };
        return .{ .context = provider, .functions = &erased.functions };
    }

    /// These fonts under ids that start at `first`, for a text that numbers
    /// fonts of its own before them.
    pub fn startingAt(self: Fonts, first: FontId) Fonts {
        var moved = self;
        moved.first_font += first;
        return moved;
    }

    pub fn fontMetrics(self: *const Fonts, font: FontId) ?FontMetrics {
        if (font < self.first_font) return null;
        return self.functions.fontMetrics(self.context, font - self.first_font);
    }

    pub fn advance(self: *const Fonts, font: FontId, codepoint: u21) f32 {
        return self.functions.advance(self.context, font - self.first_font, codepoint);
    }

    pub fn glyphIndex(self: *const Fonts, font: FontId, codepoint: u21) GlyphId {
        return self.functions.glyphIndex(self.context, font - self.first_font, codepoint);
    }

    pub fn glyphBox(self: *const Fonts, font: FontId, glyph: GlyphId, pixel_size: f32) GlyphBox {
        return self.functions.glyphBox(self.context, font - self.first_font, glyph, pixel_size);
    }

    pub fn rasterize(self: *const Fonts, font: FontId, glyph: GlyphId, pixel_size: f32, box: GlyphBox, coverage: []u8, stride: usize, scratch: []align(16) u8) bool {
        return self.functions.rasterize(self.context, font - self.first_font, glyph, pixel_size, box, coverage, stride, scratch);
    }
};

fn noFontMetrics(_: ?*const anyopaque, _: FontId) ?FontMetrics {
    return null;
}

fn noAdvance(_: ?*const anyopaque, _: FontId, _: u21) f32 {
    unreachable;
}

fn noGlyphIndex(_: ?*const anyopaque, _: FontId, _: u21) GlyphId {
    unreachable;
}

fn noGlyphBox(_: ?*const anyopaque, _: FontId, _: GlyphId, _: f32) GlyphBox {
    unreachable;
}

fn noRaster(_: ?*const anyopaque, _: FontId, _: GlyphId, _: f32, _: GlyphBox, _: []u8, _: usize, _: []align(16) u8) bool {
    unreachable;
}

const BoxFonts = @import("box_fonts.zig").BoxFonts;

test "erased fonts answer as the font system does, under the ids they start at" {
    const boxes: BoxFonts = .{};
    const fonts = Fonts.of(&boxes).startingAt(6);
    try std.testing.expectEqual(null, fonts.fontMetrics(0));
    try std.testing.expectEqual(boxes.fontMetrics(0), fonts.fontMetrics(6));
    try std.testing.expectEqual(boxes.advance(0, 'W'), fonts.advance(6, 'W'));
    try std.testing.expectEqual(null, fonts.fontMetrics(6 + BoxFonts.font_count));
    try std.testing.expectEqual(null, Fonts.none.fontMetrics(0));
    try std.testing.expectEqual(fonts, Fonts.of(&fonts));
}

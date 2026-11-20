const std = @import("std");
const zui = @import("zui");
const zui_glyphs = @import("zui_glyphs");
const zui_truetype = @import("zui_truetype");

pub const Material = @import("material.zig").Material;

/// The optional commands zui-sokol's renderer draws.
pub const commands: zui.CommandSet = .initMany(&.{ .gradient, .shadow, .backdrop_blur, .transform, .material });

/// A texture as sokol_gl samples it: the ids of a sokol_gfx view and of
/// the sampler to draw it with. `zui_sokol.imageOf` makes one from sokol's
/// own handles.
pub const Image = struct {
    view: SokolId,
    sampler: SokolId,

    pub const SokolId = struct { id: u32 = 0 };
};

/// A `zui.Config` whose frames zui-sokol's renderer draws, declared
/// without sokol, so the application builds for targets sokol does not,
/// such as `wasm32-freestanding`, and streams its frames to a renderer
/// elsewhere. `zui_sokol.config` is this, checked against the renderer.
pub fn config(overrides: zui.Config) zui.Config {
    var result = overrides;
    result.Text = Text;
    result.commands = commands;
    result.extended_color = true;
    result.ImageHandle = Image;
    result.CustomData = void;
    result.MaterialHandle = Material;
    return result;
}

/// The text contract. `FontId` 0 to 5 are sokol_debugtext's built-in 8×8
/// bitmap fonts (0 = KC85/3), where every glyph is a square of the same
/// size; the TrueType fonts of `truetype` follow them, in the order
/// `addTrueTypeFont` added them, and are laid out through `zui_glyphs`,
/// as the renderer draws them. Given no TrueType font, `FontId` 6 is
/// Atkinson Hyperlegible Regular.
///
/// ```zig
/// var text: zui_sokol.Text = .{};
/// const body_font = try text.addTrueTypeFont(zui_fonts.atkinson_hyperlegible_regular);
/// ui.text("Hello", .{ .font = body_font, .size = 16 });
/// ```
pub const Text = struct {
    pub const bitmap_font_count = 6;
    /// Measuring only reads the fonts, so zui may measure a cold frame's
    /// texts on several threads.
    pub const zui_thread_safe = true;

    /// A bitmap glyph's height and advance as a fraction of the text size.
    glyph_scale: f32 = 0.75,
    truetype: zui_truetype.Text = .{},

    /// Returns the font's `FontId`. `data` must outlive the `Text`, as an
    /// `@embedFile` does. Add fonts before the first frame: measuring may
    /// run on other threads.
    pub fn addTrueTypeFont(self: *Text, data: []const u8) error{ InvalidFont, TooManyFonts }!u16 {
        return bitmap_font_count + try self.truetype.addFont(data);
    }

    pub fn zuiMeasure(self: *Text, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        if (key.font >= bitmap_font_count) {
            var truetype_key = key;
            truetype_key.font -= bitmap_font_count;
            return self.truetype.zuiMeasure(run, truetype_key);
        }
        return zui_glyphs.measure({}, run, key, .{ .cells = .{ self.glyphSize(key.size), key.size } }).?;
    }

    /// Covers the TrueType fonts, numbered after the bitmap fonts, and the
    /// bitmap glyphs' scale.
    pub fn zuiFingerprint(self: *const Text) u64 {
        return fingerprintAfterBitmapFonts(self.truetype.zuiFingerprint(), self.glyph_scale);
    }

    /// The TrueType fonts, under the ids the renderer draws them by.
    pub fn glyphFonts(self: *const Text) zui_glyphs.Fonts {
        return zui_glyphs.Fonts.of(&self.truetype).startingAt(bitmap_font_count);
    }

    pub fn glyphSize(self: *const Text, size: f32) f32 {
        return size * self.glyph_scale;
    }
};

/// What a text that numbers TrueType fonts after the six bitmap fonts
/// fingerprints itself with, so that two such texts with the same fonts
/// agree.
pub fn fingerprintAfterBitmapFonts(truetype_fingerprint: u64, glyph_scale: f32) u64 {
    var hasher = std.hash.Wyhash.init(Text.bitmap_font_count);
    hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, truetype_fingerprint)));
    hasher.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, @bitCast(glyph_scale))));
    return hasher.final();
}

fn measure(text: *Text, run: []const u8, letter_spacing: f32) [2]f32 {
    return text.zuiMeasure(run, .{ .font = 0, .size = 16, .letter_spacing = letter_spacing });
}

test "measurement is additive, with letter spacing after every glyph" {
    var text: Text = .{};
    const one = measure(&text, "one", 2);
    const space = measure(&text, " ", 2);
    const two = measure(&text, "two", 2);
    try std.testing.expectEqual(measure(&text, "one two", 2)[0], one[0] + space[0] + two[0]);
    try std.testing.expectEqual(@as(f32, 3 * (12 + 2)), one[0]);
}

test "config declares the renderer's text, images, materials and commands, and keeps the rest" {
    const derived = config(.{ .limits = .{ .max_elements = 128 }, .CustomData = u32 });
    try std.testing.expect(derived.ImageHandle == Image);
    try std.testing.expect(derived.MaterialHandle == Material);
    try std.testing.expect(derived.Text == Text);
    try std.testing.expect(derived.CustomData == void);
    try std.testing.expect(derived.extended_color);
    try std.testing.expectEqual(@as(u32, 128), derived.limits.max_elements);
}

test "TrueType fonts follow the bitmap fonts, and measure as they are laid out" {
    var text: Text = .{};
    try std.testing.expectEqual(Text.bitmap_font_count, try text.addTrueTypeFont(@import("zui_fonts").atkinson_hyperlegible_bold));
    const key: zui.MeasureKey(u16) = .{ .font = Text.bitmap_font_count, .size = 16, .letter_spacing = 1 };
    try std.testing.expectEqual(zui_glyphs.measure(text.glyphFonts(), "Bold", key, .pixel_grid).?, text.zuiMeasure("Bold", key));
    try std.testing.expectEqual(null, text.glyphFonts().fontMetrics(Text.bitmap_font_count - 1));
}

test {
    _ = @import("material.zig");
}

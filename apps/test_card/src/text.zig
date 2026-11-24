const std = @import("std");
const zui = @import("zui");
const zui_glyphs = @import("zui_glyphs");
const zui_fonts = @import("zui_fonts");

/// The typefaces the card's text is set in, each given to the font system
/// once, in this order.
pub const Typeface = enum {
    regular,
    bold,
    mono,

    fn bytes(typeface: Typeface) []const u8 {
        return switch (typeface) {
            .regular => zui_fonts.atkinson_hyperlegible_regular,
            .bold => zui_fonts.atkinson_hyperlegible_bold,
            .mono => zui_fonts.liberation_mono_regular,
        };
    }
};

/// The font id `Renderer`'s contexts name a font by.
pub fn FontIdOf(comptime Renderer: type) type {
    return if (@hasDecl(Renderer, "FontId")) Renderer.FontId else u16;
}

/// The card's text contract: `FontSystem`, a font system's text such as
/// `zui_truetype.Text`, given every `Typeface` by `init` and laid out for
/// the placement `Renderer` draws. Its `fonts` are the ids adding them
/// returned.
pub fn Text(comptime FontSystem: type, comptime Renderer: type) type {
    comptime checkFontSystem(FontSystem);
    const FontId = FontIdOf(Renderer);
    return struct {
        const Self = @This();
        pub const zui_thread_safe = @hasDecl(FontSystem, "zui_thread_safe") and FontSystem.zui_thread_safe;

        /// The id of each `Typeface` in the font system.
        pub const Fonts = std.enums.EnumFieldStruct(Typeface, FontId, null);

        font_system: FontSystem = .{},
        fonts: Fonts = undefined,

        pub fn init(self: *Self) !void {
            self.* = .{};
            if (@hasField(FontSystem, "placement")) self.font_system.placement = zui_glyphs.placementOf(Renderer);
            if (@hasDecl(FontSystem, "init")) try self.font_system.init();
            errdefer self.deinit();
            inline for (comptime std.enums.values(Typeface)) |typeface| {
                @field(self.fonts, @tagName(typeface)) = try self.font_system.addFont(typeface.bytes());
            }
        }

        pub fn deinit(self: *Self) void {
            if (@hasDecl(FontSystem, "deinit")) self.font_system.deinit();
        }

        pub fn zuiMeasure(self: *Self, run: []const u8, key: zui.MeasureKey(FontId)) [2]f32 {
            return self.font_system.zuiMeasure(run, key);
        }

        pub fn zuiFingerprint(self: *const Self) u64 {
            return self.font_system.zuiFingerprint();
        }

        /// The font system's fonts, for a renderer that draws them.
        pub fn glyphFonts(self: *const Self) zui_glyphs.Fonts {
            return .of(&self.font_system);
        }
    };
}

fn checkFontSystem(comptime FontSystem: type) void {
    const name = @typeName(FontSystem);
    if (@typeInfo(FontSystem) != .@"struct") @compileError("zui_test_card: the Text must be a font system's struct, such as zui_truetype.Text, got " ++ name);
    for ([_][]const u8{ "addFont", "zuiMeasure", "zuiFingerprint" }) |declaration| {
        if (!@hasDecl(FontSystem, declaration)) @compileError("zui_test_card: " ++ name ++ " has no `" ++ declaration ++ "`; the test card's Text is a font system that adds font files and measures with them, such as zui_truetype.Text");
    }
}

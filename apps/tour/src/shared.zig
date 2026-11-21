//! What every screen of the tour shares, whatever draws it: its sources,
//! screens, typefaces and palettes, and the text it measures with.

const std = @import("std");
const zui_glyphs = @import("zui_glyphs");
const zui_fonts = @import("zui_fonts");
pub const zui = @import("zui");
pub const zui_widgets = @import("zui_widgets");
pub const zui_reflect = @import("zui_reflect");
pub const zui_async = @import("zui_async");
pub const Perf = @import("perf.zig").Perf;
const mission = @import("screens/mission_control.zig");
const gallery = @import("screens/gallery.zig");

pub const Sources = struct {
    telemetry: mission.TelemetrySource = .{},
    mission_log: mission.LogSource = .{},
    launch: mission.LaunchTask = .{},
    tiles: gallery.TileLoads = .{},
    tile_outcomes: gallery.TileOutcomesSource = .{},
};

/// Every screen of the tour, in the rail's order. A renderer that does not
/// draw what a screen needs is not offered it: `Kit.offered_screens`.
pub const Screen = enum {
    welcome,
    layout_lab,
    box_storm,
    gallery,
    mission_control,
    window_manager,
    robot_workshop,
    pixel_pad,
    typography,
    light_and_depth,
    transforms,
    materials,
    classic,

    pub const Info = struct {
        title: []const u8,
        tagline: []const u8,
        features: []const []const u8,
        hue: f32,
    };
};

/// The three typefaces the tour's text is set in, each given to the font
/// system once.
pub const Typeface = enum {
    body,
    bold,
    mono,

    /// The name the typography screen shows it under.
    pub fn name(typeface: Typeface) []const u8 {
        return switch (typeface) {
            .body => "Atkinson Hyperlegible",
            .bold => "Atkinson Hyperlegible Bold",
            .mono => "Liberation Mono",
        };
    }

    fn bytes(typeface: Typeface) []const u8 {
        return switch (typeface) {
            .body => zui_fonts.atkinson_hyperlegible_regular,
            .bold => zui_fonts.atkinson_hyperlegible_bold,
            .mono => zui_fonts.liberation_mono_regular,
        };
    }
};

/// The font id `Renderer`'s contexts name a font by.
pub fn FontIdOf(comptime Renderer: type) type {
    return if (@hasDecl(Renderer, "FontId")) Renderer.FontId else u16;
}

/// The tour's text contract: `FontSystem`, a font system's text such as
/// `zui_truetype.Text`, given the three `Typeface`s by `init` and laid out
/// for the placement `Renderer` draws. Its `fonts` are the ids adding them
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
    if (@typeInfo(FontSystem) != .@"struct") @compileError("zui_tour: the Text must be a font system's struct, such as zui_truetype.Text, got " ++ name);
    for ([_][]const u8{ "addFont", "zuiMeasure", "zuiFingerprint" }) |declaration| {
        if (!@hasDecl(FontSystem, declaration)) @compileError("zui_tour: " ++ name ++ " has no `" ++ declaration ++ "`; the tour's Text is a font system that adds font files and measures with them, such as zui_truetype.Text");
    }
}

/// Whether `Material` is a pattern between two colors, as the materials
/// screen describes one: `.pattern` from its `Pattern` enum, `.first` and
/// `.second`, `.phase` in turns and `.scale` in layout units.
pub fn offersPatterns(comptime Material: type) bool {
    if (@typeInfo(Material) != .@"struct" or !@hasDecl(Material, "Pattern") or @typeInfo(Material.Pattern) != .@"enum") return false;
    for ([_][]const u8{ "pattern", "first", "second", "phase", "scale" }) |field| {
        if (!@hasField(Material, field)) return false;
    }
    return @FieldType(Material, "pattern") == Material.Pattern;
}

/// Where a dragged handle grabbed what it moves, kept under the handle's id.
pub const DragGrip = struct {
    active: bool = false,
    grab_offset: [2]f32 = .{ 0, 0 },
};

pub const Palette = struct {
    background: zui.Color,
    surface: zui.Color,
    sunken: zui.Color,
    raised: zui.Color,
    hovered: zui.Color,
    border: zui.Color,
    text: zui.Color,
    muted: zui.Color,
    faint: zui.Color,
    accent: zui.Color,
    on_accent: zui.Color,
    good: zui.Color,
    warn: zui.Color,
    bad: zui.Color,
    focus: zui.Color,
    overlay: zui.Color,

    pub const dark: Palette = .{
        .background = .rgb(0x111118),
        .surface = .rgb(0x1a1a24),
        .sunken = .rgb(0x0c0c12),
        .raised = .rgb(0x232332),
        .hovered = .rgb(0x2f2f44),
        .border = .rgb(0x33334a),
        .text = .rgb(0xeaeaf4),
        .muted = .rgb(0x9a9ab4),
        .faint = .rgb(0x5a5a74),
        .accent = .rgb(0x6c8cff),
        .on_accent = .rgb(0x0b0b14),
        .good = .rgb(0x4ade80),
        .warn = .rgb(0xfbbf24),
        .bad = .rgb(0xf87171),
        .focus = .rgb(0xffc65c),
        .overlay = .rgba(0x000000aa),
    };

    pub const light: Palette = .{
        .background = .rgb(0xeef0f6),
        .surface = .rgb(0xffffff),
        .sunken = .rgb(0xdde1ec),
        .raised = .rgb(0xf6f7fb),
        .hovered = .rgb(0xe2e7f8),
        .border = .rgb(0xc4c9d8),
        .text = .rgb(0x1b1d2a),
        .muted = .rgb(0x5b6077),
        .faint = .rgb(0x9aa0b4),
        .accent = .rgb(0x3355dd),
        .on_accent = .rgb(0xffffff),
        .good = .rgb(0x168a4a),
        .warn = .rgb(0xb7790b),
        .bad = .rgb(0xc93030),
        .focus = .rgb(0xe08a00),
        .overlay = .rgba(0x1b1d2a66),
    };

    pub fn forEnvironment(environment: *const zui.Environment) Palette {
        var palette = if (environment.theme == .dark) dark else light;
        if (environment.contrast == .high) {
            palette.border = palette.text;
            palette.muted = palette.text;
            palette.faint = palette.muted.mix(palette.text, 0.5);
        }
        return palette;
    }
};

pub const Tone = enum {
    hero,
    title,
    heading,
    body,
    caption,
    tiny,

    pub fn size(tone: Tone) f32 {
        return switch (tone) {
            .hero => 88,
            .title => 34,
            .heading => 22,
            .body => 16,
            .caption => 13,
            .tiny => 11,
        };
    }
};

/// Environment changes the application makes up, for the host to append to
/// the next frame record's events as if the OS had reported them.
pub const EnvironmentQueue = struct {
    changes: [16]zui.EnvironmentChange = undefined,
    count: usize = 0,

    pub fn push(self: *EnvironmentQueue, change: zui.EnvironmentChange) void {
        if (self.count == self.changes.len) return;
        self.changes[self.count] = change;
        self.count += 1;
    }

    pub fn drain(self: *EnvironmentQueue) []const zui.EnvironmentChange {
        const pending = self.changes[0..self.count];
        self.count = 0;
        return pending;
    }
};

/// A color around the hue wheel, for things that should look different
/// from their neighbours. `hue` wraps at 1.
pub fn hueColor(hue: f32, saturation: f32, value: f32) zui.Color {
    const wrapped = hue - @floor(hue);
    const sector = wrapped * 6;
    const chroma = value * saturation;
    const secondary = chroma * (1 - @abs(@mod(sector, 2) - 1));
    const lightness_offset = value - chroma;
    const rgb: [3]f32 = switch (@as(u3, @intFromFloat(@min(sector, 5.999)))) {
        0 => .{ chroma, secondary, 0 },
        1 => .{ secondary, chroma, 0 },
        2 => .{ 0, chroma, secondary },
        3 => .{ 0, secondary, chroma },
        4 => .{ secondary, 0, chroma },
        else => .{ chroma, 0, secondary },
    };
    return .{
        .r = @intFromFloat((rgb[0] + lightness_offset) * 255),
        .g = @intFromFloat((rgb[1] + lightness_offset) * 255),
        .b = @intFromFloat((rgb[2] + lightness_offset) * 255),
    };
}

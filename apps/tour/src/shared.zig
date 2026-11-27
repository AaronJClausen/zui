//! What every screen of the tour shares, whatever draws it: its sources,
//! screens and lanes, typefaces and colors, and the text it measures with.

const std = @import("std");
const zui_glyphs = @import("zui_glyphs");
const zui_fonts = @import("zui_fonts");
pub const zui = @import("zui");
pub const zui_widgets = @import("zui_widgets");
pub const zui_reflect = @import("zui_reflect");
pub const zui_async = @import("zui_async");
pub const Perf = @import("perf.zig").Perf;
const harbor = @import("screens/harbor.zig");
const photo_cull = @import("screens/photo_cull.zig");
const log_tail = @import("screens/log_tail.zig");
const quiet_machine = @import("screens/quiet_machine.zig");

pub const Sources = struct {
    harbor_metrics: harbor.MetricsSource = .{},
    harbor_events: harbor.EventSource = .{},
    photos: photo_cull.PhotoLoads = .{},
    photo_outcomes: photo_cull.PhotoOutcomesSource = .{},
    log_rate: log_tail.RateSource = .{},
    log_lines: log_tail.LineSource = .{},
    quiet_reading: quiet_machine.ReadingSource = .{},
};

/// Every screen of the tour, in the order Ctrl+PgDn steps through them; the
/// rail groups them by lane. A renderer that does not draw what a screen
/// needs is not offered it: `Kit.offered_screens`.
pub const Screen = enum {
    overview,
    harbor,
    x_ray,
    photo_cull,
    log_tail,
    kanban,
    settings_form,
    field_guide,
    quiet_machine,
    time_machine,
    break_it,
    gesture_arena,
    light_lab,
    one_declaration,
    cabin_booking,
    manifest,
    clickable_chaos,
    preferences,

    pub const Info = struct {
        title: []const u8,
        tagline: []const u8,
        features: []const []const u8,
        lane: Lane,
    };
};

/// The four ways the tour shows zui: where to start, a product built on it,
/// real problems solved plainly, and pages built to impress.
pub const Lane = enum {
    start,
    flagship,
    field_case,
    spectacle,

    pub fn name(lane: Lane) []const u8 {
        return switch (lane) {
            .start => "Start",
            .flagship => "Flagship",
            .field_case => "Field case",
            .spectacle => "Spectacle",
        };
    }

    pub fn emphasis(lane: Lane) Emphasis {
        return switch (lane) {
            .start => .neutral,
            .flagship, .spectacle => .accent,
            .field_case => .success,
        };
    }
};

/// A producer that runs only while the UI reads its source: the UI demands
/// it each frame it reads, releases it once it stops, and the producer
/// checks `keepGoing` before each publication.
pub const DemandedProducer = struct {
    const Phase = enum(u8) { stopped, running, stopping };

    phase: std.atomic.Value(Phase) = .init(.stopped),

    /// UI thread. Returns true when the caller must start the producer.
    pub fn demand(self: *DemandedProducer) bool {
        while (true) switch (self.phase.load(.acquire)) {
            .running => return false,
            .stopping => if (self.phase.cmpxchgWeak(.stopping, .running, .acq_rel, .acquire) == null) return false,
            .stopped => {
                self.phase.store(.running, .release);
                return true;
            },
        };
    }

    /// UI thread.
    pub fn release(self: *DemandedProducer) void {
        _ = self.phase.cmpxchgStrong(.running, .stopping, .acq_rel, .acquire);
    }

    /// Producer thread: false once it should exit, after which it must not publish.
    pub fn keepGoing(self: *DemandedProducer) bool {
        while (true) switch (self.phase.load(.acquire)) {
            .running => return true,
            .stopping => if (self.phase.cmpxchgStrong(.stopping, .stopped, .acq_rel, .acquire) == null) return false,
            .stopped => return false,
        };
    }
};

/// The typefaces the tour's text is set in, each given to the font system
/// once, in this order.
pub const Typeface = enum {
    body,
    bold,
    mono,
    italic,
    bold_italic,

    /// The typeface's family name, as a screen shows it.
    pub fn name(typeface: Typeface) []const u8 {
        return switch (typeface) {
            .body => "Atkinson Hyperlegible",
            .bold => "Atkinson Hyperlegible Bold",
            .mono => "Liberation Mono",
            .italic => "Atkinson Hyperlegible Italic",
            .bold_italic => "Atkinson Hyperlegible Bold Italic",
        };
    }

    fn bytes(typeface: Typeface) []const u8 {
        return switch (typeface) {
            .body => zui_fonts.atkinson_hyperlegible_regular,
            .bold => zui_fonts.atkinson_hyperlegible_bold,
            .mono => zui_fonts.liberation_mono_regular,
            .italic => zui_fonts.atkinson_hyperlegible_italic,
            .bold_italic => zui_fonts.atkinson_hyperlegible_bold_italic,
        };
    }
};

/// The font id `Renderer`'s contexts name a font by.
pub fn FontIdOf(comptime Renderer: type) type {
    return if (@hasDecl(Renderer, "FontId")) Renderer.FontId else u16;
}

/// The tour's text contract: `FontSystem`, a font system's text such as
/// `zui_truetype.Text`, given every `Typeface` by `init` and laid out
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

/// Whether `Material` is a pattern between two colors, as the light lab
/// describes one: `.pattern` from its `Pattern` enum, `.first` and
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

/// Each color role's color at rest, from the tokens the tour resolved:
/// `colors.get(.on_surface)`.
pub const Colors = std.EnumArray(zui.design.ColorRole, zui.Color);

/// What a color marks, with the roles that draw it as a fill, as a
/// container with text on it, or as text on a surface.
pub const Emphasis = enum {
    neutral,
    accent,
    success,
    warning,
    danger,

    pub fn fill(emphasis: Emphasis, colors: Colors) zui.Color {
        return colors.get(switch (emphasis) {
            .neutral => .outline,
            .accent => .accent,
            .success => .success,
            .warning => .warning,
            .danger => .danger,
        });
    }

    pub fn container(emphasis: Emphasis, colors: Colors) zui.Color {
        return colors.get(switch (emphasis) {
            .neutral => .secondary_container,
            .accent => .accent_container,
            .success => .success_container,
            .warning => .warning_container,
            .danger => .danger_container,
        });
    }

    /// Text on `container`.
    pub fn onContainer(emphasis: Emphasis, colors: Colors) zui.Color {
        return colors.get(switch (emphasis) {
            .neutral => .on_secondary_container,
            .accent => .on_accent_container,
            .success => .on_success_container,
            .warning => .on_warning_container,
            .danger => .on_danger_container,
        });
    }

    /// Text on any surface.
    pub fn text(emphasis: Emphasis, colors: Colors) zui.Color {
        return colors.get(switch (emphasis) {
            .neutral => .on_surface_muted,
            .accent => .on_surface_accent,
            .success => .on_success_container,
            .warning => .on_warning_container,
            .danger => .on_danger_container,
        });
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
            .hero => 56,
            .title => 28,
            .heading => 18,
            .body => 15,
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

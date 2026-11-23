const std = @import("std");
const zui = @import("zui");
const zui_design = @import("zui_design");
const zui_color = @import("zui_color");

const testing = std.testing;
const design = zui.design;

const Ui = zui.Context(.{ .limits = .{ .max_elements = 8 } });
pub const Tokens = design.Tokens(Ui, void);

/// The sRGB colors a design language publishes, which its seeds are
/// converted from. A null status is one whose hue the design moved, so the
/// default's tones tell it apart under every color vision.
pub const Sources = struct {
    accent: u24,
    neutral: u24,
    danger: ?u24,
    warning: ?u24,
    success: ?u24,
};

pub fn preferencesOf(scheme: zui_design.Scheme, density: design.Density) zui_design.Preferences {
    return .{
        .theme = if (scheme == .light or scheme == .light_high_contrast) .light else .dark,
        .contrast = scheme.environmentContrast(),
        .density = density,
    };
}

/// Fails the build, with the resolver's message naming the role, when a
/// scheme or a density needs `language`'s own seeds repaired; otherwise
/// counts what was kept, which a design checked this way never has.
pub fn repairsAtComptime(comptime language: design.Design) u32 {
    return comptime count: {
        var count: u32 = 0;
        for (std.enums.values(zui_design.Scheme)) |scheme| {
            for (std.enums.values(design.Density)) |density| {
                var tokens: Tokens = .{};
                count += zui_design.resolve(language, preferencesOf(scheme, density), &tokens).kept_count;
            }
        }
        break :count count;
    };
}

pub fn expectEveryPairMeetsItsTarget(language: design.Design) !void {
    for (std.enums.values(zui_design.Scheme)) |scheme| {
        for (std.enums.values(design.Density)) |density| {
            var tokens: Tokens = .{};
            _ = zui_design.resolve(language, preferencesOf(scheme, density), &tokens);
            const colors = tokens.colors.get(.idle);
            for (zui_design.checked_pairs) |pair| {
                const measured: zui_design.Contrast = .of(colors.get(pair.foreground), colors.get(pair.background));
                if (!measured.meets(pair.target(scheme.environmentContrast()))) {
                    std.debug.print("{s}: {t} on {t} in {s} at {t} is Lc {d:.1}, {d:.2}:1\n", .{ language.name, pair.foreground, pair.background, scheme.name(), density, measured.lightness_contrast, measured.ratio });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

/// A design changes seeds, never a tone: each role keeps the default's
/// lightness and alpha in every scheme.
pub fn expectTheDefaultsTones(language: design.Design) !void {
    for (std.enums.values(zui_design.Scheme)) |scheme| {
        var language_repairs: zui_design.Repairs = .{};
        var default_repairs: zui_design.Repairs = .{};
        const preferences = preferencesOf(scheme, .comfortable);
        const own = zui_design.palettesFor(language.seeds, preferences, &language_repairs).get(.idle);
        const default = zui_design.palettesFor(zui_design.default.seeds, preferences, &default_repairs).get(.idle);
        try testing.expectEqual(0, language_repairs.kept_count);
        for (std.enums.values(design.ColorRole)) |role| {
            try testing.expectEqual(default.get(role).color.lightness, own.get(role).color.lightness);
            try testing.expectEqual(default.get(role).alpha, own.get(role).alpha);
        }
    }
}

pub fn expectSeedsConvertedFrom(language: design.Design, sources: Sources) !void {
    try expectSeedOf(sources.accent, language.seeds.accent);
    try expectSeedOf(sources.neutral, language.seeds.neutral);
    if (sources.danger) |danger| try expectHueOf(danger, language.seeds.danger_hue.?);
    if (sources.warning) |warning| try expectHueOf(warning, language.seeds.warning_hue.?);
    if (sources.success) |success| try expectHueOf(success, language.seeds.success_hue.?);
}

/// A hue `language` moved from its source's by no more than `most_moved`
/// degrees.
pub fn expectHueMovedFrom(hex: u24, hue: f32, most_moved: f32) !void {
    const converted: zui_color.Oklch = .fromColor(.rgb(hex));
    try testing.expect(@abs(converted.hue_degrees - hue) <= most_moved);
}

fn expectSeedOf(hex: u24, seed: design.Oklch) !void {
    const converted: zui_color.Oklch = .fromColor(.rgb(hex));
    try testing.expectApproxEqAbs(converted.lightness, seed.lightness, 0.0005);
    try testing.expectApproxEqAbs(converted.chroma, seed.chroma, 0.0005);
    if (converted.chroma > 0.001) try expectHueOf(hex, seed.hue);
}

fn expectHueOf(hex: u24, hue: f32) !void {
    const converted: zui_color.Oklch = .fromColor(.rgb(hex));
    try testing.expectApproxEqAbs(converted.hue_degrees, hue, 0.05);
}

/// The system's accent replaces the seed's: the accent fill is the
/// system's color, in its hue, in every scheme.
pub fn expectTheSystemsAccent(language: design.Design, system_accent: u24) !void {
    const chosen: zui_color.Oklch = .fromColor(.rgb(system_accent));
    for ([_]zui.Environment.Theme{ .light, .dark }) |theme| {
        const environment: zui.Environment = .{ .theme = theme, .accent = .rgb(system_accent) };
        var tokens: Tokens = .{};
        _ = zui_design.resolve(language, .from(&environment, .{}), &tokens);
        const accent: zui_color.Oklch = .fromColor(tokens.colors.get(.idle).get(.accent));
        try testing.expectApproxEqAbs(chosen.hue_degrees, accent.hue_degrees, 1);
        try testing.expect(@abs(accent.hue_degrees - language.seeds.accent.hue) > 1);
    }
}

/// What the design declares besides its colors reaches its tokens.
pub fn expectTheDesignsShapesTypeAndMotion(language: design.Design) !void {
    for (std.enums.values(design.Density)) |density| {
        var tokens: Tokens = .{};
        _ = zui_design.resolve(language, .{ .density = density }, &tokens);
        try testing.expectEqual(language.density.get(density), tokens.spacing);
        for (std.enums.values(design.ShapeRole)) |role| {
            try testing.expectEqual(zui_design.cornerRadiusOf(language.shapes.get(role), density), tokens.corner_radii.get(role).top_left);
            try testing.expectEqual(language.corner_shape, tokens.corner_shapes.get(role));
        }
        try testing.expectApproxEqAbs(language.type.body_size, tokens.text_styles.get(.body).size, 0.001);
        try testing.expectApproxEqAbs(language.type.body_size * language.type.ratio, tokens.text_styles.get(.title).size, 0.001);
        try testing.expectEqual(language.motion, tokens.motion);
    }
}

/// Every check a design language passes, but the comptime resolve, which
/// each language's test calls itself so a failure names it.
pub fn expectAll(language: design.Design, sources: Sources, system_accent: u24) !void {
    try expectEveryPairMeetsItsTarget(language);
    try expectTheDefaultsTones(language);
    try expectSeedsConvertedFrom(language, sources);
    try expectTheSystemsAccent(language, system_accent);
    try expectTheDesignsShapesTypeAndMotion(language);
}

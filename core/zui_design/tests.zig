const std = @import("std");
const zui = @import("zui");
const zui_design = @import("zui_design.zig");
const oklab = @import("oklab.zig");

const testing = std.testing;
const design = zui.design;

const Ui = zui.Context(.{ .limits = .{ .max_elements = 8 } });
const FontIdUi = zui.Context(.{ .limits = .{ .max_elements = 8 }, .FontId = FontId });
const FontId = enum(u8) { regular, strong, monospace };
const ExtendedUi = zui.Context(.{ .limits = .{ .max_elements = 8 }, .Color = zui.ExtendedColor });
const Tokens = design.Tokens(Ui, void);

const harbor: design.Design = .{
    .seeds = .{ .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 }, .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 } },
    .corner_shape = .continuous,
};

const every_density = std.enums.values(design.Density);
const every_theme = std.enums.values(zui.Environment.Theme);
const every_contrast = std.enums.values(zui.Environment.Contrast);

const poison: zui.Color = .rgba(0x12345601);

/// Tokens whose every field holds a value no resolve writes, so a field
/// still holding it was not written.
fn poisonedTokens() Tokens {
    return .{
        .colors = .initFill(.initFill(poison)),
        .spacing = .initFill(-1),
        .text_padding_scale = -1,
        .text_styles = .initFill(.{ .size = -1 }),
        .corner_radii = .initFill(.all(-1)),
        .corner_shapes = .initFill(.chamfer),
        .target_floors = .initFill(-1),
        .outline_width = -1,
        .focus_ring_width = -1,
        .measure = -1,
    };
}

fn expectEveryFieldWritten(tokens: *const Tokens) !void {
    for (tokens.colors.values) |by_role| {
        for (by_role.values) |color| try testing.expect(!color.eql(poison));
    }
    for (tokens.spacing.values) |length| try testing.expect(length >= 0);
    try testing.expect(tokens.text_padding_scale > 0);
    for (tokens.text_styles.values) |text_style| try testing.expect(text_style.size > 0);
    for (tokens.corner_radii.values) |radius| try testing.expect(radius.top_left >= 0 and radius.bottom_right >= 0);
    for (tokens.corner_shapes.values) |shape| try testing.expectEqual(harbor.corner_shape, shape);
    for (tokens.target_floors.values) |floor| try testing.expect(floor >= 0);
    try testing.expect(tokens.outline_width > 0);
    try testing.expect(tokens.focus_ring_width > 0);
    try testing.expect(tokens.measure > 0);
}

test "Preferences.from takes the environment's settings and the user's choices" {
    const environment: zui.Environment = .{ .theme = .dark, .contrast = .high, .text_scale = 1.5, .reduced_transparency = true };
    const preferences: zui_design.Preferences = .from(&environment, .{ .density = .roomy, .color_vision = .deutan, .corners = .rounder, .pointer = .touch, .accent = .rgb(0xff8800) });
    try testing.expectEqual(zui_design.Preferences{
        .theme = .dark,
        .contrast = .high,
        .text_scale = 1.5,
        .reduced_transparency = true,
        .accent = .rgb(0xff8800),
        .density = .roomy,
        .color_vision = .deutan,
        .corners = .rounder,
        .pointer = .touch,
    }, preferences);
    try testing.expectEqual(zui_design.Preferences{}, zui_design.Preferences.from(&.{}, .{}));
}

test "resolve writes every field in every theme and contrast at every density" {
    for (every_theme) |theme| {
        for (every_contrast) |contrast| {
            for (every_density) |density| {
                var tokens = poisonedTokens();
                _ = zui_design.resolve(harbor, .{ .theme = theme, .contrast = contrast, .density = density }, &tokens);
                try expectEveryFieldWritten(&tokens);
            }
        }
    }
}

test "spacing is the design's density table" {
    for (every_density) |density| {
        var tokens: Tokens = .{};
        _ = zui_design.resolve(harbor, .{ .density = density }, &tokens);
        try testing.expectEqual(design.Design.default_density.get(density), tokens.spacing);
        try testing.expectEqual(design.Design.default_density.get(density).get(.m), tokens.space(.m));
    }
    var custom = harbor;
    custom.density.set(.compact, .initFill(3));
    var tokens: Tokens = .{};
    _ = zui_design.resolve(custom, .{ .density = .compact }, &tokens);
    try testing.expectEqual(3, tokens.space(.xl));
}

test "corners follow the shape table and move one size with the preference" {
    var tokens: Tokens = .{};
    _ = zui_design.resolve(harbor, .{}, &tokens);
    try testing.expectEqual(zui.CornerRadius.all(4), tokens.corner_radii.get(.control));
    try testing.expectEqual(zui.CornerRadius.all(8), tokens.corner_radii.get(.container));
    try testing.expectEqual(zui.CornerRadius.all(zui_design.bubble_radius), tokens.corner_radii.get(.chip));

    _ = zui_design.resolve(harbor, .{ .density = .compact }, &tokens);
    try testing.expectEqual(zui.CornerRadius.all(2), tokens.corner_radii.get(.control));

    _ = zui_design.resolve(harbor, .{ .corners = .sharper }, &tokens);
    try testing.expectEqual(zui.CornerRadius.all(0), tokens.corner_radii.get(.control));
    try testing.expectEqual(zui.CornerRadius.all(4), tokens.corner_radii.get(.container));
    try testing.expectEqual(zui.CornerRadius.all(16), tokens.corner_radii.get(.chip));

    _ = zui_design.resolve(harbor, .{ .corners = .rounder }, &tokens);
    try testing.expectEqual(zui.CornerRadius.all(8), tokens.corner_radii.get(.control));
    try testing.expectEqual(zui.CornerRadius.all(16), tokens.corner_radii.get(.container));
    try testing.expectEqual(zui.CornerRadius.all(zui_design.bubble_radius), tokens.corner_radii.get(.chip));

    for (std.enums.values(design.CornerSize)) |size| {
        try testing.expectEqual(size, zui_design.cornerSizeFor(size, .as_designed));
    }
    try testing.expectEqual(.square, zui_design.cornerSizeFor(.square, .sharper));
    try testing.expectEqual(.bubble, zui_design.cornerSizeFor(.bubble, .rounder));
}

test "target floors hold at every density, and a touch pointer raises them" {
    for (every_density) |density| {
        var tokens: Tokens = .{};
        _ = zui_design.resolve(harbor, .{ .density = density }, &tokens);
        try testing.expectEqual(0, tokens.target_floors.get(.none));
        try testing.expectEqual(24, tokens.target_floors.get(.pointer));
        try testing.expectEqual(44, tokens.target_floors.get(.touch));
        try testing.expectEqual(2, tokens.focus_ring_width);

        _ = zui_design.resolve(harbor, .{ .density = density, .pointer = .touch }, &tokens);
        try testing.expectEqual(44, tokens.target_floors.get(.pointer));
    }
}

test "text scale reaches padding by half, captions fully and display by its square root" {
    var tokens: Tokens = .{};
    _ = zui_design.resolve(harbor, .{}, &tokens);
    try testing.expectEqual(1, tokens.text_padding_scale);
    try testing.expectEqual(15, tokens.text_styles.get(.body).size);
    try testing.expectApproxEqAbs(15 * 1.2, tokens.text_styles.get(.title).size, 0.001);
    try testing.expectApproxEqAbs(15.0 / (1.2 * 1.2), tokens.text_styles.get(.caption).size, 0.001);
    const caption = tokens.text_styles.get(.caption).size;
    const display = tokens.text_styles.get(.display).size;

    _ = zui_design.resolve(harbor, .{ .text_scale = 2 }, &tokens);
    try testing.expectEqual(1.5, tokens.text_padding_scale);
    try testing.expectApproxEqAbs(caption * 2, tokens.text_styles.get(.caption).size, 0.001);
    try testing.expectApproxEqAbs(display * @sqrt(2.0), tokens.text_styles.get(.display).size, 0.001);
}

test "text styles take the design's fonts in the context's FontId" {
    var with_fonts = harbor;
    with_fonts.type.fonts = .{ .regular = 0, .strong = 1, .monospace = 2 };
    var tokens: design.Tokens(FontIdUi, void) = .{};
    _ = zui_design.resolve(with_fonts, .{}, &tokens);
    try testing.expectEqual(FontId.regular, tokens.text_styles.get(.body).font);
    try testing.expectEqual(FontId.strong, tokens.text_styles.get(.body_strong).font);
    try testing.expectEqual(FontId.monospace, tokens.text_styles.get(.code).font);
}

test "resolve runs at comptime in every theme and contrast" {
    const resolved = comptime resolved: {
        var all: [2][2]Tokens = undefined;
        for (every_theme, &all) |theme, *by_contrast| {
            for (every_contrast, by_contrast) |contrast, *tokens| {
                tokens.* = poisonedTokens();
                _ = zui_design.resolve(harbor, .{ .theme = theme, .contrast = contrast }, tokens);
            }
        }
        break :resolved all;
    };
    for (resolved) |by_contrast| {
        for (by_contrast) |tokens| try expectEveryFieldWritten(&tokens);
    }
}

test "OKLab round-trips sRGB and keeps a mapped color in gamut" {
    for ([_]zui.Color{ .rgb(0x000000), .rgb(0xffffff), .rgb(0x3366ff), .rgb(0xff8800), .rgb(0x10a050) }) |color| {
        const linear = oklab.gamutMappedLinear(oklab.oklchOfColor(color));
        const back = oklab.colorOfLinear(linear, 1);
        inline for (.{ "r", "g", "b" }) |channel| {
            try testing.expect(@abs(@as(i16, @field(color, channel)) - @as(i16, @field(back, channel))) <= 1);
        }
    }
    const too_vivid: design.Oklch = .{ .lightness = 0.9, .chroma = 0.4, .hue = 264 };
    try testing.expect(oklab.isInGamut(oklab.gamutMappedLinear(too_vivid)));
}

const Roles = enum {
    brand,
    on_brand,
    chart_line,
    badge,
    on_badge,
    on_chart_label,

    pub const zuiPairs = .{
        .brand = .on_brand,
        .on_brand = .brand,
        .chart_line = .surface,
        .badge = .on_badge,
        .on_badge = .accent_container,
        .on_chart_label = .chart_line,
    };
};

fn hueDistance(from: f32, to: f32) f32 {
    const apart = @abs(from - to);
    return @min(apart, 360 - apart);
}

fn relativeLuminance(color: zui.ExtendedColor) f32 {
    return 0.2126 * @as(f32, color.r) + 0.7152 * @as(f32, color.g) + 0.0722 * @as(f32, color.b);
}

fn wcagRatio(foreground: zui.ExtendedColor, background: zui.ExtendedColor) f32 {
    const lighter = @max(relativeLuminance(foreground), relativeLuminance(background));
    const darker = @min(relativeLuminance(foreground), relativeLuminance(background));
    return (lighter + 0.05) / (darker + 0.05);
}

test "a seed of each of twelve hues resolves in gamut and without NaN in every scheme" {
    for (0..12) |step| {
        const hue: f32 = @floatFromInt(step * 30);
        var seeded = harbor;
        seeded.seeds = .{ .accent = .{ .lightness = 0.6, .chroma = 0.25, .hue = hue }, .neutral = .{ .lightness = 0.5, .chroma = 0.03, .hue = hue }, .danger_hue = hue };
        for (every_theme) |theme| {
            for (every_contrast) |contrast| {
                for ([_]bool{ false, true }) |reduced_transparency| {
                    var tokens: design.Tokens(ExtendedUi, void) = .{};
                    _ = zui_design.resolve(seeded, .{ .theme = theme, .contrast = contrast, .reduced_transparency = reduced_transparency }, &tokens);
                    for (tokens.colors.values) |by_role| {
                        for (by_role.values) |color| {
                            inline for (.{ "r", "g", "b", "a" }) |channel| {
                                const value: f32 = @field(color, channel);
                                try testing.expect(!std.math.isNan(value));
                                try testing.expect(value >= 0 and value <= 1);
                            }
                        }
                    }
                }
            }
        }
    }
}

test "roles take their seed's hue, and a chosen accent replaces it" {
    const palettes = zui_design.palettesFor(harbor.seeds, .{});
    const idle = palettes.get(.idle);
    try testing.expectEqual(250, idle.get(.accent).color.hue);
    try testing.expectEqual(250, idle.get(.surface).color.hue);
    try testing.expectApproxEqAbs(0.01, idle.get(.surface).color.chroma, 0.0001);
    try testing.expect(hueDistance(idle.get(.danger).color.hue, 27) < 1);

    const orange: zui.Color = .rgb(0xff8800);
    const chosen = zui_design.palettesFor(harbor.seeds, .{ .accent = orange }).get(.idle);
    const orange_hue = oklab.oklchOfColor(orange).hue;
    try testing.expectApproxEqAbs(orange_hue, chosen.get(.accent).color.hue, 0.01);
    try testing.expectApproxEqAbs(orange_hue, chosen.get(.focus).color.hue, 0.01);
    try testing.expectEqual(idle.get(.surface), chosen.get(.surface));

    var with_hues = harbor;
    with_hues.seeds.success_hue = 180;
    try testing.expectEqual(180, zui_design.palettesFor(with_hues.seeds, .{}).get(.idle).get(.success).color.hue);
}

test "dark raises its surfaces lighter, and high contrast moves text further from its surface" {
    for ([_]zui.Environment.Contrast{ .normal, .high }) |contrast| {
        const dark = zui_design.palettesFor(harbor.seeds, .{ .theme = .dark, .contrast = contrast }).get(.idle);
        try testing.expect(dark.get(.surface_raised).color.lightness > dark.get(.surface).color.lightness);
        try testing.expect(dark.get(.surface).color.lightness > dark.get(.background).color.lightness);
        try testing.expect(dark.get(.on_surface).color.lightness > dark.get(.surface).color.lightness);
        const light = zui_design.palettesFor(harbor.seeds, .{ .contrast = contrast }).get(.idle);
        try testing.expect(light.get(.on_surface).color.lightness < light.get(.surface).color.lightness);
    }
    for (every_theme) |theme| {
        const normal = zui_design.palettesFor(harbor.seeds, .{ .theme = theme }).get(.idle);
        const high = zui_design.palettesFor(harbor.seeds, .{ .theme = theme, .contrast = .high }).get(.idle);
        const normal_apart = @abs(normal.get(.on_surface).color.lightness - normal.get(.surface).color.lightness);
        const high_apart = @abs(high.get(.on_surface).color.lightness - high.get(.surface).color.lightness);
        try testing.expect(high_apart > normal_apart);
    }
}

test "on_surface on surface meets WCAG 2's 4.5:1 before contrast is solved" {
    for (every_theme) |theme| {
        for (every_contrast) |contrast| {
            var tokens: design.Tokens(ExtendedUi, void) = .{};
            _ = zui_design.resolve(harbor, .{ .theme = theme, .contrast = contrast }, &tokens);
            const idle = tokens.colors.get(.idle);
            try testing.expect(wcagRatio(idle.get(.on_surface), idle.get(.surface)) >= 4.5);
        }
    }
}

test "a fill's state layers differ from idle, its text stays, and disabled greys and fades" {
    for (every_theme) |theme| {
        for (every_contrast) |contrast| {
            var tokens: Tokens = .{};
            _ = zui_design.resolve(harbor, .{ .theme = theme, .contrast = contrast }, &tokens);
            for ([_]design.ColorRole{ .surface, .accent, .accent_container, .secondary_container, .danger, .warning, .success }) |fill| {
                const idle = tokens.colors.get(.idle).get(fill);
                const hovered = tokens.colors.get(.hovered).get(fill);
                const pressed = tokens.colors.get(.pressed).get(fill);
                try testing.expect(!hovered.eql(idle));
                try testing.expect(!pressed.eql(idle));
                try testing.expect(!pressed.eql(hovered));
                try testing.expect(!tokens.colors.get(.focused).get(fill).eql(idle));
            }
            for ([_]design.ColorRole{ .accent, .on_accent, .on_surface, .outline }) |role| {
                const disabled = tokens.colors.get(.disabled).get(role);
                try testing.expect(disabled.a < tokens.colors.get(.idle).get(role).a);
                try testing.expect(disabled.r == disabled.g or @abs(@as(i16, disabled.r) - @as(i16, disabled.g)) <= 2);
            }
            try testing.expectEqual(tokens.colors.get(.idle).get(.on_accent), tokens.colors.get(.hovered).get(.on_accent));
            try testing.expectEqual(tokens.colors.get(.idle).get(.background), tokens.colors.get(.disabled).get(.background));
        }
    }
}

test "reduced transparency makes the scrim more opaque" {
    var tokens: Tokens = .{};
    _ = zui_design.resolve(harbor, .{}, &tokens);
    const translucent = tokens.colors.get(.idle).get(.scrim).a;
    _ = zui_design.resolve(harbor, .{ .reduced_transparency = true }, &tokens);
    try testing.expect(tokens.colors.get(.idle).get(.scrim).a > translucent);
}

test "extra roles take the colors of the built-in roles their pairs name" {
    try testing.expectEqual(.accent, comptime zui_design.builtInRoleOf(Roles, .brand));
    try testing.expectEqual(.on_accent, comptime zui_design.builtInRoleOf(Roles, .on_brand));
    try testing.expectEqual(.on_surface, comptime zui_design.builtInRoleOf(Roles, .chart_line));
    try testing.expectEqual(.on_accent_container, comptime zui_design.builtInRoleOf(Roles, .on_badge));
    try testing.expectEqual(.accent_container, comptime zui_design.builtInRoleOf(Roles, .badge));
    try testing.expectEqual(.surface, comptime zui_design.builtInRoleOf(Roles, .on_chart_label));

    var tokens: design.Tokens(Ui, Roles) = .{};
    _ = zui_design.resolve(harbor, .{ .theme = .dark }, &tokens);
    for (std.enums.values(zui.WidgetState)) |state| {
        try testing.expectEqual(tokens.colors.get(state).get(.accent), tokens.extra_colors.get(state).get(.brand));
        try testing.expectEqual(tokens.colors.get(state).get(.on_surface), tokens.extra_colors.get(state).get(.chart_line));
    }
}

test "a resolve at comptime matches one at run time" {
    const at_comptime = comptime resolved: {
        var tokens: design.Tokens(Ui, Roles) = .{};
        _ = zui_design.resolve(harbor, .{ .theme = .dark, .contrast = .high, .accent = .rgb(0x10a050) }, &tokens);
        break :resolved tokens;
    };
    var at_run_time: design.Tokens(Ui, Roles) = .{};
    _ = zui_design.resolve(harbor, .{ .theme = .dark, .contrast = .high, .accent = .rgb(0x10a050) }, &at_run_time);
    try testing.expectEqual(at_comptime.colors, at_run_time.colors);
    try testing.expectEqual(at_comptime.extra_colors, at_run_time.extra_colors);
}

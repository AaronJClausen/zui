const std = @import("std");
const zui = @import("zui");
const zui_design = @import("zui_design.zig");
const oklab = @import("oklab.zig");
const contrast_solver = @import("contrast.zig");
const color_vision = @import("color_vision.zig");
const palette = @import("palette.zig");

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

fn palettesOf(seeds: design.Design.Seeds, preferences: zui_design.Preferences) zui_design.PalettesByState {
    var repairs: zui_design.Repairs = .{};
    return zui_design.palettesFor(seeds, preferences, &repairs);
}

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
    const palettes = palettesOf(harbor.seeds, .{});
    const idle = palettes.get(.idle);
    try testing.expectEqual(250, idle.get(.accent).color.hue);
    try testing.expectEqual(250, idle.get(.surface).color.hue);
    try testing.expectApproxEqAbs(0.01, idle.get(.surface).color.chroma, 0.0001);
    try testing.expect(hueDistance(idle.get(.danger).color.hue, 27) < 1);

    const orange: zui.Color = .rgb(0xff8800);
    const chosen = palettesOf(harbor.seeds, .{ .accent = orange }).get(.idle);
    const orange_hue = oklab.oklchOfColor(orange).hue;
    try testing.expectApproxEqAbs(orange_hue, chosen.get(.accent).color.hue, 0.01);
    try testing.expectApproxEqAbs(orange_hue, chosen.get(.focus).color.hue, 0.01);
    try testing.expectEqual(idle.get(.surface), chosen.get(.surface));

    var with_hues = harbor;
    with_hues.seeds.success_hue = 180;
    try testing.expectEqual(180, palettesOf(with_hues.seeds, .{}).get(.idle).get(.success).color.hue);
}

test "dark raises its surfaces lighter, and high contrast moves text further from its surface" {
    for ([_]zui.Environment.Contrast{ .normal, .high }) |contrast| {
        const dark = palettesOf(harbor.seeds, .{ .theme = .dark, .contrast = contrast }).get(.idle);
        try testing.expect(dark.get(.surface_raised).color.lightness > dark.get(.surface).color.lightness);
        try testing.expect(dark.get(.surface).color.lightness > dark.get(.background).color.lightness);
        try testing.expect(dark.get(.on_surface).color.lightness > dark.get(.surface).color.lightness);
        const light = palettesOf(harbor.seeds, .{ .contrast = contrast }).get(.idle);
        try testing.expect(light.get(.on_surface).color.lightness < light.get(.surface).color.lightness);
    }
    for (every_theme) |theme| {
        const normal = palettesOf(harbor.seeds, .{ .theme = theme }).get(.idle);
        const high = palettesOf(harbor.seeds, .{ .theme = theme, .contrast = .high }).get(.idle);
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

test "APCA and WCAG 2 match their published values" {
    const black: zui.Color = .rgb(0x000000);
    const white: zui.Color = .rgb(0xffffff);
    try testing.expectApproxEqAbs(106.04, contrast_solver.apcaLightnessContrast(black, white), 0.05);
    try testing.expectApproxEqAbs(-107.88, contrast_solver.apcaLightnessContrast(white, black), 0.05);
    try testing.expectApproxEqAbs(63.06, contrast_solver.apcaLightnessContrast(.rgb(0x888888), white), 0.05);
    try testing.expectEqual(0, contrast_solver.apcaLightnessContrast(.rgb(0x888888), .rgb(0x888888)));
    try testing.expectApproxEqAbs(21, contrast_solver.wcagRatio(black, white), 0.001);
    try testing.expectApproxEqAbs(21, contrast_solver.wcagRatio(white, black), 0.001);
    try testing.expectApproxEqAbs(4.48, contrast_solver.wcagRatio(.rgb(0x777777), white), 0.005);
    try testing.expectEqual(1, contrast_solver.wcagRatio(.rgb(0x336699), .rgb(0x336699)));
}

test "text roles take the text tier, outlines and the focus ring the non-text tier, and decoration none" {
    try testing.expectEqual(.text, zui_design.tierOf(.on_accent));
    try testing.expectEqual(.text, zui_design.tierOf(.on_surface_muted));
    try testing.expectEqual(.non_text, zui_design.tierOf(.focus));
    try testing.expectEqual(null, zui_design.tierOf(.outline_muted));
    try testing.expectEqual(null, zui_design.tierOf(.scrim));
    try testing.expectEqual(null, zui_design.tierOf(.accent));
    try testing.expectEqual(contrast_solver.Target{ .lightness_contrast = 90, .ratio = 7 }, contrast_solver.Tier.text.target(.high));
    try testing.expectEqual(contrast_solver.Target{ .lightness_contrast = 45, .ratio = 3 }, contrast_solver.Tier.non_text.target(.normal));
    for (zui_design.checked_pairs) |pair| try testing.expect(zui_design.tierOf(pair.foreground) != null);
    for (zui_design.checked_pairs, 0..) |pair, index| {
        for (zui_design.checked_pairs[index + 1 ..]) |other| try testing.expect(!std.meta.eql(pair, other));
    }
    var on_surface_backgrounds: usize = 0;
    for (zui_design.checked_pairs) |pair| on_surface_backgrounds += @intFromBool(pair.foreground == .on_surface);
    try testing.expectEqual(4, on_surface_backgrounds);
    try testing.expectEqual(14, zui_design.checked_pairs.len);
}

fn expectEveryPairMeetsItsTarget(tokens: *const Tokens, contrast_setting: zui.Environment.Contrast) !void {
    for ([_]zui.WidgetState{ .idle, .hovered, .focused, .pressed }) |state| {
        const colors = tokens.colors.get(state);
        for (zui_design.checked_pairs) |pair| {
            const measured: zui_design.Contrast = .of(colors.get(pair.foreground), colors.get(pair.background));
            if (!measured.meets(pair.target(contrast_setting))) {
                std.debug.print("{t} on {t} {t}: Lc {d:.1}, {d:.2}:1\n", .{ pair.foreground, pair.background, state, measured.lightness_contrast, measured.ratio });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "a seed of every hue meets every target in every state of every scheme, with nothing repaired" {
    for (0..12) |step| {
        const hue: f32 = @floatFromInt(step * 30);
        for ([_]f32{ 0.05, 0.25, 0.37 }) |accent_chroma| {
            var seeded = harbor;
            seeded.seeds = .{ .accent = .{ .lightness = 0.6, .chroma = accent_chroma, .hue = hue }, .neutral = .{ .lightness = 0.5, .chroma = 0.03, .hue = hue } };
            for (every_theme) |theme| {
                for (every_contrast) |contrast_setting| {
                    var tokens: Tokens = .{};
                    const repairs = zui_design.resolve(seeded, .{ .theme = theme, .contrast = contrast_setting }, &tokens);
                    try testing.expect(repairs.isEmpty());
                    try expectEveryPairMeetsItsTarget(&tokens, contrast_setting);
                }
            }
        }
    }
}

test "a chosen pure yellow accent keeps its lightness, and its pair is repaired and reported" {
    const yellow = comptime zui.Color.rgb(0xffff00);
    var tokens: Tokens = .{};
    const repairs = zui_design.resolve(harbor, .{ .accent = yellow }, &tokens);
    try testing.expectEqual(1, repairs.slice().len);
    const repair = repairs.slice()[0];
    try testing.expectEqual(.on_accent, repair.foreground);
    try testing.expectEqual(.accent, repair.background);
    try testing.expectEqual(.light, repair.scheme);
    try testing.expect(!repair.before.meets(repair.target));
    try testing.expectApproxEqAbs(oklab.oklchOfColor(yellow).lightness, repair.background_moved.?.from, 0.0001);
    try testing.expect(repair.background_moved.?.to < repair.background_moved.?.from);
    try testing.expectEqual(0, repairs.dropped);
    try expectEveryPairMeetsItsTarget(&tokens, .normal);

    const repaired_at_comptime = comptime repaired: {
        var at_comptime: Tokens = .{};
        break :repaired zui_design.resolve(harbor, .{ .accent = yellow }, &at_comptime).kept_count;
    };
    try testing.expectEqual(1, repaired_at_comptime);
}

test "a chosen accent that meets its targets is the accent fill as it is" {
    const blue: zui.Color = .rgb(0x2050c0);
    for (every_theme) |theme| {
        var repairs: zui_design.Repairs = .{};
        const idle = zui_design.palettesFor(harbor.seeds, .{ .theme = theme, .accent = blue }, &repairs).get(.idle);
        try testing.expect(repairs.isEmpty());
        try testing.expectApproxEqAbs(oklab.oklchOfColor(blue).lightness, idle.get(.accent).color.lightness, 0.0001);
    }
}

test "passingLightness keeps a passing color and finds the nearest lightness that passes" {
    const white: design.Oklch = .{ .lightness = 1, .chroma = 0, .hue = 0 };
    const dark_grey: design.Oklch = .{ .lightness = 0.2, .chroma = 0, .hue = 0 };
    const mid_blue: design.Oklch = .{ .lightness = 0.65, .chroma = 0.12, .hue = 250 };
    const body = contrast_solver.Tier.text.target(.normal);
    try testing.expectEqual(0.2, zui_design.passingLightness(dark_grey, white, .foreground, body).?);

    const darker = zui_design.passingLightness(mid_blue, white, .foreground, body).?;
    try testing.expect(darker < mid_blue.lightness);
    var moved = mid_blue;
    moved.lightness = darker;
    try testing.expect(zui_design.Contrast.ofShades(moved, white).meets(body));
    moved.lightness = darker + 0.01;
    try testing.expect(!zui_design.Contrast.ofShades(moved, white).meets(body));

    const lighter_background = zui_design.passingLightness(dark_grey, mid_blue, .background, body).?;
    try testing.expect(lighter_background > mid_blue.lightness);
    try testing.expectEqual(null, zui_design.passingLightness(.{ .lightness = 0.5, .chroma = 0, .hue = 0 }, white, .background, contrast_solver.Tier.text.target(.high)));
}

test "repairs past capacity are counted as dropped" {
    var repairs: zui_design.Repairs = .{};
    const repair: zui_design.Repair = .{ .foreground = .on_accent, .background = .accent, .scheme = .dark, .target = contrast_solver.Tier.text.target(.normal), .before = .{ .lightness_contrast = 50, .ratio = 3 } };
    for (0..zui_design.Repairs.capacity + 3) |_| repairs.record(repair);
    try testing.expectEqual(zui_design.Repairs.capacity, repairs.slice().len);
    try testing.expectEqual(3, repairs.dropped);
    try testing.expect(!repairs.isEmpty());
}

test "a fill whose text leaves no room toward it is layered toward white or black instead" {
    var repairs: zui_design.Repairs = .{};
    const palettes = zui_design.palettesFor(harbor.seeds, .{}, &repairs);
    const idle_warning = palettes.get(.idle).get(.warning).color.lightness;
    try testing.expect(palettes.get(.hovered).get(.warning).color.lightness > idle_warning);
    try testing.expect(palettes.get(.pressed).get(.warning).color.lightness > palettes.get(.hovered).get(.warning).color.lightness);
    try testing.expect(palettes.get(.pressed).get(.accent).color.lightness > palettes.get(.idle).get(.accent).color.lightness);
}

fn expectLinearApprox(expected: [3]f32, actual: [3]f32) !void {
    for (expected, actual) |expected_channel, actual_channel| try testing.expectApproxEqAbs(expected_channel, actual_channel, 0.000001);
}

test "each simulation applies Machado et al.'s matrix at full severity, or luminance alone" {
    try expectLinearApprox(.{ 0.152286, 0.114503, 0 }, color_vision.simulatedLinear(.{ 1, 0, 0 }, .protanopia));
    try expectLinearApprox(.{ 1, 0.786281, 0 }, color_vision.simulatedLinear(.{ 0, 1, 0 }, .protanopia));
    try expectLinearApprox(.{ 0.367322, 0.280085, 0 }, color_vision.simulatedLinear(.{ 1, 0, 0 }, .deuteranopia));
    try expectLinearApprox(.{ 0, 0.047413, 0.968881 }, color_vision.simulatedLinear(.{ 0, 0, 1 }, .deuteranopia));
    try expectLinearApprox(.{ 0, 0.147602, 0.303900 }, color_vision.simulatedLinear(.{ 0, 0, 1 }, .tritanopia));
    try expectLinearApprox(.{ 1, 0, 0.004733 }, color_vision.simulatedLinear(.{ 1, 0, 0 }, .tritanopia));
    try expectLinearApprox(.{ 0.2126, 0.2126, 0.2126 }, color_vision.simulatedLinear(.{ 1, 0, 0 }, .achromatopsia));
    try expectLinearApprox(.{ 0.25, 0.25, 0.25 }, color_vision.simulatedLinear(.{ 0.25, 0.25, 0.25 }, .deuteranopia));

    for (std.enums.values(zui_design.Deficiency)) |deficiency| {
        try testing.expectApproxEqAbs(1, zui_design.simulatedLightnessOfColor(.rgb(0xffffff), deficiency), 0.001);
        try testing.expectApproxEqAbs(0, zui_design.simulatedLightnessOfColor(.rgb(0x000000), deficiency), 0.001);
    }
    try testing.expectApproxEqAbs(std.math.cbrt(@as(f32, 0.2126)), zui_design.simulatedLightnessOfColor(.rgb(0xff0000), .achromatopsia), 0.001);
    try testing.expect(zui_design.simulatedLightnessOfColor(.rgb(0xff0000), .protanopia) < oklab.oklchOfColor(.rgb(0xff0000)).lightness - 0.1);
}

fn expectStatusRolesApart(tokens: *const Tokens, least: f32) !void {
    const idle = tokens.colors.get(.idle);
    for (color_vision.status_roles, 0..) |first, index| {
        for (color_vision.status_roles[index + 1 ..]) |second| {
            const nearest = zui_design.nearestOfColors(idle.get(first), idle.get(second));
            if (!nearest.isApart(least)) {
                std.debug.print("{t} and {t}: {d:.3} under {t}\n", .{ first, second, nearest.lightness_difference, nearest.deficiency });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "the status fills stay apart in lightness under every simulation, for an accent of every hue, in every scheme" {
    for (0..12) |step| {
        const hue: f32 = @floatFromInt(step * 30);
        for ([_]f32{ 0.05, 0.25, 0.37 }) |accent_chroma| {
            var seeded = harbor;
            seeded.seeds = .{ .accent = .{ .lightness = 0.6, .chroma = accent_chroma, .hue = hue }, .neutral = .{ .lightness = 0.5, .chroma = 0.03, .hue = hue } };
            for (every_theme) |theme| {
                for (every_contrast) |contrast_setting| {
                    var tokens: Tokens = .{};
                    const repairs = zui_design.resolve(seeded, .{ .theme = theme, .contrast = contrast_setting }, &tokens);
                    try testing.expect(repairs.isEmpty());
                    try expectStatusRolesApart(&tokens, zui_design.least_lightness_difference);
                    try expectEveryPairMeetsItsTarget(&tokens, contrast_setting);
                }
            }
        }
    }
}

test "status fills that collapse are moved apart, keeping their contrast, and reported" {
    var red_success = harbor;
    red_success.seeds.success_hue = 20;
    var tokens: Tokens = .{};
    const repairs = zui_design.resolve(red_success, .{ .contrast = .high }, &tokens);
    try testing.expectEqual(1, repairs.slice().len);
    const repair = repairs.slice()[0];
    try testing.expectEqual(.color_vision, repair.kind);
    try testing.expectEqual(.danger, repair.foreground);
    try testing.expectEqual(.success, repair.background);
    try testing.expectEqual(.light_high_contrast, repair.scheme);
    try testing.expect(!repair.nearest.?.isApart(zui_design.least_lightness_difference));
    try testing.expectEqual(null, repair.foreground_moved);
    try testing.expect(repair.background_moved.?.to > repair.background_moved.?.from);
    try expectStatusRolesApart(&tokens, zui_design.least_lightness_difference);
    try expectEveryPairMeetsItsTarget(&tokens, .high);
}

test "status fills no lightness can part while keeping their contrast are reported as needing a cue" {
    var shades = palettesOf(harbor.seeds, .{}).get(.idle);
    for (color_vision.status_roles) |role| {
        shades.getPtr(role).color.lightness = 0.93;
        shades.getPtr(zui_design.partnerOf(role)).color = .{ .lightness = 0, .chroma = 0, .hue = 0 };
    }
    var repairs: zui_design.Repairs = .{};
    color_vision.separateStatusRoles(&shades, .light, zui_design.least_lightness_difference, &repairs);
    var needing_cue: usize = 0;
    for (repairs.slice()) |repair| needing_cue += @intFromBool(repair.kind == .needs_non_color_cue);
    try testing.expect(needing_cue > 0);
    for (color_vision.status_roles) |role| {
        const text = shades.get(zui_design.partnerOf(role)).color;
        try testing.expect(zui_design.Contrast.ofShades(text, shades.get(role).color).meets(contrast_solver.Tier.text.target(.normal)));
    }
}

fn simulatedChromaticDistance(first: zui.Color, second: zui.Color, deficiency: zui_design.Deficiency) f32 {
    const linear = oklab.linear_of_byte;
    const first_seen = oklab.Oklab.fromLinear(color_vision.simulatedLinear(.{ linear[first.r], linear[first.g], linear[first.b] }, deficiency));
    const second_seen = oklab.Oklab.fromLinear(color_vision.simulatedLinear(.{ linear[second.r], linear[second.g], linear[second.b] }, deficiency));
    const green_red = first_seen.green_red - second_seen.green_red;
    const blue_yellow = first_seen.blue_yellow - second_seen.blue_yellow;
    return @sqrt(green_red * green_red + blue_yellow * blue_yellow);
}

fn statusChromaticDistance(first: design.ColorRole, second: design.ColorRole, chosen: zui_design.ColorVision, deficiency: zui_design.Deficiency, theme: zui.Environment.Theme, contrast_setting: zui.Environment.Contrast) f32 {
    var tokens: Tokens = .{};
    _ = zui_design.resolve(harbor, .{ .theme = theme, .contrast = contrast_setting, .color_vision = chosen }, &tokens);
    const idle = tokens.colors.get(.idle);
    return simulatedChromaticDistance(idle.get(first), idle.get(second), deficiency);
}

test "a chosen color vision moves the status hues off its confused axis, or holds them further apart without color" {
    const confusions = [_]struct { zui_design.ColorVision, zui_design.Deficiency, design.ColorRole, design.ColorRole }{
        .{ .protan, .protanopia, .danger, .success },
        .{ .deutan, .deuteranopia, .danger, .success },
    };
    for (every_theme) |theme| {
        for (every_contrast) |contrast_setting| {
            for (confusions) |confusion| {
                const chosen, const deficiency, const first, const second = confusion;
                const typical = statusChromaticDistance(first, second, .typical, deficiency, theme, contrast_setting);
                const adapted = statusChromaticDistance(first, second, chosen, deficiency, theme, contrast_setting);
                if (adapted <= typical) {
                    std.debug.print("{t} {t} {t}: {t} and {t} {d:.3} -> {d:.3}\n", .{ chosen, theme, contrast_setting, first, second, typical, adapted });
                    return error.TestUnexpectedResult;
                }
            }
            for ([_]zui_design.ColorVision{ .protan, .deutan, .tritan, .achromat }) |chosen| {
                var tokens: Tokens = .{};
                _ = zui_design.resolve(harbor, .{ .theme = theme, .contrast = contrast_setting, .color_vision = chosen }, &tokens);
                try expectStatusRolesApart(&tokens, color_vision.leastStatusDifferenceFor(chosen));
                try expectEveryPairMeetsItsTarget(&tokens, contrast_setting);
            }
        }
    }
    const protan_hues = zui_design.statusHuesFor(.protan).?;
    try testing.expectEqual(230, protan_hues.success);
    try testing.expectEqual(null, zui_design.statusHuesFor(.typical));
    try testing.expectEqual(null, zui_design.statusHuesFor(.achromat));
    try testing.expectEqual(null, zui_design.statusHuesFor(.tritan));
}

test "a chosen color vision is adapted for, never fatally, at comptime" {
    const repaired = comptime repaired: {
        var count: u32 = 0;
        for (every_theme) |theme| {
            for (every_contrast) |contrast_setting| {
                var tokens: Tokens = .{};
                count += zui_design.resolve(harbor, .{ .theme = theme, .contrast = contrast_setting, .color_vision = .achromat }, &tokens).kept_count;
            }
        }
        break :repaired count;
    };
    try testing.expect(repaired > 0);
    var tokens: Tokens = .{};
    const repairs = zui_design.resolve(harbor, .{ .contrast = .high, .color_vision = .achromat }, &tokens);
    for (repairs.slice()) |repair| try testing.expectEqual(.color_vision, repair.kind);
}

const StatusBanner = struct {
    pub const Part = enum { failed, passed, label };

    pub const zuiAppearance = design.Appearance(Part, .{
        .failed = .{ .surface = .danger, .shape = .container },
        .passed = .{ .surface = .success, .shape = .container },
        .label = .{ .text = .on_danger, .type = .label, .on = .failed },
    });

    pub const zuiDistinguish = .{
        .{ .failed, .passed },
    };
};

const CuedChip = struct {
    pub const Part = enum { container, container_selected, close };

    pub const zuiAppearance = design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container, .shape = .chip },
        .container_selected = .{ .surface = .accent_container, .shape = .chip, .cue = "a check mark before its label" },
        .close = .{ .icon = .on_secondary_container, .on = .container, .target = .touch, .cue = "the pointer over it" },
    });

    pub const zuiDistinguish = .{
        .{ .container, .container_selected },
        .{ .close, .idle, .hovered },
    };
};

test "checkDistinguished passes pairs apart in lightness, and pairs with a cue that is not color" {
    comptime zui_design.checkDistinguished(harbor, .{ StatusBanner, CuedChip, Logo });
}

const Logo = struct {
    pub const Part = enum { mark };
    pub const zuiAppearance = design.Appearance(Part, .{ .mark = .{ .surface = .unchecked(.rgb(0xff00ff), "the brand's logo") } });
};

const std = @import("std");
const zui = @import("zui");
const zui_design = @import("zui_design.zig");
const expected = @import("default_expected.zig");

const testing = std.testing;
const design = zui.design;

const Ui = zui.Context(.{ .limits = .{ .max_elements = 8 } });
const Tokens = design.Tokens(Ui, void);

const every_state = [_]zui.WidgetState{ .idle, .hovered, .focused, .pressed, .disabled };

fn preferencesOf(scheme: zui_design.Scheme) zui_design.Preferences {
    return switch (scheme) {
        .light => .{ .theme = .light },
        .dark => .{ .theme = .dark },
        .light_high_contrast => .{ .theme = .light, .contrast = .high },
        .dark_high_contrast => .{ .theme = .dark, .contrast = .high },
    };
}

fn expectedIn(scheme: zui_design.Scheme) expected.ByRole {
    return switch (scheme) {
        .light => expected.resolved.light,
        .dark => expected.resolved.dark,
        .light_high_contrast => expected.resolved.light_high_contrast,
        .dark_high_contrast => expected.resolved.dark_high_contrast,
    };
}

/// Where the showcase that made the approved colors drew one the resolver
/// rightly does not. Its port layered each surface checking only the text
/// role partnered with it, so pressed `background`, `surface_raised`,
/// `surface_sunken` and `surface_overlay` would take `on_surface` below
/// its target; and it left `outline_muted` as it was when disabled, where
/// every foreground role greys and fades. The danger fill is not compared
/// at all: the approved one shared success's lightness, so the two
/// collapse under simulated color vision, and it was darkened.
fn differsFromTheShowcase(scheme: zui_design.Scheme, role: design.ColorRole, state: zui.WidgetState) bool {
    if (role == .outline_muted and state == .disabled) return true;
    const layered_state = state == .hovered or state == .focused or state == .pressed;
    return layered_state and switch (role) {
        .surface_sunken => scheme == .light or scheme == .light_high_contrast,
        .background, .surface_raised, .surface_overlay => scheme == .light_high_contrast,
        else => false,
    };
}

test "the default design resolves every role in every scheme and state to the approved colors, to the byte" {
    for (std.enums.values(zui_design.Scheme)) |scheme| {
        var tokens: Tokens = .{};
        const repairs = zui_design.resolve(zui_design.default, preferencesOf(scheme), &tokens);
        try testing.expectEqual(0, repairs.kept_count);
        for (std.enums.values(design.ColorRole)) |role| {
            if (role == .danger) continue;
            for (every_state, expectedIn(scheme).get(role)) |state, hex| {
                if (differsFromTheShowcase(scheme, role, state)) continue;
                const resolved = tokens.colors.get(state).get(role);
                if (!resolved.eql(.rgba(hex))) {
                    std.debug.print("{s} {t} {t}: expected {x:0>8}, resolved {x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ scheme.name(), role, state, hex, resolved.r, resolved.g, resolved.b, resolved.a });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "the default design's danger fill is darker than success by the color-vision margin, keeping its text's contrast" {
    for (std.enums.values(zui_design.Scheme)) |scheme| {
        var tokens: Tokens = .{};
        _ = zui_design.resolve(zui_design.default, preferencesOf(scheme), &tokens);
        const colors = tokens.colors.get(.idle);
        const nearest = zui_design.nearestOfColors(colors.get(.danger), colors.get(.success));
        try testing.expect(nearest.lightness_difference >= zui_design.least_lightness_difference);
        const on_danger: zui_design.Contrast = .of(colors.get(.on_danger), colors.get(.danger));
        try testing.expect(on_danger.meets(zui_design.tierOf(.on_danger).?.target(scheme.environmentContrast())));
    }
}

test "the default design's text styles match the approved ones at text scale 1 and 1.5" {
    for ([_]struct { f32, std.EnumArray(design.TypeRole, expected.TextStyle) }{
        .{ 1, expected.text_styles_at_1 },
        .{ 1.5, expected.text_styles_at_1_5 },
    }) |case| {
        const text_scale, const styles = case;
        var tokens: Tokens = .{};
        _ = zui_design.resolve(zui_design.default, .{ .text_scale = text_scale }, &tokens);
        for (std.enums.values(design.TypeRole)) |role| {
            const approved = styles.get(role);
            const resolved = tokens.text_styles.get(role);
            try testing.expectApproxEqAbs(approved.size, resolved.size, 0.005);
            try testing.expectEqual(approved.line_height, resolved.line_height);
            try testing.expectApproxEqAbs(approved.letter_spacing, resolved.letter_spacing, 0.0005);
        }
    }
}

test "the default design resolves at comptime in every scheme with nothing repaired" {
    const repaired = comptime count: {
        var count: u32 = 0;
        for (std.enums.values(zui_design.Scheme)) |scheme| {
            var tokens: Tokens = .{};
            count += zui_design.resolve(zui_design.default, preferencesOf(scheme), &tokens).kept_count;
        }
        break :count count;
    };
    try testing.expectEqual(0, repaired);
}

test "every accent preset's seed resolves with nothing repaired in every scheme" {
    for (expected.accent_presets) |accent| {
        var with_accent = zui_design.default;
        with_accent.seeds.accent = accent;
        for (std.enums.values(zui_design.Scheme)) |scheme| {
            var tokens: Tokens = .{};
            const repairs = zui_design.resolve(with_accent, preferencesOf(scheme), &tokens);
            if (repairs.kept_count != 0) {
                std.debug.print("accent hue {d} in {s}: {t} {t} and {t}\n", .{ accent.hue, scheme.name(), repairs.slice()[0].kind, repairs.slice()[0].foreground, repairs.slice()[0].background });
                return error.TestUnexpectedResult;
            }
        }
    }
}

fn categoriesIn(scheme: zui_design.Scheme) expected.ByCategory {
    return switch (scheme) {
        .light => expected.categories.light,
        .dark => expected.categories.dark,
        .light_high_contrast => expected.categories.light_high_contrast,
        .dark_high_contrast => expected.categories.dark_high_contrast,
    };
}

test "the default design's categories are the eight accent presets" {
    for (std.enums.values(design.Category), expected.accent_presets) |category, preset| {
        try testing.expectEqual(preset, zui_design.default.categories.get(category));
    }
}

test "the default design resolves every category in every scheme to its pinned colors, to the byte, with nothing repaired" {
    for (std.enums.values(zui_design.Scheme)) |scheme| {
        var tokens: Tokens = .{};
        const repairs = zui_design.resolve(zui_design.default, preferencesOf(scheme), &tokens);
        try testing.expectEqual(0, repairs.kept_count);
        for (std.enums.values(design.Category)) |category| {
            const resolved = tokens.categories.get(category);
            const pinned = categoriesIn(scheme).get(category);
            for ([_]zui.Color{ resolved.fill, resolved.on_fill, resolved.container, resolved.on_container }, pinned) |color, hex| {
                if (!color.eql(.rgba(hex))) {
                    std.debug.print("{s} {t}: expected {x:0>8}, resolved {x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ scheme.name(), category, hex, color.r, color.g, color.b, color.a });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "every category's text meets its target on its fill and on its container in every scheme" {
    for (std.enums.values(zui_design.Scheme)) |scheme| {
        var tokens: Tokens = .{};
        _ = zui_design.resolve(zui_design.default, preferencesOf(scheme), &tokens);
        const target = zui_design.tierOf(.on_accent).?.target(scheme.environmentContrast());
        for (tokens.categories.values) |colors| {
            try testing.expect(zui_design.Contrast.of(colors.on_fill, colors.fill).meets(target));
            try testing.expect(zui_design.Contrast.of(colors.on_container, colors.container).meets(target));
        }
    }
}

test "every category's text stays apart from its fill and its container under every simulated color vision" {
    for (std.enums.values(zui_design.Scheme)) |scheme| {
        var tokens: Tokens = .{};
        _ = zui_design.resolve(zui_design.default, preferencesOf(scheme), &tokens);
        for (tokens.categories.values) |colors| {
            try testing.expect(zui_design.nearestOfColors(colors.on_fill, colors.fill).isApart(zui_design.least_lightness_difference));
            try testing.expect(zui_design.nearestOfColors(colors.on_container, colors.container).isApart(zui_design.least_lightness_difference));
        }
    }
}

test "the categories follow neither a chosen accent nor a chosen color vision" {
    var plain: Tokens = .{};
    var chosen: Tokens = .{};
    _ = zui_design.resolve(zui_design.default, .{}, &plain);
    _ = zui_design.resolve(zui_design.default, .{ .accent = .rgb(0xd04090), .color_vision = .deutan }, &chosen);
    for (plain.categories.values, chosen.categories.values) |designed, kept| try testing.expectEqual(designed, kept);
}

test "a category of any hue and chroma meets its targets in every scheme with nothing repaired" {
    for (std.enums.values(zui_design.Scheme)) |scheme| {
        var hue: f32 = 0;
        while (hue < 360) : (hue += 30) {
            var chroma: f32 = 0.05;
            while (chroma < 0.4) : (chroma += 0.1) {
                var vivid = zui_design.default;
                vivid.categories.set(.amber, .{ .lightness = 0.55, .chroma = chroma, .hue = hue });
                var tokens: Tokens = .{};
                try testing.expectEqual(0, zui_design.resolve(vivid, preferencesOf(scheme), &tokens).kept_count);
            }
        }
    }
}

test "control heights and icon sizes follow the density, and a touch pointer raises every height to a finger's" {
    var tokens: Tokens = .{};
    _ = zui_design.resolve(zui_design.default, .{ .density = .compact }, &tokens);
    try testing.expectEqual(28, tokens.control_heights.get(.medium));
    try testing.expectEqual(16, tokens.icon_sizes.get(.medium));
    _ = zui_design.resolve(zui_design.default, .{ .density = .roomy }, &tokens);
    try testing.expectEqual(52, tokens.control_heights.get(.large));
    try testing.expectEqual(28, tokens.icon_sizes.get(.large));
    _ = zui_design.resolve(zui_design.default, .{ .density = .compact, .pointer = .touch }, &tokens);
    for (tokens.control_heights.values) |height| try testing.expect(height >= zui_design.touch_floor);
    try testing.expectEqual(zui_design.focus_ring_offset, tokens.focus_ring_offset);
}

test "each elevation is the shadow role at its level's alpha with a rim, denser in dark" {
    for ([_]zui.Environment.Theme{ .light, .dark }) |theme| {
        var tokens: Tokens = .{};
        _ = zui_design.resolve(zui_design.default, .{ .theme = theme }, &tokens);
        const shadow = tokens.colors.get(.idle).get(.shadow);
        const rim = tokens.colors.get(.idle).get(.rim);
        const scheme: zui_design.Scheme = .of(theme, .normal);
        var previous_blur: f32 = 0;
        for (std.enums.values(design.Elevation)) |elevation| {
            const lift = tokens.elevations.get(elevation);
            const level = zui_design.elevation_levels.get(scheme).get(elevation);
            try testing.expectEqual(level.surface, lift.surface);
            try testing.expectEqual(.{ shadow.r, shadow.g, shadow.b }, .{ lift.shadow.color.r, lift.shadow.color.g, lift.shadow.color.b });
            try testing.expectEqual(@as(u8, @intFromFloat(@round(level.alpha * 255))), lift.shadow.color.a);
            try testing.expect(lift.rim.?.eql(rim));
            try testing.expect(lift.shadow.blur > previous_blur);
            previous_blur = lift.shadow.blur;
        }
    }
    var light: Tokens = .{};
    var dark: Tokens = .{};
    _ = zui_design.resolve(zui_design.default, .{ .theme = .light }, &light);
    _ = zui_design.resolve(zui_design.default, .{ .theme = .dark }, &dark);
    try testing.expect(dark.elevations.get(.modal).shadow.color.a > light.elevations.get(.modal).shadow.color.a);
}

test "reduced transparency leaves the shadow and the rim translucent" {
    var tokens: Tokens = .{};
    _ = zui_design.resolve(zui_design.default, .{ .reduced_transparency = true }, &tokens);
    const colors = tokens.colors.get(.idle);
    try testing.expectEqual(expected.resolved.light.get(.rim)[0] & 0xff, colors.get(.rim).a);
    try testing.expect(colors.get(.scrim).a >= @as(u8, @intFromFloat(@floor(0.85 * 255))));
}

test "the default design's motion reaches every motion token" {
    var tokens: Tokens = .{};
    _ = zui_design.resolve(zui_design.default, .{}, &tokens);
    const motion = tokens.motion;
    try testing.expectEqual(zui.motion.TweenOptions{ .duration = 0.12, .easing = .ease_out }, motion.state);
    try testing.expectEqual(zui.motion.TweenOptions{ .duration = 0.08, .easing = .ease_out }, motion.press);
    try testing.expectEqual(zui.motion.SpringOptions{ .angular_frequency = 28 }, motion.toggle);
    try testing.expectEqual(zui.motion.TweenOptions{ .duration = 0.16, .easing = .ease_out }, motion.check);
    try testing.expectEqual(zui.motion.TweenOptions{ .duration = 0.16, .easing = .ease_out }, motion.popover_enter);
    try testing.expectEqual(zui.motion.TweenOptions{ .duration = 0.1, .easing = .ease_in }, motion.popover_exit);
    try testing.expectEqual(zui.motion.TweenOptions{ .duration = 0.22, .easing = .ease_out }, motion.dialog_enter);
    try testing.expectEqual(zui.motion.TweenOptions{ .duration = 0.14, .easing = .ease_in }, motion.dialog_exit);
    try testing.expectEqual(zui.motion.SpringOptions{ .angular_frequency = 22 }, motion.toast_enter);
    try testing.expectEqual(zui.motion.TweenOptions{ .duration = 0.16, .easing = .ease_in }, motion.toast_exit);
    try testing.expectEqual(zui.motion.SpringOptions{ .angular_frequency = 20 }, motion.drawer);
    try testing.expectEqual(zui.motion.SpringOptions{ .angular_frequency = 30 }, motion.reorder);
    try testing.expectEqual(zui.motion.TweenOptions{ .duration = 0.2, .easing = .ease_in_out }, motion.disclosure);
    try testing.expectEqual(0.97, motion.press_scale);
}

const std = @import("std");
const zui = @import("zui");
const zui_design = @import("zui_design.zig");
const oklab = @import("oklab.zig");

const testing = std.testing;
const design = zui.design;

const Ui = zui.Context(.{ .limits = .{ .max_elements = 8 } });
const FontIdUi = zui.Context(.{ .limits = .{ .max_elements = 8 }, .FontId = FontId });
const FontId = enum(u8) { regular, strong, monospace };
const Tokens = design.Tokens(Ui, void);

const harbor: design.Design = .{
    .seeds = .{ .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 }, .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 } },
    .corner_shape = .continuous,
};

const every_density = std.enums.values(design.Density);
const every_theme = std.enums.values(zui.Environment.Theme);
const every_contrast = std.enums.values(zui.Environment.Contrast);

/// Tokens whose every field holds a value no resolve writes, so a field
/// still holding it was not written.
fn poisonedTokens() Tokens {
    return .{
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
    const preferences: zui_design.Preferences = .from(environment, .{ .density = .roomy, .color_vision = .deutan, .corners = .rounder, .pointer = .touch, .accent = .rgb(0xff8800) });
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
    try testing.expectEqual(zui_design.Preferences{}, zui_design.Preferences.from(.{}, .{}));
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

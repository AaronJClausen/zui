const std = @import("std");
const zui = @import("zui");
const palette = @import("palette.zig");
const contrast = @import("contrast.zig");
const repairs_file = @import("repairs.zig");

const Category = zui.design.Category;
const ColorRole = zui.design.ColorRole;
const Oklch = zui.design.Oklch;
const Shade = palette.Shade;

/// A category's colors before they are encoded.
pub const CategoryShades = struct {
    fill: Shade,
    on_fill: Shade,
    container: Shade,
    on_container: Shade,
};

/// `category`'s colors in `scheme`: the accent's tones on `seed`'s hue and
/// chroma, each text moved, as a role's is, until it meets its target on
/// its fill or its container, and each move recorded in `repairs`.
pub fn shadesOf(category: Category, seed: Oklch, scheme: palette.Scheme, repairs: *repairs_file.Repairs) CategoryShades {
    var shades: CategoryShades = .{
        .fill = palette.shadeOnSeed(.accent, seed, scheme),
        .on_fill = palette.shadeOnSeed(.on_accent, seed, scheme),
        .container = palette.shadeOnSeed(.accent_container, seed, scheme),
        .on_container = palette.shadeOnSeed(.on_accent_container, seed, scheme),
    };
    solvePair(category, .{ .foreground = .on_accent, .background = .accent }, &shades.on_fill, &shades.fill, scheme, repairs);
    solvePair(category, .{ .foreground = .on_accent_container, .background = .accent_container }, &shades.on_container, &shades.container, scheme, repairs);
    return shades;
}

/// The name of the category's color that takes its tone from `role`, as
/// a message names it.
pub fn colorNameOf(role: ColorRole) []const u8 {
    return switch (role) {
        .accent => "fill",
        .on_accent => "on_fill",
        .accent_container => "container",
        .on_accent_container => "on_container",
        else => @tagName(role),
    };
}

fn solvePair(category: Category, pair: contrast.Pair, foreground: *Shade, background: *Shade, scheme: palette.Scheme, repairs: *repairs_file.Repairs) void {
    const target = pair.target(scheme.environmentContrast());
    const before: contrast.Contrast = .ofShades(foreground.color, background.color);
    if (before.meets(target)) return;
    const moves = contrast.moveUntilMet(&foreground.color, &background.color, target);
    repairs.record(.{
        .category = category,
        .foreground = pair.foreground,
        .background = pair.background,
        .scheme = scheme,
        .target = target,
        .before = before,
        .foreground_moved = moves.foreground,
        .background_moved = moves.background,
    });
}

test "a category takes the accent's tones on its own hue" {
    var repairs: repairs_file.Repairs = .{};
    const seed: Oklch = .{ .lightness = 0.55, .chroma = 0.14, .hue = 150 };
    const shades = shadesOf(.green, seed, .light, &repairs);
    try std.testing.expect(repairs.isEmpty());
    try std.testing.expectEqual(150, shades.container.color.hue);
    try std.testing.expectEqual(palette.shadeOnSeed(.accent_container, seed, .light).color.lightness, shades.container.color.lightness);
}

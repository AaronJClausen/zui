const std = @import("std");
const zui = @import("zui");
const palette = @import("palette.zig");

const ColorRole = zui.design.ColorRole;
const Elevation = zui.design.Elevation;
const Scheme = palette.Scheme;

/// One elevation's shadow and rim in one scheme.
pub const Level = struct {
    surface: ColorRole,
    rim: bool,
    offset: [2]f32,
    blur: f32,
    spread: f32,
    /// Replaces the `shadow` role's alpha.
    alpha: f32,
};

pub const Levels = std.EnumArray(Elevation, Level);

/// Dark's shadows are denser, since a shadow on a dark page shows less;
/// its height reads mostly from the lighter surface and the lit rim.
pub const levels: std.EnumArray(Scheme, Levels) = .init(.{
    .light = light,
    .dark = dark,
    .light_high_contrast = light,
    .dark_high_contrast = dark,
});

const light: Levels = .init(.{
    .raised = .{ .surface = .surface_raised, .rim = true, .offset = .{ 0, 1 }, .blur = 3, .spread = 0, .alpha = 0.1 },
    .floating = .{ .surface = .surface_overlay, .rim = true, .offset = .{ 0, 6 }, .blur = 16, .spread = -2, .alpha = 0.12 },
    .modal = .{ .surface = .surface_overlay, .rim = true, .offset = .{ 0, 12 }, .blur = 32, .spread = -4, .alpha = 0.16 },
    .topmost = .{ .surface = .surface_overlay, .rim = true, .offset = .{ 0, 20 }, .blur = 48, .spread = -6, .alpha = 0.2 },
});

const dark: Levels = .init(.{
    .raised = .{ .surface = .surface_raised, .rim = true, .offset = .{ 0, 1 }, .blur = 3, .spread = 0, .alpha = 0.32 },
    .floating = .{ .surface = .surface_overlay, .rim = true, .offset = .{ 0, 6 }, .blur = 16, .spread = -2, .alpha = 0.42 },
    .modal = .{ .surface = .surface_overlay, .rim = true, .offset = .{ 0, 12 }, .blur = 32, .spread = -4, .alpha = 0.5 },
    .topmost = .{ .surface = .surface_overlay, .rim = true, .offset = .{ 0, 20 }, .blur = 48, .spread = -6, .alpha = 0.58 },
});

/// Each level of `scheme` in the context's types, from the idle palette.
pub fn write(idle: palette.Palette, scheme: Scheme, tokens: anytype) void {
    const Color = @TypeOf(tokens.colors).Value.Value;
    for (std.enums.values(Elevation)) |elevation| {
        const level = levels.get(scheme).get(elevation);
        var shadow = idle.get(.shadow);
        shadow.alpha = level.alpha;
        tokens.elevations.set(elevation, .{
            .surface = level.surface,
            .shadow = .{ .color = shadow.encoded(Color), .offset = level.offset, .blur = level.blur, .spread = level.spread },
            .rim = if (level.rim) idle.get(.rim).encoded(Color) else null,
        });
    }
}

//! Every role's color in every state, in OKLCH, from a design's seeds: each
//! seed a tonal ramp, each role a lightness on one, chosen per scheme.

const std = @import("std");
const zui = @import("zui");
const oklab = @import("oklab.zig");

const ColorRole = zui.design.ColorRole;
const Oklch = zui.design.Oklch;
const Seeds = zui.design.Design.Seeds;
const WidgetState = zui.WidgetState;

/// A hue and chroma every role on it shares; only lightness varies along it.
pub const Ramp = enum { neutral, accent, danger, warning, success };

/// The theme and contrast a palette is resolved for.
pub const Scheme = enum {
    light,
    dark,
    light_high_contrast,
    dark_high_contrast,

    /// The scheme of the environment's theme and contrast.
    pub fn of(theme: zui.Environment.Theme, contrast: zui.Environment.Contrast) Scheme {
        return switch (contrast) {
            .normal => if (theme == .light) .light else .dark,
            .high => if (theme == .light) .light_high_contrast else .dark_high_contrast,
        };
    }
};

/// A role's place on its ramp: its lightness, the share of the ramp's
/// chroma it keeps, and its alpha.
pub const Tone = struct {
    ramp: Ramp,
    lightness: f32,
    chroma_share: f32 = 1,
    alpha: f32 = 1,
};

/// One resolved color, kept in OKLCH so a contrast repair can move its
/// lightness alone before it is encoded.
pub const Shade = struct {
    color: Oklch,
    alpha: f32 = 1,

    /// In a context's `Color`, brought into sRGB by reducing chroma; an
    /// `ExtendedColor` keeps it linear, unrounded.
    pub fn encoded(self: Shade, comptime Color: type) Color {
        const linear = oklab.gamutMappedLinear(self.color);
        if (Color == zui.ExtendedColor) return .linear(linear[0], linear[1], linear[2], self.alpha);
        return oklab.colorOfLinear(linear, self.alpha);
    }
};

/// A `Shade` for each built-in role.
pub const Palette = std.EnumArray(ColorRole, Shade);
/// A `Palette` for each state's layer.
pub const PalettesByState = std.EnumArray(WidgetState, Palette);

/// The hue of each status role when the design gives none: red, amber and
/// green in OKLCH.
pub const default_danger_hue: f32 = 27;
pub const default_warning_hue: f32 = 75;
pub const default_success_hue: f32 = 150;
/// The status ramps' chroma, vivid enough to read as status whatever the
/// accent's chroma.
pub const status_chroma: f32 = 0.16;

/// How far each state's layer moves a fill toward the role drawn on it,
/// in OKLab.
pub const hovered_layer: f32 = 0.08;
pub const focused_layer: f32 = 0.10;
pub const pressed_layer: f32 = 0.16;
/// A disabled role loses its chroma and keeps this share of its alpha.
pub const disabled_alpha: f32 = 0.38;
/// The least alpha of a translucent role under reduced transparency.
pub const reduced_transparency_alpha: f32 = 0.85;

/// Each ramp's hue and chroma, its lightness unused: the design's seeds,
/// the accent's replaced by `accent` when the user chose one.
pub fn rampSeeds(seeds: Seeds, accent: ?zui.Color) std.EnumArray(Ramp, Oklch) {
    return .init(.{
        .neutral = seeds.neutral,
        .accent = if (accent) |chosen| oklab.oklchOfColor(chosen) else seeds.accent,
        .danger = .{ .lightness = 0, .chroma = status_chroma, .hue = seeds.danger_hue orelse default_danger_hue },
        .warning = .{ .lightness = 0, .chroma = status_chroma, .hue = seeds.warning_hue orelse default_warning_hue },
        .success = .{ .lightness = 0, .chroma = status_chroma, .hue = seeds.success_hue orelse default_success_hue },
    });
}

/// Each role's idle color in `scheme`.
pub fn idlePalette(ramps: std.EnumArray(Ramp, Oklch), scheme: Scheme, reduced_transparency: bool) Palette {
    var palette: Palette = undefined;
    for (std.enums.values(ColorRole)) |role| {
        const tone = tones.get(scheme).get(role);
        const ramp = ramps.get(tone.ramp);
        const alpha = if (reduced_transparency and tone.alpha < 1) @max(tone.alpha, reduced_transparency_alpha) else tone.alpha;
        palette.set(role, .{ .color = .{ .lightness = tone.lightness, .chroma = ramp.chroma * tone.chroma_share, .hue = ramp.hue }, .alpha = alpha });
    }
    return palette;
}

/// Each state's layer of `idle`: a fill moves toward its `on_*` partner
/// as it is hovered, focused and pressed; text, icons and outlines stay as
/// they are. Disabled, every role but the page's surfaces and the scrim
/// greys and fades.
pub fn stateLayers(idle: Palette) PalettesByState {
    var layers: PalettesByState = .initFill(idle);
    for (std.enums.values(ColorRole)) |role| {
        const own = idle.get(role);
        switch (kindOf(role)) {
            .fill, .base_surface => {
                const partner = idle.get(partnerOf(role)).color;
                layers.getPtr(.hovered).set(role, layered(own, partner, hovered_layer));
                layers.getPtr(.focused).set(role, layered(own, partner, focused_layer));
                layers.getPtr(.pressed).set(role, layered(own, partner, pressed_layer));
            },
            .foreground, .scrim => {},
        }
        switch (kindOf(role)) {
            .fill, .foreground => layers.getPtr(.disabled).set(role, disabled(own)),
            .base_surface, .scrim => {},
        }
    }
    return layers;
}

/// The role `role` is checked against: the `on_*` role drawn on a fill,
/// and the fill under text, an icon or an outline.
pub fn partnerOf(role: ColorRole) ColorRole {
    return switch (role) {
        .background, .surface, .surface_raised, .surface_sunken => .on_surface,
        .surface_inverse => .on_surface_inverse,
        .on_surface, .on_surface_muted, .outline, .outline_muted, .focus, .scrim => .surface,
        .on_surface_inverse => .surface_inverse,
        .accent => .on_accent,
        .on_accent => .accent,
        .accent_container => .on_accent_container,
        .on_accent_container => .accent_container,
        .secondary_container => .on_secondary_container,
        .on_secondary_container => .secondary_container,
        .danger => .on_danger,
        .on_danger => .danger,
        .warning => .on_warning,
        .on_warning => .warning,
        .success => .on_success,
        .on_success => .success,
    };
}

/// The built-in role an extra role is colored as. One paired with a
/// built-in role takes that role's partner, as a `chart_line` paired with
/// `surface` is drawn as `on_surface`, and one paired with an extra role
/// takes that role's partner in turn. In a cycle of extra roles, as
/// `.brand = .on_brand, .on_brand = .brand`, the one declared first is
/// `accent` and the rest alternate `on_accent` and `accent` around it.
pub fn builtInRoleOf(comptime ExtraRoles: type, comptime role: ExtraRoles) ColorRole {
    comptime {
        const paired_name = @tagName(@field(ExtraRoles.zuiPairs, @tagName(role)));
        if (@hasField(ColorRole, paired_name)) return partnerOf(@field(ColorRole, paired_name));
        const cycle = cycleFrom(ExtraRoles, role);
        if (cycle.len == 0) return partnerOf(builtInRoleOf(ExtraRoles, @field(ExtraRoles, paired_name)));
        var first_declared: usize = 0;
        for (cycle, 0..) |member, index| {
            if (@intFromEnum(member) < @intFromEnum(cycle[first_declared])) first_declared = index;
        }
        const steps_after_first = (cycle.len - first_declared) % cycle.len;
        return if (steps_after_first % 2 == 0) .accent else .on_accent;
    }
}

/// The roles from `role` along their pairs back to it, or none when the
/// pairs reach a built-in role or a cycle `role` is not in.
fn cycleFrom(comptime ExtraRoles: type, comptime role: ExtraRoles) []const ExtraRoles {
    var walked: []const ExtraRoles = &.{};
    var current = role;
    for (std.enums.values(ExtraRoles)) |_| {
        walked = walked ++ .{current};
        const paired_name = @tagName(@field(ExtraRoles.zuiPairs, @tagName(current)));
        if (@hasField(ColorRole, paired_name)) return &.{};
        current = @field(ExtraRoles, paired_name);
        if (current == role) return walked;
    }
    return &.{};
}

const RoleKind = enum { base_surface, fill, foreground, scrim };

fn kindOf(role: ColorRole) RoleKind {
    return switch (role) {
        .background, .surface, .surface_raised, .surface_sunken, .surface_inverse => .base_surface,
        .accent, .accent_container, .secondary_container, .danger, .warning, .success => .fill,
        .scrim => .scrim,
        else => .foreground,
    };
}

fn layered(own: Shade, partner: Oklch, amount: f32) Shade {
    const mixed = oklab.Oklab.fromOklch(own.color).mix(.fromOklch(partner), amount).toOklch();
    return .{ .color = mixed, .alpha = own.alpha };
}

fn disabled(own: Shade) Shade {
    var greyed = own;
    greyed.color.chroma = 0;
    greyed.alpha = own.alpha * disabled_alpha;
    return greyed;
}

const RoleTones = std.EnumArray(ColorRole, Tone);

fn neutral(lightness: f32) Tone {
    return .{ .ramp = .neutral, .lightness = lightness };
}

fn on(ramp: Ramp, lightness: f32, chroma_share: f32) Tone {
    return .{ .ramp = ramp, .lightness = lightness, .chroma_share = chroma_share };
}

/// Dark is solved from the same ramps, not inverted: its raised surfaces
/// are lighter than its page. High contrast moves every pair further apart.
const tones: std.EnumArray(Scheme, RoleTones) = .init(.{
    .light = .init(.{
        .background = neutral(0.975),
        .surface = neutral(0.995),
        .surface_raised = neutral(1),
        .surface_sunken = neutral(0.945),
        .surface_inverse = neutral(0.27),
        .on_surface = neutral(0.23),
        .on_surface_muted = neutral(0.46),
        .on_surface_inverse = neutral(0.96),
        .accent = on(.accent, 0.52, 1),
        .on_accent = on(.accent, 0.99, 0.05),
        .accent_container = on(.accent, 0.90, 0.45),
        .on_accent_container = on(.accent, 0.30, 0.8),
        .secondary_container = on(.accent, 0.92, 0.2),
        .on_secondary_container = on(.accent, 0.28, 0.3),
        .danger = on(.danger, 0.55, 1),
        .on_danger = on(.danger, 0.99, 0.05),
        .warning = on(.warning, 0.78, 1),
        .on_warning = on(.warning, 0.25, 0.5),
        .success = on(.success, 0.52, 1),
        .on_success = on(.success, 0.99, 0.05),
        .outline = neutral(0.58),
        .outline_muted = neutral(0.88),
        .focus = on(.accent, 0.50, 1),
        .scrim = .{ .ramp = .neutral, .lightness = 0.15, .alpha = 0.45 },
    }),
    .dark = .init(.{
        .background = neutral(0.17),
        .surface = neutral(0.21),
        .surface_raised = neutral(0.26),
        .surface_sunken = neutral(0.14),
        .surface_inverse = neutral(0.93),
        .on_surface = neutral(0.94),
        .on_surface_muted = neutral(0.74),
        .on_surface_inverse = neutral(0.24),
        .accent = on(.accent, 0.74, 1),
        .on_accent = on(.accent, 0.22, 0.5),
        .accent_container = on(.accent, 0.36, 0.5),
        .on_accent_container = on(.accent, 0.91, 0.4),
        .secondary_container = on(.accent, 0.32, 0.2),
        .on_secondary_container = on(.accent, 0.90, 0.2),
        .danger = on(.danger, 0.70, 1),
        .on_danger = on(.danger, 0.22, 0.5),
        .warning = on(.warning, 0.82, 1),
        .on_warning = on(.warning, 0.24, 0.5),
        .success = on(.success, 0.74, 1),
        .on_success = on(.success, 0.22, 0.5),
        .outline = neutral(0.62),
        .outline_muted = neutral(0.34),
        .focus = on(.accent, 0.78, 1),
        .scrim = .{ .ramp = .neutral, .lightness = 0.05, .alpha = 0.6 },
    }),
    .light_high_contrast = .init(.{
        .background = neutral(1),
        .surface = neutral(1),
        .surface_raised = neutral(1),
        .surface_sunken = neutral(0.96),
        .surface_inverse = neutral(0.15),
        .on_surface = neutral(0.12),
        .on_surface_muted = neutral(0.30),
        .on_surface_inverse = neutral(1),
        .accent = on(.accent, 0.42, 1),
        .on_accent = neutral(1),
        .accent_container = on(.accent, 0.93, 0.4),
        .on_accent_container = on(.accent, 0.20, 0.8),
        .secondary_container = on(.accent, 0.95, 0.2),
        .on_secondary_container = on(.accent, 0.18, 0.3),
        .danger = on(.danger, 0.45, 1),
        .on_danger = neutral(1),
        .warning = on(.warning, 0.80, 1),
        .on_warning = on(.warning, 0.15, 0.4),
        .success = on(.success, 0.42, 1),
        .on_success = neutral(1),
        .outline = neutral(0.32),
        .outline_muted = neutral(0.55),
        .focus = on(.accent, 0.38, 1),
        .scrim = .{ .ramp = .neutral, .lightness = 0, .alpha = 0.6 },
    }),
    .dark_high_contrast = .init(.{
        .background = neutral(0.08),
        .surface = neutral(0.10),
        .surface_raised = neutral(0.15),
        .surface_sunken = neutral(0.06),
        .surface_inverse = neutral(1),
        .on_surface = neutral(1),
        .on_surface_muted = neutral(0.86),
        .on_surface_inverse = neutral(0.10),
        .accent = on(.accent, 0.82, 1),
        .on_accent = on(.accent, 0.12, 0.5),
        .accent_container = on(.accent, 0.28, 0.5),
        .on_accent_container = on(.accent, 0.96, 0.3),
        .secondary_container = on(.accent, 0.24, 0.2),
        .on_secondary_container = on(.accent, 0.96, 0.2),
        .danger = on(.danger, 0.78, 1),
        .on_danger = on(.danger, 0.12, 0.5),
        .warning = on(.warning, 0.86, 1),
        .on_warning = on(.warning, 0.14, 0.5),
        .success = on(.success, 0.80, 1),
        .on_success = on(.success, 0.12, 0.5),
        .outline = neutral(0.80),
        .outline_muted = neutral(0.55),
        .focus = on(.accent, 0.85, 1),
        .scrim = .{ .ramp = .neutral, .lightness = 0, .alpha = 0.7 },
    }),
});

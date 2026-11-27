const std = @import("std");
const zui = @import("zui");
const oklab = @import("oklab.zig");
const palette = @import("palette.zig");
const repairs_file = @import("repairs.zig");

const ColorRole = zui.design.ColorRole;
const Oklch = zui.design.Oklch;
const Repairs = repairs_file.Repairs;

/// A pair's contrast in both of the measures every target names.
pub const Contrast = struct {
    /// APCA's lightness contrast, Lc: positive for dark text on a lighter
    /// background, negative for light text on a darker one.
    lightness_contrast: f32,
    /// WCAG 2's contrast ratio, from 1 to 21.
    ratio: f32,

    /// Both measures of `text` on `background`, their alpha ignored.
    pub fn of(text: zui.Color, background: zui.Color) Contrast {
        return .{ .lightness_contrast = apcaLightnessContrast(text, background), .ratio = wcagRatio(text, background) };
    }

    /// Of two OKLCH colors, each brought into sRGB and encoded as it is drawn.
    pub fn ofShades(text: Oklch, background: Oklch) Contrast {
        return .of(encoded(text), encoded(background));
    }

    pub fn meets(self: Contrast, target: Target) bool {
        return @abs(self.lightness_contrast) >= target.lightness_contrast and self.ratio >= target.ratio;
    }
};

/// The least contrast a pair needs: an APCA magnitude and a WCAG 2 ratio.
pub const Target = struct {
    lightness_contrast: f32,
    ratio: f32,
};

/// What a foreground role is drawn as, which sets its target.
pub const Tier = enum {
    /// Text at body size and smaller.
    text,
    /// Text at `title` size and larger.
    large_text,
    /// Icons, outlines that show a state, and the focus ring.
    non_text,

    pub fn target(self: Tier, contrast: zui.Environment.Contrast) Target {
        return switch (self) {
            .text => switch (contrast) {
                .normal => .{ .lightness_contrast = 75, .ratio = 4.5 },
                .high => .{ .lightness_contrast = 90, .ratio = 7 },
            },
            .large_text => switch (contrast) {
                .normal => .{ .lightness_contrast = 60, .ratio = 3 },
                .high => .{ .lightness_contrast = 75, .ratio = 4.5 },
            },
            .non_text => switch (contrast) {
                .normal => .{ .lightness_contrast = 45, .ratio = 3 },
                .high => .{ .lightness_contrast = 60, .ratio = 4.5 },
            },
        };
    }
};

/// The tier of a role drawn on its partner. Null for a surface or a fill,
/// which is a pair's background, and for a decorative role, which need not
/// be seen.
pub fn tierOf(role: ColorRole) ?Tier {
    return switch (role) {
        .on_surface,
        .on_surface_muted,
        .on_surface_inverse,
        .on_surface_accent,
        .on_accent,
        .on_accent_container,
        .on_secondary_container,
        .on_danger,
        .on_danger_container,
        .on_warning,
        .on_warning_container,
        .on_success,
        .on_success_container,
        .on_selection,
        => .text,
        .outline, .focus => .non_text,
        .background,
        .surface,
        .surface_raised,
        .surface_sunken,
        .surface_overlay,
        .surface_inverse,
        .accent,
        .accent_container,
        .secondary_container,
        .danger,
        .danger_container,
        .warning,
        .warning_container,
        .success,
        .success_container,
        .selection,
        .outline_muted,
        .scrim,
        .shadow,
        .rim,
        => null,
    };
}

/// A foreground role on the role it is checked against.
pub const Pair = struct {
    foreground: ColorRole,
    background: ColorRole,

    pub fn target(self: Pair, contrast: zui.Environment.Contrast) Target {
        return tierOf(self.foreground).?.target(contrast);
    }
};

/// Every pair a resolve checks: each role and its partner, once, where one
/// of them has a tier. An extra role is colored as a built-in role, so its
/// pair is one of these.
pub const checked_pairs: []const Pair = &checkedPairs();

fn checkedPairs() [checkedPairCount()]Pair {
    var pairs: [checkedPairCount()]Pair = undefined;
    var count: usize = 0;
    for (std.enums.values(ColorRole)) |role| {
        if (pairOf(role)) |pair| {
            pairs[count] = pair;
            count += 1;
        }
    }
    return pairs;
}

fn checkedPairCount() usize {
    var count: usize = 0;
    for (std.enums.values(ColorRole)) |role| count += @intFromBool(pairOf(role) != null);
    return count;
}

/// A background is listed by its foreground, unless that foreground's own
/// partner is another background.
fn pairOf(role: ColorRole) ?Pair {
    const partner = palette.partnerOf(role);
    if (tierOf(role) != null) return .{ .foreground = role, .background = partner };
    if (tierOf(partner) != null and palette.partnerOf(partner) != role) return .{ .foreground = partner, .background = role };
    return null;
}

/// Moves each checked pair of `shades`, the idle palette of `scheme`, until
/// it meets its target, and records each move in `repairs`. The foreground
/// moves alone when it can; when no lightness of it passes, it goes to
/// white or black on its side and the background moves too.
pub fn solve(shades: *palette.Palette, scheme: palette.Scheme, repairs: *Repairs) void {
    for (checked_pairs) |pair| {
        const target = pair.target(scheme.environmentContrast());
        const foreground = shades.getPtr(pair.foreground);
        const background = shades.getPtr(pair.background);
        const before: Contrast = .ofShades(foreground.color, background.color);
        if (before.meets(target)) continue;
        const moves = moveUntilMet(&foreground.color, &background.color, target);
        repairs.record(.{
            .foreground = pair.foreground,
            .background = pair.background,
            .scheme = scheme,
            .target = target,
            .before = before,
            .foreground_moved = moves.foreground,
            .background_moved = moves.background,
        });
    }
}

/// How far each side of a pair moved to meet its target.
pub const Moves = struct {
    foreground: repairs_file.LightnessMove,
    /// Null when the foreground passed alone.
    background: ?repairs_file.LightnessMove = null,
};

/// Moves `foreground` in lightness until the pair meets `target`; when no
/// lightness of it passes, it goes to white or black on its side and
/// `background` moves too.
pub fn moveUntilMet(foreground: *Oklch, background: *Oklch, target: Target) Moves {
    const foreground_from = foreground.lightness;
    var background_moved: ?repairs_file.LightnessMove = null;
    if (passingLightness(foreground.*, background.*, .foreground, target)) |lightness| {
        foreground.lightness = lightness;
    } else {
        foreground.lightness = farthestLightness(foreground.*, background.*);
        const background_from = background.lightness;
        background.lightness = passingLightness(foreground.*, background.*, .background, target) orelse farthestLightness(background.*, foreground.*);
        background_moved = .{ .from = background_from, .to = background.lightness };
    }
    return .{ .foreground = .{ .from = foreground_from, .to = foreground.lightness }, .background = background_moved };
}

/// Each role's share of the state layers in `idle`, solved so every
/// checked pair on a layered role still meets its target when pressed. A
/// role whose pairs pass at the full layers takes them; one that would keep
/// less than `least_visible_layer_share` moves toward white or black, away
/// from its partner, instead, when that passes.
pub fn layerShares(idle: palette.Palette, scheme: palette.Scheme) palette.LayerShares {
    var idle_encoded: std.EnumArray(ColorRole, zui.Color) = undefined;
    for (std.enums.values(ColorRole)) |role| idle_encoded.set(role, encoded(idle.get(role).color));
    var shares: palette.LayerShares = .initFill(1);
    for (std.enums.values(ColorRole)) |role| {
        if (!palette.isLayered(role)) continue;
        const layer: LayerCheck = .{ .idle = &idle, .idle_encoded = &idle_encoded, .role = role, .contrast = scheme.environmentContrast() };
        if (layer.passesAt(1)) continue;
        var failing: f32 = 1;
        var passing: f32 = 0;
        for (0..layer_share_search_steps) |_| {
            const middle = (failing + passing) / 2;
            if (layer.passesAt(middle)) passing = middle else failing = middle;
        }
        shares.set(role, if (passing < least_visible_layer_share and layer.passesAt(-1)) -1 else passing);
    }
    return shares;
}

/// A share is found to within 1/256 of the full layer.
const layer_share_search_steps = 8;

/// Below this share, a pressed role would hardly differ from its idle one.
pub const least_visible_layer_share: f32 = 0.25;

const LayerCheck = struct {
    idle: *const palette.Palette,
    idle_encoded: *const std.EnumArray(ColorRole, zui.Color),
    role: ColorRole,
    contrast: zui.Environment.Contrast,

    fn passesAt(self: LayerCheck, share: f32) bool {
        const own = self.idle.get(self.role);
        const partner = self.idle.get(palette.partnerOf(self.role)).color;
        const toward = if (share < 0) palette.awayFrom(own.color, partner) else partner;
        const pressed = palette.layered(own, toward, palette.pressed_layer * @abs(share));
        const pressed_encoded = encoded(pressed.color);
        for (checked_pairs) |pair| {
            if (pair.background != self.role) continue;
            const contrast: Contrast = .of(self.idle_encoded.get(pair.foreground), pressed_encoded);
            if (!contrast.meets(pair.target(self.contrast))) return false;
        }
        return true;
    }
};

/// Which color of a pair is moved.
pub const Side = enum { foreground, background };

/// The lightness of the `moved` color nearest its own at which the pair
/// meets `target`, keeping its hue and chroma: searched away from the other
/// color, lighter when the moved one is the lighter of the two. Null when
/// even white or black on that side fails.
///
/// ```zig
/// const on_accent = passingLightness(on_accent_shade, accent_shade, .foreground, Tier.text.target(.normal)) orelse unreachable;
/// ```
pub fn passingLightness(foreground: Oklch, background: Oklch, moved: Side, target: Target) ?f32 {
    const moving, const fixed = switch (moved) {
        .foreground => .{ foreground, background },
        .background => .{ background, foreground },
    };
    const fixed_encoded = encoded(fixed);
    const search: LightnessSearch = .{ .moving = moving, .fixed = fixed_encoded, .moved = moved, .target = target };
    if (search.passesAt(moving.lightness)) return moving.lightness;
    const farthest = farthestLightness(moving, fixed);
    if (!search.passesAt(farthest)) return null;

    var failing = moving.lightness;
    var passing = farthest;
    for (0..lightness_search_steps) |_| {
        const middle = (failing + passing) / 2;
        if (search.passesAt(middle)) passing = middle else failing = middle;
    }
    return passing;
}

/// A search halves the lightness between failing and passing this many
/// times, to within 1/16384 of the distance it covers.
const lightness_search_steps = 14;

const LightnessSearch = struct {
    moving: Oklch,
    fixed: zui.Color,
    moved: Side,
    target: Target,

    fn passesAt(self: LightnessSearch, lightness: f32) bool {
        var tried = self.moving;
        tried.lightness = lightness;
        const contrast: Contrast = switch (self.moved) {
            .foreground => .of(encoded(tried), self.fixed),
            .background => .of(self.fixed, encoded(tried)),
        };
        return contrast.meets(self.target);
    }
};

/// White when `moving` is the lighter of the two, black when the darker.
fn farthestLightness(moving: Oklch, fixed: Oklch) f32 {
    const moving_luminance = relativeLuminanceOf(encoded(moving));
    const fixed_luminance = relativeLuminanceOf(encoded(fixed));
    const lighter = if (moving_luminance == fixed_luminance) fixed.lightness < 0.5 else moving_luminance > fixed_luminance;
    return if (lighter) 1 else 0;
}

fn encoded(color: Oklch) zui.Color {
    return oklab.colorOfLinear(oklab.gamutMappedLinear(color), 1);
}

/// WCAG 2's contrast ratio of two colors, from 1 to 21, either way round.
pub fn wcagRatio(first: zui.Color, second: zui.Color) f32 {
    const first_luminance = relativeLuminanceOf(first);
    const second_luminance = relativeLuminanceOf(second);
    return (@max(first_luminance, second_luminance) + 0.05) / (@min(first_luminance, second_luminance) + 0.05);
}

/// WCAG 2's relative luminance, from 0 for black to 1 for white.
pub fn relativeLuminanceOf(color: zui.Color) f32 {
    const linear = oklab.linear_of_byte;
    return 0.2126 * linear[color.r] + 0.7152 * linear[color.g] + 0.0722 * linear[color.b];
}

/// APCA's lightness contrast, Lc, of `text` on `background`, by APCA-W3
/// 0.0.98G-4g: about 106 for black on white, about −108 for white on black,
/// and 0 for a pair too close to tell apart.
pub fn apcaLightnessContrast(text: zui.Color, background: zui.Color) f32 {
    const text_luminance = blackSoftClamped(apcaLuminanceOf(text));
    const background_luminance = blackSoftClamped(apcaLuminanceOf(background));
    if (@abs(background_luminance - text_luminance) < apca.least_luminance_difference) return 0;
    if (background_luminance > text_luminance) {
        const contrast = (power(background_luminance, apca.normal_background_exponent) -
            power(text_luminance, apca.normal_text_exponent)) * apca.scale;
        return if (contrast < apca.low_clip) 0 else (contrast - apca.low_offset) * 100;
    }
    const contrast = (power(background_luminance, apca.reverse_background_exponent) -
        power(text_luminance, apca.reverse_text_exponent)) * apca.scale;
    return if (contrast > -apca.low_clip) 0 else (contrast + apca.low_offset) * 100;
}

const apca = struct {
    const normal_background_exponent = 0.56;
    const normal_text_exponent = 0.57;
    const reverse_text_exponent = 0.62;
    const reverse_background_exponent = 0.65;
    const black_threshold = 0.022;
    const black_clamp_exponent = 1.414;
    const scale = 1.14;
    const low_offset = 0.027;
    const least_luminance_difference = 0.0005;
    const low_clip = 0.1;
    const red = 0.2126729;
    const green = 0.7151522;
    const blue = 0.0721750;
};

fn apcaLuminanceOf(color: zui.Color) f32 {
    return apca.red * apca_linear_of_byte[color.r] + apca.green * apca_linear_of_byte[color.g] + apca.blue * apca_linear_of_byte[color.b];
}

/// For a positive `base`; `std.math.pow`'s special cases cost more than
/// a resolve can spend on them.
fn power(base: f32, exponent: f32) f32 {
    return @exp(@log(base) * exponent);
}

fn blackSoftClamped(luminance: f32) f32 {
    if (luminance > apca.black_threshold) return luminance;
    return luminance + power(apca.black_threshold - luminance, apca.black_clamp_exponent);
}

/// APCA linearizes each byte by a plain power of 2.4, not sRGB's piecewise
/// curve.
const apca_linear_of_byte: [256]f32 = apcaTransferTable();

fn apcaTransferTable() [256]f32 {
    @setEvalBranchQuota(256 * 1000);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*linear, byte| linear.* = std.math.pow(f32, @as(f32, @floatFromInt(byte)) / 255, 2.4);
    return table;
}

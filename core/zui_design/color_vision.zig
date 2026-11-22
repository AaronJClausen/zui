const std = @import("std");
const zui = @import("zui");
const oklab = @import("oklab.zig");
const palette = @import("palette.zig");
const contrast = @import("contrast.zig");
const repairs_file = @import("repairs.zig");

const ColorRole = zui.design.ColorRole;
const Oklch = zui.design.Oklch;

/// The color vision the status roles are adapted for, the user's choice.
pub const ColorVision = enum { typical, protan, deutan, tritan, achromat };

/// A dichromacy at full severity, or the absence of color vision, as a
/// color is simulated for it.
pub const Deficiency = enum {
    protanopia,
    deuteranopia,
    tritanopia,
    achromatopsia,

    /// As a message names it: "protanopia".
    pub fn name(self: Deficiency) []const u8 {
        return @tagName(self);
    }
};

/// Machado, Oliveira and Fernandes's matrices at severity 1, by row, on
/// linear sRGB.
const machado_matrices: std.EnumArray(Deficiency, [3][3]f32) = .init(.{
    .protanopia = .{
        .{ 0.152286, 1.052583, -0.204868 },
        .{ 0.114503, 0.786281, 0.099216 },
        .{ -0.003882, -0.048116, 1.051998 },
    },
    .deuteranopia = .{
        .{ 0.367322, 0.860646, -0.227968 },
        .{ 0.280085, 0.672501, 0.047413 },
        .{ -0.011820, 0.042940, 0.968881 },
    },
    .tritanopia = .{
        .{ 1.255528, -0.076749, -0.178779 },
        .{ -0.078411, 0.930809, 0.147602 },
        .{ 0.004733, 0.691367, 0.303900 },
    },
    .achromatopsia = .{
        .{ 0.2126, 0.7152, 0.0722 },
        .{ 0.2126, 0.7152, 0.0722 },
        .{ 0.2126, 0.7152, 0.0722 },
    },
});

/// `linear`, a color in linear sRGB, as seen with `deficiency`, clamped
/// into sRGB's gamut. Achromatopsia keeps the luminance alone.
///
/// ```zig
/// const seen = simulatedLinear(.{ 1, 0, 0 }, .protanopia); // a dim olive: .{ 0.152, 0.115, 0 }
/// ```
pub fn simulatedLinear(linear: [3]f32, deficiency: Deficiency) [3]f32 {
    const matrix = machado_matrices.get(deficiency);
    var seen: [3]f32 = undefined;
    for (&seen, matrix) |*channel, row| {
        channel.* = std.math.clamp(row[0] * linear[0] + row[1] * linear[1] + row[2] * linear[2], 0, 1);
    }
    return seen;
}

/// The OKLab lightness of `color`, brought into sRGB as it is drawn, as
/// seen with `deficiency`.
pub fn simulatedLightness(color: Oklch, deficiency: Deficiency) f32 {
    return lightnessOfLinear(simulatedLinear(oklab.gamutMappedLinear(color), deficiency));
}

/// The OKLab lightness of an encoded `color` as seen with `deficiency`.
pub fn simulatedLightnessOfColor(color: zui.Color, deficiency: Deficiency) f32 {
    return lightnessOfLinear(simulatedLinear(linearOfColor(color), deficiency));
}

/// Two colors at least this far apart in OKLab lightness under every
/// simulation are told apart without their hue.
pub const least_lightness_difference: f32 = 0.15;
/// What the status roles are held apart by for a user whose color vision
/// no hue of theirs can help: without blue and yellow, warning's light
/// fill has too little chroma for its hue to show, and without color
/// lightness is all there is.
pub const least_lightness_difference_adapted: f32 = 0.20;

/// The simulation under which two colors are nearest in lightness, and
/// how far apart they are there.
pub const Nearest = struct {
    deficiency: Deficiency,
    lightness_difference: f32,

    /// True when the two are at least `least` apart under every simulation.
    pub fn isApart(self: Nearest, least: f32) bool {
        return self.lightness_difference >= least;
    }
};

/// Of two OKLCH colors, each brought into sRGB and encoded as it is drawn.
pub fn nearestUnderSimulation(first: Oklch, second: Oklch) Nearest {
    return nearestOfColors(encoded(first), encoded(second));
}

/// Of two encoded colors.
pub fn nearestOfColors(first: zui.Color, second: zui.Color) Nearest {
    return nearestOfLinear(linearOfColor(first), linearOfColor(second));
}

/// Each simulation's lightness difference of two colors.
pub fn lightnessDifferences(first: Oklch, second: Oklch) std.EnumArray(Deficiency, f32) {
    const first_linear = oklab.gamutMappedLinear(first);
    const second_linear = oklab.gamutMappedLinear(second);
    var differences: std.EnumArray(Deficiency, f32) = undefined;
    for (std.enums.values(Deficiency)) |deficiency| {
        differences.set(deficiency, @abs(lightnessOfLinear(simulatedLinear(first_linear, deficiency)) -
            lightnessOfLinear(simulatedLinear(second_linear, deficiency))));
    }
    return differences;
}

fn nearestOfLinear(first: [3]f32, second: [3]f32) Nearest {
    var nearest: Nearest = .{ .deficiency = .protanopia, .lightness_difference = std.math.inf(f32) };
    for (std.enums.values(Deficiency)) |deficiency| {
        const difference = @abs(lightnessOfLinear(simulatedLinear(first, deficiency)) - lightnessOfLinear(simulatedLinear(second, deficiency)));
        if (difference < nearest.lightness_difference) nearest = .{ .deficiency = deficiency, .lightness_difference = difference };
    }
    return nearest;
}

fn lightnessOfLinear(linear: [3]f32) f32 {
    return oklab.Oklab.fromLinear(linear).lightness;
}

fn linearOfColor(color: zui.Color) [3]f32 {
    const linear = oklab.linear_of_byte;
    return .{ linear[color.r], linear[color.g], linear[color.b] };
}

/// The status roles' hues for a user who chose `color_vision`, or null to
/// keep the design's. Without red and green, danger moves toward orange
/// and success to azure, apart on the blue-yellow axis that is left.
/// Tritanopia keeps red and green apart, and achromatopsia has no hue, so
/// both keep the hues and hold the roles further apart in lightness.
pub fn statusHuesFor(color_vision: ColorVision) ?StatusHues {
    return switch (color_vision) {
        .typical, .tritan, .achromat => null,
        .protan, .deutan => .{ .danger = 40, .warning = 85, .success = 230 },
    };
}

/// A hue in degrees for each status role.
pub const StatusHues = struct {
    danger: f32,
    warning: f32,
    success: f32,
};

/// How far apart the status roles are held for `color_vision`.
pub fn leastStatusDifferenceFor(color_vision: ColorVision) f32 {
    return switch (color_vision) {
        .typical, .protan, .deutan => least_lightness_difference,
        .tritan, .achromat => least_lightness_difference_adapted,
    };
}

/// The status fills, each pair of which is held apart in lightness.
pub const status_roles = [_]ColorRole{ .danger, .warning, .success };

/// Moves each pair of status fills in `shades`, the idle palette of
/// `scheme` with its contrast solved, until they are `least` apart in
/// lightness under every simulation, keeping each fill's contrast with its
/// `on_*` role. Of the two, the one that moves less moves. A pair that no
/// such move separates is recorded as needing a cue that is not color.
pub fn separateStatusRoles(shades: *palette.Palette, scheme: palette.Scheme, least: f32, repairs: *repairs_file.Repairs) void {
    for (status_roles, 0..) |first, index| {
        for (status_roles[index + 1 ..]) |second| {
            const before = nearestUnderSimulation(shades.get(first).color, shades.get(second).color);
            if (before.isApart(least)) continue;
            var repair: repairs_file.Repair = .{ .kind = .color_vision, .foreground = first, .background = second, .scheme = scheme, .nearest = before };
            const first_move = separatingLightness(shades, first, second, scheme, least);
            const second_move = separatingLightness(shades, second, first, scheme, least);
            const first_distance = if (first_move) |lightness| @abs(lightness - shades.get(first).color.lightness) else std.math.inf(f32);
            const second_distance = if (second_move) |lightness| @abs(lightness - shades.get(second).color.lightness) else std.math.inf(f32);
            if (first_move == null and second_move == null) {
                repair.kind = .needs_non_color_cue;
            } else if (first_distance <= second_distance) {
                const moved = shades.getPtr(first);
                repair.foreground_moved = .{ .from = moved.color.lightness, .to = first_move.? };
                moved.color.lightness = first_move.?;
            } else {
                const moved = shades.getPtr(second);
                repair.background_moved = .{ .from = moved.color.lightness, .to = second_move.? };
                moved.color.lightness = second_move.?;
            }
            repairs.record(repair);
        }
    }
}

/// The lightness of `moving` nearest its own, away from `fixed`, at which
/// the two are `least` apart and `moving` still meets its target with its
/// `on_*` role; null when none does, nor leaves the other status fills
/// apart.
fn separatingLightness(shades: *const palette.Palette, moving: ColorRole, fixed: ColorRole, scheme: palette.Scheme, least: f32) ?f32 {
    const own = shades.get(moving).color;
    var search: SeparationSearch = .{
        .own = own,
        .text = encoded(shades.get(palette.partnerOf(moving)).color),
        .target = tierOfPartner(moving).target(scheme.environmentContrast()),
        .least = least,
    };
    const own_seen = seenOf(encoded(own));
    search.keep(seenOf(encoded(shades.get(fixed).color)));
    for (status_roles) |role| {
        if (role == moving or role == fixed) continue;
        const other_seen = seenOf(encoded(shades.get(role).color));
        if (isApart(own_seen, other_seen, least)) search.keep(other_seen);
    }
    var reachable: f32 = if (own.lightness >= shades.get(fixed).color.lightness) 1 else 0;
    if (!search.keepsContrastAt(reachable)) {
        var keeping = own.lightness;
        for (0..separation_search_steps) |_| {
            const middle = (keeping + reachable) / 2;
            if (search.keepsContrastAt(middle)) keeping = middle else reachable = middle;
        }
        reachable = keeping;
    }
    if (!search.passesAt(reachable)) return null;
    var passing = reachable;
    var failing = own.lightness;
    for (0..separation_search_steps) |_| {
        const middle = (failing + passing) / 2;
        if (search.passesAt(middle)) passing = middle else failing = middle;
    }
    return passing;
}

/// A search halves the lightness between failing and passing this many
/// times, to within 1/512 of the distance it covers.
const separation_search_steps = 9;

/// A color's OKLab lightness under each simulation.
const Seen = std.EnumArray(Deficiency, f32);

fn seenOf(color: zui.Color) Seen {
    const linear = linearOfColor(color);
    var seen: Seen = undefined;
    for (std.enums.values(Deficiency)) |deficiency| seen.set(deficiency, lightnessOfLinear(simulatedLinear(linear, deficiency)));
    return seen;
}

fn isApart(first: Seen, second: Seen, least: f32) bool {
    for (first.values, second.values) |first_lightness, second_lightness| {
        if (@abs(first_lightness - second_lightness) < least) return false;
    }
    return true;
}

fn encoded(color: Oklch) zui.Color {
    return oklab.colorOfLinear(oklab.gamutMappedLinear(color), 1);
}

fn tierOfPartner(fill: ColorRole) contrast.Tier {
    return contrast.tierOf(palette.partnerOf(fill)).?;
}

fn withLightness(color: Oklch, lightness: f32) Oklch {
    var moved = color;
    moved.lightness = lightness;
    return moved;
}

const SeparationSearch = struct {
    own: Oklch,
    text: zui.Color,
    target: contrast.Target,
    least: f32,
    /// The fill it is moved from, then each other status fill it was
    /// already apart from.
    kept_apart_from: [status_roles.len - 1]Seen = undefined,
    kept_apart_count: usize = 0,

    fn keep(self: *SeparationSearch, seen: Seen) void {
        self.kept_apart_from[self.kept_apart_count] = seen;
        self.kept_apart_count += 1;
    }

    /// True when the moving fill at `lightness` keeps its contrast and is
    /// `least` apart from every fill it is kept apart from.
    fn passesAt(self: SeparationSearch, lightness: f32) bool {
        const tried = encoded(withLightness(self.own, lightness));
        if (!contrast.Contrast.of(self.text, tried).meets(self.target)) return false;
        const tried_seen = seenOf(tried);
        for (self.kept_apart_from[0..self.kept_apart_count]) |other_seen| {
            if (!isApart(tried_seen, other_seen, self.least)) return false;
        }
        return true;
    }

    fn keepsContrastAt(self: SeparationSearch, lightness: f32) bool {
        return contrast.Contrast.of(self.text, encoded(withLightness(self.own, lightness))).meets(self.target);
    }
};

//! Color spaces for building palettes: OKLab, where equal distances look
//! equally different, its polar form OKLCH, and CSS's HSL. Every function
//! runs at comptime, so a theme's shades can be constants.
//!
//! ```zig
//! const accent: zui.Color = .rgb(0x3366ff);
//! const accent_hovered = comptime zui_color.shiftLightness(accent, 0.06);
//! const accent_pressed = comptime zui_color.shiftLightness(accent, -0.08);
//! const greys = comptime zui_color.ramp(9, .rgb(0x15151c), .rgb(0xf4f4f8));
//! const blues = comptime zui_color.lightnessScale(10, accent, 0.25, 0.97);
//! ```

const std = @import("std");
const zui = @import("zui");

const Color = zui.Color;
const ExtendedColor = zui.ExtendedColor;

/// A color in OKLab: `lightness` from 0 (black) to 1 (white), `green_red`
/// from green (negative) to red, `blue_yellow` from blue (negative) to
/// yellow, and straight `alpha` from 0 to 1. Equal distances in it look
/// about equally different, so a mix through it keeps its brightness.
pub const Oklab = struct {
    lightness: f32,
    green_red: f32,
    blue_yellow: f32,
    alpha: f32 = 1,

    pub fn fromColor(color: Color) Oklab {
        return fromLinear(linearOf(color), alphaOf(color));
    }

    /// An out-of-gamut color is brought into sRGB by reducing its chroma,
    /// keeping its lightness and hue, rather than by clipping each channel.
    pub fn toColor(self: Oklab) Color {
        return colorOfLinear(gamutMappedLinear(self), self.alpha);
    }

    pub fn fromExtendedColor(color: ExtendedColor) Oklab {
        return fromLinear(.{ color.r, color.g, color.b }, color.a);
    }

    /// Unmapped: an `ExtendedColor` holds what lies outside sRGB.
    pub fn toExtendedColor(self: Oklab) ExtendedColor {
        const red, const green, const blue = self.toLinear();
        return .linear(red, green, blue, self.alpha);
    }

    pub fn toOklch(self: Oklab) Oklch {
        const chroma = @sqrt(self.green_red * self.green_red + self.blue_yellow * self.blue_yellow);
        const hue_degrees = if (chroma < achromatic_chroma) 0 else normalizedDegrees(std.math.radiansToDegrees(std.math.atan2(self.blue_yellow, self.green_red)));
        return .{ .lightness = self.lightness, .chroma = chroma, .hue_degrees = hue_degrees, .alpha = self.alpha };
    }

    /// `amount` 0 is `self`, 1 is `other`; outside that it extrapolates.
    pub fn mix(self: Oklab, other: Oklab, amount: f32) Oklab {
        return .{
            .lightness = lerp(self.lightness, other.lightness, amount),
            .green_red = lerp(self.green_red, other.green_red, amount),
            .blue_yellow = lerp(self.blue_yellow, other.blue_yellow, amount),
            .alpha = lerp(self.alpha, other.alpha, amount),
        };
    }

    /// From linear sRGB, by Björn Ottosson's matrices.
    pub fn fromLinear(rgb: [3]f32, alpha: f32) Oklab {
        @setEvalBranchQuota(comptime_branch_quota);
        const red, const green, const blue = rgb;
        const long = std.math.cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue);
        const medium = std.math.cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue);
        const short = std.math.cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue);
        return .{
            .lightness = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
            .green_red = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
            .blue_yellow = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short,
            .alpha = alpha,
        };
    }

    /// To linear sRGB, unclamped: a channel below 0 or above 1 is outside
    /// sRGB's gamut.
    pub fn toLinear(self: Oklab) [3]f32 {
        @setEvalBranchQuota(comptime_branch_quota);
        const long = cube(self.lightness + 0.3963377774 * self.green_red + 0.2158037573 * self.blue_yellow);
        const medium = cube(self.lightness - 0.1055613458 * self.green_red - 0.0638541728 * self.blue_yellow);
        const short = cube(self.lightness - 0.0894841775 * self.green_red - 1.2914855480 * self.blue_yellow);
        return .{
            4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short,
            -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short,
            -0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short,
        };
    }
};

/// OKLab in polar form: `lightness` from 0 to 1, `chroma` from 0 (grey) up
/// to about 0.37 for the most vivid sRGB colors, `hue_degrees` from 0 to
/// 360 (about 29 is sRGB red, 142 green, 264 blue), and straight `alpha`.
/// A grey's hue is 0 and means nothing.
pub const Oklch = struct {
    lightness: f32,
    chroma: f32,
    hue_degrees: f32,
    alpha: f32 = 1,

    pub fn fromColor(color: Color) Oklch {
        return Oklab.fromColor(color).toOklch();
    }

    /// An out-of-gamut color is brought into sRGB by reducing its chroma,
    /// keeping its lightness and hue, rather than by clipping each channel.
    pub fn toColor(self: Oklch) Color {
        return self.toOklab().toColor();
    }

    pub fn fromExtendedColor(color: ExtendedColor) Oklch {
        return Oklab.fromExtendedColor(color).toOklch();
    }

    /// Unmapped: an `ExtendedColor` holds what lies outside sRGB.
    pub fn toExtendedColor(self: Oklch) ExtendedColor {
        return self.toOklab().toExtendedColor();
    }

    pub fn toOklab(self: Oklch) Oklab {
        const hue_radians = std.math.degreesToRadians(self.hue_degrees);
        return .{
            .lightness = self.lightness,
            .green_red = self.chroma * @cos(hue_radians),
            .blue_yellow = self.chroma * @sin(hue_radians),
            .alpha = self.alpha,
        };
    }

    /// Hue goes the shorter way around, so red to magenta passes no green.
    /// A grey takes the other color's hue, so a mix from grey to blue stays
    /// blue. `amount` 0 is `self`, 1 is `other`.
    pub fn mix(self: Oklch, other: Oklch, amount: f32) Oklch {
        const from_hue = if (self.chroma < achromatic_chroma) other.hue_degrees else self.hue_degrees;
        const to_hue = if (other.chroma < achromatic_chroma) from_hue else other.hue_degrees;
        var hue_change = to_hue - from_hue;
        if (hue_change > 180) hue_change -= 360;
        if (hue_change < -180) hue_change += 360;
        return .{
            .lightness = lerp(self.lightness, other.lightness, amount),
            .chroma = lerp(self.chroma, other.chroma, amount),
            .hue_degrees = normalizedDegrees(from_hue + hue_change * amount),
            .alpha = lerp(self.alpha, other.alpha, amount),
        };
    }
};

/// CSS's HSL, over sRGB-encoded channels: `hue_degrees` from 0 to 360,
/// `saturation` and `lightness` from 0 to 1, and straight `alpha`.
/// `hsl(210 50% 60%)` is `.{ .hue_degrees = 210, .saturation = 0.5, .lightness = 0.6 }`.
/// A grey's hue is 0. Its lightness is not perceptual: yellow and blue at
/// the same HSL lightness look nothing alike, which `Oklch` avoids.
pub const Hsl = struct {
    hue_degrees: f32,
    saturation: f32,
    lightness: f32,
    alpha: f32 = 1,

    pub fn fromColor(color: Color) Hsl {
        @setEvalBranchQuota(comptime_branch_quota);
        const red = encodedOf(color.r);
        const green = encodedOf(color.g);
        const blue = encodedOf(color.b);
        const brightest = @max(red, green, blue);
        const darkest = @min(red, green, blue);
        const lightness = (brightest + darkest) / 2;
        const spread = brightest - darkest;
        if (spread == 0 or lightness == 0 or lightness == 1) {
            return .{ .hue_degrees = 0, .saturation = 0, .lightness = lightness, .alpha = alphaOf(color) };
        }
        const sextant = if (brightest == red)
            (green - blue) / spread + @as(f32, if (green < blue) 6 else 0)
        else if (brightest == green)
            (blue - red) / spread + 2
        else
            (red - green) / spread + 4;
        return .{
            .hue_degrees = normalizedDegrees(sextant * 60),
            .saturation = (brightest - lightness) / @min(lightness, 1 - lightness),
            .lightness = lightness,
            .alpha = alphaOf(color),
        };
    }

    /// Saturation and lightness are clamped to 0 to 1; any hue wraps.
    pub fn toColor(self: Hsl) Color {
        @setEvalBranchQuota(comptime_branch_quota);
        const hue = normalizedDegrees(self.hue_degrees);
        const saturation = std.math.clamp(self.saturation, 0, 1);
        const lightness = std.math.clamp(self.lightness, 0, 1);
        const swing = saturation * @min(lightness, 1 - lightness);
        const channel = struct {
            fn at(offset: f32, hue_in_degrees: f32, base: f32, amplitude: f32) u8 {
                const position = @mod(offset + hue_in_degrees / 30, 12);
                return byteOfEncoded(base - amplitude * std.math.clamp(@min(position - 3, 9 - position), -1, 1));
            }
        }.at;
        return .{
            .r = channel(0, hue, lightness, swing),
            .g = channel(8, hue, lightness, swing),
            .b = channel(4, hue, lightness, swing),
            .a = byteOfEncoded(self.alpha),
        };
    }
};

/// Mixed in OKLab, so the middle is neither muddy nor too dark; alpha is
/// mixed linearly. `amount` is clamped to 0 (`from`) to 1 (`to`).
///
/// ```zig
/// const middle = zui_color.mix(.black, .white, 0.5); // #636363, where Color.mix gives #808080
/// ```
pub fn mix(from: Color, to: Color, amount: f32) Color {
    const clamped = std.math.clamp(amount, 0, 1);
    return Oklab.fromColor(from).mix(.fromColor(to), clamped).toColor();
}

/// Mixed in OKLCH, keeping chroma between the two and taking the shorter
/// way around the hue circle, so blue to red passes through purple at full
/// strength where `mix` passes through a greyer one. `amount` is clamped to
/// 0 (`from`) to 1 (`to`).
pub fn mixOklch(from: Color, to: Color, amount: f32) Color {
    const clamped = std.math.clamp(amount, 0, 1);
    return Oklch.fromColor(from).mix(.fromColor(to), clamped).toColor();
}

/// `steps` colors evenly spaced in OKLab from `from` to `to`, both
/// included.
///
/// ```zig
/// const surfaces = comptime zui_color.ramp(5, .rgb(0x101014), .rgb(0x3a3a48));
/// ```
pub fn ramp(comptime steps: usize, from: Color, to: Color) [steps]Color {
    requireBothEnds("ramp", steps);
    @setEvalBranchQuota(comptime_branch_quota + steps * branches_per_color);
    const start: Oklab = .fromColor(from);
    const end: Oklab = .fromColor(to);
    var colors: [steps]Color = undefined;
    colors[0] = from;
    colors[steps - 1] = to;
    for (colors[1 .. steps - 1], 1..) |*color, step| {
        color.* = start.mix(end, fractionOf(step, steps)).toColor();
    }
    return colors;
}

/// `color` at OKLCH `lightness`, keeping its hue, and its chroma where
/// sRGB can show it at that lightness.
pub fn withLightness(color: Color, lightness: f32) Color {
    var shade: Oklch = .fromColor(color);
    shade.lightness = std.math.clamp(lightness, 0, 1);
    return shade.toColor();
}

/// `color` made lighter by `change` in OKLCH lightness, or darker when it
/// is negative: a hovered or pressed shade of a skin's color.
///
/// ```zig
/// const hovered = comptime zui_color.shiftLightness(accent, 0.06);
/// const pressed = comptime zui_color.shiftLightness(accent, -0.08);
/// ```
pub fn shiftLightness(color: Color, change: f32) Color {
    return withLightness(color, Oklch.fromColor(color).lightness + change);
}

/// `steps` shades of `color`'s hue and chroma, evenly spaced in OKLCH
/// lightness from `darkest` to `lightest`, each brought into sRGB by
/// reducing its chroma: a tonal scale, as a design system's 50 to 900.
///
/// ```zig
/// const blues = comptime zui_color.lightnessScale(10, .rgb(0x3366ff), 0.25, 0.97);
/// ```
pub fn lightnessScale(comptime steps: usize, color: Color, darkest: f32, lightest: f32) [steps]Color {
    requireBothEnds("lightnessScale", steps);
    @setEvalBranchQuota(comptime_branch_quota + steps * branches_per_color);
    const base: Oklch = .fromColor(color);
    var shades: [steps]Color = undefined;
    for (&shades, 0..) |*shade, step| {
        var tone = base;
        tone.lightness = std.math.clamp(lerp(darkest, lightest, fractionOf(step, steps)), 0, 1);
        shade.* = tone.toColor();
    }
    return shades;
}

/// Below this, float error alone could account for the chroma, so the
/// color is treated as grey and its hue as meaningless.
const achromatic_chroma = 0.0002;

const gamut_tolerance = 0.00001;
const gamut_search_steps = 16;
// Every call made at comptime counts against the branch quota, and one
// conversion makes a few hundred, so the default quota of 1000 would end a
// comptime block after four colors. Each conversion raises it to this,
// which a block of hundreds of conversions fits.
const comptime_branch_quota = 200_000;
const branches_per_color = 1000;

fn requireBothEnds(comptime function_name: []const u8, comptime steps: usize) void {
    if (steps < 2) {
        @compileError(std.fmt.comptimePrint("zui_color: {s} needs at least 2 steps, one for each end; got {d}", .{ function_name, steps }));
    }
}

fn gamutMappedLinear(color: Oklab) [3]f32 {
    if (color.lightness >= 1) return .{ 1, 1, 1 };
    if (color.lightness <= 0) return .{ 0, 0, 0 };
    const unmapped = color.toLinear();
    if (isInGamut(unmapped)) return unmapped;

    const polar = color.toOklch();
    var shown_chroma: f32 = 0;
    var hidden_chroma: f32 = polar.chroma;
    inline for (0..gamut_search_steps) |_| {
        const tried_chroma = (shown_chroma + hidden_chroma) / 2;
        var tried = polar;
        tried.chroma = tried_chroma;
        if (isInGamut(tried.toOklab().toLinear())) shown_chroma = tried_chroma else hidden_chroma = tried_chroma;
    }
    var mapped = polar;
    mapped.chroma = shown_chroma;
    return mapped.toOklab().toLinear();
}

fn isInGamut(rgb: [3]f32) bool {
    const channels: @Vector(3, f32) = rgb;
    return @reduce(.And, channels >= @as(@Vector(3, f32), @splat(-gamut_tolerance))) and
        @reduce(.And, channels <= @as(@Vector(3, f32), @splat(1 + gamut_tolerance)));
}

fn linearOf(color: Color) [3]f32 {
    return .{ linear_of_byte[color.r], linear_of_byte[color.g], linear_of_byte[color.b] };
}

fn colorOfLinear(rgb: [3]f32, alpha: f32) Color {
    return .{ .r = byteOfLinear(rgb[0]), .g = byteOfLinear(rgb[1]), .b = byteOfLinear(rgb[2]), .a = byteOfEncoded(alpha) };
}

// `std.math.pow` at comptime spends hundreds of backward branches a call,
// so a few conversions in one comptime block would exhaust the default
// quota. The transfer function is paid once here instead, for every byte.
const linear_of_byte: [256]f32 = transferTable(0);
const linear_rounding_up_to_byte: [256]f32 = transferTable(0.5);

fn transferTable(comptime offset_in_bytes: f32) [256]f32 {
    @setEvalBranchQuota(256 * 1000);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*linear, byte| linear.* = linearFromEncoded((@as(f32, @floatFromInt(byte)) + offset_in_bytes) / 255);
    return table;
}

fn linearFromEncoded(encoded: f32) f32 {
    return if (encoded <= 0.04045) encoded / 12.92 else std.math.pow(f32, (encoded + 0.055) / 1.055, 2.4);
}

/// The byte whose encoding `linear` rounds to, found a bit at a time: a
/// byte is at least `candidate` when `linear` reaches the boundary
/// rounding up from the byte below it.
fn byteOfLinear(linear: f32) u8 {
    var byte: u8 = 0;
    inline for (0..8) |bit_from_top| {
        const candidate = byte | (@as(u8, 0x80) >> bit_from_top);
        if (linear >= linear_rounding_up_to_byte[candidate - 1]) byte = candidate;
    }
    return byte;
}

fn encodedOf(channel: u8) f32 {
    return @as(f32, @floatFromInt(channel)) / 255;
}

fn alphaOf(color: Color) f32 {
    return encodedOf(color.a);
}

fn byteOfEncoded(encoded: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(encoded, 0, 1) * 255));
}

fn fractionOf(step: usize, steps: usize) f32 {
    return @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps - 1));
}

fn normalizedDegrees(degrees: f32) f32 {
    const wrapped = @mod(degrees, 360);
    return if (wrapped >= 360) 0 else wrapped;
}

fn lerp(from: f32, to: f32, amount: f32) f32 {
    return from + (to - from) * amount;
}

fn cube(value: f32) f32 {
    return value * value * value;
}

test {
    _ = @import("tests.zig");
}

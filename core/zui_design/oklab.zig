//! The OKLab conversions a resolver needs, over `zui.design.Oklch`: to and
//! from linear sRGB, and into sRGB's gamut by reducing chroma.

const std = @import("std");
const zui = @import("zui");

const Oklch = zui.design.Oklch;

/// A color in OKLab: `lightness` from 0 to 1, `green_red` from green
/// (negative) to red, `blue_yellow` from blue (negative) to yellow.
pub const Oklab = struct {
    lightness: f32,
    green_red: f32,
    blue_yellow: f32,

    /// By Björn Ottosson's matrices.
    pub fn fromLinear(rgb: [3]f32) Oklab {
        const red, const green, const blue = rgb;
        const long = std.math.cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue);
        const medium = std.math.cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue);
        const short = std.math.cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue);
        return .{
            .lightness = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
            .green_red = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
            .blue_yellow = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short,
        };
    }

    /// Unclamped: a channel below 0 or above 1 is outside sRGB's gamut.
    pub fn toLinear(self: Oklab) [3]f32 {
        const long = cube(self.lightness + 0.3963377774 * self.green_red + 0.2158037573 * self.blue_yellow);
        const medium = cube(self.lightness - 0.1055613458 * self.green_red - 0.0638541728 * self.blue_yellow);
        const short = cube(self.lightness - 0.0894841775 * self.green_red - 1.2914855480 * self.blue_yellow);
        return .{
            4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short,
            -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short,
            -0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short,
        };
    }

    pub fn fromOklch(color: Oklch) Oklab {
        const hue_radians = std.math.degreesToRadians(color.hue);
        return .{
            .lightness = color.lightness,
            .green_red = color.chroma * @cos(hue_radians),
            .blue_yellow = color.chroma * @sin(hue_radians),
        };
    }

    pub fn toOklch(self: Oklab) Oklch {
        const chroma = @sqrt(self.green_red * self.green_red + self.blue_yellow * self.blue_yellow);
        const hue = if (chroma < achromatic_chroma) 0 else normalizedDegrees(std.math.radiansToDegrees(std.math.atan2(self.blue_yellow, self.green_red)));
        return .{ .lightness = self.lightness, .chroma = chroma, .hue = hue };
    }

    /// `amount` 0 is `self`, 1 is `other`.
    pub fn mix(self: Oklab, other: Oklab, amount: f32) Oklab {
        return .{
            .lightness = lerp(self.lightness, other.lightness, amount),
            .green_red = lerp(self.green_red, other.green_red, amount),
            .blue_yellow = lerp(self.blue_yellow, other.blue_yellow, amount),
        };
    }
};

pub fn oklchOfColor(color: zui.Color) Oklch {
    return Oklab.fromLinear(.{ linear_of_byte[color.r], linear_of_byte[color.g], linear_of_byte[color.b] }).toOklch();
}

/// `color` in linear sRGB, its chroma reduced until sRGB can show it,
/// keeping its lightness and hue.
pub fn gamutMappedLinear(color: Oklch) [3]f32 {
    if (color.lightness >= 1) return .{ 1, 1, 1 };
    if (color.lightness <= 0) return .{ 0, 0, 0 };
    const unmapped = Oklab.fromOklch(color).toLinear();
    if (isInGamut(unmapped)) return clampedToGamut(unmapped);

    var shown_chroma: f32 = 0;
    var hidden_chroma: f32 = color.chroma;
    inline for (0..gamut_search_steps) |_| {
        var tried = color;
        tried.chroma = (shown_chroma + hidden_chroma) / 2;
        if (isInGamut(Oklab.fromOklch(tried).toLinear())) shown_chroma = tried.chroma else hidden_chroma = tried.chroma;
    }
    var mapped = color;
    mapped.chroma = shown_chroma;
    return clampedToGamut(Oklab.fromOklch(mapped).toLinear());
}

pub fn isInGamut(rgb: [3]f32) bool {
    const channels: @Vector(3, f32) = rgb;
    return @reduce(.And, channels >= @as(@Vector(3, f32), @splat(-gamut_tolerance))) and
        @reduce(.And, channels <= @as(@Vector(3, f32), @splat(1 + gamut_tolerance)));
}

/// Encoded to sRGB bytes, with a straight `alpha` from 0 to 1.
pub fn colorOfLinear(rgb: [3]f32, alpha: f32) zui.Color {
    return .{ .r = byteOfLinear(rgb[0]), .g = byteOfLinear(rgb[1]), .b = byteOfLinear(rgb[2]), .a = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255)) };
}

/// Below this, float error alone could account for the chroma, so the
/// color is grey and its hue means nothing.
const achromatic_chroma = 0.0002;
const gamut_tolerance = 0.00001;
const gamut_search_steps = 16;

fn clampedToGamut(rgb: [3]f32) [3]f32 {
    return @min(@max(@as(@Vector(3, f32), rgb), @as(@Vector(3, f32), @splat(0))), @as(@Vector(3, f32), @splat(1)));
}

// `std.math.pow` at comptime spends hundreds of backward branches a call,
// so the transfer function is paid once here, for every byte, rather than
// in each conversion of a comptime resolve.
/// Each encoded sRGB byte's linear value.
pub const linear_of_byte: [256]f32 = transferTable(0);
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

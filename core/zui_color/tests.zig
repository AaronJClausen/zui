const std = @import("std");
const zui = @import("zui");
const zui_color = @import("zui_color.zig");

const testing = std.testing;
const Color = zui.Color;
const Oklab = zui_color.Oklab;
const Oklch = zui_color.Oklch;
const Hsl = zui_color.Hsl;

/// The published values carry seven digits; f32 and the matrices' ten
/// digits agree with them to well within this.
const reference_tolerance = 0.0005;

fn expectOklab(expected: Oklab, actual: Oklab) !void {
    try testing.expectApproxEqAbs(expected.lightness, actual.lightness, reference_tolerance);
    try testing.expectApproxEqAbs(expected.green_red, actual.green_red, reference_tolerance);
    try testing.expectApproxEqAbs(expected.blue_yellow, actual.blue_yellow, reference_tolerance);
}

fn expectWithinOneStep(expected: Color, actual: Color) !void {
    inline for (.{ "r", "g", "b", "a" }) |channel| {
        const difference = @abs(@as(i16, @field(expected, channel)) - @as(i16, @field(actual, channel)));
        if (difference > 1) {
            std.debug.print("expected {any}, got {any}\n", .{ expected, actual });
            return error.TestExpectedEqual;
        }
    }
}

test "sRGB's white, black, grey and primaries land on their published OKLab values" {
    const cases = comptime [_]struct { color: Color, oklab: Oklab }{
        .{ .color = .white, .oklab = .{ .lightness = 1, .green_red = 0, .blue_yellow = 0 } },
        .{ .color = .black, .oklab = .{ .lightness = 0, .green_red = 0, .blue_yellow = 0 } },
        .{ .color = .rgb(0x808080), .oklab = .{ .lightness = 0.5998708, .green_red = 0, .blue_yellow = 0 } },
        .{ .color = .rgb(0xff0000), .oklab = .{ .lightness = 0.6279554, .green_red = 0.2248631, .blue_yellow = 0.1258463 } },
        .{ .color = .rgb(0x00ff00), .oklab = .{ .lightness = 0.8664396, .green_red = -0.2338876, .blue_yellow = 0.1794985 } },
        .{ .color = .rgb(0x0000ff), .oklab = .{ .lightness = 0.4520137, .green_red = -0.0324570, .blue_yellow = -0.3115281 } },
    };
    inline for (cases) |case| {
        try expectOklab(case.oklab, Oklab.fromColor(case.color));
        try expectOklab(case.oklab, comptime Oklab.fromColor(case.color));
    }
}

test "OKLCH gives sRGB's primaries their published chroma and hue, and grey none" {
    const red: Oklch = .fromColor(.rgb(0xff0000));
    try testing.expectApproxEqAbs(@as(f32, 0.2576833), red.chroma, reference_tolerance);
    try testing.expectApproxEqAbs(@as(f32, 29.2338851), red.hue_degrees, 0.05);
    const blue = comptime Oklch.fromColor(.rgb(0x0000ff));
    try testing.expectApproxEqAbs(@as(f32, 0.3132141), blue.chroma, reference_tolerance);
    try testing.expectApproxEqAbs(@as(f32, 264.0520206), blue.hue_degrees, 0.05);
    const grey: Oklch = .fromColor(.rgb(0x808080));
    try testing.expectApproxEqAbs(@as(f32, 0), grey.chroma, reference_tolerance);
    try testing.expectEqual(@as(f32, 0), grey.hue_degrees);
}

test "every sRGB color comes back from OKLab, OKLCH and HSL within one 8-bit step" {
    var red: u16 = 0;
    while (red <= 255) : (red += 15) {
        var green: u16 = 0;
        while (green <= 255) : (green += 15) {
            var blue: u16 = 0;
            while (blue <= 255) : (blue += 15) {
                const color: Color = .{ .r = @intCast(red), .g = @intCast(green), .b = @intCast(blue), .a = @intCast(255 - red) };
                try expectWithinOneStep(color, Oklab.fromColor(color).toColor());
                try expectWithinOneStep(color, Oklch.fromColor(color).toColor());
                try expectWithinOneStep(color, Hsl.fromColor(color).toColor());
            }
        }
    }
    const comptime_round_trip = comptime Oklch.fromColor(.rgb(0x3366ff)).toColor();
    try expectWithinOneStep(.rgb(0x3366ff), comptime_round_trip);
}

test "an ExtendedColor goes through OKLab unclamped" {
    const brighter_than_white = zui.ExtendedColor.linear(2, 2, 2, 0.5);
    const oklab: Oklab = .fromExtendedColor(brighter_than_white);
    try testing.expect(oklab.lightness > 1);
    const back = oklab.toExtendedColor();
    try testing.expectApproxEqAbs(@as(f32, 2), @as(f32, back.r), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), @as(f32, back.a), 0.001);
    const blue = comptime Oklch.fromExtendedColor(.rgb(0x0000ff)).toExtendedColor();
    try testing.expectApproxEqAbs(@as(f32, 1), @as(f32, blue.b), 0.002);
    try testing.expectApproxEqAbs(@as(f32, 0), @as(f32, blue.r), 0.002);
}

test "HSL follows CSS's definitions" {
    const cases = comptime [_]struct { hsl: Hsl, color: Color }{
        .{ .hsl = .{ .hue_degrees = 0, .saturation = 1, .lightness = 0.5 }, .color = .rgb(0xff0000) },
        .{ .hsl = .{ .hue_degrees = 120, .saturation = 1, .lightness = 0.25 }, .color = .rgb(0x008000) },
        .{ .hsl = .{ .hue_degrees = 210, .saturation = 0.5, .lightness = 0.6 }, .color = .rgb(0x6699cc) },
        .{ .hsl = .{ .hue_degrees = 300, .saturation = 1, .lightness = 0.5 }, .color = .rgb(0xff00ff) },
        .{ .hsl = .{ .hue_degrees = 0, .saturation = 0, .lightness = 1 }, .color = .white },
    };
    inline for (cases) |case| {
        try testing.expectEqual(case.color, case.hsl.toColor());
        try testing.expectEqual(case.color, comptime case.hsl.toColor());
        const back: Hsl = .fromColor(case.color);
        try testing.expectEqual(case.color, back.toColor());
    }
    const steel_blue: Hsl = .fromColor(.rgb(0x6699cc));
    try testing.expectApproxEqAbs(@as(f32, 210), steel_blue.hue_degrees, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), steel_blue.saturation, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.6), steel_blue.lightness, 0.001);
    const wrapped: Hsl = .{ .hue_degrees = -240, .saturation = 1, .lightness = 0.25 };
    try testing.expectEqual(Color.rgb(0x008000), wrapped.toColor());
    try testing.expectEqual(@as(f32, 0), Hsl.fromColor(.rgb(0x808080)).hue_degrees);
}

test "mix's ends are its colors exactly, and its middle is OKLab's" {
    const from: Color = .rgba(0x3366ff20);
    const to: Color = .rgba(0xffcc00e0);
    try testing.expectEqual(from, zui_color.mix(from, to, 0));
    try testing.expectEqual(to, zui_color.mix(from, to, 1));
    try testing.expectEqual(to, zui_color.mix(from, to, 3));
    try testing.expectEqual(from, zui_color.mixOklch(from, to, -1));
    try testing.expectEqual(to, zui_color.mixOklch(from, to, 1));
    try testing.expectEqual(Color.rgb(0x636363), zui_color.mix(.black, .white, 0.5));
    try testing.expectEqual(Color.black.mixOklab(.white, 0.25), zui_color.mix(.black, .white, 0.25));
    try testing.expectEqual(Color.rgb(0x636363), comptime zui_color.mix(.black, .white, 0.5));
    try testing.expectEqual(@as(u8, 0x80), zui_color.mix(from, to, 0.5).a);
}

test "OKLCH's mix takes the shorter way around the hue circle" {
    const crimson: Oklch = .{ .lightness = 0.6, .chroma = 0.2, .hue_degrees = 350 };
    const vermilion: Oklch = .{ .lightness = 0.6, .chroma = 0.2, .hue_degrees = 30 };
    try testing.expectApproxEqAbs(@as(f32, 10), crimson.mix(vermilion, 0.5).hue_degrees, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), vermilion.mix(crimson, 0.5).hue_degrees, 0.001);
    const comptime_middle = comptime crimson.mix(vermilion, 0.25);
    try testing.expectApproxEqAbs(@as(f32, 0), comptime_middle.hue_degrees, 0.001);

    const grey: Oklch = .{ .lightness = 0.6, .chroma = 0, .hue_degrees = 0 };
    const blue: Oklch = .{ .lightness = 0.6, .chroma = 0.2, .hue_degrees = 264 };
    try testing.expectApproxEqAbs(@as(f32, 264), grey.mix(blue, 0.5).hue_degrees, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 264), blue.mix(grey, 0.5).hue_degrees, 0.001);

    const purple = zui_color.mixOklch(.rgb(0x0000ff), .rgb(0xff0000), 0.5);
    const purple_hue = Oklch.fromColor(purple).hue_degrees;
    try testing.expect(purple_hue > 300 and purple_hue < 340);
    try testing.expect(Oklch.fromColor(purple).chroma > Oklch.fromColor(zui_color.mix(.rgb(0x0000ff), .rgb(0xff0000), 0.5)).chroma);
}

test "a color outside sRGB loses chroma, not lightness or hue" {
    const too_vivid: Oklch = .{ .lightness = 0.7, .chroma = 0.4, .hue_degrees = 264 };
    inline for (.{ too_vivid.toColor(), comptime too_vivid.toColor() }) |shown| {
        const landed: Oklch = .fromColor(shown);
        try testing.expectApproxEqAbs(@as(f32, 0.7), landed.lightness, 0.01);
        try testing.expectApproxEqAbs(@as(f32, 264), landed.hue_degrees, 2);
        try testing.expect(landed.chroma < 0.4);
        const at_the_edge = shown.r <= 1 or shown.g <= 1 or shown.b <= 1 or shown.r >= 254 or shown.g >= 254 or shown.b >= 254;
        try testing.expect(at_the_edge);
    }
    const beyond_white: Oklch = .{ .lightness = 1.2, .chroma = 0.1, .hue_degrees = 90 };
    try testing.expectEqual(Color.white, beyond_white.toColor());
    const beyond_black: Oklch = .{ .lightness = -0.1, .chroma = 0.1, .hue_degrees = 90, .alpha = 0.5 };
    try testing.expectEqual(Color.rgba(0x00000080), beyond_black.toColor());
}

test "a ramp holds both ends and evenly spaced steps between" {
    const from = comptime Color.rgb(0x15151c);
    const to = comptime Color.rgb(0xf4f4f8);
    const greys = comptime zui_color.ramp(9, from, to);
    try testing.expectEqual(greys, zui_color.ramp(9, from, to));
    try testing.expectEqual(from, greys[0]);
    try testing.expectEqual(to, greys[8]);
    try testing.expectEqual(zui_color.mix(from, to, 0.5), greys[4]);
    const start = Oklab.fromColor(from).lightness;
    const end = Oklab.fromColor(to).lightness;
    for (greys, 0..) |grey, step| {
        const expected = start + (end - start) * @as(f32, @floatFromInt(step)) / 8;
        try testing.expectApproxEqAbs(expected, Oklab.fromColor(grey).lightness, 0.004);
    }
    try testing.expectEqual([2]Color{ from, to }, zui_color.ramp(2, from, to));
}

test "lightness steps keep a color's hue while sRGB has room for its chroma" {
    const accent = comptime Color.rgb(0x3366ff);
    const base: Oklch = .fromColor(accent);
    const hovered = comptime zui_color.shiftLightness(accent, 0.06);
    try testing.expectEqual(hovered, zui_color.shiftLightness(accent, 0.06));
    try testing.expectApproxEqAbs(base.lightness + 0.06, Oklch.fromColor(hovered).lightness, 0.005);
    try testing.expectApproxEqAbs(base.hue_degrees, Oklch.fromColor(hovered).hue_degrees, 1);
    const pressed = zui_color.shiftLightness(accent, -0.08);
    try testing.expectApproxEqAbs(base.lightness - 0.08, Oklch.fromColor(pressed).lightness, 0.005);
    try testing.expectEqual(Color.white, zui_color.withLightness(accent, 1));
    try testing.expectEqual(Color.black, zui_color.withLightness(accent, 0));

    const blues = comptime zui_color.lightnessScale(10, accent, 0.25, 0.97);
    try testing.expectEqual(blues, zui_color.lightnessScale(10, accent, 0.25, 0.97));
    var previous_lightness: f32 = 0;
    for (blues, 0..) |blue, step| {
        const shade: Oklch = .fromColor(blue);
        const expected = 0.25 + 0.72 * @as(f32, @floatFromInt(step)) / 9;
        try testing.expectApproxEqAbs(expected, shade.lightness, 0.006);
        try testing.expect(shade.lightness > previous_lightness);
        try testing.expect(shade.chroma <= base.chroma + 0.005);
        try testing.expectApproxEqAbs(base.hue_degrees, shade.hue_degrees, 3);
        previous_lightness = shade.lightness;
    }
}

test "a comptime block converts a hundred colors without raising the branch quota" {
    const greens = comptime shades: {
        var shades: [100]Color = undefined;
        for (&shades, 0..) |*shade, step| shade.* = zui_color.shiftLightness(.rgb(0x00ff00), -@as(f32, @floatFromInt(step)) / 200);
        break :shades shades;
    };
    for (greens, 0..) |green, step| {
        try testing.expectEqual(zui_color.shiftLightness(.rgb(0x00ff00), -@as(f32, @floatFromInt(step)) / 200), green);
    }
}

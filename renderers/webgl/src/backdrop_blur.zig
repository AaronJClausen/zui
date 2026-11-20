const std = @import("std");
const zui = @import("zui");

/// Whole pixels from the target's top left, so every sample lands on a
/// texel's center.
pub const PixelRegion = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    pub fn covering(bounds: zui.Rect, pixels_per_unit: [2]f32, size: [2]f32) PixelRegion {
        return .{
            .left = std.math.clamp(@floor(bounds.x * pixels_per_unit[0]), 0, size[0]),
            .top = std.math.clamp(@floor(bounds.y * pixels_per_unit[1]), 0, size[1]),
            .right = std.math.clamp(@ceil((bounds.x + bounds.width) * pixels_per_unit[0]), 0, size[0]),
            .bottom = std.math.clamp(@ceil((bounds.y + bounds.height) * pixels_per_unit[1]), 0, size[1]),
        };
    }

    pub fn isEmpty(region: PixelRegion) bool {
        return region.right - region.left < 1 or region.bottom - region.top < 1;
    }
};

/// A Gaussian sampled at whole pixels out to three standard deviations,
/// with each pair of neighbouring pixels taken by one linearly filtered
/// sample between them, weighted so the filter splits it as the two
/// weights do.
pub const Taps = struct {
    pub const max_pairs_per_side = 64;
    pub const max_count = 2 * max_pairs_per_side + 1;
    /// Wider blurs are drawn at this standard deviation, in pixels.
    pub const max_sigma: f32 = 2.0 * max_pairs_per_side / 3.0;

    offsets: [max_count]f32 = undefined,
    weights: [max_count]f32 = undefined,
    count: usize = 0,

    pub fn gaussian(sigma_pixels: f32) Taps {
        var taps: Taps = .{};
        const sigma = @min(sigma_pixels, max_sigma);
        if (!(sigma > 0)) {
            taps.add(0, 1);
            return taps;
        }
        const reach: usize = @min(@as(usize, @intFromFloat(@ceil(3 * sigma))), 2 * max_pairs_per_side);
        var total = weightAt(0, sigma);
        for (1..reach + 1) |distance| total += 2 * weightAt(distance, sigma);
        taps.add(0, weightAt(0, sigma) / total);
        var near: usize = 1;
        while (near <= reach) : (near += 2) {
            const near_weight = weightAt(near, sigma);
            const far_weight = if (near + 1 <= reach) weightAt(near + 1, sigma) else 0;
            const pair_weight = near_weight + far_weight;
            const near_distance: f32 = @floatFromInt(near);
            const offset = near_distance + far_weight / pair_weight;
            taps.add(offset, pair_weight / total);
            taps.add(-offset, pair_weight / total);
        }
        return taps;
    }

    fn weightAt(distance: usize, sigma: f32) f32 {
        const pixels: f32 = @floatFromInt(distance);
        return @exp(-pixels * pixels / (2 * sigma * sigma));
    }

    fn add(self: *Taps, offset: f32, weight: f32) void {
        self.offsets[self.count] = offset;
        self.weights[self.count] = weight;
        self.count += 1;
    }
};

/// A tap's weight as zui-sokol sums it: sokol_gl's vertex colors are
/// 8-bit, so it is a coarse part in steps of 1/255 and the remainder in
/// steps of 1/65025, each added on its own.
pub const SplitWeight = struct {
    coarse: u8,
    fine: u8,

    pub fn of(weight: f32) SplitWeight {
        const in_steps = std.math.clamp(weight, 0, 1) * 255;
        const coarse = @floor(in_steps);
        const fine = @round((in_steps - coarse) * 255);
        if (fine == 255) return .{ .coarse = @intFromFloat(@min(coarse + 1, 255)), .fine = 0 };
        return .{ .coarse = @intFromFloat(coarse), .fine = @intFromFloat(fine) };
    }

    pub fn coarseValue(self: SplitWeight) f32 {
        return @as(f32, @floatFromInt(self.coarse)) / 255;
    }

    pub fn fineValue(self: SplitWeight) f32 {
        return @as(f32, @floatFromInt(self.fine)) / 255 / 255;
    }
};

test "a blur's taps sum to one and are symmetric" {
    for ([_]f32{ 0.5, 3, 8, 21.3, 42, 200 }) |sigma| {
        const taps: Taps = .gaussian(sigma);
        var total: f32 = 0;
        for (taps.weights[0..taps.count]) |weight| total += weight;
        try std.testing.expectApproxEqAbs(@as(f32, 1), total, 1e-5);
        try std.testing.expect(taps.count % 2 == 1 and taps.count <= Taps.max_count);
        for (1..taps.count / 2 + 1) |pair| try std.testing.expectEqual(taps.offsets[2 * pair - 1], -taps.offsets[2 * pair]);
    }
}

test "a pair's sample sits between its two pixels, nearer the heavier" {
    const taps: Taps = .gaussian(8);
    try std.testing.expectEqual(@as(f32, 0), taps.offsets[0]);
    try std.testing.expect(taps.offsets[1] > 1 and taps.offsets[1] < 1.5);
}

test "no blur is a single tap of the pixel itself" {
    const taps: Taps = .gaussian(0);
    try std.testing.expectEqual(1, taps.count);
    try std.testing.expectEqual(@as(f32, 1), taps.weights[0]);
}

test "the widest blur's split weights sum to one within a quarter of a color step" {
    const taps: Taps = .gaussian(Taps.max_sigma);
    var total: f32 = 0;
    for (taps.weights[0..taps.count]) |weight| {
        const split: SplitWeight = .of(weight);
        total += split.coarseValue() + split.fineValue();
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1), total, 0.25 / 255.0);
}

test "a region covers every pixel the bounds touch, inside the target" {
    const region: PixelRegion = .covering(.{ .x = -3.2, .y = 1.5, .width = 10, .height = 4 }, .{ 2, 2 }, .{ 12, 100 });
    try std.testing.expectEqual(PixelRegion{ .left = 0, .top = 3, .right = 12, .bottom = 11 }, region);
}

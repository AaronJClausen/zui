const std = @import("std");

/// A point estimate and the 95% confidence interval around it.
pub const Interval = struct {
    lower: f64,
    estimate: f64,
    upper: f64,

    pub fn width(interval: Interval) f64 {
        return interval.upper - interval.lower;
    }

    /// How far past no change (a ratio of 1) the interval reaches on its
    /// farther side.
    pub fn reach(interval: Interval) f64 {
        return @max(@abs(interval.lower - 1), @abs(interval.upper - 1));
    }
};

pub const resamples = 10_000;
pub const seed = 0x5eed_2b0b;

/// The median of `values`, which it sorts.
pub fn median(values: []f64) f64 {
    std.mem.sortUnstable(f64, values, {}, std.sort.asc(f64));
    const middle = values.len / 2;
    return if (values.len % 2 == 1) values[middle] else (values[middle - 1] + values[middle]) / 2;
}

/// The bootstrap 95% confidence interval of the median of every value in
/// `groups`, resampling in two stages: whole groups first, then values
/// within each chosen group. With one group, this resamples the values.
///
/// ```zig
/// // Ratios from two code layouts, three rounds each: the interval also
/// // covers how much the layout moves the result.
/// const by_layout = [_][]const f64{ &.{ 1.01, 1.02, 1.00 }, &.{ 0.97, 0.98, 0.99 } };
/// const change = try bootstrapMedian(arena, &by_layout);
/// ```
pub fn bootstrapMedian(scratch: std.mem.Allocator, groups: []const []const f64) !Interval {
    var total: usize = 0;
    var longest: usize = 0;
    for (groups) |group| {
        total += group.len;
        longest = @max(longest, group.len);
    }
    const all = try scratch.alloc(f64, total);
    defer scratch.free(all);
    const resample = try scratch.alloc(f64, groups.len * longest);
    defer scratch.free(resample);
    const medians = try scratch.alloc(f64, resamples);
    defer scratch.free(medians);

    var offset: usize = 0;
    for (groups) |group| {
        @memcpy(all[offset..][0..group.len], group);
        offset += group.len;
    }
    const estimate = median(all);

    var random: std.Random.DefaultPrng = .init(seed);
    const rng = random.random();
    for (medians) |*resampled_median| {
        var count: usize = 0;
        for (0..groups.len) |_| {
            const group = groups[rng.uintLessThan(usize, groups.len)];
            for (0..group.len) |_| {
                resample[count] = group[rng.uintLessThan(usize, group.len)];
                count += 1;
            }
        }
        resampled_median.* = median(resample[0..count]);
    }
    std.mem.sortUnstable(f64, medians, {}, std.sort.asc(f64));
    return .{
        .lower = medians[resamples * 25 / 1000],
        .estimate = estimate,
        .upper = medians[resamples * 975 / 1000 - 1],
    };
}

/// The value below which `fraction` of the sorted samples fall.
pub fn percentile(sorted: []const u64, fraction: f64) u64 {
    const position: usize = @intFromFloat(@floor(fraction * @as(f64, @floatFromInt(sorted.len - 1))));
    return sorted[position];
}

pub const Clusters = struct {
    lower_median: u64,
    upper_median: u64,
    /// The share of samples in the upper cluster.
    upper_share: f64,
};

/// Two clusters, when the sorted samples have a gap much wider than the
/// spread within the samples on either side of it: a sign that something,
/// such as a clock change or a second code path, moved part of the run.
/// Each cluster must hold at least a tenth of the samples, so a slow tail
/// is not taken for one.
pub fn twoClusters(sorted: []const u64) ?Clusters {
    const count = sorted.len;
    if (count < 20) return null;
    const smallest_cluster = count / 10;
    var gap_index: usize = smallest_cluster - 1;
    for (smallest_cluster - 1..count - smallest_cluster) |index| {
        if (sorted[index + 1] - sorted[index] > sorted[gap_index + 1] - sorted[gap_index]) gap_index = index;
    }
    const gap = sorted[gap_index + 1] - sorted[gap_index];
    const lower = sorted[0 .. gap_index + 1];
    const upper = sorted[gap_index + 1 ..];
    // Without the clock's step, a 1.7 µs scene timed by a 0.1 µs clock
    // splits into two "clusters" one step apart.
    const spread = @max(interquartileRange(lower), interquartileRange(upper), sorted[count / 2] / 200, smallestStep(sorted));
    if (gap <= 5 * spread or gap * 50 <= sorted[count / 2]) return null;
    return .{
        .lower_median = lower[lower.len / 2],
        .upper_median = upper[upper.len / 2],
        .upper_share = @as(f64, @floatFromInt(upper.len)) / @as(f64, @floatFromInt(count)),
    };
}

/// The smallest difference between two distinct samples: the clock's
/// resolution, or finer.
fn smallestStep(sorted: []const u64) u64 {
    var step: u64 = std.math.maxInt(u64);
    for (sorted[0 .. sorted.len - 1], sorted[1..]) |previous, next| {
        if (next != previous) step = @min(step, next - previous);
    }
    return if (step == std.math.maxInt(u64)) 0 else step;
}

fn interquartileRange(sorted: []const u64) u64 {
    return sorted[sorted.len - 1 - sorted.len / 4] - sorted[sorted.len / 4];
}

test "the interval of identical ratios is that ratio" {
    const ratios = [_]f64{ 1.0, 1.0, 1.0, 1.0 };
    const interval = try bootstrapMedian(std.testing.allocator, &.{&ratios});
    try std.testing.expectEqual(Interval{ .lower = 1, .estimate = 1, .upper = 1 }, interval);
}

test "the interval covers the median and lies within the values" {
    const ratios = [_]f64{ 0.98, 1.03, 0.99, 1.01, 1.0, 1.02, 0.97, 1.0, 1.01, 0.99 };
    const interval = try bootstrapMedian(std.testing.allocator, &.{&ratios});
    try std.testing.expect(interval.lower <= interval.estimate and interval.estimate <= interval.upper);
    try std.testing.expect(interval.lower >= 0.97 and interval.upper <= 1.03);
    try std.testing.expect(interval.lower < 1 and interval.upper > 1);
}

test "resampling groups widens the interval when the groups disagree" {
    const one = [_]f64{ 1.04, 1.05, 1.04, 1.05, 1.04 };
    const other = [_]f64{ 0.96, 0.95, 0.96, 0.95, 0.96 };
    const values = one ++ other;
    const by_value = try bootstrapMedian(std.testing.allocator, &.{&values});
    const by_group = try bootstrapMedian(std.testing.allocator, &.{ &one, &other });
    try std.testing.expect(by_group.width() >= by_value.width());
    try std.testing.expect(by_group.lower <= 0.96 and by_group.upper >= 1.04);
}

test "the same values give the same interval every time" {
    const ratios = [_]f64{ 0.98, 1.03, 0.99, 1.01, 1.0, 1.02 };
    const first = try bootstrapMedian(std.testing.allocator, &.{&ratios});
    const second = try bootstrapMedian(std.testing.allocator, &.{&ratios});
    try std.testing.expectEqual(first, second);
}

test "two clusters are found, and one cluster with a tail is not" {
    var bimodal: [100]u64 = undefined;
    for (&bimodal, 0..) |*sample, index| sample.* = if (index < 60) 1000 + index / 12 else 1200 + (index - 60) / 8;
    const clusters = twoClusters(&bimodal).?;
    try std.testing.expectEqual(1002, clusters.lower_median);
    try std.testing.expectEqual(1202, clusters.upper_median);
    try std.testing.expectEqual(0.4, clusters.upper_share);

    var tailed: [100]u64 = undefined;
    for (&tailed, 0..) |*sample, index| sample.* = 1000 + index * index / 20;
    try std.testing.expectEqual(null, twoClusters(&tailed));
}

test "samples one clock step apart are one cluster" {
    var quantized: [100]u64 = undefined;
    for (&quantized, 0..) |*sample, index| sample.* = if (index < 20) 1700 else 1800;
    try std.testing.expectEqual(null, twoClusters(&quantized));
}

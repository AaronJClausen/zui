const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const fade_id: zui.Id = .of("fade");
const drawer_id: zui.Id = .of("drawer");

const sixteen_frame_linear_tween: zui.motion.TweenOptions = .{ .duration = 16 * @as(f32, support.frame_interval_ns) / std.time.ns_per_s, .easing = .linear };

test "zui.motion.tween eases toward its target, asking for frames only while it moves" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    try testing.expectEqual(0, zui.motion.tween(harness.begin(), fade_id, f32, 0, sixteen_frame_linear_tween));
    _ = try harness.end();
    try testing.expectEqual(zui.NextFrame.on_event, harness.ui.nextFrame());

    var previous: f32 = 0;
    for (0..16) |_| {
        const value = zui.motion.tween(harness.begin(), fade_id, f32, 16, sixteen_frame_linear_tween);
        _ = try harness.end();
        try testing.expect(value >= previous and value < 16);
        try testing.expectEqual(zui.NextFrame.immediately, harness.ui.nextFrame());
        previous = value;
    }
    try testing.expectEqual(16, zui.motion.tween(harness.begin(), fade_id, f32, 16, sixteen_frame_linear_tween));
    _ = try harness.end();
    try testing.expectEqual(zui.NextFrame.on_event, harness.ui.nextFrame());
}

test "zui.motion.spring follows its target without overshooting and comes to rest on it" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    const drawer: zui.motion.SpringOptions = .{ .angular_frequency = 40 };

    try testing.expectEqual(-280, zui.motion.spring(harness.begin(), drawer_id, f32, -280, drawer));
    _ = try harness.end();

    var previous: f32 = -280;
    var frames: usize = 0;
    while (frames < 120) : (frames += 1) {
        const value = zui.motion.spring(harness.begin(), drawer_id, f32, 0, drawer);
        _ = try harness.end();
        try testing.expect(value >= previous and value <= 0);
        previous = value;
        if (harness.ui.nextFrame() == .on_event) break;
    }
    try testing.expect(frames < 120);
    try testing.expectEqual(0, previous);
}

test "every easing maps 0 to 0 and 1 to 1 exactly" {
    for (std.enums.values(zui.motion.Easing)) |easing| {
        try testing.expectEqual(0, easing.apply(0));
        try testing.expectEqual(1, easing.apply(1));
    }
}

test "a token's motion is a value zui.motion takes as it is" {
    var tokens: zui.design.Tokens(support.Ui, void) = .{};
    tokens.motion.press = .{ .duration = 0.08, .easing = .ease_out };
    tokens.motion.press_scale = 0.97;
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = zui.motion.tween(harness.begin(), fade_id, f32, 1, tokens.motion.press);
    _ = try harness.end();
    const pressing = zui.motion.tween(harness.begin(), fade_id, f32, tokens.motion.press_scale, tokens.motion.press);
    _ = try harness.end();
    try testing.expectEqual(1, pressing);
    try testing.expectEqual(zui.NextFrame.immediately, harness.ui.nextFrame());
}

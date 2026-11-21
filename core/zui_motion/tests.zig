const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_motion = @import("zui_motion.zig");

const testing = std.testing;
const Ui = zui.Context(.{ .limits = .{ .max_elements = 16, .state_slots = 16 } });
const Driver = zui_testing.Driver(Ui);

const fade_id: zui.Id = .of("fade");
const frame_interval_ns = 50 * std.time.ns_per_ms;

fn Animated(comptime T: type, comptime animate: fn (*Ui, T) T) type {
    return struct {
        const Self = @This();

        target: T,
        value: T = undefined,

        fn declare(self: *Self, ui: *Ui) void {
            self.value = animate(ui, self.target);
        }
    };
}

fn linearFade(ui: *Ui, target: f32) f32 {
    return zui_motion.tween(ui, fade_id, f32, target, .{ .duration = 0.25, .easing = .linear });
}

fn delayedFade(ui: *Ui, target: f32) f32 {
    return zui_motion.tween(ui, fade_id, f32, target, .{ .duration = 0.25, .easing = .linear, .delay = 0.5 });
}

fn slowLinearFade(ui: *Ui, target: f32) f32 {
    return zui_motion.tween(ui, fade_id, f32, target, .{ .duration = 1, .easing = .linear });
}

fn colorFade(ui: *Ui, target: zui.Color) zui.Color {
    return zui_motion.tween(ui, fade_id, zui.Color, target, .{ .duration = 0.1, .easing = .linear });
}

const Card = struct { offset: [2]f32, background: zui.Color, glow: zui.ExtendedColor };

fn cardMove(ui: *Ui, target: Card) Card {
    return zui_motion.tween(ui, fade_id, Card, target, .{ .duration = 0.1, .easing = .linear });
}

fn drawerSpring(ui: *Ui, target: f32) f32 {
    return zui_motion.spring(ui, fade_id, f32, target, .{});
}

const Fixture = struct {
    ui: Ui = undefined,
    driver: Driver = undefined,

    fn init(fixture: *Fixture) !void {
        fixture.ui = try .init(testing.allocator, testing.io);
        fixture.driver = .{ .ui = &fixture.ui, .frame_interval_ns = frame_interval_ns };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.ui.deinit(testing.allocator);
    }

    fn frame(fixture: *Fixture, app: anytype) !void {
        _ = try fixture.driver.frame(app, @TypeOf(app.*).declare, &.{});
    }

    fn frameWith(fixture: *Fixture, app: anytype, events: []const zui.Event) !void {
        _ = try fixture.driver.frame(app, @TypeOf(app.*).declare, events);
    }
};

test "a tween starts where its first target is, without asking for frames" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Animated(f32, linearFade) = .{ .target = 1 };

    try fixture.frame(&app);
    try testing.expectEqual(1, app.value);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

test "a tween reaches its target at its duration, asking for every frame until then and none after" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Animated(f32, linearFade) = .{ .target = 0 };
    try fixture.frame(&app);

    app.target = 10;
    const expected = [_]f32{ 0, 2, 4, 6, 8 };
    for (expected) |value| {
        try fixture.frame(&app);
        try testing.expectApproxEqAbs(value, app.value, 1e-4);
        try testing.expectEqual(zui.NextFrame.immediately, fixture.ui.nextFrame());
    }
    for (0..3) |_| {
        try fixture.frame(&app);
        try testing.expectEqual(10, app.value);
        try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
    }
}

test "every easing maps 0 to 0 and 1 to 1 exactly" {
    for (std.enums.values(zui_motion.Easing)) |easing| {
        try testing.expectEqual(0, easing.apply(0));
        try testing.expectEqual(1, easing.apply(1));
        try testing.expectEqual(0, easing.apply(-1));
        try testing.expectEqual(1, easing.apply(2));
    }
    try testing.expectEqual(0.5, zui_motion.Easing.ease_in_out.apply(0.5));
    try testing.expect(zui_motion.Easing.ease_in.apply(0.5) < 0.5);
    try testing.expect(zui_motion.Easing.ease_out.apply(0.5) > 0.5);
}

test "under reduced motion a tween lands on a new target in the frame it changes" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Animated(f32, linearFade) = .{ .target = 0 };
    try fixture.frameWith(&app, &.{.{ .environment = .{ .reduced_motion = true } }});

    app.target = 10;
    try fixture.frame(&app);
    try testing.expectEqual(10, app.value);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

test "a tween moving when reduced motion turns on lands at once" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Animated(f32, linearFade) = .{ .target = 0 };
    try fixture.frame(&app);
    app.target = 10;
    try fixture.frame(&app);
    try fixture.frame(&app);
    try testing.expect(app.value < 10);

    try fixture.frameWith(&app, &.{.{ .environment = .{ .reduced_motion = true } }});
    try testing.expectEqual(10, app.value);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

test "retargeting a tween mid-flight starts from its current value" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Animated(f32, slowLinearFade) = .{ .target = 0 };
    try fixture.frame(&app);
    app.target = 100;
    for (0..5) |_| try fixture.frame(&app);
    try testing.expectApproxEqAbs(20, app.value, 1e-3);

    app.target = 0;
    try fixture.frame(&app);
    const where_the_old_tween_had_reached = 25;
    try testing.expectApproxEqAbs(where_the_old_tween_had_reached, app.value, 1e-3);
    for (0..25) |_| {
        const previous = app.value;
        try fixture.frame(&app);
        try testing.expect(app.value <= previous);
        try testing.expect(previous - app.value <= where_the_old_tween_had_reached * 0.05 + 1e-3);
    }
    try testing.expectEqual(0, app.value);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

test "a delayed tween holds its value and asks for a frame at the instant it starts" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Animated(f32, delayedFade) = .{ .target = 0 };
    try fixture.frame(&app);

    app.target = 10;
    try fixture.frame(&app);
    const starts_at = fixture.driver.now.addSeconds(0.5);
    try testing.expectEqual(0, app.value);
    try testing.expectEqual(zui.NextFrame{ .at = starts_at }, fixture.ui.nextFrame());

    fixture.driver.now = starts_at.addNanoseconds(100 * std.time.ns_per_ms - frame_interval_ns);
    try fixture.frame(&app);
    try testing.expectApproxEqAbs(4, app.value, 1e-4);
    try testing.expectEqual(zui.NextFrame.immediately, fixture.ui.nextFrame());
}

test "a full state table reports state_slots and the tween returns its target" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);

    for (0..2) |frame_number| {
        ui.beginFrame(&.{ .params = .{ .now = .fromNanoseconds(frame_number * frame_interval_ns), .viewport = .{ 100, 100 } } });
        for (0..16) |index| ui.state(.indexed("filler", index), u32).* = 1;
        const value = zui_motion.tween(&ui, fade_id, f32, @floatFromInt(frame_number), .{});
        const ended = ui.endFrame();
        defer ui.release(ended);
        try testing.expect(ended.diagnostics.exceeded.contains(.state_slots));
        try testing.expectEqual(@as(f32, @floatFromInt(frame_number)), value);
        try testing.expectEqual(zui.NextFrame.on_event, ui.nextFrame());
    }
}

test "a color is tweened per sRGB channel" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Animated(zui.Color, colorFade) = .{ .target = .black };
    try fixture.frame(&app);

    app.target = .white;
    try fixture.frame(&app);
    try fixture.frame(&app);
    try testing.expectEqual(zui.Color.black.mix(.white, 0.5), app.value);
    try fixture.frame(&app);
    try testing.expectEqual(zui.Color.white, app.value);
}

test "a struct of values is tweened field by field" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Animated(Card, cardMove) = .{ .target = .{ .offset = .{ 0, 40 }, .background = .black, .glow = .linear(0, 0, 0, 1) } };
    try fixture.frame(&app);

    app.target = .{ .offset = .{ 20, 0 }, .background = .white, .glow = .linear(4, 2, 0, 1) };
    try fixture.frame(&app);
    try fixture.frame(&app);
    try testing.expectEqual([2]f32{ 10, 20 }, app.value.offset);
    try testing.expectEqual(zui.Color.black.mix(.white, 0.5), app.value.background);
    try testing.expectEqual(2, app.value.glow.r);
    try testing.expectEqual(1, app.value.glow.g);
    try fixture.frame(&app);
    try testing.expectEqual(app.target, app.value);
}

test "a spring follows its target without overshooting, then comes to rest and stops asking for frames" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Animated(f32, drawerSpring) = .{ .target = -280 };
    try fixture.frame(&app);
    try testing.expectEqual(-280, app.value);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());

    app.target = 0;
    try fixture.frame(&app);
    try testing.expectEqual(-280, app.value);
    try testing.expectEqual(zui.NextFrame.immediately, fixture.ui.nextFrame());

    var previous = app.value;
    var frames: usize = 0;
    while (fixture.ui.nextFrame() == .immediately) : (frames += 1) {
        try testing.expect(frames < 100);
        try fixture.frame(&app);
        try testing.expect(app.value >= previous);
        try testing.expect(app.value <= 0);
        previous = app.value;
    }
    try testing.expectEqual(0, app.value);
    try fixture.frame(&app);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

test "under reduced motion a spring lands on a new target in the frame it changes" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Animated(f32, drawerSpring) = .{ .target = -280 };
    try fixture.frameWith(&app, &.{.{ .environment = .{ .reduced_motion = true } }});

    app.target = 0;
    try fixture.frame(&app);
    try testing.expectEqual(0, app.value);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

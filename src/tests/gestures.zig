//! Gestures are arbitrated against the previous frame's hit regions, so each
//! test declares a frame before the one whose input it checks.

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;
const Ui = support.Ui;
const Harness = support.Harness;

const list: zui.Id = .of("list");
const carousel: zui.Id = .of("carousel");
const button: zui.Id = .of("button");
const slider: zui.Id = .of("slider");
const map: zui.Id = .of("map");

fn fixed(width: f32, height: f32) zui.Layout {
    return .{ .sizing = .{ .width = .fixed(width), .height = .fixed(height) } };
}

/// A 200×300 list that scrolls vertically over 1,100 units of rows: a
/// carousel 100 tall at the top, scrolling horizontally over five 150-wide
/// cards, then a button and a slider 50 tall each, then filler.
fn feed(ui: *Ui) void {
    ui.open(.{ .id = list, .scroll = .{}, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(200), .height = .fixed(300) } } });
    ui.open(.{ .id = carousel, .scroll = .{ .horizontal = true, .vertical = false }, .layout = fixed(200, 100) });
    for (0..5) |_| ui.box(.{ .layout = fixed(150, 100) });
    ui.close();
    ui.box(.{ .id = button, .interactive = true, .layout = fixed(200, 50) });
    ui.box(.{ .id = slider, .gestures = .{ .pan = .horizontal }, .layout = fixed(200, 50) });
    for (0..9) |_| ui.box(.{ .layout = fixed(200, 100) });
    ui.close();
}

fn frame(harness: *Harness, events: []const zui.Event) !*Ui {
    const ui = harness.beginEvents(events);
    feed(ui);
    _ = try harness.end();
    return ui;
}

fn down(finger: u32, position: [2]f32) zui.Event {
    return .{ .pointer_down = .{ .pointer = support.touch(finger, position) } };
}

fn move(finger: u32, position: [2]f32) zui.Event {
    return .{ .pointer_move = .{ .pointer = support.touch(finger, position) } };
}

fn up(finger: u32, position: [2]f32) zui.Event {
    return .{ .pointer_up = .{ .pointer = support.touch(finger, position) } };
}

test "a vertical drag on a horizontal carousel scrolls the list it is in" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try frame(&harness, &.{});
    _ = try frame(&harness, &.{ down(1, .{ 100, 80 }), move(1, .{ 102, 60 }), move(1, .{ 103, 40 }) });
    var ui = try frame(&harness, &.{up(1, .{ 103, 40 })});
    try testing.expectEqual([2]f32{ 0, 40 }, ui.scrollOffset(list));
    try testing.expectEqual([2]f32{ 0, 0 }, ui.scrollOffset(carousel));

    _ = try frame(&harness, &.{ down(1, .{ 150, 50 }), move(1, .{ 120, 52 }), move(1, .{ 90, 53 }) });
    ui = try frame(&harness, &.{up(1, .{ 90, 53 })});
    try testing.expectEqual([2]f32{ 60, 0 }, ui.scrollOffset(carousel));
    try testing.expectEqual([2]f32{ 0, 40 }, ui.scrollOffset(list));
}

test "a pan reports what it moved, and the list scrolls in the frame of the move" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try frame(&harness, &.{});
    const ui = harness.beginEvents(&.{ down(1, .{ 100, 200 }), move(1, .{ 100, 170 }) });
    try testing.expectEqual(zui.Manipulation{ .translation = .{ 0, -30 } }, ui.manipulation(list).?);
    try testing.expectEqual([2]f32{ 0, 30 }, ui.scrollOffset(list));
    try testing.expectEqual(@as(?zui.Manipulation, null), ui.manipulation(carousel));
    feed(ui);
    _ = try harness.end();
}

test "a tap on a button in a list clicks it, and a drag scrolls the list instead" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try frame(&harness, &.{});
    var ui = try frame(&harness, &.{ down(1, .{ 100, 125 }), move(1, .{ 103, 128 }), up(1, .{ 103, 128 }) });
    try testing.expect(ui.clicked(button));

    ui = try frame(&harness, &.{ down(1, .{ 100, 125 }), move(1, .{ 100, 122 }) });
    try testing.expect(ui.pressed(button)); // within the slop, it could still be a tap
    ui = try frame(&harness, &.{move(1, .{ 100, 90 })});
    try testing.expect(!ui.pressed(button));
    try testing.expectEqual([2]f32{ 0, 35 }, ui.scrollOffset(list));
    ui = try frame(&harness, &.{up(1, .{ 100, 90 })});
    try testing.expect(!ui.clicked(button));
}

test "a slider in a drag-scrolled list keeps a horizontal drag and gives up a vertical one" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try frame(&harness, &.{});
    var ui = try frame(&harness, &.{ down(1, .{ 50, 175 }), move(1, .{ 80, 177 }) });
    try testing.expect(ui.pressed(slider));
    try testing.expectEqual(zui.Manipulation{ .translation = .{ 30, 0 } }, ui.manipulation(slider).?);
    ui = try frame(&harness, &.{move(1, .{ 90, 140 })});
    try testing.expect(ui.pressed(slider)); // the axis stays locked
    try testing.expectEqual(zui.Manipulation{ .translation = .{ 10, 0 } }, ui.manipulation(slider).?);
    try testing.expectEqual([2]f32{ 0, 0 }, ui.scrollOffset(list));
    ui = try frame(&harness, &.{up(1, .{ 90, 140 })});
    try testing.expect(!ui.clicked(slider)); // a pan is not a tap

    ui = try frame(&harness, &.{ down(1, .{ 50, 175 }), move(1, .{ 52, 150 }) });
    try testing.expect(!ui.pressed(slider));
    try testing.expectEqual(@as(?zui.Manipulation, null), ui.manipulation(slider));
    try testing.expectEqual([2]f32{ 0, 25 }, ui.scrollOffset(list));
    _ = try frame(&harness, &.{up(1, .{ 52, 150 })});
}

test "a drag toward a list's end it has reached goes to the list around it" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try frame(&harness, &.{});
    harness.ui.setScrollOffset(carousel, .{ 530, 0 });
    _ = try frame(&harness, &.{});
    var ui = try frame(&harness, &.{ down(1, .{ 100, 50 }), move(1, .{ 60, 50 }) });
    try testing.expectEqual([2]f32{ 550, 0 }, ui.scrollOffset(carousel)); // clamped to its end
    ui = try frame(&harness, &.{up(1, .{ 60, 50 })});

    // Left would move the carousel past its end; the list does not pan
    // horizontally, so nothing takes the pointer.
    ui = try frame(&harness, &.{ down(1, .{ 100, 50 }), move(1, .{ 60, 50 }) });
    try testing.expectEqual([2]f32{ 550, 0 }, ui.scrollOffset(carousel));
    try testing.expectEqual(@as(?zui.Manipulation, null), ui.manipulation(carousel));
    _ = try frame(&harness, &.{up(1, .{ 60, 50 })});

    // Down would move the list before its start.
    ui = try frame(&harness, &.{ down(1, .{ 100, 200 }), move(1, .{ 100, 260 }) });
    try testing.expectEqual(@as(?zui.Manipulation, null), ui.manipulation(list));
    _ = try frame(&harness, &.{up(1, .{ 100, 260 })});
}

test "the mouse scrolls a list with the wheel, not by dragging" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try frame(&harness, &.{});
    const at: [2]f32 = .{ 100, 200 };
    var ui = try frame(&harness, &.{
        .{ .pointer_move = .{ .pointer = support.mouse(at) } },
        .{ .pointer_down = .{ .pointer = support.mouse(at) } },
        .{ .pointer_move = .{ .pointer = support.mouse(.{ 100, 150 }) } },
        .{ .pointer_up = .{ .pointer = support.mouse(.{ 100, 150 }) } },
    });
    try testing.expectEqual([2]f32{ 0, 0 }, ui.scrollOffset(list));

    ui = try frame(&harness, &.{.{ .wheel = .{ .position = at, .delta = .{ 0, 40 }, .at = .zero } }});
    try testing.expectEqual([2]f32{ 0, 40 }, ui.scrollOffset(list));
    try testing.expectEqual(zui.Manipulation{ .translation = .{ 0, -40 } }, ui.manipulation(list).?);
}

/// A 400×300 map that pans on both axes, with a pin button on it.
fn mapView(ui: *Ui) void {
    ui.open(.{ .id = map, .gestures = .{ .pan = .both }, .layout = fixed(400, 300) });
    ui.box(.{ .id = button, .interactive = true, .layout = fixed(40, 40) });
    ui.close();
}

fn mapFrame(harness: *Harness, events: []const zui.Event) !*Ui {
    const ui = harness.beginEvents(events);
    mapView(ui);
    _ = try harness.end();
    return ui;
}

test "an element that pans on both axes follows the pointer freely, the wheel too" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try mapFrame(&harness, &.{});
    const start: [2]f32 = .{ 200, 150 };
    var ui = try mapFrame(&harness, &.{
        .{ .pointer_move = .{ .pointer = support.mouse(start) } },
        .{ .pointer_down = .{ .pointer = support.mouse(start) } },
        .{ .pointer_move = .{ .pointer = support.mouse(.{ 210, 160 }) } },
        .{ .pointer_move = .{ .pointer = support.mouse(.{ 230, 140 }) } },
    });
    try testing.expectEqual(zui.Manipulation{ .translation = .{ 30, -10 } }, ui.manipulation(map).?);
    try testing.expect(ui.pressed(map));
    try testing.expect(ui.hovered(map));
    ui = try mapFrame(&harness, &.{.{ .pointer_up = .{ .pointer = support.mouse(.{ 230, 140 }) } }});
    try testing.expect(!ui.clicked(map));

    ui = try mapFrame(&harness, &.{.{ .wheel = .{ .position = start, .delta = .{ 5, 20 }, .at = .zero } }});
    try testing.expectEqual(zui.Manipulation{ .translation = .{ -5, -20 } }, ui.manipulation(map).?);
}

test "a press on a button on a map clicks it within the slop, and pans the map past it" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try mapFrame(&harness, &.{});
    var ui = try mapFrame(&harness, &.{ down(1, .{ 20, 20 }), move(1, .{ 24, 23 }), up(1, .{ 24, 23 }) });
    try testing.expect(ui.clicked(button));
    try testing.expect(!ui.clicked(map));

    ui = try mapFrame(&harness, &.{ down(1, .{ 20, 20 }), move(1, .{ 60, 20 }), up(1, .{ 60, 20 }) });
    try testing.expect(!ui.clicked(button));
    try testing.expectEqual(zui.Manipulation{ .translation = .{ 40, 0 } }, ui.manipulation(map).?);
}

test "without the feature, gestures are ignored and a touch drag scrolls nothing" {
    const PlainUi = zui.Context(.{ .features = .{ .gestures = false } });
    var ui = try PlainUi.init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);

    var now: zui.Instant = .zero;
    for (0..3) |frame_number| {
        now = now.addNanoseconds(support.frame_interval_ns);
        const events: []const zui.Event = if (frame_number == 1) &.{ down(1, .{ 100, 200 }), move(1, .{ 100, 150 }) } else &.{};
        ui.beginFrame(&.{ .params = .{ .now = now, .viewport = .{ 800, 600 } }, .events = events });
        ui.open(.{ .id = list, .scroll = .{}, .gestures = .{ .pan = .both }, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(200), .height = .fixed(300) } } });
        ui.box(.{ .layout = fixed(200, 1000) });
        ui.close();
        if (frame_number == 2) {
            try testing.expectEqual([2]f32{ 0, 0 }, ui.scrollOffset(list));
            try testing.expect(!ui.hovered(list));
        }
        ui.release(ui.endFrame());
    }
    try testing.expectEqual(0, @sizeOf(@FieldType(PlainUi.Frame, "gestures")));
}

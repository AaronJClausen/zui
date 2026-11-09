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

const atlas: zui.Id = .of("atlas");
const places: zui.Id = .of("places");
const place: zui.Id = .of("place");

/// A 400×400 map that pans and zooms, with a list of places 200×200 at
/// (100, 100) that scrolls over 600 units and starts with a 50-tall button.
fn atlasView(ui: *Ui) void {
    ui.open(.{ .id = atlas, .gestures = .{ .pan = .both, .zoom = true }, .layout = .{ .sizing = .{ .width = .fixed(400), .height = .fixed(400) }, .padding = .all(100) } });
    ui.open(.{ .id = places, .scroll = .{}, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(200), .height = .fixed(200) } } });
    ui.box(.{ .id = place, .interactive = true, .layout = fixed(200, 50) });
    ui.box(.{ .layout = fixed(200, 550) });
    ui.close();
    ui.close();
}

fn atlasFrame(harness: *Harness, events: []const zui.Event) !*Ui {
    const ui = harness.beginEvents(events);
    atlasView(ui);
    _ = try harness.end();
    return ui;
}

fn expectManipulation(expected: zui.Manipulation, actual: ?zui.Manipulation) !void {
    const moved = actual orelse return error.NotManipulated;
    const tolerance = 1e-4;
    try testing.expectApproxEqAbs(expected.translation[0], moved.translation[0], tolerance);
    try testing.expectApproxEqAbs(expected.translation[1], moved.translation[1], tolerance);
    try testing.expectApproxEqAbs(expected.scale, moved.scale, tolerance);
    try testing.expectApproxEqAbs(expected.rotation, moved.rotation, tolerance);
    try testing.expectApproxEqAbs(expected.pivot[0], moved.pivot[0], tolerance);
    try testing.expectApproxEqAbs(expected.pivot[1], moved.pivot[1], tolerance);
}

test "a button in a list in a zoomable map: a tap clicks it, and each motion goes to its own element" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try atlasFrame(&harness, &.{});
    var ui = try atlasFrame(&harness, &.{ down(1, .{ 150, 125 }), up(1, .{ 150, 125 }) });
    try testing.expect(ui.clicked(place));

    ui = try atlasFrame(&harness, &.{ down(1, .{ 150, 140 }), move(1, .{ 150, 100 }), up(1, .{ 150, 100 }) });
    try testing.expectEqual([2]f32{ 0, 40 }, ui.scrollOffset(places));
    try testing.expectEqual(@as(?zui.Manipulation, null), ui.manipulation(atlas));
    try testing.expect(!ui.clicked(place));

    ui = try atlasFrame(&harness, &.{ down(1, .{ 150, 140 }), move(1, .{ 190, 150 }), up(1, .{ 190, 150 }) });
    try expectManipulation(.{ .translation = .{ 40, 10 } }, ui.manipulation(atlas));
    try testing.expectEqual([2]f32{ 0, 40 }, ui.scrollOffset(places));

    ui = try atlasFrame(&harness, &.{ down(1, .{ 120, 125 }), down(2, .{ 180, 125 }) });
    try testing.expect(!ui.pressed(place));
    ui = try atlasFrame(&harness, &.{ move(1, .{ 100, 125 }), move(2, .{ 200, 125 }) });
    try expectManipulation(.{ .translation = .{ 0, 0 }, .scale = 100.0 / 60.0, .pivot = .{ 150, 125 } }, ui.manipulation(atlas));
    try testing.expectEqual(@as(?zui.Manipulation, null), ui.manipulation(places));
    ui = try atlasFrame(&harness, &.{ up(1, .{ 100, 125 }), up(2, .{ 200, 125 }) });
    try testing.expect(!ui.clicked(place));
    try testing.expect(!ui.clicked(atlas));
    try testing.expectEqual([2]f32{ 0, 40 }, ui.scrollOffset(places));
}

test "a pinch that starts on a list goes to the map around it" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try atlasFrame(&harness, &.{});
    var ui = try atlasFrame(&harness, &.{ down(1, .{ 150, 200 }), move(1, .{ 150, 170 }) });
    try testing.expectEqual([2]f32{ 0, 30 }, ui.scrollOffset(places)); // one finger scrolls the list
    ui = try atlasFrame(&harness, &.{ down(2, .{ 150, 260 }), move(1, .{ 150, 150 }), move(2, .{ 150, 280 }) });
    try testing.expectEqual([2]f32{ 0, 30 }, ui.scrollOffset(places));
    try expectManipulation(.{ .translation = .{ 0, 0 }, .scale = 130.0 / 90.0, .pivot = .{ 150, 215 } }, ui.manipulation(atlas));

    // Lifting one finger leaves the other panning the map.
    ui = try atlasFrame(&harness, &.{ up(1, .{ 150, 150 }), move(2, .{ 170, 290 }) });
    try expectManipulation(.{ .translation = .{ 20, 10 } }, ui.manipulation(atlas));
    try testing.expectEqual([2]f32{ 0, 30 }, ui.scrollOffset(places));
    _ = try atlasFrame(&harness, &.{up(2, .{ 170, 290 })});
}

test "two pointers turning about each other rotate the map clockwise" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try atlasFrame(&harness, &.{});
    _ = try atlasFrame(&harness, &.{ down(1, .{ 120, 200 }), down(2, .{ 180, 200 }) });
    const ui = try atlasFrame(&harness, &.{ move(1, .{ 150, 170 }), move(2, .{ 150, 230 }) });
    try expectManipulation(.{ .translation = .{ 0, 0 }, .rotation = std.math.pi / 2.0, .pivot = .{ 150, 200 } }, ui.manipulation(atlas));
    _ = try atlasFrame(&harness, &.{ up(1, .{ 150, 170 }), up(2, .{ 150, 230 }) });
}

test "two pointers on an element that does not zoom each do what one would" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try frame(&harness, &.{});
    var ui = try frame(&harness, &.{ down(1, .{ 150, 50 }), down(2, .{ 100, 250 }), move(1, .{ 110, 50 }), move(2, .{ 100, 220 }) });
    try testing.expectEqual([2]f32{ 40, 0 }, ui.scrollOffset(carousel));
    try testing.expectEqual([2]f32{ 0, 30 }, ui.scrollOffset(list));
    ui = try frame(&harness, &.{ up(1, .{ 110, 50 }), up(2, .{ 100, 220 }) });
}

const single: zui.Id = .of("single");
const double: zui.Id = .of("double");
const held: zui.Id = .of("held");
const dialog: zui.Id = .of("dialog");

/// `single` at (0, 0) and `double`, which accepts double taps, at
/// (100, 0), both 100×40; `held`, which accepts a long press, 200×50 at
/// (0, 40); all three in a dialog's focus scope.
fn photoActions(ui: *Ui) void {
    ui.open(.{ .id = dialog, .focus_scope = true, .layout = .{ .direction = .top_to_bottom } });
    ui.open(.{});
    ui.box(.{ .id = single, .focusable = true, .layout = fixed(100, 40) });
    ui.box(.{ .id = double, .focusable = true, .gestures = .{ .double_tap = true }, .layout = fixed(100, 40) });
    ui.close();
    ui.box(.{ .id = held, .gestures = .{ .long_press = true }, .layout = fixed(200, 50) });
    ui.close();
}

fn actionsFrame(harness: *Harness, events: []const zui.Event) !*Ui {
    const ui = harness.beginEvents(events);
    photoActions(ui);
    _ = try harness.end();
    return ui;
}

/// A finger at `position` when the harness's last frame began.
fn fingerNow(harness: *const Harness, position: [2]f32) zui.Pointer {
    return .{ .id = @enumFromInt(1), .kind = .touch, .position = position, .at = harness.now };
}

fn tapAt(harness: *const Harness, position: [2]f32) [2]zui.Event {
    return .{ .{ .pointer_down = .{ .pointer = fingerNow(harness, position) } }, .{ .pointer_up = .{ .pointer = fingerNow(harness, position) } } };
}

test "a press held still asks for the context menu once it is due, and is not a tap" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try actionsFrame(&harness, &.{});
    const pressed_at = harness.now;
    var ui = try actionsFrame(&harness, &.{.{ .pointer_down = .{ .pointer = fingerNow(&harness, .{ 50, 60 }) } }});
    const due = pressed_at.addSeconds(zui.Gestures.long_press_seconds);
    try testing.expectEqual(zui.NextFrame{ .at = due }, ui.nextFrame());

    var requests: u32 = 0;
    while (harness.now.isBefore(due.addSeconds(0.1))) {
        ui = try actionsFrame(&harness, &.{});
        if (ui.contextRequested(held)) {
            requests += 1;
            try testing.expect(!harness.now.isBefore(due));
        }
    }
    try testing.expectEqual(@as(u32, 1), requests);
    ui = try actionsFrame(&harness, &.{.{ .pointer_up = .{ .pointer = fingerNow(&harness, .{ 50, 60 }) } }});
    try testing.expect(!ui.clicked(held));
    try testing.expectEqual(zui.NextFrame.on_event, ui.nextFrame());
}

test "a long press released in the frame it falls due still asks for the menu, and a short one taps" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try actionsFrame(&harness, &.{});
    var down_pointer = fingerNow(&harness, .{ 50, 60 });
    var up_pointer = down_pointer;
    up_pointer.at = down_pointer.at.addSeconds(0.6);
    var ui = try actionsFrame(&harness, &.{ .{ .pointer_down = .{ .pointer = down_pointer } }, .{ .pointer_up = .{ .pointer = up_pointer } } });
    try testing.expect(ui.contextRequested(held));
    try testing.expect(!ui.clicked(held));

    ui = try actionsFrame(&harness, &tapAt(&harness, .{ 50, 60 }));
    try testing.expect(ui.clicked(held));
    try testing.expect(!ui.contextRequested(held));

    // Moving past the slop is not holding still.
    down_pointer = fingerNow(&harness, .{ 50, 60 });
    ui = try actionsFrame(&harness, &.{ .{ .pointer_down = .{ .pointer = down_pointer } }, .{ .pointer_move = .{ .pointer = fingerNow(&harness, .{ 80, 60 }) } } });
    try testing.expectEqual(zui.NextFrame.on_event, ui.nextFrame());
    harness.now = harness.now.addSeconds(1);
    ui = try actionsFrame(&harness, &.{.{ .pointer_up = .{ .pointer = fingerNow(&harness, .{ 80, 60 }) } }});
    try testing.expect(!ui.contextRequested(held));
}

test "a double tap next to a single tap: one clicks at once, the other waits for a second tap" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try actionsFrame(&harness, &.{});
    var ui = try actionsFrame(&harness, &tapAt(&harness, .{ 50, 20 }));
    try testing.expect(ui.clicked(single));
    try testing.expectEqual(zui.NextFrame.on_event, ui.nextFrame());

    const tapped_at = harness.now;
    ui = try actionsFrame(&harness, &tapAt(&harness, .{ 150, 20 }));
    try testing.expect(!ui.clicked(double));
    const due = tapped_at.addSeconds(zui.Gestures.double_tap_seconds);
    try testing.expectEqual(zui.NextFrame{ .at = due }, ui.nextFrame());
    var clicks: u32 = 0;
    while (harness.now.isBefore(due.addSeconds(0.1))) {
        ui = try actionsFrame(&harness, &.{});
        if (ui.clicked(double)) clicks += 1;
        try testing.expect(!ui.doubleTapped(double));
    }
    try testing.expectEqual(@as(u32, 1), clicks);

    ui = try actionsFrame(&harness, &tapAt(&harness, .{ 150, 20 }));
    ui = try actionsFrame(&harness, &tapAt(&harness, .{ 152, 22 }));
    try testing.expect(ui.doubleTapped(double));
    try testing.expect(!ui.clicked(double));
    try testing.expectEqual(zui.NextFrame.on_event, ui.nextFrame());
    for (0..30) |_| {
        ui = try actionsFrame(&harness, &.{});
        try testing.expect(!ui.clicked(double));
        try testing.expect(!ui.doubleTapped(double));
    }

    // A second tap after the window is a click of its own, late.
    ui = try actionsFrame(&harness, &tapAt(&harness, .{ 150, 20 }));
    harness.now = harness.now.addSeconds(0.5);
    ui = try actionsFrame(&harness, &tapAt(&harness, .{ 150, 20 }));
    try testing.expect(ui.clicked(double));
    try testing.expect(!ui.doubleTapped(double));
}

test "a right click and the menu key ask for the context menu; Escape dismisses; arrows adjust and navigate" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try actionsFrame(&harness, &.{});
    const at = support.mouse(.{ 50, 20 });
    var ui = try actionsFrame(&harness, &.{
        .{ .pointer_move = .{ .pointer = at } },
        .{ .pointer_down = .{ .pointer = at, .button = .secondary } },
        .{ .pointer_up = .{ .pointer = at, .button = .secondary } },
    });
    try testing.expect(ui.contextRequested(single));
    try testing.expect(!ui.clicked(single));

    harness.ui.requestFocus(single);
    ui = try actionsFrame(&harness, &.{});
    try testing.expect(!ui.contextRequested(single));
    const key = struct {
        fn down(pressed: zui.Key) zui.Event {
            return .{ .key_down = .{ .key = pressed, .at = .zero } };
        }
    }.down;
    ui = try actionsFrame(&harness, &.{key(.menu)});
    try testing.expect(ui.contextRequested(single));

    ui = try actionsFrame(&harness, &.{ key(.right), key(.right), key(.left), key(.down) });
    try testing.expectEqual(@as(?i32, 0), ui.adjusted(single));
    try testing.expectEqual(@as(?zui.NavigationDirection, .down), ui.navigated(single));
    try testing.expectEqual(@as(?i32, null), ui.adjusted(double));
    ui = try actionsFrame(&harness, &.{key(.up)});
    try testing.expectEqual(@as(?i32, 1), ui.adjusted(single));
    ui = try actionsFrame(&harness, &.{key(.enter)});
    try testing.expectEqual(@as(?i32, null), ui.adjusted(single));
    try testing.expectEqual(@as(?zui.NavigationDirection, null), ui.navigated(single));

    ui = try actionsFrame(&harness, &.{key(.escape)});
    try testing.expect(ui.dismissed(single));
    try testing.expect(ui.dismissed(dialog));
    try testing.expect(!ui.dismissed(double));
}

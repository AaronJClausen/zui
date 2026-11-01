//! Interaction queries answer for the previous frame (SPEC.md §5), so each
//! test declares a frame, then begins the next one with the input under test.

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;
const Ui = support.Ui;
const Harness = support.Harness;

const a: zui.Id = .of("a");
const b: zui.Id = .of("b");

const ButtonOptions = struct { disabled_a: bool = false, focusable: bool = true };

/// Two 100×40 buttons side by side: `a` at (0,0) and `b` at (100,0).
fn buttons(ui: *Ui, options: ButtonOptions) void {
    ui.open(.{});
    ui.box(.{ .id = a, .interactive = true, .focusable = options.focusable, .disabled = options.disabled_a, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
    ui.box(.{ .id = b, .interactive = true, .focusable = options.focusable, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
    ui.close();
}

fn step(harness: *Harness, input: support.InputWithoutViewport, options: ButtonOptions) !*Ui {
    const ui = harness.beginWith(input);
    buttons(ui, options);
    return ui;
}

fn finish(harness: *Harness) !void {
    _ = try harness.end();
}

test "hover follows the pointer, one frame late" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    var ui = try step(&harness, .{ .pointer = .{ 10, 10 } }, .{});
    try testing.expect(!ui.hovered(a)); // nothing was on screen yet
    try finish(&harness);

    ui = try step(&harness, .{ .pointer = .{ 10, 10 } }, .{});
    try testing.expect(ui.hovered(a));
    try testing.expect(!ui.hovered(b));
    try finish(&harness);

    ui = try step(&harness, .{ .pointer = .{ 150, 10 } }, .{});
    try testing.expect(!ui.hovered(a));
    try testing.expect(ui.hovered(b));
    try finish(&harness);

    ui = try step(&harness, .{ .pointer = null }, .{});
    try testing.expect(!ui.hovered(b));
    try finish(&harness);
}

test "a click is a press and a release on the same element" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try step(&harness, .{}, .{});
    try finish(&harness);

    var ui = try step(&harness, .{ .pointer = .{ 10, 10 }, .buttons = support.primaryDown() }, .{});
    try testing.expect(ui.pressed(a));
    try testing.expect(!ui.clicked(a));
    try testing.expectEqual(zui.WidgetState.pressed, ui.widgetState(a));
    try finish(&harness);

    ui = try step(&harness, .{ .pointer = .{ 10, 10 } }, .{});
    try testing.expect(ui.clicked(a));
    try testing.expect(!ui.pressed(a));
    try finish(&harness);

    ui = try step(&harness, .{ .pointer = .{ 10, 10 } }, .{});
    try testing.expect(!ui.clicked(a)); // a click lasts one frame
    try finish(&harness);
}

test "releasing over a different element is not a click" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try step(&harness, .{}, .{});
    try finish(&harness);
    _ = try step(&harness, .{ .pointer = .{ 10, 10 }, .buttons = support.primaryDown() }, .{});
    try finish(&harness);

    var ui = try step(&harness, .{ .pointer = .{ 150, 10 }, .buttons = support.primaryDown() }, .{});
    try testing.expect(ui.pressed(a)); // the press stays with where it began
    try testing.expect(ui.hovered(b));
    try finish(&harness);

    ui = try step(&harness, .{ .pointer = .{ 150, 10 } }, .{});
    try testing.expect(!ui.clicked(a));
    try testing.expect(!ui.clicked(b));
    try finish(&harness);
}

test "disabled elements report their state and are never pressed or clicked" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    const options: ButtonOptions = .{ .disabled_a = true };
    _ = try step(&harness, .{}, options);
    try finish(&harness);
    var ui = try step(&harness, .{ .pointer = .{ 10, 10 }, .buttons = support.primaryDown() }, options);
    try testing.expectEqual(zui.WidgetState.disabled, ui.widgetState(a));
    try testing.expect(!ui.pressed(a));
    try finish(&harness);
    ui = try step(&harness, .{ .pointer = .{ 10, 10 } }, options);
    try testing.expect(!ui.clicked(a));
    try testing.expect(!ui.focused(a));
    try finish(&harness);
}

test "hover covers interactive ancestors; the click goes to the innermost" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    const card: zui.Id = .of("card");
    const inner: zui.Id = .of("inner_button");
    for (0..4) |frame_number| {
        const input: support.InputWithoutViewport = switch (frame_number) {
            0, 1 => .{ .pointer = .{ 20, 20 } },
            2 => .{ .pointer = .{ 20, 20 }, .buttons = support.primaryDown() },
            else => .{ .pointer = .{ 20, 20 } },
        };
        const ui = harness.beginWith(input);
        if (frame_number == 1) {
            try testing.expect(ui.hovered(card));
            try testing.expect(ui.hovered(inner));
        }
        if (frame_number == 3) {
            try testing.expect(ui.clicked(inner));
            try testing.expect(!ui.clicked(card));
        }
        ui.open(.{ .id = card, .interactive = true, .layout = .{ .padding = .all(10) } });
        ui.box(.{ .id = inner, .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(50), .height = .fixed(20) } } });
        ui.close();
        try finish(&harness);
    }
}

test "a floating element blocks the pointer from what it covers" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    for (0..3) |frame_number| {
        const pointer: [2]f32 = if (frame_number == 1) .{ 10, 10 } else .{ 80, 10 };
        const ui = harness.beginWith(.{ .pointer = pointer });
        if (frame_number == 1) try testing.expect(!ui.hovered(a));
        if (frame_number == 2) try testing.expect(ui.hovered(a));
        buttons(ui, .{});
        ui.box(.{ .floating = .{ .attach_to = .root }, .layout = .{ .sizing = .{ .width = .fixed(50), .height = .fixed(50) } } });
        try finish(&harness);
    }
}

test "a floating descendant covers its siblings but keeps its ancestor hovered" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    // A tooltip owned by `a` spans x 80..140: over `a` until 100, over `b` after.
    const pointers = [_][2]f32{ .{ 0, 0 }, .{ 120, 10 }, .{ 90, 10 } };
    for (pointers, 0..) |pointer, frame_number| {
        const ui = harness.beginWith(.{ .pointer = pointer });
        if (frame_number == 1) {
            try testing.expect(!ui.hovered(b)); // covered by the tooltip
            try testing.expect(!ui.hovered(a)); // the pointer is outside `a`
        }
        if (frame_number == 2) {
            try testing.expect(ui.hovered(a)); // inside `a`, through its own tooltip
            try testing.expect(!ui.hovered(b));
        }
        ui.open(.{});
        ui.open(.{ .id = a, .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(60), .height = .fixed(30) } }, .floating = .{ .offset = .{ 80, 0 } } });
        ui.close();
        ui.box(.{ .id = b, .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
        ui.close();
        try finish(&harness);
    }
}

test "clicking focuses a focusable element, and clicking elsewhere blurs it" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try step(&harness, .{}, .{});
    try finish(&harness);
    var ui = try step(&harness, .{ .pointer = .{ 10, 10 }, .buttons = support.primaryDown() }, .{});
    try testing.expect(ui.focused(a));
    try finish(&harness);
    _ = try step(&harness, .{ .pointer = .{ 10, 10 } }, .{});
    try finish(&harness);
    ui = try step(&harness, .{ .pointer = .{ 500, 500 }, .buttons = support.primaryDown() }, .{});
    try testing.expect(!ui.focused(a));
    try finish(&harness);
}

test "tab and shift-tab move focus in declaration order, wrapping" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try step(&harness, .{}, .{});
    try finish(&harness);
    const tab = [_]zui.Key{.tab};
    const expected = [_]zui.Id{ a, b, a };
    for (expected) |expected_focus| {
        const ui = try step(&harness, .{ .keys_pressed = &tab }, .{});
        try testing.expect(ui.focused(expected_focus));
        try finish(&harness);
    }
    const ui = try step(&harness, .{ .keys_pressed = &tab, .modifiers = .{ .shift = true } }, .{});
    try testing.expect(ui.focused(b));
    try finish(&harness);
}

test "a focus scope keeps tab inside it" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ok: zui.Id = .of("dialog_ok");
    const cancel: zui.Id = .of("dialog_cancel");
    const tab = [_]zui.Key{.tab};
    var focus_sequence: [4]u64 = undefined;
    for (0..5) |frame_number| {
        const ui = harness.beginWith(.{ .keys_pressed = if (frame_number == 0) &.{} else &tab });
        if (frame_number == 0) ui.requestFocus(ok);
        buttons(ui, .{});
        ui.open(.{ .focus_scope = true, .floating = .{ .attach_to = .root } });
        ui.box(.{ .id = ok, .focusable = true, .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
        ui.box(.{ .id = cancel, .focusable = true, .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
        ui.close();
        if (frame_number > 0) focus_sequence[frame_number - 1] = if (ui.focused(ok)) ok.hash else if (ui.focused(cancel)) cancel.hash else 0;
        try finish(&harness);
    }
    // Frame 1 applies the requested focus and then tabs once.
    try testing.expectEqual([4]u64{ cancel.hash, ok.hash, cancel.hash, ok.hash }, focus_sequence);
}

test "enter or space on the focused element counts as a click" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    var ui = try step(&harness, .{}, .{});
    ui.requestFocus(b);
    try finish(&harness);
    ui = try step(&harness, .{}, .{});
    try testing.expect(ui.focused(b));
    try testing.expectEqual(zui.WidgetState.focused, ui.widgetState(b));
    try finish(&harness);
    for ([_]zui.Key{ .enter, .space }) |key| {
        ui = try step(&harness, .{ .keys_pressed = &.{key} }, .{});
        try testing.expect(ui.clicked(b));
        try finish(&harness);
    }
}

test "focus is dropped when its element disappears" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    var ui = try step(&harness, .{}, .{});
    ui.requestFocus(a);
    try finish(&harness);
    ui = harness.beginWith(.{});
    try testing.expect(ui.focused(a));
    try finish(&harness);
    ui = try step(&harness, .{}, .{});
    try testing.expect(!ui.focused(a));
    try finish(&harness);
}

test "rectOf and pointerLocal describe the previous frame" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = try step(&harness, .{}, .{});
    try finish(&harness);
    const ui = try step(&harness, .{ .pointer = .{ 130, 25 } }, .{});
    try testing.expectEqual(zui.Rect{ .x = 100, .y = 0, .width = 100, .height = 40 }, ui.rectOf(b).?);
    try testing.expectEqual([2]f32{ 30, 25 }, ui.pointerLocal(b).?);
    try testing.expectEqual(@as(?zui.Rect, null), ui.rectOf(.of("never_declared")));
    try finish(&harness);
}

test "key presses and typed text are copied for the frame" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    var typed = "hi".*;
    const ui = harness.beginWith(.{ .keys_pressed = &.{ .escape, .left }, .text_input = &typed, .modifiers = .{ .control = true } });
    typed = "xx".*;
    try testing.expect(ui.keyPressed(.escape));
    try testing.expect(!ui.keyPressed(.tab));
    try testing.expectEqualStrings("hi", ui.typedText());
    try testing.expect(ui.modifiers().control);
    try finish(&harness);
}

test "state persists while used and is evicted after its time to live" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();

    const Expanded = struct { open: bool };
    var ui = harness.begin();
    ui.state(.of("panel"), Expanded).open = true;
    try finish(&harness);

    ui = harness.begin();
    try testing.expect(ui.state(.of("panel"), Expanded).open);
    try finish(&harness);

    for (0..3) |_| {
        _ = harness.begin();
        try finish(&harness);
    }
    ui = harness.begin();
    try testing.expectEqual(@as(?*Expanded, null), ui.stateIfPresent(.of("panel"), Expanded));
    try finish(&harness);
}

test "a full state table hands out scratch memory and reports it" {
    const SmallStateUi = zui.Context(.{ .max_elements = 16, .state_slots = 2 }, support.TestPlatform);
    var platform: support.TestPlatform = .{};
    var ui = try SmallStateUi.init(testing.allocator, testing.io, &platform);
    defer ui.deinit(testing.allocator);

    const Counter = struct { count: u32 };
    ui.beginFrame(.{ .viewport = .{ 10, 10 } });
    ui.state(.of("one"), Counter).count = 1;
    ui.state(.of("two"), Counter).count = 2;
    ui.state(.of("three"), Counter).count = 3;
    try testing.expectError(error.CapacityExceeded, ui.endFrame());
    ui.release(ui.lastFrame());
    try testing.expect(ui.diagnostics().exceeded.contains(.state_slots));
    try testing.expectEqualStrings("state_slots", zui.Limit.state_slots.configField());
}

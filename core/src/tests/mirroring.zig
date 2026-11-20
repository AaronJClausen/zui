//! Right-to-left layout. Each mirrored layout is checked against the same
//! scene laid out left to right, reflected across the box it mirrors in,
//! and a few against hand-computed positions. The viewport is 800 wide.

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const expectRect = support.expectRect;
const testing = std.testing;

const right_to_left_environment = [_]zui.Event{.{ .environment = .{ .direction = .right_to_left } }};
const left_to_right_environment = [_]zui.Event{.{ .environment = .{ .direction = .left_to_right } }};

/// How a scene is mirrored: not at all, by the environment, by an
/// ancestor's `mirrored`, or by the parent's own `right_to_left`.
const Mode = enum { none, environment, mirrored_ancestor, right_to_left_parent };

fn beginIn(harness: *support.Harness, mode: Mode) *support.Ui {
    return harness.beginEvents(if (mode == .environment) &right_to_left_environment else &left_to_right_environment);
}

fn fixed(width: f32, height: f32) zui.Sizing2 {
    return .{ .width = .fixed(width), .height = .fixed(height) };
}

fn openOuter(ui: *support.Ui, mode: Mode) void {
    ui.open(.{ .id = .of("outer"), .layout = .{
        .sizing = .{ .width = .grow, .height = .fixed(300) },
        .padding = .{ .left = 40, .top = 20 },
        .mirrored = if (mode == .mirrored_ancestor) .yes else .inherit,
    } });
}

fn rowDirection(mode: Mode) zui.Direction {
    return if (mode == .right_to_left_parent) .right_to_left else .left_to_right;
}

const child_ids = [_]zui.Id{ .of("a"), .of("b"), .of("c") };
const child_sizes = [_][2]f32{ .{ 50, 20 }, .{ 30, 40 }, .{ 20, 10 } };

fn alignmentScene(harness: *support.Harness, mode: Mode, column: bool, alignment: zui.Alignment2) !*const support.Ui.Frame {
    const ui = beginIn(harness, mode);
    openOuter(ui, mode);
    ui.open(.{ .id = .of("parent"), .layout = .{
        .direction = if (column) .top_to_bottom else rowDirection(mode),
        .sizing = fixed(300, 200),
        .padding = .{ .left = 10, .right = 30, .top = 5, .bottom = 7 },
        .child_gap = 4,
        .child_alignment = alignment,
    } });
    for (child_ids, child_sizes) |id, size| ui.box(.{ .id = id, .layout = .{ .sizing = fixed(size[0], size[1]) } });
    ui.close();
    ui.close();
    return harness.end();
}

fn reflected(rect: zui.Rect, across: zui.Rect) zui.Rect {
    return .{ .x = 2 * across.x + across.width - rect.x - rect.width, .y = rect.y, .width = rect.width, .height = rect.height };
}

const viewport: zui.Rect = .{ .width = 800, .height = 600 };

test "every alignment of a row and a column mirrors, with the padding" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const alignments = [_]zui.Alignment{ .start, .center, .end };
    for ([_]bool{ false, true }) |column| for (alignments) |x| for (alignments) |y| {
        const alignment: zui.Alignment2 = .{ .x = x, .y = y };
        var unmirrored: [child_ids.len]zui.Rect = undefined;
        const plain = try alignmentScene(&harness, .none, column, alignment);
        const parent = plain.rectOf(.of("parent")).?;
        for (child_ids, &unmirrored) |id, *rect| rect.* = plain.rectOf(id).?;

        for ([_]Mode{ .environment, .mirrored_ancestor, .right_to_left_parent }) |mode| {
            if (column and mode == .right_to_left_parent) continue;
            const frame = try alignmentScene(&harness, mode, column, alignment);
            const across = if (mode == .right_to_left_parent) parent else viewport;
            for (child_ids, unmirrored, 0..) |id, rect, child| {
                errdefer std.debug.print("column={} x={t} y={t} mode={t} child={d}\n", .{ column, x, y, mode, child });
                try testing.expectEqual(reflected(rect, across), frame.rectOf(id).?);
            }
        }
    };
}

test "a mirrored row starts at its right edge, inside the padding on its left" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const frame = try alignmentScene(&harness, .environment, false, .{});
    try expectRect(frame, .of("parent"), 460, 20, 300, 200);
    try expectRect(frame, .of("a"), 700, 25, 50, 20);
    try expectRect(frame, .of("b"), 666, 25, 30, 40);
    try expectRect(frame, .of("c"), 642, 25, 20, 10);
}

const target_id: zui.Id = .of("target");
const floating_id: zui.Id = .of("floating");

fn anchorScene(harness: *support.Harness, mode: Mode, attach_to: zui.AttachTo, anchor: zui.AnchorPoint, attach_point: zui.AnchorPoint) !*const support.Ui.Frame {
    const ui = beginIn(harness, mode);
    openOuter(ui, mode);
    ui.box(.{ .id = target_id, .layout = .{ .sizing = fixed(120, 60) } });
    ui.open(.{ .id = .of("parent"), .layout = .{ .direction = rowDirection(mode), .sizing = fixed(200, 100) } });
    ui.box(.{
        .id = floating_id,
        .layout = .{ .sizing = fixed(30, 16) },
        .floating = .{ .attach_to = attach_to, .anchor = anchor, .attach_point = attach_point, .offset = .{ 7, 3 } },
    });
    ui.close();
    ui.close();
    return harness.end();
}

test "every anchor and attach point mirrors, with the offset, for every target" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const points = std.enums.values(zui.AnchorPoint);
    const targets = [_]zui.AttachTo{ .parent, .root, .{ .element = target_id } };
    for (targets) |attach_to| for (points) |anchor| for (points) |attach_point| {
        const plain = try anchorScene(&harness, .none, attach_to, anchor, attach_point);
        const unmirrored = plain.rectOf(floating_id).?;
        const target_box = switch (attach_to) {
            .parent => plain.rectOf(.of("parent")).?,
            .root => viewport,
            .element => plain.rectOf(target_id).?,
        };
        for ([_]Mode{ .environment, .mirrored_ancestor, .right_to_left_parent }) |mode| {
            errdefer std.debug.print("attach_to={t} anchor={t} attach_point={t} mode={t}\n", .{ attach_to, anchor, attach_point, mode });
            const frame = try anchorScene(&harness, mode, attach_to, anchor, attach_point);
            const across = if (mode == .right_to_left_parent) target_box else viewport;
            try testing.expectEqual(reflected(unmirrored, across), frame.rectOf(floating_id).?);
        }
    };
}

test "a mirrored menu opens below its button, aligned to the button's right edge" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const frame = try anchorScene(&harness, .environment, .{ .element = target_id }, .top_left, .bottom_left);
    try expectRect(frame, target_id, 640, 20, 120, 60);
    try expectRect(frame, floating_id, 723, 83, 30, 16);
}

fn textLines(frame: *const support.Ui.Frame, lines: *[2]zui.Rect) void {
    var count: usize = 0;
    for (frame.commands()) |command| if (command.payload == .text) {
        lines[count] = command.bounds;
        count += 1;
    };
}

test "a text's start and end alignments swap in a mirrored element" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const alignments = [_]zui.Alignment{ .start, .center, .end };
    const second_line_x = [_]f32{ 784, 768, 752 };
    for (alignments, second_line_x) |alignment, expected_x| {
        const ui = harness.beginEvents(&right_to_left_environment);
        ui.text("abcdef\nab", .{ .wrap = .newlines, .alignment = alignment });
        const frame = try harness.end();
        var lines: [2]zui.Rect = undefined;
        textLines(frame, &lines);
        try testing.expectEqual(zui.Rect{ .x = 752, .y = 0, .width = 48, .height = 16 }, lines[0]);
        try testing.expectEqual(zui.Rect{ .x = expected_x, .y = 16, .width = 16, .height = 16 }, lines[1]);
    }
}

test "mirrored = .no and .yes override the parent, and right_to_left in a mirrored row flows from the left" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.beginEvents(&right_to_left_environment);
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(200) }, .mirrored = .no } });
    ui.box(.{ .id = .of("first"), .layout = .{ .sizing = fixed(20, 10) } });
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(100) }, .mirrored = .yes } });
    ui.box(.{ .id = .of("inner"), .layout = .{ .sizing = fixed(20, 10) } });
    ui.close();
    ui.close();
    ui.open(.{ .layout = .{ .direction = .right_to_left, .sizing = .{ .width = .fixed(200) } } });
    ui.box(.{ .id = .indexed("reversed", 0), .layout = .{ .sizing = fixed(20, 10) } });
    ui.box(.{ .id = .indexed("reversed", 1), .layout = .{ .sizing = fixed(20, 10) } });
    ui.close();
    const frame = try harness.end();

    try expectRect(frame, .of("first"), 600, 0, 20, 10);
    try expectRect(frame, .of("inner"), 700, 0, 20, 10);
    try expectRect(frame, .indexed("reversed", 0), 600, 10, 20, 10);
    try expectRect(frame, .indexed("reversed", 1), 620, 10, 20, 10);
}

test "a mirrored row scrolls from its right edge, and the wheel moves it the way the pointer does" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    _ = harness.beginEvents(&right_to_left_environment);
    _ = try harness.end();

    const list: zui.Id = .of("list");
    const wheels = [_][2]f32{ .{ 0, 0 }, .{ 30, 0 }, .{ -30, 0 }, .{ 10, 0 } };
    const offsets = [_]f32{ 0, 0, 30, 20 };
    for (wheels, offsets) |wheel, offset| {
        const ui = harness.beginWith(.{ .pointer = .{ 700, 10 }, .wheel = wheel });
        try testing.expectEqual(offset, ui.scrollOffset(list)[0]);
        ui.open(.{ .id = list, .layout = .{ .sizing = fixed(200, 50) }, .scroll = .{ .horizontal = true, .vertical = false } });
        for (0..5) |index| ui.box(.{ .id = .indexed("item", @intCast(index)), .layout = .{ .sizing = fixed(100, 50) } });
        ui.close();
        const frame = try harness.end();
        try expectRect(frame, list, 600, 0, 200, 50);
        try expectRect(frame, .indexed("item", 0), 700 + offset, 0, 100, 50);
        try expectRect(frame, .indexed("item", 4), 300 + offset, 0, 100, 50);
    }
}

test "a mirrored row's dividers sit in its gaps" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.beginEvents(&right_to_left_environment);
    ui.open(.{
        .layout = .{ .sizing = fixed(100, 20), .child_gap = 10 },
        .decoration = .{ .border = .{ .color = .rgb(0x222222), .widths = .all(1), .between_children = 2 } },
    });
    for (0..3) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(20), .height = .grow } }, .decoration = .{ .background = .rgb(0x333333) } });
    ui.close();

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        \\rect 780 0 20 20 #333333
        \\rect 750 0 20 20 #333333
        \\rect 720 0 20 20 #333333
        \\rect 774 1 2 18 #222222
        \\rect 744 1 2 18 #222222
        \\border 700 0 100 20 #222222
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "a frame that cannot mirror leaves every element unmirrored" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("row"), .layout = .{ .sizing = fixed(100, 20) } });
    ui.text("ab", .{});
    ui.close();
    const frame = try harness.end();
    try testing.expect(!frame.may_mirror);
    for (frame.flags[0..frame.element_count]) |flags| try testing.expect(!flags.mirrored and !flags.reversed);
}

//! Rows that wrap their children onto new lines. The viewport is 800 wide.

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const expectRect = support.expectRect;
const testing = std.testing;

fn fixed(width: f32, height: f32) zui.Sizing2 {
    return .{ .width = .fixed(width), .height = .fixed(height) };
}

const child_ids = [_]zui.Id{ .of("a"), .of("b"), .of("c"), .of("d") };
const child_sizes = [_][2]f32{ .{ 60, 20 }, .{ 70, 30 }, .{ 50, 10 }, .{ 100, 16 } };

/// A content box of 170 × 140: "a" and "b" fill 134 of the first line,
/// "c" does not fit after them, and "c" and "d" fill 154 of the second.
fn alignmentScene(harness: *support.Harness, alignment: zui.Alignment2, mirrored: zui.Mirrored) !*const support.Ui.Frame {
    const ui = harness.begin();
    ui.open(.{ .id = .of("row"), .layout = .{
        .sizing = fixed(200, 150),
        .padding = .{ .left = 10, .right = 20, .top = 5, .bottom = 5 },
        .child_gap = 4,
        .child_alignment = alignment,
        .mirrored = mirrored,
    } });
    ui.wrapChildren();
    for (child_ids, child_sizes) |id, size| ui.box(.{ .id = id, .layout = .{ .sizing = fixed(size[0], size[1]) } });
    ui.close();
    return harness.end();
}

test "every alignment places the lines as a group, each line along the row and each child in its line" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const alignments = [_]zui.Alignment{ .start, .center, .end };
    for (alignments) |x| for (alignments) |y| {
        const frame = try alignmentScene(&harness, .{ .x = x, .y = y }, .inherit);
        const along = x.fraction();
        const across = y.fraction();
        const first_top = 5 + 90 * across;
        const second_top = first_top + 30 + 4;
        const first_left = 10 + 36 * along;
        const second_left = 10 + 16 * along;
        errdefer std.debug.print("x={t} y={t}\n", .{ x, y });
        try expectRect(frame, .of("a"), first_left, first_top + 10 * across, 60, 20);
        try expectRect(frame, .of("b"), first_left + 64, first_top, 70, 30);
        try expectRect(frame, .of("c"), second_left, second_top + 6 * across, 50, 10);
        try expectRect(frame, .of("d"), second_left + 54, second_top, 100, 16);
    };
}

test "a wrapping row at the start, by hand" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const frame = try alignmentScene(&harness, .{}, .inherit);
    try expectRect(frame, .of("a"), 10, 5, 60, 20);
    try expectRect(frame, .of("b"), 74, 5, 70, 30);
    try expectRect(frame, .of("c"), 10, 39, 50, 10);
    try expectRect(frame, .of("d"), 64, 39, 100, 16);
}

test "every alignment of a mirrored wrapping row is the row reflected" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const alignments = [_]zui.Alignment{ .start, .center, .end };
    for (alignments) |x| for (alignments) |y| {
        var unmirrored: [child_ids.len]zui.Rect = undefined;
        const plain = try alignmentScene(&harness, .{ .x = x, .y = y }, .inherit);
        const row = plain.rectOf(.of("row")).?;
        for (child_ids, &unmirrored) |id, *rect| rect.* = plain.rectOf(id).?;
        const frame = try alignmentScene(&harness, .{ .x = x, .y = y }, .yes);
        for (child_ids, unmirrored) |id, rect| {
            errdefer std.debug.print("x={t} y={t}\n", .{ x, y });
            try testing.expectEqual(zui.Rect{ .x = 2 * row.x + row.width - rect.x - rect.width, .y = rect.y, .width = rect.width, .height = rect.height }, frame.rectOf(id).?);
        }
    };
}

test "growing children share each line's free space, not the row's" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("row"), .layout = .{ .sizing = .{ .width = .fixed(300) } } });
    ui.wrapChildren();
    ui.box(.{ .id = .of("a"), .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(10) }, .padding = .{ .left = 100 } } });
    ui.box(.{ .id = .of("b"), .layout = .{ .sizing = fixed(150, 20) } });
    ui.box(.{ .id = .of("c"), .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(10) }, .padding = .{ .left = 100 } } });
    ui.close();
    const frame = try harness.end();
    try expectRect(frame, .of("row"), 0, 0, 300, 30);
    try expectRect(frame, .of("a"), 0, 0, 150, 10);
    try expectRect(frame, .of("b"), 150, 0, 150, 20);
    try expectRect(frame, .of("c"), 0, 20, 300, 10);
}

test "a child wider than the row takes a line of its own and shrinks to it" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("row"), .layout = .{ .sizing = .{ .width = .fixed(100) } } });
    ui.wrapChildren();
    ui.box(.{ .id = .of("before"), .layout = .{ .sizing = fixed(30, 10) } });
    ui.text("abcdefghij abcdefghij", .{});
    ui.box(.{ .id = .of("after"), .layout = .{ .sizing = fixed(30, 10) } });
    ui.close();
    const frame = try harness.end();
    try expectRect(frame, .of("before"), 0, 0, 30, 10);
    try expectRect(frame, .of("after"), 0, 42, 30, 10);
    try expectRect(frame, .of("row"), 0, 0, 100, 52);
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        \\text 0 10 80 16 "abcdefghij"
        \\text 0 26 80 16 "abcdefghij"
        \\
    , try support.snapshot(frame, &buffer));
}

test "a fit wrapping row is as wide as one line, but narrows to its widest child" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .direction = .top_to_bottom } });
    ui.open(.{ .id = .of("wide"), .layout = .{ .child_gap = 10 } });
    ui.wrapChildren();
    for (0..3) |_| ui.box(.{ .layout = .{ .sizing = fixed(50, 20) } });
    ui.close();
    ui.close();
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(120) } } });
    ui.open(.{ .id = .of("narrow"), .layout = .{ .child_gap = 10 } });
    ui.wrapChildren();
    for (0..3) |index| ui.box(.{ .id = .indexed("cell", @intCast(index)), .layout = .{ .sizing = fixed(50, 20) } });
    ui.close();
    ui.close();
    const frame = try harness.end();
    try expectRect(frame, .of("wide"), 0, 0, 170, 20);
    try expectRect(frame, .of("narrow"), 0, 20, 120, 50);
    try expectRect(frame, .indexed("cell", 1), 60, 20, 50, 20);
    try expectRect(frame, .indexed("cell", 2), 0, 50, 50, 20);
}

test "a growing height stretches to its line, and the row is as tall as its lines" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("row"), .layout = .{ .sizing = .{ .width = .fixed(170) } } });
    ui.wrapChildren();
    ui.box(.{ .id = .of("a"), .layout = .{ .sizing = fixed(80, 40) } });
    ui.box(.{ .id = .of("b"), .layout = .{ .sizing = .{ .width = .fixed(80), .height = .grow } } });
    ui.box(.{ .id = .of("c"), .layout = .{ .sizing = .{ .width = .fixed(80), .height = .grow }, .padding = .{ .top = 10 } } });
    ui.close();
    const frame = try harness.end();
    try expectRect(frame, .of("b"), 80, 0, 80, 40);
    try expectRect(frame, .of("c"), 0, 40, 80, 10);
    try expectRect(frame, .of("row"), 0, 0, 170, 50);
}

test "a floating child takes no part in the lines" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("row"), .layout = .{ .sizing = .{ .width = .fixed(100) } } });
    ui.wrapChildren();
    ui.box(.{ .id = .of("a"), .layout = .{ .sizing = fixed(60, 10) } });
    ui.box(.{ .id = .of("badge"), .layout = .{ .sizing = fixed(90, 90) }, .floating = .{ .offset = .{ 5, 5 } } });
    ui.box(.{ .id = .of("b"), .layout = .{ .sizing = fixed(60, 10) } });
    ui.close();
    const frame = try harness.end();
    try expectRect(frame, .of("b"), 0, 10, 60, 10);
    try expectRect(frame, .of("badge"), 5, 5, 90, 90);
    try expectRect(frame, .of("row"), 0, 0, 100, 20);
}

test "a column does not wrap" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("column"), .layout = .{ .direction = .top_to_bottom, .sizing = fixed(100, 30) } });
    ui.wrapChildren();
    ui.box(.{ .id = .of("a"), .layout = .{ .sizing = fixed(50, 20) } });
    ui.box(.{ .id = .of("b"), .layout = .{ .sizing = fixed(50, 20) } });
    ui.close();
    const frame = try harness.end();
    try expectRect(frame, .of("b"), 0, 20, 50, 20);
}

test "a wrapping row scrolls through its lines" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const gallery: zui.Id = .of("gallery");
    for (0..2) |_| {
        const ui = harness.begin();
        ui.setScrollOffset(gallery, .{ 0, 1000 });
        ui.open(.{ .id = gallery, .scroll = .{}, .layout = .{ .sizing = fixed(100, 30), .child_gap = 10 } });
        ui.wrapChildren();
        for (0..6) |index| ui.box(.{ .id = .indexed("photo", @intCast(index)), .layout = .{ .sizing = fixed(40, 20) } });
        ui.close();
        _ = try harness.end();
    }
    try testing.expectEqual([2]f32{ 0, 50 }, harness.ui.scrollOffset(gallery));
    const ui = harness.begin();
    ui.open(.{ .id = gallery, .scroll = .{}, .layout = .{ .sizing = fixed(100, 30), .child_gap = 10 } });
    ui.wrapChildren();
    for (0..6) |index| ui.box(.{ .id = .indexed("photo", @intCast(index)), .layout = .{ .sizing = fixed(40, 20) } });
    ui.close();
    const frame = try harness.end();
    try expectRect(frame, .indexed("photo", 5), 50, 10, 40, 20);
}

test "dividers sit between the children of a line and between the lines" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{
        .layout = .{ .sizing = .{ .width = .fixed(100) }, .child_gap = 10 },
        .decoration = .{ .border = .{ .color = .rgb(0x2c2c38), .between_children = 2 } },
    });
    ui.wrapChildren();
    for (0..3) |_| ui.box(.{ .layout = .{ .sizing = fixed(40, 20) } });
    ui.close();
    const frame = try harness.end();
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        \\rect 44 0 2 20 #2c2c38
        \\rect 0 24 100 2 #2c2c38
        \\
    , try support.snapshot(frame, &buffer));
}

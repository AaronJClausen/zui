const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;
const Ui = support.Ui;
const expectRect = support.expectRect;

fn fixed(width: f32, height: f32) zui.Layout {
    return .{ .sizing = .{ .width = .fixed(width), .height = .fixed(height) } };
}

fn fixedColumn(width: f32, height: f32) zui.Layout {
    return .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(width), .height = .fixed(height) } };
}

test "clipping emits a clip pair and skips what is fully hidden" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = fixedColumn(100, 50), .clip = .both });
    ui.box(.{ .layout = fixed(100, 40), .decoration = .{ .background = .rgb(0x111111) } });
    ui.box(.{ .layout = fixed(100, 40), .decoration = .{ .background = .rgb(0x222222) } }); // half visible
    ui.box(.{ .layout = fixed(100, 40), .decoration = .{ .background = .rgb(0x333333) } }); // fully below the clip
    ui.close();

    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\clip 0 0 100 50
        \\rect 0 0 100 40 #111111
        \\rect 0 40 100 40 #222222
        \\clip_end
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "nested clips are intersected before they are emitted" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(100) }, .padding = .{ .left = 50 } }, .clip = .both });
    ui.box(.{ .layout = fixed(100, 20), .clip = .both });
    ui.close();

    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\clip 0 0 100 100
        \\clip 50 0 50 20
        \\clip_end
        \\clip_end
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "clipping one axis leaves the other to the enclosing clip" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    harness.begin().box(.{ .layout = fixed(100, 20), .clip = .horizontal });
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings("clip 0 0 100 600\nclip_end\n", try support.snapshot(try harness.end(), &buffer));
}

const list: zui.Id = .of("list");

/// A 100×50 vertical scroll container holding five 20-high rows: content
/// 100 high, so the largest offset is 50.
fn scrollList(ui: *Ui) void {
    ui.open(.{ .id = list, .layout = fixedColumn(100, 50), .scroll = .{} });
    for (0..5) |row| ui.box(.{ .id = .indexed("row", row), .layout = fixed(100, 20), .decoration = .{ .background = .white } });
    ui.close();
}

test "a scroll offset moves the content, clamped to its extent" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    scrollList(harness.begin());
    try expectRect(try harness.end(), .indexed("row", 0), 0, 0, 100, 20);

    var ui = harness.begin();
    ui.setScrollOffset(list, .{ 0, 30 });
    scrollList(ui);
    var frame = try harness.end();
    try expectRect(frame, .indexed("row", 0), 0, -30, 100, 20);
    try expectRect(frame, .indexed("row", 2), 0, 10, 100, 20);
    try testing.expectEqual([2]f32{ 0, 30 }, harness.ui.scrollOffset(list));
    // Row 0 (-30..-10) is outside the clip and not drawn; row 1 (-10..10) is.
    try testing.expectEqual(@as(f32, -10), frame.commands()[1].bounds.y);

    ui = harness.begin();
    ui.setScrollOffset(list, .{ 0, 500 });
    scrollList(ui);
    frame = try harness.end();
    try expectRect(frame, .indexed("row", 0), 0, -50, 100, 20);
    try testing.expectEqual([2]f32{ 0, 50 }, harness.ui.scrollOffset(list));
}

test "the wheel scrolls the innermost container that can still move" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const outer: zui.Id = .of("outer");
    const inner: zui.Id = .of("inner");
    const expected = [_][2]f32{ .{ 0, 0 }, .{ 30, 0 }, .{ 50, 0 }, .{ 50, 30 } };
    for (expected, 0..) |offsets, frame_number| {
        const ui = harness.beginWith(.{ .pointer = .{ 10, 10 }, .wheel = if (frame_number == 0) .{ 0, 0 } else .{ 0, 30 } });
        try testing.expectEqual(offsets[0], ui.scrollOffset(inner)[1]);
        try testing.expectEqual(offsets[1], ui.scrollOffset(outer)[1]);
        ui.open(.{ .id = outer, .layout = fixedColumn(200, 100), .scroll = .{} });
        ui.open(.{ .id = inner, .layout = fixedColumn(200, 50), .scroll = .{} });
        for (0..5) |_| ui.box(.{ .layout = fixed(200, 20) });
        ui.close();
        ui.box(.{ .layout = fixed(200, 200) });
        ui.close();
        _ = try harness.end();
    }
}

test "a scrolled axis does not shrink its children" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("strip"), .layout = .{ .sizing = .{ .width = .fixed(50) } }, .scroll = .{ .horizontal = true, .vertical = false } });
    ui.text("abcdefgh ijklmnop", .{});
    ui.close();

    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\clip 0 0 50 600
        \\text 0 0 136 16 "abcdefgh ijklmnop"
        \\clip_end
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "a floating element takes no space in its parent" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("anchor") });
    ui.box(.{ .layout = fixed(50, 20) });
    ui.box(.{ .id = .of("float"), .layout = fixed(30, 30), .floating = .{} });
    ui.close();

    const frame = try harness.end();
    try expectRect(frame, .of("anchor"), 0, 0, 50, 20);
    try expectRect(frame, .of("float"), 0, 0, 30, 30);
}

test "anchor and attach points place a tooltip under its button" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = fixed(100, 40) });
    ui.box(.{ .id = .of("tip"), .layout = fixed(60, 20), .floating = .{ .anchor = .top_center, .attach_point = .bottom_center, .offset = .{ 0, 4 } } });
    ui.close();

    try expectRect(try harness.end(), .of("tip"), 20, 44, 60, 20);
}

test "attaching to the root centers in the viewport" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    harness.begin().box(.{ .id = .of("modal"), .layout = fixed(100, 100), .floating = .{ .attach_to = .root, .anchor = .center, .attach_point = .center } });
    try expectRect(try harness.end(), .of("modal"), 350, 250, 100, 100);
}

test "attaching to another element by id" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.box(.{ .layout = fixed(800, 100) });
    ui.open(.{ .id = .of("target"), .layout = fixed(50, 50) });
    ui.close();
    ui.box(.{ .id = .of("menu"), .layout = fixed(40, 10), .floating = .{ .attach_to = .{ .element = .of("target") }, .attach_point = .bottom_right } });

    try expectRect(try harness.end(), .of("menu"), 50, 150, 40, 10);
}

test "a target declared later falls back to the parent" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.box(.{ .layout = fixed(800, 100) });
    ui.open(.{ .id = .of("panel"), .layout = fixed(200, 60) });
    ui.box(.{ .id = .of("menu"), .layout = fixed(40, 10), .floating = .{ .attach_to = .{ .element = .of("later") }, .attach_point = .bottom_right } });
    ui.close();
    ui.box(.{ .id = .of("later"), .layout = fixed(50, 50) });

    try expectRect(try harness.end(), .of("menu"), 200, 160, 40, 10);
}

test "grow on a root-attached floating element fills the viewport" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = fixed(10, 10) });
    ui.box(.{ .id = .of("overlay"), .layout = .{ .sizing = .grow_both }, .floating = .{ .attach_to = .root } });
    ui.close();
    try expectRect(try harness.end(), .of("overlay"), 0, 0, 800, 600);
}

test "floating layers paint last and escape their ancestors' clip" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = fixed(100, 50), .clip = .both, .decoration = .{ .background = .rgb(0x111111) } });
    ui.box(.{ .layout = fixed(20, 20), .decoration = .{ .background = .rgb(0x333333) }, .floating = .{ .offset = .{ 200, 0 } } });
    ui.close();
    ui.box(.{ .layout = fixed(10, 10), .decoration = .{ .background = .rgb(0x222222) } });

    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\rect 0 0 100 50 #111111
        \\clip 0 0 100 50
        \\clip_end
        \\rect 0 50 10 10 #222222
        \\rect 200 0 20 20 #333333
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "floating children add no gap to their parent's flow" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("row"), .layout = .{ .child_gap = 10 } });
    ui.box(.{ .layout = fixed(20, 20) });
    ui.box(.{ .layout = fixed(5, 5), .floating = .{} });
    ui.box(.{ .layout = fixed(20, 20) });
    ui.close();

    try expectRect(try harness.end(), .of("row"), 0, 0, 50, 20);
}

test "alignment centers children inside the padding" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(60) }, .padding = .all(10), .child_alignment = .{ .x = .center, .y = .end } } });
    ui.box(.{ .id = .of("child"), .layout = fixed(20, 10) });
    ui.close();

    try expectRect(try harness.end(), .of("child"), 40, 40, 20, 10);
}

test "a row scrolls vertically to its tallest child" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    scrollingRow(harness.begin());
    _ = try harness.end();
    const ui = harness.begin();
    ui.setScrollOffset(strip, .{ 0, 1000 });
    scrollingRow(ui);
    _ = try harness.end();
    try testing.expectEqual([2]f32{ 0, 55 }, harness.ui.scrollOffset(strip));
}

const strip: zui.Id = .of("strip");

fn scrollingRow(ui: *Ui) void {
    ui.open(.{ .id = strip, .scroll = .{}, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(30) }, .padding = .{ .bottom = 5 } } });
    ui.box(.{ .layout = fixed(20, 50) });
    ui.box(.{ .layout = fixed(20, 80) });
    ui.close();
}

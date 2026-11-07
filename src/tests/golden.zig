//! Hand-computed layouts. An unspaced character is 8×16, letter spacing
//! adds its width after every character, the viewport is 800×600, and
//! zui's root stacks children top to bottom.

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const expectRect = support.expectRect;
const testing = std.testing;

fn fixedBox(ui: *support.Ui, id: zui.Id, width: f32, height: f32) void {
    ui.box(.{ .id = id, .layout = .{ .sizing = .{ .width = .fixed(width), .height = .fixed(height) } } });
}

test "a fixed box sits at the origin" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    fixedBox(harness.begin(), .of("box"), 100, 50);
    try expectRect(try harness.end(), .of("box"), 0, 0, 100, 50);
}

test "grow_both fills the viewport" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    harness.begin().box(.{ .id = .of("fill"), .layout = .{ .sizing = .grow_both } });
    try expectRect(try harness.end(), .of("fill"), 0, 0, 800, 600);
}

test "fit wraps children, padding and gaps" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("parent"), .layout = .{ .padding = .all(10), .child_gap = 5 } });
    fixedBox(ui, .of("a"), 50, 20);
    fixedBox(ui, .of("b"), 30, 40);
    ui.close();

    const frame = try harness.end();
    try expectRect(frame, .of("parent"), 0, 0, 105, 60);
    try expectRect(frame, .of("a"), 10, 10, 50, 20);
    try expectRect(frame, .of("b"), 65, 10, 30, 40);
}

test "grow splits free space by weight" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(300), .height = .fixed(100) } } });
    ui.box(.{ .id = .of("one"), .layout = .{ .sizing = .{ .width = .growWeighted(1), .height = .grow } } });
    ui.box(.{ .id = .of("two"), .layout = .{ .sizing = .{ .width = .growWeighted(2), .height = .grow } } });
    ui.close();

    const frame = try harness.end();
    try expectRect(frame, .of("one"), 0, 0, 100, 100);
    try expectRect(frame, .of("two"), 100, 0, 200, 100);
}

test "grow stops at max and the rest goes to the others" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(300) } } });
    ui.box(.{ .id = .of("capped"), .layout = .{ .sizing = .{ .width = .{ .rule = .grow, .amount = 1, .max = 50 } } } });
    ui.box(.{ .id = .of("open"), .layout = .{ .sizing = .{ .width = .grow } } });
    ui.close();

    const frame = try harness.end();
    try expectRect(frame, .of("capped"), 0, 0, 50, 0);
    try expectRect(frame, .of("open"), 50, 0, 250, 0);
}

test "grow adds free space on top of content size" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(200) } } });
    ui.open(.{ .id = .of("with_content"), .layout = .{ .sizing = .{ .width = .grow } } });
    fixedBox(ui, .of("content"), 50, 10);
    ui.close();
    ui.box(.{ .id = .of("empty"), .layout = .{ .sizing = .{ .width = .grow } } });
    ui.close();

    const frame = try harness.end();
    try expectRect(frame, .of("with_content"), 0, 0, 125, 10);
    try expectRect(frame, .of("empty"), 125, 0, 75, 0);
}

test "percent is a fraction of the parent's content box" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(400), .height = .fixed(100) }, .padding = .all(50) } });
    ui.box(.{ .id = .of("half"), .layout = .{ .sizing = .{ .width = .percent(0.5), .height = .percent(1) } } });
    ui.close();

    try expectRect(try harness.end(), .of("half"), 50, 50, 150, 0);
}

test "fixed children overflow instead of shrinking" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(100) } } });
    fixedBox(ui, .of("a"), 80, 10);
    fixedBox(ui, .of("b"), 80, 10);
    ui.close();

    const frame = try harness.end();
    try expectRect(frame, .of("a"), 0, 0, 80, 10);
    try expectRect(frame, .of("b"), 80, 0, 80, 10);
}

/// 24 characters: preferred 192, longest word 32.
const long_text = "aaaa aaaa aaaa aaaa aaaa";
/// 9 characters: preferred 72, longest word 32.
const short_text = "bbbb bbbb";

fn twoTexts(ui: *support.Ui, parent_width: f32) void {
    ui.open(.{ .id = .of("row"), .layout = .{ .sizing = .{ .width = .fixed(parent_width) } } });
    ui.open(.{ .id = .of("long") });
    ui.text(long_text, .{});
    ui.close();
    ui.open(.{ .id = .of("short") });
    ui.text(short_text, .{});
    ui.close();
    ui.close();
}

test "shrinking takes from the largest child first" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    twoTexts(harness.begin(), 200);
    const frame = try harness.end();
    // Deficit 64 comes entirely out of the 192-wide child; at 128 wide its
    // text wraps to two lines.
    try expectRect(frame, .of("long"), 0, 0, 128, 32);
    try expectRect(frame, .of("short"), 128, 0, 72, 16);
    try expectRect(frame, .of("row"), 0, 0, 200, 32);
}

test "shrinking levels equal children down together" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    twoTexts(harness.begin(), 100);
    const frame = try harness.end();
    // Deficit 164: the long child drops to 72 (the next largest), then both
    // share the remaining 44 and end at 50.
    try expectRect(frame, .of("long"), 0, 0, 50, 80);
    try expectRect(frame, .of("short"), 50, 0, 50, 32);
}

test "shrinking never goes below a child's minimum" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    twoTexts(harness.begin(), 40);
    const frame = try harness.end();
    try expectRect(frame, .of("long"), 0, 0, 32, 80);
    try expectRect(frame, .of("short"), 32, 0, 32, 32);
}

test "across the axis, grow stretches and fixed stays" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(200), .height = .fixed(100) } } });
    ui.box(.{ .id = .of("stretched"), .layout = .{ .sizing = .{ .width = .fixed(20), .height = .grow } } });
    fixedBox(ui, .of("fixed"), 20, 10);
    ui.close();

    const frame = try harness.end();
    try expectRect(frame, .of("stretched"), 0, 0, 20, 100);
    try expectRect(frame, .of("fixed"), 20, 0, 20, 10);
}

test "child alignment along and across the axis" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(200), .height = .fixed(100) }, .child_alignment = .{ .x = .center, .y = .end } } });
    fixedBox(ui, .of("centered"), 50, 20);
    ui.close();

    try expectRect(try harness.end(), .of("centered"), 75, 80, 50, 20);
}

test "top to bottom stacks with gaps" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("column"), .layout = .{ .direction = .top_to_bottom, .child_gap = 10 } });
    fixedBox(ui, .of("a"), 30, 20);
    fixedBox(ui, .of("b"), 50, 10);
    ui.close();

    const frame = try harness.end();
    try expectRect(frame, .of("column"), 0, 0, 50, 40);
    try expectRect(frame, .of("b"), 0, 30, 50, 10);
}

test "nested padding accumulates" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(200), .height = .fixed(200) }, .padding = .all(10) } });
    ui.open(.{ .id = .of("inner"), .layout = .{ .sizing = .grow_both, .padding = .all(5) } });
    fixedBox(ui, .of("leaf"), 10, 10);
    ui.close();
    ui.close();

    const frame = try harness.end();
    try expectRect(frame, .of("inner"), 10, 10, 180, 180);
    try expectRect(frame, .of("leaf"), 15, 15, 10, 10);
}

test "top-level siblings stack in the root" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    fixedBox(ui, .of("header"), 800, 40);
    ui.box(.{ .id = .of("body"), .layout = .{ .sizing = .grow_both } });

    const frame = try harness.end();
    try expectRect(frame, .of("header"), 0, 0, 800, 40);
    try expectRect(frame, .of("body"), 0, 40, 800, 560);
}

test "text wraps at words and emits one command per line" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(64) } } });
    ui.text("one two three", .{});
    ui.close();

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        \\text 0 0 56 16 "one two"
        \\text 0 16 40 16 "three"
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "text alignment positions each line within the element" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(64) } } });
    ui.text("one two three", .{ .alignment = .end });
    ui.close();

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        \\text 8 0 56 16 "one two"
        \\text 24 16 40 16 "three"
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "newline wrapping breaks only at newlines" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    harness.begin().text("ab\ncde", .{ .wrap = .newlines });
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        \\text 0 0 16 16 "ab"
        \\text 0 16 24 16 "cde"
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "no wrapping keeps one line and overflows a narrow parent" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(16) } } });
    ui.text("a b c", .{ .wrap = .none });
    ui.close();

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("text 0 0 40 16 \"a b c\"\n", try support.snapshot(try harness.end(), &buffer));
}

test "a word wider than its line overflows instead of breaking" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(32) } } });
    ui.text("ab abcdefghij", .{});
    ui.close();

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        \\text 0 0 16 16 "ab"
        \\text 0 16 80 16 "abcdefghij"
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "empty text has no lines and no height" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("wrapper") });
    ui.text("", .{});
    ui.close();

    const frame = try harness.end();
    try expectRect(frame, .of("wrapper"), 0, 0, 0, 0);
    try testing.expectEqual(@as(usize, 0), frame.commands().len);
}

test "line height override sets the line pitch" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("block"), .layout = .{ .sizing = .{ .width = .fixed(64) } } });
    ui.text("one two three", .{ .line_height = 24 });
    ui.close();

    try expectRect(try harness.end(), .of("block"), 0, 0, 64, 48);
}

test "backgrounds, children, then borders: paint order" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{
        .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(50) }, .padding = .all(5) },
        .decoration = .{
            .background = .rgb(0x111111),
            .border = .{ .color = .rgb(0x222222), .widths = .all(1) },
        },
    });
    ui.box(.{ .layout = .{ .sizing = .grow_both }, .decoration = .{ .background = .rgb(0x333333) } });
    ui.close();

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        \\rect 0 0 100 50 #111111
        \\rect 5 5 90 40 #333333
        \\border 0 0 100 50 #222222
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "elements without ids get the same internal ids every frame" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    var first_ids: [2]u64 = undefined;
    for (0..2) |frame_number| {
        const ui = harness.begin();
        ui.open(.{ .decoration = .{ .background = .rgb(0x101010) }, .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
        ui.box(.{ .decoration = .{ .background = .rgb(0x202020) }, .layout = .{ .sizing = .grow_both } });
        ui.close();
        const frame = try harness.end();
        const commands = frame.commands();
        if (frame_number == 0) {
            first_ids = .{ commands[0].id, commands[1].id };
        } else {
            try testing.expectEqual(first_ids, [2]u64{ commands[0].id, commands[1].id });
        }
    }
    try testing.expect(first_ids[0] != first_ids[1]);
}

test "rectOf misses undeclared ids" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    fixedBox(harness.begin(), .of("present"), 1, 1);
    const frame = try harness.end();
    try testing.expect(frame.rectOf(.of("present")) != null);
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(.of("absent")));
}

test "image and custom elements carry typed payloads" {
    const Shape = enum { circle, star };
    const PayloadUi = zui.Context(.{ .limits = .{ .max_elements = 16 }, .CustomData = Shape, .ImageHandle = u32 });
    var ui = try PayloadUi.init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    ui.image(.{ .handle = 42 }, .{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
    ui.custom(.star, .{ .layout = .{ .sizing = .{ .width = .fixed(5), .height = .fixed(5) } } });
    const frame = ui.endFrame();
    defer ui.release(frame);

    const commands = frame.commands();
    try testing.expectEqual(@as(u32, 42), commands[0].payload.image.handle);
    try testing.expectEqual(Shape.star, commands[1].payload.custom);
    try testing.expectEqual(zui.Rect{ .x = 0, .y = 10, .width = 5, .height = 5 }, commands[1].bounds);
}

test "letter spacing is part of the measurement key" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("plain") });
    ui.text("abc", .{});
    ui.close();
    ui.open(.{ .id = .of("spaced") });
    ui.text("abc", .{ .letter_spacing = 2 });
    ui.close();
    const frame = try harness.end();
    // "abc" and the space, once per key.
    try testing.expectEqual(@as(u64, 4), harness.ui.measureCalls());
    try expectRect(frame, .of("plain"), 0, 0, 24, 16);
    try expectRect(frame, .of("spaced"), 0, 16, 30, 16);
}

test "letter spacing widens every character, including the last, and wraps sooner" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    // Unspaced, "ab cd ef" is exactly 64 wide and fits on one line; with a
    // spacing of 2 each character is 10 wide and the text needs 80.
    for ([_]f32{ 0.5, 1, 2 }) |zoom| {
        harness.ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 800, 600 }, .zoom = zoom } });
        harness.ui.open(.{ .id = .of("block"), .layout = .{ .sizing = .{ .width = .fixed(64) } } });
        harness.ui.text("ab cd ef", .{ .letter_spacing = 2 });
        harness.ui.close();
        const frame = try harness.end();

        var buffer: [256]u8 = undefined;
        try testing.expectEqualStrings(
            \\text 0 0 50 16 "ab cd" spacing=2
            \\text 0 16 20 16 "ef" spacing=2
            \\
        , try support.snapshot(frame, &buffer));
        try expectRect(frame, .of("block"), 0, 0, 64, 32);
    }
}

test "centered spaced lines are centered by their spaced width" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(48) } } });
    ui.text("abc de", .{ .letter_spacing = 4, .alignment = .center });
    ui.close();

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        \\text 6 0 36 16 "abc" spacing=4
        \\text 12 16 24 16 "de" spacing=4
        \\
    , try support.snapshot(try harness.end(), &buffer));
}

test "a steady frame measures nothing new" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    for (0..3) |_| {
        const ui = harness.begin();
        ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(64) } } });
        ui.text("one two three", .{});
        ui.close();
        _ = try harness.end();
    }
    const calls_after_three_frames = harness.ui.measureCalls();

    const ui = harness.begin();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(64) } } });
    ui.text("one two three", .{});
    ui.close();
    _ = try harness.end();
    try testing.expectEqual(calls_after_three_frames, harness.ui.measureCalls());
}

/// `leading_words` moves where every later text's run widths go.
fn declareStringCacheCases(ui: *support.Ui, width: f32, leading_words: usize) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(width) } } });
    ui.text("w w w w w w w w w w"[0 .. 2 * leading_words + 1], .{});
    ui.text("one two three", .{});
    ui.text("one", .{});
    ui.text("a b c d e f g h i j k l m n o p q r s t", .{});
    ui.text("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np\nq", .{ .wrap = .newlines });
    ui.text("one two three", .{ .wrap = .none });
    ui.text("one two three", .{ .size = 32 });
    ui.close();
}

test "a cached string lays out as a freshly measured one, at any width and zoom" {
    var cached: support.Harness = .{};
    try cached.init();
    defer cached.deinit();

    const frames = [_]struct { width: f32, zoom: f32 }{
        .{ .width = 64, .zoom = 1 },
        .{ .width = 64, .zoom = 1 },
        .{ .width = 200, .zoom = 1 },
        .{ .width = 64, .zoom = 2 },
        .{ .width = 64, .zoom = 1 },
    };
    var calls_after_first_frame: u64 = 0;
    for (frames, 0..) |frame_params, index| {
        var fresh: support.Harness = .{};
        try fresh.init();
        defer fresh.deinit();

        var expected_buffer: [2048]u8 = undefined;
        var actual_buffer: [2048]u8 = undefined;
        const record: zui.FrameRecord = .{ .params = .{ .now = .zero, .viewport = .{ 800, 600 }, .zoom = frame_params.zoom } };
        fresh.ui.beginFrame(&record);
        declareStringCacheCases(&fresh.ui, frame_params.width, index);
        const expected = try support.snapshot(try fresh.end(), &expected_buffer);
        cached.ui.beginFrame(&record);
        declareStringCacheCases(&cached.ui, frame_params.width, index);
        try testing.expectEqualStrings(expected, try support.snapshot(try cached.end(), &actual_buffer));

        if (index == 0) calls_after_first_frame = cached.ui.measureCalls();
        if (index == 1 or index == 2) try testing.expectEqual(calls_after_first_frame, cached.ui.measureCalls());
    }
}

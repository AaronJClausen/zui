const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

test "init makes exactly one allocation, of required_bytes" {
    var text_contract: support.FixedMetricsText = .{};

    var no_allocations: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, support.Ui.init(no_allocations.allocator(), testing.io, &text_contract));

    var one_allocation: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var ui = try support.Ui.init(one_allocation.allocator(), testing.io, &text_contract);
    defer ui.deinit(one_allocation.allocator());
    try testing.expectEqual(@as(usize, 1), one_allocation.allocations);
    try testing.expectEqual(support.Ui.required_bytes, one_allocation.allocated_bytes);
}

test "frames run with no allocator at all" {
    var text_contract: support.FixedMetricsText = .{};
    const buffer = try testing.allocator.alignedAlloc(u8, .fromByteUnits(support.Ui.buffer_alignment), support.Ui.required_bytes);
    defer testing.allocator.free(buffer);

    try testing.expectError(error.BufferTooSmall, support.Ui.initBuffer(buffer[0 .. buffer.len - 1], testing.io, &text_contract));
    var ui = try support.Ui.initBuffer(buffer, testing.io, &text_contract);
    defer ui.deinit(testing.allocator);

    for (0..100) |frame_number| {
        ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 640, 480 } } });
        ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .all(4) }, .decoration = .{ .background = .black } });
        ui.text("frames need no allocator", .{});
        ui.box(.{ .id = .indexed("cell", frame_number), .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } } });
        ui.close();
        ui.release(ui.endFrame());
    }
}

test "two frames can be held at once, and release recycles them" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    harness.ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    const first = harness.ui.endFrame();
    harness.ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 200, 200 } } });
    const second = harness.ui.endFrame();
    try testing.expect(first != second);
    try testing.expectEqual([2]f32{ 100, 100 }, first.params.viewport);

    harness.ui.release(first);
    harness.ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 300, 300 } } });
    const third = harness.ui.endFrame();
    try testing.expectEqual(first, third);
    harness.ui.release(second);
    harness.ui.release(third);
}

const TinyUi = zui.Context(.{
    .limits = .{
        .max_elements = 4,
        .max_text_bytes = 8,
        .max_depth = 3,
        .max_render_commands = 4,
        .measure_cache_entries = 16,
    },
    .Text = support.FixedMetricsText,
});

fn tinyUi(text_contract: *support.FixedMetricsText) !TinyUi {
    return TinyUi.init(testing.allocator, testing.io, text_contract);
}

test "elements past max_elements are dropped and reported" {
    var text_contract: support.FixedMetricsText = .{};
    var ui = try tinyUi(&text_contract);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    for (0..5) |index| ui.box(.{ .id = .indexed("box", index), .decoration = .{ .background = .white }, .layout = .{ .sizing = .{ .width = .fixed(1), .height = .fixed(1) } } });
    const frame = ui.endFrame();

    try testing.expectError(error.CapacityExceeded, frame.diagnostics.check());
    defer ui.release(frame);
    const diagnostics = frame.diagnostics;
    try testing.expect(diagnostics.exceeded.contains(.max_elements));
    try testing.expectEqual(@as(u32, 6), diagnostics.needed.get(.max_elements));
    try testing.expectEqual(zui.Id.indexed("box", 3).hash, diagnostics.first_dropped_id);
    try testing.expectEqual(@as(usize, 3), frame.commands().len);
}

test "a subtree past max_depth is dropped while open and close stay paired" {
    var text_contract: support.FixedMetricsText = .{};
    var ui = try tinyUi(&text_contract);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    ui.open(.{ .id = .of("level1") });
    ui.open(.{ .id = .of("level2") });
    ui.open(.{ .id = .of("level3_dropped") });
    ui.box(.{});
    ui.close();
    ui.close();
    ui.close();
    const frame = ui.endFrame();
    try testing.expectError(error.CapacityExceeded, frame.diagnostics.check());
    defer ui.release(frame);

    try testing.expect(frame.diagnostics.exceeded.contains(.max_depth));
    try testing.expectEqual(@as(u32, 4), frame.diagnostics.needed.get(.max_depth));
    try testing.expect(frame.rectOf(.of("level2")) != null);
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(.of("level3_dropped")));
}

test "text past max_text_bytes is dropped and reported" {
    var text_contract: support.FixedMetricsText = .{};
    var ui = try tinyUi(&text_contract);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    ui.text("12345", .{});
    ui.text("6789", .{});
    const frame = ui.endFrame();
    try testing.expectError(error.CapacityExceeded, frame.diagnostics.check());
    defer ui.release(frame);

    try testing.expect(frame.diagnostics.exceeded.contains(.max_text_bytes));
    try testing.expectEqual(@as(u32, 9), frame.diagnostics.needed.get(.max_text_bytes));
    try testing.expectEqual(@as(usize, 1), frame.commands().len);
}

test "a frame reports only what it asked for, not what the frame before it did" {
    var text_contract: support.FixedMetricsText = .{};
    var ui = try tinyUi(&text_contract);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    ui.text("123456789", .{});
    ui.open(.{});
    ui.open(.{});
    ui.open(.{});
    ui.close();
    ui.close();
    ui.close();
    for (0..3) |_| ui.box(.{});
    const crowded = ui.endFrame();
    try testing.expectError(error.CapacityExceeded, crowded.diagnostics.check());
    ui.release(crowded);

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    ui.box(.{});
    const frame = ui.endFrame();
    defer ui.release(frame);
    const needed = frame.diagnostics.needed;
    try testing.expectEqual(@as(u32, 2), needed.get(.max_elements));
    try testing.expectEqual(@as(u32, 1), needed.get(.max_depth));
    try testing.expectEqual(@as(u32, 0), needed.get(.max_text_bytes));
}

test "commands past max_render_commands are dropped and reported" {
    var text_contract: support.FixedMetricsText = .{};
    var ui = try tinyUi(&text_contract);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    for (0..3) |_| ui.box(.{ .decoration = .{ .background = .white, .border = .{ .color = .black, .widths = .all(1) } }, .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
    const frame = ui.endFrame();
    try testing.expectError(error.CapacityExceeded, frame.diagnostics.check());
    defer ui.release(frame);

    try testing.expect(frame.diagnostics.exceeded.contains(.max_render_commands));
    try testing.expectEqual(@as(u32, 6), frame.diagnostics.needed.get(.max_render_commands));
    try testing.expectEqual(@as(usize, 4), frame.commands().len);
}

// In safe builds the two mistakes below panic with the element's id.
// Release builds recover and report, which these test.

test "release builds close an unbalanced tree and report it" {
    if (std.debug.runtime_safety) return error.SkipZigTest;
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("never_closed"), .layout = .{ .sizing = .{ .width = .fixed(100) } } });
    ui.box(.{ .id = .of("child_of_never_closed"), .layout = .{ .sizing = .{ .width = .grow } } });
    const frame = ui.endFrame();
    try testing.expectError(error.UnbalancedTree, frame.diagnostics.check());
    try testing.expect(frame.diagnostics.unbalanced);
    try testing.expect(frame.rectOf(.of("never_closed")) != null);
    try testing.expectEqual(@as(f32, 100), frame.rectOf(.of("child_of_never_closed")).?.width);
    ui.release(frame);
}

test "ids from an earlier use of the same frame memory are forgotten" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    var ui = harness.begin();
    for (0..200) |index| ui.box(.{ .id = .indexed("earlier", index) });
    ui.release(ui.endFrame());

    // With two or three frames in flight, one of these reuses the memory of
    // the frame above, id table included.
    for (0..3) |_| {
        ui = harness.begin();
        ui.box(.{ .id = .indexed("earlier", 150) });
        ui.box(.{ .id = .indexed("later", 0) });
        const frame = ui.endFrame();
        defer ui.release(frame);
        try testing.expectEqual(@as(u32, 0), frame.diagnostics.duplicate_ids);
        try testing.expect(frame.rectOf(.indexed("earlier", 150)) != null);
        try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(.indexed("earlier", 1)));
        try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(.indexed("earlier", 199)));
    }
}

test "release builds count duplicate ids" {
    if (std.debug.runtime_safety) return error.SkipZigTest;
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.box(.{ .id = .of("twice") });
    ui.box(.{ .id = .of("twice") });
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expectEqual(@as(u32, 1), frame.diagnostics.duplicate_ids);
}

//! Memory discipline and the defined behavior at every capacity limit.

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

test "init makes exactly one allocation, of required_bytes" {
    var platform: support.TestPlatform = .{};

    var no_allocations: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, support.Ui.init(no_allocations.allocator(), testing.io, &platform));

    var one_allocation: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var ui = try support.Ui.init(one_allocation.allocator(), testing.io, &platform);
    defer ui.deinit(one_allocation.allocator());
    try testing.expectEqual(@as(usize, 1), one_allocation.allocations);
    try testing.expectEqual(support.Ui.required_bytes, one_allocation.allocated_bytes);
}

test "frames run with no allocator at all" {
    var platform: support.TestPlatform = .{};
    const buffer = try testing.allocator.alignedAlloc(u8, .@"16", support.Ui.required_bytes);
    defer testing.allocator.free(buffer);

    try testing.expectError(error.BufferTooSmall, support.Ui.initBuffer(buffer[0 .. buffer.len - 1], testing.io, &platform));
    var ui = try support.Ui.initBuffer(buffer, testing.io, &platform);
    defer ui.deinit(testing.allocator);

    for (0..100) |frame_number| {
        ui.beginFrame(.{ .viewport = .{ 640, 480 } });
        ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .all(4) }, .background = .black });
        ui.text("frames need no allocator", .{});
        ui.box(.{ .id = .indexed("cell", frame_number), .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } } });
        ui.close();
        ui.release(try ui.endFrame());
    }
}

test "two frames can be held at once, and release recycles them" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    harness.ui.beginFrame(.{ .viewport = .{ 100, 100 } });
    const first = try harness.ui.endFrame();
    harness.ui.beginFrame(.{ .viewport = .{ 200, 200 } });
    const second = try harness.ui.endFrame();
    try testing.expect(first != second);
    try testing.expectEqual([2]f32{ 100, 100 }, first.viewport);

    harness.ui.release(first);
    harness.ui.beginFrame(.{ .viewport = .{ 300, 300 } });
    const third = try harness.ui.endFrame();
    try testing.expectEqual(first, third);
    harness.ui.release(second);
    harness.ui.release(third);
}

const TinyUi = zui.Context(.{
    .max_elements = 4,
    .max_text_bytes = 8,
    .max_depth = 3,
    .max_render_commands = 4,
    .measure_cache_entries = 16,
}, support.TestPlatform);

fn tinyUi(platform: *support.TestPlatform) !TinyUi {
    return TinyUi.init(testing.allocator, testing.io, platform);
}

test "elements past max_elements are dropped and reported" {
    var platform: support.TestPlatform = .{};
    var ui = try tinyUi(&platform);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(.{ .viewport = .{ 100, 100 } });
    for (0..5) |index| ui.box(.{ .id = .indexed("box", index), .background = .white, .layout = .{ .sizing = .{ .width = .fixed(1), .height = .fixed(1) } } });
    try testing.expectError(error.CapacityExceeded, ui.endFrame());

    const frame = ui.lastFrame();
    defer ui.release(frame);
    const diagnostics = ui.diagnostics();
    try testing.expect(diagnostics.exceeded.contains(.elements));
    try testing.expectEqual(@as(u32, 6), diagnostics.needed.get(.elements));
    try testing.expectEqual(zui.Id.indexed("box", 3).hash, diagnostics.first_dropped_id);
    try testing.expectEqual(@as(usize, 3), frame.commands().len);
    try testing.expectEqualStrings("max_elements", zui.Limit.elements.configField());
}

test "a subtree past max_depth is dropped while open and close stay paired" {
    var platform: support.TestPlatform = .{};
    var ui = try tinyUi(&platform);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(.{ .viewport = .{ 100, 100 } });
    ui.open(.{ .id = .of("level1") });
    ui.open(.{ .id = .of("level2") });
    ui.open(.{ .id = .of("level3_dropped") });
    ui.box(.{});
    ui.close();
    ui.close();
    ui.close();
    try testing.expectError(error.CapacityExceeded, ui.endFrame());
    const frame = ui.lastFrame();
    defer ui.release(frame);

    try testing.expect(ui.diagnostics().exceeded.contains(.depth));
    try testing.expectEqual(@as(u32, 4), ui.diagnostics().needed.get(.depth));
    try testing.expect(frame.rectOf(.of("level2")) != null);
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(.of("level3_dropped")));
}

test "text past max_text_bytes is dropped and reported" {
    var platform: support.TestPlatform = .{};
    var ui = try tinyUi(&platform);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(.{ .viewport = .{ 100, 100 } });
    ui.text("12345", .{});
    ui.text("6789", .{});
    try testing.expectError(error.CapacityExceeded, ui.endFrame());
    const frame = ui.lastFrame();
    defer ui.release(frame);

    try testing.expect(ui.diagnostics().exceeded.contains(.text_bytes));
    try testing.expectEqual(@as(u32, 9), ui.diagnostics().needed.get(.text_bytes));
    try testing.expectEqual(@as(usize, 1), frame.commands().len);
}

test "a frame reports only what it asked for, not what the frame before it did" {
    var platform: support.TestPlatform = .{};
    var ui = try tinyUi(&platform);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(.{ .viewport = .{ 100, 100 } });
    ui.text("123456789", .{});
    ui.open(.{});
    ui.open(.{});
    ui.open(.{});
    ui.close();
    ui.close();
    ui.close();
    for (0..3) |_| ui.box(.{});
    try testing.expectError(error.CapacityExceeded, ui.endFrame());
    ui.release(ui.lastFrame());

    ui.beginFrame(.{ .viewport = .{ 100, 100 } });
    ui.box(.{});
    const frame = try ui.endFrame();
    defer ui.release(frame);
    const needed = ui.diagnostics().needed;
    try testing.expectEqual(@as(u32, 2), needed.get(.elements));
    try testing.expectEqual(@as(u32, 1), needed.get(.depth));
    try testing.expectEqual(@as(u32, 0), needed.get(.text_bytes));
}

test "commands past max_render_commands are dropped and reported" {
    var platform: support.TestPlatform = .{};
    var ui = try tinyUi(&platform);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(.{ .viewport = .{ 100, 100 } });
    for (0..3) |_| ui.box(.{ .background = .white, .border = .{ .color = .black, .widths = .all(1) }, .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
    try testing.expectError(error.CapacityExceeded, ui.endFrame());
    const frame = ui.lastFrame();
    defer ui.release(frame);

    try testing.expect(ui.diagnostics().exceeded.contains(.render_commands));
    try testing.expectEqual(@as(u32, 6), ui.diagnostics().needed.get(.render_commands));
    try testing.expectEqual(@as(usize, 4), frame.commands().len);
}

// In safe builds the two mistakes below panic with the element's id (see
// SPEC.md §13.1). Release builds recover and report, which these test.

test "release builds close an unbalanced tree and report it" {
    if (std.debug.runtime_safety) return error.SkipZigTest;
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .id = .of("never_closed"), .layout = .{ .sizing = .{ .width = .fixed(100) } } });
    ui.box(.{ .id = .of("child_of_never_closed"), .layout = .{ .sizing = .{ .width = .grow } } });
    try testing.expectError(error.UnbalancedTree, ui.endFrame());
    try testing.expect(ui.diagnostics().unbalanced);
    try testing.expect(ui.lastFrame().rectOf(.of("never_closed")) != null);
    try testing.expectEqual(@as(f32, 100), ui.lastFrame().rectOf(.of("child_of_never_closed")).?.width);
    ui.release(ui.lastFrame());
}

test "release builds count duplicate ids" {
    if (std.debug.runtime_safety) return error.SkipZigTest;
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.box(.{ .id = .of("twice") });
    ui.box(.{ .id = .of("twice") });
    const frame = try ui.endFrame();
    defer ui.release(frame);
    try testing.expectEqual(@as(u32, 1), ui.diagnostics().duplicate_ids);
}

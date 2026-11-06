const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;
const Io = std.Io;

test "nextFrame: on input only, unless a frame is requested now or later" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = harness.begin();
    _ = try harness.end();
    try testing.expectEqual(zui.NextFrame.on_event, harness.ui.nextFrame());

    var ui = harness.begin();
    ui.requestFrame();
    _ = try harness.end();
    try testing.expectEqual(zui.NextFrame.immediately, harness.ui.nextFrame());

    ui = harness.begin();
    const blink = ui.now().addSeconds(0.5);
    ui.requestFrameAt(ui.now().addSeconds(2));
    ui.requestFrameAt(blink);
    _ = try harness.end();
    try testing.expectEqual(zui.NextFrame{ .at = blink }, harness.ui.nextFrame());

    _ = harness.begin();
    _ = try harness.end();
    try testing.expectEqual(zui.NextFrame.on_event, harness.ui.nextFrame());
}

test "dt is the time between two records" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    try testing.expectEqual(@as(f32, 0), harness.begin().dt());
    _ = try harness.end();
    const ui = harness.begin();
    try testing.expectApproxEqAbs(@as(f32, 0.016), ui.dt(), 1e-6);
    _ = try harness.end();
}

test "frames are numbered from 0" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    _ = harness.begin();
    try testing.expectEqual(@as(u64, 0), (try harness.end()).number);
    _ = harness.begin();
    try testing.expectEqual(@as(u64, 1), (try harness.end()).number);
}

test "commands snap to physical pixels at scale times zoom" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    for ([_]f32{ 1, 2 }) |scale| {
        harness.ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 10 }, .scale = scale } });
        harness.ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(10) } } });
        for (0..3) |_| harness.ui.box(.{ .decoration = .{ .background = .white }, .layout = .{ .sizing = .{ .width = .grow, .height = .grow } } });
        harness.ui.close();
        const frame = try harness.end();

        var widths: [3]f32 = undefined;
        for (frame.commands(), &widths) |command, *width| width.* = command.bounds.width;
        const expected: [3]f32 = if (scale == 1) .{ 33, 34, 33 } else .{ 33.5, 33, 33.5 };
        try testing.expectEqual(expected, widths);
        try testing.expectEqual(@as(f32, 100), frame.commands()[2].bounds.x + frame.commands()[2].bounds.width);
    }
}

test "zoom measures text at the zoomed size and keeps layout in layout units" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    for ([_]f32{ 0.5, 1, 2 }) |zoom| {
        harness.ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 400, 300 }, .zoom = zoom } });
        harness.ui.open(.{ .id = .of("label") });
        harness.ui.text("zoomed", .{});
        harness.ui.close();
        try support.expectRect(try harness.end(), .of("label"), 0, 0, 48, 16);
    }
}

test "tryBeginFrame refuses instead of waiting" {
    var ui = try SingleFrameUi.init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);

    const record: zui.FrameRecord = .{ .params = .{ .now = .zero, .viewport = .{ 10, 10 } } };
    try ui.tryBeginFrame(&record);
    const held = ui.endFrame();
    try testing.expectError(error.NoFreeFrame, ui.tryBeginFrame(&record));
    ui.release(held);
    try ui.tryBeginFrame(&record);
    ui.release(ui.endFrame());
}

const SingleFrameUi = zui.Context(.{ .limits = .{ .max_elements = 16 }, .frames_in_flight = 1 });

fn releaseLater(io: Io, ui: *SingleFrameUi, frame: *const SingleFrameUi.Frame) void {
    io.sleep(.fromMilliseconds(30), .awake) catch {};
    ui.release(frame);
}

test "beginFrame waits until a render thread releases a frame" {
    var ui = try SingleFrameUi.init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);

    const record: zui.FrameRecord = .{ .params = .{ .now = .zero, .viewport = .{ 10, 10 } } };
    ui.beginFrame(&record);
    const held = ui.endFrame();
    var render_thread = try testing.io.concurrent(releaseLater, .{ testing.io, &ui, held });

    const start: Io.Timestamp = .now(testing.io, .awake);
    ui.beginFrame(&record); // blocks until releaseLater runs
    const waited = start.untilNow(testing.io, .awake);
    render_thread.await(testing.io);
    ui.release(ui.endFrame());

    try testing.expect(waited.toMilliseconds() >= 20);
}

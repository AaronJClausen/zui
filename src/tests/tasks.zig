//! Task pools, needsFrame, and frames held by another thread (SPEC.md §10).

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;
const Io = std.Io;
const Ui = support.Ui;

fn doubleAfterAMoment(io: Io, value: u32) u32 {
    io.sleep(.fromMilliseconds(1), .awake) catch {};
    return value * 2;
}

fn failAfterAMoment(io: Io) error{Broken}!u32 {
    io.sleep(.fromMilliseconds(1), .awake) catch {};
    return error.Broken;
}

/// Sleeps far longer than any test should take; only cancelation ends it early.
fn waitForCancelation(io: Io, value: u32) Io.Cancelable!u32 {
    try io.sleep(.fromSeconds(30), .awake);
    return value;
}

/// Runs frames that request `id` until the pool reports something other
/// than `.pending`, or gives up after about two seconds.
fn requestUntilSettled(harness: *support.Harness, pool: anytype, id: zui.Id, comptime function: anytype, arguments: anytype) !@TypeOf(pool.*).PoolStatus {
    for (0..2000) |_| {
        const ui = harness.begin();
        const status = pool.request(ui, id, function, arguments, .{});
        _ = try harness.end();
        if (status != .pending) return status;
        testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.TaskNeverSettled;
}

test "a task runs in the background and its result appears at a frame boundary" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    var pool: zui.TaskPool(u32, 4) = .init;
    defer pool.deinit(&harness.ui);

    const id: zui.Id = .of("answer");
    const ui = harness.begin();
    try testing.expectEqual(.pending, std.meta.activeTag(pool.request(ui, id, doubleAfterAMoment, .{ testing.io, 21 }, .{})));
    _ = try harness.end();

    const settled = try requestUntilSettled(&harness, &pool, id, doubleAfterAMoment, .{ testing.io, 21 });
    try testing.expectEqual(@as(u32, 42), settled.ready);
    try testing.expectEqual(@as(u64, 1), pool.stats.started);
    try testing.expectEqual(@as(u64, 1), pool.stats.completed);
}

test "an error result comes back as .failed" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    var pool: zui.TaskPool(error{Broken}!u32, 2) = .init;
    defer pool.deinit(&harness.ui);

    const settled = try requestUntilSettled(&harness, &pool, .of("broken"), failAfterAMoment, .{testing.io});
    try testing.expectEqual(error.Broken, settled.failed);
}

test "an infallible pool has no .failed state to handle" {
    const InfallibleStatus = zui.TaskPool(u32, 1).PoolStatus;
    const FallibleStatus = zui.TaskPool(error{Broken}!u32, 1).PoolStatus;
    try testing.expectEqual(@as(usize, 2), @typeInfo(InfallibleStatus).@"union".fields.len);
    try testing.expectEqual(@as(usize, 3), @typeInfo(FallibleStatus).@"union".fields.len);
}

var discarded_results: u32 = 0;

fn countDiscard(_: Io.Cancelable!u32) void {
    discarded_results += 1;
}

test "a task whose element disappears is canceled at endFrame" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    var pool: zui.TaskPool(Io.Cancelable!u32, 4) = .{ .discard = countDiscard };
    defer pool.deinit(&harness.ui);
    discarded_results = 0;

    const start: Io.Timestamp = .now(testing.io, .awake);
    var ui = harness.begin();
    _ = pool.request(ui, .of("offscreen"), waitForCancelation, .{ testing.io, 7 }, .{});
    _ = try harness.end();

    ui = harness.begin(); // the element is no longer declared
    _ = try harness.end();

    try testing.expectEqual(@as(u64, 1), pool.stats.canceled);
    try testing.expectEqual(@as(u32, 1), discarded_results);
    // Canceling interrupted the 30-second sleep.
    try testing.expect(start.untilNow(testing.io, .awake).toSeconds() < 10);
}

test "a different key for the same id restarts the task" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    var pool: zui.TaskPool(Io.Cancelable!u32, 4) = .init;
    defer pool.deinit(&harness.ui);

    const id: zui.Id = .of("photo");
    var ui = harness.begin();
    _ = pool.request(ui, id, waitForCancelation, .{ testing.io, 1 }, .{ .key = 1 });
    _ = try harness.end();

    var settled: ?u32 = null;
    for (0..2000) |_| {
        ui = harness.begin();
        const status = pool.request(ui, id, doubleAfterAMomentCancelable, .{ testing.io, 50 }, .{ .key = 2 });
        _ = try harness.end();
        if (status == .ready) {
            settled = status.ready;
            break;
        }
        testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expectEqual(@as(?u32, 100), settled);
    try testing.expectEqual(@as(u64, 1), pool.stats.canceled);
    try testing.expectEqual(@as(u64, 2), pool.stats.started);
}

test "a canceled task's late completion does not count for its replacement" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    var pool: zui.TaskPool(Io.Cancelable!u32, 1) = .init;
    defer pool.deinit(&harness.ui);

    const id: zui.Id = .of("reused_slot");
    var ui = harness.begin();
    _ = pool.request(ui, id, waitForCancelation, .{ testing.io, 1 }, .{ .key = 1 });
    _ = try harness.end();

    // The canceled task queues its completion while being canceled. If that
    // completion were credited to the replacement in the same slot, request
    // would wait for the replacement's 30-second sleep to finish.
    const start: Io.Timestamp = .now(testing.io, .awake);
    ui = harness.begin();
    const status = pool.request(ui, id, waitForCancelation, .{ testing.io, 2 }, .{ .key = 2 });
    _ = try harness.end();
    try testing.expectEqual(.pending, std.meta.activeTag(status));
    try testing.expect(start.untilNow(testing.io, .awake).toSeconds() < 10);
}

fn doubleAfterAMomentCancelable(io: Io, value: u32) Io.Cancelable!u32 {
    try io.sleep(.fromMilliseconds(1), .awake);
    return value * 2;
}

test "a full pool keeps new requests pending and counts them" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    var pool: zui.TaskPool(Io.Cancelable!u32, 1) = .init;
    defer pool.deinit(&harness.ui);

    const ui = harness.begin();
    _ = pool.request(ui, .of("first"), waitForCancelation, .{ testing.io, 1 }, .{});
    const second = pool.request(ui, .of("second"), waitForCancelation, .{ testing.io, 2 }, .{});
    _ = try harness.end();
    try testing.expectEqual(.pending, std.meta.activeTag(second));
    try testing.expectEqual(@as(u64, 1), pool.stats.rejected);
}

test "without concurrency, a task runs inline and is ready at the next beginFrame" {
    var single_threaded: Io.Threaded = .init_single_threaded;
    defer single_threaded.deinit();
    const io = single_threaded.io();

    var platform: support.TestPlatform = .{};
    var ui = try Ui.init(testing.allocator, io, &platform);
    defer ui.deinit(testing.allocator);
    var pool: zui.TaskPool(u32, 2) = .init;
    defer pool.deinit(&ui);

    ui.beginFrame(.{ .viewport = .{ 100, 100 } });
    const first = pool.request(&ui, .of("inline"), doubleAfterAMoment, .{ io, 4 }, .{});
    ui.release(try ui.endFrame());
    try testing.expectEqual(.pending, std.meta.activeTag(first));
    try testing.expectEqual(@as(u64, 1), pool.stats.started);
    try testing.expect(ui.needsFrame());

    ui.beginFrame(.{ .viewport = .{ 100, 100 } });
    const second = pool.request(&ui, .of("inline"), doubleAfterAMoment, .{ io, 4 }, .{});
    ui.release(try ui.endFrame());
    try testing.expectEqual(@as(u32, 8), second.ready);
}

test "every request in a frame sees the pool as it was at beginFrame" {
    const WakingUi = zui.Context(.{ .max_elements = 16 }, WakingPlatform);
    var platform: WakingPlatform = .{};
    var ui = try WakingUi.init(testing.allocator, testing.io, &platform);
    defer ui.deinit(testing.allocator);
    var pool: zui.TaskPool(u32, 1) = .init;
    defer pool.deinit(&ui);
    const id: zui.Id = .of("mid_frame");

    ui.beginFrame(.{ .viewport = .{ 10, 10 } });
    const before_completion = pool.request(&ui, id, doubleAfterAMoment, .{ testing.io, 5 }, .{});
    var waited: u32 = 0;
    while (platform.wakes.load(.acquire) == 0 and waited < 2000) : (waited += 1) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    try testing.expectEqual(@as(u32, 1), platform.wakes.load(.acquire)); // the task has completed
    const after_completion = pool.request(&ui, id, doubleAfterAMoment, .{ testing.io, 5 }, .{});
    ui.release(try ui.endFrame());
    try testing.expectEqual(.pending, std.meta.activeTag(before_completion));
    try testing.expectEqual(.pending, std.meta.activeTag(after_completion));

    ui.beginFrame(.{ .viewport = .{ 10, 10 } });
    const next_frame = pool.request(&ui, id, doubleAfterAMoment, .{ testing.io, 5 }, .{});
    ui.release(try ui.endFrame());
    try testing.expectEqual(@as(u32, 10), next_frame.ready);
    try testing.expectEqual(@as(u64, 1), pool.stats.completed);
}

const needs_frame_button: zui.Id = .of("button");

test "needsFrame: after input that changed something, a completed task, or a request" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    var pool: zui.TaskPool(u32, 2) = .init;
    defer pool.deinit(&harness.ui);

    const declare = struct {
        fn declare(ui: *Ui) void {
            ui.box(.{ .id = needs_frame_button, .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(50), .height = .fixed(50) } } });
        }
    }.declare;

    for (0..2) |_| {
        declare(harness.beginWith(.{ .pointer = .{ 400, 400 } }));
        _ = try harness.end();
    }
    try testing.expect(!harness.ui.needsFrame()); // nothing changed: sleep

    declare(harness.beginWith(.{ .pointer = .{ 10, 10 } }));
    _ = try harness.end();
    try testing.expect(harness.ui.needsFrame()); // hover moved onto the button

    declare(harness.beginWith(.{ .pointer = .{ 10, 10 } }));
    _ = try harness.end();
    try testing.expect(!harness.ui.needsFrame());

    const ui = harness.beginWith(.{ .pointer = .{ 10, 10 } });
    declare(ui);
    ui.requestFrame();
    _ = try harness.end();
    try testing.expect(harness.ui.needsFrame());

    const task_ui = harness.beginWith(.{ .pointer = .{ 10, 10 } });
    declare(task_ui);
    _ = pool.request(task_ui, .of("task"), doubleAfterAMoment, .{ testing.io, 1 }, .{});
    _ = try harness.end();
    var waited: u32 = 0;
    while (!harness.ui.needsFrame() and waited < 2000) : (waited += 1) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    try testing.expect(harness.ui.needsFrame()); // the completion asks for a frame
}

const WakingPlatform = struct {
    wakes: std.atomic.Value(u32) = .init(0),

    pub fn measureText(_: *WakingPlatform, text: []const u8, _: u16, size: f32) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * size / 2, size };
    }

    pub fn wake(self: *WakingPlatform) void {
        _ = self.wakes.fetchAdd(1, .acq_rel);
    }
};

test "a completed task wakes the platform" {
    const WakingUi = zui.Context(.{ .max_elements = 16 }, WakingPlatform);
    var platform: WakingPlatform = .{};
    var ui = try WakingUi.init(testing.allocator, testing.io, &platform);
    defer ui.deinit(testing.allocator);
    var pool: zui.TaskPool(u32, 1) = .init;
    defer pool.deinit(&ui);

    ui.beginFrame(.{ .viewport = .{ 10, 10 } });
    _ = pool.request(&ui, .of("wake"), doubleAfterAMoment, .{ testing.io, 3 }, .{});
    ui.release(try ui.endFrame());
    var waited: u32 = 0;
    while (platform.wakes.load(.acquire) == 0 and waited < 2000) : (waited += 1) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    try testing.expectEqual(@as(u32, 1), platform.wakes.load(.acquire));
}

const SingleFrameUi = zui.Context(.{ .max_elements = 16, .frames_in_flight = 1 }, support.TestPlatform);

fn releaseLater(io: Io, ui: *SingleFrameUi, frame: *const SingleFrameUi.Frame) void {
    io.sleep(.fromMilliseconds(30), .awake) catch {};
    ui.release(frame);
}

test "beginFrame waits until a render thread releases a frame" {
    var platform: support.TestPlatform = .{};
    var ui = try SingleFrameUi.init(testing.allocator, testing.io, &platform);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(.{ .viewport = .{ 10, 10 } });
    const held = try ui.endFrame();
    var render_thread = try testing.io.concurrent(releaseLater, .{ testing.io, &ui, held });

    const start: Io.Timestamp = .now(testing.io, .awake);
    ui.beginFrame(.{ .viewport = .{ 10, 10 } }); // blocks until releaseLater runs
    const waited = start.untilNow(testing.io, .awake);
    render_thread.await(testing.io);
    ui.release(try ui.endFrame());

    try testing.expect(waited.toMilliseconds() >= 20);
}

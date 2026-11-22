//! zui's tour for a browser's Web Worker, on memory shared with the
//! workers its tasks run on. `web/tour_worker.mjs` instantiates it, starts
//! a worker per thread that calls `zuiTourRunThread` on a stack of its own,
//! and then, once per frame, hands over the page's records, instant and
//! draw time and posts back the wire bytes `zuiTourFrame` wrote. The module
//! imports `performanceNow`, the worker's `performance.now()`, which times
//! the tour's frames.

const std = @import("std");
const builtin = @import("builtin");
const SteppedIo = @import("stepped_io.zig").SteppedIo;
const shared_memory = @import("shared_memory.zig");
const tour_session = @import("tour_session.zig");
const TourSession = tour_session.TourSession;

/// A worker has no stderr; what the tour and `zui_app` log is dropped.
pub const std_options: std.Options = .{ .logFn = dropLog };

fn dropLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

comptime {
    std.debug.assert(!builtin.single_threaded);
}

const thread_count = TourSession.thread_count;
const growing_allocator = shared_memory.growing_allocator;

var stepped: SteppedIo = undefined;
var session: TourSession = undefined;
var thread_memory: shared_memory.ThreadMemory = .{};
var error_name: [*:0]const u8 = "";

extern "env" fn performanceNow() f64;

/// Reserves the tour's memory. False, with `zuiTourErrorName` saying why,
/// if it did not fit. With `steady_timings`, the tour's frames are timed
/// as `tour-frames` times them natively, so the two draw the same bytes,
/// rather than by `performanceNow`.
export fn zuiTourInit(steady_timings: bool) bool {
    initialize(if (steady_timings) .{ .steady = .{} } else .{ .clock = performanceNow }) catch |err| {
        error_name = @errorName(err);
        return false;
    };
    return true;
}

fn initialize(stopwatch: tour_session.Stopwatch) !void {
    thread_memory = try .init(growing_allocator, thread_count);
    stepped = try .init(growing_allocator, shared_memory.futex_io, .{ .thread_count = thread_count });
    try session.init(growing_allocator, &stepped, .{ .stopwatch = stopwatch });
}

export fn zuiTourThreadCount() u32 {
    return thread_count;
}

/// Where thread `index`'s stack starts, for its worker to set
/// `__stack_pointer` to before calling into this module.
export fn zuiTourThreadStackTop(index: u32) usize {
    return thread_memory.stackTop(index);
}

/// The thread-local storage for thread `index`'s worker to pass to
/// `__wasm_init_tls`.
export fn zuiTourThreadLocalStorage(index: u32) usize {
    return thread_memory.threadLocalStorage(index);
}

/// Runs the tour's tasks given to thread `index`; never returns while the
/// tour runs.
export fn zuiTourRunThread(index: u32) void {
    stepped.runThread(index);
}

export fn zuiTourRoomForRecords(count: usize) usize {
    const room = session.roomForRecords(count) catch |err| {
        error_name = @errorName(err);
        return 0;
    };
    return @intFromPtr(room.ptr);
}

export fn zuiTourReceivedRecords(count: usize) void {
    session.receivedRecords(count);
}

var frame_bytes: []const u8 = &.{};

/// Steps the tour to `now_milliseconds` on the page's clock, after the page
/// took `previous_draw_milliseconds` to draw the frame before, and declares
/// a frame if one is due: the count of wire bytes at `zuiTourFrameBytes`, 0
/// before the first record or when no frame was due, or -1 with
/// `zuiTourErrorName` saying why.
export fn zuiTourFrame(now_milliseconds: f64, previous_draw_milliseconds: f64) i32 {
    frame_bytes = (session.frame(now_milliseconds, previous_draw_milliseconds) catch |err| {
        error_name = @errorName(err);
        return -1;
    }) orelse &.{};
    return @intCast(frame_bytes.len);
}

/// The instant on the page's clock, in milliseconds, by which the page must
/// step the tour again: 0 for at once, or infinity if not before input.
export fn zuiTourNextWakeMilliseconds() f64 {
    return switch (session.nextWake()) {
        .immediately => 0,
        .at => |deadline| @as(f64, @floatFromInt(deadline.nanoseconds)) / std.time.ns_per_ms,
        .on_event => std.math.inf(f64),
    };
}

export fn zuiTourFrameBytes() usize {
    return @intFromPtr(frame_bytes.ptr);
}

export fn zuiTourErrorName() [*:0]const u8 {
    return error_name;
}

/// What the tour's strip shows for its newest frame: the microseconds of
/// its beginFrame, declaration and layout together.
export fn zuiTourNewestFrameMicroseconds() f64 {
    return session.perf().latest().totalMicroseconds();
}

export fn zuiTourTasksStarted() f64 {
    return @floatFromInt(stepped.counts.started);
}

export fn zuiTourTasksFinished() f64 {
    return @floatFromInt(stepped.counts.finished);
}

export fn zuiTourTasksRefused() f64 {
    return @floatFromInt(stepped.counts.refused);
}

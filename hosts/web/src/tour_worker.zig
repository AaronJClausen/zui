//! zui-sokol's tour for a browser's Web Worker, on memory shared with the
//! workers its tasks run on. `web/tour_worker.mjs` instantiates it, starts
//! a worker per thread that calls `zuiTourRunThread` on a stack of its own,
//! and then, once per frame, hands over the page's records, instant and
//! draw time and posts back the wire bytes `zuiTourFrame` wrote. The module
//! imports `performanceNow`, the worker's `performance.now()`, which times
//! the tour's frames.

const std = @import("std");
const builtin = @import("builtin");
const SteppedIo = @import("stepped_io.zig").SteppedIo;
const TourSession = @import("tour_session.zig").TourSession;

comptime {
    std.debug.assert(!builtin.single_threaded);
}

const thread_count = TourSession.thread_count;
const thread_stack_bytes = 256 * 1024;
const thread_local_bytes_most = 4096;

var stepped: SteppedIo = undefined;
var session: TourSession = undefined;
var thread_memory: []align(16) u8 = &.{};
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

fn initialize(stopwatch: TourSession.Stopwatch) !void {
    if (threadLocalBytes() > thread_local_bytes_most) return error.ThreadLocalStorageTooLarge;
    thread_memory = try growing_allocator.alignedAlloc(u8, .@"16", thread_count * (thread_stack_bytes + thread_local_bytes_most));
    stepped = try .init(growing_allocator, futex_io, .{ .thread_count = thread_count });
    try session.init(growing_allocator, &stepped, .{ .stopwatch = stopwatch });
}

export fn zuiTourThreadCount() u32 {
    return thread_count;
}

/// Where thread `index`'s stack starts, for its worker to set
/// `__stack_pointer` to before calling into this module.
export fn zuiTourThreadStackTop(index: u32) usize {
    return @intFromPtr(threadMemory(index).ptr) + thread_stack_bytes;
}

/// The thread-local storage for thread `index`'s worker to pass to
/// `__wasm_init_tls`.
export fn zuiTourThreadLocalStorage(index: u32) usize {
    return @intFromPtr(threadMemory(index).ptr) + thread_stack_bytes;
}

fn threadMemory(index: u32) []u8 {
    return thread_memory[index * (thread_stack_bytes + thread_local_bytes_most) ..][0 .. thread_stack_bytes + thread_local_bytes_most];
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

/// Declares the frame at `now_milliseconds` on the page's clock, after the
/// page took `previous_draw_milliseconds` to draw the one before: the count
/// of wire bytes at `zuiTourFrameBytes`, 0 before the first record, or -1
/// with `zuiTourErrorName` saying why.
export fn zuiTourFrame(now_milliseconds: f64, previous_draw_milliseconds: f64) i32 {
    frame_bytes = (session.frame(now_milliseconds, previous_draw_milliseconds) catch |err| {
        error_name = @errorName(err);
        return -1;
    }) orelse &.{};
    return @intCast(frame_bytes.len);
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
    return session.app.perf.latest().totalMicroseconds();
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

fn threadLocalBytes() usize {
    return asm (
        \\ .globaltype __tls_size, i32, immutable
        \\ global.get __tls_size
        \\ local.set %[ret]
        : [ret] "=r" (-> usize),
    );
}

/// The futex the threads take turns by, which only a worker may wait on.
const futex_io: std.Io = .{ .userdata = null, .vtable = &futex_vtable };

const futex_vtable: std.Io.VTable = vtable: {
    var table = std.Io.failing.vtable.*;
    table.futexWaitUncancelable = futexWaitUncancelable;
    table.futexWake = futexWake;
    break :vtable table;
};

fn futexWaitUncancelable(_: ?*anyopaque, futex: *const u32, expected: u32) void {
    _ = asm volatile (
        \\local.get %[futex]
        \\local.get %[expected]
        \\i64.const -1
        \\memory.atomic.wait32 0
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
        : [futex] "r" (futex),
          [expected] "r" (expected),
    );
}

fn futexWake(_: ?*anyopaque, futex: *const u32, max_waiters: u32) void {
    _ = asm volatile (
        \\local.get %[futex]
        \\local.get %[max_waiters]
        \\memory.atomic.notify 0
        \\local.set %[ret]
        : [ret] "=r" (-> u32),
        : [futex] "r" (futex),
          [max_waiters] "r" (max_waiters),
    );
}

/// Takes memory from the end of the module's, growing it, and frees none:
/// only `zuiTourInit` allocates, on the worker the tour runs on.
const growing_allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = growingAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
} };

var growing_end: usize = 0;

fn growingAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const page_bytes = std.wasm.page_size;
    if (growing_end == 0) growing_end = @wasmMemorySize(0) * page_bytes;
    const start = alignment.forward(growing_end);
    const end = start + len;
    const pages_held = @wasmMemorySize(0);
    const pages_needed = std.math.divCeil(usize, end, page_bytes) catch unreachable;
    if (pages_needed > pages_held and @wasmMemoryGrow(0, pages_needed - pages_held) < 0) return null;
    growing_end = end;
    return @ptrFromInt(start);
}

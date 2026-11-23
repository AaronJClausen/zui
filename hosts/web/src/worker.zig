const std = @import("std");
const builtin = @import("builtin");
const zui_app = @import("zui_app");
const SteppedIo = @import("stepped_io.zig").SteppedIo;
const shared_memory = @import("shared_memory.zig");
const browser_host = @import("browser_host.zig");

/// What an application's module in the browser's worker runs on: memory
/// shared with the workers its tasks take turns on, and the `Io` they
/// take turns by. A target's root names `std_options` and `os` from here,
/// and exports the call that runs the application:
///
/// ```zig
/// pub const std_options = zui_web.worker.std_options;
/// pub const os = zui_web.worker.os;
///
/// export fn zuiWebRun() void {
///     const setup = zui_web.worker.setup(.{ .task_threads = 16 }) catch |err| return zui_web.worker.fail(err);
///     zui_app.runWith(App, setup, .{ .title = "editor" }) catch |err| zui_web.worker.fail(err);
/// }
/// ```
pub const Options = struct {
    /// The workers the application's tasks take turns on, one at a time
    /// and only while a turn waits for them.
    task_threads: u32,
};

var stepped: SteppedIo = undefined;
var thread_memory: shared_memory.ThreadMemory = .{};
var task_threads: u32 = 0;

/// Reserves the task threads' stacks and the `SteppedIo`, and returns what
/// `zui_app.runWith` takes. Called once, before the worker starts the
/// threads.
pub fn setup(options: Options) !zui_app.Setup {
    thread_memory = try .init(shared_memory.growing_allocator, options.task_threads);
    stepped = try .init(shared_memory.growing_allocator, shared_memory.futex_io, .{ .thread_count = options.task_threads });
    task_threads = options.task_threads;
    return .{ .gpa = shared_memory.growing_allocator, .io = stepped.io() };
}

/// Keeps `err` for the worker, which reports it once `zuiWebRun` returns
/// rather than yielding.
pub const fail = browser_host.fail;

/// The worker's `performance.now()`, in milliseconds, which moves on within
/// a turn while the `SteppedIo`'s clock stands still: for timing what a
/// turn does, as a `zui_tour.Stopwatch` does.
pub const millisecondsNow = browser_host.BrowserPlatform.zuiWebHostNow;

/// A worker has no stderr; what the application and `zui_app` log is
/// dropped.
pub const std_options: std.Options = .{ .logFn = dropLog };

fn dropLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

/// The module's `std.heap.page_allocator`: the allocator `setup` hands
/// the application, so one allocator alone grows the memory.
pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = shared_memory.growing_allocator;
    };
};

comptime {
    if (builtin.cpu.arch.isWasm() and !builtin.single_threaded) _ = &exports;
}

/// What the worker calls to start the task threads, each a worker of its
/// own that instantiates the module again on the same memory.
const exports = struct {
    export fn zuiWebThreadCount() u32 {
        return task_threads;
    }

    /// Where thread `index`'s stack starts, for its worker to set
    /// `__stack_pointer` to before calling into the module.
    export fn zuiWebThreadStackTop(index: u32) usize {
        return thread_memory.stackTop(index);
    }

    /// The thread-local storage for thread `index`'s worker to pass to
    /// `__wasm_init_tls`.
    export fn zuiWebThreadLocalStorage(index: u32) usize {
        return thread_memory.threadLocalStorage(index);
    }

    /// Runs the tasks given to thread `index`; never returns while the
    /// application runs.
    export fn zuiWebRunThread(index: u32) void {
        stepped.runThread(index);
    }

    /// The application's tasks started so far, for a check to read.
    export fn zuiWebTasksStarted() f64 {
        return @floatFromInt(stepped.counts.started);
    }

    /// The application's tasks finished so far, for a check to read.
    export fn zuiWebTasksFinished() f64 {
        return @floatFromInt(stepped.counts.finished);
    }
};

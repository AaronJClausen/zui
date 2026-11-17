const std = @import("std");
const Io = std.Io;

/// An `Io` for a loop that owns the clock, as a browser's worker does:
/// every clock reads the instant the last `step` set, and the tasks
/// started with `Group.concurrent` take turns on a fixed set of threads,
/// one at a time and only while the loop waits for them, so a loop given
/// the same instants and input draws the same frames on any machine. A
/// task runs as it starts until it first waits, unless every thread is
/// taken, when it waits for one. The owner starts the threads, each
/// calling `runThread`, before the first step; `turns` is an `Io` whose
/// futex the threads block on. Memory is reserved by `init`.
///
/// ```zig
/// var stepped: SteppedIo = try .init(gpa, threaded.io(), .{ .thread_count = 4 });
/// var threads: [4]std.Thread = undefined;
/// for (&threads, 0..) |*thread, index| thread.* = try .spawn(.{}, SteppedIo.runThread, .{ &stepped, index });
/// while (running) {
///     stepped.step(page_clock_nanoseconds);
///     ui.beginFrame(&record, &sources); // declared on `stepped.io()`
///     // ...
/// }
/// app.deinit(); // cancels the app's groups
/// stepped.stopThreads();
/// for (threads) |thread| thread.join();
/// ```
pub const SteppedIo = struct {
    turns: Io,
    tasks: []Task,
    threads: []Thread,
    clock_nanoseconds: i96 = 0,
    /// The task whose turn it is, or null while the loop that steps runs.
    running: ?*Task = null,
    stepper_turn: std.atomic.Value(u32) = .init(0),
    next_sequence: u64 = 0,
    stepper_cancel_protection: Io.CancelProtection = .unblocked,
    counts: Counts = .{},

    pub const Options = struct {
        thread_count: u32,
        /// Tasks started and not yet finished, queued for a thread or on one.
        task_capacity: u32 = 512,
    };

    pub const Counts = struct {
        started: u64 = 0,
        finished: u64 = 0,
        /// Tasks `Group.concurrent` failed with `ConcurrencyUnavailable`:
        /// every task slot was taken, or their arguments did not fit one.
        refused: u64 = 0,
    };

    /// The most bytes of arguments a task is started with.
    pub const context_bytes_most = 256;
    const context_alignment_most: std.mem.Alignment = .@"16";

    const Task = struct {
        state: State = .free,
        /// The order tasks were started in, which orders the turns of
        /// tasks that woke at the same instant.
        sequence: u64 = 0,
        group: *Io.Group = undefined,
        start: *const fn (context: *const anyopaque) void = undefined,
        context: [context_bytes_most]u8 align(context_alignment_most.toByteUnits()) = undefined,
        thread: ?*Thread = null,
        /// While sleeping or waiting: when the clock wakes it.
        wake_at: i96 = 0,
        /// While waiting: the futex it waits on.
        futex: *const u32 = undefined,
        cancelable_wait: bool = false,
        woken: bool = false,
        cancel_requested: bool = false,
        cancel_protection: Io.CancelProtection = .unblocked,

        const State = enum { free, queued, sleeping, waiting, running };

        fn sees(task: *const Task) bool {
            return task.cancel_requested and task.cancel_protection == .unblocked;
        }

        fn runnable(task: *const Task, clock_nanoseconds: i96) bool {
            return switch (task.state) {
                .free, .running, .queued => false,
                .sleeping => task.wake_at <= clock_nanoseconds or task.sees(),
                .waiting => task.woken or task.wake_at <= clock_nanoseconds or (task.cancelable_wait and task.sees()),
            };
        }
    };

    const Thread = struct {
        turn: std.atomic.Value(u32) = .init(0),
        task: ?*Task = null,
    };

    const never: i96 = std.math.maxInt(i96);

    pub fn init(gpa: std.mem.Allocator, turns: Io, options: Options) std.mem.Allocator.Error!SteppedIo {
        const tasks = try gpa.alloc(Task, options.task_capacity);
        errdefer gpa.free(tasks);
        @memset(tasks, .{});
        const threads = try gpa.alloc(Thread, options.thread_count);
        @memset(threads, .{});
        return .{ .turns = turns, .tasks = tasks, .threads = threads };
    }

    pub fn deinit(self: *SteppedIo, gpa: std.mem.Allocator) void {
        gpa.free(self.threads);
        gpa.free(self.tasks);
    }

    pub fn io(self: *SteppedIo) Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    /// Sets every clock to `now_nanoseconds`, which never goes back, and
    /// gives each task whose sleep has ended, or that was woken or started,
    /// its turn until every task waits for a later instant or another task.
    pub fn step(self: *SteppedIo, now_nanoseconds: i96) void {
        std.debug.assert(self.running == null);
        self.clock_nanoseconds = @max(self.clock_nanoseconds, now_nanoseconds);
        self.takeTurns();
    }

    /// The body of the thread the owner started for `index`: it runs each
    /// task given to it, in turns, until `stopThreads`.
    pub fn runThread(self: *SteppedIo, index: usize) void {
        const thread = &self.threads[index];
        while (true) {
            awaitTurn(self.turns, &thread.turn);
            const task = thread.task orelse return;
            task.start(&task.context);
            self.retire(task);
            handTurn(self.turns, &self.stepper_turn);
        }
    }

    /// Ends every thread's `runThread`, once no task is left: after
    /// every group has been awaited or canceled.
    pub fn stopThreads(self: *SteppedIo) void {
        for (self.tasks) |*task| std.debug.assert(task.state == .free);
        for (self.threads) |*thread| handTurn(self.turns, &thread.turn);
    }

    fn takeTurns(self: *SteppedIo) void {
        while (self.nextTurn()) |task| {
            if (task.thread == null) task.thread = self.idleThread().?;
            task.state = .running;
            task.woken = false;
            task.thread.?.task = task;
            self.running = task;
            handTurn(self.turns, &task.thread.?.turn);
            awaitTurn(self.turns, &self.stepper_turn);
            self.running = null;
        }
    }

    /// The runnable task that woke first, or of those that woke together
    /// the one started first; a queued task runs only once a thread is
    /// idle, and counts as woken now.
    fn nextTurn(self: *SteppedIo) ?*Task {
        const thread_idle = self.idleThread() != null;
        var next: ?*Task = null;
        var next_woke_at: i96 = never;
        for (self.tasks) |*task| {
            const can_run = task.runnable(self.clock_nanoseconds) or (task.state == .queued and thread_idle);
            if (!can_run) continue;
            const woke_at = if (task.state == .queued or task.woken) self.clock_nanoseconds else @min(task.wake_at, self.clock_nanoseconds);
            if (next == null or woke_at < next_woke_at or (woke_at == next_woke_at and task.sequence < next.?.sequence)) {
                next = task;
                next_woke_at = woke_at;
            }
        }
        return next;
    }

    fn idleThread(self: *SteppedIo) ?*Thread {
        for (self.threads) |*thread| {
            if (thread.task == null) return thread;
        }
        return null;
    }

    fn retire(self: *SteppedIo, task: *Task) void {
        const group = task.group;
        task.thread.?.task = null;
        task.* = .{};
        self.counts.finished += 1;
        group.state -= 1;
        if (group.state == 0) {
            group.token.store(null, .release);
            self.wakeWaiters(@ptrCast(&group.state), std.math.maxInt(u32));
        }
    }

    /// From a task: lets the loop that steps, and the tasks after it, run
    /// until this task is given its turn again.
    fn yieldTurn(self: *SteppedIo, task: *Task) void {
        handTurn(self.turns, &self.stepper_turn);
        awaitTurn(self.turns, &task.thread.?.turn);
    }

    fn handTurn(turns: Io, turn: *std.atomic.Value(u32)) void {
        turn.store(1, .release);
        turns.futexWake(u32, &turn.raw, 1);
    }

    fn awaitTurn(turns: Io, turn: *std.atomic.Value(u32)) void {
        while (turn.load(.acquire) == 0) turns.futexWaitUncancelable(u32, &turn.raw, 0);
        turn.store(0, .monotonic);
    }

    fn wakeWaiters(self: *SteppedIo, futex: *const u32, max_waiters: u32) void {
        var woken: u32 = 0;
        while (woken < max_waiters) : (woken += 1) {
            var first: ?*Task = null;
            for (self.tasks) |*task| {
                const waits_here = task.state == .waiting and !task.woken and task.futex == futex;
                if (waits_here and (first == null or task.sequence < first.?.sequence)) first = task;
            }
            (first orelse return).woken = true;
        }
    }

    /// From the loop that steps, which no task runs beside: waits for
    /// `group` by letting its tasks run, moving the clock on to the next
    /// instant one of them sleeps until whenever none can run now.
    fn finishGroup(self: *SteppedIo, group: *Io.Group) void {
        while (group.state != 0) {
            self.takeTurns();
            if (group.state == 0) return;
            var earliest: i96 = never;
            for (self.tasks) |*task| {
                if (task.state == .sleeping or task.state == .waiting) earliest = @min(earliest, task.wake_at);
            }
            if (earliest == never) std.debug.panic("a group's tasks wait on each other, and none can run", .{});
            self.clock_nanoseconds = earliest;
        }
    }

    fn deadlineOf(self: *const SteppedIo, timeout: Io.Timeout) i96 {
        return switch (timeout) {
            .none => never,
            .duration => |duration| self.clock_nanoseconds +| duration.raw.nanoseconds,
            .deadline => |deadline| deadline.raw.nanoseconds,
        };
    }

    fn of(userdata: ?*anyopaque) *SteppedIo {
        return @ptrCast(@alignCast(userdata.?));
    }

    const vtable: Io.VTable = vtable: {
        var table = Io.failing.vtable.*;
        table.groupAsync = groupAsync;
        table.groupConcurrent = groupConcurrent;
        table.groupAwait = groupAwait;
        table.groupCancel = groupCancel;
        table.recancel = recancel;
        table.swapCancelProtection = swapCancelProtection;
        table.checkCancel = checkCancel;
        table.futexWait = futexWait;
        table.futexWaitUncancelable = futexWaitUncancelable;
        table.futexWake = futexWake;
        table.now = now;
        table.clockResolution = clockResolution;
        table.sleep = sleep;
        break :vtable table;
    };

    fn groupAsync(_: ?*anyopaque, _: *Io.Group, context: []const u8, _: std.mem.Alignment, start: *const fn (context: *const anyopaque) void) void {
        start(context.ptr);
    }

    fn groupConcurrent(userdata: ?*anyopaque, group: *Io.Group, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (context: *const anyopaque) void) Io.ConcurrentError!void {
        const self = of(userdata);
        const fits = context.len <= context_bytes_most and context_alignment.order(context_alignment_most) != .gt;
        const task = for (self.tasks) |*task| {
            if (task.state == .free) break task;
        } else null;
        if (!fits or task == null) {
            self.counts.refused += 1;
            return error.ConcurrencyUnavailable;
        }
        task.?.* = .{ .state = .queued, .sequence = self.next_sequence, .group = group, .start = start };
        @memcpy(task.?.context[0..context.len], context);
        self.next_sequence += 1;
        self.counts.started += 1;
        group.state += 1;
        group.token.store(self, .release);
        if (self.running == null) self.takeTurns();
    }

    fn groupAwait(userdata: ?*anyopaque, group: *Io.Group, _: *anyopaque) Io.Cancelable!void {
        const self = of(userdata);
        if (self.running) |task| {
            while (group.state != 0) try self.waitOn(task, @ptrCast(&group.state), never, true);
        } else self.finishGroup(group);
    }

    fn groupCancel(userdata: ?*anyopaque, group: *Io.Group, _: *anyopaque) void {
        const self = of(userdata);
        for (self.tasks) |*task| {
            if (task.state != .free and task.group == group) task.cancel_requested = true;
        }
        if (self.running) |task| {
            while (group.state != 0) self.waitOn(task, @ptrCast(&group.state), never, false) catch unreachable;
        } else self.finishGroup(group);
    }

    fn recancel(userdata: ?*anyopaque) void {
        if (of(userdata).running) |task| task.cancel_requested = true;
    }

    fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
        const self = of(userdata);
        const protection = if (self.running) |task| &task.cancel_protection else &self.stepper_cancel_protection;
        defer protection.* = new;
        return protection.*;
    }

    fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
        const task = of(userdata).running orelse return;
        if (task.sees()) {
            task.cancel_requested = false;
            return error.Canceled;
        }
    }

    fn waitAsTask(self: *SteppedIo, task: *Task, futex: *const u32, expected: u32, wake_at: i96, cancelable: bool) Io.Cancelable!void {
        if (@atomicLoad(u32, futex, .acquire) != expected) return;
        return self.waitOn(task, futex, wake_at, cancelable);
    }

    /// Only one task runs at a time, so nothing can wake `futex` between a
    /// task's check of what it waits for and this.
    fn waitOn(self: *SteppedIo, task: *Task, futex: *const u32, wake_at: i96, cancelable: bool) Io.Cancelable!void {
        if (cancelable) try checkCancel(self);
        task.state = .waiting;
        task.futex = futex;
        task.wake_at = wake_at;
        task.cancelable_wait = cancelable;
        self.yieldTurn(task);
        if (cancelable) try checkCancel(self);
    }

    /// The loop that steps waits by letting the tasks run, and then wakes
    /// as a futex may without being woken.
    fn futexWait(userdata: ?*anyopaque, futex: *const u32, expected: u32, timeout: Io.Timeout) Io.Cancelable!void {
        const self = of(userdata);
        if (self.running) |task| return self.waitAsTask(task, futex, expected, self.deadlineOf(timeout), true);
        self.takeTurns();
    }

    fn futexWaitUncancelable(userdata: ?*anyopaque, futex: *const u32, expected: u32) void {
        const self = of(userdata);
        if (self.running) |task| return self.waitAsTask(task, futex, expected, never, false) catch unreachable;
        self.takeTurns();
    }

    fn futexWake(userdata: ?*anyopaque, futex: *const u32, max_waiters: u32) void {
        of(userdata).wakeWaiters(futex, max_waiters);
    }

    fn now(userdata: ?*anyopaque, _: Io.Clock) Io.Timestamp {
        return .{ .nanoseconds = of(userdata).clock_nanoseconds };
    }

    fn clockResolution(_: ?*anyopaque, _: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
        return .{ .nanoseconds = 1 };
    }

    fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
        const self = of(userdata);
        const task = self.running orelse return;
        try checkCancel(self);
        task.state = .sleeping;
        task.wake_at = self.deadlineOf(timeout);
        self.yieldTurn(task);
        try checkCancel(self);
    }
};

const testing = std.testing;

const TestThreads = struct {
    stepped: SteppedIo,
    threads: []std.Thread,

    fn start(self: *TestThreads, thread_count: u32, task_capacity: u32) !void {
        self.stepped = try .init(testing.allocator, testing.io, .{ .thread_count = thread_count, .task_capacity = task_capacity });
        self.threads = try testing.allocator.alloc(std.Thread, thread_count);
        for (self.threads, 0..) |*thread, index| thread.* = try .spawn(.{}, SteppedIo.runThread, .{ &self.stepped, index });
    }

    fn stop(self: *TestThreads) void {
        self.stepped.stopThreads();
        for (self.threads) |thread| thread.join();
        testing.allocator.free(self.threads);
        self.stepped.deinit(testing.allocator);
    }
};

const milliseconds = std.time.ns_per_ms;

/// Appends its mark each time it wakes, for `wakes` wakes `gap` apart.
fn markEachWake(io: Io, marks: *std.ArrayList(u8), mark: u8, wakes: u32, gap: u64) Io.Cancelable!void {
    for (0..wakes) |_| {
        try io.sleep(.fromNanoseconds(gap), .awake);
        marks.appendBounded(mark) catch unreachable;
    }
}

test "a task sleeps on the clock the steps set, and runs only inside a step" {
    var harness: TestThreads = undefined;
    try harness.start(2, 8);
    defer harness.stop();
    const io = harness.stepped.io();
    var buffer: [16]u8 = undefined;
    var marks: std.ArrayList(u8) = .initBuffer(&buffer);
    var group: Io.Group = .init;
    try group.concurrent(io, markEachWake, .{ io, &marks, 'a', 3, 30 * milliseconds });
    try testing.expectEqual(0, marks.items.len);
    harness.stepped.step(16 * milliseconds);
    try testing.expectEqual(0, marks.items.len);
    harness.stepped.step(33 * milliseconds);
    try testing.expectEqualStrings("a", marks.items);
    try testing.expectEqual(33 * milliseconds, Io.Timestamp.now(io, .awake).nanoseconds);
    harness.stepped.step(200 * milliseconds);
    try testing.expectEqualStrings("aa", marks.items);
    harness.stepped.step(200 * milliseconds);
    try testing.expectEqualStrings("aa", marks.items);
    harness.stepped.step(300 * milliseconds);
    try testing.expectEqualStrings("aaa", marks.items);
    try testing.expectEqual(null, group.token.load(.acquire));
    try testing.expectEqual(1, harness.stepped.counts.finished);
}

test "tasks take turns in the order they started, so every run interleaves them alike" {
    var harness: TestThreads = undefined;
    try harness.start(3, 8);
    defer harness.stop();
    const io = harness.stepped.io();
    var buffer: [16]u8 = undefined;
    var marks: std.ArrayList(u8) = .initBuffer(&buffer);
    var group: Io.Group = .init;
    try group.concurrent(io, markEachWake, .{ io, &marks, 'a', 2, 10 * milliseconds });
    try group.concurrent(io, markEachWake, .{ io, &marks, 'b', 4, 5 * milliseconds });
    try group.concurrent(io, markEachWake, .{ io, &marks, 'c', 1, 10 * milliseconds });
    harness.stepped.step(10 * milliseconds);
    try testing.expectEqualStrings("bac", marks.items);
    harness.stepped.step(20 * milliseconds);
    try testing.expectEqualStrings("bacba", marks.items);
    group.cancel(io);
}

test "more tasks than threads wait for one, and more than the slots are refused" {
    var harness: TestThreads = undefined;
    try harness.start(1, 2);
    defer harness.stop();
    const io = harness.stepped.io();
    var buffer: [16]u8 = undefined;
    var marks: std.ArrayList(u8) = .initBuffer(&buffer);
    var group: Io.Group = .init;
    try group.concurrent(io, markEachWake, .{ io, &marks, 'a', 1, 10 * milliseconds });
    try group.concurrent(io, markEachWake, .{ io, &marks, 'b', 1, 10 * milliseconds });
    try testing.expectError(error.ConcurrencyUnavailable, group.concurrent(io, markEachWake, .{ io, &marks, 'c', 1, 10 * milliseconds }));
    harness.stepped.step(10 * milliseconds);
    try testing.expectEqualStrings("a", marks.items);
    harness.stepped.step(20 * milliseconds);
    try testing.expectEqualStrings("ab", marks.items);
    try testing.expectEqual(SteppedIo.Counts{ .started = 2, .finished = 2, .refused = 1 }, harness.stepped.counts);
}

fn sleepUntilCanceled(io: Io, outcome: *?Io.Cancelable!void) void {
    outcome.* = io.sleep(.fromSeconds(3600), .awake);
}

test "canceling a group ends its sleeping and queued tasks with error.Canceled" {
    var harness: TestThreads = undefined;
    try harness.start(1, 4);
    defer harness.stop();
    const io = harness.stepped.io();
    var outcomes: [2]?Io.Cancelable!void = .{ null, null };
    var group: Io.Group = .init;
    for (&outcomes) |*outcome| try group.concurrent(io, sleepUntilCanceled, .{ io, outcome });
    harness.stepped.step(1);
    try testing.expectEqual(null, outcomes[0]);
    group.cancel(io);
    for (outcomes) |outcome| try testing.expectError(error.Canceled, outcome.?);
}

const Tally = struct {
    mutex: Io.Mutex = .init,
    count: u32 = 0,

    fn countWhileAsleep(tally: *Tally, io: Io) Io.Cancelable!void {
        try tally.mutex.lock(io);
        defer tally.mutex.unlock(io);
        const before = tally.count;
        try io.sleep(.fromNanoseconds(milliseconds), .awake);
        tally.count = before + 1;
    }
};

test "a task waiting for a mutex another holds runs once it is unlocked" {
    var harness: TestThreads = undefined;
    try harness.start(2, 4);
    defer harness.stop();
    const io = harness.stepped.io();
    var tally: Tally = .{};
    var group: Io.Group = .init;
    for (0..2) |_| try group.concurrent(io, Tally.countWhileAsleep, .{ &tally, io });
    harness.stepped.step(1 * milliseconds);
    try testing.expectEqual(1, tally.count);
    harness.stepped.step(2 * milliseconds);
    try testing.expectEqual(2, tally.count);
    try group.await(io);
}

test "awaiting a group from the loop runs the clock on to its tasks' last wake" {
    var harness: TestThreads = undefined;
    try harness.start(1, 4);
    defer harness.stop();
    const io = harness.stepped.io();
    var buffer: [16]u8 = undefined;
    var marks: std.ArrayList(u8) = .initBuffer(&buffer);
    var group: Io.Group = .init;
    try group.concurrent(io, markEachWake, .{ io, &marks, 'a', 3, 10 * milliseconds });
    try group.await(io);
    try testing.expectEqualStrings("aaa", marks.items);
    try testing.expectEqual(30 * milliseconds, Io.Timestamp.now(io, .awake).nanoseconds);
}

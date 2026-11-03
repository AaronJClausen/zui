//! Async work whose lifetime follows an element (SPEC.md §10.3).

const std = @import("std");
const Io = std.Io;
const Id = @import("id.zig").Id;

/// A pool's entry in the Context's list of pools, which the Context walks
/// at `beginFrame` to apply completions and at `endFrame` to cancel the
/// tasks of elements that were not declared.
pub const Registration = struct {
    next: ?*Registration = null,
    apply_completions: *const fn (registration: *Registration) void,
    sweep: *const fn (registration: *Registration, frame_number: u32) void,
    cancel_all: *const fn (registration: *Registration) void,
};

/// Wakes a sleeping event loop when a task completes. Called from task
/// threads.
pub const Waker = struct {
    task_completed: *std.atomic.Value(bool),
    platform: *anyopaque,
    wake: ?*const fn (platform: *anyopaque) void,

    pub fn notify(self: Waker) void {
        self.task_completed.store(true, .release);
        if (self.wake) |wake| wake(self.platform);
    }
};

/// The status union of a pool: `.pending`, `.ready` with the value, and
/// `.failed` with the error only when `Result` is an error union, so an
/// infallible pool needs no `.failed` prong.
pub fn Status(comptime Result: type) type {
    const info = @typeInfo(Result);
    const Value = if (info == .error_union) info.error_union.payload else Result;
    if (info == .error_union) {
        return union(enum) { pending, ready: Value, failed: info.error_union.error_set };
    }
    return union(enum) { pending, ready: Value };
}

pub const Stats = struct {
    started: u64 = 0,
    completed: u64 = 0,
    canceled: u64 = 0,
    /// Requests that found every slot busy and stayed pending.
    rejected: u64 = 0,
};

/// A fixed number of slots for background work of one result type.
///
/// ```zig
/// var thumbnails: zui.TaskPool(LoadError!Thumbnail, 64) = .init;
///
/// switch (thumbnails.request(ui, id, loadThumbnail, .{path}, .{ .key = path_hash })) {
///     .pending => drawPlaceholder(ui),
///     .ready => |thumbnail| drawThumbnail(ui, thumbnail),
///     .failed => |err| ui.text(@errorName(err), .{}),
/// }
/// ```
///
/// A task belongs to the id that requested it. When that id is not
/// requested in a frame, `endFrame` cancels the task with `Future.cancel`,
/// which waits for the task to return: tasks must reach cancelation points
/// (any `Io` call, or `io.checkCancel()` in long computations).
pub fn TaskPool(comptime Result: type, comptime capacity: u16) type {
    if (capacity == 0) @compileError("zui: a TaskPool needs a capacity of at least 1");

    return struct {
        const Self = @This();
        pub const PoolStatus = Status(Result);
        const is_fallible = @typeInfo(Result) == .error_union;

        const SlotState = enum { free, running, completed };

        const Slot = struct {
            state: SlotState = .free,
            element_id: u64 = 0,
            key: u64 = 0,
            last_requested: u32 = 0,
            generation: u32 = 0,
            /// Stored by the task after `result`; equal to `generation` once
            /// the slot's current task has finished.
            finished_generation: std.atomic.Value(u32) = .init(0),
            future: Io.Future(void) = undefined,
            /// Set by the task after writing `result`; read only after the
            /// task has been joined by `await` or `cancel`.
            has_result: bool = false,
            result: Result = undefined,
        };

        slots: [capacity]Slot = @splat(.{}),
        /// Set by a task after its `finished_generation`, so `beginFrame`
        /// only looks through the slots of pools where something finished.
        any_finished: std.atomic.Value(bool) = .init(false),
        registration: Registration = .{ .apply_completions = applyCompletionsRegistration, .sweep = sweepRegistration, .cancel_all = cancelAllRegistration },
        registered: bool = false,
        io: Io = undefined,
        waker: Waker = undefined,
        stats: Stats = .{},
        /// Called on the UI thread with each result that is dropped without
        /// being handed out as `.ready`, and with each result whose slot is
        /// freed, so resources it owns can be released.
        discard: ?*const fn (result: Result) void = null,

        pub const init: Self = .{};

        pub const RequestOptions = struct {
            /// Identifies the work. A different key for the same id cancels
            /// the old task and starts a new one.
            key: u64 = 0,
        };

        /// The state of `element_id`'s task as of `beginFrame`, starting it
        /// on the first request. Never blocks, except to cancel a task whose
        /// key changed.
        pub fn request(self: *Self, ui: anytype, element_id: Id, comptime function: anytype, arguments: std.meta.ArgsTuple(@TypeOf(function)), options: RequestOptions) PoolStatus {
            comptime checkContext(@TypeOf(ui));
            if (element_id.isNone()) @panic("zui: a task needs an element id, because it is canceled when the id disappears");
            if (!self.registered) self.register(ui);
            const frame_number = ui.input_state.frame_number;

            if (self.find(element_id.hash)) |slot| {
                if (slot.key == options.key) {
                    slot.last_requested = frame_number;
                    return self.statusOf(slot);
                }
                self.free(slot, true);
            }

            const slot_index = self.claimSlot() orelse {
                self.stats.rejected += 1;
                return .pending;
            };
            const slot = &self.slots[slot_index];
            const next_generation = slot.generation +% 1;
            slot.* = .{
                .state = .running,
                .element_id = element_id.hash,
                .key = options.key,
                .last_requested = frame_number,
                .generation = next_generation,
                .finished_generation = .init(next_generation -% 1),
            };
            self.stats.started += 1;
            const task_arguments = .{ self, slot_index, slot.generation, arguments };
            const Runner = TaskRunner(function);
            // Without concurrency, `io.async` may run the task to completion
            // right here; it is still `.pending` until the next `beginFrame`.
            slot.future = self.io.concurrent(Runner.run, task_arguments) catch self.io.async(Runner.run, task_arguments);
            return .pending;
        }

        /// Cancels every task and unregisters from the Context.
        pub fn deinit(self: *Self, ui: anytype) void {
            if (!self.registered) return;
            self.cancelAll();
            ui.unregisterTaskPool(&self.registration);
            self.registered = false;
        }

        fn checkContext(comptime Pointer: type) void {
            const info = @typeInfo(Pointer);
            if (info != .pointer or !@hasDecl(info.pointer.child, "registerTaskPool")) {
                @compileError("zui: TaskPool.request takes a *zui.Context, got " ++ @typeName(Pointer));
            }
        }

        fn TaskRunner(comptime function: anytype) type {
            return struct {
                fn run(pool: *Self, slot_index: u16, generation: u32, arguments: std.meta.ArgsTuple(@TypeOf(function))) void {
                    pool.slots[slot_index].result = @call(.auto, function, arguments);
                    pool.slots[slot_index].has_result = true;
                    pool.slots[slot_index].finished_generation.store(generation, .release);
                    pool.any_finished.store(true, .release);
                    pool.waker.notify();
                }
            };
        }

        fn register(self: *Self, ui: anytype) void {
            self.io = ui.io;
            self.waker = ui.waker();
            ui.registerTaskPool(&self.registration);
            self.registered = true;
        }

        fn statusOf(self: *const Self, slot: *const Slot) PoolStatus {
            _ = self;
            if (slot.state != .completed) return .pending;
            if (is_fallible) {
                return if (slot.result) |value| .{ .ready = value } else |err| .{ .failed = err };
            }
            return .{ .ready = slot.result };
        }

        fn find(self: *Self, element_id: u64) ?*Slot {
            for (&self.slots) |*slot| {
                if (slot.state != .free and slot.element_id == element_id) return slot;
            }
            return null;
        }

        fn claimSlot(self: *Self) ?u16 {
            for (&self.slots, 0..) |*slot, index| {
                if (slot.state == .free) return @intCast(index);
            }
            return null;
        }

        fn applyCompletions(self: *Self) void {
            if (!self.any_finished.swap(false, .acquire)) return;
            for (&self.slots) |*slot| {
                if (slot.state != .running or slot.finished_generation.load(.acquire) != slot.generation) continue;
                _ = slot.future.await(self.io);
                slot.state = .completed;
                self.stats.completed += 1;
            }
        }

        /// Frees a slot; a running task is canceled first, which waits for it.
        fn free(self: *Self, slot: *Slot, count_as_canceled: bool) void {
            switch (slot.state) {
                .free => return,
                .running => {
                    _ = slot.future.cancel(self.io);
                    if (count_as_canceled) self.stats.canceled += 1;
                },
                .completed => {},
            }
            if (slot.has_result) if (self.discard) |discard| discard(slot.result);
            slot.state = .free;
        }

        fn applyCompletionsRegistration(registration: *Registration) void {
            const self: *Self = @alignCast(@fieldParentPtr("registration", registration));
            self.applyCompletions();
        }

        /// A task that completed during this frame is still `.running`, so
        /// freeing it counts it as canceled and hands its result to `discard`.
        fn sweepRegistration(registration: *Registration, frame_number: u32) void {
            const self: *Self = @alignCast(@fieldParentPtr("registration", registration));
            for (&self.slots) |*slot| {
                if (slot.state != .free and slot.last_requested != frame_number) self.free(slot, true);
            }
        }

        fn cancelAllRegistration(registration: *Registration) void {
            const self: *Self = @alignCast(@fieldParentPtr("registration", registration));
            self.cancelAll();
        }

        fn cancelAll(self: *Self) void {
            for (&self.slots) |*slot| self.free(slot, true);
        }
    };
}

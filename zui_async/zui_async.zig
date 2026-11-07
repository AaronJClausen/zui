//! The default sources: data published from any thread, swapped into each
//! frame at `beginFrame`.
//!
//! ```zig
//! const AppSources = struct {
//!     battery: zui_async.Latest(f32) = .{},
//!     quotes: zui_async.Stream(Quote, .{ .capacity = 64, .producers = .many }) = .{},
//!     catalog: CatalogTask = .{},
//!     thumbnails: zui_async.KeyedLoads(u64, DecodeError!Texture, .{ .capacity = 128, .owns_resources = true }) = .{},
//! };
//! const CatalogTask = zui_async.Task(FetchError!*const Catalog, .{ .Progress = f32 });
//!
//! // On any thread:
//! waker.wakeIf(app.sources.battery.publish(0.8));
//! ```

const std = @import("std");
const zui = @import("zui");

const safety = std.debug.runtime_safety;
const cache_line = std.atomic.cache_line;

/// Remembers the last frame number `zuiEndFrame` saw, in safe builds, to
/// catch a second context swapping the same source: the numbers one
/// context reports only increase.
const OneReader = struct {
    next_frame: if (safety) u64 else void = if (safety) 0 else {},

    fn check(self: *OneReader, info: zui.EndFrameInfo) void {
        if (!safety) return;
        if (info.frame_number < self.next_frame) @panic("zui_async: two contexts swap one source; give each context its own sources");
        self.next_frame = info.frame_number + 1;
    }
};

/// Catches, in safe builds, two producers publishing at once into a
/// source declared for one.
const OneProducer = struct {
    publishing: if (safety) std.atomic.Value(bool) else void = if (safety) .init(false) else {},

    fn enter(self: *OneProducer, comptime source_kind: []const u8) void {
        if (safety and self.publishing.swap(true, .acquire)) {
            @panic("zui_async: two producers publish at once into a " ++ source_kind ++ " that takes one");
        }
    }

    fn exit(self: *OneProducer) void {
        if (safety) self.publishing.store(false, .release);
    }
};

/// The newest value only: a battery level, a sync state. One producer.
///
/// A triple buffer and one atomic byte. A publish exchanges the producer's
/// buffer with the middle one; a swap exchanges the front and the middle if
/// the middle is fresh; the view reads the front in place. Two publishes
/// between swaps lose the first, so `T` is plain data, or a handle the
/// producer keeps alive.
pub fn Latest(comptime T: type) type {
    return struct {
        const Self = @This();
        const index_mask: u8 = 0b011;
        const fresh_bit: u8 = 0b100;

        /// The value this frame's swap brought, if any.
        pub const Delivery = ?T;

        pub const View = struct {
            latest: *const Self,

            /// The newest value swapped so far; null before the first.
            pub fn get(self: View) ?T {
                return if (self.latest.reader.has_value) self.latest.buffers[self.latest.reader.front] else null;
            }

            /// Like `get`, without copying: valid until the next swap.
            pub fn getPtr(self: View) ?*const T {
                return if (self.latest.reader.has_value) &self.latest.buffers[self.latest.reader.front] else null;
            }

            /// Whether this frame's swap brought a new value.
            pub fn changed(self: View) bool {
                return self.latest.reader.received;
            }
        };

        buffers: [3]T = undefined,
        /// The middle buffer's index, with `fresh_bit` while it holds a
        /// value not yet swapped.
        shared: struct { middle: std.atomic.Value(u8) align(cache_line) = .init(1) } = .{},
        producer: struct {
            back: u8 align(cache_line) = 2,
            one_producer: OneProducer = .{},
        } = .{},
        reader: struct {
            front: u8 align(cache_line) = 0,
            has_value: bool = false,
            received: bool = false,
            one_reader: OneReader = .{},
        } = .{},

        /// Makes `value` the newest. Any thread, but one at a time.
        ///
        /// ```zig
        /// waker.wakeIf(app.sources.battery.publish(level));
        /// ```
        pub fn publish(self: *Self, value: T) zui.Wake {
            self.producer.one_producer.enter("Latest");
            defer self.producer.one_producer.exit();
            self.buffers[self.producer.back] = value;
            const previous = self.shared.middle.swap(self.producer.back | fresh_bit, .acq_rel);
            self.producer.back = previous & index_mask;
            return if (previous & fresh_bit != 0) .already_pending else .needed;
        }

        pub fn zuiSwap(self: *Self) void {
            self.reader.received = false;
            if (self.shared.middle.load(.monotonic) & fresh_bit == 0) return;
            const previous = self.shared.middle.swap(self.reader.front, .acq_rel);
            self.reader.front = previous & index_mask;
            self.reader.received = true;
            self.reader.has_value = true;
        }

        pub fn zuiView(self: *Self) View {
            return .{ .latest = self };
        }

        pub fn zuiDelivery(self: *const Self, delivery: *Delivery) void {
            delivery.* = if (self.reader.received) self.buffers[self.reader.front] else null;
        }

        pub fn zuiInject(self: *Self, delivery: *const Delivery) void {
            self.reader.received = delivery.* != null;
            if (delivery.*) |value| {
                self.buffers[self.reader.front] = value;
                self.reader.has_value = true;
            }
        }

        pub fn zuiPending(self: *const Self) bool {
            return self.shared.middle.load(.monotonic) & fresh_bit != 0;
        }

        pub fn zuiEndFrame(self: *Self, info: zui.EndFrameInfo) void {
            self.reader.one_reader.check(info);
        }
    };
}

pub const Producers = enum { one, many };

pub const StreamOptions = struct {
    /// Items published and not yet released: those waiting for a swap and
    /// those the last frame read. A power of two.
    capacity: u32,
    /// `.many` claims each item with a compare-and-swap; `.one` with a
    /// plain store, and asserts in safe builds that publishes never overlap.
    producers: Producers = .one,
};

/// Every item, in order: messages, log lines.
///
/// A bounded ring with a sequence number per slot. A swap first releases
/// what the previous frame read, then takes every item written since,
/// stopping without waiting at the first slot claimed but not yet written.
/// A full stream refuses the newest item, which stays its producer's.
pub fn Stream(comptime T: type, comptime options: StreamOptions) type {
    const capacity = options.capacity;
    if (capacity == 0 or !std.math.isPowerOfTwo(capacity)) {
        @compileError(std.fmt.comptimePrint("zui_async: Stream capacity must be a power of two, got {d}", .{capacity}));
    }

    const Head = if (options.producers == .many) std.atomic.Value(usize) else usize;

    return struct {
        const Self = @This();

        /// What one swap took, for relay and replay.
        pub const Delivery = struct {
            items: [capacity]T = undefined,
            len: u32 = 0,

            pub const empty: Delivery = .{};

            /// `items` must fit the stream's capacity.
            pub fn init(items: []const T) Delivery {
                std.debug.assert(items.len <= capacity);
                var delivery: Delivery = .{ .len = @intCast(items.len) };
                @memcpy(delivery.items[0..items.len], items);
                return delivery;
            }

            pub fn slice(self: *const Delivery) []const T {
                return self.items[0..self.len];
            }

            /// Writes only the items taken, for `zui_wire`.
            pub fn zuiSerialize(self: *const Delivery, serializer: anytype) !void {
                try serializer.write(self.slice());
            }

            pub fn zuiDeserialize(deserializer: anytype) !Delivery {
                const items = try deserializer.read([]const T);
                if (items.len > capacity) return error.Malformed;
                return .init(items);
            }
        };

        pub const View = struct {
            stream: *const Self,

            /// This frame's items, in the order they were published, read in
            /// place: they may wrap around the ring, so they are not one slice.
            ///
            /// ```zig
            /// var quotes = ui.source(.quotes).items();
            /// while (quotes.next()) |quote| tickerRow(ui, quote.*);
            /// ```
            pub fn items(self: View) Iterator {
                return .{ .stream = self.stream, .position = self.stream.reader.start, .end = self.stream.reader.end };
            }

            pub fn count(self: View) usize {
                return self.stream.reader.end -% self.stream.reader.start;
            }
        };

        pub const Iterator = struct {
            stream: *const Self,
            position: usize,
            end: usize,

            pub fn next(self: *Iterator) ?*const T {
                if (self.position == self.end) return null;
                defer self.position +%= 1;
                return &self.stream.slots[self.position % capacity].item;
            }
        };

        const Slot = struct {
            /// The position this slot takes next while free, that plus one
            /// once written, and that plus `capacity` once released.
            sequence: std.atomic.Value(usize),
            item: T,
        };

        slots: [capacity]Slot = initial_slots,
        shared: struct {
            /// Set by the publish that made the stream fresh, cleared by a swap.
            fresh: std.atomic.Value(bool) align(cache_line) = .init(false),
        } = .{},
        producer: struct {
            head: Head align(cache_line) = if (options.producers == .many) .init(0) else 0,
            refused: std.atomic.Value(u32) = .init(0),
            one_producer: if (options.producers == .one) OneProducer else void = if (options.producers == .one) .{} else {},
        } = .{},
        reader: struct {
            /// The positions this frame's swap took.
            start: usize align(cache_line) = 0,
            end: usize = 0,
            one_reader: OneReader = .{},
        } = .{},

        const initial_slots = slots: {
            @setEvalBranchQuota(4 * capacity + 1000);
            var slots: [capacity]Slot = undefined;
            for (&slots, 0..) |*slot, position| slot.* = .{ .sequence = .init(position), .item = undefined };
            break :slots slots;
        };

        /// Appends `item`, or refuses it with `error.Full` when the stream
        /// holds `capacity` items. Never waits, so a producer on the UI
        /// thread is safe.
        ///
        /// ```zig
        /// waker.wakeIf(app.sources.quotes.publish(quote) catch .already_pending);
        /// ```
        pub fn publish(self: *Self, item: T) error{Full}!zui.Wake {
            if (options.producers == .one) self.producer.one_producer.enter("Stream");
            defer if (options.producers == .one) self.producer.one_producer.exit();
            const position = self.claim() orelse {
                _ = self.producer.refused.fetchAdd(1, .monotonic);
                return error.Full;
            };
            const slot = &self.slots[position % capacity];
            slot.item = item;
            slot.sequence.store(position +% 1, .release);
            return if (self.shared.fresh.swap(true, .acq_rel)) .already_pending else .needed;
        }

        fn claim(self: *Self) ?usize {
            switch (options.producers) {
                .one => {
                    const position = self.producer.head;
                    if (self.slots[position % capacity].sequence.load(.acquire) != position) return null;
                    self.producer.head = position +% 1;
                    return position;
                },
                .many => {
                    var position = self.producer.head.load(.monotonic);
                    while (true) {
                        const sequence = self.slots[position % capacity].sequence.load(.acquire);
                        const lag: isize = @bitCast(sequence -% position);
                        if (lag < 0) return null;
                        if (lag > 0) {
                            position = self.producer.head.load(.monotonic);
                            continue;
                        }
                        position = self.producer.head.cmpxchgWeak(position, position +% 1, .monotonic, .monotonic) orelse return position;
                    }
                },
            }
        }

        fn releaseRead(self: *Self) void {
            var position = self.reader.start;
            while (position != self.reader.end) : (position +%= 1) {
                self.slots[position % capacity].sequence.store(position +% capacity, .release);
            }
            self.reader.start = self.reader.end;
        }

        fn takeWritten(self: *Self) void {
            _ = self.shared.fresh.swap(false, .acq_rel);
            var end = self.reader.end;
            while (self.slots[end % capacity].sequence.load(.acquire) == end +% 1) end +%= 1;
            self.reader.end = end;
        }

        pub fn zuiSwap(self: *Self) void {
            self.releaseRead();
            if (!self.shared.fresh.load(.monotonic)) return;
            self.takeWritten();
        }

        pub fn zuiView(self: *Self) View {
            return .{ .stream = self };
        }

        pub fn zuiDelivery(self: *const Self, delivery: *Delivery) void {
            var items = (View{ .stream = self }).items();
            delivery.len = 0;
            while (items.next()) |item| {
                delivery.items[delivery.len] = item.*;
                delivery.len += 1;
            }
        }

        /// Republishes the recorded items and takes them, so replay must not
        /// run producers alongside.
        pub fn zuiInject(self: *Self, delivery: *const Delivery) void {
            self.releaseRead();
            for (delivery.slice()) |item| _ = self.publish(item) catch break;
            self.takeWritten();
        }

        pub fn zuiPending(self: *const Self) bool {
            return self.shared.fresh.load(.monotonic);
        }

        pub fn zuiEndFrame(self: *Self, info: zui.EndFrameInfo) void {
            self.reader.one_reader.check(info);
        }

        pub fn zuiRefusedCount(self: *Self) u32 {
            return self.producer.refused.swap(0, .monotonic);
        }
    };
}

pub const TaskOptions = struct {
    /// What `.running` carries, e.g. an `f32` fraction done.
    Progress: type = void,
};

/// One piece of work with a status, one run at a time.
///
/// The loader calls `begin` for a `Run`; the producer reports `progress`
/// and calls `finish` exactly once. `begin` refuses while a run is active
/// or its final status is not yet swapped, which keeps the task
/// single-producer; work that restarts while running belongs in
/// `KeyedLoads`.
pub fn Task(comptime Result: type, comptime options: TaskOptions) type {
    return struct {
        const Self = @This();
        const Progress = options.Progress;

        pub const Status = zui.StatusWithProgress(Result, Progress);
        /// The status this frame's swap brought, if it changed.
        pub const Delivery = ?Status;

        pub const View = struct {
            task: *Self,

            pub fn status(self: View) Status {
                self.task.reader.read_this_frame = true;
                return self.task.frontStatus();
            }

            /// Whether this frame's swap changed the status.
            pub fn changed(self: View) bool {
                return self.task.statuses.reader.received;
            }
        };

        const Phase = enum(u8) {
            /// No run, or the last run's final status was swapped.
            idle,
            running,
            /// `finish` was called; the final status is not yet swapped.
            finished,
        };

        /// Handed to the producer by `begin`.
        pub const Run = struct {
            task: *Self,
            waker: zui.Waker,

            /// Any thread: reports the run's progress. Before `finish` only.
            pub fn progress(self: Run, value: Progress) void {
                if (safety and self.task.shared.phase.load(.monotonic) != .running) @panic("zui_async: a Task run reported progress after it finished");
                self.waker.wakeIf(self.task.statuses.publish(.{ .running = value }));
            }

            /// Any thread: ends the run with what the work returned. Exactly once.
            pub fn finish(self: Run, result: Result) void {
                const previous = self.task.shared.phase.swap(.finished, .monotonic);
                if (safety and previous != .running) @panic("zui_async: a Task run finished twice");
                self.waker.wakeIf(self.task.statuses.publish(.fromResult(result)));
            }

            /// Whether the loader asked this run to stop; read at the
            /// producer's own pace. A run that stops finishes with
            /// `error.Canceled`.
            pub fn abandoned(self: Run) bool {
                return self.task.shared.abandon_requested.load(.monotonic);
            }
        };

        statuses: Latest(Status) = .{},
        shared: struct {
            phase: std.atomic.Value(Phase) align(cache_line) = .init(.idle),
            abandon_requested: std.atomic.Value(bool) = .init(false),
        } = .{},
        reader: struct {
            read_this_frame: bool align(cache_line) = false,
            last_read_frame: ?u64 = null,
            last_ended_frame: ?u64 = null,
            frames_in_flight: u8 = 1,
        } = .{},

        /// Adapts a plain function into one that finishes a `Run` with
        /// what it returns, for `Io.Group.async`:
        ///
        /// ```zig
        /// if (app.sources.catalog.begin(app.waker)) |run| {
        ///     app.work.async(io, CatalogTask.publishing(fetchCatalog), .{ run, .{ io, app.catalog_url } });
        /// } else |_| {}
        /// ```
        pub fn publishing(comptime work: anytype) fn (Run, std.meta.ArgsTuple(@TypeOf(work))) void {
            return struct {
                fn finishWith(run: Run, arguments: std.meta.ArgsTuple(@TypeOf(work))) void {
                    run.finish(@call(.auto, work, arguments));
                }
            }.finishWith;
        }

        /// The loader's side: starts a run, whose status becomes `.running`
        /// with zeroed progress. `error.Busy` while a run is active or its
        /// final status is not yet swapped. A new run replaces a final
        /// status, so a result the application owns is taken with `clear`
        /// first.
        pub fn begin(self: *Self, waker: zui.Waker) error{Busy}!Run {
            if (self.shared.phase.cmpxchgStrong(.idle, .running, .acquire, .monotonic) != null) return error.Busy;
            self.shared.abandon_requested.store(false, .monotonic);
            _ = self.statuses.publish(.{ .running = std.mem.zeroes(Progress) });
            return .{ .task = self, .waker = waker };
        }

        /// The loader's side: asks the active run to stop. Nothing waits for it.
        pub fn abandon(self: *Self) void {
            self.shared.abandon_requested.store(true, .monotonic);
        }

        /// The loader's side: nothing has started since the task was made
        /// or cleared.
        pub fn isIdle(self: *const Self) bool {
            return self.shared.phase.load(.acquire) == .idle and self.frontStatus() == .idle;
        }

        /// The loader's side: hands back the final status and makes the task
        /// idle, once `frames_in_flight` frames have ended since the last
        /// frame that read it, so no frame in flight still uses the result.
        /// Null while running, while idle, or until then.
        pub fn clear(self: *Self) ?Status {
            if (self.shared.phase.load(.acquire) != .idle) return null;
            const status = self.frontStatus();
            switch (status) {
                .idle, .running => return null,
                else => {},
            }
            if (self.reader.last_read_frame) |read_frame| {
                const ended = self.reader.last_ended_frame orelse return null;
                if (ended - read_frame < self.reader.frames_in_flight) return null;
            }
            self.statuses.buffers[self.statuses.reader.front] = .idle;
            return status;
        }

        fn frontStatus(self: *const Self) Status {
            const statuses = &self.statuses;
            return if (statuses.reader.has_value) statuses.buffers[statuses.reader.front] else .idle;
        }

        fn isFinal(status: Status) bool {
            return switch (status) {
                .idle, .running => false,
                else => true,
            };
        }

        pub fn zuiSwap(self: *Self) void {
            self.statuses.zuiSwap();
            if (self.statuses.reader.received and isFinal(self.frontStatus())) self.shared.phase.store(.idle, .release);
        }

        pub fn zuiView(self: *Self) View {
            return .{ .task = self };
        }

        pub fn zuiDelivery(self: *const Self, delivery: *Delivery) void {
            self.statuses.zuiDelivery(delivery);
        }

        pub fn zuiInject(self: *Self, delivery: *const Delivery) void {
            self.statuses.zuiInject(delivery);
        }

        pub fn zuiPending(self: *const Self) bool {
            return self.statuses.zuiPending();
        }

        pub fn zuiEndFrame(self: *Self, info: zui.EndFrameInfo) void {
            self.statuses.zuiEndFrame(info);
            if (self.reader.read_this_frame) self.reader.last_read_frame = info.frame_number;
            self.reader.read_this_frame = false;
            self.reader.last_ended_frame = info.frame_number;
            self.reader.frames_in_flight = info.frames_in_flight;
        }
    };
}

pub const KeyedLoadsOptions = struct {
    /// Keys tracked at once: wanted, loading, ready, or waiting in `toRelease`.
    capacity: u32,
    /// Frames a key may go unread before it is released. A value is never
    /// released before `frames_in_flight` unread frames, whatever this says.
    unread_frames_before_release: u32 = 30,
    /// Results are resources the application frees, such as textures: they
    /// come back through `toRelease`.
    owns_resources: bool = false,
    /// What `.running` carries; at most the size of a `usize`, so a
    /// producer reports it with one atomic store on every target.
    Progress: type = void,
};

/// Many keyed loads driven by demand: thumbnails, remote rows, search
/// results per query.
///
/// A key moves through *wanted* (`get` asked for it; `.idle`), *loading*
/// (the loader took it from `toStart`; `.running`), *ready* (`.ready`,
/// `.failed` or `.canceled`) and, once unread for long enough, *released*:
/// freed, or with `owns_resources` handed back by `toRelease`. `get` never
/// starts work. Completions go through a ring with a place for every
/// slot, so it cannot overflow however rarely it is drained, and a slot is
/// reused only after its load's completion is swapped, so an abandoned
/// load never completes the next one. An abandoned load still finishes,
/// into `toRelease`.
pub fn KeyedLoads(comptime Key: type, comptime Result: type, comptime options: KeyedLoadsOptions) type {
    const Progress = options.Progress;
    if (@bitSizeOf(Progress) > @bitSizeOf(usize)) {
        @compileError("zui_async: KeyedLoads Progress must fit in a usize, got " ++ @typeName(Progress));
    }
    const capacity = options.capacity;
    if (capacity == 0) @compileError("zui_async: KeyedLoads capacity must be at least 1");
    const has_progress = Progress != void;
    const ProgressBits = std.meta.Int(.unsigned, @bitSizeOf(Progress));
    const ProgressWord = std.meta.Int(.unsigned, @max(8, std.math.ceilPowerOfTwoAssert(u16, @max(1, @bitSizeOf(Progress)))));

    return struct {
        const Self = @This();
        const index_size = std.math.ceilPowerOfTwoAssert(u32, capacity * 2);
        /// A power of two, so positions may wrap a 32-bit `usize` without
        /// changing entry.
        const ring_size = std.math.ceilPowerOfTwoAssert(u32, capacity);
        const empty_entry: u32 = 0;

        pub const Status = zui.StatusWithProgress(Result, Progress);

        pub const Completion = struct { key: Key, result: Result };

        /// The keys whose loads this frame's swap completed.
        pub const Delivery = struct {
            completions: [capacity]Completion = undefined,
            len: u32 = 0,

            pub const empty: Delivery = .{};

            pub fn init(completions: []const Completion) Delivery {
                std.debug.assert(completions.len <= capacity);
                var delivery: Delivery = .{ .len = @intCast(completions.len) };
                @memcpy(delivery.completions[0..completions.len], completions);
                return delivery;
            }

            pub fn slice(self: *const Delivery) []const Completion {
                return self.completions[0..self.len];
            }

            /// Writes only the completions taken, for `zui_wire`.
            pub fn zuiSerialize(self: *const Delivery, serializer: anytype) !void {
                try serializer.write(self.slice());
            }

            pub fn zuiDeserialize(deserializer: anytype) !Delivery {
                const completions = try deserializer.read([]const Completion);
                if (completions.len > capacity) return error.Malformed;
                return .init(completions);
            }
        };

        pub const View = struct {
            loads: *Self,

            /// The key's status, recording that this frame asked for it. A
            /// key not yet tracked becomes wanted, for the loader's
            /// `toStart`; nothing starts here. With every slot taken, the
            /// key stays `.idle` and the refusal is reported.
            pub fn get(self: View, key: Key) Status {
                return self.loads.statusOf(key);
            }
        };

        const State = enum(u8) { free, wanted, loading, abandoned, ready, releasing };

        const Slot = struct {
            key: Key = undefined,
            state: State = .free,
            last_read_frame: u64 = 0,
            progress_seen: Progress = undefined,
        };

        /// Handed to the producer by `toStart`.
        pub const Load = struct {
            loads: *Self,
            slot: u32,
            generation: if (safety) u32 else void,
            key: Key,
            waker: zui.Waker,

            /// Any thread: reports the load's progress. Before `finish` only.
            pub fn progress(self: Load, value: Progress) void {
                if (has_progress) {
                    self.checkActive("reported progress after it finished");
                    const bits: ProgressBits = @bitCast(value);
                    self.loads.producer_slots[self.slot].progress.store(bits, .monotonic);
                    self.waker.wakeIf(self.loads.markFresh());
                }
            }

            /// Any thread: ends the load with what the work returned. Exactly once.
            pub fn finish(self: Load, result: Result) void {
                self.checkActive("finished twice");
                if (safety) self.loads.producer_slots[self.slot].finished_generation.store(self.generation, .monotonic);
                self.loads.producer_slots[self.slot].result = result;
                self.waker.wakeIf(self.loads.complete(self.slot));
            }

            /// Whether demand for the key lapsed; read at the producer's own
            /// pace. A load that stops finishes with `error.Canceled`.
            pub fn abandoned(self: Load) bool {
                return self.loads.producer_slots[self.slot].abandon.load(.monotonic);
            }

            fn checkActive(self: Load, comptime mistake: []const u8) void {
                if (safety and self.loads.producer_slots[self.slot].finished_generation.load(.monotonic) == self.generation) {
                    @panic("zui_async: a KeyedLoads load " ++ mistake);
                }
            }
        };

        /// What a producer writes; one per slot.
        const ProducerSlot = struct {
            result: Result = undefined,
            progress: if (has_progress) std.atomic.Value(ProgressWord) else void = if (has_progress) .init(0) else {},
            abandon: std.atomic.Value(bool) = .init(false),
            finished_generation: if (safety) std.atomic.Value(u32) else void = if (safety) .init(0) else {},
        };

        const CompletionEntry = struct {
            sequence: std.atomic.Value(usize),
            slot: u32,
        };

        slots: [capacity]Slot = @splat(.{}),
        producer_slots: [capacity]ProducerSlot = @splat(.{}),
        /// Each entry holds `slot + 1`; 0 is empty.
        index: [index_size]u32 = @splat(empty_entry),
        free_slots: [capacity]u32 = initial_free_slots,
        completions: [ring_size]CompletionEntry = initial_completions,
        shared: struct {
            fresh: std.atomic.Value(bool) align(cache_line) = .init(false),
        } = .{},
        producer: struct {
            completion_head: std.atomic.Value(usize) align(cache_line) = .init(0),
        } = .{},
        reader: struct {
            completion_tail: usize align(cache_line) = 0,
            free_count: u32 = capacity,
            wanted_count: u32 = 0,
            frame: u64 = 0,
            /// No key can have gone unread long enough before this frame,
            /// so `zuiEndFrame` walks the slots only from then.
            next_release_check: u64 = 0,
            release_after: u64 = options.unread_frames_before_release,
            refused: u32 = 0,
            generation: if (safety) u32 else void = if (safety) 0 else {},
            delivered: [capacity]u32 = undefined,
            delivered_count: u32 = 0,
            releasing: if (options.owns_resources) [capacity]u32 else void = undefined,
            releasing_count: u32 = 0,
            one_reader: OneReader = .{},
        } = .{},

        const initial_free_slots = slots: {
            @setEvalBranchQuota(4 * capacity + 1000);
            var free: [capacity]u32 = undefined;
            for (&free, 0..) |*slot, position| slot.* = capacity - 1 - position;
            break :slots free;
        };

        const initial_completions = entries: {
            @setEvalBranchQuota(4 * ring_size + 1000);
            var entries: [ring_size]CompletionEntry = undefined;
            for (&entries, 0..) |*entry, position| entry.* = .{ .sequence = .init(position), .slot = undefined };
            break :entries entries;
        };

        fn hashOf(key: Key) u32 {
            var hasher: std.hash.Wyhash = .init(0);
            std.hash.autoHash(&hasher, key);
            return @truncate(hasher.final());
        }

        fn findEntry(self: *const Self, key: Key) ?u32 {
            var position = hashOf(key) & (index_size - 1);
            while (self.index[position] != empty_entry) : (position = (position + 1) & (index_size - 1)) {
                if (std.meta.eql(self.slots[self.index[position] - 1].key, key)) return position;
            }
            return null;
        }

        fn insertEntry(self: *Self, key: Key, slot: u32) void {
            var position = hashOf(key) & (index_size - 1);
            while (self.index[position] != empty_entry) position = (position + 1) & (index_size - 1);
            self.index[position] = slot + 1;
        }

        fn removeEntry(self: *Self, removed_position: u32) void {
            var hole = removed_position;
            var probe = removed_position;
            while (true) {
                probe = (probe + 1) & (index_size - 1);
                const entry = self.index[probe];
                if (entry == empty_entry) break;
                const home = hashOf(self.slots[entry - 1].key) & (index_size - 1);
                const stays_put = if (probe > hole) (home > hole and home <= probe) else (home > hole or home <= probe);
                if (!stays_put) {
                    self.index[hole] = entry;
                    hole = probe;
                }
            }
            self.index[hole] = empty_entry;
        }

        fn takeFreeSlot(self: *Self, key: Key, state: State) ?u32 {
            if (self.reader.free_count == 0) {
                self.reader.refused += 1;
                return null;
            }
            self.reader.free_count -= 1;
            const slot = self.free_slots[self.reader.free_count];
            self.slots[slot] = .{ .key = key, .state = state, .last_read_frame = self.reader.frame };
            self.insertEntry(key, slot);
            self.reader.next_release_check = @min(self.reader.next_release_check, self.reader.frame + self.reader.release_after);
            return slot;
        }

        fn freeSlot(self: *Self, slot: u32) void {
            self.slots[slot].state = .free;
            self.free_slots[self.reader.free_count] = slot;
            self.reader.free_count += 1;
        }

        fn statusOf(self: *Self, key: Key) Status {
            const slot = if (self.findEntry(key)) |position| self.index[position] - 1 else {
                if (self.takeFreeSlot(key, .wanted) != null) self.reader.wanted_count += 1;
                return .idle;
            };
            self.slots[slot].last_read_frame = self.reader.frame;
            return switch (self.slots[slot].state) {
                .wanted => .idle,
                .loading => .{ .running = if (has_progress) self.slots[slot].progress_seen else {} },
                .ready => .fromResult(self.producer_slots[slot].result),
                .free, .abandoned, .releasing => unreachable,
            };
        }

        fn markFresh(self: *Self) zui.Wake {
            return if (self.shared.fresh.swap(true, .acq_rel)) .already_pending else .needed;
        }

        fn complete(self: *Self, slot: u32) zui.Wake {
            const position = self.producer.completion_head.fetchAdd(1, .monotonic);
            const entry = &self.completions[position % ring_size];
            if (safety and entry.sequence.load(.acquire) != position) @panic("zui_async: KeyedLoads completed more loads than it started");
            entry.slot = slot;
            entry.sequence.store(position +% 1, .release);
            return self.markFresh();
        }

        /// An iterator over the wanted keys, each now loading; the loader
        /// starts one piece of work per `Load`, which wakes `waker` when it
        /// finishes.
        ///
        /// ```zig
        /// var to_start = app.sources.thumbnails.toStart(app.waker);
        /// while (to_start.next()) |load| app.work.async(io, loadThumbnail, .{ load, io });
        /// ```
        pub fn toStart(self: *Self, waker: zui.Waker) ToStart {
            return .{ .loads = self, .waker = waker };
        }

        pub const ToStart = struct {
            loads: *Self,
            waker: zui.Waker,
            next_slot: u32 = 0,

            pub fn next(self: *ToStart) ?Load {
                const loads = self.loads;
                while (loads.reader.wanted_count != 0 and self.next_slot < capacity) {
                    const slot = self.next_slot;
                    self.next_slot += 1;
                    if (loads.slots[slot].state != .wanted) continue;
                    loads.reader.wanted_count -= 1;
                    loads.slots[slot].state = .loading;
                    if (has_progress) loads.slots[slot].progress_seen = std.mem.zeroes(Progress);
                    const producer_slot = &loads.producer_slots[slot];
                    producer_slot.abandon.store(false, .monotonic);
                    if (has_progress) producer_slot.progress.store(0, .monotonic);
                    if (safety) loads.reader.generation = @max(1, loads.reader.generation +% 1);
                    return .{
                        .loads = loads,
                        .slot = slot,
                        .generation = loads.reader.generation,
                        .key = loads.slots[slot].key,
                        .waker = self.waker,
                    };
                }
                return null;
            }
        };

        /// An iterator over results whose keys went unread long enough, and
        /// over abandoned loads that finished, each handed back once for the
        /// application to free. With `owns_resources` only.
        ///
        /// ```zig
        /// var to_release = app.sources.thumbnails.toRelease();
        /// while (to_release.next()) |released| if (released) |texture| app.renderer.unload(texture) else |_| {};
        /// ```
        pub fn toRelease(self: *Self) ToRelease {
            if (!options.owns_resources) @compileError("zui_async: toRelease() needs .owns_resources = true");
            return .{ .loads = self };
        }

        pub const ToRelease = struct {
            loads: *Self,

            pub fn next(self: *ToRelease) ?Result {
                const loads = self.loads;
                if (loads.reader.releasing_count == 0) return null;
                loads.reader.releasing_count -= 1;
                const slot = loads.reader.releasing[loads.reader.releasing_count];
                const result = loads.producer_slots[slot].result;
                loads.freeSlot(slot);
                return result;
            }
        };

        fn handBack(self: *Self, slot: u32) void {
            if (options.owns_resources) {
                self.slots[slot].state = .releasing;
                self.reader.releasing[self.reader.releasing_count] = slot;
                self.reader.releasing_count += 1;
            } else self.freeSlot(slot);
        }

        fn release(self: *Self, slot: u32) void {
            self.removeEntry(self.findEntry(self.slots[slot].key).?);
            switch (self.slots[slot].state) {
                .wanted => {
                    self.reader.wanted_count -= 1;
                    self.freeSlot(slot);
                },
                .loading => {
                    self.slots[slot].state = .abandoned;
                    self.producer_slots[slot].abandon.store(true, .monotonic);
                },
                .ready => self.handBack(slot),
                .free, .abandoned, .releasing => unreachable,
            }
        }

        pub fn zuiSwap(self: *Self) void {
            self.reader.delivered_count = 0;
            if (!self.shared.fresh.load(.monotonic)) return;
            _ = self.shared.fresh.swap(false, .acq_rel);
            var tail = self.reader.completion_tail;
            while (true) : (tail +%= 1) {
                const entry = &self.completions[tail % ring_size];
                if (entry.sequence.load(.acquire) != tail +% 1) break;
                const slot = entry.slot;
                entry.sequence.store(tail +% ring_size, .release);
                switch (self.slots[slot].state) {
                    .loading => {
                        self.slots[slot].state = .ready;
                        self.reader.delivered[self.reader.delivered_count] = slot;
                        self.reader.delivered_count += 1;
                    },
                    .abandoned => self.handBack(slot),
                    .free, .wanted, .ready, .releasing => unreachable,
                }
            }
            self.reader.completion_tail = tail;
            if (has_progress) {
                for (&self.slots, &self.producer_slots) |*slot, *producer_slot| {
                    if (slot.state != .loading) continue;
                    const bits: ProgressBits = @truncate(producer_slot.progress.load(.monotonic));
                    slot.progress_seen = @bitCast(bits);
                }
            }
        }

        pub fn zuiView(self: *Self) View {
            return .{ .loads = self };
        }

        pub fn zuiDelivery(self: *const Self, delivery: *Delivery) void {
            delivery.len = self.reader.delivered_count;
            for (self.reader.delivered[0..self.reader.delivered_count], delivery.completions[0..delivery.len]) |slot, *completion| {
                completion.* = .{ .key = self.slots[slot].key, .result = self.producer_slots[slot].result };
            }
        }

        /// Makes each recorded key ready with its recorded result. Replay
        /// must not run loads alongside.
        pub fn zuiInject(self: *Self, delivery: *const Delivery) void {
            self.reader.delivered_count = 0;
            for (delivery.slice()) |completion| {
                const slot = if (self.findEntry(completion.key)) |position| self.index[position] - 1 else self.takeFreeSlot(completion.key, .ready) orelse continue;
                if (self.slots[slot].state == .wanted) self.reader.wanted_count -= 1;
                self.slots[slot].state = .ready;
                self.slots[slot].last_read_frame = self.reader.frame;
                self.producer_slots[slot].result = completion.result;
                self.reader.delivered[self.reader.delivered_count] = slot;
                self.reader.delivered_count += 1;
            }
        }

        pub fn zuiPending(self: *const Self) bool {
            return self.shared.fresh.load(.monotonic);
        }

        /// Releases every key unread for `max(unread_frames_before_release,
        /// frames_in_flight)` frames.
        pub fn zuiEndFrame(self: *Self, info: zui.EndFrameInfo) void {
            self.reader.one_reader.check(info);
            self.reader.release_after = @max(options.unread_frames_before_release, info.frames_in_flight);
            if (self.reader.frame >= self.reader.next_release_check) self.releaseUnread();
            self.reader.frame += 1;
        }

        fn releaseUnread(self: *Self) void {
            var oldest_read: u64 = std.math.maxInt(u64);
            for (&self.slots, 0..) |*slot, index| {
                switch (slot.state) {
                    .wanted, .loading, .ready => {
                        if (self.reader.frame - slot.last_read_frame >= self.reader.release_after) {
                            self.release(@intCast(index));
                        } else oldest_read = @min(oldest_read, slot.last_read_frame);
                    },
                    .free, .abandoned, .releasing => {},
                }
            }
            self.reader.next_release_check = oldest_read +| self.reader.release_after;
        }

        pub fn zuiRefusedCount(self: *Self) u32 {
            defer self.reader.refused = 0;
            return self.reader.refused;
        }
    };
}

test {
    _ = @import("tests.zig");
}

const std = @import("std");

/// How a producer ends the host's wait: the host makes one, and a source
/// calls it when a publish makes it fresh. Callable from any thread; a
/// host's wake is sticky, so one that arrives while the loop is not
/// waiting ends its next wait.
pub const Waker = struct {
    /// The host's own pointer, passed back to `wakeFn`.
    context: *anyopaque,
    wakeFn: *const fn (*anyopaque) void,

    pub fn wake(self: Waker) void {
        self.wakeFn(self.context);
    }

    /// Wakes only for the publish that made the source fresh, so a hundred
    /// loads finishing between two frames cost one wake.
    ///
    /// ```zig
    /// waker.wakeIf(source.publish(value));
    /// ```
    pub fn wakeIf(self: Waker, wake_needed: Wake) void {
        if (wake_needed == .needed) self.wake();
    }
};

/// What a publish reports, so only the publish that made a source fresh
/// wakes the host.
pub const Wake = enum {
    /// This publish moved the source from swapped to fresh: call `wake`.
    needed,
    /// An earlier publish since the last swap already did.
    already_pending,
};

/// What `zuiEndFrame` learns about the frame that just ended.
pub const EndFrameInfo = struct {
    frame_number: u64,
    /// A value read this frame may be in use until this many frames pass.
    frames_in_flight: u8,
};

/// The state of one piece of work, for a result of type `Result`.
pub fn Status(comptime Result: type) type {
    return StatusWithProgress(Result, void);
}

/// `Status` with a payload while `.running`, e.g. an `f32` fraction done.
/// `.failed` exists only when `Result` is an error union with an error
/// other than `Canceled`, so an infallible result has no prong for it.
/// `error.Canceled` is always `.canceled`, never `.failed`.
pub fn StatusWithProgress(comptime Result: type, comptime Progress: type) type {
    const Value = switch (@typeInfo(Result)) {
        .error_union => |error_union| error_union.payload,
        else => Result,
    };
    const Error = switch (@typeInfo(Result)) {
        .error_union => |error_union| error_union.error_set,
        else => error{},
    };
    const has_canceled = hasError(Error, "Canceled");
    const can_fail = Error != error{} and Error != error{Canceled};

    const Methods = struct {
        fn fromResult(comptime Self: type, result: Result) Self {
            if (comptime Error == error{}) return .{ .ready = result };
            const value = result catch |err| {
                if (has_canceled and err == @field(Error, "Canceled")) return .canceled;
                if (can_fail) return .{ .failed = err };
                unreachable;
            };
            return .{ .ready = value };
        }
    };

    if (can_fail) return union(enum) {
        const Self = @This();
        /// Nothing started.
        idle,
        /// Started, not finished.
        running: Progress,
        ready: Value,
        failed: Error,
        /// The producer gave up with `error.Canceled`.
        canceled,

        /// `.ready`, `.failed` or `.canceled`, from what the work returned.
        pub fn fromResult(result: Result) Self {
            return Methods.fromResult(Self, result);
        }
    };
    return union(enum) {
        const Self = @This();
        /// Nothing started.
        idle,
        /// Started, not finished.
        running: Progress,
        ready: Value,
        /// The producer gave up with `error.Canceled`.
        canceled,

        /// `.ready` or `.canceled`, from what the work returned.
        pub fn fromResult(result: Result) Self {
            return Methods.fromResult(Self, result);
        }
    };
}

fn hasError(comptime Error: type, comptime name: []const u8) bool {
    const errors = @typeInfo(Error).error_set orelse return true;
    for (errors) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return true;
    }
    return false;
}

/// One field per field of `Sources`, named alike and typed as that
/// source's `Delivery`: what one frame's swaps received, so a recorded
/// frame can be replayed by setting `FrameRecord.deliveries`.
pub fn Deliveries(comptime Sources: type) type {
    const fields = @typeInfo(Sources).@"struct".fields;
    var field_names: [fields.len][]const u8 = undefined;
    var field_types: [fields.len]type = undefined;
    for (fields, &field_names, &field_types) |field, *field_name, *field_type| {
        field_name.* = field.name;
        field_type.* = field.type.Delivery;
    }
    return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
}

test "a status has a failed prong only for a result that can fail" {
    try std.testing.expect(!@hasField(Status(u32), "failed"));
    try std.testing.expect(!@hasField(Status(error{Canceled}!u32), "failed"));
    try std.testing.expect(@hasField(Status(error{ Canceled, Timeout }!u32), "failed"));
    try std.testing.expect(@hasField(Status(anyerror!u32), "failed"));
    try std.testing.expectEqual(f32, @FieldType(StatusWithProgress(u32, f32), "running"));
    try std.testing.expectEqual(void, @FieldType(Status(u32), "running"));
}

test "a status from a result: ready, failed, or canceled" {
    const Fallible = Status(error{ Canceled, Timeout }!u32);
    try std.testing.expectEqual(Fallible{ .ready = 7 }, Fallible.fromResult(7));
    try std.testing.expectEqual(Fallible{ .failed = error.Timeout }, Fallible.fromResult(error.Timeout));
    try std.testing.expectEqual(Fallible.canceled, Fallible.fromResult(error.Canceled));

    const Cancelable = Status(error{Canceled}!u32);
    try std.testing.expectEqual(Cancelable.canceled, Cancelable.fromResult(error.Canceled));

    const Infallible = Status(u32);
    try std.testing.expectEqual(Infallible{ .ready = 3 }, Infallible.fromResult(3));
}

test "a waker wakes only for the publish that made a source fresh" {
    const Counter = struct {
        wakes: u32 = 0,
        fn wake(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.wakes += 1;
        }
    };
    var counter: Counter = .{};
    const waker: Waker = .{ .context = &counter, .wakeFn = Counter.wake };
    waker.wakeIf(.needed);
    waker.wakeIf(.already_pending);
    waker.wake();
    try std.testing.expectEqual(@as(u32, 2), counter.wakes);
}

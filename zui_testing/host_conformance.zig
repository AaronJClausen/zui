const std = @import("std");
const zui = @import("zui");
const DescribedViolation = @import("violation.zig").DescribedViolation;

pub const HostConformance = struct {
    /// Runs the suite's waker, which wakes the host from another thread.
    /// It must offer concurrency.
    io: std.Io,
    window: zui.WindowId = .main,
    /// A wait that should end at once may take this long, and an `.at`
    /// wait may end this long after its instant.
    prompt_ns: u64 = 500 * std.time.ns_per_ms,
    /// Events the harness posted may take this long to be polled.
    event_arrival_ns: u64 = 2 * std.time.ns_per_s,
    /// An `.on_event` wait still waiting after this has lost its wake. The
    /// suite then keeps waking the host until the wait ends, so that a host
    /// which loses only some wakes fails the suite instead of hanging it.
    lost_wake_ns: u64 = 5 * std.time.ns_per_s,
};

pub const HostError = error{
    WindowClosed,
    ZoomNotKept,
    NoViewport,
    SurfaceNotDeclared,
    EventLost,
    ImmediateWaited,
    WakeNotSticky,
    WakeLost,
    WokeBeforeInstant,
    WaitedPastInstant,
    ClosedWindowPolled,
};
pub const HostViolation = DescribedViolation(HostError);

const kept_zoom = 1.5;
const at_wait_ns = 30 * std.time.ns_per_ms;
const other_thread_wake_ns = 20 * std.time.ns_per_ms;

/// Runs a host through the loop's calls on its own, without a `Context`,
/// and fails on the first thing it did differently from the host contract:
/// - `zuiPoll` keeps the application's zoom, reports a viewport, and gives
///   back what the harness posted in the order it was posted;
/// - `zuiSurface` gives a kind its `zui_surfaces` names;
/// - `zuiWait` returns at once for `.immediately`;
/// - a wake before an `.on_event` wait ends it at once, and is then
///   cleared, so the next `.at` wait lasts until its instant;
/// - a wake from another thread ends an `.on_event` wait;
/// - an `.at` wait ends at its instant, not before and not long after;
/// - `zuiApply` takes requests, and, when the harness can close the window,
///   `zuiPoll` returns false after it is closed.
///
/// Every wait the suite starts is bounded by `conformance`.
///
/// `harness` is a pointer to a value that declares:
/// - `fn host(self) *Host`;
/// - `fn post(self, event: zui.Event) bool`: make the OS report `event` to
///   the host, or return false when this host cannot report its kind, which
///   the suite then skips;
/// - optionally `fn close(self) void`, closing the window as the user would.
///
/// ```zig
/// test "the raylib host conforms" {
///     var harness: RaylibHostHarness = try .init();
///     defer harness.deinit();
///     try zui_testing.expectHostConforms(zui_raylib.Host, &harness, .{ .io = std.testing.io });
/// }
/// ```
pub fn expectHostConforms(comptime Host: type, harness: anytype, conformance: HostConformance) !void {
    const violation = try findHostViolation(Host, harness, conformance) orelse return;
    std.debug.print("zui_testing.expectHostConforms: {s} {s}\n", .{ @typeName(Host), violation.description() });
    return violation.kind;
}

/// `expectHostConforms` without printing: the first violation, or null.
pub fn findHostViolation(comptime Host: type, harness: anytype, conformance: HostConformance) !?HostViolation {
    comptime zui.checkHost(Host);
    const Harness = @typeInfo(@TypeOf(harness)).pointer.child;
    const host: *Host = harness.host();
    const window = conformance.window;
    const io = conformance.io;

    var event_buffer: [64]zui.Event = undefined;
    var text_buffer: [64]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&event_buffer, &text_buffer);
    builder.params.zoom = kept_zoom;

    if (!host.zuiPoll(window, &builder)) return .init(error.WindowClosed, "closed its window before the first poll", .{});
    if (builder.params.zoom != kept_zoom) {
        return .init(error.ZoomNotKept, "replaced the application's zoom of {d} with {d}", .{ kept_zoom, builder.params.zoom });
    }
    const viewport = builder.params.viewport;
    if (!(viewport[0] > 0 and viewport[1] > 0)) return .init(error.NoViewport, "reported a viewport of {d} by {d}", .{ viewport[0], viewport[1] });
    const surface_kind = std.meta.activeTag(host.zuiSurface(window));
    if (!Host.zui_surfaces.contains(surface_kind)) {
        return .init(error.SurfaceNotDeclared, "gave a .{t} surface, which its zui_surfaces does not name", .{surface_kind});
    }

    if (try expectPostedEvents(host, harness, &builder, conformance)) |violation| return violation;

    var started = now(io);
    host.zuiWait(.immediately);
    var waited = now(io).nanoseconds -| started.nanoseconds;
    if (waited > conformance.prompt_ns) return .init(error.ImmediateWaited, "took {d} ms to return from an .immediately wait", .{milliseconds(waited)});

    host.zuiWaker().wake();
    started = now(io);
    try waitOnEvent(host, null, conformance);
    waited = now(io).nanoseconds -| started.nanoseconds;
    if (waited > conformance.prompt_ns) {
        return .init(error.WakeNotSticky, "took {d} ms to end an .on_event wait woken before it began", .{milliseconds(waited)});
    }
    if (try expectWaitUntil(host, &builder, conformance, "after a wake the previous wait had taken")) |violation| return violation;

    started = now(io);
    try waitOnEvent(host, other_thread_wake_ns, conformance);
    waited = now(io).nanoseconds -| started.nanoseconds;
    if (waited >= conformance.lost_wake_ns) {
        return .init(error.WakeLost, "took {d} ms to end an .on_event wait woken from another thread after {d} ms", .{ milliseconds(waited), milliseconds(other_thread_wake_ns) });
    }
    if (try expectWaitUntil(host, &builder, conformance, "")) |violation| return violation;

    host.zuiApply(window, .{ .cursor = .pointer });
    host.zuiApply(window, .{});
    if (@hasDecl(Harness, "close")) {
        harness.close();
        if (host.zuiPoll(window, &builder)) return .init(error.ClosedWindowPolled, "polled true after its window was closed", .{});
    }
    return null;
}

fn now(io: std.Io) zui.Instant {
    return .fromTimestamp(std.Io.Timestamp.now(io, .awake));
}

fn milliseconds(nanoseconds: u64) u64 {
    return nanoseconds / std.time.ns_per_ms;
}

/// Posts a click, a key, typed text and a move, then polls until each
/// event the harness could post has arrived after the one before it.
fn expectPostedEvents(host: anytype, harness: anytype, builder: *zui.RecordBuilder, conformance: HostConformance) !?HostViolation {
    const at = builder.params.now;
    const press: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 10, 10 }, .at = at };
    const moved: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 20, 30 }, .at = at };
    const candidates = [_]zui.Event{
        .{ .pointer_move = .{ .pointer = press } },
        .{ .pointer_down = .{ .pointer = press } },
        .{ .pointer_up = .{ .pointer = press } },
        .{ .key_down = .{ .key = .s, .at = at } },
        .{ .key_up = .{ .key = .s, .at = at } },
        .{ .text = "ok" },
        .{ .pointer_move = .{ .pointer = moved } },
    };
    var posted: [candidates.len]zui.Event = undefined;
    var posted_count: usize = 0;
    for (candidates) |event| {
        if (!harness.post(event)) continue;
        posted[posted_count] = event;
        posted_count += 1;
    }

    var arrived: usize = 0;
    const started = now(conformance.io);
    while (arrived < posted_count) {
        host.zuiWait(.immediately);
        if (!host.zuiPoll(conformance.window, builder)) return .init(error.WindowClosed, "closed its window while the suite polled for events", .{});
        for (builder.events()) |event| {
            if (arrived < posted_count and sameEvent(event, posted[arrived])) arrived += 1;
        }
        if (now(conformance.io).nanoseconds -| started.nanoseconds > conformance.event_arrival_ns) break;
    }
    if (arrived == posted_count) return null;
    return .init(error.EventLost, "reported the posted {t} (event {d} of {d}) out of order or not at all", .{
        std.meta.activeTag(posted[arrived]), arrived + 1, posted_count,
    });
}

fn sameEvent(event: zui.Event, posted: zui.Event) bool {
    if (std.meta.activeTag(event) != std.meta.activeTag(posted)) return false;
    return switch (posted) {
        .pointer_down => |press| samePress(press, event.pointer_down),
        .pointer_up => |release| samePress(release, event.pointer_up),
        .pointer_move => |move| std.meta.eql(move.pointer.position, event.pointer_move.pointer.position),
        .key_down => |key| key.key == event.key_down.key,
        .key_up => |key| key.key == event.key_up.key,
        .text => |text| std.mem.eql(u8, text, event.text),
        else => unreachable,
    };
}

fn samePress(posted: zui.PointerButton, polled: zui.PointerButton) bool {
    return posted.button == polled.button and std.meta.eql(posted.pointer.position, polled.pointer.position);
}

/// An `.at` wait 30 ms from the host's own clock: it may not end before
/// its instant, which a wake left over from an earlier wait would do.
fn expectWaitUntil(host: anytype, builder: *zui.RecordBuilder, conformance: HostConformance, comptime context: []const u8) !?HostViolation {
    if (!host.zuiPoll(conformance.window, builder)) return .init(error.WindowClosed, "closed its window before an .at wait", .{});
    const instant = builder.params.now.addNanoseconds(at_wait_ns);
    host.zuiWait(.{ .at = instant });
    if (!host.zuiPoll(conformance.window, builder)) return .init(error.WindowClosed, "closed its window during an .at wait", .{});
    const ended = builder.params.now;
    const separator = if (context.len == 0) "" else ", ";
    if (ended.isBefore(instant)) {
        return .init(error.WokeBeforeInstant, "returned from an .at wait {d} ms before its instant" ++ separator ++ context, .{milliseconds(instant.nanoseconds - ended.nanoseconds)});
    }
    if (ended.nanoseconds - instant.nanoseconds > conformance.prompt_ns) {
        return .init(error.WaitedPastInstant, "returned from an .at wait {d} ms after its instant" ++ separator ++ context, .{milliseconds(ended.nanoseconds - instant.nanoseconds)});
    }
    return null;
}

/// An `.on_event` wait, with another thread waking the host after
/// `wake_after_ns` when it is set, and again every 50 ms from
/// `lost_wake_ns` on, until the wait ends.
fn waitOnEvent(host: anytype, wake_after_ns: ?u64, conformance: HostConformance) !void {
    var waker: OtherThreadWaker = .{ .waker = host.zuiWaker(), .io = conformance.io, .wake_after_ns = wake_after_ns, .rescue_after_ns = conformance.lost_wake_ns };
    var group: std.Io.Group = .init;
    try group.concurrent(conformance.io, OtherThreadWaker.run, .{&waker});
    host.zuiWait(.on_event);
    waker.wait_ended.store(true, .release);
    group.await(conformance.io) catch {};
}

const OtherThreadWaker = struct {
    waker: zui.Waker,
    io: std.Io,
    wake_after_ns: ?u64,
    rescue_after_ns: u64,
    wait_ended: std.atomic.Value(bool) = .init(false),

    const rescue_interval_ns = 50 * std.time.ns_per_ms;
    const poll_interval_ns = 2 * std.time.ns_per_ms;

    fn run(self: *OtherThreadWaker) void {
        const started = now(self.io);
        if (self.wake_after_ns) |delay| {
            if (!self.sleepUntil(started.addNanoseconds(delay))) return;
            self.waker.wake();
        }
        if (!self.sleepUntil(started.addNanoseconds(self.rescue_after_ns))) return;
        while (!self.wait_ended.load(.acquire)) {
            self.waker.wake();
            self.io.sleep(.fromNanoseconds(rescue_interval_ns), .awake) catch return;
        }
    }

    /// False when the wait ended first.
    fn sleepUntil(self: *OtherThreadWaker, instant: zui.Instant) bool {
        while (now(self.io).isBefore(instant)) {
            if (self.wait_ended.load(.acquire)) return false;
            self.io.sleep(.fromNanoseconds(poll_interval_ns), .awake) catch return false;
        }
        return !self.wait_ended.load(.acquire);
    }
};

/// Reports what its harness posts, and waits on an `Io.Event` for the
/// awake clock. With `clears_wake_before_waiting`, a wake that arrives
/// before a wait is lost, which the suite must catch.
fn QueueHost(comptime clears_wake_before_waiting: bool) type {
    return struct {
        const Self = @This();
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

        io: std.Io,
        woken: std.Io.Event = .unset,
        queued: [16]zui.Event = undefined,
        queued_count: usize = 0,
        window_open: bool = true,
        applied: zui.HostRequests = .{},

        const longest_wait_ns = 10 * std.time.ns_per_s;

        pub fn zuiPoll(self: *Self, window: zui.WindowId, record: *zui.RecordBuilder) bool {
            std.debug.assert(window == .main);
            if (!self.window_open) return false;
            record.begin(.{ .now = now(self.io), .viewport = .{ 800, 600 }, .scale = 2 });
            for (self.queued[0..self.queued_count]) |event| switch (event) {
                .text => |text| record.appendText(text),
                else => record.append(event),
            };
            self.queued_count = 0;
            return true;
        }

        pub fn zuiWaker(self: *Self) zui.Waker {
            return .{ .context = self, .wakeFn = wake };
        }

        pub fn zuiWait(self: *Self, next: zui.NextFrame) void {
            if (clears_wake_before_waiting) self.woken.reset();
            const deadline: zui.Instant = switch (next) {
                .immediately => now(self.io),
                .at => |instant| instant,
                .on_event => now(self.io).addNanoseconds(longest_wait_ns),
            };
            const awake_deadline: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = deadline.nanoseconds }, .clock = .awake };
            while (!self.woken.isSet() and now(self.io).isBefore(deadline)) {
                self.woken.waitTimeout(self.io, .{ .deadline = awake_deadline }) catch {};
            }
            self.woken.reset();
        }

        pub fn zuiSurface(_: *Self, window: zui.WindowId) zui.Surface {
            std.debug.assert(window == .main);
            return .{ .offscreen = .{ .size = .{ 1600, 1200 } } };
        }

        pub fn zuiApply(self: *Self, window: zui.WindowId, requests: zui.HostRequests) void {
            std.debug.assert(window == .main);
            self.applied = requests;
        }

        fn wake(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.woken.set(self.io);
        }
    };
}

fn QueueHostHarness(comptime Host: type) type {
    return struct {
        const Self = @This();

        queue_host: Host,

        pub fn host(self: *Self) *Host {
            return &self.queue_host;
        }

        pub fn post(self: *Self, event: zui.Event) bool {
            if (event == .key_up) return false;
            self.queue_host.queued[self.queue_host.queued_count] = event;
            self.queue_host.queued_count += 1;
            return true;
        }

        pub fn close(self: *Self) void {
            self.queue_host.window_open = false;
        }
    };
}

test "a host that keeps the contract passes the suite" {
    var harness: QueueHostHarness(QueueHost(false)) = .{ .queue_host = .{ .io = std.testing.io } };
    try expectHostConforms(QueueHost(false), &harness, .{ .io = std.testing.io });
    try std.testing.expectEqual(zui.Cursor.default, harness.queue_host.applied.cursor);
}

test "a host that clears a wake before waiting fails the suite" {
    var harness: QueueHostHarness(QueueHost(true)) = .{ .queue_host = .{ .io = std.testing.io } };
    const violation = (try findHostViolation(QueueHost(true), &harness, .{ .io = std.testing.io, .prompt_ns = 100 * std.time.ns_per_ms, .lost_wake_ns = 300 * std.time.ns_per_ms })).?;
    try std.testing.expectEqual(error.WakeNotSticky, violation.kind);
    try std.testing.expect(std.mem.startsWith(u8, violation.description(), "took "));
    try std.testing.expect(std.mem.endsWith(u8, violation.description(), " ms to end an .on_event wait woken before it began"));
}

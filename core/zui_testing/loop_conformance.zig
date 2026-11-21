const std = @import("std");
const zui = @import("zui");
const host_conformance = @import("host_conformance.zig");

const HostConformance = host_conformance.HostConformance;
const HostViolation = host_conformance.HostViolation;
const now = host_conformance.now;
const milliseconds = host_conformance.milliseconds;

const at_wait_ns = 30 * std.time.ns_per_ms;
const other_thread_wake_ns = 20 * std.time.ns_per_ms;
const empty_polls = 3;

/// Runs a host that declares `zuiRun` through the platform's loop it
/// runs, handing it a `zui.Driver` whose steps ask, in turn, for the next
/// turn `.immediately`, `.at` an instant 30 ms on, and `.on_event`, with a
/// wake from another thread 20 ms later; then has the harness take the
/// surface away and give it back, and ends the run. It checks that the
/// host starts the driver once and before any step, schedules each step
/// as the one before asked, reports the lost surface and its return,
/// stops the driver, and steps no more once a step has ended the run.
///
/// The harness declares `host()`, the host before `zuiRun`, and
/// `takeSurfaceAway()`, `giveSurfaceBack()` and `quit()`, which make the
/// platform do each on a later callback. The suite calls `quit()` from
/// another thread when the platform has stopped stepping, so no run waits
/// without a bound.
///
/// ```zig
/// test "the Android host conforms" {
///     var harness: AndroidHostHarness = try .init();
///     defer harness.deinit();
///     try zui_testing.expectPushedHostConforms(AndroidHost, &harness, .{ .io = std.testing.io });
/// }
/// ```
pub fn expectPushedHostConforms(comptime Host: type, harness: anytype, conformance: HostConformance) !void {
    const violation = try findPushedHostViolation(Host, harness, conformance) orelse return;
    std.debug.print("zui_testing.expectPushedHostConforms: {s} {s}\n", .{ @typeName(Host), violation.description() });
    return violation.kind;
}

/// `expectPushedHostConforms` without printing: the first violation, or
/// null.
pub fn findPushedHostViolation(comptime Host: type, harness: anytype, conformance: HostConformance) !?HostViolation {
    comptime checkPushed(Host, @typeInfo(@TypeOf(harness)).pointer.child);
    var run: PushedRun(Host, @TypeOf(harness)) = .{ .host = harness.host(), .harness = harness, .conformance = conformance };
    defer run.watchdog.stop(conformance.io);
    try run.host.zuiRun(conformance.io, .{ .title = "zui_testing", .visible = false }, run.driver());
    run.watchdog.stop(conformance.io);
    if (run.violation) |violation| return violation;
    if (run.watchdog.quit_platform.load(.acquire)) {
        return .init(error.WakeLost, "stopped stepping, so the suite quit its platform after {d} ms", .{milliseconds(2 * conformance.lost_wake_ns)});
    }
    if (run.stops == 0) return .init(error.NotStopped, "returned from zuiRun without calling Driver.stop", .{});
    if (run.turn != .ended) return .init(error.NotStopped, "returned from zuiRun before a step ended the run", .{});
    return null;
}

fn checkPushed(comptime Host: type, comptime Harness: type) void {
    zui.checkHost(Host);
    const name = @typeName(Host);
    if (!@hasDecl(Host, "zuiRun")) @compileError("zui_testing: " ++ name ++ " declares no `zuiRun`; expectPushedHostConforms tests a host whose platform runs the loop, and expectHostConforms one zui waits on");
    if (@typeInfo(@TypeOf(Host.zuiRun)).@"fn".return_type.? == noreturn) {
        @compileError("zui_testing: " ++ name ++ ".zuiRun never returns, so expectPushedHostConforms cannot run it in this process");
    }
    for ([_][]const u8{ "host", "takeSurfaceAway", "giveSurfaceBack", "quit" }) |declaration| {
        if (!@hasDecl(Harness, declaration)) @compileError("zui_testing: " ++ @typeName(Harness) ++ " tests a pushed host, so it must declare `" ++ declaration ++ "`");
    }
}

fn PushedRun(comptime Host: type, comptime HarnessPointer: type) type {
    return struct {
        const Self = @This();

        host: *Host,
        harness: HarnessPointer,
        conformance: HostConformance,
        turn: Turn = .first,
        starts: u32 = 0,
        stops: u32 = 0,
        last_step: zui.Instant = .zero,
        instant: zui.Instant = .zero,
        deadline: zui.Instant = .zero,
        violation: ?HostViolation = null,
        watchdog: Watchdog = .{},
        event_buffer: [16]zui.Event = undefined,
        text_buffer: [64]u8 = undefined,
        builder: ?zui.RecordBuilder = null,

        const Turn = enum { first, after_immediately, after_at, after_on_event, awaiting_suspend, awaiting_resume, resumed, ended };

        const calls: zui.Driver.Calls = .{
            .start = start,
            .step = step,
            .suspendSurfaces = suspendSurfaces,
            .resumeSurfaces = resumeSurfaces,
            .stop = stop,
        };

        fn driver(self: *Self) zui.Driver {
            return .{ .context = self, .calls = &calls };
        }

        fn of(context: *anyopaque) *Self {
            return @ptrCast(@alignCast(context));
        }

        fn fail(self: *Self, violation: HostViolation) void {
            if (self.violation == null) self.violation = violation;
        }

        fn start(context: *anyopaque, _: std.Io) anyerror!void {
            const self = of(context);
            self.starts += 1;
            if (self.starts > 1) return self.fail(.init(error.StartedTwice, "called Driver.start twice", .{}));
            const kind = std.meta.activeTag(self.host.zuiSurface(.main));
            if (!Host.zui_surfaces.contains(kind)) self.fail(.init(error.SurfaceNotDeclared, "gave a .{t} surface, which its zui_surfaces does not name", .{kind}));
        }

        fn step(context: *anyopaque) anyerror!?zui.NextFrame {
            const self = of(context);
            const io = self.conformance.io;
            if (self.turn == .ended) {
                self.fail(.init(error.SteppedAfterTheEnd, "called Driver.step after a step had ended the run", .{}));
                return null;
            }
            if (self.starts == 0) {
                self.fail(.init(error.SteppedBeforeStart, "called Driver.step before Driver.start", .{}));
                return self.end();
            }
            self.watchdog.stop(io);
            const polled = self.poll() orelse return self.end();
            if (self.violation != null) return self.end();
            const since_last = polled.nanoseconds -| self.last_step.nanoseconds;
            self.last_step = polled;
            switch (self.turn) {
                .first => {
                    self.turn = .after_immediately;
                    return .immediately;
                },
                .after_immediately => {
                    if (since_last > self.conformance.prompt_ns) {
                        self.fail(.init(error.ImmediateNotStepped, "took {d} ms to step again after a step asked for .immediately", .{milliseconds(since_last)}));
                        return self.end();
                    }
                    self.instant = polled.addNanoseconds(at_wait_ns);
                    self.turn = .after_at;
                    return .{ .at = self.instant };
                },
                .after_at => {
                    if (polled.isBefore(self.instant)) {
                        self.fail(.init(error.SteppedBeforeInstant, "stepped {d} ms before the instant a step asked for", .{milliseconds(self.instant.nanoseconds - polled.nanoseconds)}));
                        return self.end();
                    }
                    if (polled.nanoseconds - self.instant.nanoseconds > self.conformance.prompt_ns) {
                        self.fail(.init(error.SteppedPastInstant, "stepped {d} ms after the instant a step asked for", .{milliseconds(polled.nanoseconds - self.instant.nanoseconds)}));
                        return self.end();
                    }
                    self.turn = .after_on_event;
                    try self.watchdog.start(self, other_thread_wake_ns);
                    return .on_event;
                },
                .after_on_event => {
                    if (since_last >= self.conformance.lost_wake_ns) {
                        self.fail(.init(error.WakeLost, "took {d} ms to step after a wake from another thread {d} ms into an .on_event wait", .{ milliseconds(since_last), milliseconds(other_thread_wake_ns) }));
                        return self.end();
                    }
                    self.harness.takeSurfaceAway();
                    self.deadline = polled.addNanoseconds(self.conformance.event_arrival_ns);
                    self.turn = .awaiting_suspend;
                    return .immediately;
                },
                .awaiting_suspend, .awaiting_resume => {
                    if (!polled.isBefore(self.deadline)) {
                        const lost_step = self.turn == .awaiting_suspend;
                        self.fail(if (lost_step)
                            .init(error.SurfaceLossNotReported, "did not call Driver.suspendSurfaces within {d} ms of its platform taking the surface away", .{milliseconds(self.conformance.event_arrival_ns)})
                        else
                            .init(error.SurfaceNotGivenBack, "did not call Driver.resumeSurfaces within {d} ms of its platform giving the surface back", .{milliseconds(self.conformance.event_arrival_ns)}));
                        return self.end();
                    }
                    return .immediately;
                },
                .resumed => return self.end(),
                .ended => unreachable,
            }
        }

        fn end(self: *Self) ?zui.NextFrame {
            self.turn = .ended;
            return null;
        }

        /// The time the host's record gives, or null when a poll blocked
        /// or closed the window.
        fn poll(self: *Self) ?zui.Instant {
            if (self.builder == null) self.builder = .init(&self.event_buffer, &self.text_buffer);
            const builder = &self.builder.?;
            const started = now(self.conformance.io);
            if (!self.host.zuiPoll(.main, builder)) {
                self.fail(.init(error.WindowClosed, "closed its window during the run", .{}));
                return null;
            }
            const polled_for = now(self.conformance.io).nanoseconds -| started.nanoseconds;
            if (polled_for > self.conformance.prompt_ns) {
                self.fail(.init(error.PollBlocked, "took {d} ms to poll; a poll never blocks", .{milliseconds(polled_for)}));
                return null;
            }
            return builder.params.now;
        }

        fn suspendSurfaces(context: *anyopaque) void {
            const self = of(context);
            if (self.turn != .awaiting_suspend) return;
            self.turn = .awaiting_resume;
            self.harness.giveSurfaceBack();
        }

        fn resumeSurfaces(context: *anyopaque) anyerror!void {
            const self = of(context);
            if (self.turn != .awaiting_resume) return;
            self.turn = .resumed;
        }

        fn stop(context: *anyopaque) void {
            of(context).stops += 1;
        }

        fn quit(context: *anyopaque) void {
            of(context).harness.quit();
        }
    };
}

/// Wakes the host from another thread, once after a delay and then again
/// and again once it has waited `lost_wake_ns`, and quits the platform
/// once it has waited twice that, until the next step stops it.
const Watchdog = struct {
    group: std.Io.Group = .init,
    running: bool = false,
    stepped: std.atomic.Value(bool) = .init(false),
    quit_platform: std.atomic.Value(bool) = .init(false),
    waker: zui.Waker = undefined,
    io: std.Io = undefined,
    wake_after_ns: u64 = 0,
    lost_wake_ns: u64 = 0,
    run_context: *anyopaque = undefined,
    quitFn: *const fn (*anyopaque) void = undefined,

    const rescue_interval_ns = 50 * std.time.ns_per_ms;
    const poll_interval_ns = 2 * std.time.ns_per_ms;

    fn start(self: *Watchdog, run: anytype, wake_after_ns: u64) !void {
        self.stepped.store(false, .release);
        self.waker = run.host.zuiWaker();
        self.io = run.conformance.io;
        self.wake_after_ns = wake_after_ns;
        self.lost_wake_ns = run.conformance.lost_wake_ns;
        self.run_context = run;
        self.quitFn = @TypeOf(run.*).quit;
        self.group = .init;
        try self.group.concurrent(self.io, watch, .{self});
        self.running = true;
    }

    fn stop(self: *Watchdog, io: std.Io) void {
        if (!self.running) return;
        self.stepped.store(true, .release);
        self.group.await(io) catch {};
        self.running = false;
    }

    fn watch(self: *Watchdog) void {
        const started = now(self.io);
        if (!self.sleepUntil(started.addNanoseconds(self.wake_after_ns))) return;
        self.waker.wake();
        if (!self.sleepUntil(started.addNanoseconds(self.lost_wake_ns))) return;
        const quit_at = started.addNanoseconds(2 * self.lost_wake_ns);
        while (!self.stepped.load(.acquire)) {
            if (!now(self.io).isBefore(quit_at)) {
                self.quit_platform.store(true, .release);
                self.quitFn(self.run_context);
                self.waker.wake();
                return;
            }
            self.waker.wake();
            self.io.sleep(.fromNanoseconds(rescue_interval_ns), .awake) catch return;
        }
    }

    /// False when a step came first.
    fn sleepUntil(self: *Watchdog, instant: zui.Instant) bool {
        while (now(self.io).isBefore(instant)) {
            if (self.stepped.load(.acquire)) return false;
            self.io.sleep(.fromNanoseconds(poll_interval_ns), .awake) catch return false;
        }
        return !self.stepped.load(.acquire);
    }
};

/// Tests a host that declares neither `zuiWait` nor `zuiRun`, a window
/// whose application steps it from a loop of its own: its poll never
/// blocks, with nothing to report or after a wake from another thread; it
/// gives a surface it declares; and events the harness posts arrive in
/// order. The harness declares `host()` and `post(event)` as for
/// `expectHostConforms`, and `close()` if it can close the window.
///
/// ```zig
/// test "the editor's panel host conforms" {
///     var harness: PanelHarness = try .init();
///     defer harness.deinit();
///     try zui_testing.expectSteppedHostConforms(PanelHost, &harness, .{ .io = std.testing.io });
/// }
/// ```
pub fn expectSteppedHostConforms(comptime Host: type, harness: anytype, conformance: HostConformance) !void {
    const violation = try findSteppedHostViolation(Host, harness, conformance) orelse return;
    std.debug.print("zui_testing.expectSteppedHostConforms: {s} {s}\n", .{ @typeName(Host), violation.description() });
    return violation.kind;
}

/// `expectSteppedHostConforms` without printing: the first violation, or
/// null.
pub fn findSteppedHostViolation(comptime Host: type, harness: anytype, conformance: HostConformance) !?HostViolation {
    comptime zui.checkHost(Host);
    inline for (.{ "zuiWait", "zuiRun" }) |loop_call| {
        if (@hasDecl(Host, loop_call)) @compileError("zui_testing: " ++ @typeName(Host) ++ " declares `" ++ loop_call ++ "`; expectSteppedHostConforms tests a host the application steps, which declares neither loop call");
    }
    const Harness = @typeInfo(@TypeOf(harness)).pointer.child;
    const host: *Host = harness.host();
    const io = conformance.io;

    var event_buffer: [64]zui.Event = undefined;
    var text_buffer: [64]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&event_buffer, &text_buffer);

    for (0..empty_polls) |_| {
        if (try expectPromptPoll(host, &builder, conformance, "with nothing to report")) |violation| return violation;
    }
    const surface_kind = std.meta.activeTag(host.zuiSurface(.main));
    if (!Host.zui_surfaces.contains(surface_kind)) {
        return .init(error.SurfaceNotDeclared, "gave a .{t} surface, which its zui_surfaces does not name", .{surface_kind});
    }

    var group: std.Io.Group = .init;
    try group.concurrent(io, wakeFromAnotherThread, .{host.zuiWaker()});
    group.await(io) catch {};
    if (try expectPromptPoll(host, &builder, conformance, "after a wake from another thread")) |violation| return violation;

    if (try host_conformance.expectPostedEvents(host, harness, &builder, conformance)) |violation| return violation;
    if (@hasDecl(Harness, "close")) {
        harness.close();
        if (host.zuiPoll(.main, &builder)) return .init(error.ClosedWindowPolled, "polled true after its window was closed", .{});
    }
    return null;
}

fn expectPromptPoll(host: anytype, builder: *zui.RecordBuilder, conformance: HostConformance, comptime context: []const u8) !?HostViolation {
    const started = now(conformance.io);
    if (!host.zuiPoll(.main, builder)) return .init(error.WindowClosed, "closed its window when polled " ++ context, .{});
    const polled_for = now(conformance.io).nanoseconds -| started.nanoseconds;
    if (polled_for > conformance.prompt_ns) return .init(error.PollBlocked, "took {d} ms to poll " ++ context ++ "; a poll never blocks", .{milliseconds(polled_for)});
    return null;
}

fn wakeFromAnotherThread(waker: zui.Waker) void {
    waker.wake();
}

/// A mistake `PushedQueueHost` makes, which the suite must catch.
const PushedFlaw = enum {
    none,
    /// It steps at once when a step asks for an instant.
    steps_at_once_for_at,
    /// It never tells the driver its surface was taken away.
    ignores_lost_surface,
    /// It returns from `zuiRun` without stopping the driver.
    never_stops,
};

/// A platform's loop in miniature: it steps the driver, then waits as the
/// step asked, on an `Io.Event` its waker and its platform's events set.
fn PushedQueueHost(comptime flaw: PushedFlaw) type {
    return struct {
        const Self = @This();
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

        io: std.Io,
        woken: std.Io.Event = .unset,
        surface_taken: bool = false,
        surface_given_back: bool = false,
        quitting: std.atomic.Value(bool) = .init(false),

        const longest_wait_ns = 10 * std.time.ns_per_s;

        pub fn zuiRun(self: *Self, io: std.Io, _: zui.WindowOptions, driver: zui.Driver) !void {
            self.io = io;
            try driver.start(io);
            defer if (flaw != .never_stops) driver.stop();
            var suspended = false;
            while (!self.quitting.load(.acquire)) {
                if (self.surface_taken and !suspended and flaw != .ignores_lost_surface) {
                    driver.suspendSurfaces();
                    suspended = true;
                }
                if (self.surface_given_back and suspended) {
                    try driver.resumeSurfaces();
                    suspended = false;
                }
                const next = try driver.step() orelse return;
                self.waitFor(if (flaw == .steps_at_once_for_at and next == .at) .immediately else next);
            }
        }

        fn waitFor(self: *Self, next: zui.NextFrame) void {
            const deadline: zui.Instant = switch (next) {
                .immediately => return,
                .at => |instant| instant,
                .on_event => now(self.io).addNanoseconds(longest_wait_ns),
            };
            const awake_deadline: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = deadline.nanoseconds }, .clock = .awake };
            while (!self.woken.isSet() and now(self.io).isBefore(deadline)) {
                self.woken.waitTimeout(self.io, .{ .deadline = awake_deadline }) catch {};
            }
            self.woken.reset();
        }

        pub fn zuiPoll(self: *Self, window: zui.WindowId, record: *zui.RecordBuilder) bool {
            std.debug.assert(window == .main);
            record.begin(.{ .now = now(self.io), .viewport = .{ 800, 600 } });
            return true;
        }

        pub fn zuiWaker(self: *Self) zui.Waker {
            return .{ .context = self, .wakeFn = wake };
        }

        pub fn zuiSurface(_: *Self, window: zui.WindowId) zui.Surface {
            std.debug.assert(window == .main);
            return .{ .offscreen = .{ .size = .{ 800, 600 } } };
        }

        pub fn zuiApply(_: *Self, _: zui.WindowId, _: zui.HostRequests) void {}

        fn wake(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.woken.set(self.io);
        }
    };
}

fn PushedQueueHostHarness(comptime Host: type) type {
    return struct {
        const Self = @This();

        pushed_host: Host,

        pub fn host(self: *Self) *Host {
            return &self.pushed_host;
        }

        pub fn takeSurfaceAway(self: *Self) void {
            self.pushed_host.surface_taken = true;
            self.pushed_host.woken.set(self.pushed_host.io);
        }

        pub fn giveSurfaceBack(self: *Self) void {
            self.pushed_host.surface_given_back = true;
            self.pushed_host.woken.set(self.pushed_host.io);
        }

        pub fn quit(self: *Self) void {
            self.pushed_host.quitting.store(true, .release);
        }
    };
}

/// A window its application steps: it reports what its harness posts,
/// and with `blocks_in_poll` waits in every poll as a pulled host waits.
fn SteppedQueueHost(comptime blocks_in_poll: bool) type {
    return struct {
        const Self = @This();
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

        io: std.Io,
        queued: [16]zui.Event = undefined,
        queued_count: usize = 0,
        window_open: bool = true,

        pub fn zuiPoll(self: *Self, window: zui.WindowId, record: *zui.RecordBuilder) bool {
            std.debug.assert(window == .main);
            if (!self.window_open) return false;
            if (blocks_in_poll) self.io.sleep(.fromNanoseconds(150 * std.time.ns_per_ms), .awake) catch {};
            record.begin(.{ .now = now(self.io), .viewport = .{ 800, 600 } });
            for (self.queued[0..self.queued_count]) |event| switch (event) {
                .text => |text| record.appendText(text),
                else => record.append(event),
            };
            self.queued_count = 0;
            return true;
        }

        pub fn zuiWaker(self: *Self) zui.Waker {
            return .{ .context = self, .wakeFn = ignoreWake };
        }

        pub fn zuiSurface(_: *Self, window: zui.WindowId) zui.Surface {
            std.debug.assert(window == .main);
            return .{ .offscreen = .{ .size = .{ 800, 600 } } };
        }

        pub fn zuiApply(_: *Self, _: zui.WindowId, _: zui.HostRequests) void {}

        fn ignoreWake(_: *anyopaque) void {}
    };
}

fn SteppedQueueHostHarness(comptime Host: type) type {
    return struct {
        const Self = @This();

        stepped_host: Host,

        pub fn host(self: *Self) *Host {
            return &self.stepped_host;
        }

        pub fn post(self: *Self, event: zui.Event) bool {
            self.stepped_host.queued[self.stepped_host.queued_count] = event;
            self.stepped_host.queued_count += 1;
            return true;
        }

        pub fn close(self: *Self) void {
            self.stepped_host.window_open = false;
        }
    };
}

test "a pushed host that keeps the contract passes the suite" {
    const Host = PushedQueueHost(.none);
    var harness: PushedQueueHostHarness(Host) = .{ .pushed_host = .{ .io = std.testing.io } };
    try expectPushedHostConforms(Host, &harness, .{ .io = std.testing.io });
}

test "a pushed host that steps before the instant a step asked for fails the suite" {
    const Host = PushedQueueHost(.steps_at_once_for_at);
    var harness: PushedQueueHostHarness(Host) = .{ .pushed_host = .{ .io = std.testing.io } };
    const violation = (try findPushedHostViolation(Host, &harness, .{ .io = std.testing.io })).?;
    try std.testing.expectEqual(error.SteppedBeforeInstant, violation.kind);
    try std.testing.expect(std.mem.endsWith(u8, violation.description(), " ms before the instant a step asked for"));
}

test "a pushed host that never reports a lost surface fails the suite" {
    const Host = PushedQueueHost(.ignores_lost_surface);
    var harness: PushedQueueHostHarness(Host) = .{ .pushed_host = .{ .io = std.testing.io } };
    const violation = (try findPushedHostViolation(Host, &harness, .{ .io = std.testing.io, .event_arrival_ns = 50 * std.time.ns_per_ms })).?;
    try std.testing.expectEqual(error.SurfaceLossNotReported, violation.kind);
    try std.testing.expectEqualStrings("did not call Driver.suspendSurfaces within 50 ms of its platform taking the surface away", violation.description());
}

test "a pushed host that returns without stopping the driver fails the suite" {
    const Host = PushedQueueHost(.never_stops);
    var harness: PushedQueueHostHarness(Host) = .{ .pushed_host = .{ .io = std.testing.io } };
    const violation = (try findPushedHostViolation(Host, &harness, .{ .io = std.testing.io })).?;
    try std.testing.expectEqual(error.NotStopped, violation.kind);
    try std.testing.expectEqualStrings("returned from zuiRun without calling Driver.stop", violation.description());
}

test "a stepped host that keeps the contract passes the suite" {
    const Host = SteppedQueueHost(false);
    var harness: SteppedQueueHostHarness(Host) = .{ .stepped_host = .{ .io = std.testing.io } };
    try expectSteppedHostConforms(Host, &harness, .{ .io = std.testing.io });
}

test "a stepped host whose poll waits fails the suite" {
    const Host = SteppedQueueHost(true);
    var harness: SteppedQueueHostHarness(Host) = .{ .stepped_host = .{ .io = std.testing.io } };
    const violation = (try findSteppedHostViolation(Host, &harness, .{ .io = std.testing.io, .prompt_ns = 100 * std.time.ns_per_ms })).?;
    try std.testing.expectEqual(error.PollBlocked, violation.kind);
    try std.testing.expect(std.mem.endsWith(u8, violation.description(), " ms to poll with nothing to report; a poll never blocks"));
}

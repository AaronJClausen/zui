const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app.zig");

const testing = std.testing;
const frame_interval_ns = 16 * std.time.ns_per_ms;

/// An offscreen window whose OS events are scripted, one list per poll, on
/// a clock that advances a frame per poll. Its waits only record what they
/// were asked, so a test never sleeps.
const TestHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
    pub const zuiClipboard = struct {};

    window: zui.WindowOptions,
    closes_after_polls: u32 = 1,
    script: []const []const zui.Event = &.{},
    /// Events appended to every record, beyond what it can hold.
    flood: u32 = 0,
    polls: u32 = 0,
    waits: [16]zui.NextFrame = undefined,
    wait_count: usize = 0,
    applied: zui.HostRequests = .{},
    closed: bool = false,

    pub fn init(self: *TestHost, _: std.Io, window: zui.WindowOptions) !void {
        self.* = .{ .window = window };
    }

    pub fn deinit(self: *TestHost) void {
        self.closed = true;
    }

    pub fn zuiPoll(self: *TestHost, _: zui.WindowId, record: *zui.RecordBuilder) bool {
        if (self.polls == self.closes_after_polls) return false;
        record.begin(.{ .now = self.now(), .viewport = .{ 400, 300 }, .scale = 2 });
        if (self.polls < self.script.len) for (self.script[self.polls]) |event| switch (event) {
            .text => |text| record.appendText(text),
            else => record.append(event),
        };
        for (0..self.flood) |_| record.append(.{ .pointer_leave = .mouse });
        self.polls += 1;
        return true;
    }

    pub fn zuiWaker(self: *TestHost) zui.Waker {
        return .{ .context = self, .wakeFn = ignoreWake };
    }

    pub fn zuiWait(self: *TestHost, next: zui.NextFrame) void {
        if (self.wait_count < self.waits.len) self.waits[self.wait_count] = next;
        self.wait_count += 1;
    }

    pub fn zuiSurface(_: *TestHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 800, 600 } } };
    }

    pub fn zuiApply(self: *TestHost, _: zui.WindowId, requests: zui.HostRequests) void {
        self.applied = requests;
    }

    fn now(self: *const TestHost) zui.Instant {
        return .fromNanoseconds(@as(u64, self.polls + 1) * frame_interval_ns);
    }

    fn ignoreWake(_: *anyopaque) void {}
};

/// Counts what it was given to draw, on which thread, and is its own text
/// contract, at 8 by 16 units a byte.
fn TestRenderer(comptime submits_on_any_thread: bool) type {
    return struct {
        const Self = @This();
        pub const zui_surfaces: zui.SurfaceKinds = .initMany(&.{ .offscreen, .library });
        pub const zui_commands: zui.CommandSet = .initOne(.shadow);
        pub const zui_render_thread = submits_on_any_thread;

        frame_numbers: [32]u64 = undefined,
        threads: [32]std.Thread.Id = undefined,
        submitted: usize = 0,
        zoom: f32 = 0,
        fails_at_frame: ?u64 = null,

        pub fn zuiMeasure(_: *Self, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
            return .{ @as(f32, @floatFromInt(run.len)) * key.size / 2, key.size };
        }

        pub fn zuiSubmit(self: *Self, surface: zui.Surface, frame: anytype) !void {
            if (surface != .offscreen) return error.UnsupportedSurface;
            if (self.fails_at_frame == frame.number) return error.DeviceLost;
            self.frame_numbers[self.submitted] = frame.number;
            self.threads[self.submitted] = std.Thread.getCurrentId();
            self.submitted += 1;
            self.zoom = frame.params.zoom;
        }
    };
}

const Notices = struct {
    var recorded: [16]zui_app.Notice = undefined;
    var count: usize = 0;

    fn record(notice: zui_app.Notice) void {
        if (count < recorded.len) recorded[count] = notice;
        count += 1;
    }

    fn clear() void {
        count = 0;
    }

    fn countOf(tag: std.meta.Tag(zui_app.Notice)) usize {
        var matching: usize = 0;
        for (recorded[0..@min(count, recorded.len)]) |notice| {
            if (notice == tag) matching += 1;
        }
        return matching;
    }

    fn first(tag: std.meta.Tag(zui_app.Notice)) zui_app.Notice {
        for (recorded[0..@min(count, recorded.len)]) |notice| {
            if (notice == tag) return notice;
        }
        unreachable;
    }
};

fn runToClose(runner: anytype) !u32 {
    var frames: u32 = 0;
    while (try runner.frame()) frames += 1;
    return frames;
}

const save: zui.Id = .of("save");
const pointer_at_save: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 10, 10 }, .at = .fromNanoseconds(frame_interval_ns) };
const click_and_typing = [_]zui.Event{
    .{ .pointer_move = .{ .pointer = pointer_at_save } },
    .{ .pointer_down = .{ .pointer = pointer_at_save } },
    .{ .pointer_up = .{ .pointer = pointer_at_save } },
    .{ .text = "ok" },
};

const ClickApp = struct {
    pub const Host = TestHost;
    pub const Renderer = TestRenderer(false);
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 64 } }));

    clicks: u32 = 0,
    typed: [16]u8 = undefined,
    typed_len: usize = 0,
    declarations: u32 = 0,
    loads_after_declaration: u32 = 0,
    title: []const u8 = "",

    pub fn init(app: *ClickApp, start: zui_app.Start(ClickApp)) !void {
        app.* = .{ .title = start.host.window.title };
        start.host.closes_after_polls = 3;
        start.host.script = &.{ &.{}, &click_and_typing };
    }

    pub fn zuiDeclare(app: *ClickApp, ui: *Ui) void {
        app.declarations += 1;
        if (ui.clicked(save)) app.clicks += 1;
        const typed = ui.typedText();
        @memcpy(app.typed[app.typed_len..][0..typed.len], typed);
        app.typed_len += typed.len;
        ui.box(.{ .id = save, .interactive = true, .cursor = .pointer, .decoration = .{ .background = .black }, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
        ui.text("Save", .{});
    }

    pub fn zuiLoader(app: *ClickApp, _: *const Ui, _: std.Io) void {
        if (app.loads_after_declaration + 1 == app.declarations) app.loads_after_declaration += 1;
    }
};

test "the runner opens the window, runs the loop until it closes, and applies its requests" {
    var runner: zui_app.Runner(ClickApp) = undefined;
    try runner.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .title = "clicks", .zoom = 1.5, .notify = Notices.record });
    try testing.expectEqual(@as(u32, 3), try runToClose(&runner));

    try testing.expectEqualStrings("clicks", runner.app.title);
    try testing.expectEqual(@as(u32, 1), runner.app.clicks);
    try testing.expectEqualStrings("ok", runner.app.typed[0..runner.app.typed_len]);
    try testing.expectEqual(@as(u32, 3), runner.app.loads_after_declaration);
    try testing.expectEqual(zui.Cursor.pointer, runner.host.applied.cursor);
    try testing.expectEqual(@as(usize, 3), runner.renderer.submitted);
    try testing.expectEqual(@as(f32, 1.5), runner.renderer.zoom);
    for (runner.renderer.threads[0..3]) |thread| try testing.expectEqual(std.Thread.getCurrentId(), thread);
    runner.stop();
    try testing.expect(runner.host.closed);
}

fn FramesApp(comptime Renderer_: type, comptime frames_in_flight: u8, comptime frames: u32) type {
    return struct {
        const Self = @This();
        pub const Host = TestHost;
        pub const Renderer = Renderer_;
        pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 16 }, .frames_in_flight = frames_in_flight }));

        pub fn init(_: *Self, start: zui_app.Start(Self)) !void {
            start.host.closes_after_polls = frames;
        }

        pub fn zuiDeclare(_: *Self, ui: *Ui) void {
            ui.box(.{ .decoration = .{ .background = .white }, .layout = .{ .sizing = .grow_both } });
        }
    };
}

test "a renderer that declares zui_render_thread draws every frame, in order, on a thread of its own" {
    const App = FramesApp(TestRenderer(true), 2, 12);
    var runner: zui_app.Runner(App) = undefined;
    try runner.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    try testing.expectEqual(zui_app.Submission.render_thread, runner.report.submission);
    try testing.expectEqual(@as(u32, 12), try runToClose(&runner));
    runner.stop();

    try testing.expectEqual(@as(usize, 12), runner.renderer.submitted);
    for (runner.renderer.frame_numbers[0..12], 0..) |number, expected| try testing.expectEqual(@as(u64, expected), number);
    for (runner.renderer.threads[0..12]) |thread| try testing.expect(thread != std.Thread.getCurrentId());
}

test "frames are submitted on the UI thread, with the reason reported, when a render thread cannot be used" {
    const cases = .{
        .{ FramesApp(TestRenderer(false), 2, 2), true, testing.io, zui_app.Submission.Reason.renderer_needs_its_thread },
        .{ FramesApp(TestRenderer(true), 1, 2), true, testing.io, zui_app.Submission.Reason.one_frame_in_flight },
        .{ FramesApp(TestRenderer(true), 2, 2), false, testing.io, zui_app.Submission.Reason.turned_off_in_options },
        .{ FramesApp(TestRenderer(true), 2, 2), true, singleThreadedIo(), zui_app.Submission.Reason.io_cannot_run_concurrently },
    };
    inline for (cases) |case| {
        var runner: zui_app.Runner(case[0]) = undefined;
        try runner.start(.{ .gpa = testing.allocator, .io = case[2] }, .{ .render_thread = case[1], .notify = Notices.record });
        defer runner.stop();
        try testing.expectEqual(zui_app.Submission{ .ui_thread = case[3] }, runner.report.submission);
        try testing.expectEqual(@as(u32, 2), try runToClose(&runner));
        for (runner.renderer.threads[0..2]) |thread| try testing.expectEqual(std.Thread.getCurrentId(), thread);
    }
}

fn singleThreadedIo() std.Io {
    const instance = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return instance.threaded.io();
}

test "an error drawing on the render thread is returned by a later frame" {
    const App = FramesApp(TestRenderer(true), 2, 20);
    var runner: zui_app.Runner(App) = undefined;
    try runner.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer runner.stop();
    runner.renderer.fails_at_frame = 3;
    try testing.expectError(error.DeviceLost, runToClose(&runner));
    try testing.expect(runner.host.polls <= 6);
}

test "the start reports the host's capabilities, where frames are drawn, and every fallback" {
    Notices.clear();
    const App = FramesApp(TestRenderer(false), 2, 1);
    var runner: zui_app.Runner(App) = undefined;
    try runner.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer runner.stop();

    try testing.expectEqual(@as(usize, 1), Notices.count);
    const report = Notices.first(.started).started;
    try testing.expect(report.lowered.contains(.gradient) and !report.lowered.contains(.shadow));
    try testing.expect(!report.missing_services.contains(.clipboard) and report.missing_services.contains(.file_dialogs));
    try testing.expectEqual(zui.SurfaceKinds.initOne(.offscreen), report.surfaces);
    try testing.expectEqual(zui.HostCapabilities{}, report.capabilities);

    const described = try std.fmt.allocPrint(testing.allocator, "{f}", .{Notices.first(.started)});
    defer testing.allocator.free(described);
    try testing.expect(std.mem.endsWith(u8, described, "; one window; no system material, so the root draws its own background; submitting on the UI thread, since the renderer does not declare zui_render_thread; lowered: gradient, backdrop_blur, transform, material; no host notifications, file_dialogs, open_url, menus, file_watch"));
}

const FloodApp = struct {
    pub const Host = TestHost;
    pub const Renderer = TestRenderer(false);
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8, .max_events_per_frame = 4, .max_text_input_bytes = 8 } }));

    pub fn init(_: *FloodApp, start: zui_app.Start(FloodApp)) !void {
        start.host.closes_after_polls = 3;
        start.host.flood = 10;
    }

    pub fn zuiDeclare(_: *FloodApp, ui: *Ui) void {
        for (0..20) |_| ui.box(.{});
    }
};

test "dropped input and an exceeded limit are each reported once, naming what to raise" {
    Notices.clear();
    var runner: zui_app.Runner(FloodApp) = undefined;
    try runner.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer runner.stop();
    try testing.expectEqual(@as(u32, 3), try runToClose(&runner));

    try testing.expectEqual(@as(usize, 3), Notices.count);
    try testing.expectEqual(@as(u32, 6), Notices.first(.input_dropped).input_dropped.events);
    const exceeded = Notices.first(.limit_exceeded).limit_exceeded;
    try testing.expectEqual(zui.Limit.max_elements, exceeded.limit);
    try testing.expectEqual(@as(u32, 8), exceeded.allowed);
    try testing.expectEqual(@as(u32, 21), exceeded.needed);

    const described = try std.fmt.allocPrint(testing.allocator, "{f}", .{Notices.first(.limit_exceeded)});
    defer testing.allocator.free(described);
    try testing.expect(std.mem.startsWith(u8, described, "limits.max_elements is 8, but a frame needed 21; what fit was drawn"));
}

/// The newest number published, swapped at `beginFrame`.
const Counter = struct {
    pub const Delivery = ?u32;
    pub const View = ?u32;

    published: ?u32 = null,
    readable: ?u32 = null,

    pub fn zuiSwap(self: *Counter) void {
        self.readable = self.published;
        self.published = null;
    }

    pub fn zuiView(self: *Counter) View {
        return self.readable;
    }

    pub fn zuiDelivery(self: *const Counter, delivery: *Delivery) void {
        delivery.* = self.readable;
    }

    pub fn zuiInject(self: *Counter, delivery: *const Delivery) void {
        self.readable = delivery.*;
    }

    pub fn zuiPending(self: *const Counter) bool {
        return self.published != null;
    }
};

const PacedApp = struct {
    pub const Host = TestHost;
    pub const Renderer = TestRenderer(false);
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8 }, .Sources = Sources }));
    const Sources = struct { counter: Counter = .{} };

    sources: Sources = .{},
    frames: u32 = 0,
    seen: ?u32 = null,

    pub fn init(app: *PacedApp, start: zui_app.Start(PacedApp)) !void {
        app.* = .{};
        start.host.closes_after_polls = 4;
    }

    pub fn zuiDeclare(app: *PacedApp, ui: *Ui) void {
        if (ui.source(.counter)) |value| app.seen = value;
        if (app.frames == 0) ui.requestFrameAt(.fromNanoseconds(1_000 * frame_interval_ns));
        ui.box(.{});
    }

    pub fn zuiLoader(app: *PacedApp, _: *const Ui, _: std.Io) void {
        if (app.frames == 1) app.sources.counter.published = 7;
        app.frames += 1;
    }
};

test "the host waits as nextFrame says, after the loader, with the application's sources" {
    var runner: zui_app.Runner(PacedApp) = undefined;
    try runner.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer runner.stop();
    try testing.expectEqual(@as(u32, 4), try runToClose(&runner));

    const waits = runner.host.waits[0..runner.host.wait_count];
    try testing.expectEqual(@as(usize, 4), waits.len);
    try testing.expectEqual(zui.NextFrame{ .at = .fromNanoseconds(1_000 * frame_interval_ns) }, waits[0]);
    try testing.expectEqual(zui.NextFrame.immediately, waits[1]);
    try testing.expectEqual(zui.NextFrame.on_event, waits[2]);
    try testing.expectEqual(@as(?u32, 7), runner.app.seen);
}

test "contextConfig takes the renderer's commands, payload types and text contract" {
    const Renderer = struct {
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const zui_commands: zui.CommandSet = .initMany(&.{ .gradient, .material });
        pub const ImageHandle = u32;
        pub const MaterialHandle = u8;
        pub const FontId = enum(u8) { body, heading };

        pub fn zuiSubmit(_: *@This(), _: zui.Surface, _: anytype) !void {}
        pub fn zuiMeasure(_: *@This(), _: []const u8, _: zui.MeasureKey(FontId)) [2]f32 {
            return .{ 0, 0 };
        }
    };
    const config = zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 32 }, .CustomData = u64, .ImageHandle = u16 });
    try testing.expectEqual(zui.CommandSet.initMany(&.{ .gradient, .material }), config.commands);
    try testing.expect(config.ImageHandle == u32 and config.MaterialHandle == u8 and config.CustomData == void);
    try testing.expect(config.FontId == Renderer.FontId and config.Text == Renderer);
    try testing.expectEqual(@as(u32, 32), config.limits.max_elements);
}

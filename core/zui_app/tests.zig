const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app.zig");

const testing = std.testing;
const frame_interval_ns = 16 * std.time.ns_per_ms;

/// An offscreen window whose OS events are scripted, one list per poll, on
/// a clock that advances a frame per poll, opened in HDR when the renderer
/// draws it. Its waits only record what they were asked, so a test never
/// sleeps.
const TestHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
    pub const zui_output_formats: zui.OutputFormats = .initMany(&.{ .sdr, .scrgb_fp16 });
    pub const zuiClipboard = struct {
        pub fn write(host: *TestHost, text: []const u8) zui.ServiceError!void {
            if (text.len > host.clipboard.len) return error.TooLarge;
            @memcpy(host.clipboard[0..text.len], text);
            host.clipboard_len = text.len;
        }

        pub fn read(host: *TestHost, request: zui.ServiceRequest, sink: zui.ServiceSink) zui.ServiceError!void {
            _ = sink.publish(&.{ .request = request, .outcome = .{ .clipboard_text = host.clipboard[0..host.clipboard_len] } });
        }
    };

    window: zui.WindowOptions,
    /// A setting made on the type, which `init` keeps.
    scale: f32 = 2,
    closes_after_polls: u32 = 1,
    script: []const []const zui.Event = &.{},
    /// Events appended to every record, beyond what it can hold.
    flood: u32 = 0,
    polls: u32 = 0,
    waits: [16]zui.NextFrame = undefined,
    wait_count: usize = 0,
    applied: zui.HostRequests = .{},
    closed: bool = false,
    clipboard: [64]u8 = undefined,
    clipboard_len: usize = 0,

    pub fn init(self: *TestHost, _: std.Io, window: zui.WindowOptions) !void {
        self.* = .{ .window = window, .scale = self.scale };
    }

    pub fn deinit(self: *TestHost) void {
        self.closed = true;
    }

    pub fn zuiPoll(self: *TestHost, _: zui.WindowId, record: *zui.RecordBuilder) bool {
        if (self.polls == self.closes_after_polls) return false;
        record.begin(.{ .now = self.now(), .viewport = .{ 400, 300 }, .scale = self.scale });
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

    pub fn zuiSurface(self: *TestHost, _: zui.WindowId) zui.Surface {
        const format: zui.OutputFormat = if (self.window.output_formats.contains(.scrgb_fp16)) .scrgb_fp16 else .sdr;
        return .{ .offscreen = .{ .size = .{ 800, 600 }, .format = format } };
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

fn runToClose(session: anytype) !u32 {
    var frames: u32 = 0;
    while (try session.frame()) frames += 1;
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

test "a session opens the window, runs the loop until it closes, and applies its requests" {
    var session: zui_app.Session(ClickApp) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .title = "clicks", .zoom = 1.5, .notify = Notices.record });
    try testing.expectEqual(@as(u32, 3), try runToClose(&session));

    try testing.expectEqualStrings("clicks", session.app.title);
    try testing.expectEqual(@as(u32, 1), session.app.clicks);
    try testing.expectEqualStrings("ok", session.app.typed[0..session.app.typed_len]);
    try testing.expectEqual(@as(u32, 3), session.app.loads_after_declaration);
    try testing.expectEqual(zui.Cursor.pointer, session.host.applied.cursor);
    try testing.expectEqual(@as(usize, 3), session.renderer.submitted);
    try testing.expectEqual(@as(f32, 1.5), session.renderer.zoom);
    for (session.renderer.threads[0..3]) |thread| try testing.expectEqual(std.Thread.getCurrentId(), thread);
    session.stop();
    try testing.expect(session.host.closed);
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

fn ObservingApp(comptime Renderer_: type) type {
    return struct {
        const Self = @This();
        pub const Host = TestHost;
        pub const Renderer = Renderer_;
        pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 16 }, .frames_in_flight = 2 }));
        const frame_count = 4;

        renderer: *Renderer = undefined,
        observed_numbers: [frame_count]u64 = undefined,
        submitted_when_observed: [frame_count]usize = undefined,
        elements_observed: [frame_count]u32 = undefined,
        observed: usize = 0,
        thread_observed_on: ?std.Thread.Id = null,

        pub fn init(app: *Self, start: zui_app.Start(Self)) !void {
            app.* = .{ .renderer = start.renderer };
            start.host.closes_after_polls = frame_count;
        }

        pub fn zuiDeclare(_: *Self, ui: *Ui) void {
            ui.box(.{ .layout = .{ .sizing = .grow_both } });
        }

        pub fn zuiObserve(app: *Self, _: *const Ui, frame: *const Ui.Frame) void {
            app.observed_numbers[app.observed] = frame.number;
            if (!Renderer.zui_render_thread) app.submitted_when_observed[app.observed] = app.renderer.submitted;
            app.elements_observed[app.observed] = frame.elementCount();
            app.observed += 1;
            app.thread_observed_on = std.Thread.getCurrentId();
        }
    };
}

test "zuiObserve reads each frame on the UI thread, before it is submitted" {
    inline for (.{ TestRenderer(false), TestRenderer(true) }) |Renderer| {
        const App = ObservingApp(Renderer);
        var session: zui_app.Session(App) = undefined;
        try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
        try testing.expectEqual(@as(u32, App.frame_count), try runToClose(&session));
        session.stop();

        try testing.expectEqual(@as(usize, App.frame_count), session.app.observed);
        try testing.expectEqual(std.Thread.getCurrentId(), session.app.thread_observed_on.?);
        for (session.app.observed_numbers, session.app.elements_observed, 0..) |number, elements, index| {
            try testing.expectEqual(@as(u64, index), number);
            try testing.expectEqual(@as(u32, 2), elements);
        }
        if (!Renderer.zui_render_thread) {
            for (session.app.submitted_when_observed, 0..) |submitted, index| try testing.expectEqual(index, submitted);
        }
    }
}

test "a renderer that declares zui_render_thread draws every frame, in order, on a thread of its own" {
    const App = FramesApp(TestRenderer(true), 2, 12);
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    try testing.expectEqual(zui_app.Submission.render_thread, session.report.submission);
    try testing.expectEqual(@as(u32, 12), try runToClose(&session));
    session.stop();

    try testing.expectEqual(@as(usize, 12), session.renderer.submitted);
    for (session.renderer.frame_numbers[0..12], 0..) |number, expected| try testing.expectEqual(@as(u64, expected), number);
    for (session.renderer.threads[0..12]) |thread| try testing.expect(thread != std.Thread.getCurrentId());
}

test "frames are submitted on the UI thread, with the reason reported, when a render thread cannot be used" {
    const cases = .{
        .{ FramesApp(TestRenderer(false), 2, 2), true, testing.io, zui_app.Submission.Reason.renderer_needs_its_thread },
        .{ FramesApp(TestRenderer(true), 1, 2), true, testing.io, zui_app.Submission.Reason.one_frame_in_flight },
        .{ FramesApp(TestRenderer(true), 2, 2), false, testing.io, zui_app.Submission.Reason.turned_off_in_options },
        .{ FramesApp(TestRenderer(true), 2, 2), true, singleThreadedIo(), zui_app.Submission.Reason.io_cannot_run_concurrently },
    };
    inline for (cases) |case| {
        var session: zui_app.Session(case[0]) = undefined;
        try session.start(.{ .gpa = testing.allocator, .io = case[2] }, .{ .render_thread = case[1], .notify = Notices.record });
        defer session.stop();
        try testing.expectEqual(zui_app.Submission{ .ui_thread = case[3] }, session.report.submission);
        try testing.expectEqual(@as(u32, 2), try runToClose(&session));
        for (session.renderer.threads[0..2]) |thread| try testing.expectEqual(std.Thread.getCurrentId(), thread);
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
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    session.renderer.fails_at_frame = 3;
    try testing.expectError(error.DeviceLost, runToClose(&session));
    try testing.expect(session.host.polls <= 6);
}

test "the start reports the host's capabilities, where frames are drawn, and every fallback" {
    Notices.clear();
    const App = FramesApp(TestRenderer(false), 2, 1);
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();

    try testing.expectEqual(@as(usize, 1), Notices.count);
    const report = Notices.first(.started).started;
    try testing.expect(report.lowered.contains(.gradient) and !report.lowered.contains(.shadow));
    try testing.expect(!report.missing_services.contains(.clipboard) and report.missing_services.contains(.file_dialogs));
    try testing.expectEqual(zui.SurfaceKinds.initOne(.offscreen), report.surfaces);
    try testing.expectEqual(zui.HostCapabilities{}, report.capabilities);
    try testing.expectEqual(zui.OutputFormats.initOne(.sdr), report.output_formats);
    try testing.expectEqual(zui.OutputFormats.initOne(.sdr), session.host.window.output_formats);

    const described = try std.fmt.allocPrint(testing.allocator, "{f}", .{Notices.first(.started)});
    defer testing.allocator.free(described);
    try testing.expect(std.mem.endsWith(u8, described, "; one window; no system material, so the root draws its own background; submitting on the UI thread, since the renderer does not declare zui_render_thread; output: sdr; lowered: gradient, backdrop_blur, transform, material; no host notifications, file_dialogs, open_url, menus, file_watch"));
}

/// Draws HDR, and keeps the output format of the last surface it was given.
const HdrRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
    pub const zui_extended_color = true;
    pub const zui_output_formats: zui.OutputFormats = .initMany(&.{ .sdr, .scrgb_fp16 });

    drawn_in: ?zui.OutputFormat = null,

    pub fn zuiSubmit(self: *HdrRenderer, surface: zui.Surface, _: anytype) !void {
        self.drawn_in = surface.outputFormat();
    }
};

test "a host and a renderer that both draw HDR open the window in it" {
    const App = FramesApp(HdrRenderer, 1, 2);
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();

    const both: zui.OutputFormats = .initMany(&.{ .sdr, .scrgb_fp16 });
    try testing.expectEqual(both, session.host.window.output_formats);
    try testing.expectEqual(both, session.report.output_formats);
    _ = try runToClose(&session);
    try testing.expectEqual(@as(?zui.OutputFormat, .scrgb_fp16), session.renderer.drawn_in);
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
    var session: zui_app.Session(FloodApp) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(@as(u32, 3), try runToClose(&session));

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
    var session: zui_app.Session(PacedApp) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(@as(u32, 4), try runToClose(&session));

    const waits = session.host.waits[0..session.host.wait_count];
    try testing.expectEqual(@as(usize, 4), waits.len);
    try testing.expectEqual(zui.NextFrame{ .at = .fromNanoseconds(1_000 * frame_interval_ns) }, waits[0]);
    try testing.expectEqual(zui.NextFrame.immediately, waits[1]);
    try testing.expectEqual(zui.NextFrame.on_event, waits[2]);
    try testing.expectEqual(@as(?u32, 7), session.app.seen);
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
    try testing.expect(!config.extended_color);
}

test "contextConfig takes the renderer's extended color, and keeps the colors the overrides declare in" {
    const Renderer = struct {
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const zui_extended_color = true;

        pub fn zuiSubmit(_: *@This(), _: zui.Surface, _: anytype) !void {}
    };
    const config = zui_app.contextConfig(Renderer, .{ .Color = zui.ExtendedColor });
    try testing.expect(config.extended_color and config.Color == zui.ExtendedColor);
    try testing.expect(zui.Context(config).CommandColor == zui.ExtendedColor);
}

/// Fonts that are not the renderer, at 6 by 12 units a byte.
const Fonts = struct {
    var deinitializations: u32 = 0;

    initialized: bool = false,
    measured: u32 = 0,

    pub fn init(self: *Fonts) !void {
        self.initialized = true;
    }

    pub fn deinit(self: *Fonts) void {
        _ = self;
        deinitializations += 1;
    }

    pub fn zuiMeasure(self: *Fonts, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        self.measured += 1;
        return .{ @as(f32, @floatFromInt(run.len)) * key.size / 2, key.size };
    }
};

/// Draws with the application's fonts, as a renderer whose text contract
/// is a separate type does.
const FontsRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    fonts: *const Fonts,
    submitted: u32 = 0,
    zoom: f32 = 0,
    clear_color: zui.Color = .black,

    pub fn init(self: *FontsRenderer, _: zui.Surface, fonts: *const Fonts) !void {
        self.fonts = fonts;
    }

    pub fn zuiSubmit(self: *FontsRenderer, _: zui.Surface, frame: anytype) !void {
        self.submitted += 1;
        self.zoom = frame.params.zoom;
    }
};

const FontsApp = struct {
    pub const Host = TestHost;
    pub const Renderer = FontsRenderer;
    pub const Text = Fonts;
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8 }, .Text = Fonts, .Sources = Sources }));
    const Sources = struct { counter: Counter = .{} };

    owned_sources: Sources = .{},
    sources: *Sources,
    renderer: *FontsRenderer,
    zoom: f32 = 1.25,
    themes_seen: [3]zui.Environment.Theme = undefined,
    frames: u32 = 0,

    pub fn init(app: *FontsApp, start: zui_app.Start(FontsApp)) !void {
        app.* = .{ .sources = &app.owned_sources, .renderer = start.renderer };
        start.host.closes_after_polls = 3;
        start.renderer.clear_color = .white;
    }

    pub fn zuiRecord(app: *FontsApp, record: *zui.RecordBuilder) void {
        record.params.zoom = app.zoom;
        if (app.frames == 1) record.append(.{ .environment = .{ .theme = .dark } });
    }

    pub fn zuiDeclare(app: *FontsApp, ui: *Ui) void {
        app.themes_seen[app.frames] = ui.environment().theme;
        if (app.frames == 0) app.sources.counter.published = 5;
        if (ui.source(.counter)) |value| app.zoom = @floatFromInt(value);
        ui.text("fonts", .{});
        app.frames += 1;
    }
};

test "an application whose text contract is not the renderer has zui_app make it, for the context and the renderer" {
    var session: zui_app.Session(FontsApp) = undefined;
    session.host.scale = 3;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    try testing.expect(FontsApp.Ui.Text == Fonts and zui_app.Session(FontsApp).Text == Fonts);
    try testing.expect(session.text.initialized);
    try testing.expectEqual(@as(*const Fonts, &session.text), session.renderer.fonts);
    try testing.expectEqual(&session.renderer, session.app.renderer);
    try testing.expectEqual(zui.Color.white, session.renderer.clear_color);
    try testing.expectEqual(@as(f32, 2), session.host.scale);

    try testing.expectEqual(@as(u32, 3), try runToClose(&session));
    try testing.expect(session.text.measured > 0);
    try testing.expectEqual(@as(u32, 3), session.renderer.submitted);
    const deinitializations_before = Fonts.deinitializations;
    session.stop();
    try testing.expectEqual(deinitializations_before + 1, Fonts.deinitializations);
}

/// Names no text contract: it erases whichever it is given.
const AnyTextRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    text: ?*const anyopaque = null,

    pub fn init(self: *AnyTextRenderer, _: zui.Surface, text: anytype) !void {
        self.text = text;
    }

    pub fn zuiSubmit(_: *AnyTextRenderer, _: zui.Surface, _: anytype) !void {}
};

const AnyTextApp = struct {
    pub const Host = TestHost;
    pub const Renderer = AnyTextRenderer;
    pub const Text = Fonts;
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8 }, .Text = Fonts }));

    pub fn init(_: *AnyTextApp, start: zui_app.Start(AnyTextApp)) !void {
        start.host.closes_after_polls = 1;
    }

    pub fn zuiDeclare(_: *AnyTextApp, ui: *Ui) void {
        ui.text("fonts", .{});
    }
};

test "a renderer may take the text it is given as anytype" {
    var session: zui_app.Session(AnyTextApp) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(@as(?*const anyopaque, &session.text), session.renderer.text);
}

/// Keeps the text `init` was given, to add its fonts there.
const TextKeepingApp = struct {
    pub const Host = TestHost;
    pub const Renderer = AnyTextRenderer;
    pub const Text = Fonts;
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8 }, .Text = Fonts }));

    text: ?*Fonts = null,

    pub fn init(app: *TextKeepingApp, start: zui_app.Start(TextKeepingApp)) !void {
        start.host.closes_after_polls = 1;
        app.* = .{ .text = start.text };
    }

    pub fn zuiDeclare(_: *TextKeepingApp, ui: *Ui) void {
        ui.text("fonts", .{});
    }
};

test "init is given the text the context measures with" {
    var session: zui_app.Session(TextKeepingApp) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(&session.text, session.app.text.?);
    try testing.expectEqual(&session.text, session.ui.text_contract);
    try testing.expect(@FieldType(zui_app.Start(ClickApp), "text") == void);
}

test "zuiRecord adds the application's zoom and events to the record, after the host's" {
    var session: zui_app.Session(FontsApp) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .zoom = 1, .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(@as(u32, 3), try runToClose(&session));

    try testing.expectEqualSlices(zui.Environment.Theme, &.{ .light, .dark, .dark }, &session.app.themes_seen);
    try testing.expectEqual(@as(f32, 5), session.renderer.zoom);
}

test "contextConfig keeps a text contract the overrides name, even from a renderer that measures" {
    const config = zui_app.contextConfig(TestRenderer(false), .{ .Text = Fonts });
    try testing.expect(config.Text == Fonts);
}

/// `TestHost` with an accessibility bridge that keeps what it is handed.
const SemanticsHost = struct {
    pub const zui_surfaces = TestHost.zui_surfaces;

    base: TestHost = .{ .window = undefined },
    lists_received: u32 = 0,
    last_node_count: usize = 0,
    last_label: [16]u8 = undefined,
    last_label_len: usize = 0,
    thread_received_on: ?std.Thread.Id = null,
    submitted_when_received: [4]usize = undefined,
    renderer_submitted: ?*const usize = null,
    reports_dropped: zui.SemanticsDropped = .{},

    pub fn init(self: *SemanticsHost, io: std.Io, window: zui.WindowOptions) !void {
        self.* = .{};
        try self.base.init(io, window);
    }

    pub fn deinit(self: *SemanticsHost) void {
        self.base.deinit();
    }

    pub fn zuiPoll(self: *SemanticsHost, window: zui.WindowId, record: *zui.RecordBuilder) bool {
        return self.base.zuiPoll(window, record);
    }

    pub fn zuiWaker(self: *SemanticsHost) zui.Waker {
        return self.base.zuiWaker();
    }

    pub fn zuiWait(self: *SemanticsHost, next: zui.NextFrame) void {
        self.base.zuiWait(next);
    }

    pub fn zuiSurface(self: *SemanticsHost, window: zui.WindowId) zui.Surface {
        return self.base.zuiSurface(window);
    }

    pub fn zuiApply(self: *SemanticsHost, window: zui.WindowId, requests: zui.HostRequests) void {
        self.base.zuiApply(window, requests);
    }

    pub fn zuiSemantics(self: *SemanticsHost, _: zui.WindowId, nodes: []const zui.SemanticNode) zui.SemanticsDropped {
        if (self.renderer_submitted) |submitted| {
            if (self.lists_received < self.submitted_when_received.len) self.submitted_when_received[self.lists_received] = submitted.*;
        }
        self.lists_received += 1;
        self.last_node_count = nodes.len;
        if (nodes.len > 0) {
            self.last_label_len = @min(nodes[0].label.len, self.last_label.len);
            @memcpy(self.last_label[0..self.last_label_len], nodes[0].label[0..self.last_label_len]);
        }
        self.thread_received_on = std.Thread.getCurrentId();
        return self.reports_dropped;
    }
};

fn AccessibleApp(comptime Host_: type, comptime Renderer_: type, comptime semantics: bool) type {
    return struct {
        const Self = @This();
        pub const Host = Host_;
        pub const Renderer = Renderer_;
        pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 16 }, .features = .{ .semantics = semantics } }));
        const frame_count = 3;

        pub fn init(_: *Self, start: zui_app.Start(Self)) !void {
            const host_closing = if (Host == SemanticsHost) &start.host.base else start.host;
            host_closing.closes_after_polls = frame_count;
            if (Host == SemanticsHost and !Renderer.zui_render_thread) start.host.renderer_submitted = &start.renderer.submitted;
        }

        pub fn zuiDeclare(_: *Self, ui: *Ui) void {
            ui.box(.{ .id = save, .interactive = true, .semantics = .{ .role = .button, .label = "Save" }, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
        }
    };
}

test "a host that bridges semantics is handed each frame's list on the UI thread, before the frame is submitted" {
    inline for (.{ TestRenderer(false), TestRenderer(true) }) |Renderer| {
        const App = AccessibleApp(SemanticsHost, Renderer, true);
        var session: zui_app.Session(App) = undefined;
        try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
        try testing.expectEqual(zui.SemanticsCapacity{ .nodes = 16, .text_bytes = App.Ui.limits.max_text_bytes }, session.host.base.window.semantics);
        try testing.expectEqual(zui_app.Accessibility.bridged, session.report.accessibility);
        try testing.expectEqual(@as(u32, App.frame_count), try runToClose(&session));
        session.stop();

        try testing.expectEqual(@as(u32, App.frame_count), session.host.lists_received);
        try testing.expectEqual(@as(usize, 1), session.host.last_node_count);
        try testing.expectEqualStrings("Save", session.host.last_label[0..session.host.last_label_len]);
        try testing.expectEqual(std.Thread.getCurrentId(), session.host.thread_received_on.?);
        if (!Renderer.zui_render_thread) {
            for (session.host.submitted_when_received[0..App.frame_count], 0..) |submitted, index| try testing.expectEqual(index, submitted);
        }
    }
}

test "without semantics a bridging host is never handed a list, and opens its window without room for one" {
    const App = AccessibleApp(SemanticsHost, TestRenderer(false), false);
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(zui.SemanticsCapacity{}, session.host.base.window.semantics);
    try testing.expectEqual(zui_app.Accessibility.off, session.report.accessibility);
    _ = try runToClose(&session);
    try testing.expectEqual(@as(u32, 0), session.host.lists_received);
}

test "semantics on a host without a bridge are reported as a fallback" {
    Notices.clear();
    const App = AccessibleApp(TestHost, TestRenderer(false), true);
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(zui.SemanticsCapacity{}, session.host.window.semantics);
    try testing.expectEqual(zui_app.Accessibility.not_bridged, session.report.accessibility);
    const described = try std.fmt.allocPrint(testing.allocator, "{f}", .{Notices.first(.started)});
    defer testing.allocator.free(described);
    try testing.expect(std.mem.endsWith(u8, described, "; semantics on, but the host bridges none to an accessibility API"));
}

test "a bridge without room for the list is reported once" {
    Notices.clear();
    const App = AccessibleApp(SemanticsHost, TestRenderer(false), true);
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    session.host.reports_dropped = .{ .nodes = 2, .text_bytes = 5 };
    _ = try runToClose(&session);

    try testing.expectEqual(@as(usize, 1), Notices.countOf(.semantics_dropped));
    const described = try std.fmt.allocPrint(testing.allocator, "{f}", .{Notices.first(.semantics_dropped)});
    defer testing.allocator.free(described);
    try testing.expectEqualStrings("the host's accessibility bridge had no room for 2 semantic nodes and 5 bytes of their text; an assistive technology sees the rest", described);
}

/// `TestHost` that leaves the title bar to the application, and counts the
/// chrome it is handed on each frame.
const TitleBarHost = struct {
    pub const zui_surfaces = TestHost.zui_surfaces;
    pub const zui_capabilities: zui.HostCapabilities = .{ .custom_title_bar = true };

    base: TestHost = .{ .window = undefined },
    lists_received: u32 = 0,
    last_kinds: [4]zui.ChromeKind = undefined,
    last_count: usize = 0,
    thread_received_on: ?std.Thread.Id = null,

    pub fn init(self: *TitleBarHost, io: std.Io, window: zui.WindowOptions) !void {
        self.* = .{};
        try self.base.init(io, window);
    }

    pub fn deinit(self: *TitleBarHost) void {
        self.base.deinit();
    }

    pub fn zuiPoll(self: *TitleBarHost, window: zui.WindowId, record: *zui.RecordBuilder) bool {
        return self.base.zuiPoll(window, record);
    }

    pub fn zuiWaker(self: *TitleBarHost) zui.Waker {
        return self.base.zuiWaker();
    }

    pub fn zuiWait(self: *TitleBarHost, next: zui.NextFrame) void {
        self.base.zuiWait(next);
    }

    pub fn zuiSurface(self: *TitleBarHost, window: zui.WindowId) zui.Surface {
        return self.base.zuiSurface(window);
    }

    pub fn zuiApply(self: *TitleBarHost, window: zui.WindowId, requests: zui.HostRequests) void {
        self.base.zuiApply(window, requests);
    }

    pub fn zuiChromeRegions(self: *TitleBarHost, _: zui.WindowId, regions: []const zui.ChromeRegion) void {
        self.lists_received += 1;
        self.last_count = @min(regions.len, self.last_kinds.len);
        for (regions[0..self.last_count], self.last_kinds[0..self.last_count]) |region, *kind| kind.* = region.kind;
        self.thread_received_on = std.Thread.getCurrentId();
    }
};

fn TitleBarApp(comptime Host_: type, comptime chrome_regions: bool) type {
    return struct {
        const Self = @This();
        pub const Host = Host_;
        pub const Renderer = TestRenderer(true);
        pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 16 }, .features = .{ .chrome_regions = chrome_regions } }));
        const frame_count = 3;

        pub fn init(_: *Self, start: zui_app.Start(Self)) !void {
            const host_closing = if (Host == TitleBarHost) &start.host.base else start.host;
            host_closing.closes_after_polls = frame_count;
        }

        pub fn zuiDeclare(_: *Self, ui: *Ui) void {
            ui.open(.{ .id = .of("title bar"), .chrome = .title_bar, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(32) } } });
            ui.box(.{ .id = save, .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(24) } } });
            ui.box(.{ .id = .of("close"), .interactive = true, .chrome = .close_button, .layout = .{ .sizing = .{ .width = .fixed(46), .height = .fixed(32) } } });
            ui.close();
        }
    };
}

test "a custom title bar opens the window with it, and the host is handed each frame's chrome on the UI thread" {
    const App = TitleBarApp(TitleBarHost, true);
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .title_bar = .custom, .notify = Notices.record });
    try testing.expectEqual(zui.TitleBar.custom, session.host.base.window.title_bar);
    try testing.expect(session.report.capabilities.custom_title_bar);
    try testing.expectEqual(@as(u32, App.frame_count), try runToClose(&session));
    session.stop();

    try testing.expectEqual(@as(u32, App.frame_count), session.host.lists_received);
    try testing.expectEqualSlices(zui.ChromeKind, &.{ .title_bar, .client, .close_button }, session.host.last_kinds[0..session.host.last_count]);
    try testing.expectEqual(std.Thread.getCurrentId(), session.host.thread_received_on.?);
}

test "without chrome regions a custom title bar does not start, and a native one hands the host nothing" {
    var refused: zui_app.Session(TitleBarApp(TitleBarHost, false)) = undefined;
    try testing.expectError(error.CustomTitleBarWithoutChromeRegions, refused.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .title_bar = .custom, .notify = Notices.record }));

    const App = TitleBarApp(TitleBarHost, false);
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(zui.TitleBar.native, session.host.base.window.title_bar);
    _ = try runToClose(&session);
    try testing.expectEqual(@as(u32, 0), session.host.lists_received);
}

const LastReply = struct {
    reply: ?zui.ServiceReply(16) = null,

    pub fn publish(self: *LastReply, reply: zui.ServiceReply(16)) zui.Wake {
        self.reply = reply;
        return .needed;
    }
};

test "ServicesOf guards each service the host has, and reaches it" {
    const Services = zui_app.ServicesOf(TestHost);
    try testing.expect(Services.has_clipboard and !Services.has_notifications and !Services.has_file_dialogs);
    try testing.expect(!Services.has_open_url and !Services.has_menus and !Services.has_menu_bar and !Services.has_file_watch);

    var host: TestHost = undefined;
    try host.init(testing.io, .{});
    try Services.clipboard.write(&host, "copied");
    var last: LastReply = .{};
    const paste: zui.ServiceRequest = .of("paste");
    try Services.clipboard.read(&host, paste, .of(&last));
    try testing.expectEqual(paste, last.reply.?.request);
    try testing.expectEqualStrings("copied", last.reply.?.text());
    if (Services.has_notifications) try Services.notifications.show(&host, paste, .{ .title = "never compiled" }, .of(&last));
}

/// Offscreen windows, each with its own script of events, one list per
/// turn, on a clock that advances a frame per wait. Each window's surface
/// is 100 times one more than its id wide, so a renderer can tell them
/// apart.
const WindowsHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .many };
    const capacity = 16;

    const Window = struct {
        open: bool = false,
        /// The user closes the window at this turn.
        closes_at_turn: u32 = std.math.maxInt(u32),
        script: []const []const zui.Event = &.{},
        applied: zui.HostRequests = .{},
    };

    windows: [capacity]Window = @splat(.{}),
    /// How many windows the host holds at once.
    holds: u32 = 4,
    next_id: u32 = 1,
    turn: u32 = 0,
    waits: [16]zui.NextFrame = undefined,
    closed: [16]zui.WindowId = undefined,
    closed_count: usize = 0,
    deinitialized: bool = false,

    pub fn init(self: *WindowsHost, _: std.Io, _: zui.WindowOptions) !void {
        self.* = .{};
        self.windows[0] = .{ .open = true };
    }

    pub fn deinit(self: *WindowsHost) void {
        self.deinitialized = true;
    }

    pub fn zuiOpenWindow(self: *WindowsHost, _: zui.WindowOptions) zui.OpenWindowError!zui.WindowId {
        var open_count: u32 = 0;
        for (self.windows) |window| open_count += @intFromBool(window.open);
        if (open_count == self.holds or self.next_id == capacity) return error.TooManyWindows;
        const id = self.next_id;
        self.next_id += 1;
        self.windows[id] = .{ .open = true };
        return @enumFromInt(id);
    }

    pub fn zuiCloseWindow(self: *WindowsHost, window: zui.WindowId) void {
        self.windows[@intFromEnum(window)].open = false;
        self.closed[self.closed_count] = window;
        self.closed_count += 1;
    }

    pub fn zuiPoll(self: *WindowsHost, id: zui.WindowId, record: *zui.RecordBuilder) bool {
        const window = &self.windows[@intFromEnum(id)];
        if (!window.open or self.turn >= window.closes_at_turn) return false;
        record.begin(.{ .now = self.now(), .viewport = .{ 400, 300 }, .scale = 1 });
        if (self.turn < window.script.len) for (window.script[self.turn]) |event| record.append(event);
        return true;
    }

    pub fn zuiWaker(self: *WindowsHost) zui.Waker {
        return .{ .context = self, .wakeFn = ignoreWake };
    }

    pub fn zuiWait(self: *WindowsHost, next: zui.NextFrame) void {
        if (self.turn < self.waits.len) self.waits[self.turn] = next;
        self.turn += 1;
    }

    pub fn zuiSurface(_: *WindowsHost, id: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 100 * (@intFromEnum(id) + 1), 100 } } };
    }

    pub fn zuiApply(self: *WindowsHost, id: zui.WindowId, requests: zui.HostRequests) void {
        self.windows[@intFromEnum(id)].applied = requests;
    }

    fn now(self: *const WindowsHost) zui.Instant {
        return .fromNanoseconds(@as(u64, self.turn + 1) * frame_interval_ns);
    }

    fn ignoreWake(_: *anyopaque) void {}

    fn waitsSoFar(self: *const WindowsHost) []const zui.NextFrame {
        return self.waits[0..@min(self.turn, self.waits.len)];
    }
};

/// Records which window each frame was drawn for, by its surface's width,
/// and the thread of every call.
fn WindowsRenderer(comptime submits_on_any_thread: bool) type {
    return struct {
        const Self = @This();
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const zui_render_thread = submits_on_any_thread;

        drawn_for: [32]u32 = undefined,
        submitted: usize = 0,
        attached: [8]u32 = undefined,
        attached_count: usize = 0,
        detached: [8]u32 = undefined,
        detached_count: usize = 0,
        threads: [48]std.Thread.Id = undefined,
        thread_count: usize = 0,

        pub fn zuiSubmit(self: *Self, surface: zui.Surface, _: anytype) !void {
            self.drawn_for[self.submitted] = windowOf(surface);
            self.submitted += 1;
            self.recordThread();
        }

        pub fn zuiAttachSurface(self: *Self, surface: zui.Surface) error{UnsupportedSurface}!void {
            self.attached[self.attached_count] = windowOf(surface);
            self.attached_count += 1;
            self.recordThread();
        }

        pub fn zuiDetachSurface(self: *Self, surface: zui.Surface) void {
            self.detached[self.detached_count] = windowOf(surface);
            self.detached_count += 1;
            self.recordThread();
        }

        fn windowOf(surface: zui.Surface) u32 {
            return surface.offscreen.size[0] / 100 - 1;
        }

        fn recordThread(self: *Self) void {
            self.threads[self.thread_count] = std.Thread.getCurrentId();
            self.thread_count += 1;
        }

        fn drawnFor(self: *const Self, window: u32) usize {
            return std.mem.count(u32, self.drawn_for[0..self.submitted], &.{window});
        }
    };
}

const click_at_save = [_]zui.Event{
    .{ .pointer_move = .{ .pointer = pointer_at_save } },
    .{ .pointer_down = .{ .pointer = pointer_at_save } },
    .{ .pointer_up = .{ .pointer = pointer_at_save } },
};

fn TwoWindowsApp(comptime Renderer_: type) type {
    return struct {
        const Self = @This();
        pub const Host = WindowsHost;
        pub const Renderer = Renderer_;
        pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 16 }, .frames_in_flight = 2 }));

        windows: zui_app.Windows(Self) = undefined,
        second: zui.WindowId = .main,
        clicks: [2]u32 = .{ 0, 0 },
        declarations: [2]u32 = .{ 0, 0 },
        loads: [2]u32 = .{ 0, 0 },
        closed: [2]zui.WindowId = undefined,
        closed_count: usize = 0,

        pub fn init(app: *Self, start: zui_app.Start(Self)) !void {
            app.* = .{ .windows = start.windows };
            app.second = try app.windows.open(.{ .title = "second", .visible = false });
            start.host.windows[0].closes_at_turn = 4;
            start.host.windows[1].closes_at_turn = 3;
            start.host.windows[1].script = &.{ &.{}, &click_at_save };
        }

        pub fn zuiDeclare(app: *Self, ui: *Ui, window: zui.WindowId) void {
            const index = @intFromEnum(window);
            app.declarations[index] += 1;
            if (ui.clicked(save)) app.clicks[index] += 1;
            ui.box(.{ .id = save, .interactive = true, .cursor = if (window == .main) .default else .pointer, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
        }

        pub fn zuiLoader(app: *Self, _: *const Ui, window: zui.WindowId, _: std.Io) void {
            app.loads[@intFromEnum(window)] += 1;
        }

        pub fn zuiWindowClosed(app: *Self, window: zui.WindowId) void {
            app.closed[app.closed_count] = window;
            app.closed_count += 1;
        }
    };
}

fn expectTwoWindowsRan(session: anytype) !void {
    const second: zui.WindowId = @enumFromInt(1);
    try testing.expectEqual(second, session.app.second);
    try testing.expectEqual([2]u32{ 0, 1 }, session.app.clicks);
    // Each window draws its first frame, and then only when it has input.
    try testing.expectEqual([2]u32{ 1, 2 }, session.app.declarations);
    try testing.expectEqual(session.app.declarations, session.app.loads);
    try testing.expectEqual(zui.Cursor.pointer, session.host.windows[1].applied.cursor);
    try testing.expectEqual(zui.Cursor.default, session.host.windows[0].applied.cursor);
    try testing.expectEqualSlices(zui.WindowId, &.{ second, .main }, session.app.closed[0..session.app.closed_count]);
    try testing.expectEqualSlices(zui.WindowId, &.{ second, .main }, session.host.closed[0..session.host.closed_count]);
    try testing.expectEqual(@as(usize, 1), session.renderer.drawnFor(0));
    try testing.expectEqual(@as(usize, 2), session.renderer.drawnFor(1));
    try testing.expectEqualSlices(u32, &.{1}, session.renderer.attached[0..session.renderer.attached_count]);
    try testing.expectEqualSlices(u32, &.{ 1, 0 }, session.renderer.detached[0..session.renderer.detached_count]);
}

test "an application with many windows declares each in a context of its own, and input reaches only its window" {
    const App = TwoWindowsApp(WindowsRenderer(false));
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    try testing.expectEqual(@as(u32, 4), try runToClose(&session));
    session.stop();
    try expectTwoWindowsRan(&session);
    try testing.expect(session.host.deinitialized);
    for (session.renderer.threads[0..session.renderer.thread_count]) |thread| try testing.expectEqual(std.Thread.getCurrentId(), thread);
}

test "with a render thread, every window's frames and surfaces go through it, and a window closes after its frames" {
    const App = TwoWindowsApp(WindowsRenderer(true));
    var session: zui_app.Session(App) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    try testing.expectEqual(zui_app.Submission.render_thread, session.report.submission);
    try testing.expectEqual(@as(u32, 4), try runToClose(&session));
    session.stop();
    try expectTwoWindowsRan(&session);
    // The second window was attached in `init`, before the render thread started.
    try testing.expectEqual(std.Thread.getCurrentId(), session.renderer.threads[0]);
    for (session.renderer.threads[1..session.renderer.thread_count]) |thread| try testing.expect(thread != std.Thread.getCurrentId());
}

const PacedWindowsApp = struct {
    pub const Host = WindowsHost;
    pub const Renderer = WindowsRenderer(false);
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8 }, .Sources = Sources }));
    const Sources = struct { counter: Counter = .{} };
    const main_deadline: zui.Instant = .fromNanoseconds(1_000 * frame_interval_ns);

    sources: [2]Sources = .{ .{}, .{} },
    declarations: [2]u32 = .{ 0, 0 },
    seen: [2]?u32 = .{ null, null },

    pub fn init(app: *PacedWindowsApp, start: zui_app.Start(PacedWindowsApp)) !void {
        app.* = .{};
        _ = try start.windows.open(.{ .title = "second" });
        start.host.windows[0].closes_at_turn = 4;
        start.host.windows[1].closes_at_turn = 4;
    }

    pub fn zuiSources(app: *PacedWindowsApp, window: zui.WindowId) *Sources {
        return &app.sources[@intFromEnum(window)];
    }

    pub fn zuiDeclare(app: *PacedWindowsApp, ui: *Ui, window: zui.WindowId) void {
        const index = @intFromEnum(window);
        app.declarations[index] += 1;
        if (ui.source(.counter)) |value| app.seen[index] = value;
        if (window == .main) ui.requestFrameAt(main_deadline);
        if (window != .main and app.declarations[index] == 1) ui.requestFrame();
        ui.box(.{});
    }

    pub fn zuiLoader(app: *PacedWindowsApp, _: *const Ui, window: zui.WindowId, _: std.Io) void {
        if (window != .main and app.declarations[1] == 2) app.sources[1].counter.published = 7;
    }
};

test "the host waits for the earliest nextFrame of every window, and a publish makes only its own window due" {
    var session: zui_app.Session(PacedWindowsApp) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(@as(u32, 4), try runToClose(&session));

    const at_main_deadline: zui.NextFrame = .{ .at = PacedWindowsApp.main_deadline };
    try testing.expectEqualSlices(zui.NextFrame, &.{ .immediately, .immediately, at_main_deadline, at_main_deadline }, session.host.waitsSoFar());
    try testing.expectEqual([2]u32{ 1, 3 }, session.app.declarations);
    try testing.expectEqual([2]?u32{ null, 7 }, session.app.seen);
}

fn ManyWindowsApp(comptime host_holds: u32) type {
    return struct {
        const Self = @This();
        pub const Host = WindowsHost;
        pub const Renderer = WindowsRenderer(false);
        pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8 } }));

        opened: u32 = 0,
        refused: ?anyerror = null,

        pub fn init(app: *Self, start: zui_app.Start(Self)) !void {
            app.* = .{};
            start.host.holds = host_holds;
            while (start.windows.open(.{})) |_| app.opened += 1 else |err| app.refused = err;
        }

        pub fn zuiDeclare(_: *Self, ui: *Ui, _: zui.WindowId) void {
            ui.box(.{});
        }
    };
}

test "past the windows the host or zui_app holds, opening one more is refused" {
    inline for (.{ .{ 4, 3 }, .{ WindowsHost.capacity, zui_app.max_windows - 1 } }) |case| {
        var session: zui_app.Session(ManyWindowsApp(case[0])) = undefined;
        try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
        defer session.stop();
        try testing.expectEqual(@as(u32, case[1]), session.app.opened);
        try testing.expectEqual(@as(?anyerror, error.TooManyWindows), session.app.refused);
    }
}

const ClosingWindowApp = struct {
    pub const Host = WindowsHost;
    pub const Renderer = WindowsRenderer(false);
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8 } }));

    windows: zui_app.Windows(ClosingWindowApp) = undefined,
    declarations: u32 = 0,

    pub fn init(app: *ClosingWindowApp, start: zui_app.Start(ClosingWindowApp)) !void {
        app.* = .{ .windows = start.windows };
        _ = try app.windows.open(.{});
    }

    pub fn zuiDeclare(app: *ClosingWindowApp, ui: *Ui, _: zui.WindowId) void {
        app.declarations += 1;
        ui.requestFrame();
        ui.box(.{});
    }

    pub fn zuiLoader(app: *ClosingWindowApp, _: *const Ui, window: zui.WindowId, _: std.Io) void {
        app.windows.close(window);
    }
};

test "a window the application closes runs no frame after that turn, and the run ends with the last" {
    var session: zui_app.Session(ClosingWindowApp) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(@as(u32, 0), try runToClose(&session));
    try testing.expectEqual(@as(u32, 2), session.app.declarations);
    try testing.expectEqual(@as(usize, 2), session.host.closed_count);
}

const OneWindowOnManyApp = struct {
    pub const Host = WindowsHost;
    pub const Renderer = WindowsRenderer(false);
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8 } }));

    declarations: u32 = 0,

    pub fn init(app: *OneWindowOnManyApp, start: zui_app.Start(OneWindowOnManyApp)) !void {
        app.* = .{};
        start.host.windows[0].closes_at_turn = 3;
    }

    pub fn zuiDeclare(app: *OneWindowOnManyApp, ui: *Ui) void {
        app.declarations += 1;
        ui.box(.{});
    }
};

test "an application with one window runs a frame every turn on a host with many, and ends when it closes" {
    var session: zui_app.Session(OneWindowOnManyApp) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(@as(u32, 3), try runToClose(&session));
    try testing.expectEqual(@as(u32, 3), session.app.declarations);
    try testing.expectEqual(@as(usize, 0), session.host.closed_count);
}

const WindowedAppOnOneWindow = struct {
    pub const Host = TestHost;
    pub const Renderer = TestRenderer(false);
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 8 } }));

    declared_in: ?zui.WindowId = null,
    closed: ?zui.WindowId = null,

    pub fn init(app: *WindowedAppOnOneWindow, start: zui_app.Start(WindowedAppOnOneWindow)) !void {
        app.* = .{};
        start.host.closes_after_polls = 2;
        if (zui_app.Windows(WindowedAppOnOneWindow).has_many_windows) _ = try start.windows.open(.{});
    }

    pub fn zuiDeclare(app: *WindowedAppOnOneWindow, ui: *Ui, window: zui.WindowId) void {
        app.declared_in = window;
        ui.box(.{});
    }

    pub fn zuiWindowClosed(app: *WindowedAppOnOneWindow, window: zui.WindowId) void {
        app.closed = window;
    }
};

test "an application that declares windows runs on a host with one, in its main window" {
    var session: zui_app.Session(WindowedAppOnOneWindow) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expectEqual(@as(u32, 2), try runToClose(&session));
    try testing.expectEqual(@as(?zui.WindowId, .main), session.app.declared_in);
    try testing.expectEqual(@as(?zui.WindowId, .main), session.app.closed);
    try testing.expectEqual(@as(usize, 1), session.renderer.submitted);
}

/// What the platform calls a host that runs its own loop with, as a page's
/// `requestAnimationFrame` or Android's window commands do.
const Callback = enum { window_opened, display_frame, clicked, surface_lost, surface_regained, close_requested };

/// What a run on `PushHost` left behind, since the host, the renderer and
/// the application are freed before `run` returns.
const PushRun = struct {
    var nexts: [16]zui.NextFrame = undefined;
    var next_count: usize = 0;
    var ended_by_step: bool = false;
    var declarations: u32 = 0;
    var clicks: u32 = 0;
    var drawn_for: [8]u32 = undefined;
    var submitted: usize = 0;
    var attached: [4]u32 = undefined;
    var attached_count: usize = 0;
    var detached: [4]u32 = undefined;
    var detached_count: usize = 0;
    var deinitializations: u32 = 0;

    fn clear() void {
        next_count = 0;
        ended_by_step = false;
        declarations = 0;
        clicks = 0;
        submitted = 0;
        attached_count = 0;
        detached_count = 0;
        deinitializations = 0;
    }

    fn nextsSoFar() []const zui.NextFrame {
        return nexts[0..next_count];
    }
};

/// A host that runs its own loop through `zuiRun`, calling the driver from
/// a scripted list of the platform's callbacks. Each display frame moves
/// its clock on a frame. Its surface is 100 units wide for each time it
/// has been given, so a renderer can tell a regained surface from the
/// lost one. With `owns_io`, the application's tasks run on an `Io` of
/// the host's own.
fn PushHost(comptime callbacks: []const Callback, comptime owns_io: bool) type {
    return struct {
        const Self = @This();
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

        window: zui.WindowOptions = .{},
        surfaces_given: u32 = 1,
        display_frames: u32 = 0,
        closing: bool = false,
        pending_events: []const zui.Event = &.{},

        pub fn zuiRun(self: *Self, io: std.Io, window: zui.WindowOptions, driver: zui.Driver) !void {
            self.window = window;
            defer driver.stop();
            for (callbacks) |callback| switch (callback) {
                .window_opened => try driver.start(if (owns_io) singleThreadedIo() else io),
                .surface_lost => driver.suspendSurfaces(),
                .surface_regained => {
                    self.surfaces_given += 1;
                    try driver.resumeSurfaces();
                },
                .display_frame, .clicked, .close_requested => {
                    if (callback == .clicked) self.pending_events = &click_at_save;
                    if (callback == .close_requested) self.closing = true;
                    self.display_frames += 1;
                    const next = try driver.step() orelse {
                        PushRun.ended_by_step = true;
                        return;
                    };
                    PushRun.nexts[PushRun.next_count] = next;
                    PushRun.next_count += 1;
                },
            };
        }

        pub fn zuiPoll(self: *Self, _: zui.WindowId, record: *zui.RecordBuilder) bool {
            if (self.closing) return false;
            record.begin(.{ .now = .fromNanoseconds(@as(u64, self.display_frames) * frame_interval_ns), .viewport = .{ 400, 300 }, .scale = 1 });
            for (self.pending_events) |event| record.append(event);
            self.pending_events = &.{};
            return true;
        }

        pub fn zuiWaker(self: *Self) zui.Waker {
            return .{ .context = self, .wakeFn = ignoreWake };
        }

        pub fn zuiSurface(self: *Self, _: zui.WindowId) zui.Surface {
            return .{ .offscreen = .{ .size = .{ 100 * self.surfaces_given, 100 } } };
        }

        pub fn zuiApply(_: *Self, _: zui.WindowId, _: zui.HostRequests) void {}

        fn ignoreWake(_: *anyopaque) void {}
    };
}

fn PushedApp(comptime Host_: type, comptime Renderer_: type) type {
    return struct {
        const Self = @This();
        pub const Host = Host_;
        pub const Renderer = Renderer_;
        pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 16 }, .frames_in_flight = 2 }));

        renderer: *Renderer = undefined,
        declarations: u32 = 0,
        clicks: u32 = 0,

        pub fn init(app: *Self, start: zui_app.Start(Self)) !void {
            app.* = .{ .renderer = start.renderer };
        }

        pub fn zuiDeclare(app: *Self, ui: *Ui) void {
            app.declarations += 1;
            if (ui.clicked(save)) app.clicks += 1;
            ui.box(.{ .id = save, .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
        }

        /// After the render thread has submitted its last frame, and before
        /// the renderer is freed.
        pub fn deinit(app: *Self) void {
            const renderer = app.renderer;
            PushRun.deinitializations += 1;
            PushRun.declarations = app.declarations;
            PushRun.clicks = app.clicks;
            PushRun.submitted = renderer.submitted;
            @memcpy(PushRun.drawn_for[0..renderer.submitted], renderer.drawn_for[0..renderer.submitted]);
            PushRun.attached_count = renderer.attached_count;
            @memcpy(PushRun.attached[0..renderer.attached_count], renderer.attached[0..renderer.attached_count]);
            PushRun.detached_count = renderer.detached_count;
            @memcpy(PushRun.detached[0..renderer.detached_count], renderer.detached[0..renderer.detached_count]);
        }
    };
}

const lose_and_regain_the_surface = [_]Callback{ .window_opened, .display_frame, .display_frame, .clicked, .surface_lost, .display_frame, .surface_regained, .display_frame, .close_requested };

test "a host that runs its own loop drives the application through its driver, and a lost surface is let go and given back" {
    inline for (.{ WindowsRenderer(false), WindowsRenderer(true) }) |Renderer| {
        PushRun.clear();
        Notices.clear();
        const App = PushedApp(PushHost(&lose_and_regain_the_surface, false), Renderer);
        try testing.expect(zui_app.Session(App).loop == .pushed);
        try zui_app.runWith(App, .{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });

        const expected_submission: zui_app.Submission = if (Renderer.zui_render_thread) .render_thread else .{ .ui_thread = .renderer_needs_its_thread };
        try testing.expectEqual(expected_submission, Notices.first(.started).started.submission);
        try testing.expect(PushRun.ended_by_step);
        try testing.expectEqual(@as(u32, 1), PushRun.deinitializations);
        // The first frame, the click, and the first frame on the regained
        // surface; a display frame with nothing new declares nothing.
        try testing.expectEqual(@as(u32, 3), PushRun.declarations);
        try testing.expectEqual(@as(u32, 1), PushRun.clicks);
        try testing.expectEqualSlices(u32, &.{ 0, 0, 1 }, PushRun.drawn_for[0..PushRun.submitted]);
        try testing.expectEqualSlices(u32, &.{0}, PushRun.detached[0..PushRun.detached_count]);
        try testing.expectEqualSlices(u32, &.{1}, PushRun.attached[0..PushRun.attached_count]);
        try testing.expectEqualSlices(zui.NextFrame, &.{ .on_event, .on_event, .on_event, .on_event, .on_event }, PushRun.nextsSoFar());
    }
}

test "a host that runs its own loop may run the application's tasks on an Io of its own" {
    Notices.clear();
    PushRun.clear();
    const App = PushedApp(PushHost(&.{ .window_opened, .display_frame, .close_requested }, true), WindowsRenderer(true));
    try zui_app.runWith(App, .{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    try testing.expectEqual(zui_app.Submission{ .ui_thread = .io_cannot_run_concurrently }, Notices.first(.started).started.submission);
    try testing.expectEqual(@as(u32, 1), PushRun.declarations);
}

test "a driver stopped by the host is not stopped again, and one never started frees nothing" {
    PushRun.clear();
    const NeverOpened = PushedApp(PushHost(&.{}, false), WindowsRenderer(false));
    try zui_app.runWith(NeverOpened, .{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    try testing.expectEqual(@as(u32, 0), PushRun.deinitializations);

    const OpenedAndLeft = PushedApp(PushHost(&.{ .window_opened, .display_frame }, false), WindowsRenderer(false));
    try zui_app.runWith(OpenedAndLeft, .{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    try testing.expectEqual(@as(u32, 1), PushRun.deinitializations);
    try testing.expect(!PushRun.ended_by_step);
}

/// A host that runs a loop that never returns, as `[NSApp run]` does.
const NeverReturningHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiRun(_: *NeverReturningHost, _: std.Io, _: zui.WindowOptions, _: zui.Driver) noreturn {
        std.process.exit(0);
    }

    pub fn zuiPoll(_: *NeverReturningHost, _: zui.WindowId, _: *zui.RecordBuilder) bool {
        return false;
    }

    pub fn zuiWaker(self: *NeverReturningHost) zui.Waker {
        return .{ .context = self, .wakeFn = ignoreWake };
    }

    pub fn zuiSurface(_: *NeverReturningHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 1, 1 } } };
    }

    pub fn zuiApply(_: *NeverReturningHost, _: zui.WindowId, _: zui.HostRequests) void {}

    fn ignoreWake(_: *anyopaque) void {}
};

test "run returns as the host's zuiRun does, and never when it never returns" {
    const App = PushedApp(NeverReturningHost, WindowsRenderer(false));
    try testing.expect(@TypeOf(zui_app.runWith(App, undefined, .{})) == zui_app.PushedStartError!noreturn);
    try testing.expect(@TypeOf(zui_app.runWith(PushedApp(PushHost(&.{}, false), WindowsRenderer(false)), undefined, .{})) == anyerror!void);
    try testing.expect(@TypeOf(zui_app.runWith(ClickApp, undefined, .{})) == anyerror!void);
}

/// `TestHost` without `zuiWait`: a window the application's own loop owns
/// and waits for, as an editor's panel or a game's overlay is.
const SteppedHost = struct {
    pub const zui_surfaces = TestHost.zui_surfaces;

    base: TestHost = .{ .window = undefined },

    pub fn init(self: *SteppedHost, io: std.Io, window: zui.WindowOptions) !void {
        self.* = .{};
        try self.base.init(io, window);
    }

    pub fn deinit(self: *SteppedHost) void {
        self.base.deinit();
    }

    pub fn zuiPoll(self: *SteppedHost, window: zui.WindowId, record: *zui.RecordBuilder) bool {
        return self.base.zuiPoll(window, record);
    }

    pub fn zuiWaker(self: *SteppedHost) zui.Waker {
        return self.base.zuiWaker();
    }

    pub fn zuiSurface(self: *SteppedHost, window: zui.WindowId) zui.Surface {
        return self.base.zuiSurface(window);
    }

    pub fn zuiApply(self: *SteppedHost, window: zui.WindowId, requests: zui.HostRequests) void {
        self.base.zuiApply(window, requests);
    }
};

const SteppedApp = struct {
    pub const Host = SteppedHost;
    pub const Renderer = TestRenderer(false);
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .limits = .{ .max_elements = 16 } }));

    declarations: u32 = 0,
    clicks: u32 = 0,

    pub fn init(app: *SteppedApp, start: zui_app.Start(SteppedApp)) !void {
        app.* = .{};
        start.host.base.closes_after_polls = 4;
        start.host.base.script = &.{ &.{}, &.{}, &click_at_save, &.{} };
    }

    pub fn zuiDeclare(app: *SteppedApp, ui: *Ui) void {
        app.declarations += 1;
        if (ui.clicked(save)) app.clicks += 1;
        ui.box(.{ .id = save, .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
    }
};

test "an application's own loop steps a Session on a host without a loop, which declares only the frames that are due" {
    var session: zui_app.Session(SteppedApp) = undefined;
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = Notices.record });
    defer session.stop();
    try testing.expect(zui_app.Session(SteppedApp).loop == .stepped);

    var nexts: [8]zui.NextFrame = undefined;
    var turns: usize = 0;
    while (try session.step()) |next| : (turns += 1) nexts[turns] = next;

    try testing.expectEqual(@as(usize, 4), turns);
    try testing.expectEqual(@as(u32, 2), session.app.declarations);
    try testing.expectEqual(@as(u32, 1), session.app.clicks);
    try testing.expectEqual(@as(usize, 2), session.renderer.submitted);
    try testing.expectEqual(@as(usize, 0), session.host.base.wait_count);
    try testing.expectEqualSlices(zui.NextFrame, &.{ .on_event, .on_event, .on_event, .on_event }, nexts[0..turns]);
}

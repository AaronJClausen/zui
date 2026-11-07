const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_testing = @import("zui_testing");
const zui_wire = @import("zui_wire.zig");

const testing = std.testing;
const Io = std.Io;
const Stream = Io.net.Stream;

const Text = zui_testing.FixedMetricsText(u16);
const Ui = zui.Context(.{
    .limits = .{ .max_elements = 64, .max_text_bytes = 1024, .max_render_commands = 64, .measure_cache_entries = 64, .string_cache_entries = 64, .max_events_per_frame = 32 },
    .Text = Text,
});

/// The longest any test here waits for the other end of a connection.
const patience_ns = 5 * std.time.ns_per_s;

const Pair = struct { application: Stream, client: Stream };

/// Both ends of a connection over the loopback interface.
fn connect(io: Io) !Pair {
    var address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const client = try server.socket.address.connect(io, .{ .mode = .stream });
    errdefer client.close(io);
    return .{ .application = try server.accept(io), .client = client };
}

fn awakeNow(io: Io) zui.Instant {
    return .fromTimestamp(Io.Timestamp.now(io, .awake));
}

/// The client's end, written by hand: a record per posted event.
const HostHarness = struct {
    io: Io,
    wire_host: zui_wire.Host(Ui) = .{},
    client: Stream,
    client_writer: Stream.Writer = undefined,
    write_buffer: [4096]u8 = undefined,
    encoder: zui_wire.Encoder(Ui),
    open: bool = true,

    fn init(self: *HostHarness) !void {
        self.client_writer = self.client.writer(self.io, &self.write_buffer);
        try zui_wire.writeHeader(&self.client_writer.interface, null);
        try self.send(&.{});
    }

    fn deinit(self: *HostHarness) void {
        self.wire_host.deinit();
        self.encoder.deinit(testing.allocator);
        if (self.open) self.client.close(self.io);
    }

    fn send(self: *HostHarness, events: []const zui.Event) !void {
        const record: Ui.FrameRecord = .{ .params = .{ .now = awakeNow(self.io), .viewport = .{ 800, 600 }, .scale = 2 }, .events = events };
        try self.encoder.writeRecord(&self.client_writer.interface, &record);
        try self.client_writer.interface.flush();
    }

    pub fn host(self: *HostHarness) *zui_wire.Host(Ui) {
        return &self.wire_host;
    }

    pub fn post(self: *HostHarness, event: zui.Event) bool {
        self.send(&.{event}) catch return false;
        return true;
    }

    /// Returns once the host has seen the connection end, as a host sees
    /// its window close before its next poll.
    pub fn close(self: *HostHarness) void {
        self.client.close(self.io);
        self.open = false;
        const started = awakeNow(self.io);
        while (self.wire_host.connected() and awakeNow(self.io).nanoseconds -| started.nanoseconds < patience_ns) {
            self.io.sleep(.fromMilliseconds(1), .awake) catch return;
        }
    }
};

test "the wire host passes zui's host suite" {
    const io = testing.io;
    const pair = try connect(io);
    var harness: HostHarness = .{ .io = io, .client = pair.client, .encoder = try .init(testing.allocator) };
    defer harness.deinit();
    try harness.wire_host.init(io, .{});
    try harness.init();
    try harness.wire_host.attach(testing.allocator, pair.application);
    try zui_testing.expectHostConforms(zui_wire.Host(Ui), &harness, .{ .io = io });
    try testing.expectEqual(null, harness.wire_host.failure());
}

test "the wire host closes on bytes that are not a record, and says why" {
    const io = testing.io;
    const pair = try connect(io);
    var harness: HostHarness = .{ .io = io, .client = pair.client, .encoder = try .init(testing.allocator) };
    defer harness.deinit();
    try harness.wire_host.init(io, .{});
    try harness.init();
    try harness.wire_host.attach(testing.allocator, pair.application);
    try harness.client_writer.interface.writeByte(0xff);
    try harness.client_writer.interface.flush();
    var events: [4]zui.Event = undefined;
    var text: [4]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text);
    const started = awakeNow(io);
    while (harness.wire_host.zuiPoll(.main, &builder)) {
        if (awakeNow(io).nanoseconds -| started.nanoseconds > patience_ns) return error.ConnectionNeverClosed;
        harness.wire_host.zuiWait(.{ .at = builder.params.now.addNanoseconds(10 * std.time.ns_per_ms) });
    }
    try testing.expectEqual(error.Malformed, harness.wire_host.failure().?);
}

const more: zui.Id = .of("more");

/// Counts clicks on a button and shows the count.
const CounterApp = struct {
    pub const Host = zui_wire.Host(Ui);
    pub const Renderer = zui_wire.Renderer(Ui);
    pub const Text = Ui.Text;

    clicks: u32 = 0,
    label: [32]u8 = undefined,

    pub fn zuiDeclare(app: *CounterApp, ui: *Ui) void {
        if (ui.clicked(more)) app.clicks += 1;
        ui.open(.{ .id = more, .interactive = true, .cursor = .pointer, .decoration = .{ .background = .black }, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
        ui.text(std.fmt.bufPrint(&app.label, "clicks: {d}", .{app.clicks}) catch unreachable, .{});
        ui.close();
    }
};

/// The client's own host: it reports what a test posts, and waits at most
/// a few milliseconds, so a test's loop never blocks on it.
const ViewerHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    io: Io,
    woken: Io.Event = .unset,
    posted: [8]zui.Event = undefined,
    posted_count: usize = 0,
    applied: zui.HostRequests = .{},

    const longest_wait_ns = 20 * std.time.ns_per_ms;

    fn post(self: *ViewerHost, events: []const zui.Event) void {
        @memcpy(self.posted[self.posted_count..][0..events.len], events);
        self.posted_count += events.len;
    }

    pub fn zuiPoll(self: *ViewerHost, _: zui.WindowId, record: *zui.RecordBuilder) bool {
        record.begin(.{ .now = awakeNow(self.io), .viewport = .{ 400, 300 } });
        for (self.posted[0..self.posted_count]) |event| record.append(event);
        self.posted_count = 0;
        return true;
    }

    pub fn zuiWaker(self: *ViewerHost) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }

    pub fn zuiWait(self: *ViewerHost, _: zui.NextFrame) void {
        const deadline = awakeNow(self.io).addNanoseconds(longest_wait_ns);
        self.woken.waitTimeout(self.io, .{ .deadline = .{ .raw = .{ .nanoseconds = deadline.nanoseconds }, .clock = .awake } }) catch {};
        self.woken.reset();
    }

    pub fn zuiSurface(_: *ViewerHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 400, 300 } } };
    }

    pub fn zuiApply(self: *ViewerHost, _: zui.WindowId, requests: zui.HostRequests) void {
        self.applied = requests;
    }

    fn wake(context: *anyopaque) void {
        const self: *ViewerHost = @ptrCast(@alignCast(context));
        self.woken.set(self.io);
    }
};

/// Keeps the text of the last frame it drew.
const ViewerRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    frames: u32 = 0,
    last_number: u64 = 0,
    label: [32]u8 = undefined,
    label_len: usize = 0,

    pub fn zuiSubmit(self: *ViewerRenderer, _: zui.Surface, frame: anytype) !void {
        self.frames += 1;
        self.last_number = frame.number;
        for (frame.commands()) |command| switch (command.payload) {
            .text => |text| {
                @memcpy(self.label[0..text.content.len], text.content);
                self.label_len = text.content.len;
            },
            else => {},
        };
    }

    fn shows(self: *const ViewerRenderer, label: []const u8) bool {
        return std.mem.eql(u8, self.label[0..self.label_len], label);
    }
};

fn runUntilClosed(runner: *zui_app.Runner(CounterApp)) void {
    while (runner.frame() catch false) {}
}

/// Runs the client's turns until the renderer shows `label`, failing after
/// `patience_ns`.
fn presentUntil(client: *zui_wire.Client(Ui), host: *ViewerHost, renderer: *ViewerRenderer, label: []const u8) !void {
    const started = awakeNow(host.io);
    while (!renderer.shows(label)) {
        if (awakeNow(host.io).nanoseconds -| started.nanoseconds > patience_ns) return error.FrameNeverArrived;
        if (!try client.frame(host, renderer)) return error.ConnectionClosed;
    }
}

test "an application runs in one place and draws in another, with input going back" {
    const io = testing.io;
    const pair = try connect(io);

    var runner: zui_app.Runner(CounterApp) = undefined;
    try runner.start(.{ .gpa = testing.allocator, .io = io }, .{});
    var app_stopped = false;
    defer if (!app_stopped) runner.stop();

    var viewer_host: ViewerHost = .{ .io = io };
    var viewer_renderer: ViewerRenderer = .{};
    var client: zui_wire.Client(Ui) = undefined;
    try client.init(testing.allocator, io, pair.client, .{ .waker = viewer_host.zuiWaker() });
    var client_open = true;
    defer if (client_open) client.deinit();
    try testing.expect(client.poll(&viewer_host));
    client.send();

    try runner.host.attach(testing.allocator, pair.application);
    var application: Io.Group = .init;
    try application.concurrent(io, runUntilClosed, .{&runner});
    defer application.cancel(io);

    try presentUntil(&client, &viewer_host, &viewer_renderer, "clicks: 0");
    try testing.expectEqual(zui.Cursor.default, viewer_host.applied.cursor);

    const over_button: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 50, 20 }, .at = awakeNow(io) };
    viewer_host.post(&.{.{ .pointer_move = .{ .pointer = over_button } }});
    const hovered_from = awakeNow(io);
    while (viewer_host.applied.cursor != .pointer) {
        if (awakeNow(io).nanoseconds -| hovered_from.nanoseconds > patience_ns) return error.CursorNeverApplied;
        _ = try client.frame(&viewer_host, &viewer_renderer);
    }
    viewer_host.post(&.{ .{ .pointer_down = .{ .pointer = over_button } }, .{ .pointer_up = .{ .pointer = over_button } } });
    try presentUntil(&client, &viewer_host, &viewer_renderer, "clicks: 1");
    viewer_host.post(&.{ .{ .pointer_down = .{ .pointer = over_button } }, .{ .pointer_up = .{ .pointer = over_button } } });
    try presentUntil(&client, &viewer_host, &viewer_renderer, "clicks: 2");

    try testing.expectEqual(client.shownFrame().number, viewer_renderer.last_number);
    try testing.expect(client.framesReceived() >= viewer_renderer.frames);

    client.deinit();
    client_open = false;
    try application.await(io);
    try testing.expectEqual(@as(u32, 2), runner.app.clicks);
    try testing.expect(!runner.host.connected());
    try testing.expectEqual(null, runner.host.failure());
    runner.stop();
    app_stopped = true;
}

test "a client refuses a stream measured with other fonts" {
    const io = testing.io;
    const pair = try connect(io);
    var wire_host: zui_wire.Host(Ui) = .{};
    try wire_host.init(io, .{});
    defer wire_host.deinit();
    wire_host.fingerprint = 1;

    var viewer_host: ViewerHost = .{ .io = io };
    var viewer_renderer: ViewerRenderer = .{};
    var client: zui_wire.Client(Ui) = undefined;
    try client.init(testing.allocator, io, pair.client, .{ .waker = viewer_host.zuiWaker(), .fingerprint = 2 });
    defer client.deinit();
    try testing.expect(client.poll(&viewer_host));
    client.send();
    try wire_host.attach(testing.allocator, pair.application);

    var text: Text = .{};
    var ui: Ui = try .init(testing.allocator, io, &text);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 400, 300 } } });
    const frame = ui.endFrame();
    wire_host.sendFrame(frame);
    ui.release(frame);

    const started = awakeNow(io);
    const refused = while (awakeNow(io).nanoseconds -| started.nanoseconds < patience_ns) {
        _ = client.frame(&viewer_host, &viewer_renderer) catch |err| break err;
    } else return error.StreamNeverRefused;
    try testing.expectEqual(error.FontsDiffer, refused);
    try testing.expectEqual(@as(u32, 0), viewer_renderer.frames);
}

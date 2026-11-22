const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_wire = @import("zui_wire");
const zui_tour = @import("zui_tour");
const zui_truetype = @import("zui_truetype");
const zui_webgl = @import("zui_webgl");

pub const SteppedIo = @import("stepped_io.zig").SteppedIo;
pub const Stopwatch = zui_tour.Stopwatch;

/// The tour as the browser draws it: declared for `zui_webgl.Renderer`, in
/// `zui_truetype`'s layout of the three fonts it adds, which the page hands
/// the client in the same order.
pub const kit = zui_tour.Kit(.{ .Renderer = zui_webgl.Renderer, .FontSystem = zui_truetype.Text, .inspector = false, .renderer_name = "the browser" });
pub const Ui = kit.Ui;
pub const Tour = zui_tour.Tour(kit);

/// The tour's application, stepped by the page: `zui_tour.App` on a host
/// over the records the page sends, drawn by a renderer that writes each
/// frame as wire bytes for the page to draw.
pub const App = zui_tour.App(.{ .Host = PageHost, .Renderer = PageRenderer, .Text = zui_truetype.Text, .inspector = false, .renderer_name = "the browser" });

/// The tour, run by a loop that owns its clock: the page's, in a browser's
/// worker. Each `frame` steps the tour's `Io` to the page's instant, takes
/// the records the page sent since the last, and steps a
/// `zui_app.Session` of the tour, which declares a frame when one is due
/// and writes it as wire bytes, the stream's header before the first. Given
/// the same instants, records and draw times, and a `.steady` stopwatch,
/// it writes the same bytes in a worker as natively. Memory is reserved by
/// `init`.
///
/// ```zig
/// try session.init(gpa, &stepped, .{ .stopwatch = .{ .clock = performanceNow } });
/// @memcpy(try session.roomForRecords(bytes.len), bytes);
/// session.receivedRecords(bytes.len);
/// if (try session.frame(page_milliseconds, last_draw_milliseconds)) |wire_bytes| post(wire_bytes);
/// sleepUntil(session.nextWake());
/// ```
pub const TourSession = struct {
    /// The threads the tour's tasks take turns on, the same wherever it
    /// runs, since how many run at once changes what it draws: a Gallery
    /// tile waits to start loading while sixteen tasks hold a thread.
    pub const thread_count = 16;

    gpa: std.mem.Allocator,
    stepped: *SteppedIo,
    session: *zui_app.Session(App),
    decoder: zui_wire.Decoder(App.Ui),
    encoder: zui_wire.Encoder(App.Ui),
    /// What arrived from the page since the last step, which the host's
    /// poll hands the session.
    received: zui.RecordBuilder,
    pending_records: []u8,
    pending_end: usize = 0,
    read_start: usize = 0,
    records_header_read: bool = false,
    /// The canvas as the newest record measured it; no frame is declared
    /// before the first record.
    measured: ?struct { viewport: [2]f32, scale: f32 } = null,
    frame_bytes: []u8,
    /// What the renderer wrote this step, if it declared a frame.
    written: ?[]const u8 = null,
    fingerprint: ?u64 = null,
    header_written: bool = false,
    /// Set when a frame did not fit `frame_bytes`, so the next is written
    /// whole rather than as changes from one the page never received.
    key_frame_next: bool = false,
    next: zui.NextFrame = .on_event,

    pub const Options = struct {
        /// The most bytes held of records that have not arrived whole.
        max_pending_record_bytes: usize = 256 * 1024,
        /// The most bytes one frame is written in: at least a key frame of
        /// every command.
        max_frame_bytes: usize = 4 << 20,
        stopwatch: Stopwatch = .{ .steady = .{} },
    };

    pub const FrameError = zui_wire.HeaderError || error{
        /// The page sent a frame, which only goes the other way.
        UnexpectedFrame,
        /// More record bytes arrived than are held, or a record larger
        /// than all of them.
        RecordsExceedCapacity,
        /// The frame was larger than `max_frame_bytes`; it is dropped and
        /// the next is written whole.
        FrameTooLarge,
    };

    pub fn init(self: *TourSession, gpa: std.mem.Allocator, stepped: *SteppedIo, options: Options) !void {
        self.* = .{
            .gpa = gpa,
            .stepped = stepped,
            .session = undefined,
            .decoder = undefined,
            .encoder = undefined,
            .received = undefined,
            .pending_records = &.{},
            .frame_bytes = &.{},
        };
        self.decoder = try .init(gpa, .of(App.Ui));
        errdefer self.decoder.deinit(gpa);
        self.encoder = try .init(gpa);
        errdefer self.encoder.deinit(gpa);
        const event_buffer = try gpa.alloc(zui.Event, App.Ui.limits.max_events_per_frame);
        errdefer gpa.free(event_buffer);
        const text_buffer = try gpa.alloc(u8, @as(usize, App.Ui.limits.max_text_input_bytes) + App.Ui.limits.max_dropped_path_bytes);
        errdefer gpa.free(text_buffer);
        self.received = .init(event_buffer, text_buffer);
        self.pending_records = try gpa.alloc(u8, options.max_pending_record_bytes);
        errdefer gpa.free(self.pending_records);
        self.frame_bytes = try gpa.alloc(u8, options.max_frame_bytes);
        errdefer gpa.free(self.frame_bytes);

        self.session = try gpa.create(zui_app.Session(App));
        errdefer gpa.destroy(self.session);
        self.session.host.page = self;
        try self.session.start(.{ .gpa = gpa, .io = stepped.io() }, .{ .notify = ignoreNotice });
        self.session.app.stopwatch = options.stopwatch;
    }

    /// Cancels the tour's tasks, which the `Io` runs to their end.
    pub fn deinit(self: *TourSession) void {
        const gpa = self.gpa;
        self.session.stop();
        gpa.destroy(self.session);
        gpa.free(self.frame_bytes);
        gpa.free(self.pending_records);
        gpa.free(self.received.text_buffer);
        gpa.free(self.received.event_buffer);
        self.encoder.deinit(gpa);
        self.decoder.deinit(gpa);
    }

    /// What the tour measured of its frames, for what a page shows beside
    /// them.
    pub fn perf(self: *const TourSession) *const zui_tour.Perf {
        return &self.session.app.tour.perf;
    }

    /// Memory for the next `count` bytes of the page's records, which the
    /// transport writes in place before `receivedRecords(count)`.
    pub fn roomForRecords(self: *TourSession, count: usize) error{RecordsExceedCapacity}![]u8 {
        if (self.read_start != 0) {
            const unread_count = self.pending_end - self.read_start;
            std.mem.copyForwards(u8, self.pending_records[0..unread_count], self.pending_records[self.read_start..self.pending_end]);
            self.pending_end = unread_count;
            self.read_start = 0;
        }
        if (count > self.pending_records.len - self.pending_end) return error.RecordsExceedCapacity;
        return self.pending_records[self.pending_end..][0..count];
    }

    pub fn receivedRecords(self: *TourSession, count: usize) void {
        std.debug.assert(count <= self.pending_records.len - self.pending_end);
        self.pending_end += count;
    }

    /// Steps the tour's tasks to `now_milliseconds` on the page's clock,
    /// takes every record that has arrived whole, and steps the session,
    /// which declares a frame if one is due. Returns that frame as wire
    /// bytes, valid until the next call; null until the first record has
    /// measured the canvas, or while no frame is due. The tour's strip shows
    /// how long the page took to draw the frames before as its renderer's
    /// submit time, `previous_draw_milliseconds` being the newest.
    pub fn frame(self: *TourSession, now_milliseconds: f64, previous_draw_milliseconds: f64) anyerror!?[]const u8 {
        const now: zui.Instant = .fromNanoseconds(@intFromFloat(@max(0, now_milliseconds) * std.time.ns_per_ms));
        self.stepped.step(now.nanoseconds);
        self.received.begin(.{ .now = now, .viewport = .{ 0, 0 } });
        try self.takeRecords();
        if (self.measured == null) return null;

        self.session.renderer.drew(previous_draw_milliseconds);
        self.written = null;
        self.next = (try self.session.step()) orelse .on_event;
        return self.written;
    }

    /// When the page should next call `frame`, on its clock: the tour's
    /// `nextFrame`, or sooner, when one of its tasks wakes. Tasks run only
    /// inside a frame, so where a native host sleeps until a task's thread
    /// wakes it, the page wakes the task instead.
    pub fn nextWake(self: *const TourSession) zui.NextFrame {
        const task_nanoseconds = self.stepped.nextWakeNanoseconds() orelse return self.next;
        return self.next.sooner(.{ .at = .fromNanoseconds(@intCast(@max(0, task_nanoseconds))) });
    }

    fn pollInto(self: *TourSession, record: *zui.RecordBuilder) void {
        const measured = self.measured.?;
        const zoom = record.params.zoom;
        record.begin(.{ .now = self.received.params.now, .viewport = .{ measured.viewport[0] / zoom, measured.viewport[1] / zoom }, .scale = measured.scale });
        for (self.received.events()) |event| switch (event) {
            .text => |text| record.appendText(text),
            .files_dropped => |drop| record.appendFilesDropped(drop),
            else => record.append(event),
        };
        record.dropped_events +|= self.received.dropped_events;
        record.dropped_text_bytes +|= self.received.dropped_text_bytes;
    }

    fn writeFrame(self: *TourSession, declared: *const App.Ui.Frame) error{FrameTooLarge}!void {
        var writer: std.Io.Writer = .fixed(self.frame_bytes);
        self.writeFrameTo(&writer, declared) catch {
            self.key_frame_next = true;
            return error.FrameTooLarge;
        };
        self.written = writer.buffered();
    }

    fn writeFrameTo(self: *TourSession, writer: *std.Io.Writer, declared: *const App.Ui.Frame) zui_wire.WriteError!void {
        if (!self.header_written) try zui_wire.writeHeader(writer, self.fingerprint);
        if (self.key_frame_next) try self.encoder.writeKeyFrame(writer, declared) else try self.encoder.writeFrame(writer, declared);
        self.header_written = true;
        self.key_frame_next = false;
    }

    fn takeRecords(self: *TourSession) FrameError!void {
        while (true) {
            var reader: std.Io.Reader = .fixed(self.pending_records[self.read_start..self.pending_end]);
            if (!self.records_header_read) {
                zui_wire.readHeader(&reader, null) catch |err| return self.waitingFor(err);
                self.read_start += reader.seek;
                self.records_header_read = true;
                continue;
            }
            const message = (self.decoder.next(&reader) catch |err| return self.waitingFor(err)) orelse return;
            self.read_start += reader.seek;
            const record = switch (message) {
                .record => |record| record,
                .frame => return error.UnexpectedFrame,
            };
            self.measured = .{ .viewport = record.params.viewport, .scale = record.params.scale };
            for (record.events) |event| switch (event) {
                .text => |text| self.received.appendText(text),
                .files_dropped => |drop| self.received.appendFilesDropped(drop),
                else => self.received.append(event),
            };
        }
    }

    /// A record cut short is read again once the rest has arrived.
    fn waitingFor(self: *const TourSession, err: zui_wire.HeaderError) FrameError!void {
        if (err != error.EndOfStream) return err;
        const record_fills_every_byte_held = self.pending_end - self.read_start == self.pending_records.len;
        if (record_fills_every_byte_held) return error.RecordsExceedCapacity;
    }

    fn ignoreNotice(_: zui_app.Notice) void {}
};

/// The page as the tour's host: its window is the canvas the page
/// measures, its input the records the page sends, and its loop the
/// page's, which steps the session, so it declares neither `zuiWait` nor
/// `zuiRun`. Its surface is the page link the renderer writes frames to.
pub const PageHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.wire);

    page: *TourSession,

    pub fn init(_: *PageHost, _: std.Io, _: zui.WindowOptions) !void {}

    pub fn deinit(_: *PageHost) void {}

    pub fn zuiPoll(self: *PageHost, _: zui.WindowId, record: *zui.RecordBuilder) bool {
        self.page.pollInto(record);
        return true;
    }

    /// The tour's tasks run only while the page steps it, and the page asks
    /// `nextWake` after each step, so a wake has nothing to end.
    pub fn zuiWaker(self: *PageHost) zui.Waker {
        return .{ .context = self, .wakeFn = ignoreWake };
    }

    pub fn zuiSurface(self: *PageHost, _: zui.WindowId) zui.Surface {
        return .{ .wire = .{ .connection = self.page } };
    }

    /// A frame's requests reach the page inside its wire bytes.
    pub fn zuiApply(_: *PageHost, _: zui.WindowId, _: zui.HostRequests) void {}

    fn ignoreWake(_: *anyopaque) void {}
};

/// What the page draws, declared as `zui_webgl.Renderer` declares it, so the
/// tour's frames carry exactly the commands and payloads the page's WebGL
/// drawing draws. It draws nothing itself: each frame is written as wire
/// bytes for the page, which draws it after the step returns and reports
/// how long that took.
pub const PageRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.wire);
    pub const zui_commands = zui_webgl.Renderer.zui_commands;
    pub const zui_extended_color = zui_webgl.Renderer.zui_extended_color;
    pub const ImageHandle = zui_webgl.Renderer.ImageHandle;
    pub const MaterialHandle = zui_webgl.Renderer.MaterialHandle;

    /// The page's draw times, smoothed; null before the first.
    smoothed_draw_microseconds: ?f32 = null,

    /// Puts the fingerprint of the fonts frames are measured with in the
    /// stream's header, so a client with other fonts refuses the stream.
    pub fn init(_: *PageRenderer, surface: zui.Surface, text: anytype) error{UnsupportedSurface}!void {
        (try pageOf(surface)).fingerprint = zui_wire.fingerprintOf(text);
    }

    pub fn zuiSubmit(_: *PageRenderer, surface: zui.Surface, frame: anytype) error{ UnsupportedSurface, FrameTooLarge }!void {
        try (try pageOf(surface)).writeFrame(frame);
    }

    /// The page took `milliseconds` to draw the frame before.
    pub fn drew(self: *PageRenderer, milliseconds: f64) void {
        const microseconds: f32 = @floatCast(milliseconds * std.time.us_per_ms);
        self.smoothed_draw_microseconds = if (self.smoothed_draw_microseconds) |smoothed| smoothed * 0.95 + microseconds * 0.05 else microseconds;
    }

    pub fn submitMicroseconds(self: *const PageRenderer) f32 {
        return self.smoothed_draw_microseconds orelse 0;
    }

    fn pageOf(surface: zui.Surface) error{UnsupportedSurface}!*TourSession {
        return switch (surface) {
            .wire => |link| @ptrCast(@alignCast(link.connection)),
            else => error.UnsupportedSurface,
        };
    }
};

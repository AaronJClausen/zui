const std = @import("std");
const zui = @import("zui");
const zui_wire = @import("zui_wire");
const zui_tour = @import("zui_tour");
const zui_truetype = @import("zui_truetype");
const zui_webgl = @import("zui_webgl");
const FrameReason = zui_tour.FrameReason;

pub const SteppedIo = @import("stepped_io.zig").SteppedIo;

/// The tour as the browser draws it: declared for `zui_webgl.Drawing`, in
/// `zui_truetype`'s layout of the three fonts it adds, which the page hands
/// the client in the same order.
pub const kit = zui_tour.Kit(.{ .Renderer = zui_webgl.Drawing, .FontSystem = zui_truetype.Text, .inspector = false, .renderer_name = "the browser" });
pub const Ui = kit.Ui;
pub const Tour = zui_tour.Tour(kit);

/// The tour, run by a loop that owns its clock: the page's, in a
/// browser's worker. Each `frame` steps the tour's `Io` to the page's
/// instant, takes the records the page sent since the last, declares a
/// frame, times it on the session's `Stopwatch` for the tour's strip, and
/// writes it as the wire renderer sends it, the stream's header before the
/// first. Given the same instants, records and draw times, and a `.steady`
/// stopwatch, it writes the same bytes in a worker as natively. A page that
/// sleeps between frames, as a native host does, declares one only
/// `.when_due` and wakes when `nextWake` says. Memory is reserved by `init`.
///
/// ```zig
/// try session.init(gpa, &stepped, .{ .stopwatch = .{ .clock = performanceNow } });
/// @memcpy(try session.roomForRecords(bytes.len), bytes);
/// session.receivedRecords(bytes.len);
/// if (try session.frame(.when_due, page_milliseconds, last_draw_milliseconds)) |wire_bytes| post(wire_bytes);
/// sleepUntil(session.nextWake());
/// ```
pub const TourSession = struct {
    /// The threads the tour's tasks take turns on, the same wherever it
    /// runs, since how many run at once changes what it draws: a Gallery
    /// tile waits to start loading while sixteen tasks hold a thread.
    pub const thread_count = 16;

    gpa: std.mem.Allocator,
    stepped: *SteppedIo,
    text: kit.Text,
    ui: Ui,
    app: *Tour,
    decoder: zui_wire.Decoder(Ui),
    encoder: zui_wire.Encoder(Ui),
    builder: zui.RecordBuilder,
    pending_records: []u8,
    pending_end: usize = 0,
    read_start: usize = 0,
    records_header_read: bool = false,
    /// The canvas as the newest record measured it; no frame is declared
    /// before the first record.
    measured: ?struct { viewport: [2]f32, scale: f32 } = null,
    frame_bytes: []u8,
    header_written: bool = false,
    /// Set when a frame did not fit `frame_bytes`, so the next is written
    /// whole rather than as changes from one the page never received.
    key_frame_next: bool = false,
    stopwatch: Stopwatch,
    steady_stopwatch_reads: u64 = 0,
    previous_params: ?zui.FrameParams = null,

    /// What the tour's frames are timed by: the page's `Io` cannot time
    /// them, since it holds one instant for all of a frame.
    pub const Stopwatch = union(enum) {
        /// Milliseconds since a fixed instant, such as the page's
        /// `performance.now()`.
        clock: *const fn () callconv(.c) f64,
        /// Moves on `step_nanoseconds` each time it is read, so every run
        /// times its frames alike and draws the same timings.
        steady: struct { step_nanoseconds: u64 = std.time.ns_per_us },
    };

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
            .text = undefined,
            .ui = undefined,
            .app = undefined,
            .decoder = undefined,
            .encoder = undefined,
            .builder = undefined,
            .pending_records = &.{},
            .frame_bytes = &.{},
            .stopwatch = options.stopwatch,
        };
        try self.text.init();
        errdefer self.text.deinit();
        const io = stepped.io();
        self.ui = try .init(gpa, io, &self.text);
        errdefer self.ui.deinit(gpa);
        self.app = try gpa.create(Tour);
        errdefer gpa.destroy(self.app);
        self.app.init(io, .zero, self.text.fonts);
        errdefer self.app.deinit();
        self.decoder = try .init(gpa, .of(Ui));
        errdefer self.decoder.deinit(gpa);
        self.encoder = try .init(gpa);
        errdefer self.encoder.deinit(gpa);
        const event_buffer = try gpa.alloc(zui.Event, Ui.limits.max_events_per_frame);
        errdefer gpa.free(event_buffer);
        const text_buffer = try gpa.alloc(u8, @as(usize, Ui.limits.max_text_input_bytes) + Ui.limits.max_dropped_path_bytes);
        errdefer gpa.free(text_buffer);
        self.builder = .init(event_buffer, text_buffer);
        self.pending_records = try gpa.alloc(u8, options.max_pending_record_bytes);
        errdefer gpa.free(self.pending_records);
        self.frame_bytes = try gpa.alloc(u8, options.max_frame_bytes);
    }

    /// Cancels the tour's tasks, which the `Io` runs to their end.
    pub fn deinit(self: *TourSession) void {
        const gpa = self.gpa;
        self.app.deinit();
        gpa.destroy(self.app);
        self.ui.deinit(gpa);
        self.text.deinit();
        gpa.free(self.frame_bytes);
        gpa.free(self.pending_records);
        gpa.free(self.builder.text_buffer);
        gpa.free(self.builder.event_buffer);
        self.encoder.deinit(gpa);
        self.decoder.deinit(gpa);
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

    pub const Declaring = enum {
        /// A frame at every call, whether one is due or not.
        every_call,
        /// Only when a host that sleeps between frames would declare one:
        /// on input, a resize, a source that delivered, a requested frame
        /// or a deadline that came due.
        when_due,
    };

    /// Steps the tour's tasks to `now_milliseconds` on the page's clock,
    /// declares a frame with the events of every record that has arrived
    /// whole, and returns it as wire bytes, valid until the next call; null
    /// until the first record has measured the canvas, or `.when_due` while
    /// none is. The tour's strip shows `previous_draw_milliseconds`, how
    /// long the page took to draw the frame before, as its renderer's
    /// submit time.
    pub fn frame(self: *TourSession, declaring: Declaring, now_milliseconds: f64, previous_draw_milliseconds: f64) FrameError!?[]const u8 {
        const now: zui.Instant = .fromNanoseconds(@intFromFloat(@max(0, now_milliseconds) * std.time.ns_per_ms));
        self.stepped.step(now.nanoseconds);

        const app = self.app;
        const builder = &self.builder;
        builder.begin(.{ .now = now, .viewport = .{ 0, 0 } });
        for (app.environment_changes.drain()) |change| builder.append(.{ .environment = change });
        try self.takeRecords();
        const measured = self.measured orelse return null;
        builder.params.viewport = measured.viewport;
        builder.params.scale = measured.scale;

        const due_reason = self.frameReason(builder.params, builder.events().len);
        const reason = switch (declaring) {
            .every_call => due_reason orelse .requested,
            .when_due => due_reason orelse return null,
        };
        const measure_calls_before = self.ui.measureCalls();
        const started = self.readStopwatch();
        self.ui.beginFrame(&.{ .params = builder.params, .events = builder.events() }, &app.sources);
        const began = self.readStopwatch();
        app.declare(&self.ui);
        const declaration_ended = self.readStopwatch();
        const declared = self.ui.endFrame();
        const ended = self.readStopwatch();
        app.observe(&self.ui, declared);
        app.afterFrame(&self.ui);
        defer self.ui.release(declared);

        const measure_calls = self.ui.measureCalls() - measure_calls_before;
        const perf = &app.perf;
        perf.record(.{
            .begin_frame_us = microsecondsBetween(started, began),
            .declare_us = microsecondsBetween(began, declaration_ended),
            .end_frame_us = microsecondsBetween(declaration_ended, ended),
            .elements = declared.elementCount(),
            .commands = @intCast(declared.commands().len),
            .measure_calls = @intCast(measure_calls),
            .reason = reason,
        });
        const submit_microseconds: f32 = @floatCast(previous_draw_milliseconds * std.time.us_per_ms);
        perf.submit_us = if (perf.zui_frames == 0) submit_microseconds else perf.submit_us * 0.95 + submit_microseconds * 0.05;
        perf.zui_frames += 1;
        perf.countFrameAt(now.secondsSince(app.started_at));
        perf.measure_calls_total += measure_calls;
        perf.diagnostics = declared.diagnostics;
        perf.wakes = app.wakes.load(.monotonic);
        perf.next_frame = self.ui.nextFrame(&app.sources);
        perf.next_frame_seconds = switch (perf.next_frame) {
            .at => |deadline| deadline.secondsSince(now),
            else => 0,
        };
        self.previous_params = builder.params;

        var writer: std.Io.Writer = .fixed(self.frame_bytes);
        self.writeFrame(&writer, declared) catch {
            self.key_frame_next = true;
            return error.FrameTooLarge;
        };
        return writer.buffered();
    }

    /// When the page should next call `frame(.when_due, ...)`, on its
    /// clock: the tour's `nextFrame`, or sooner, when one of its tasks
    /// wakes. Tasks run only inside a frame, so where a native host sleeps
    /// until a task's thread wakes it, the page wakes the task instead.
    pub fn nextWake(self: *const TourSession) zui.NextFrame {
        const tour_next = self.ui.nextFrame(&self.app.sources);
        const task_nanoseconds = self.stepped.nextWakeNanoseconds() orelse return tour_next;
        const task_wake: zui.Instant = .fromNanoseconds(@intCast(@max(0, task_nanoseconds)));
        return switch (tour_next) {
            .immediately => .immediately,
            .at => |deadline| .{ .at = if (task_wake.isBefore(deadline)) task_wake else deadline },
            .on_event => .{ .at = task_wake },
        };
    }

    /// Why the tour declares this frame, as a host that declares only the
    /// frames zui needs would tell it, or null if it would not declare one.
    fn frameReason(self: *const TourSession, params: zui.FrameParams, event_count: usize) ?FrameReason {
        const previous = self.previous_params orelse return .first;
        if (event_count != 0) return .input;
        if (!std.meta.eql(params.viewport, previous.viewport) or params.scale != previous.scale or params.zoom != previous.zoom) return .resize;
        inline for (@typeInfo(kit.Sources).@"struct".fields) |field| {
            if (@field(&self.app.sources, field.name).zuiPending()) return .source;
        }
        return switch (self.ui.nextFrame(&self.app.sources)) {
            .immediately => .requested,
            .at => |deadline| if (params.now.isBefore(deadline)) null else .timer,
            .on_event => null,
        };
    }

    fn readStopwatch(self: *TourSession) zui.Instant {
        switch (self.stopwatch) {
            .clock => |milliseconds| return .fromNanoseconds(@intFromFloat(@max(0, milliseconds()) * std.time.ns_per_ms)),
            .steady => |steady| {
                self.steady_stopwatch_reads += 1;
                return .fromNanoseconds(self.steady_stopwatch_reads * steady.step_nanoseconds);
            },
        }
    }

    fn writeFrame(self: *TourSession, writer: *std.Io.Writer, declared: *const Ui.Frame) zui_wire.WriteError!void {
        if (!self.header_written) try zui_wire.writeHeader(writer, zui_wire.fingerprintOf(&self.text));
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
                .text => |text| self.builder.appendText(text),
                .files_dropped => |drop| self.builder.appendFilesDropped(drop),
                else => self.builder.append(event),
            };
        }
    }

    fn microsecondsBetween(earlier: zui.Instant, later: zui.Instant) f32 {
        return later.secondsSince(earlier) * std.time.us_per_s;
    }

    /// A record cut short is read again once the rest has arrived.
    fn waitingFor(self: *const TourSession, err: zui_wire.HeaderError) FrameError!void {
        if (err != error.EndOfStream) return err;
        const record_fills_every_byte_held = self.pending_end - self.read_start == self.pending_records.len;
        if (record_fills_every_byte_held) return error.RecordsExceedCapacity;
    }
};

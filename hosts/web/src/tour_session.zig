const std = @import("std");
const zui_sokol_ui = @import("zui_sokol_ui");
const zui_wire = @import("zui_wire");
const tour = @import("zui_sokol_tour");
const zui = tour.kit.zui;

pub const SteppedIo = @import("stepped_io.zig").SteppedIo;

pub const Ui = tour.kit.Ui;

/// zui-sokol's tour, run by a loop that owns its clock: the page's, in a
/// browser's worker. Each `frame` steps the tour's `Io` to the page's
/// instant, takes the records the page sent since the last, declares a
/// frame and writes it as the wire renderer sends it, the stream's header
/// before the first. Given the same instants and records, it writes the
/// same bytes in a worker as natively. Memory is reserved by `init`.
///
/// ```zig
/// try session.init(gpa, &stepped, .{});
/// @memcpy(try session.roomForRecords(bytes.len), bytes);
/// session.receivedRecords(bytes.len);
/// if (try session.frame(page_milliseconds)) |wire_bytes| post(wire_bytes);
/// ```
pub const TourSession = struct {
    /// The threads the tour's tasks take turns on, the same wherever it
    /// runs, since how many run at once changes what it draws: a Gallery
    /// tile waits to start loading while sixteen tasks hold a thread.
    pub const thread_count = 16;

    gpa: std.mem.Allocator,
    stepped: *SteppedIo,
    text: zui_sokol_ui.Text,
    ui: Ui,
    app: *tour.App,
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

    pub const Options = struct {
        /// The most bytes held of records that have not arrived whole.
        max_pending_record_bytes: usize = 256 * 1024,
        /// The most bytes one frame is written in: at least a key frame of
        /// every command.
        max_frame_bytes: usize = 4 << 20,
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
            .text = .{},
            .ui = undefined,
            .app = undefined,
            .decoder = undefined,
            .encoder = undefined,
            .builder = undefined,
            .pending_records = &.{},
            .frame_bytes = &.{},
        };
        try tour.kit.addFonts(&self.text);
        const io = stepped.io();
        self.ui = try .init(gpa, io, &self.text);
        errdefer self.ui.deinit(gpa);
        self.app = try gpa.create(tour.App);
        errdefer gpa.destroy(self.app);
        self.app.init(io, .zero);
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

    /// Steps the tour's tasks to `now_milliseconds` on the page's clock,
    /// declares a frame with the events of every record that has arrived
    /// whole, and returns it as wire bytes, valid until the next call; null
    /// until the first record has measured the canvas.
    pub fn frame(self: *TourSession, now_milliseconds: f64) FrameError!?[]const u8 {
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

        self.ui.beginFrame(&.{ .params = builder.params, .events = builder.events() }, &app.sources);
        app.declare(&self.ui);
        const declared = self.ui.endFrame();
        app.afterFrame(&self.ui);
        defer self.ui.release(declared);

        var writer: std.Io.Writer = .fixed(self.frame_bytes);
        self.writeFrame(&writer, declared) catch {
            self.key_frame_next = true;
            return error.FrameTooLarge;
        };
        return writer.buffered();
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

    /// A record cut short is read again once the rest has arrived.
    fn waitingFor(self: *const TourSession, err: zui_wire.HeaderError) FrameError!void {
        if (err != error.EndOfStream) return err;
        const record_fills_every_byte_held = self.pending_end - self.read_start == self.pending_records.len;
        if (record_fills_every_byte_held) return error.RecordsExceedCapacity;
    }
};

const std = @import("std");
const zui = @import("zui");
const zui_wire = @import("zui_wire");

/// The browser's end of the records going back to a `zui_wire.Host`: the
/// page appends its events to `builder` and measures the canvas, and
/// `take` writes what to send, as `zui_wire.Client` sends it. Memory is
/// reserved by `init`.
///
/// ```zig
/// var records: RecordStream(Ui) = try .init(gpa, .{});
/// records.measure(.{ 1280, 800 }, 1.5);
/// records.builder.append(.{ .pointer_move = .{ .pointer = mouse } });
/// if (try records.take(now)) |bytes| transport.send(bytes);
/// ```
pub fn RecordStream(comptime Ui: type) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            /// The fonts this end draws with, `zui_wire.fingerprintOf(&text)`,
            /// written in the stream's header.
            fingerprint: ?u64 = null,
        };

        pub const TakeError = error{
            /// The record did not fit the bytes reserved for one, which
            /// `messageBytes` makes room for; its events were dropped and
            /// counted in `dropped_events`.
            RecordTooLarge,
        };

        builder: zui.RecordBuilder,
        /// Since `init`, events past the builder's room, and events in
        /// records too large to send.
        dropped_events: u32 = 0,
        encoder: zui_wire.Encoder(Ui),
        message: []u8,
        fingerprint: ?u64,
        header_written: bool = false,
        last_sent: ?zui.RecordBuilder.HostParams = null,

        const header_bytes_most = 16;
        const kind_params_and_count_bytes_most = 48;

        /// Room for a header and a record of every event the builder holds,
        /// each written at most twice its size in memory, and its text.
        pub fn messageBytes() usize {
            return header_bytes_most + kind_params_and_count_bytes_most + 2 * @sizeOf(zui.Event) * @as(usize, Ui.limits.max_events_per_frame) + recordTextBytes();
        }

        fn recordTextBytes() usize {
            return @as(usize, Ui.limits.max_text_input_bytes) + Ui.limits.max_dropped_path_bytes;
        }

        pub fn init(gpa: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Self {
            const event_buffer = try gpa.alloc(zui.Event, Ui.limits.max_events_per_frame);
            errdefer gpa.free(event_buffer);
            const text_buffer = try gpa.alloc(u8, recordTextBytes());
            errdefer gpa.free(text_buffer);
            var encoder: zui_wire.Encoder(Ui) = try .init(gpa);
            errdefer encoder.deinit(gpa);
            return .{
                .builder = .init(event_buffer, text_buffer),
                .encoder = encoder,
                .message = try gpa.alloc(u8, messageBytes()),
                .fingerprint = options.fingerprint,
            };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            gpa.free(self.message);
            self.encoder.deinit(gpa);
            gpa.free(self.builder.text_buffer);
            gpa.free(self.builder.event_buffer);
        }

        /// The canvas's size in layout units, and physical pixels per unit.
        pub fn measure(self: *Self, viewport: [2]f32, scale: f32) void {
            self.builder.params.viewport = viewport;
            self.builder.params.scale = scale;
        }

        /// The bytes to send, valid until the next `take`: the stream's
        /// header before the first record, then a record at `now` of the
        /// events appended since the last, or null when there are none and
        /// the viewport and scale are as last sent, since the host counts
        /// the time on itself.
        pub fn take(self: *Self, now: zui.Instant) TakeError!?[]const u8 {
            self.builder.params.now = now;
            const params = self.builder.params;
            const measured: zui.RecordBuilder.HostParams = .{ .now = params.now, .viewport = params.viewport, .scale = params.scale };
            const resized = if (self.last_sent) |last| !std.meta.eql(last.viewport, measured.viewport) or last.scale != measured.scale else true;
            if (!resized and self.builder.event_count == 0) return null;

            const record: Ui.FrameRecord = .{ .params = params, .events = self.builder.events() };
            const params_before = self.encoder.last_record_params;
            var writer: std.Io.Writer = .fixed(self.message);
            const written = written: {
                if (!self.header_written) zui_wire.writeHeader(&writer, self.fingerprint) catch break :written false;
                self.encoder.writeRecord(&writer, &record) catch break :written false;
                break :written true;
            };
            if (!written) {
                self.encoder.last_record_params = params_before;
                self.dropped_events +|= self.builder.dropped_events +| std.math.lossyCast(u32, self.builder.event_count);
                self.builder.begin(measured);
                return error.RecordTooLarge;
            }
            self.header_written = true;
            self.last_sent = measured;
            self.dropped_events +|= self.builder.dropped_events;
            self.builder.begin(measured);
            return writer.buffered();
        }
    };
}

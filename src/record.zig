const std = @import("std");
const input = @import("input.zig");
const Rect = @import("style.zig").Rect;

/// A reading of the host's monotonic clock. Only differences between two
/// instants from the same host mean anything.
pub const Instant = struct {
    nanoseconds: u64,

    pub const zero: Instant = .{ .nanoseconds = 0 };

    pub fn fromNanoseconds(nanoseconds: u64) Instant {
        return .{ .nanoseconds = nanoseconds };
    }

    /// For hosts that read `std.Io.Clock.awake`.
    pub fn fromTimestamp(timestamp: std.Io.Timestamp) Instant {
        return .{ .nanoseconds = std.math.lossyCast(u64, timestamp.nanoseconds) };
    }

    pub fn addNanoseconds(self: Instant, nanoseconds: u64) Instant {
        return .{ .nanoseconds = self.nanoseconds +| nanoseconds };
    }

    pub fn addSeconds(self: Instant, seconds: f64) Instant {
        return self.addNanoseconds(std.math.lossyCast(u64, seconds * std.time.ns_per_s));
    }

    /// 0 when `earlier` is not earlier.
    pub fn secondsSince(self: Instant, earlier: Instant) f32 {
        const elapsed = self.nanoseconds -| earlier.nanoseconds;
        return @floatCast(@as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s);
    }

    pub fn isBefore(self: Instant, other: Instant) bool {
        return self.nanoseconds < other.nanoseconds;
    }
};

pub const FrameParams = struct {
    /// The host's monotonic clock.
    now: Instant,
    /// Width and height, in layout units.
    viewport: [2]f32,
    /// Physical pixels per layout unit, from the display.
    scale: f32 = 1,
    /// The application's zoom, multiplied into layout.
    zoom: f32 = 1,
};

/// Everything inbound for one frame. It is borrowed: zui copies what it
/// keeps before `beginFrame` returns. A `Context` with sources takes
/// `FrameRecordWith(Ui.Deliveries)` instead, as `Ui.FrameRecord`.
pub const FrameRecord = struct {
    params: FrameParams,
    /// In arrival order.
    events: []const input.Event = &.{},
};

/// `FrameRecord` with recorded deliveries, for a `Context` with sources.
pub fn FrameRecordWith(comptime Deliveries: type) type {
    return struct {
        params: FrameParams,
        /// In arrival order.
        events: []const input.Event = &.{},
        /// Set to replay: each source takes its recorded delivery instead
        /// of swapping.
        deliveries: ?*const Deliveries = null,
    };
}

/// What a host fills in `zuiPoll`: the parameters it measures and the
/// events since the last record, in memory the application reserved, so
/// polling allocates nothing. The application keeps `params.zoom`.
///
/// ```zig
/// var events: [256]zui.Event = undefined;
/// var text: [256]u8 = undefined;
/// var builder: zui.RecordBuilder = .init(&events, &text);
/// while (host.zuiPoll(.main, &builder)) {
///     ui.beginFrame(&builder.record()); // with sources: builder.recordWith(Ui.Deliveries)
///     // ...
/// }
/// ```
pub const RecordBuilder = struct {
    params: FrameParams = .{ .now = .zero, .viewport = .{ 0, 0 } },
    event_buffer: []input.Event,
    event_count: usize = 0,
    text_buffer: []u8,
    text_len: usize = 0,
    /// Events refused since `begin` because `event_buffer` was full.
    dropped_events: u32 = 0,
    /// Bytes of text refused since `begin`, with their events or because
    /// `text_buffer` was full.
    dropped_text_bytes: u32 = 0,

    /// The parameters a host measures; zoom is the application's.
    pub const HostParams = struct {
        now: Instant,
        viewport: [2]f32,
        scale: f32 = 1,
    };

    pub fn init(event_buffer: []input.Event, text_buffer: []u8) RecordBuilder {
        return .{ .event_buffer = event_buffer, .text_buffer = text_buffer };
    }

    /// Starts a record: forgets the last one's events and text, and sets
    /// what the host measures. The zoom is kept.
    pub fn begin(self: *RecordBuilder, host_params: HostParams) void {
        self.params = .{ .now = host_params.now, .viewport = host_params.viewport, .scale = host_params.scale, .zoom = self.params.zoom };
        self.event_count = 0;
        self.text_len = 0;
        self.dropped_events = 0;
        self.dropped_text_bytes = 0;
    }

    /// Keeps `event` if there is room. When there is none the newest is
    /// dropped, so what is kept stays in arrival order. A `.text` event
    /// appended here borrows its bytes; `appendText` copies them.
    pub fn append(self: *RecordBuilder, event: input.Event) void {
        if (self.event_count == self.event_buffer.len) {
            self.dropped_events +|= 1;
            if (event == .text) self.dropped_text_bytes +|= saturatingCount(event.text.len);
            return;
        }
        self.event_buffer[self.event_count] = event;
        self.event_count += 1;
    }

    /// Copies committed UTF-8 into `text_buffer`, so the host may reuse its
    /// own at once, and appends it as a `.text` event. What does not fit is
    /// cut at a character boundary.
    pub fn appendText(self: *RecordBuilder, text: []const u8) void {
        if (self.event_count == self.event_buffer.len) return self.append(.{ .text = text });
        const room = self.text_buffer.len - self.text_len;
        var kept = @min(text.len, room);
        if (kept < text.len) {
            while (kept > 0 and text[kept] & 0b1100_0000 == 0b1000_0000) kept -= 1;
            self.dropped_text_bytes +|= saturatingCount(text.len - kept);
        }
        if (kept == 0) return;
        const copy = self.text_buffer[self.text_len..][0..kept];
        @memcpy(copy, text[0..kept]);
        self.text_len += kept;
        self.append(.{ .text = copy });
    }

    /// Valid until the next `begin`.
    pub fn events(self: *const RecordBuilder) []const input.Event {
        return self.event_buffer[0..self.event_count];
    }

    /// The record for a `Context` without sources. It borrows the
    /// builder's memory until the next `begin`.
    pub fn record(self: *const RecordBuilder) FrameRecord {
        return .{ .params = self.params, .events = self.events() };
    }

    /// The record for a `Context` with sources, which swap rather than
    /// replay: `builder.recordWith(Ui.Deliveries)`.
    pub fn recordWith(self: *const RecordBuilder, comptime Deliveries: type) FrameRecordWith(Deliveries) {
        return .{ .params = self.params, .events = self.events() };
    }

    fn saturatingCount(count: usize) u32 {
        return std.math.lossyCast(u32, count);
    }
};

/// The pointer's shape. Hosts map each to the closest their OS has.
pub const Cursor = enum(u8) {
    default,
    /// A link or button: usually a hand.
    pointer,
    /// An I-beam, over editable text.
    text,
    crosshair,
    move,
    grab,
    grabbing,
    not_allowed,
    wait,
    /// Busy, but still accepting input.
    progress,
    help,
    resize_horizontal,
    resize_vertical,
    /// From the top-left corner to the bottom-right.
    resize_nwse,
    /// From the top-right corner to the bottom-left.
    resize_nesw,
};

/// Where the focused editable's caret is, so the host can place the IME
/// window beside it and show an on-screen keyboard.
pub const TextInputArea = struct {
    /// In layout units, from the surface's top-left.
    caret: Rect,
};

/// What a frame asks of the host rather than the renderer.
pub const HostRequests = struct {
    /// The shape for the hot element under the hovering pointer.
    cursor: Cursor = .default,
    /// Null when no editable is focused: the host hides its text input.
    text_input: ?TextInputArea = null,
};

pub const NextFrame = union(enum) {
    immediately,
    at: Instant,
    /// Sleep until input arrives or something wakes the host.
    on_event,
};

test "instants measure the seconds between them" {
    const start: Instant = .fromNanoseconds(1_000_000_000);
    try std.testing.expectEqual(@as(f32, 0.5), start.addSeconds(0.5).secondsSince(start));
    try std.testing.expectEqual(@as(f32, 0), start.secondsSince(start.addSeconds(1)));
    try std.testing.expect(start.isBefore(start.addNanoseconds(1)));
}

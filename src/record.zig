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
/// keeps before `beginFrame` returns.
pub const FrameRecord = struct {
    params: FrameParams,
    /// In arrival order.
    events: []const input.Event = &.{},
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

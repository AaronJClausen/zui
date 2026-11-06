const std = @import("std");
const Instant = @import("record.zig").Instant;

/// Identifies one contact across its events: the mouse, one finger, one pen.
pub const PointerId = enum(u32) {
    mouse = 0,
    _,
};

pub const PointerKind = enum { mouse, touch, pen };

pub const Pointer = struct {
    id: PointerId,
    kind: PointerKind,
    /// Layout units, from the surface's top-left.
    position: [2]f32,
    /// When the host received it, not when zui applied it.
    at: Instant,
    /// 0 to 1; 1 for devices without pressure.
    pressure: f32 = 1,
    /// A pen's tilt from vertical, in radians, on x and y.
    tilt: [2]f32 = .{ 0, 0 },
};

pub const Button = enum { primary, secondary, middle };

pub const PointerButton = struct {
    pointer: Pointer,
    button: Button = .primary,
};

pub const PointerMove = struct {
    pointer: Pointer,
};

pub const Wheel = struct {
    /// Where the pointer was, in layout units.
    position: [2]f32,
    /// In layout units; positive scrolls toward the end of the content.
    delta: [2]f32,
    at: Instant,
};

/// A logical key: what the key means in the user's layout, not where it is.
pub const Key = enum {
    tab,
    enter,
    escape,
    space,
    backspace,
    delete,
    insert,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    menu,

    shift,
    control,
    alt,
    super,
    caps_lock,

    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,

    minus,
    equals,
    left_bracket,
    right_bracket,
    backslash,
    semicolon,
    apostrophe,
    grave,
    comma,
    period,
    slash,

    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    /// A key the host could not map; its `scancode` still identifies it.
    unidentified,
};

pub const Modifiers = packed struct(u4) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const KeyEvent = struct {
    key: Key,
    /// As held at this event.
    modifiers: Modifiers = .{},
    repeat: bool = false,
    /// The host's physical code, opaque, for game-style bindings.
    scancode: u32 = 0,
    /// When the host received it.
    at: Instant,
};

/// A key pressed with exactly these modifiers held.
///
/// ```zig
/// if (ui.chordPressed(.{ .key = .s, .modifiers = .{ .control = true } })) save();
/// ```
pub const Chord = struct {
    key: Key,
    modifiers: Modifiers = .{},
};

pub const Event = union(enum) {
    pointer_down: PointerButton,
    pointer_up: PointerButton,
    pointer_move: PointerMove,
    /// The OS took the pointer: its press ends without a click.
    pointer_cancel: PointerId,
    /// A hovering pointer left the surface.
    pointer_leave: PointerId,
    wheel: Wheel,
    key_down: KeyEvent,
    key_up: KeyEvent,
    /// Committed UTF-8.
    text: []const u8,
};

/// Turns the state a library reports once per frame (where the mouse is,
/// which buttons are down) into the events a frame record carries. Changes
/// between two samples are lost, so a host that sees events should send
/// those instead.
///
/// ```zig
/// var events: [64]zui.Event = undefined;
/// const record: zui.FrameRecord = .{
///     .params = .{ .now = now, .viewport = viewport },
///     .events = sampler.sample(now, .{ .pointer = mouse_position, .buttons = buttons }, &events),
/// };
/// ```
pub const InputSampler = struct {
    previous_pointer: ?[2]f32 = null,
    previous_buttons: std.EnumSet(Button) = .initEmpty(),

    pub const Sample = struct {
        /// Null when the mouse is outside the surface.
        pointer: ?[2]f32 = null,
        buttons: std.EnumSet(Button) = .initEmpty(),
        wheel: [2]f32 = .{ 0, 0 },
        /// Keys that went down since the last sample, in order.
        keys_pressed: []const Key = &.{},
        modifiers: Modifiers = .{},
        /// UTF-8 typed since the last sample.
        text: []const u8 = "",
    };

    /// Writes the events between the previous sample and `current` into
    /// `buffer`, and returns those that fit.
    pub fn sample(self: *InputSampler, now: Instant, current: Sample, buffer: []Event) []const Event {
        var writer: EventWriter = .{ .buffer = buffer };
        if (current.pointer) |position| {
            const pointer: Pointer = .{ .id = .mouse, .kind = .mouse, .position = position, .at = now };
            const moved = if (self.previous_pointer) |previous| previous[0] != position[0] or previous[1] != position[1] else true;
            if (moved) writer.append(.{ .pointer_move = .{ .pointer = pointer } });
            for (std.enums.values(Button)) |button| {
                const was_down = self.previous_buttons.contains(button);
                const is_down = current.buttons.contains(button);
                if (is_down and !was_down) writer.append(.{ .pointer_down = .{ .pointer = pointer, .button = button } });
                if (!is_down and was_down) writer.append(.{ .pointer_up = .{ .pointer = pointer, .button = button } });
            }
            if (current.wheel[0] != 0 or current.wheel[1] != 0) writer.append(.{ .wheel = .{ .position = position, .delta = current.wheel, .at = now } });
            self.previous_buttons = current.buttons;
        } else if (self.previous_pointer != null) {
            writer.append(if (self.previous_buttons.count() != 0) .{ .pointer_cancel = .mouse } else .{ .pointer_leave = .mouse });
            self.previous_buttons = .initEmpty();
        }
        self.previous_pointer = current.pointer;

        for (current.keys_pressed) |key| writer.append(.{ .key_down = .{ .key = key, .modifiers = current.modifiers, .at = now } });
        if (current.text.len != 0) writer.append(.{ .text = current.text });
        return writer.buffer[0..writer.count];
    }

    const EventWriter = struct {
        buffer: []Event,
        count: usize = 0,

        fn append(self: *EventWriter, event: Event) void {
            if (self.count == self.buffer.len) return;
            self.buffer[self.count] = event;
            self.count += 1;
        }
    };
};

test "the sampler reports what changed between samples" {
    var sampler: InputSampler = .{};
    var buffer: [8]Event = undefined;
    const now: Instant = .zero;

    var events = sampler.sample(now, .{ .pointer = .{ 10, 10 }, .buttons = .initOne(.primary) }, &buffer);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(std.meta.Tag(Event).pointer_move, std.meta.activeTag(events[0]));
    try std.testing.expectEqual(std.meta.Tag(Event).pointer_down, std.meta.activeTag(events[1]));

    events = sampler.sample(now, .{ .pointer = .{ 10, 10 }, .buttons = .initOne(.primary) }, &buffer);
    try std.testing.expectEqual(@as(usize, 0), events.len);

    events = sampler.sample(now, .{ .pointer = .{ 10, 10 }, .keys_pressed = &.{.tab}, .text = "a" }, &buffer);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(std.meta.Tag(Event).pointer_up, std.meta.activeTag(events[0]));
    try std.testing.expectEqual(Key.tab, events[1].key_down.key);
    try std.testing.expectEqualStrings("a", events[2].text);

    events = sampler.sample(now, .{}, &buffer);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(PointerId.mouse, events[0].pointer_leave);
}

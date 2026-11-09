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

/// A transformation the user applied to an element, summed over a frame.
pub const Manipulation = struct {
    /// Layout units.
    translation: [2]f32 = .{ 0, 0 },
    /// 1 leaves the size unchanged.
    scale: f32 = 1,
    /// Radians, clockwise.
    rotation: f32 = 0,
    /// The point the scale and rotation are about, after the translation:
    /// where the pointers' centroid ended, in layout units.
    pivot: [2]f32 = .{ 0, 0 },
};

/// Which way the arrow keys or a D-pad moved, on screen.
pub const NavigationDirection = enum { left, right, up, down };

pub const Wheel = struct {
    /// Where the pointer was, in layout units.
    position: [2]f32,
    /// In layout units, as the OS reports it: positive moves the view down
    /// and to the right, toward the end of the content but the start of a
    /// mirrored row.
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
    /// One setting of the environment changed; the others are kept.
    environment: EnvironmentChange,
    files_dropped: FilesDropped,
    lifecycle: Lifecycle,
};

/// Files the user dropped onto the surface.
pub const FilesDropped = struct {
    /// Where they were dropped, in layout units from the surface's top-left.
    position: [2]f32,
    /// Each path in UTF-8, followed by a 0 byte; `paths()` reads them.
    path_list: []const u8,
    at: Instant,

    /// ```zig
    /// for (ui.filesDropped()) |drop| {
    ///     var paths = drop.paths();
    ///     while (paths.next()) |path| open(path);
    /// }
    /// ```
    pub fn paths(self: FilesDropped) std.mem.TokenIterator(u8, .scalar) {
        return std.mem.tokenizeScalar(u8, self.path_list, 0);
    }
};

/// What the OS tells an application about its life. A host reports each in
/// the next record; one it cannot catch is not a value here.
pub const Lifecycle = enum(u8) {
    /// The system is about to sleep.
    @"suspend",
    /// The system woke from sleep.
    @"resume",
    /// The user or the system asked the application to end, as Ctrl+C, a
    /// console closing or the session ending do. The host closes the window
    /// after the record that carries it: `zuiPoll` returns false next.
    terminate_requested,
    /// The system is short of memory: release what can be rebuilt.
    low_memory,
};

pub const LifecycleSet = std.EnumSet(Lifecycle);

/// The language's reading direction.
pub const ReadingDirection = enum(u8) { left_to_right, right_to_left };

/// A BCP 47 language tag such as `"fr-CA"`. zui only reports it.
pub const Locale = struct {
    bytes: [capacity]u8 = @splat(0),
    len: u8 = 0,

    pub const capacity = 23;
    /// The host has not reported a locale.
    pub const default: Locale = .{};

    pub fn parse(language_tag: []const u8) error{TagTooLong}!Locale {
        if (language_tag.len > capacity) return error.TagTooLong;
        var locale: Locale = .{ .len = @intCast(language_tag.len) };
        @memcpy(locale.bytes[0..language_tag.len], language_tag);
        return locale;
    }

    pub fn tag(self: *const Locale) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: Locale, other: Locale) bool {
        return std.mem.eql(u8, self.tag(), other.tag());
    }
};

/// The user's and the system's settings, as last reported by the host.
/// Skins, motion and widgets read it through `ui.environment()`.
pub const Environment = struct {
    theme: Theme = .light,
    contrast: Contrast = .normal,
    reduced_motion: bool = false,
    reduced_transparency: bool = false,
    /// The user's text size preference, e.g. 1.25; applied by skins, not by layout.
    text_scale: f32 = 1,
    locale: Locale = .default,
    direction: ReadingDirection = .left_to_right,
    /// The display's peak over SDR white, e.g. 4; 1 is an SDR display.
    hdr_headroom: f32 = 1,
    power: Power = .plugged,
    /// The OS window has keyboard focus, not an element.
    window_focused: bool = true,
    /// The window shows the system's material (Mica, vibrancy) wherever
    /// nothing is drawn, so a root without a background lets the desktop
    /// show through. False where the OS has none, the user turned
    /// transparency off, or the window did not ask for one: the root then
    /// draws its own background.
    system_material: bool = false,

    pub const Theme = enum(u8) { light, dark };
    pub const Contrast = enum(u8) { normal, high };
    pub const Power = enum(u8) { plugged, battery, saver };

    pub fn apply(self: *Environment, change: EnvironmentChange) void {
        switch (change) {
            inline else => |value, setting| @field(self, @tagName(setting)) = value,
        }
    }
};

/// One `Environment` field's new value, so a record carries only what
/// changed:
///
/// ```zig
/// events.append(.{ .environment = .{ .theme = .dark } });
/// ```
pub const EnvironmentChange = union(enum) {
    theme: Environment.Theme,
    contrast: Environment.Contrast,
    reduced_motion: bool,
    reduced_transparency: bool,
    text_scale: f32,
    locale: Locale,
    direction: ReadingDirection,
    hdr_headroom: f32,
    power: Environment.Power,
    window_focused: bool,
    system_material: bool,
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

test "an environment change sets one setting and keeps the others" {
    var environment: Environment = .{ .reduced_motion = true };
    environment.apply(.{ .theme = .dark });
    environment.apply(.{ .locale = try .parse("fr-CA") });
    try std.testing.expectEqual(Environment.Theme.dark, environment.theme);
    try std.testing.expectEqualStrings("fr-CA", environment.locale.tag());
    try std.testing.expect(environment.reduced_motion);
    try std.testing.expectError(error.TagTooLong, Locale.parse("x" ** (Locale.capacity + 1)));
}

test "every environment setting has a change" {
    const settings = @typeInfo(Environment).@"struct".fields;
    const changes = @typeInfo(EnvironmentChange).@"union".fields;
    try std.testing.expectEqual(settings.len, changes.len);
    inline for (settings, changes) |setting, change| {
        try std.testing.expectEqualStrings(setting.name, change.name);
        try std.testing.expectEqual(setting.type, change.type);
    }
}

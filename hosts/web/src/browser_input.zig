const std = @import("std");
const zui = @import("zui");

/// A `PointerEvent.pointerType` as the page passes it.
pub const BrowserPointerKind = enum(u32) { mouse = 0, touch = 1, pen = 2 };

/// The browser's `pointerId`s are its own, so every contact but the mouse
/// is moved past `PointerId.mouse`.
pub fn pointerId(kind: zui.PointerKind, browser_pointer_id: u32) zui.PointerId {
    return if (kind == .mouse) .mouse else @enumFromInt(browser_pointer_id +| 1);
}

pub fn pointerKind(browser_kind: u32) zui.PointerKind {
    return switch (std.enums.fromInt(BrowserPointerKind, browser_kind) orelse .mouse) {
        .mouse => .mouse,
        .touch => .touch,
        .pen => .pen,
    };
}

/// `MouseEvent.button`; the back and forward buttons have no `zui.Button`.
pub fn button(browser_button: u32) ?zui.Button {
    return switch (browser_button) {
        0 => .primary,
        1 => .middle,
        2 => .secondary,
        else => null,
    };
}

/// `Event.timeStamp` and `performance.now()`, in milliseconds since the
/// page's time origin.
pub fn instant(milliseconds: f64) zui.Instant {
    return .fromNanoseconds(std.math.lossyCast(u64, milliseconds * std.time.ns_per_ms));
}

/// `WheelEvent.deltaMode`.
pub const WheelDeltaMode = enum(u32) { pixel = 0, line = 1, page = 2 };

/// Browsers that count the wheel in lines count three a notch, and a
/// notch scrolls 40 layout units.
pub const wheel_line_units: f32 = 40.0 / 3.0;

/// A wheel's delta in layout units, from one in the mode it was reported in.
pub fn wheelDelta(delta: [2]f32, browser_delta_mode: u32, viewport: [2]f32) [2]f32 {
    const units_per_step: [2]f32 = switch (std.enums.fromInt(WheelDeltaMode, browser_delta_mode) orelse .pixel) {
        .pixel => .{ 1, 1 },
        .line => .{ wheel_line_units, wheel_line_units },
        .page => viewport,
    };
    return .{ delta[0] * units_per_step[0], delta[1] * units_per_step[1] };
}

/// `KeyboardEvent.shiftKey`, `ctrlKey`, `altKey` and `metaKey`, in that
/// order from the lowest bit, as `zui.Modifiers` holds them.
pub fn modifiers(browser_modifier_bits: u32) zui.Modifiers {
    return @bitCast(@as(u4, @truncate(browser_modifier_bits)));
}

/// What a key means in the user's layout: its `KeyboardEvent.key` where
/// that names a key or a letter, and otherwise its `code`, so a digit or a
/// mark typed with Shift, or in a layout that types another character
/// there, is still the key it is pressed on.
pub fn logicalKey(key: []const u8, code: []const u8) zui.Key {
    if (named_keys.get(key)) |named| return named;
    if (key.len == 1 and std.ascii.isAlphabetic(key[0])) {
        return @enumFromInt(@intFromEnum(zui.Key.a) + (std.ascii.toLower(key[0]) - 'a'));
    }
    return keys_by_code.get(code) orelse .unidentified;
}

/// An opaque number for `KeyboardEvent.code`, the key's place on the
/// keyboard; 0 when the browser gives none.
pub fn scancode(code: []const u8) u32 {
    return if (code.len == 0) 0 else std.hash.Crc32.hash(code);
}

const named_keys: std.StaticStringMap(zui.Key) = .initComptime(.{
    .{ "Tab", .tab },
    .{ "Enter", .enter },
    .{ "Escape", .escape },
    .{ " ", .space },
    .{ "Backspace", .backspace },
    .{ "Delete", .delete },
    .{ "Insert", .insert },
    .{ "ArrowLeft", .left },
    .{ "ArrowRight", .right },
    .{ "ArrowUp", .up },
    .{ "ArrowDown", .down },
    .{ "Home", .home },
    .{ "End", .end },
    .{ "PageUp", .page_up },
    .{ "PageDown", .page_down },
    .{ "ContextMenu", .menu },
    .{ "Shift", .shift },
    .{ "Control", .control },
    .{ "Alt", .alt },
    .{ "Meta", .super },
    .{ "OS", .super },
    .{ "CapsLock", .caps_lock },
    .{ "F1", .f1 },
    .{ "F2", .f2 },
    .{ "F3", .f3 },
    .{ "F4", .f4 },
    .{ "F5", .f5 },
    .{ "F6", .f6 },
    .{ "F7", .f7 },
    .{ "F8", .f8 },
    .{ "F9", .f9 },
    .{ "F10", .f10 },
    .{ "F11", .f11 },
    .{ "F12", .f12 },
});

const keys_by_code: std.StaticStringMap(zui.Key) = .initComptime(.{
    .{ "Digit0", .digit_0 },
    .{ "Digit1", .digit_1 },
    .{ "Digit2", .digit_2 },
    .{ "Digit3", .digit_3 },
    .{ "Digit4", .digit_4 },
    .{ "Digit5", .digit_5 },
    .{ "Digit6", .digit_6 },
    .{ "Digit7", .digit_7 },
    .{ "Digit8", .digit_8 },
    .{ "Digit9", .digit_9 },
    .{ "Numpad0", .digit_0 },
    .{ "Numpad1", .digit_1 },
    .{ "Numpad2", .digit_2 },
    .{ "Numpad3", .digit_3 },
    .{ "Numpad4", .digit_4 },
    .{ "Numpad5", .digit_5 },
    .{ "Numpad6", .digit_6 },
    .{ "Numpad7", .digit_7 },
    .{ "Numpad8", .digit_8 },
    .{ "Numpad9", .digit_9 },
    .{ "Minus", .minus },
    .{ "Equal", .equals },
    .{ "BracketLeft", .left_bracket },
    .{ "BracketRight", .right_bracket },
    .{ "Backslash", .backslash },
    .{ "Semicolon", .semicolon },
    .{ "Quote", .apostrophe },
    .{ "Backquote", .grave },
    .{ "Comma", .comma },
    .{ "Period", .period },
    .{ "Slash", .slash },
});

/// The CSS `cursor` for each `zui.Cursor`.
pub fn cursorName(cursor: zui.Cursor) [:0]const u8 {
    return switch (cursor) {
        .default => "default",
        .pointer => "pointer",
        .text => "text",
        .crosshair => "crosshair",
        .move => "move",
        .grab => "grab",
        .grabbing => "grabbing",
        .not_allowed => "not-allowed",
        .wait => "wait",
        .progress => "progress",
        .help => "help",
        .resize_horizontal => "ew-resize",
        .resize_vertical => "ns-resize",
        .resize_nwse => "nwse-resize",
        .resize_nesw => "nesw-resize",
    };
}

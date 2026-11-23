const std = @import("std");
const zui = @import("zui");
const xkb = @import("xkb.zig");
const keys = @import("keys.zig");

/// The logical key at an evdev code: the keysym at its first level in
/// `keymap`, or its US place where that names no key or there is no
/// keymap.
pub fn keyOf(keymap: ?*xkb.Keymap, state: ?*xkb.State, evdev_code: u32) zui.Key {
    const loaded = keymap orelse return keys.keyFromEvdev(evdev_code);
    const keycode = evdev_code + xkb.evdev_offset;
    var symbols: ?[*]const xkb.Keysym = null;
    const layout = if (state) |key_state| xkb.xkb_state_key_get_layout(key_state, keycode) else 0;
    const count = xkb.xkb_keymap_key_get_syms_by_level(loaded, keycode, layout, 0, &symbols);
    if (count > 0) {
        const key = keys.keyFromKeysym(symbols.?[0]);
        if (key != .unidentified) return key;
    }
    return keys.keyFromEvdev(evdev_code);
}

/// Shift, Control, Alt and Super as `state` has them in effect.
pub fn modifiersOf(state: *xkb.State) zui.Modifiers {
    return .{ .shift = isActive(state, "Shift"), .control = isActive(state, "Control"), .alt = isActive(state, "Mod1"), .super = isActive(state, "Mod4") };
}

fn isActive(state: *xkb.State, name: [*:0]const u8) bool {
    return xkb.xkb_state_mod_name_is_active(state, name, xkb.state_mods_effective) > 0;
}

/// The text a press of `evdev_code` types, written into `buffer`, or
/// null. Shortcuts type nothing: Ctrl, Alt and Super keep their letters
/// to themselves, and control characters are keys.
pub fn typedText(state: *xkb.State, modifiers: zui.Modifiers, evdev_code: u32, buffer: *[64]u8) ?[]const u8 {
    if (modifiers.control or modifiers.alt or modifiers.super) return null;
    return plainText(state, evdev_code, buffer);
}

/// `typedText` through the compose sequences of `compose`: a key that
/// starts or continues a sequence types nothing, the key that ends one
/// types what it composes, and one that cancels it types nothing. A
/// repeat types as it would without compose.
pub fn composedText(state: *xkb.State, compose: *Compose, modifiers: zui.Modifiers, evdev_code: u32, repeat: bool, buffer: *[64]u8) ?[]const u8 {
    const press: PressedKey = .read(state, modifiers, evdev_code, repeat);
    return press.composedText(compose, buffer);
}

/// What a press would type, read from the keyboard's state as the key
/// went down, so it can be typed later, as when an input method answers
/// for it, through the compose sequences as they stand then.
pub const PressedKey = struct {
    keysym: xkb.Keysym,
    repeat: bool,
    is_shortcut: bool,
    plain_text: [64]u8 = undefined,
    plain_text_len: u8 = 0,

    pub fn read(state: *xkb.State, modifiers: zui.Modifiers, evdev_code: u32, repeat: bool) PressedKey {
        var press: PressedKey = .{
            .keysym = xkb.xkb_state_key_get_one_sym(state, evdev_code + xkb.evdev_offset),
            .repeat = repeat,
            .is_shortcut = modifiers.control or modifiers.alt or modifiers.super,
        };
        if (plainText(state, evdev_code, &press.plain_text)) |typed| press.plain_text_len = @intCast(typed.len);
        return press;
    }

    fn plain(self: *const PressedKey, buffer: *[64]u8) ?[]const u8 {
        if (self.plain_text_len == 0) return null;
        @memcpy(buffer[0..self.plain_text_len], self.plain_text[0..self.plain_text_len]);
        return buffer[0..self.plain_text_len];
    }

    /// Feeds `compose`, as `composedText` does, and returns what the press
    /// types, written into `buffer`.
    pub fn composedText(self: *const PressedKey, compose: *Compose, buffer: *[64]u8) ?[]const u8 {
        if (self.is_shortcut) return null;
        const sequences = compose.state orelse return self.plain(buffer);
        if (self.repeat) return self.plain(buffer);
        if (xkb.xkb_compose_state_feed(sequences, self.keysym) != .accepted) return self.plain(buffer);
        switch (xkb.xkb_compose_state_get_status(sequences)) {
            .composing => return null,
            .composed => {
                defer xkb.xkb_compose_state_reset(sequences);
                const len = xkb.xkb_compose_state_get_utf8(sequences, buffer, buffer.len);
                if (len <= 0 or len >= buffer.len) return null;
                return buffer[0..@intCast(len)];
            },
            .cancelled => {
                xkb.xkb_compose_state_reset(sequences);
                return null;
            },
            else => return self.plain(buffer),
        }
    }
};

/// The text `keysym` stands for, as an input method's forwarded key names
/// it, written into `buffer`: none for a control character or a key that
/// types nothing.
pub fn textOfKeysym(keysym: xkb.Keysym, buffer: *[64]u8) ?[]const u8 {
    const len = xkb.xkb_keysym_to_utf8(keysym, buffer, buffer.len);
    // The length counts the 0 byte it writes after the text.
    if (len <= 1) return null;
    const typed = buffer[0..@intCast(len - 1)];
    if (typed.len == 1 and (typed[0] < 0x20 or typed[0] == 0x7F)) return null;
    return typed;
}

fn plainText(state: *xkb.State, evdev_code: u32, buffer: *[64]u8) ?[]const u8 {
    const len = xkb.xkb_state_key_get_utf8(state, evdev_code + xkb.evdev_offset, buffer, buffer.len);
    if (len <= 0 or len >= buffer.len) return null;
    const typed = buffer[0..@intCast(len)];
    if (typed.len == 1 and (typed[0] < 0x20 or typed[0] == 0x7F)) return null;
    return typed;
}

/// The compose sequences a keyboard types through, such as a dead acute
/// then `e` for "é", or `Multi_key` `o` `c` for "©". Without a table,
/// keys type as they would without compose.
pub const Compose = struct {
    table: ?*xkb.ComposeTable = null,
    state: ?*xkb.ComposeState = null,

    /// The table of the locale `LC_ALL`, `LC_CTYPE` or `LANG` names, in
    /// that order, or of "C".
    pub fn fromLocale(context: *xkb.Context) Compose {
        const locale = std.c.getenv("LC_ALL") orelse std.c.getenv("LC_CTYPE") orelse std.c.getenv("LANG") orelse "C";
        return .of(xkb.xkb_compose_table_new_from_locale(context, locale, 0));
    }

    /// A table compiled from Compose-file text, for tests that must not
    /// depend on the machine's locale.
    ///
    /// ```zig
    /// host.compose.deinit();
    /// host.compose = .fromText(host.xkb_context, "<dead_acute> <e> : \"\u{e9}\"\n");
    /// ```
    pub fn fromText(context: *xkb.Context, text: []const u8) Compose {
        return .of(xkb.xkb_compose_table_new_from_buffer(context, text.ptr, text.len, "C", xkb.compose_format_text_v1, 0));
    }

    fn of(table: ?*xkb.ComposeTable) Compose {
        const compiled = table orelse return .{};
        const state = xkb.xkb_compose_state_new(compiled, 0) orelse {
            xkb.xkb_compose_table_unref(compiled);
            return .{};
        };
        return .{ .table = compiled, .state = state };
    }

    pub fn deinit(self: *Compose) void {
        if (self.state) |state| xkb.xkb_compose_state_unref(state);
        if (self.table) |table| xkb.xkb_compose_table_unref(table);
        self.* = .{};
    }

    /// Forgets a sequence in progress, as when the keyboard's focus leaves.
    pub fn reset(self: *Compose) void {
        if (self.state) |state| xkb.xkb_compose_state_reset(state);
    }
};

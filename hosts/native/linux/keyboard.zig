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
    const len = xkb.xkb_state_key_get_utf8(state, evdev_code + xkb.evdev_offset, buffer, buffer.len);
    if (len <= 0 or len >= buffer.len) return null;
    const typed = buffer[0..@intCast(len)];
    if (typed.len == 1 and (typed[0] < 0x20 or typed[0] == 0x7F)) return null;
    return typed;
}

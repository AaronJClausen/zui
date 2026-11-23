//! The parts of libxkbcommon the Linux host uses: a compositor sends its
//! keymap as XKB text, and xkbcommon turns key codes into symbols and text.

pub const Context = opaque {};
pub const Keymap = opaque {};
pub const State = opaque {};
pub const Keysym = u32;

pub const keymap_format_text_v1 = 1;
pub const state_mods_effective = 1 << 3;
/// An evdev code plus this is the XKB key code.
pub const evdev_offset = 8;

pub const RuleNames = extern struct {
    rules: ?[*:0]const u8 = null,
    model: ?[*:0]const u8 = null,
    layout: ?[*:0]const u8 = null,
    variant: ?[*:0]const u8 = null,
    options: ?[*:0]const u8 = null,
};

pub extern "xkbcommon" fn xkb_context_new(flags: c_int) callconv(.c) ?*Context;
pub extern "xkbcommon" fn xkb_context_unref(context: *Context) callconv(.c) void;
pub extern "xkbcommon" fn xkb_keymap_new_from_string(context: *Context, string: [*:0]const u8, format: c_int, flags: c_int) callconv(.c) ?*Keymap;
pub extern "xkbcommon" fn xkb_keymap_new_from_names(context: *Context, names: ?*const RuleNames, flags: c_int) callconv(.c) ?*Keymap;
pub extern "xkbcommon" fn xkb_keymap_unref(keymap: *Keymap) callconv(.c) void;
pub extern "xkbcommon" fn xkb_keymap_key_repeats(keymap: *Keymap, key: u32) callconv(.c) c_int;
pub extern "xkbcommon" fn xkb_keymap_key_get_syms_by_level(keymap: *Keymap, key: u32, layout: u32, level: u32, syms: *?[*]const Keysym) callconv(.c) c_int;
pub extern "xkbcommon" fn xkb_state_new(keymap: *Keymap) callconv(.c) ?*State;
pub extern "xkbcommon" fn xkb_state_unref(state: *State) callconv(.c) void;
pub extern "xkbcommon" fn xkb_state_update_mask(state: *State, depressed: u32, latched: u32, locked: u32, depressed_layout: u32, latched_layout: u32, locked_layout: u32) callconv(.c) c_int;
pub extern "xkbcommon" fn xkb_state_key_get_layout(state: *State, key: u32) callconv(.c) u32;
pub extern "xkbcommon" fn xkb_state_key_get_utf8(state: *State, key: u32, buffer: ?[*]u8, size: usize) callconv(.c) c_int;
pub extern "xkbcommon" fn xkb_state_mod_name_is_active(state: *State, name: [*:0]const u8, kind: c_int) callconv(.c) c_int;
pub extern "xkbcommon" fn xkb_state_key_get_one_sym(state: *State, key: u32) callconv(.c) Keysym;
pub extern "xkbcommon" fn xkb_state_serialize_mods(state: *State, components: c_int) callconv(.c) u32;
pub extern "xkbcommon" fn xkb_keysym_to_utf8(keysym: Keysym, buffer: [*]u8, size: usize) callconv(.c) c_int;

pub const ComposeTable = opaque {};
pub const ComposeState = opaque {};
pub const compose_format_text_v1 = 1;

pub const ComposeStatus = enum(c_int) { nothing, composing, composed, cancelled, _ };
pub const ComposeFeedResult = enum(c_int) { ignored, accepted, _ };

pub extern "xkbcommon" fn xkb_compose_table_new_from_locale(context: *Context, locale: [*:0]const u8, flags: c_int) callconv(.c) ?*ComposeTable;
pub extern "xkbcommon" fn xkb_compose_table_new_from_buffer(context: *Context, buffer: [*]const u8, length: usize, locale: [*:0]const u8, format: c_int, flags: c_int) callconv(.c) ?*ComposeTable;
pub extern "xkbcommon" fn xkb_compose_table_unref(table: *ComposeTable) callconv(.c) void;
pub extern "xkbcommon" fn xkb_compose_state_new(table: *ComposeTable, flags: c_int) callconv(.c) ?*ComposeState;
pub extern "xkbcommon" fn xkb_compose_state_unref(state: *ComposeState) callconv(.c) void;
pub extern "xkbcommon" fn xkb_compose_state_feed(state: *ComposeState, keysym: Keysym) callconv(.c) ComposeFeedResult;
pub extern "xkbcommon" fn xkb_compose_state_reset(state: *ComposeState) callconv(.c) void;
pub extern "xkbcommon" fn xkb_compose_state_get_status(state: *ComposeState) callconv(.c) ComposeStatus;
pub extern "xkbcommon" fn xkb_compose_state_get_utf8(state: *ComposeState, buffer: ?[*]u8, size: usize) callconv(.c) c_int;

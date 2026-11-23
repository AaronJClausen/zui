//! The parts of libX11, libxcb, its XKB extension, xcb-cursor and
//! xkbcommon-x11 the X11 host uses. The display is opened through Xlib,
//! since EGL's X11 platform takes an Xlib `Display`, and spoken to through
//! the xcb connection beneath it, which owns its event queue.

const std = @import("std");
const xkb = @import("xkb.zig");

pub const Display = opaque {};
pub const Connection = opaque {};
pub const CursorContext = opaque {};
pub const Window = u32;
pub const Atom = u32;

pub const VoidCookie = extern struct { sequence: c_uint };
pub const InternAtomCookie = extern struct { sequence: c_uint };
pub const GetPropertyCookie = extern struct { sequence: c_uint };
pub const PerClientFlagsCookie = extern struct { sequence: c_uint };
pub const GetSelectionOwnerCookie = extern struct { sequence: c_uint };
pub const TranslateCoordinatesCookie = extern struct { sequence: c_uint };

pub const Screen = extern struct {
    root: Window,
    default_colormap: u32,
    white_pixel: u32,
    black_pixel: u32,
    current_input_masks: u32,
    width_in_pixels: u16,
    height_in_pixels: u16,
    width_in_millimeters: u16,
    height_in_millimeters: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,
    root_visual: u32,
    backing_stores: u8,
    save_unders: u8,
    root_depth: u8,
    allowed_depths_len: u8,
};

pub const ScreenIterator = extern struct { data: ?*Screen, rem: c_int, index: c_int };
pub const Setup = opaque {};

pub const GenericError = extern struct {
    response_type: u8,
    error_code: u8,
    sequence: u16,
    resource_id: u32,
    minor_code: u16,
    major_code: u8,
    pad0: u8,
    pad: [5]u32,
    full_sequence: u32,
};

pub const GenericEvent = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    pad: [7]u32,
    full_sequence: u32,

    /// The event's code, without the bit that marks one another client sent.
    pub fn code(self: *const GenericEvent) u8 {
        return self.response_type & 0x7f;
    }
};

/// KeyPress, KeyRelease, ButtonPress, ButtonRelease and MotionNotify.
pub const InputEvent = extern struct {
    response_type: u8,
    detail: u8,
    sequence: u16,
    time: u32,
    root: Window,
    event: Window,
    child: Window,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16,
    same_screen: u8,
    pad0: u8,
};

/// EnterNotify and LeaveNotify.
pub const CrossingEvent = extern struct {
    response_type: u8,
    detail: u8,
    sequence: u16,
    time: u32,
    root: Window,
    event: Window,
    child: Window,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16,
    mode: u8,
    same_screen_focus: u8,
};

/// FocusIn and FocusOut.
pub const FocusEvent = extern struct {
    response_type: u8,
    detail: u8,
    sequence: u16,
    event: Window,
    mode: u8,
    pad0: [3]u8,
};

pub const ConfigureNotifyEvent = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    event: Window,
    window: Window,
    above_sibling: Window,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    override_redirect: u8,
    pad1: u8,
};

pub const ClientMessageEvent = extern struct {
    response_type: u8,
    format: u8,
    sequence: u16,
    window: Window,
    type: Atom,
    data32: [5]u32,
};

pub const PropertyNotifyEvent = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    window: Window,
    atom: Atom,
    time: u32,
    state: u8,
    pad1: [3]u8,
};

pub const SelectionClearEvent = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    time: u32,
    owner: Window,
    selection: Atom,
};

pub const SelectionRequestEvent = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    time: u32,
    owner: Window,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
};

pub const SelectionNotifyEvent = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    time: u32,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
};

/// Every XKB event shares these first bytes; `xkb_type` tells them apart.
pub const XkbEventHeader = extern struct {
    response_type: u8,
    xkb_type: u8,
    sequence: u16,
    time: u32,
    device_id: u8,
};

pub const XkbStateNotifyEvent = extern struct {
    response_type: u8,
    xkb_type: u8,
    sequence: u16,
    time: u32,
    device_id: u8,
    mods: u8,
    base_mods: u8,
    latched_mods: u8,
    locked_mods: u8,
    group: u8,
    base_group: i16,
    latched_group: i16,
    locked_group: u8,
    compat_state: u8,
    grab_mods: u8,
    compat_grab_mods: u8,
    lookup_mods: u8,
    compat_lookup_mods: u8,
    pointer_button_state: u16,
    changed: u16,
    keycode: u8,
    event_type: u8,
    request_major: u8,
    request_minor: u8,
};

pub const InternAtomReply = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    atom: Atom,
};

pub const GetPropertyReply = extern struct {
    response_type: u8,
    format: u8,
    sequence: u16,
    length: u32,
    type: Atom,
    bytes_after: u32,
    value_len: u32,
    pad0: [12]u8,
};

pub const GetSelectionOwnerReply = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    owner: Window,
};

pub const TranslateCoordinatesReply = extern struct {
    response_type: u8,
    same_screen: u8,
    sequence: u16,
    length: u32,
    child: Window,
    dst_x: i16,
    dst_y: i16,
};

pub const PerClientFlagsReply = extern struct {
    response_type: u8,
    device_id: u8,
    sequence: u16,
    length: u32,
    supported: u32,
    value: u32,
    auto_controls: u32,
    auto_controls_values: u32,
    pad0: [8]u8,
};

pub const XkbSelectEventsDetails = extern struct {
    affect_new_keyboard: u16 = 0,
    new_keyboard_details: u16 = 0,
    affect_state: u16 = 0,
    state_details: u16 = 0,
    affect_controls: u32 = 0,
    control_details: u32 = 0,
    affect_indicator_state: u32 = 0,
    indicator_state_details: u32 = 0,
    affect_indicator_map: u32 = 0,
    indicator_map_details: u32 = 0,
    affect_names: u16 = 0,
    names_details: u16 = 0,
    affect_compat: u8 = 0,
    compat_details: u8 = 0,
    affect_bell: u8 = 0,
    bell_details: u8 = 0,
    affect_message_details: u8 = 0,
    message_details: u8 = 0,
    affect_access_x: u16 = 0,
    access_x_details: u16 = 0,
    affect_extension_device: u16 = 0,
    extension_device_details: u16 = 0,
};

/// One of `WM_NORMAL_HINTS`' 18 words, in order.
pub const SizeHints = extern struct {
    flags: u32 = 0,
    unused_position_and_size: [4]i32 = @splat(0),
    min_width: i32 = 0,
    min_height: i32 = 0,
    max_width: i32 = 0,
    max_height: i32 = 0,
    width_increment: i32 = 0,
    height_increment: i32 = 0,
    min_aspect: [2]i32 = @splat(0),
    max_aspect: [2]i32 = @splat(0),
    base_width: i32 = 0,
    base_height: i32 = 0,
    window_gravity: i32 = 0,

    pub const program_min_size = 1 << 4;
    pub const program_max_size = 1 << 5;
};

pub const key_press = 2;
pub const key_release = 3;
pub const button_press = 4;
pub const button_release = 5;
pub const motion_notify = 6;
pub const enter_notify = 7;
pub const leave_notify = 8;
pub const focus_in = 9;
pub const focus_out = 10;
pub const expose = 12;
pub const configure_notify = 22;
pub const property_notify = 28;
pub const selection_clear = 29;
pub const selection_request = 30;
pub const selection_notify = 31;
pub const client_message = 33;

pub const property_new_value = 0;
pub const current_time = 0;
pub const atom_none = 0;

pub const notify_mode_grab = 1;
pub const notify_mode_ungrab = 2;

pub const event_mask_key_press = 1;
pub const event_mask_key_release = 2;
pub const event_mask_button_press = 4;
pub const event_mask_button_release = 8;
pub const event_mask_enter_window = 16;
pub const event_mask_leave_window = 32;
pub const event_mask_pointer_motion = 64;
pub const event_mask_exposure = 32768;
pub const event_mask_structure_notify = 131072;
pub const event_mask_substructure_notify = 524288;
pub const event_mask_substructure_redirect = 1048576;
pub const event_mask_focus_change = 2097152;
pub const event_mask_property_change = 4194304;

pub const configure_width = 4;
pub const configure_height = 8;

pub const window_attribute_event_mask = 2048;
pub const window_attribute_cursor = 16384;
pub const window_class_input_output = 1;
pub const copy_from_parent = 0;
pub const property_mode_replace = 0;
pub const any_property_type = 0;

pub const atom_atom = 4;
pub const atom_cardinal = 6;
pub const atom_resource_manager = 23;
pub const atom_string = 31;
pub const atom_wm_name = 39;
pub const atom_wm_normal_hints = 40;
pub const atom_wm_size_hints = 41;
pub const atom_wm_class = 67;

pub const xkb_use_core_keyboard = 0x100;
pub const xkb_new_keyboard_notify = 0;
pub const xkb_map_notify = 1;
pub const xkb_state_notify = 2;
pub const xkb_event_type_new_keyboard_notify = 1;
pub const xkb_event_type_map_notify = 2;
pub const xkb_event_type_state_notify = 4;
pub const xkb_new_keyboard_detail_keycodes = 1;
pub const xkb_map_parts = 1 | 2 | 4 | 8 | 16 | 64 | 128;
/// The base, latched and locked modifiers and groups.
pub const xkb_state_parts = 2 | 4 | 8 | 32 | 64 | 128;
pub const xkb_per_client_flag_detectable_auto_repeat = 1;

pub const xkb_x11_min_major_version = 1;
pub const xkb_x11_min_minor_version = 0;

pub const xcb_owns_event_queue = 1;

pub extern "X11" fn XOpenDisplay(name: ?[*:0]const u8) callconv(.c) ?*Display;
pub extern "X11" fn XCloseDisplay(display: *Display) callconv(.c) c_int;
pub extern "X11" fn XDefaultScreen(display: *Display) callconv(.c) c_int;
pub extern "X11-xcb" fn XGetXCBConnection(display: *Display) callconv(.c) ?*Connection;
pub extern "X11-xcb" fn XSetEventQueueOwner(display: *Display, owner: c_int) callconv(.c) void;

pub extern "xcb" fn xcb_get_setup(connection: *Connection) callconv(.c) *const Setup;
pub extern "xcb" fn xcb_setup_roots_iterator(setup: *const Setup) callconv(.c) ScreenIterator;
pub extern "xcb" fn xcb_screen_next(iterator: *ScreenIterator) callconv(.c) void;
pub extern "xcb" fn xcb_generate_id(connection: *Connection) callconv(.c) u32;
pub extern "xcb" fn xcb_create_window(connection: *Connection, depth: u8, window: Window, parent: Window, x: i16, y: i16, width: u16, height: u16, border_width: u16, class: u16, visual: u32, value_mask: u32, values: ?*const anyopaque) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_destroy_window(connection: *Connection, window: Window) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_map_window(connection: *Connection, window: Window) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_configure_window(connection: *Connection, window: Window, value_mask: u16, values: ?*const anyopaque) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_change_window_attributes(connection: *Connection, window: Window, value_mask: u32, values: ?*const anyopaque) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_change_window_attributes_checked(connection: *Connection, window: Window, value_mask: u32, values: ?*const anyopaque) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_request_check(connection: *Connection, cookie: VoidCookie) callconv(.c) ?*GenericError;
pub extern "xcb" fn xcb_ungrab_pointer(connection: *Connection, time: u32) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_change_property(connection: *Connection, mode: u8, window: Window, property: Atom, type: Atom, format: u8, data_len: u32, data: ?*const anyopaque) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_intern_atom(connection: *Connection, only_if_exists: u8, name_len: u16, name: [*]const u8) callconv(.c) InternAtomCookie;
pub extern "xcb" fn xcb_intern_atom_reply(connection: *Connection, cookie: InternAtomCookie, err: ?*?*GenericError) callconv(.c) ?*InternAtomReply;
pub extern "xcb" fn xcb_get_property(connection: *Connection, delete: u8, window: Window, property: Atom, type: Atom, long_offset: u32, long_length: u32) callconv(.c) GetPropertyCookie;
pub extern "xcb" fn xcb_get_property_reply(connection: *Connection, cookie: GetPropertyCookie, err: ?*?*GenericError) callconv(.c) ?*GetPropertyReply;
pub extern "xcb" fn xcb_get_property_value(reply: *const GetPropertyReply) callconv(.c) ?[*]const u8;
pub extern "xcb" fn xcb_get_property_value_length(reply: *const GetPropertyReply) callconv(.c) c_int;
pub extern "xcb" fn xcb_delete_property(connection: *Connection, window: Window, property: Atom) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_set_selection_owner(connection: *Connection, owner: Window, selection: Atom, time: u32) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_get_selection_owner(connection: *Connection, selection: Atom) callconv(.c) GetSelectionOwnerCookie;
pub extern "xcb" fn xcb_get_selection_owner_reply(connection: *Connection, cookie: GetSelectionOwnerCookie, err: ?*?*GenericError) callconv(.c) ?*GetSelectionOwnerReply;
pub extern "xcb" fn xcb_convert_selection(connection: *Connection, requestor: Window, selection: Atom, target: Atom, property: Atom, time: u32) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_send_event(connection: *Connection, propagate: u8, destination: Window, event_mask: u32, event: *const [32]u8) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_translate_coordinates(connection: *Connection, source: Window, destination: Window, x: i16, y: i16) callconv(.c) TranslateCoordinatesCookie;
pub extern "xcb" fn xcb_translate_coordinates_reply(connection: *Connection, cookie: TranslateCoordinatesCookie, err: ?*?*GenericError) callconv(.c) ?*TranslateCoordinatesReply;
pub extern "xcb" fn xcb_free_cursor(connection: *Connection, cursor: u32) callconv(.c) VoidCookie;
pub extern "xcb" fn xcb_flush(connection: *Connection) callconv(.c) c_int;
pub extern "xcb" fn xcb_poll_for_event(connection: *Connection) callconv(.c) ?*GenericEvent;
pub extern "xcb" fn xcb_get_file_descriptor(connection: *Connection) callconv(.c) c_int;
pub extern "xcb" fn xcb_connection_has_error(connection: *Connection) callconv(.c) c_int;

pub extern "xcb-xkb" fn xcb_xkb_per_client_flags(connection: *Connection, device_spec: u16, change: u32, value: u32, controls_to_change: u32, auto_controls: u32, auto_controls_values: u32) callconv(.c) PerClientFlagsCookie;
pub extern "xcb-xkb" fn xcb_xkb_per_client_flags_reply(connection: *Connection, cookie: PerClientFlagsCookie, err: ?*?*GenericError) callconv(.c) ?*PerClientFlagsReply;
pub extern "xcb-xkb" fn xcb_xkb_select_events_aux(connection: *Connection, device_spec: u16, affect_which: u16, clear: u16, select_all: u16, affect_map: u16, map: u16, details: *const XkbSelectEventsDetails) callconv(.c) VoidCookie;

pub extern "xcb-cursor" fn xcb_cursor_context_new(connection: *Connection, screen: *Screen, context: *?*CursorContext) callconv(.c) c_int;
pub extern "xcb-cursor" fn xcb_cursor_load_cursor(context: *CursorContext, name: [*:0]const u8) callconv(.c) u32;
pub extern "xcb-cursor" fn xcb_cursor_context_free(context: *CursorContext) callconv(.c) void;

pub extern "xkbcommon-x11" fn xkb_x11_setup_xkb_extension(connection: *Connection, major_version: u16, minor_version: u16, flags: c_int, major_version_out: ?*u16, minor_version_out: ?*u16, base_event_out: ?*u8, base_error_out: ?*u8) callconv(.c) c_int;
pub extern "xkbcommon-x11" fn xkb_x11_get_core_keyboard_device_id(connection: *Connection) callconv(.c) i32;
pub extern "xkbcommon-x11" fn xkb_x11_keymap_new_from_device(context: *xkb.Context, connection: *Connection, device_id: i32, flags: c_int) callconv(.c) ?*xkb.Keymap;
pub extern "xkbcommon-x11" fn xkb_x11_state_new_from_device(keymap: *xkb.Keymap, connection: *Connection, device_id: i32) callconv(.c) ?*xkb.State;

pub extern "c" fn free(pointer: ?*anyopaque) callconv(.c) void;

/// The atoms the X11 host names, each 0 when the server did not answer.
pub const Atoms = struct {
    wm_protocols: Atom = 0,
    wm_delete_window: Atom = 0,
    net_wm_name: Atom = 0,
    utf8_string: Atom = 0,
    clipboard: Atom = 0,
    targets: Atom = 0,
    text: Atom = 0,
    text_plain_utf8: Atom = 0,
    incr: Atom = 0,
    /// The host's window's property a clipboard's owner writes into.
    clipboard_property: Atom = 0,
    /// The host's window's property a drop's source writes into.
    drop_property: Atom = 0,
    uri_list: Atom = 0,
    xdnd_aware: Atom = 0,
    xdnd_enter: Atom = 0,
    xdnd_position: Atom = 0,
    xdnd_status: Atom = 0,
    xdnd_leave: Atom = 0,
    xdnd_drop: Atom = 0,
    xdnd_finished: Atom = 0,
    xdnd_selection: Atom = 0,
    xdnd_type_list: Atom = 0,
    xdnd_action_copy: Atom = 0,
    wm_change_state: Atom = 0,
    motif_wm_hints: Atom = 0,
    net_supported: Atom = 0,
    net_wm_moveresize: Atom = 0,
    net_wm_state: Atom = 0,
    net_wm_state_maximized_vert: Atom = 0,
    net_wm_state_maximized_horz: Atom = 0,
    net_frame_extents: Atom = 0,
    gtk_show_window_menu: Atom = 0,

    const names: [std.meta.fields(Atoms).len][]const u8 = .{
        "WM_PROTOCOLS",   "WM_DELETE_WINDOW",   "_NET_WM_NAME",  "UTF8_STRING",                  "CLIPBOARD",                    "TARGETS",            "TEXT",                  "text/plain;charset=utf-8",
        "INCR",           "ZUI_CLIPBOARD",      "ZUI_DROP",      "text/uri-list",                "XdndAware",                    "XdndEnter",          "XdndPosition",          "XdndStatus",
        "XdndLeave",      "XdndDrop",           "XdndFinished",  "XdndSelection",                "XdndTypeList",                 "XdndActionCopy",     "WM_CHANGE_STATE",       "_MOTIF_WM_HINTS",
        "_NET_SUPPORTED", "_NET_WM_MOVERESIZE", "_NET_WM_STATE", "_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ", "_NET_FRAME_EXTENTS", "_GTK_SHOW_WINDOW_MENU",
    };

    /// Asks for every atom at once, then waits for the answers, so the
    /// round trips overlap.
    pub fn intern(connection: *Connection) Atoms {
        var cookies: [names.len]InternAtomCookie = undefined;
        for (names, &cookies) |name, *cookie| cookie.* = xcb_intern_atom(connection, 0, @intCast(name.len), name.ptr);
        var atoms: Atoms = .{};
        inline for (std.meta.fields(Atoms), cookies) |field, cookie| {
            if (xcb_intern_atom_reply(connection, cookie, null)) |reply| {
                defer free(reply);
                @field(atoms, field.name) = reply.atom;
            }
        }
        return atoms;
    }
};

/// The atom named `name`, made if the server has none yet; 0 when the
/// server does not answer.
pub fn internAtom(connection: *Connection, name: []const u8) Atom {
    const reply = xcb_intern_atom_reply(connection, xcb_intern_atom(connection, 0, @intCast(name.len), name.ptr), null) orelse return 0;
    defer free(reply);
    return reply.atom;
}

/// Sends a 32-bit client message of `message_type` to `destination`.
pub fn sendClientMessage(connection: *Connection, destination: Window, message_type: Atom, data: [5]u32) void {
    const message: ClientMessageEvent = .{ .response_type = client_message, .format = 32, .sequence = 0, .window = destination, .type = message_type, .data32 = data };
    _ = xcb_send_event(connection, 0, destination, 0, @ptrCast(&message));
}

/// Sends a 32-bit client message about `window` to the window manager,
/// which takes it from the root as a client that redirects its children's
/// requests.
pub fn sendToWindowManager(connection: *Connection, root: Window, window: Window, message_type: Atom, data: [5]u32) void {
    const message: ClientMessageEvent = .{ .response_type = client_message, .format = 32, .sequence = 0, .window = window, .type = message_type, .data32 = data };
    _ = xcb_send_event(connection, 0, root, event_mask_substructure_notify | event_mask_substructure_redirect, @ptrCast(&message));
}

/// The 32-bit values of `window`'s `property`, up to `values.len` of
/// them: none when it is unset or of another format.
pub fn readCardinals(connection: *Connection, window: Window, property: Atom, values: []u32) []const u32 {
    const cookie = xcb_get_property(connection, 0, window, property, any_property_type, 0, @intCast(values.len));
    const reply = xcb_get_property_reply(connection, cookie, null) orelse return values[0..0];
    defer free(reply);
    if (reply.format != 32) return values[0..0];
    const count = @min(reply.value_len, values.len);
    const bytes = xcb_get_property_value(reply) orelse return values[0..0];
    @memcpy(std.mem.sliceAsBytes(values[0..count]), bytes[0 .. count * 4]);
    return values[0..count];
}

/// The screen numbered `number`, or the first.
pub fn screenOf(connection: *Connection, number: c_int) ?*Screen {
    var iterator = xcb_setup_roots_iterator(xcb_get_setup(connection));
    const first = iterator.data;
    var index: c_int = 0;
    while (iterator.rem > 0) : (index += 1) {
        if (index == number) return iterator.data;
        xcb_screen_next(&iterator);
    }
    return first;
}

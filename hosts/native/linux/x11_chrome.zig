const std = @import("std");
const zui = @import("zui");
const x11 = @import("x11.zig");
const chrome = @import("chrome.zig");

/// What the window manager offers a custom title bar, as the root
/// window's `_NET_SUPPORTED` lists it.
pub const WindowManagerSupport = struct {
    /// `_NET_WM_MOVERESIZE`, without which the window could not be moved
    /// or resized from its own title bar.
    move_resize: bool = false,
    /// `_GTK_SHOW_WINDOW_MENU`.
    window_menu: bool = false,

    /// From the atoms `_NET_SUPPORTED` holds.
    pub fn of(supported: []const x11.Atom, atoms: *const x11.Atoms) WindowManagerSupport {
        return .{
            .move_resize = atoms.net_wm_moveresize != 0 and std.mem.indexOfScalar(x11.Atom, supported, atoms.net_wm_moveresize) != null,
            .window_menu = atoms.gtk_show_window_menu != 0 and std.mem.indexOfScalar(x11.Atom, supported, atoms.gtk_show_window_menu) != null,
        };
    }

    /// The most atoms of `_NET_SUPPORTED` read.
    pub const supported_capacity = 1024;
};

/// `_NET_WM_MOVERESIZE`'s directions: the edges and corners clockwise from
/// the top-left, then a move.
pub const MoveResizeDirection = enum(u32) {
    size_top_left = 0,
    size_top = 1,
    size_top_right = 2,
    size_right = 3,
    size_bottom_right = 4,
    size_bottom = 5,
    size_bottom_left = 6,
    size_left = 7,
    move = 8,

    pub fn ofResize(kind: zui.ChromeKind) ?MoveResizeDirection {
        return switch (kind) {
            .resize_top_left => .size_top_left,
            .resize_top => .size_top,
            .resize_top_right => .size_top_right,
            .resize_right => .size_right,
            .resize_bottom_right => .size_bottom_right,
            .resize_bottom => .size_bottom,
            .resize_bottom_left => .size_bottom_left,
            .resize_left => .size_left,
            .title_bar, .minimize_button, .maximize_button, .close_button, .client => null,
        };
    }
};

/// What the host last asked of the window manager for the window's chrome.
pub const WindowManagerRequest = union(enum) {
    /// At the press's root position, with the X button pressed.
    move_resize: struct { direction: MoveResizeDirection, root_position: [2]i32, x_button: u8 },
    /// At the press's root position.
    show_window_menu: [2]i32,
    set_maximized,
    unset_maximized,
    iconify,
};

/// Where the requests go: the window manager, through the root window.
pub const Endpoint = struct {
    connection: *x11.Connection,
    root: x11.Window,
    window: x11.Window,
    atoms: *const x11.Atoms,
};

/// An X11 window's custom title bar: whether the window manager lets the
/// application draw it, the regions of its last frame, the presses on them
/// it handed the window manager, and whether the window is maximized.
pub const WindowChrome = struct {
    /// The window was opened with `title_bar = .custom`.
    asked_for_custom: bool = false,
    resizable: bool = true,
    support: WindowManagerSupport = .{},
    /// `_NET_FRAME_EXTENTS` gives the window a border: the window manager
    /// ignored the Motif hint and draws its own frame.
    window_manager_draws_frame: bool = false,
    snapshot: chrome.ChromeSnapshot = .{},
    presses: chrome.ChromePresses = .{},
    /// Both of `_NET_WM_STATE`'s maximized states are set.
    maximized: bool = false,
    last_request: ?WindowManagerRequest = null,
    requests_sent: u32 = 0,

    pub const Press = enum { reaches_zui, handed_to_window_manager };
    pub const Release = chrome.ChromePresses.Release;

    /// `_MOTIF_WM_HINTS`' words: flags, functions, decorations, input mode
    /// and status, of which only the decorations are given, as none.
    pub const no_decorations_hint: [5]u32 = .{ decorations_flag, 0, 0, 0, 0 };
    const decorations_flag = 1 << 1;

    const iconic_state = 3;
    const source_application = 1;

    const StateAction = enum(u32) { remove = 0, add = 1 };

    /// The application draws the title bar: it asked to, the window
    /// manager moves and resizes windows for it, and it drew no frame of
    /// its own around the window.
    pub fn isCustom(self: *const WindowChrome) bool {
        return self.asked_for_custom and self.support.move_resize and !self.window_manager_draws_frame;
    }

    /// Asks the window manager to draw no decorations, for a window that
    /// asked for a custom title bar. Call before the window is mapped.
    pub fn askForNoDecorations(self: *const WindowChrome, endpoint: Endpoint) void {
        if (!self.asked_for_custom) return;
        const hint = endpoint.atoms.motif_wm_hints;
        _ = x11.xcb_change_property(endpoint.connection, x11.property_mode_replace, endpoint.window, hint, hint, 32, no_decorations_hint.len, &no_decorations_hint);
    }

    /// Returns whether `isCustom` changed.
    pub fn onSupport(self: *WindowChrome, support: WindowManagerSupport) bool {
        const was_custom = self.isCustom();
        self.support = support;
        return self.settle(was_custom);
    }

    /// `extents` are `_NET_FRAME_EXTENTS`' left, right, top and bottom, or
    /// none once it is removed. Returns whether `isCustom` changed.
    pub fn onFrameExtents(self: *WindowChrome, extents: []const u32) bool {
        const was_custom = self.isCustom();
        self.window_manager_draws_frame = std.mem.indexOfNone(u32, extents, &.{0}) != null;
        return self.settle(was_custom);
    }

    /// `states` are the atoms `_NET_WM_STATE` holds. Returns whether the
    /// window's maximized state changed.
    pub fn onWindowState(self: *WindowChrome, states: []const x11.Atom, atoms: *const x11.Atoms) bool {
        const vertically = std.mem.indexOfScalar(x11.Atom, states, atoms.net_wm_state_maximized_vert) != null;
        const horizontally = std.mem.indexOfScalar(x11.Atom, states, atoms.net_wm_state_maximized_horz) != null;
        const maximized = vertically and horizontally;
        if (maximized == self.maximized) return false;
        self.maximized = maximized;
        return true;
    }

    fn settle(self: *WindowChrome, was_custom: bool) bool {
        const custom = self.isCustom();
        if (!custom) {
            self.snapshot.clear();
            self.presses.forget();
        }
        return custom != was_custom;
    }

    pub fn publish(self: *WindowChrome, regions: []const zui.ChromeRegion, pixels_per_unit: f32) void {
        if (!self.isCustom()) return;
        self.snapshot.publish(regions, pixels_per_unit);
    }

    /// What the window manager makes of a point, in the window's physical
    /// pixels: null where it is the application's, as outside any region.
    pub fn kindAt(self: *const WindowChrome, point: [2]f32) ?zui.ChromeKind {
        if (!self.isCustom()) return null;
        return self.snapshot.windowManagerKindAt(self.resizable, point);
    }

    /// See `ChromePresses.press`. A secondary press on the title bar
    /// reaches zui where the window manager has no window menu to show.
    pub fn press(self: *WindowChrome, button: zui.Button, point: [2]f32, root_position: [2]i32, x_button: u8, at: zui.Instant, endpoint: Endpoint) Press {
        const kind = if (button == .secondary and !self.support.window_menu) null else self.kindAt(point);
        const gesture = switch (self.presses.press(button, kind, point, at)) {
            .reaches_zui => return .reaches_zui,
            .handed_to_window_manager => |gesture| gesture,
        };
        switch (gesture) {
            .move => self.request(endpoint, .{ .move_resize = .{ .direction = .move, .root_position = root_position, .x_button = x_button } }),
            .resize => |resize_kind| self.request(endpoint, .{ .move_resize = .{ .direction = MoveResizeDirection.ofResize(resize_kind).?, .root_position = root_position, .x_button = x_button } }),
            .show_window_menu => self.request(endpoint, .{ .show_window_menu = root_position }),
            .toggle_maximized => self.toggleMaximized(endpoint),
        }
        return .handed_to_window_manager;
    }

    pub fn release(self: *WindowChrome, button: zui.Button, point: [2]f32) Release {
        return self.presses.release(button, self.kindAt(point));
    }

    /// Returns whether a caption button's press was cancelled.
    pub fn onPointerLeave(self: *WindowChrome) bool {
        return self.presses.onPointerLeave();
    }

    pub fn onPointerEnter(self: *WindowChrome) void {
        self.presses.onPointerEnter();
    }

    pub fn toggleMaximized(self: *WindowChrome, endpoint: Endpoint) void {
        self.request(endpoint, if (self.maximized) .unset_maximized else .set_maximized);
    }

    pub fn minimize(self: *WindowChrome, endpoint: Endpoint) void {
        self.request(endpoint, .iconify);
    }

    fn request(self: *WindowChrome, endpoint: Endpoint, sent: WindowManagerRequest) void {
        self.last_request = sent;
        self.requests_sent += 1;
        const atoms = endpoint.atoms;
        switch (sent) {
            .move_resize => |move_resize| {
                // The press's implicit grab would keep the pointer from the
                // window manager, which then could not take the drag.
                _ = x11.xcb_ungrab_pointer(endpoint.connection, x11.current_time);
                const root_x: u32 = @bitCast(move_resize.root_position[0]);
                const root_y: u32 = @bitCast(move_resize.root_position[1]);
                send(endpoint, atoms.net_wm_moveresize, .{ root_x, root_y, @intFromEnum(move_resize.direction), move_resize.x_button, source_application });
            },
            .show_window_menu => |root_position| {
                const any_pointer_device = 0;
                send(endpoint, atoms.gtk_show_window_menu, .{ any_pointer_device, @bitCast(root_position[0]), @bitCast(root_position[1]), 0, 0 });
            },
            .set_maximized => sendMaximized(endpoint, .add),
            .unset_maximized => sendMaximized(endpoint, .remove),
            .iconify => send(endpoint, atoms.wm_change_state, .{ iconic_state, 0, 0, 0, 0 }),
        }
    }

    fn sendMaximized(endpoint: Endpoint, action: StateAction) void {
        const atoms = endpoint.atoms;
        send(endpoint, atoms.net_wm_state, .{ @intFromEnum(action), atoms.net_wm_state_maximized_vert, atoms.net_wm_state_maximized_horz, source_application, 0 });
    }

    fn send(endpoint: Endpoint, message_type: x11.Atom, data: [5]u32) void {
        if (message_type == 0) return;
        x11.sendToWindowManager(endpoint.connection, endpoint.root, endpoint.window, message_type, data);
    }
};

const test_atoms: x11.Atoms = .{ .net_wm_moveresize = 10, .gtk_show_window_menu = 11, .net_wm_state_maximized_vert = 20, .net_wm_state_maximized_horz = 21 };

test "the window manager's support is read from the atoms _NET_SUPPORTED lists" {
    try std.testing.expectEqual(WindowManagerSupport{ .move_resize = true, .window_menu = false }, WindowManagerSupport.of(&.{ 3, 10, 4 }, &test_atoms));
    try std.testing.expectEqual(WindowManagerSupport{ .move_resize = true, .window_menu = true }, WindowManagerSupport.of(&.{ 11, 10 }, &test_atoms));
    try std.testing.expectEqual(WindowManagerSupport{}, WindowManagerSupport.of(&.{}, &test_atoms));
    try std.testing.expectEqual(WindowManagerSupport{}, WindowManagerSupport.of(&.{0}, &.{}));
}

test "a custom title bar needs the window manager's moves, and is taken back by a frame it draws" {
    var window_chrome: WindowChrome = .{ .asked_for_custom = true };
    try std.testing.expect(!window_chrome.isCustom());
    try std.testing.expect(window_chrome.onSupport(.{ .move_resize = true }));
    try std.testing.expect(window_chrome.isCustom());
    const title_bar: zui.ChromeRegion = .{ .id = 1, .bounds = .{ .width = 100, .height = 20 }, .kind = .title_bar };
    window_chrome.publish(&.{title_bar}, 1);
    try std.testing.expectEqual(zui.ChromeKind.title_bar, window_chrome.kindAt(.{ 5, 5 }).?);

    try std.testing.expect(!window_chrome.onFrameExtents(&.{ 0, 0, 0, 0 }));
    try std.testing.expect(window_chrome.onFrameExtents(&.{ 1, 1, 24, 1 }));
    try std.testing.expect(!window_chrome.isCustom());
    try std.testing.expectEqual(@as(usize, 0), window_chrome.snapshot.count);
    try std.testing.expect(window_chrome.onFrameExtents(&.{}));
    try std.testing.expect(window_chrome.isCustom());
}

test "the window is maximized while _NET_WM_STATE holds both maximized states" {
    var window_chrome: WindowChrome = .{};
    try std.testing.expect(!window_chrome.onWindowState(&.{20}, &test_atoms));
    try std.testing.expect(window_chrome.onWindowState(&.{ 5, 21, 20 }, &test_atoms));
    try std.testing.expect(window_chrome.maximized);
    try std.testing.expect(!window_chrome.onWindowState(&.{ 20, 21 }, &test_atoms));
    try std.testing.expect(window_chrome.onWindowState(&.{}, &test_atoms));
}

test "each resize kind is the _NET_WM_MOVERESIZE direction of its edge" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(MoveResizeDirection.ofResize(.resize_top_left).?));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(MoveResizeDirection.ofResize(.resize_right).?));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(MoveResizeDirection.ofResize(.resize_left).?));
    try std.testing.expectEqual(@as(?MoveResizeDirection, null), MoveResizeDirection.ofResize(.title_bar));
}

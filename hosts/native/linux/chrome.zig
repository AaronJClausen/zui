const std = @import("std");
const zui = @import("zui");
const wayland = @import("wayland.zig");
const Proxy = wayland.Proxy;

/// The chrome regions of the window's last frame, in surface coordinates,
/// which presses are hit-tested against.
pub const ChromeSnapshot = struct {
    pub const capacity = 256;

    regions: [capacity]SurfaceRegion = undefined,
    count: usize = 0,
    /// Regions the last publish cut from the end, past `capacity`.
    dropped: usize = 0,

    pub const SurfaceRegion = struct {
        left: f32,
        top: f32,
        right: f32,
        bottom: f32,
        kind: zui.ChromeKind,

        fn contains(self: SurfaceRegion, point: [2]f32) bool {
            return point[0] >= self.left and point[0] < self.right and point[1] >= self.top and point[1] < self.bottom;
        }
    };

    /// Copies what fits of `regions`, which are valid only during the call.
    pub fn publish(self: *ChromeSnapshot, regions: []const zui.ChromeRegion, surface_coordinates_per_unit: f32) void {
        const kept = @min(regions.len, capacity);
        for (regions[0..kept], self.regions[0..kept]) |region, *in_surface| {
            const bounds = region.bounds;
            in_surface.* = .{
                .left = bounds.x * surface_coordinates_per_unit,
                .top = bounds.y * surface_coordinates_per_unit,
                .right = (bounds.x + bounds.width) * surface_coordinates_per_unit,
                .bottom = (bounds.y + bounds.height) * surface_coordinates_per_unit,
                .kind = region.kind,
            };
        }
        self.count = kept;
        self.dropped = regions.len - kept;
    }

    /// The kind of the last region holding `point`, in surface
    /// coordinates: the one on top.
    pub fn kindAt(self: *const ChromeSnapshot, point: [2]f32) ?zui.ChromeKind {
        var index = self.count;
        while (index > 0) {
            index -= 1;
            if (self.regions[index].contains(point)) return self.regions[index].kind;
        }
        return null;
    }

    /// What a window manager makes of `point`, in surface coordinates:
    /// null where it is the application's, as outside any region, and on
    /// an edge of a window that is not resizable.
    pub fn windowManagerKindAt(self: *const ChromeSnapshot, resizable: bool, point: [2]f32) ?zui.ChromeKind {
        const kind = self.kindAt(point) orelse return null;
        if (!resizable and isResizeKind(kind)) return null;
        return if (kind == .client) null else kind;
    }

    pub fn clear(self: *ChromeSnapshot) void {
        self.count = 0;
        self.dropped = 0;
    }
};

pub fn isResizeKind(kind: zui.ChromeKind) bool {
    return switch (kind) {
        .resize_top, .resize_bottom, .resize_left, .resize_right, .resize_top_left, .resize_top_right, .resize_bottom_left, .resize_bottom_right => true,
        .title_bar, .minimize_button, .maximize_button, .close_button, .client => false,
    };
}

/// What a press on a custom title bar's chrome asks of the window manager,
/// whichever display server it runs on.
pub const ChromeGesture = union(enum) {
    move,
    /// From the edge or corner this resize kind names.
    resize: zui.ChromeKind,
    /// At the press's point, in surface coordinates.
    show_window_menu: [2]f32,
    toggle_maximized,
};

/// The presses on a custom title bar's chrome, on any display server: which
/// go to the window manager, which caption button is held, and the title
/// bar's double click.
pub const ChromePresses = struct {
    pressed_caption_button: ?zui.ChromeKind = null,
    /// Buttons whose press went to the window manager, so their release is
    /// not zui's either.
    handed_buttons: std.EnumSet(zui.Button) = .initEmpty(),
    last_title_bar_press_at: ?zui.Instant = null,

    /// From the first press to the second, as a press handed to the window
    /// manager has no release the host sees.
    pub const double_click_seconds = zui.Gestures.double_tap_seconds;

    pub const Press = union(enum) {
        reaches_zui,
        handed_to_window_manager: ChromeGesture,
    };

    pub const Release = union(enum) {
        reaches_zui,
        /// The release of a press the window manager took.
        swallowed,
        /// The release of a press on a caption button: zui sees the press
        /// cancelled, and the host works the button it names, null when the
        /// pointer left the button it pressed.
        cancels_press: ?zui.ChromeKind,
    };

    /// `kind_at_point` is what the window manager makes of `point`. A
    /// primary press on the title bar moves the window, or, the second
    /// within `double_click_seconds`, maximizes or restores it; on an edge
    /// it resizes the window; a secondary press on the title bar opens the
    /// window menu. Each goes to the window manager. A primary press on a
    /// caption button reaches zui, which shows it, and the release works
    /// the button.
    pub fn press(self: *ChromePresses, button: zui.Button, kind_at_point: ?zui.ChromeKind, point: [2]f32, at: zui.Instant) Press {
        self.handed_buttons.remove(button);
        const kind = kind_at_point orelse return .reaches_zui;
        switch (button) {
            .primary => switch (kind) {
                .title_bar => {
                    if (self.last_title_bar_press_at) |last| if (at.isBefore(last.addSeconds(double_click_seconds))) {
                        self.last_title_bar_press_at = null;
                        return self.handed(button, .toggle_maximized);
                    };
                    self.last_title_bar_press_at = at;
                    return self.handed(button, .move);
                },
                .minimize_button, .maximize_button, .close_button => {
                    self.pressed_caption_button = kind;
                    return .reaches_zui;
                },
                else => return self.handed(button, .{ .resize = kind }),
            },
            .secondary => if (kind == .title_bar) return self.handed(button, .{ .show_window_menu = point }),
            .middle => {},
        }
        return .reaches_zui;
    }

    /// `kind_at_point` is what the window manager makes of the release's
    /// point.
    pub fn release(self: *ChromePresses, button: zui.Button, kind_at_point: ?zui.ChromeKind) Release {
        if (self.handed_buttons.contains(button)) {
            self.handed_buttons.remove(button);
            return .swallowed;
        }
        if (button != .primary) return .reaches_zui;
        const pressed = self.pressed_caption_button orelse return .reaches_zui;
        self.pressed_caption_button = null;
        return .{ .cancels_press = if (kind_at_point == pressed) pressed else null };
    }

    /// Returns whether a caption button's press was cancelled.
    pub fn onPointerLeave(self: *ChromePresses) bool {
        const cancelled = self.pressed_caption_button != null;
        self.pressed_caption_button = null;
        return cancelled;
    }

    /// A press handed to the window manager may end without a release the
    /// window sees.
    pub fn onPointerEnter(self: *ChromePresses) void {
        self.handed_buttons = .initEmpty();
    }

    pub fn forget(self: *ChromePresses) void {
        self.* = .{};
    }

    fn handed(self: *ChromePresses, button: zui.Button, gesture: ChromeGesture) Press {
        self.handed_buttons.insert(button);
        return .{ .handed_to_window_manager = gesture };
    }
};

/// `zxdg_toplevel_decoration_v1`'s modes.
pub const DecorationMode = enum(u32) {
    client_side = 1,
    server_side = 2,
    _,
};

/// `xdg_toplevel.resize_edge`.
pub const ResizeEdge = enum(u32) {
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,

    pub fn of(kind: zui.ChromeKind) ?ResizeEdge {
        return switch (kind) {
            .resize_top => .top,
            .resize_bottom => .bottom,
            .resize_left => .left,
            .resize_right => .right,
            .resize_top_left => .top_left,
            .resize_top_right => .top_right,
            .resize_bottom_left => .bottom_left,
            .resize_bottom_right => .bottom_right,
            .title_bar, .minimize_button, .maximize_button, .close_button, .client => null,
        };
    }
};

/// What the host asks of the compositor for the window's chrome, each
/// carrying the serial of the press that asked for it where the protocol
/// wants one.
pub const WindowManagerRequest = union(enum) {
    move: u32,
    resize: struct { serial: u32, edge: ResizeEdge },
    /// At a surface-local position.
    show_window_menu: struct { serial: u32, position: [2]i32 },
    set_maximized,
    unset_maximized,
    set_minimized,
};

/// Who the requests go to: an unshown window has no toplevel, and a
/// compositor without a seat takes no move, resize or menu.
pub const WindowManager = struct {
    toplevel: ?*Proxy,
    seat: ?*Proxy,
};

/// A Wayland window's custom title bar: what the compositor let it be, the
/// regions of its last frame, the presses on them it handed the
/// compositor, and whether the window is maximized.
pub const WindowChrome = struct {
    /// The window was opened with `title_bar = .custom`.
    asked_for_custom: bool = false,
    resizable: bool = true,
    /// Null where the compositor offers no decoration manager, or for a
    /// window without a toplevel.
    decoration: ?*Proxy = null,
    /// Null until the compositor configures one.
    decoration_mode: ?DecorationMode = null,
    snapshot: ChromeSnapshot = .{},
    /// As of the last configure the window acknowledged.
    maximized: bool = false,
    /// As the last `xdg_toplevel.configure` said, applied by the
    /// `xdg_surface.configure` that ends it.
    configured_maximized: bool = false,
    presses: ChromePresses = .{},
    last_request: ?WindowManagerRequest = null,
    requests_sent: u32 = 0,

    pub const Press = enum { reaches_zui, handed_to_window_manager };
    pub const Release = ChromePresses.Release;

    /// The application draws the title bar: it asked to, and the compositor
    /// did not insist on drawing its own.
    pub fn isCustom(self: *const WindowChrome) bool {
        return self.asked_for_custom and self.decoration_mode != .server_side;
    }

    /// Asks the compositor to leave the decorations to the window, for a
    /// custom title bar, or to draw its own. Call before the toplevel's
    /// first commit.
    pub fn decorate(self: *WindowChrome, manager: *Proxy, toplevel: *Proxy) ?*Proxy {
        const decoration = wayland.create(manager, wayland.decoration_manager_get_toplevel_decoration, &wayland.toplevel_decoration_interface, 1, .{ wayland.no_id, toplevel }) orelse return null;
        self.decoration = decoration;
        const mode: DecorationMode = if (self.asked_for_custom) .client_side else .server_side;
        wayland.send(decoration, wayland.toplevel_decoration_set_mode, .{@intFromEnum(mode)});
        return decoration;
    }

    pub fn deinit(self: *WindowChrome) void {
        if (self.decoration) |decoration| wayland.destroy(decoration, wayland.toplevel_decoration_destroy);
        self.decoration = null;
    }

    /// A server-side mode takes the title bar back from the application,
    /// and the host stops answering presses on its chrome.
    pub fn onDecorationMode(self: *WindowChrome, mode: DecorationMode) void {
        self.decoration_mode = mode;
        if (!self.isCustom()) {
            self.snapshot.clear();
            self.presses.forget();
        }
    }

    pub fn publish(self: *WindowChrome, regions: []const zui.ChromeRegion, surface_coordinates_per_unit: f32) void {
        if (!self.isCustom()) return;
        self.snapshot.publish(regions, surface_coordinates_per_unit);
    }

    /// What the compositor makes of a point, in surface coordinates: null
    /// where it is the application's, as outside any region.
    pub fn kindAt(self: *const WindowChrome, point: [2]f32) ?zui.ChromeKind {
        if (!self.isCustom()) return null;
        return self.snapshot.windowManagerKindAt(self.resizable, point);
    }

    /// See `ChromePresses.press`; each request carries `serial`.
    pub fn press(self: *WindowChrome, button: zui.Button, point: [2]f32, serial: u32, at: zui.Instant, window_manager: WindowManager) Press {
        const gesture = switch (self.presses.press(button, self.kindAt(point), point, at)) {
            .reaches_zui => return .reaches_zui,
            .handed_to_window_manager => |gesture| gesture,
        };
        switch (gesture) {
            .move => self.request(window_manager, .{ .move = serial }),
            .resize => |kind| self.request(window_manager, .{ .resize = .{ .serial = serial, .edge = ResizeEdge.of(kind).? } }),
            .show_window_menu => |menu_point| self.request(window_manager, .{ .show_window_menu = .{ .serial = serial, .position = .{ surfaceLocal(menu_point[0]), surfaceLocal(menu_point[1]) } } }),
            .toggle_maximized => self.toggleMaximized(window_manager),
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

    pub fn toggleMaximized(self: *WindowChrome, window_manager: WindowManager) void {
        self.request(window_manager, if (self.maximized) .unset_maximized else .set_maximized);
    }

    pub fn minimize(self: *WindowChrome, window_manager: WindowManager) void {
        self.request(window_manager, .set_minimized);
    }

    /// Returns whether the window's maximized state changed.
    pub fn applyConfigure(self: *WindowChrome) bool {
        if (self.maximized == self.configured_maximized) return false;
        self.maximized = self.configured_maximized;
        return true;
    }

    fn request(self: *WindowChrome, window_manager: WindowManager, sent: WindowManagerRequest) void {
        self.last_request = sent;
        self.requests_sent += 1;
        const toplevel = window_manager.toplevel orelse return;
        switch (sent) {
            .set_maximized => wayland.send(toplevel, wayland.xdg_toplevel_set_maximized, .{}),
            .unset_maximized => wayland.send(toplevel, wayland.xdg_toplevel_unset_maximized, .{}),
            .set_minimized => wayland.send(toplevel, wayland.xdg_toplevel_set_minimized, .{}),
            .move => |serial| if (window_manager.seat) |seat| wayland.send(toplevel, wayland.xdg_toplevel_move, .{ seat, serial }),
            .resize => |resize| if (window_manager.seat) |seat| wayland.send(toplevel, wayland.xdg_toplevel_resize, .{ seat, resize.serial, @intFromEnum(resize.edge) }),
            .show_window_menu => |menu| if (window_manager.seat) |seat| wayland.send(toplevel, wayland.xdg_toplevel_show_window_menu, .{ seat, menu.serial, menu.position[0], menu.position[1] }),
        }
    }

    fn surfaceLocal(coordinate: f32) i32 {
        const farthest = 1 << 30;
        return @intFromFloat(std.math.clamp(@floor(coordinate), -farthest, farthest));
    }
};

/// Whether `states`, an `xdg_toplevel.configure`'s, holds `maximized`.
pub fn statesHoldMaximized(states: []const u32) bool {
    const maximized = 1;
    return std.mem.indexOfScalar(u32, states, maximized) != null;
}

const no_window_manager: WindowManager = .{ .toplevel = null, .seat = null };

fn customChrome() WindowChrome {
    var chrome: WindowChrome = .{ .asked_for_custom = true };
    const title_bar: zui.ChromeRegion = .{ .id = 1, .bounds = .{ .width = 400, .height = 32 }, .kind = .title_bar };
    const search: zui.ChromeRegion = .{ .id = 2, .bounds = .{ .x = 100, .y = 4, .width = 120, .height = 24 }, .kind = .client };
    const close: zui.ChromeRegion = .{ .id = 3, .bounds = .{ .x = 360, .width = 40, .height = 32 }, .kind = .close_button };
    chrome.publish(&.{ title_bar, search, close }, 2);
    return chrome;
}

test "the region on top is the last one holding the point, and what does not fit is counted" {
    var chrome = customChrome();
    try std.testing.expectEqual(zui.ChromeKind.title_bar, chrome.kindAt(.{ 10, 10 }).?);
    try std.testing.expectEqual(@as(?zui.ChromeKind, null), chrome.kindAt(.{ 250, 20 }));
    try std.testing.expectEqual(zui.ChromeKind.close_button, chrome.kindAt(.{ 790, 20 }).?);
    try std.testing.expectEqual(zui.ChromeKind.title_bar, chrome.kindAt(.{ 450, 20 }).?);
    try std.testing.expectEqual(@as(?zui.ChromeKind, null), chrome.kindAt(.{ 10, 64 }));

    var many: [ChromeSnapshot.capacity + 3]zui.ChromeRegion = @splat(.{ .id = 1, .bounds = .{ .width = 1, .height = 1 }, .kind = .title_bar });
    chrome.publish(&many, 1);
    try std.testing.expectEqual(@as(usize, ChromeSnapshot.capacity), chrome.snapshot.count);
    try std.testing.expectEqual(@as(usize, 3), chrome.snapshot.dropped);
}

test "a caption button released off itself cancels the press and works nothing" {
    var chrome = customChrome();
    try std.testing.expectEqual(WindowChrome.Press.reaches_zui, chrome.press(.primary, .{ 790, 20 }, 7, .zero, no_window_manager));
    try std.testing.expectEqual(WindowChrome.Release{ .cancels_press = null }, chrome.release(.primary, .{ 10, 10 }));
    try std.testing.expectEqual(@as(u32, 0), chrome.requests_sent);
}

test "a compositor that insists on its own decorations takes the chrome back" {
    var chrome = customChrome();
    chrome.onDecorationMode(.server_side);
    try std.testing.expect(!chrome.isCustom());
    try std.testing.expectEqual(@as(?zui.ChromeKind, null), chrome.kindAt(.{ 10, 10 }));
    try std.testing.expectEqual(WindowChrome.Press.reaches_zui, chrome.press(.primary, .{ 10, 10 }, 7, .zero, no_window_manager));
}

test "the maximized state is found among a configure's states" {
    try std.testing.expect(statesHoldMaximized(&.{ 4, 1 }));
    try std.testing.expect(!statesHoldMaximized(&.{ 4, 5 }));
    try std.testing.expect(!statesHoldMaximized(&.{}));
}

test "the title bar's second press within the double click's time toggles maximize, and a third starts again with a move" {
    var presses: ChromePresses = .{};
    const at: zui.Instant = .zero;
    try std.testing.expectEqual(ChromePresses.Press{ .handed_to_window_manager = .move }, presses.press(.primary, .title_bar, .{ 1, 1 }, at));
    try std.testing.expectEqual(ChromePresses.Release.swallowed, presses.release(.primary, null));
    try std.testing.expectEqual(ChromePresses.Press{ .handed_to_window_manager = .toggle_maximized }, presses.press(.primary, .title_bar, .{ 1, 1 }, at.addSeconds(0.1)));
    try std.testing.expectEqual(ChromePresses.Press{ .handed_to_window_manager = .move }, presses.press(.primary, .title_bar, .{ 1, 1 }, at.addSeconds(0.2)));
    const late = at.addSeconds(0.2 + ChromePresses.double_click_seconds);
    try std.testing.expectEqual(ChromePresses.Press{ .handed_to_window_manager = .move }, presses.press(.primary, .title_bar, .{ 1, 1 }, late));
}

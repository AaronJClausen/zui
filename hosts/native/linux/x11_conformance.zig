const std = @import("std");
const zui_host = @import("zui_host");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const X11Host = zui_host.linux.X11Host;
const x11 = zui_host.linux.x11;
const services = zui_host.linux.services;
const desktop_bus = zui_host.linux.desktop_bus;
const x11_chrome = zui_host.linux.x11_chrome;
const WindowManagerSupport = x11_chrome.WindowManagerSupport;
const WindowManagerRequest = x11_chrome.WindowManagerRequest;

const testing = std.testing;

const no_buses: desktop_bus.Addresses = .{ .session = null, .system = null };

/// An X11 window that is never mapped, so the server never shows it.
const UnmappedWindow = struct {
    window_host: X11Host = undefined,
    service_fake: services.ServiceFake = .{},
    title_bar: zui.TitleBar = .native,
    /// Null reads the window manager's from the root window.
    window_manager_support: ?WindowManagerSupport = null,
    /// The bus the input method is reached on; null reaches none.
    input_method_bus: ?[]const u8 = null,

    /// With `forced_scale` set, a physical pixel is that many layout units
    /// at a zoom of 1. The window reads no bus but `input_method_bus`, so
    /// its environment starts at zui's defaults.
    fn open(self: *UnmappedWindow, forced_scale: ?f32) !void {
        self.window_host.forced_scale = forced_scale;
        self.window_host.bus_addresses = no_buses;
        self.window_host.input_method_bus = self.input_method_bus;
        self.window_host.service_fake = &self.service_fake;
        self.window_host.forced_window_manager_support = self.window_manager_support;
        self.window_host.init(testing.io, .{ .title = "zui host suite on X11", .size = .{ 320, 240 }, .visible = false, .title_bar = self.title_bar }) catch |err| switch (err) {
            error.NoX11Display => return skipWithoutServer(),
            else => return err,
        };
        // As if the pointer and the keyboard were already in the window,
        // without the events entering it reports.
        self.window_host.pointer_window = mainOf(&self.window_host);
        self.window_host.keyboard_window = mainOf(&self.window_host);
    }

    fn close(self: *UnmappedWindow) void {
        self.window_host.deinit();
    }

    fn host(self: *UnmappedWindow) *X11Host {
        return &self.window_host;
    }
};

fn skipWithoutServer() error{SkipZigTest} {
    std.debug.print("skipped: no X server to connect to (DISPLAY)\n", .{});
    return error.SkipZigTest;
}

fn mainOf(window_host: *X11Host) *X11Host.Window {
    return window_host.windowById(.main).?;
}

/// Delivers each event the suite posts as the X server would, at the
/// physical pixels the last poll's scale and zoom put it at, first moving
/// the pointer or the keyboard's focus into the window it is posted to.
const ServerHarness = struct {
    window: UnmappedWindow = .{},

    pub fn host(self: *ServerHarness) *X11Host {
        return self.window.host();
    }

    pub fn post(self: *ServerHarness, event: zui.Event) bool {
        return self.postTo(.main, event);
    }

    pub fn postTo(self: *ServerHarness, id: zui.WindowId, event: zui.Event) bool {
        const window_host = self.host();
        const target = window_host.windowById(id) orelse return false;
        switch (event) {
            .pointer_move => |move| {
                const position = physicalPixels(target, move.pointer.position);
                if (window_host.pointer_window == target) window_host.onPointerMotion(position) else enterWithPointer(window_host, target, position);
            },
            .pointer_down, .pointer_up => |press| {
                const position = physicalPixels(target, press.pointer.position);
                if (window_host.pointer_window != target) enterWithPointer(window_host, target, position);
                window_host.onButton(1, event == .pointer_down, position);
            },
            .key_down, .key_up => |key| {
                const keycode = keycodeOf(window_host, key.key) orelse return false;
                if (window_host.keyboard_window != target) focusOn(window_host, target);
                window_host.onKey(keycode, event == .key_down);
            },
            .environment => |change| switch (change) {
                .accent => |accent| window_host.onDesktopReport(.{ .accent = accent }),
                else => return false,
            },
            else => return false,
        }
        return true;
    }

    pub fn openedUrl(self: *ServerHarness) ?[]const u8 {
        return self.window.service_fake.openedUrl();
    }

    pub fn scriptServices(self: *ServerHarness, script: zui_testing.ServiceScript) void {
        self.window.service_fake.scriptFileDialog(script.chosen_paths);
        self.window.service_fake.scriptNotification(switch (script.notification) {
            .activated => .activated,
            .dismissed => .dismissed,
        });
    }

    pub fn close(self: *ServerHarness) void {
        self.host().close();
    }
};

fn enterWithPointer(window_host: *X11Host, target: *X11Host.Window, position: [2]f32) void {
    window_host.onPointerLeave();
    window_host.onPointerEnter(target, position);
}

fn focusOn(window_host: *X11Host, target: *X11Host.Window) void {
    if (window_host.keyboard_window) |focused| window_host.onFocus(focused, false);
    window_host.onFocus(target, true);
}

fn physicalPixels(window: *const X11Host.Window, position: [2]f32) [2]f32 {
    const per_unit = window.surface_coordinates_per_unit;
    return .{ position[0] * per_unit, position[1] * per_unit };
}

/// The X key code of `key` in the server's keymap.
fn keycodeOf(window_host: *const X11Host, key: zui.Key) ?u8 {
    for (1..248) |evdev_code| {
        if (window_host.keyOf(@intCast(evdev_code)) == key) return @intCast(evdev_code + 8);
    }
    return null;
}

const control_modifier_mask = 1 << 2;

fn typedText(polled: *const zui_testing.PolledRecord, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (polled.builder.events()) |event| if (event == .text) {
        @memcpy(buffer[len..][0..event.text.len], event.text);
        len += event.text.len;
    };
    return buffer[0..len];
}

fn countOf(polled: *const zui_testing.PolledRecord, comptime tag: std.meta.Tag(zui.Event)) usize {
    var count: usize = 0;
    for (polled.builder.events()) |event| if (event == tag) {
        count += 1;
    };
    return count;
}

test "the X11 host passes zui's host suite on a window that is never mapped" {
    var harness: ServerHarness = .{};
    try harness.window.open(1);
    defer harness.window.close();
    try zui_testing.expectHostConforms(X11Host, &harness, .{ .io = testing.io });
}

test "on X11 the first poll reports focus and the environment, and a viewport in layout units of the window's physical pixels" {
    var window: UnmappedWindow = .{};
    try window.open(2);
    defer window.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    polled.builder.params.zoom = 1.25;
    try testing.expect(polled.poll(window.host()));
    try testing.expectEqual(@as(f32, 2), polled.builder.params.scale);
    try testing.expectEqual([2]f32{ 320 / 1.25, 240 / 1.25 }, polled.builder.params.viewport);
    try testing.expectEqual(false, polled.find(.environment).?.window_focused);
    try testing.expectEqual(@as(usize, 10), countOf(&polled, .environment));
    try testing.expectEqual(zui.Surface{ .x11 = .{ .display = window.host().display, .window = mainOf(window.host()).x_window } }, window.host().zuiSurface(.main));
}

test "on X11 a key reports its key, its evdev code and the modifiers XKB reports, and types its text, but not with Control held" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    if (window_host.keymap == null) {
        std.debug.print("skipped: the X server offers no XKB keymap\n", .{});
        return error.SkipZigTest;
    }
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);

    for ([_]zui.Key{ .h, .i, .enter }) |key| {
        window_host.onKey(keycodeOf(window_host, key).?, true);
        window_host.onKey(keycodeOf(window_host, key).?, false);
    }
    _ = polled.poll(window_host);
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("hi", typedText(&polled, &buffer));
    const pressed = polled.find(.key_down).?;
    try testing.expectEqual(zui.Key.h, pressed.key);
    try testing.expectEqual(@as(u32, keycodeOf(window_host, .h).? - 8), pressed.scancode);
    try testing.expect(!pressed.modifiers.control and !pressed.repeat);
    try testing.expectEqual(zui.Key.h, polled.find(.key_up).?.key);

    window_host.onXkbState(control_modifier_mask, 0, 0, 0, 0, 0);
    window_host.onKey(keycodeOf(window_host, .s).?, true);
    _ = polled.poll(window_host);
    try testing.expectEqualStrings("", typedText(&polled, &buffer));
    try testing.expect(polled.find(.key_down).?.modifiers.control);

    window_host.onXkbState(0, 0, 0, 0, 0, 0);
    window_host.onKey(keycodeOf(window_host, .s).?, false);
    window_host.onKey(keycodeOf(window_host, .s).?, true);
    _ = polled.poll(window_host);
    try testing.expect(!polled.find(.key_down).?.modifiers.control);
    try testing.expectEqualStrings("s", typedText(&polled, &buffer));
}

test "on X11 a dead acute and e type é once, Multi_key o c types ©, and a cancelled sequence types nothing, each press still a key" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    try @import("compose_testing.zig").expectComposes(window.host(), struct {
        fn press(window_host: *X11Host, evdev_code: u32, pressed: bool) void {
            window_host.onKey(@intCast(evdev_code + 8), pressed);
        }
    }.press);
}

test "on X11 a key the server repeats arrives as presses, each after the first a repeat that types again, until it is released or focus leaves" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    if (!window_host.detectable_repeat) std.debug.print("note: the X server does not report repeats as presses alone\n", .{});
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    const a = keycodeOf(window_host, .a).?;

    window_host.onKey(a, true);
    window_host.onKey(a, true);
    window_host.onKey(a, true);
    _ = polled.poll(window_host);
    var repeats: usize = 0;
    for (polled.builder.events(), 0..) |event, index| if (event == .key_down) {
        try testing.expectEqual(index > 0, event.key_down.repeat);
        if (event.key_down.repeat) repeats += 1;
    };
    try testing.expectEqual(@as(usize, 2), repeats);
    var buffer: [32]u8 = undefined;
    if (window_host.keymap != null) try testing.expectEqualStrings("aaa", typedText(&polled, &buffer));

    window_host.onKey(a, false);
    window_host.onKey(a, true);
    _ = polled.poll(window_host);
    try testing.expect(!polled.find(.key_down).?.repeat);

    window_host.onFocus(mainOf(window_host), true);
    window_host.onFocus(mainOf(window_host), false);
    window_host.onKey(a, true);
    _ = polled.poll(window_host);
    try testing.expect(!polled.find(.key_down).?.repeat);
}

test "on X11 each press of buttons 4 to 7 is a wheel's notch, toward the end for down and right, and 1 to 3 are the primary, middle and secondary buttons" {
    var window: UnmappedWindow = .{};
    try window.open(2);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);

    const notches = [_]struct { u8, [2]f32 }{
        .{ 4, .{ 0, -X11Host.wheel_step } },
        .{ 5, .{ 0, X11Host.wheel_step } },
        .{ 6, .{ -X11Host.wheel_step, 0 } },
        .{ 7, .{ X11Host.wheel_step, 0 } },
    };
    for (notches) |notch| {
        window_host.onButton(notch[0], true, .{ 40, 60 });
        window_host.onButton(notch[0], false, .{ 40, 60 });
        _ = polled.poll(window_host);
        try testing.expectEqual(@as(usize, 1), countOf(&polled, .wheel));
        const wheel = polled.find(.wheel).?;
        try testing.expectEqual(notch[1], wheel.delta);
        try testing.expectEqual([2]f32{ 20, 30 }, wheel.position);
        try testing.expectEqual(@as(usize, 0), countOf(&polled, .pointer_down));
    }

    for ([_]struct { u8, zui.Button }{ .{ 1, .primary }, .{ 2, .middle }, .{ 3, .secondary } }) |pair| {
        window_host.onButton(pair[0], true, .{ 10, 10 });
        window_host.onButton(pair[0], false, .{ 10, 10 });
        _ = polled.poll(window_host);
        try testing.expectEqual(pair[1], polled.find(.pointer_down).?.button);
        try testing.expectEqual(pair[1], polled.find(.pointer_up).?.button);
    }
    window_host.onButton(8, true, .{ 10, 10 });
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(usize, 0), countOf(&polled, .pointer_down));
}

test "on X11 the server resizing the window is its new size at the next poll" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    try testing.expectEqual([2]f32{ 320, 240 }, polled.builder.params.viewport);

    const size = [_]u32{ 400, 300 };
    _ = x11.xcb_configure_window(window_host.connection, mainOf(window_host).x_window, x11.configure_width | x11.configure_height, &size);
    window_host.zuiWait(.{ .at = window_host.now().addSeconds(2) });
    try testing.expect(polled.poll(window_host));
    try testing.expectEqual([2]f32{ 400, 300 }, polled.builder.params.viewport);

    mainOf(window_host).onConfigure(400, 300);
    window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    try testing.expect(window_host.now().secondsSince(polled.builder.params.now) >= 0.04);
}

test "on X11 Xft.dpi in the resource manager is the scale, 96 being 1, and without it the scale is 1" {
    var window: UnmappedWindow = .{};
    try window.open(null);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    window_host.onResourceManager("Xft.dpi:\t96\n");
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(f32, 1), polled.builder.params.scale);
    const pixels = polled.builder.params.viewport;

    window_host.onResourceManager("Xcursor.size:\t24\nXft.dpi:\t144\n");
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(f32, 1.5), polled.builder.params.scale);
    try testing.expectEqual([2]f32{ pixels[0] / 1.5, pixels[1] / 1.5 }, polled.builder.params.viewport);

    window_host.onResourceManager("Xcursor.size:\t24\n");
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(f32, 1), polled.builder.params.scale);
}

fn focusEvent(code: u8, window: x11.Window, mode: u8) x11.GenericEvent {
    var event = std.mem.zeroes(x11.GenericEvent);
    const focus: *x11.FocusEvent = @ptrCast(&event);
    focus.* = .{ .response_type = code, .detail = 0, .sequence = 0, .event = window, .mode = mode, .pad0 = @splat(0) };
    return event;
}

test "on X11 focus coming and going is reported once each, and a grab's moving the keyboard is not" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const id = mainOf(window_host).x_window;
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);

    var focus_in = focusEvent(x11.focus_in, id, 0);
    window_host.dispatch(&focus_in);
    window_host.dispatch(&focus_in);
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(usize, 1), countOf(&polled, .environment));
    try testing.expectEqual(true, polled.find(.environment).?.window_focused);

    var grabbed = focusEvent(x11.focus_out, id, x11.notify_mode_grab);
    window_host.dispatch(&grabbed);
    var another_window = focusEvent(x11.focus_out, id + 1, 0);
    window_host.dispatch(&another_window);
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(usize, 0), countOf(&polled, .environment));

    var focus_out = focusEvent(x11.focus_out, id, 0);
    window_host.dispatch(&focus_out);
    _ = polled.poll(window_host);
    try testing.expectEqual(false, polled.find(.environment).?.window_focused);
}

test "on X11 the window manager's WM_DELETE_WINDOW closes the window at the next poll, and another message does not" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    try testing.expect(polled.poll(window_host));

    var event = std.mem.zeroes(x11.GenericEvent);
    const message: *x11.ClientMessageEvent = @ptrCast(&event);
    message.* = .{ .response_type = x11.client_message, .format = 32, .sequence = 0, .window = mainOf(window_host).x_window, .type = window_host.atoms.wm_protocols, .data32 = .{ window_host.atoms.net_wm_name, 0, 0, 0, 0 } };
    window_host.dispatch(&event);
    try testing.expect(polled.poll(window_host));

    message.data32[0] = window_host.atoms.wm_delete_window;
    window_host.dispatch(&event);
    try testing.expect(!polled.poll(window_host));
}

test "on X11 the pointer leaving is reported, and a cursor asked for is loaded once and shown" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);

    window_host.onPointerEnter(mainOf(window_host), .{ 5, 6 });
    window_host.onPointerLeave();
    _ = polled.poll(window_host);
    try testing.expectEqual([2]f32{ 5, 6 }, polled.find(.pointer_move).?.pointer.position);
    try testing.expectEqual(zui.PointerId.mouse, polled.find(.pointer_leave).?);

    window_host.zuiApply(.main, .{ .cursor = .text });
    const shown = window_host.shownCursor(.main).?;
    window_host.zuiApply(.main, .{ .cursor = .default });
    window_host.zuiApply(.main, .{ .cursor = .text });
    try testing.expectEqual(shown, window_host.shownCursor(.main).?);
}

test "on X11 SIGINT wakes the wait as a terminate request, after which the window reports closed" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    if (!window_host.handlesSignal(.INT)) {
        std.debug.print("skipped: SIGINT already has a handler in this process\n", .{});
        return error.SkipZigTest;
    }
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    try std.posix.raise(.INT);
    window_host.zuiWait(.{ .at = window_host.now().addSeconds(2) });
    try testing.expect(polled.poll(window_host));
    try testing.expectEqual(zui.Lifecycle.terminate_requested, polled.find(.lifecycle).?);
    try testing.expect(!polled.poll(window_host));
}

test "on X11 a desktop setting that changes is reported" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    window_host.onDesktopReport(.{ .theme = .dark });
    window_host.onDesktopReport(.{ .preparing_for_sleep = true });
    _ = polled.poll(window_host);
    try testing.expectEqual(zui.Environment.Theme.dark, polled.find(.environment).?.theme);
    try testing.expectEqual(zui.Lifecycle.@"suspend", polled.find(.lifecycle).?);
}

test "on X11 the desktop's accent is reported, and as null once unset" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    window_host.onDesktopReport(.{ .accent = .rgb(0x3584e4) });
    _ = polled.poll(window_host);
    try testing.expectEqual(zui.EnvironmentChange{ .accent = .rgb(0x3584e4) }, polled.find(.environment).?);
    window_host.onDesktopReport(.{ .accent = null });
    _ = polled.poll(window_host);
    try testing.expectEqual(zui.EnvironmentChange{ .accent = null }, polled.find(.environment).?);
}

test "zui_host.Host connects to the backend forced, or follows ZUI_HOST_BACKEND, its surface naming the backend" {
    const variable: ?[]const u8 = if (std.c.getenv(zui_host.linux.backend_variable)) |value| std.mem.span(value) else null;
    const followed: ?zui_host.linux.Backend = switch (zui_host.Host.choiceOf(variable)) {
        .wayland => .wayland,
        .x11 => .x11,
        .wayland_then_x11 => if (zui_host.linux.wayland.wl_display_connect(null)) |display| blk: {
            zui_host.linux.wayland.wl_display_disconnect(display);
            break :blk .wayland;
        } else .x11,
    };
    for ([_]?zui_host.linux.Backend{ .x11, .wayland, null }) |forced| {
        const expected = forced orelse followed.?;
        var host: zui_host.Host = .{ .backend = undefined, .forced_backend = forced, .bus_addresses = no_buses };
        host.init(testing.io, .{ .title = "zui host choice", .size = .{ 64, 48 }, .visible = false }) catch |err| switch (err) {
            error.NoX11Display, error.NoWaylandDisplay => {
                std.debug.print("skipped: zui_host.Host on {t}: no display server to connect to\n", .{expected});
                continue;
            },
            else => return err,
        };
        defer host.deinit();
        try testing.expectEqual(expected, host.backendInUse());
        try testing.expectEqual(@as(zui.SurfaceKind, switch (expected) {
            .wayland => .wayland,
            .x11 => .x11,
        }), std.meta.activeTag(host.zuiSurface(.main)));
        if (expected == .x11) {
            const second = try host.zuiOpenWindow(.{ .visible = false });
            try testing.expect(second != .main);
            try testing.expectEqual(zui.SurfaceKind.x11, std.meta.activeTag(host.zuiSurface(second)));
            host.zuiCloseWindow(second);
            try testing.expectEqual(@as(?WindowManagerSupport, null), host.backend.x11.forced_window_manager_support);
            host.zuiChromeRegions(.main, &.{});
            try testing.expectEqual(@as(?zui.ChromeKind, null), host.chromeKindAt(.main, .{ 1, 1 }));
        }
    }
}

const ClipboardReplies = struct {
    replies: [4]zui.ServiceReply(128 * 1024) = undefined,
    count: usize = 0,

    pub fn publish(self: *ClipboardReplies, reply: zui.ServiceReply(128 * 1024)) error{Full}!zui.Wake {
        if (self.count == self.replies.len) return error.Full;
        self.replies[self.count] = reply;
        self.count += 1;
        return .needed;
    }

    fn last(self: *const ClipboardReplies) *const zui.ServiceReply(128 * 1024) {
        return &self.replies[self.count - 1];
    }
};

/// Another X client, on a connection of its own, as the server would show
/// one to the host: it owns selections and answers requests for them as a
/// test says, asks for the host's, and drags onto the host's window.
const OtherClient = struct {
    display: *x11.Display,
    connection: *x11.Connection,
    window: x11.Window,
    atoms: x11.Atoms,
    answer: Answer = .refuse,
    incremental: ?IncrementalSend = null,
    requests_answered: u32 = 0,
    notified: ?x11.SelectionNotifyEvent = null,
    status: ?[5]u32 = null,
    finished: ?[5]u32 = null,

    const Answer = union(enum) {
        refuse,
        never,
        /// Written whole, as the type the requestor asked for.
        whole: []const u8,
        /// Written in `INCR`'s chunks.
        incremental: struct { text: []const u8, chunk_len: usize },
    };

    const IncrementalSend = struct { requestor: x11.Window, property: x11.Atom, target: x11.Atom, remaining: []const u8, chunk_len: usize };

    fn open() !OtherClient {
        const display = x11.XOpenDisplay(null) orelse return skipWithoutServer();
        const connection = x11.XGetXCBConnection(display).?;
        x11.XSetEventQueueOwner(display, x11.xcb_owns_event_queue);
        const screen = x11.screenOf(connection, x11.XDefaultScreen(display)).?;
        const window = x11.xcb_generate_id(connection);
        const event_mask: u32 = x11.event_mask_property_change;
        _ = x11.xcb_create_window(connection, x11.copy_from_parent, window, screen.root, 0, 0, 16, 16, 0, x11.window_class_input_output, x11.copy_from_parent, x11.window_attribute_event_mask, &event_mask);
        const atoms: x11.Atoms = .intern(connection);
        _ = x11.xcb_flush(connection);
        return .{ .display = display, .connection = connection, .window = window, .atoms = atoms };
    }

    fn close(self: *OtherClient) void {
        _ = x11.xcb_destroy_window(self.connection, self.window);
        _ = x11.xcb_flush(self.connection);
        _ = x11.XCloseDisplay(self.display);
    }

    fn own(self: *OtherClient, selection: x11.Atom) void {
        _ = x11.xcb_set_selection_owner(self.connection, self.window, selection, x11.current_time);
        self.waitUntilServerApplied();
    }

    /// Watches the host's window's properties, as an `INCR` owner does to
    /// learn when its chunks are taken.
    fn watchPropertiesOf(self: *OtherClient, window: x11.Window) void {
        const event_mask: u32 = x11.event_mask_property_change;
        _ = x11.xcb_change_window_attributes(self.connection, window, x11.window_attribute_event_mask, &event_mask);
        self.waitUntilServerApplied();
    }

    /// A flush only sends: the host's next request, on its own connection,
    /// can still reach the server first. A reply comes after every request
    /// before it on this connection has been applied.
    fn waitUntilServerApplied(self: *OtherClient) void {
        const reply = x11.xcb_get_selection_owner_reply(self.connection, x11.xcb_get_selection_owner(self.connection, self.atoms.clipboard), null);
        if (reply) |applied| x11.free(applied);
    }

    fn convert(self: *OtherClient, selection: x11.Atom, target: x11.Atom) void {
        self.notified = null;
        _ = x11.xcb_delete_property(self.connection, self.window, self.atoms.clipboard_property);
        _ = x11.xcb_convert_selection(self.connection, self.window, selection, target, self.atoms.clipboard_property, x11.current_time);
        _ = x11.xcb_flush(self.connection);
    }

    fn sendToHost(self: *OtherClient, host_window: x11.Window, message_type: x11.Atom, data: [5]u32) void {
        x11.sendClientMessage(self.connection, host_window, message_type, data);
        _ = x11.xcb_flush(self.connection);
    }

    /// The type and the bytes of the property `convert` asked for.
    fn converted(self: *OtherClient, buffer: []u8) struct { type: x11.Atom, value: []const u8 } {
        const cookie = x11.xcb_get_property(self.connection, 0, self.window, self.atoms.clipboard_property, x11.any_property_type, 0, @intCast(buffer.len / 4));
        const reply = x11.xcb_get_property_reply(self.connection, cookie, null) orelse return .{ .type = x11.atom_none, .value = "" };
        defer x11.free(reply);
        const length: usize = @intCast(@max(x11.xcb_get_property_value_length(reply), 0));
        if (length > 0) @memcpy(buffer[0..length], x11.xcb_get_property_value(reply).?[0..length]);
        return .{ .type = reply.type, .value = buffer[0..length] };
    }

    /// Lets the host and this client take turns until `condition.holds()`,
    /// for at most 3 s, longer than the host's transfer bound, first
    /// taking what the host already has pending, which would end every
    /// wait at once.
    fn pumpUntil(self: *OtherClient, window_host: *X11Host, condition: anytype) !void {
        var pending: zui_testing.PolledRecord = .{};
        pending.init();
        _ = pending.poll(window_host);
        const deadline = window_host.now().addSeconds(3);
        while (!condition.holds()) {
            if (!window_host.now().isBefore(deadline)) return error.Timeout;
            window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.005) });
            self.receive();
        }
    }

    fn receive(self: *OtherClient) void {
        while (x11.xcb_poll_for_event(self.connection)) |event| {
            defer x11.free(event);
            switch (event.code()) {
                x11.selection_request => self.answerRequest(@as(*const x11.SelectionRequestEvent, @ptrCast(event)).*),
                x11.selection_notify => self.notified = @as(*const x11.SelectionNotifyEvent, @ptrCast(event)).*,
                x11.client_message => {
                    const message: *const x11.ClientMessageEvent = @ptrCast(event);
                    if (message.type == self.atoms.xdnd_status) self.status = message.data32;
                    if (message.type == self.atoms.xdnd_finished) self.finished = message.data32;
                },
                x11.property_notify => {
                    const property: *const x11.PropertyNotifyEvent = @ptrCast(event);
                    const property_deleted = 1;
                    if (self.incremental) |send| if (property.window == send.requestor and property.atom == send.property and property.state == property_deleted) self.sendNextChunk();
                },
                else => {},
            }
        }
        _ = x11.xcb_flush(self.connection);
    }

    fn answerRequest(self: *OtherClient, request: x11.SelectionRequestEvent) void {
        self.requests_answered += 1;
        switch (self.answer) {
            .never => return,
            .refuse => return self.notify(request, x11.atom_none),
            .whole => |text| _ = x11.xcb_change_property(self.connection, x11.property_mode_replace, request.requestor, request.property, request.target, 8, @intCast(text.len), text.ptr),
            .incremental => |transfer| {
                const size: u32 = @intCast(transfer.text.len);
                _ = x11.xcb_change_property(self.connection, x11.property_mode_replace, request.requestor, request.property, self.atoms.incr, 32, 1, &size);
                self.incremental = .{ .requestor = request.requestor, .property = request.property, .target = request.target, .remaining = transfer.text, .chunk_len = transfer.chunk_len };
            },
        }
        self.notify(request, request.property);
    }

    /// After the last chunk, an empty one ends the transfer.
    fn sendNextChunk(self: *OtherClient) void {
        const send = &self.incremental.?;
        const chunk = send.remaining[0..@min(send.chunk_len, send.remaining.len)];
        _ = x11.xcb_change_property(self.connection, x11.property_mode_replace, send.requestor, send.property, send.target, 8, @intCast(chunk.len), chunk.ptr);
        if (chunk.len == 0) self.incremental = null else send.remaining = send.remaining[chunk.len..];
    }

    fn notify(self: *OtherClient, request: x11.SelectionRequestEvent, property: x11.Atom) void {
        const notified: x11.SelectionNotifyEvent = .{ .response_type = x11.selection_notify, .pad0 = 0, .sequence = 0, .time = request.time, .requestor = request.requestor, .selection = request.selection, .target = request.target, .property = property };
        var event: [32]u8 = @splat(0);
        @memcpy(event[0..@sizeOf(x11.SelectionNotifyEvent)], std.mem.asBytes(&notified));
        _ = x11.xcb_send_event(self.connection, 0, request.requestor, 0, &event);
    }
};

const Notified = struct {
    other: *const OtherClient,
    pub fn holds(self: Notified) bool {
        return self.other.notified != null;
    }
};

const Answered = struct {
    replies: *const ClipboardReplies,
    count: usize,
    pub fn holds(self: Answered) bool {
        return self.replies.count >= self.count;
    }
};

test "on X11 another client reads the clipboard's text as each text target, and its targets, and is refused any other" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var other: OtherClient = try .open();
    defer other.close();

    const text = "zui \u{2713} clipboard";
    try X11Host.zuiClipboard.write(window_host, text);
    var buffer: [4096]u8 = undefined;
    const atoms = other.atoms;
    const targets = [_]struct { x11.Atom, x11.Atom, []const u8 }{
        .{ atoms.utf8_string, atoms.utf8_string, text },
        .{ atoms.text_plain_utf8, atoms.text_plain_utf8, text },
        .{ atoms.text, atoms.utf8_string, text },
        .{ x11.atom_string, x11.atom_string, "zui ? clipboard" },
    };
    for (targets) |target| {
        other.convert(atoms.clipboard, target[0]);
        try other.pumpUntil(window_host, Notified{ .other = &other });
        try testing.expectEqual(atoms.clipboard_property, other.notified.?.property);
        const got = other.converted(&buffer);
        try testing.expectEqual(target[1], got.type);
        try testing.expectEqualStrings(target[2], got.value);
    }

    other.convert(atoms.clipboard, atoms.targets);
    try other.pumpUntil(window_host, Notified{ .other = &other });
    const offered = other.converted(&buffer);
    try testing.expectEqual(@as(x11.Atom, x11.atom_atom), offered.type);
    const offered_targets: []align(1) const u32 = std.mem.bytesAsSlice(u32, offered.value);
    for ([_]x11.Atom{ atoms.utf8_string, atoms.text_plain_utf8, x11.atom_string, atoms.text }) |target| {
        try testing.expect(for (offered_targets) |listed| {
            if (listed == target) break true;
        } else false);
    }

    other.convert(atoms.clipboard, x11.internAtom(other.connection, "image/png"));
    try other.pumpUntil(window_host, Notified{ .other = &other });
    try testing.expectEqual(@as(x11.Atom, x11.atom_none), other.notified.?.property);
}

test "on X11 the clipboard reads another owner's text, its refusal as empty, and once the window owns it again, its own text without asking" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var other: OtherClient = try .open();
    defer other.close();
    var replies: ClipboardReplies = .{};

    try X11Host.zuiClipboard.write(window_host, "the window's own");
    other.own(other.atoms.clipboard);
    try other.pumpUntil(window_host, struct {
        host: *const X11Host,
        pub fn holds(self: @This()) bool {
            return !self.host.clipboard.owns_selection;
        }
    }{ .host = window_host });

    other.answer = .{ .whole = "from another client" };
    try X11Host.zuiClipboard.read(window_host, .of("paste"), .of(&replies));
    try testing.expectError(error.Busy, X11Host.zuiClipboard.read(window_host, .of("paste again"), .of(&replies)));
    try other.pumpUntil(window_host, Answered{ .replies = &replies, .count = 1 });
    try testing.expectEqual(.clipboard_text, replies.last().kind);
    try testing.expectEqualStrings("from another client", replies.last().text());

    other.answer = .refuse;
    try X11Host.zuiClipboard.read(window_host, .of("paste"), .of(&replies));
    try other.pumpUntil(window_host, Answered{ .replies = &replies, .count = 2 });
    try testing.expectEqual(.clipboard_text, replies.last().kind);
    try testing.expectEqualStrings("", replies.last().text());

    try X11Host.zuiClipboard.write(window_host, "the window's own");
    const asked = other.requests_answered;
    try X11Host.zuiClipboard.read(window_host, .of("paste"), .of(&replies));
    try testing.expectEqual(@as(usize, 3), replies.count);
    try testing.expectEqualStrings("the window's own", replies.last().text());
    try testing.expectEqual(asked, other.requests_answered);
}

test "on X11 an owner's INCR transfer is read in chunks, and one past the bound is cut at a character, the rest counted as left out" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var other: OtherClient = try .open();
    defer other.close();
    other.own(other.atoms.clipboard);
    other.watchPropertiesOf(window_host.selection_window);
    var replies: ClipboardReplies = .{};

    var text: [70_002]u8 = undefined;
    for (0..text.len / 3) |index| @memcpy(text[index * 3 ..][0..3], "\u{2713}");
    other.answer = .{ .incremental = .{ .text = text[0..20_001], .chunk_len = 4096 } };
    try X11Host.zuiClipboard.read(window_host, .of("paste"), .of(&replies));
    try other.pumpUntil(window_host, Answered{ .replies = &replies, .count = 1 });
    try testing.expectEqualStrings(text[0..20_001], replies.last().text());
    try testing.expectEqual(@as(u32, 0), replies.last().left_out_bytes);

    other.answer = .{ .incremental = .{ .text = &text, .chunk_len = 16 * 1024 } };
    try X11Host.zuiClipboard.read(window_host, .of("paste"), .of(&replies));
    try other.pumpUntil(window_host, Answered{ .replies = &replies, .count = 2 });
    const kept = X11Host.clipboard_text_capacity / 3 * 3;
    try testing.expectEqualStrings(text[0..kept], replies.last().text());
    try testing.expectEqual(@as(u32, text.len - kept), replies.last().left_out_bytes);
}

test "on X11 a read whose owner never answers fails after the transfer bound, and a SelectionClear drops the window's text" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var other: OtherClient = try .open();
    defer other.close();
    other.own(other.atoms.clipboard);
    other.answer = .never;
    var replies: ClipboardReplies = .{};

    const started = window_host.now();
    try X11Host.zuiClipboard.read(window_host, .of("paste"), .of(&replies));
    try other.pumpUntil(window_host, Answered{ .replies = &replies, .count = 1 });
    try testing.expectEqual(.failed, replies.last().kind);
    try testing.expect(window_host.now().secondsSince(started) >= 1.9);

    try X11Host.zuiClipboard.write(window_host, "held");
    var clear = std.mem.zeroes(x11.GenericEvent);
    const cleared: *x11.SelectionClearEvent = @ptrCast(&clear);
    cleared.* = .{ .response_type = x11.selection_clear, .pad0 = 0, .sequence = 0, .time = 0, .owner = window_host.selection_window, .selection = window_host.atoms.clipboard };
    window_host.dispatch(&clear);
    try testing.expect(!window_host.clipboard.owns_selection);
}

fn dropOf(polled: *zui_testing.PolledRecord, window_host: *X11Host) ?zui.FilesDropped {
    _ = polled.poll(window_host);
    return polled.find(.files_dropped);
}

test "on X11 files another client drags in and drops arrive as files_dropped at the drop's position in layout units, only file URIs among them" {
    var window: UnmappedWindow = .{};
    try window.open(2);
    defer window.close();
    const window_host = window.host();
    var other: OtherClient = try .open();
    defer other.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);

    const atoms = other.atoms;
    const listed = [_]x11.Atom{ atoms.utf8_string, atoms.text, atoms.targets, atoms.uri_list };
    _ = x11.xcb_change_property(other.connection, x11.property_mode_replace, other.window, atoms.xdnd_type_list, x11.atom_atom, 32, listed.len, &listed);
    other.own(atoms.xdnd_selection);
    other.answer = .{ .whole = "file:///home/user/My%20Theme.zon\r\nhttps://ziglang.org/\r\nfile:///tmp/notes.txt\r\n" };
    const host_window = mainOf(window_host).x_window;
    const lists_more_types = 1;
    other.sendToHost(host_window, atoms.xdnd_enter, .{ other.window, 5 << 24 | lists_more_types, listed[0], listed[1], listed[2] });
    other.sendToHost(host_window, atoms.xdnd_position, .{ other.window, 0, 120 << 16 | 80, x11.current_time, atoms.xdnd_action_copy });
    try other.pumpUntil(window_host, struct {
        other: *const OtherClient,
        pub fn holds(self: @This()) bool {
            return self.other.status != null;
        }
    }{ .other = &other });
    try testing.expectEqual(@as(u32, 1), other.status.?[1] & 1);
    try testing.expectEqual(atoms.xdnd_action_copy, other.status.?[4]);

    other.sendToHost(host_window, atoms.xdnd_drop, .{ other.window, 0, x11.current_time, 0, 0 });
    try other.pumpUntil(window_host, struct {
        other: *const OtherClient,
        pub fn holds(self: @This()) bool {
            return self.other.finished != null;
        }
    }{ .other = &other });
    try testing.expectEqual(@as(u32, 1), other.finished.?[1]);
    const drop = dropOf(&polled, window_host).?;
    try testing.expectEqual([2]f32{ 60, 40 }, drop.position);
    var paths = drop.paths();
    try testing.expectEqualStrings("/home/user/My Theme.zon", paths.next().?);
    try testing.expectEqualStrings("/tmp/notes.txt", paths.next().?);
    try testing.expectEqual(@as(?[]const u8, null), paths.next());
}

test "on X11 a drag that offers no URI list is refused and its drop finished unaccepted, and one that leaves drops nothing" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var other: OtherClient = try .open();
    defer other.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    const atoms = other.atoms;
    const host_window = mainOf(window_host).x_window;
    other.own(atoms.xdnd_selection);
    other.answer = .{ .whole = "file:///tmp/notes.txt\r\n" };

    other.sendToHost(host_window, atoms.xdnd_enter, .{ other.window, 5 << 24, atoms.utf8_string, 0, 0 });
    other.sendToHost(host_window, atoms.xdnd_position, .{ other.window, 0, 10 << 16 | 10, x11.current_time, atoms.xdnd_action_copy });
    other.sendToHost(host_window, atoms.xdnd_drop, .{ other.window, 0, x11.current_time, 0, 0 });
    try other.pumpUntil(window_host, struct {
        other: *const OtherClient,
        pub fn holds(self: @This()) bool {
            return self.other.finished != null;
        }
    }{ .other = &other });
    try testing.expectEqual(@as(u32, 0), other.status.?[1] & 1);
    try testing.expectEqual(@as(u32, x11.atom_none), other.status.?[4]);
    try testing.expectEqual(@as(u32, 0), other.finished.?[1]);

    other.status = null;
    other.sendToHost(host_window, atoms.xdnd_enter, .{ other.window, 5 << 24, atoms.uri_list, 0, 0 });
    other.sendToHost(host_window, atoms.xdnd_position, .{ other.window, 0, 10 << 16 | 10, x11.current_time, atoms.xdnd_action_copy });
    other.sendToHost(host_window, atoms.xdnd_leave, .{ other.window, 0, 0, 0, 0 });
    try other.pumpUntil(window_host, struct {
        other: *const OtherClient,
        pub fn holds(self: @This()) bool {
            return self.other.status != null;
        }
    }{ .other = &other });
    window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    other.receive();
    try testing.expectEqual(@as(?zui.FilesDropped, null), dropOf(&polled, window_host));
    try testing.expectEqual(@as(u32, 0), other.requests_answered);
}

fn reportedEnvironment(polled: *const zui_testing.PolledRecord) zui.Environment {
    var environment: zui.Environment = .{};
    for (polled.builder.events()) |event| if (event == .environment) environment.apply(event.environment);
    return environment;
}

const title_bar_height = 20;

/// A title bar across the top, a search field in it, three caption buttons
/// at its right and a resize grip in the bottom-right corner, in layout
/// units for a viewport of `width` by `height`.
fn titleBarRegions(width: f32, height: f32) [6]zui.ChromeRegion {
    return .{
        .{ .id = 1, .bounds = .{ .width = width, .height = title_bar_height }, .kind = .title_bar },
        .{ .id = 2, .bounds = .{ .x = 20, .y = 2, .width = 40, .height = 16 }, .kind = .client },
        .{ .id = 3, .bounds = .{ .x = width - 69, .width = 23, .height = title_bar_height }, .kind = .minimize_button },
        .{ .id = 4, .bounds = .{ .x = width - 46, .width = 23, .height = title_bar_height }, .kind = .maximize_button },
        .{ .id = 5, .bounds = .{ .x = width - 23, .width = 23, .height = title_bar_height }, .kind = .close_button },
        .{ .id = 6, .bounds = .{ .x = width - 8, .y = height - 8, .width = 8, .height = 8 }, .kind = .resize_bottom_right },
    };
}

const Part = enum(usize) { title_bar, search, minimize, maximize, close, grip };

/// Where the tests' presses put the window's top-left on the root window.
const window_on_root: [2]i16 = .{ 1000, 500 };

fn rootPositionOf(point: [2]i16) [2]i32 {
    return .{ @as(i32, point[0]) + window_on_root[0], @as(i32, point[1]) + window_on_root[1] };
}

fn pointerButtonEvent(code: u8, window: x11.Window, x_button: u8, point: [2]i16) x11.GenericEvent {
    var event = std.mem.zeroes(x11.GenericEvent);
    const input: *x11.InputEvent = @ptrCast(&event);
    const root_position = rootPositionOf(point);
    input.* = .{
        .response_type = code,
        .detail = x_button,
        .sequence = 0,
        .time = 0,
        .root = 0,
        .event = window,
        .child = 0,
        .root_x = @intCast(root_position[0]),
        .root_y = @intCast(root_position[1]),
        .event_x = point[0],
        .event_y = point[1],
        .state = 0,
        .same_screen = 1,
        .pad0 = 0,
    };
    return event;
}

/// A window with a custom title bar, polled once and handed
/// `titleBarRegions` for its viewport from a buffer overwritten after the
/// call. Its presses arrive as the server's button events, with root
/// positions.
const TitleBarWindow = struct {
    window: UnmappedWindow = .{ .title_bar = .custom, .window_manager_support = .{ .move_resize = true, .window_menu = true } },
    polled: zui_testing.PolledRecord = .{},
    regions: [6]zui.ChromeRegion = undefined,

    fn open(self: *TitleBarWindow, forced_scale: ?f32) !void {
        try self.window.open(forced_scale);
        self.polled.init();
        _ = self.polled.poll(self.host());
        const viewport = self.polled.builder.params.viewport;
        self.regions = titleBarRegions(viewport[0], viewport[1]);
        var handed = self.regions;
        self.host().zuiChromeRegions(.main, &handed);
        @memset(std.mem.sliceAsBytes(&handed), 0xaa);
    }

    fn close(self: *TitleBarWindow) void {
        self.window.close();
    }

    fn host(self: *TitleBarWindow) *X11Host {
        return self.window.host();
    }

    /// The middle of `part`, in the window's physical pixels.
    fn pointIn(self: *TitleBarWindow, part: Part) [2]i16 {
        const bounds = self.regions[@intFromEnum(part)].bounds;
        const per_unit = self.host().surfaceCoordinatesPerUnit(.main);
        return .{ @intFromFloat((bounds.x + bounds.width / 2) * per_unit), @intFromFloat((bounds.y + bounds.height / 2) * per_unit) };
    }

    fn kindAt(self: *TitleBarWindow, point: [2]i16) ?zui.ChromeKind {
        return self.host().chromeKindAt(.main, .{ @floatFromInt(point[0]), @floatFromInt(point[1]) });
    }

    fn press(self: *TitleBarWindow, point: [2]i16, x_button: u8) void {
        var event = pointerButtonEvent(x11.button_press, mainOf(self.host()).x_window, x_button, point);
        self.host().dispatch(&event);
    }

    fn release(self: *TitleBarWindow, point: [2]i16, x_button: u8) void {
        var event = pointerButtonEvent(x11.button_release, mainOf(self.host()).x_window, x_button, point);
        self.host().dispatch(&event);
    }

    fn click(self: *TitleBarWindow, point: [2]i16) void {
        self.press(point, 1);
        self.release(point, 1);
    }

    fn windowChrome(self: *TitleBarWindow) *x11_chrome.WindowChrome {
        return &mainOf(self.host()).window_chrome;
    }

    fn lastRequest(self: *TitleBarWindow) ?WindowManagerRequest {
        return self.windowChrome().last_request;
    }

    /// Polls, waiting on the server between polls for at most 3 s, until a
    /// poll reports `expected`.
    fn pollUntilReported(self: *TitleBarWindow, expected: zui.EnvironmentChange) !void {
        const window_host = self.host();
        const deadline = window_host.now().addSeconds(3);
        while (window_host.now().isBefore(deadline)) {
            _ = self.polled.poll(window_host);
            for (self.polled.builder.events()) |event| if (event == .environment and std.meta.eql(event.environment, expected)) return;
            window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.005) });
        }
        return error.Timeout;
    }
};

test "on X11 a custom title bar asks the window manager for no decorations and is reported, and a native one asks for nothing and keeps no chrome" {
    var titled: TitleBarWindow = .{};
    try titled.open(2);
    defer titled.close();
    const titled_host = titled.host();
    var hint: [5]u32 = undefined;
    try testing.expectEqualSlices(u32, &x11_chrome.WindowChrome.no_decorations_hint, x11.readCardinals(titled_host.connection, mainOf(titled_host).x_window, titled_host.atoms.motif_wm_hints, &hint));
    const environment = reportedEnvironment(&titled.polled);
    try testing.expect(environment.custom_title_bar);
    try testing.expect(!environment.window_maximized);
    try testing.expectEqual(zui.ChromeKind.title_bar, titled.kindAt(titled.pointIn(.title_bar)).?);
    try testing.expectEqual(@as(?zui.ChromeKind, null), titled.kindAt(titled.pointIn(.search)));
    try testing.expectEqual(zui.ChromeKind.close_button, titled.kindAt(titled.pointIn(.close)).?);
    try testing.expectEqual(zui.ChromeKind.resize_bottom_right, titled.kindAt(titled.pointIn(.grip)).?);

    var window: UnmappedWindow = .{ .window_manager_support = .{ .move_resize = true, .window_menu = true } };
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    try testing.expectEqual(@as(usize, 0), x11.readCardinals(window_host.connection, mainOf(window_host).x_window, window_host.atoms.motif_wm_hints, &hint).len);
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    try testing.expect(!reportedEnvironment(&polled).custom_title_bar);
    var regions = titleBarRegions(320, 240);
    window_host.zuiChromeRegions(.main, &regions);
    try testing.expectEqual(@as(usize, 0), mainOf(window_host).window_chrome.snapshot.count);
    var press = pointerButtonEvent(x11.button_press, mainOf(window_host).x_window, 1, .{ 100, 10 });
    window_host.dispatch(&press);
    _ = polled.poll(window_host);
    try testing.expect(polled.find(.pointer_down) != null);
    try testing.expectEqual(@as(u32, 0), mainOf(window_host).window_chrome.requests_sent);
}

test "on X11 a custom title bar is not reported where the window manager cannot move the window, or once it frames the window itself" {
    var unmovable: TitleBarWindow = .{ .window = .{ .title_bar = .custom, .window_manager_support = .{ .window_menu = true } } };
    try unmovable.open(1);
    defer unmovable.close();
    try testing.expect(!reportedEnvironment(&unmovable.polled).custom_title_bar);
    try testing.expectEqual(@as(?zui.ChromeKind, null), unmovable.kindAt(unmovable.pointIn(.title_bar)));

    var framed: TitleBarWindow = .{};
    try framed.open(1);
    defer framed.close();
    mainOf(framed.host()).onFrameExtents(&.{ 0, 0, 0, 0 });
    try testing.expect(framed.windowChrome().isCustom());
    mainOf(framed.host()).onFrameExtents(&.{ 2, 2, 30, 2 });
    _ = framed.polled.poll(framed.host());
    try testing.expectEqual(false, framed.polled.find(.environment).?.custom_title_bar);
    try testing.expectEqual(@as(?zui.ChromeKind, null), framed.kindAt(framed.pointIn(.title_bar)));
    framed.click(framed.pointIn(.title_bar));
    try testing.expectEqual(@as(u32, 0), framed.windowChrome().requests_sent);
}

test "on X11 a press on the title bar moves the window from its root position, one on an edge resizes it from that edge, and neither press nor release reaches zui" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    const window_host = titled.host();
    _ = titled.polled.poll(window_host);

    const title = titled.pointIn(.title_bar);
    titled.click(title);
    try testing.expectEqual(WindowManagerRequest{ .move_resize = .{ .direction = .move, .root_position = rootPositionOf(title), .x_button = 1 } }, titled.lastRequest().?);
    _ = titled.polled.poll(window_host);
    try testing.expectEqual(@as(?zui.PointerButton, null), titled.polled.find(.pointer_down));
    try testing.expectEqual(@as(?zui.PointerButton, null), titled.polled.find(.pointer_up));

    const edges = [_]struct { zui.ChromeKind, u32 }{
        .{ .resize_top_left, 0 },     .{ .resize_top, 1 },    .{ .resize_top_right, 2 },   .{ .resize_right, 3 },
        .{ .resize_bottom_right, 4 }, .{ .resize_bottom, 5 }, .{ .resize_bottom_left, 6 }, .{ .resize_left, 7 },
    };
    var regions: [edges.len]zui.ChromeRegion = undefined;
    for (edges, &regions, 0..) |edge, *region, index| {
        region.* = .{ .id = index + 1, .bounds = .{ .x = @floatFromInt(index * 20), .y = 100, .width = 10, .height = 10 }, .kind = edge[0] };
    }
    window_host.zuiChromeRegions(.main, &regions);
    for (edges, 0..) |edge, index| {
        const point: [2]i16 = .{ @intCast(index * 20 + 5), 105 };
        titled.click(point);
        const request = titled.lastRequest().?.move_resize;
        try testing.expectEqual(edge[1], @intFromEnum(request.direction));
        try testing.expectEqual(rootPositionOf(point), request.root_position);
    }
    _ = titled.polled.poll(window_host);
    try testing.expectEqual(@as(?zui.PointerButton, null), titled.polled.find(.pointer_down));
    try testing.expectEqual(@as(?zui.PointerButton, null), titled.polled.find(.pointer_up));
}

test "on X11 a secondary press on the title bar shows the window menu where the window manager offers one, and reaches zui where it does not" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    _ = titled.polled.poll(titled.host());
    const title = titled.pointIn(.title_bar);
    titled.press(title, 3);
    titled.release(title, 3);
    try testing.expectEqual(WindowManagerRequest{ .show_window_menu = rootPositionOf(title) }, titled.lastRequest().?);
    _ = titled.polled.poll(titled.host());
    try testing.expectEqual(@as(?zui.PointerButton, null), titled.polled.find(.pointer_down));

    var without_menu: TitleBarWindow = .{ .window = .{ .title_bar = .custom, .window_manager_support = .{ .move_resize = true } } };
    try without_menu.open(1);
    defer without_menu.close();
    _ = without_menu.polled.poll(without_menu.host());
    without_menu.press(title, 3);
    without_menu.release(title, 3);
    try testing.expectEqual(@as(u32, 0), without_menu.windowChrome().requests_sent);
    _ = without_menu.polled.poll(without_menu.host());
    try testing.expectEqual(zui.Button.secondary, without_menu.polled.find(.pointer_down).?.button);
    try testing.expectEqual(zui.Button.secondary, without_menu.polled.find(.pointer_up).?.button);
}

test "on X11 a caption button's press reaches zui and its release cancels it and works the button: minimize iconifies, maximize maximizes and close closes" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    const window_host = titled.host();
    _ = titled.polled.poll(window_host);

    titled.click(titled.pointIn(.minimize));
    try testing.expectEqual(WindowManagerRequest.iconify, titled.lastRequest().?);
    _ = titled.polled.poll(window_host);
    try testing.expect(titled.polled.find(.pointer_down) != null);
    try testing.expect(titled.polled.find(.pointer_cancel) != null);
    try testing.expectEqual(@as(?zui.PointerButton, null), titled.polled.find(.pointer_up));

    titled.click(titled.pointIn(.maximize));
    try testing.expectEqual(WindowManagerRequest.set_maximized, titled.lastRequest().?);

    titled.press(titled.pointIn(.minimize), 1);
    titled.release(titled.pointIn(.search), 1);
    try testing.expectEqual(@as(u32, 2), titled.windowChrome().requests_sent);
    _ = titled.polled.poll(window_host);
    try testing.expect(titled.polled.find(.pointer_cancel) != null);

    try testing.expect(titled.polled.poll(window_host));
    titled.click(titled.pointIn(.close));
    try testing.expect(!titled.polled.poll(window_host));
}

test "on X11 a double click on the title bar maximizes the window, and once _NET_WM_STATE says it is maximized, restores it" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    const window_host = titled.host();
    const title = titled.pointIn(.title_bar);

    titled.click(title);
    titled.click(title);
    try testing.expectEqual(WindowManagerRequest.set_maximized, titled.lastRequest().?);
    try testing.expectEqual(@as(u32, 2), titled.windowChrome().requests_sent);

    const atoms = &window_host.atoms;
    mainOf(window_host).onWindowState(&.{ atoms.net_wm_state_maximized_horz, atoms.net_wm_state_maximized_vert });
    _ = titled.polled.poll(window_host);
    try testing.expect(titled.polled.find(.environment).?.window_maximized);

    titled.click(title);
    try testing.expectEqual(std.meta.Tag(WindowManagerRequest).move_resize, std.meta.activeTag(titled.lastRequest().?));
    titled.click(title);
    try testing.expectEqual(WindowManagerRequest.unset_maximized, titled.lastRequest().?);
    try testing.expectEqual(@as(u32, 4), titled.windowChrome().requests_sent);
}

test "on X11 window_maximized follows the _NET_WM_STATE another client writes, and maximize then asks to restore" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    const window_host = titled.host();
    const host_window = mainOf(window_host).x_window;
    var other = try OtherClient.open();
    defer other.close();
    const atoms = &other.atoms;

    const maximized_states = [_]x11.Atom{ atoms.net_wm_state_maximized_vert, atoms.net_wm_state_maximized_horz };
    _ = x11.xcb_change_property(other.connection, x11.property_mode_replace, host_window, atoms.net_wm_state, x11.atom_atom, 32, maximized_states.len, &maximized_states);
    other.waitUntilServerApplied();
    try titled.pollUntilReported(.{ .window_maximized = true });
    window_host.toggleMaximized();
    try testing.expectEqual(WindowManagerRequest.unset_maximized, titled.lastRequest().?);

    _ = x11.xcb_delete_property(other.connection, host_window, atoms.net_wm_state);
    other.waitUntilServerApplied();
    try titled.pollUntilReported(.{ .window_maximized = false });
    try testing.expect(!titled.windowChrome().maximized);
}

/// A window manager of the test's own, on a connection of its own: it
/// redirects the root window's children, lists what it supports in the
/// root's `_NET_SUPPORTED`, and reads the client messages sent to it.
const StandInWindowManager = struct {
    display: *x11.Display,
    connection: *x11.Connection,
    root: x11.Window,
    atoms: x11.Atoms,

    /// Skips where another client already redirects the root, as a running
    /// window manager does.
    fn open() !StandInWindowManager {
        const display = x11.XOpenDisplay(null) orelse return skipWithoutServer();
        errdefer _ = x11.XCloseDisplay(display);
        const connection = x11.XGetXCBConnection(display).?;
        x11.XSetEventQueueOwner(display, x11.xcb_owns_event_queue);
        const root = x11.screenOf(connection, x11.XDefaultScreen(display)).?.root;
        const event_mask: u32 = x11.event_mask_substructure_redirect | x11.event_mask_substructure_notify;
        if (x11.xcb_request_check(connection, x11.xcb_change_window_attributes_checked(connection, root, x11.window_attribute_event_mask, &event_mask))) |refused| {
            x11.free(refused);
            std.debug.print("skipped: a window manager already redirects the root window (BadAccess), so the test cannot stand in for one\n", .{});
            return error.SkipZigTest;
        }
        const atoms: x11.Atoms = .intern(connection);
        const supported = [_]x11.Atom{ atoms.net_wm_moveresize, atoms.gtk_show_window_menu, atoms.net_wm_state };
        _ = x11.xcb_change_property(connection, x11.property_mode_replace, root, atoms.net_supported, x11.atom_atom, 32, supported.len, &supported);
        var applied: [1]u32 = undefined;
        _ = x11.readCardinals(connection, root, atoms.net_supported, &applied);
        return .{ .display = display, .connection = connection, .root = root, .atoms = atoms };
    }

    fn close(self: *StandInWindowManager) void {
        _ = x11.xcb_delete_property(self.connection, self.root, self.atoms.net_supported);
        _ = x11.xcb_flush(self.connection);
        _ = x11.XCloseDisplay(self.display);
    }

    /// The data of the next client message of `message_type` about
    /// `window`, waiting up to 3 s for it; others are dropped.
    fn nextMessage(self: *StandInWindowManager, window: x11.Window, message_type: x11.Atom) ![5]u32 {
        const pause: std.os.linux.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        var waited_ms: u32 = 0;
        while (waited_ms < 3000) : (waited_ms += 5) {
            while (x11.xcb_poll_for_event(self.connection)) |event| {
                defer x11.free(event);
                if (event.code() != x11.client_message) continue;
                const message: *const x11.ClientMessageEvent = @ptrCast(event);
                if (message.window == window and message.type == message_type) return message.data32;
            }
            _ = std.os.linux.nanosleep(&pause, null);
        }
        return error.Timeout;
    }
};

test "on X11 the window manager is sent each request as EWMH and ICCCM name it, and a frame it draws takes the title bar back" {
    var window_manager = try StandInWindowManager.open();
    defer window_manager.close();
    var titled: TitleBarWindow = .{ .window = .{ .title_bar = .custom } };
    try titled.open(1);
    defer titled.close();
    try testing.expect(reportedEnvironment(&titled.polled).custom_title_bar);
    const window_host = titled.host();
    const host_window = mainOf(window_host).x_window;
    const atoms = &window_manager.atoms;
    const source_application = 1;

    const title = titled.pointIn(.title_bar);
    const title_on_root: [2]u32 = @bitCast(rootPositionOf(title));
    titled.click(title);
    const move_direction = 8;
    try testing.expectEqual([5]u32{ title_on_root[0], title_on_root[1], move_direction, 1, source_application }, try window_manager.nextMessage(host_window, atoms.net_wm_moveresize));

    const grip = titled.pointIn(.grip);
    const grip_on_root: [2]u32 = @bitCast(rootPositionOf(grip));
    titled.click(grip);
    const bottom_right_direction = 4;
    try testing.expectEqual([5]u32{ grip_on_root[0], grip_on_root[1], bottom_right_direction, 1, source_application }, try window_manager.nextMessage(host_window, atoms.net_wm_moveresize));

    titled.press(title, 3);
    titled.release(title, 3);
    try testing.expectEqual([5]u32{ 0, title_on_root[0], title_on_root[1], 0, 0 }, try window_manager.nextMessage(host_window, atoms.gtk_show_window_menu));

    titled.click(titled.pointIn(.minimize));
    const iconic_state = 3;
    try testing.expectEqual([5]u32{ iconic_state, 0, 0, 0, 0 }, try window_manager.nextMessage(host_window, atoms.wm_change_state));

    titled.click(titled.pointIn(.maximize));
    const add_state = 1;
    try testing.expectEqual([5]u32{ add_state, atoms.net_wm_state_maximized_vert, atoms.net_wm_state_maximized_horz, source_application, 0 }, try window_manager.nextMessage(host_window, atoms.net_wm_state));

    const extents = [_]u32{ 2, 2, 30, 2 };
    _ = x11.xcb_change_property(window_manager.connection, x11.property_mode_replace, host_window, atoms.net_frame_extents, x11.atom_cardinal, 32, extents.len, &extents);
    _ = x11.xcb_flush(window_manager.connection);
    try titled.pollUntilReported(.{ .custom_title_bar = false });
    try testing.expectEqual(@as(?zui.ChromeKind, null), titled.kindAt(title));
}

const dbus = zui_host.linux.dbus;
const ibus = zui_host.linux.ibus;

const played_context_path = "/org/freedesktop/IBus/InputContext_7";
const bus_service: dbus.Header = .{ .type = .method_call, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus" };

/// An input method played on the test's session bus under the IBus
/// portal's name, which keeps the calls made of it in order and answers
/// only as a test says.
const PlayedInputMethod = struct {
    bus: dbus.Connection = .{},
    calls: [64]Call = undefined,
    call_count: usize = 0,
    calls_taken: usize = 0,
    reply_serials_seen: [8]u32 = @splat(0),
    replies_seen: usize = 0,

    const Call = struct {
        member: services.Text(32) = .{},
        serial: u32 = 0,
        sender: services.Text(64) = .{},
        arguments: [4]u32 = @splat(0),
    };

    fn open(self: *PlayedInputMethod, address: []const u8) !void {
        const give_up_at = deadlineIn(5);
        try self.bus.open(testing.io, address, give_up_at);
        var hello = bus_service;
        hello.member = "Hello";
        try self.awaitReply(try self.bus.send(testing.io, hello, "", give_up_at));
        var body_buffer: [128]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        body.string(ibus.portal.service);
        const do_not_queue = 4;
        body.uint32(do_not_queue);
        var request_name = bus_service;
        request_name.member = "RequestName";
        request_name.signature = "su";
        try self.awaitReply(try self.bus.send(testing.io, request_name, body_buffer[0..body.len], give_up_at));
    }

    fn close(self: *PlayedInputMethod) void {
        self.bus.close();
    }

    pub fn onMessage(self: *PlayedInputMethod, message: dbus.Message) void {
        const header = message.header;
        if (header.type == .method_return) {
            self.reply_serials_seen[self.replies_seen % self.reply_serials_seen.len] = header.reply_serial orelse 0;
            self.replies_seen += 1;
            return;
        }
        if (header.type != .method_call or self.call_count == self.calls.len) return;
        const interface = header.interface orelse return;
        if (!std.mem.eql(u8, interface, ibus.portal.interface) and !std.mem.eql(u8, interface, ibus.context_interface)) return;
        var call: Call = .{ .serial = header.serial };
        _ = call.member.set(header.member orelse "");
        _ = call.sender.set(header.sender orelse "");
        var body = message.body;
        for (header.signature, 0..) |code, index| {
            if (index == call.arguments.len or (code != 'u' and code != 'i')) break;
            call.arguments[index] = body.uint32() catch break;
        }
        self.calls[self.call_count] = call;
        self.call_count += 1;
    }

    fn awaitReply(self: *PlayedInputMethod, serial: u32) !void {
        const give_up_at = deadlineIn(5);
        while (std.mem.indexOfScalar(u32, &self.reply_serials_seen, serial) == null) {
            if (!self.bus.waitFor(testing.io, std.os.linux.POLL.IN, give_up_at)) return error.Timeout;
            try self.bus.receive(self);
        }
    }

    /// The next call the host made of the input method, which must be a
    /// call of `member`.
    fn expectCall(self: *PlayedInputMethod, member: []const u8) !Call {
        const give_up_at = deadlineIn(5);
        while (self.calls_taken == self.call_count) {
            if (!self.bus.waitFor(testing.io, std.os.linux.POLL.IN, give_up_at)) return error.Timeout;
            try self.bus.receive(self);
        }
        defer self.calls_taken += 1;
        const call = self.calls[self.calls_taken];
        try testing.expectEqualStrings(member, call.member.slice());
        return call;
    }

    fn reply(self: *PlayedInputMethod, call: *const Call, signature: []const u8, body: []const u8) !void {
        _ = try self.bus.send(testing.io, .{ .type = .method_return, .reply_serial = call.serial, .destination = call.sender.slice(), .signature = signature }, body, deadlineIn(1));
    }

    fn answerKey(self: *PlayedInputMethod, call: *const Call, consumed: bool) !void {
        var body_buffer: [8]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        body.boolean(consumed);
        try self.reply(call, "b", body_buffer[0..body.len]);
    }

    fn commit(self: *PlayedInputMethod, text: []const u8) !void {
        var body_buffer: [512]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        ibus.writeText(&body, text);
        _ = try self.bus.send(testing.io, .{ .type = .signal, .path = played_context_path, .interface = ibus.context_interface, .member = "CommitText", .signature = "v" }, body_buffer[0..body.len], deadlineIn(1));
    }
};

fn deadlineIn(seconds: f64) zui.Instant {
    return zui.Instant.fromTimestamp(std.Io.Timestamp.now(testing.io, .awake)).addSeconds(seconds);
}

/// What the polls since it was made reported: the text typed and the
/// evdev codes of the keys, in order.
const Reported = struct {
    text: [256]u8 = undefined,
    text_len: usize = 0,
    keys_down: [32]u32 = undefined,
    keys_down_count: usize = 0,
    keys_up_count: usize = 0,

    fn typed(self: *const Reported) []const u8 {
        return self.text[0..self.text_len];
    }

    fn pressed(self: *const Reported) []const u32 {
        return self.keys_down[0..self.keys_down_count];
    }
};

/// A window on the test's session bus, its context made by the played
/// input method and focused at a caret, at a scale of 2.
const InputMethodWindow = struct {
    window: UnmappedWindow = .{},
    played: PlayedInputMethod = .{},
    polled: zui_testing.PolledRecord = .{},
    reported: Reported = .{},

    const caret: zui.Rect = .{ .x = 10, .y = 20, .width = 1, .height = 16 };

    fn open(self: *InputMethodWindow) !void {
        const address = std.mem.span(std.c.getenv("ZUI_HOST_TEST_SESSION_BUS") orelse return error.SkipZigTest);
        try self.played.open(address);
        errdefer self.played.close();
        self.window.input_method_bus = address;
        try self.window.open(2);
        errdefer self.window.close();
        if (self.host().keymap == null) {
            std.debug.print("skipped: the X server offers no XKB keymap\n", .{});
            return error.SkipZigTest;
        }
        self.polled.init();
        _ = self.polled.poll(self.host());

        const created = try self.played.expectCall("CreateInputContext");
        var body_buffer: [64]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        body.string(played_context_path);
        try self.played.reply(&created, "o", body_buffer[0..body.len]);
        try self.pumpUntil(isReady);
        try testing.expectEqual(ibus.capabilities, (try self.played.expectCall("SetCapabilities")).arguments[0]);
    }

    fn close(self: *InputMethodWindow) void {
        self.window.close();
        self.played.close();
    }

    fn host(self: *InputMethodWindow) *X11Host {
        return self.window.host();
    }

    fn askForTextInput(self: *InputMethodWindow, at: ?zui.Rect) void {
        self.host().zuiApply(.main, .{ .text_input = if (at) |rect| .{ .caret = rect } else null });
    }

    /// Focuses the window and asks for text input at `caret`, which the
    /// input method must be told.
    fn focusAtCaret(self: *InputMethodWindow) !void {
        self.host().onFocus(mainOf(self.host()), true);
        self.askForTextInput(caret);
        _ = try self.played.expectCall("FocusIn");
        _ = try self.played.expectCall("SetCursorLocation");
    }

    /// Waits a moment for what the buses send, and polls.
    fn pump(self: *InputMethodWindow) void {
        const window_host = self.host();
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.005) });
        _ = self.polled.poll(window_host);
        const reported = &self.reported;
        for (self.polled.builder.events()) |event| switch (event) {
            .text => |text| {
                @memcpy(reported.text[reported.text_len..][0..text.len], text);
                reported.text_len += text.len;
            },
            .key_down => |key| {
                reported.keys_down[reported.keys_down_count] = key.scancode;
                reported.keys_down_count += 1;
            },
            .key_up => reported.keys_up_count += 1,
            else => {},
        };
    }

    fn pumpUntil(self: *InputMethodWindow, comptime condition: fn (*InputMethodWindow) bool) !void {
        const give_up_at = deadlineIn(5);
        while (!condition(self)) {
            if (!self.host().now().isBefore(give_up_at)) return error.Timeout;
            self.pump();
        }
    }

    fn pumpFor(self: *InputMethodWindow, seconds: f64) void {
        const until = self.host().now().addSeconds(seconds);
        while (self.host().now().isBefore(until)) self.pump();
    }

    fn evdevCodeOf(self: *InputMethodWindow, key: zui.Key) u32 {
        return keycodeOf(self.host(), key).? - 8;
    }

    fn press(self: *InputMethodWindow, key: zui.Key, pressed: bool) void {
        self.host().onKey(keycodeOf(self.host(), key).?, pressed);
    }

    fn isReady(self: *InputMethodWindow) bool {
        return self.host().input_context.phase == .ready;
    }
};

fn requestsSent(input_method_window: *InputMethodWindow) u32 {
    return input_method_window.host().input_context.requests_sent;
}

test "on X11 the session's input method is asked for a context at init, and focus and the caret in root coordinates follow the frames, each sent once" {
    var tested: InputMethodWindow = .{};
    try tested.open();
    defer tested.close();
    const window_host = tested.host();

    tested.askForTextInput(InputMethodWindow.caret);
    window_host.onFocus(mainOf(window_host), true);
    _ = try tested.played.expectCall("FocusIn");
    const origin = mainOf(window_host).origin_on_root.?;
    const located = try tested.played.expectCall("SetCursorLocation");
    try testing.expectEqual([4]u32{ @bitCast(origin[0] + 20), @bitCast(origin[1] + 40), 2, 32 }, located.arguments);

    const sent = requestsSent(&tested);
    tested.askForTextInput(InputMethodWindow.caret);
    tested.pump();
    try testing.expectEqual(sent, requestsSent(&tested));

    tested.askForTextInput(.{ .x = 30, .y = 20, .width = 1, .height = 16 });
    try testing.expectEqual(@as(u32, @bitCast(origin[0] + 60)), (try tested.played.expectCall("SetCursorLocation")).arguments[0]);
    tested.askForTextInput(null);
    _ = try tested.played.expectCall("FocusOut");

    window_host.onFocus(mainOf(window_host), false);
    tested.askForTextInput(InputMethodWindow.caret);
    const unfocused_sent = requestsSent(&tested);
    tested.pump();
    try testing.expectEqual(unfocused_sent, requestsSent(&tested));
    window_host.onFocus(mainOf(window_host), true);
    _ = try tested.played.expectCall("FocusIn");
    _ = try tested.played.expectCall("SetCursorLocation");
}

test "on X11 a key the input method consumes reaches the record as a key and types nothing, one it does not types, and committed text is typed once" {
    var tested: InputMethodWindow = .{};
    try tested.open();
    defer tested.close();
    try tested.focusAtCaret();

    tested.press(.a, true);
    tested.pump();
    try testing.expectEqual(@as(usize, 0), tested.reported.keys_down_count);
    const pressed = try tested.played.expectCall("ProcessKeyEvent");
    try testing.expectEqual(@as(u32, 'a'), pressed.arguments[0]);
    try testing.expectEqual(tested.evdevCodeOf(.a), pressed.arguments[1]);
    try testing.expectEqual(@as(u32, 0), pressed.arguments[2] & ibus.release_mask);
    try tested.played.answerKey(&pressed, true);
    try tested.pumpUntil(struct {
        fn pressedOne(input_method_window: *InputMethodWindow) bool {
            return input_method_window.reported.keys_down_count == 1;
        }
    }.pressedOne);

    tested.press(.a, false);
    const released = try tested.played.expectCall("ProcessKeyEvent");
    try testing.expect(released.arguments[2] & ibus.release_mask != 0);
    try tested.played.answerKey(&released, false);
    tested.press(.b, true);
    try tested.played.answerKey(&(try tested.played.expectCall("ProcessKeyEvent")), false);
    try tested.pumpUntil(struct {
        fn typedB(input_method_window: *InputMethodWindow) bool {
            return input_method_window.reported.text_len > 0;
        }
    }.typedB);
    try testing.expectEqualStrings("b", tested.reported.typed());
    try testing.expectEqual(@as(usize, 1), tested.reported.keys_up_count);

    try tested.played.commit("\u{4f60}\u{597d}");
    try tested.pumpUntil(struct {
        fn committed(input_method_window: *InputMethodWindow) bool {
            return input_method_window.reported.text_len > 1;
        }
    }.committed);
    tested.pumpFor(0.05);
    try testing.expectEqualStrings("b\u{4f60}\u{597d}", tested.reported.typed());
    try testing.expectEqualSlices(u32, &.{ tested.evdevCodeOf(.a), tested.evdevCodeOf(.b) }, tested.reported.pressed());
}

test "on X11 keys the input method does not answer within the bound are typed in order, it is passed over until it answers, and then asked again" {
    var tested: InputMethodWindow = .{};
    try tested.open();
    defer tested.close();
    try tested.focusAtCaret();

    const held_at = tested.host().now();
    tested.press(.c, true);
    tested.press(.d, true);
    const first = try tested.played.expectCall("ProcessKeyEvent");
    const second = try tested.played.expectCall("ProcessKeyEvent");
    try tested.pumpUntil(struct {
        fn typedBoth(input_method_window: *InputMethodWindow) bool {
            return input_method_window.reported.text_len == 2;
        }
    }.typedBoth);
    const waited_ns = tested.host().now().nanoseconds - held_at.nanoseconds;
    try testing.expect(waited_ns >= ibus.InputContext.answer_bound_ns);
    try testing.expect(waited_ns < 4 * ibus.InputContext.answer_bound_ns);
    try testing.expectEqualStrings("cd", tested.reported.typed());
    try testing.expectEqualSlices(u32, &.{ tested.evdevCodeOf(.c), tested.evdevCodeOf(.d) }, tested.reported.pressed());
    try testing.expect(!tested.host().input_context.answering);

    const sent = requestsSent(&tested);
    tested.press(.e, true);
    tested.pump();
    try testing.expectEqualStrings("cde", tested.reported.typed());
    try testing.expectEqual(sent, requestsSent(&tested));

    try tested.played.answerKey(&first, true);
    try tested.played.answerKey(&second, true);
    try tested.pumpUntil(struct {
        fn answering(input_method_window: *InputMethodWindow) bool {
            return input_method_window.host().input_context.answering;
        }
    }.answering);
    try testing.expectEqualStrings("cde", tested.reported.typed());
    tested.press(.f, true);
    _ = try tested.played.expectCall("ProcessKeyEvent");
}

test "on X11 an input method that leaves the bus while it holds a key leaves typing to the keymap, the key typed without waiting for the bound" {
    var tested: InputMethodWindow = .{};
    try tested.open();
    defer tested.close();
    try tested.focusAtCaret();

    tested.press(.g, true);
    _ = try tested.played.expectCall("ProcessKeyEvent");
    const left_at = tested.host().now();
    tested.played.close();
    try tested.pumpUntil(struct {
        fn typed(input_method_window: *InputMethodWindow) bool {
            return input_method_window.reported.text_len == 1;
        }
    }.typed);
    try testing.expect(tested.host().now().nanoseconds - left_at.nanoseconds < ibus.InputContext.answer_bound_ns);
    try tested.pumpUntil(struct {
        fn closed(input_method_window: *InputMethodWindow) bool {
            return input_method_window.host().input_context.phase == .closed;
        }
    }.closed);

    tested.press(.h, true);
    tested.pump();
    try testing.expectEqualStrings("gh", tested.reported.typed());
}

test "on X11 without an input method on the session bus, keys type through the keymap at once" {
    const address = std.mem.span(std.c.getenv("ZUI_HOST_TEST_SESSION_BUS") orelse return error.SkipZigTest);
    var window: UnmappedWindow = .{ .input_method_bus = address };
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    if (window_host.keymap == null) return error.SkipZigTest;
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    const give_up_at = deadlineIn(5);
    while (window_host.input_context.phase == .creating) {
        if (!window_host.now().isBefore(give_up_at)) return error.Timeout;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.005) });
        _ = polled.poll(window_host);
    }
    try testing.expectEqual(ibus.InputContext.Phase.closed, window_host.input_context.phase);
    window_host.onFocus(mainOf(window_host), true);
    window_host.zuiApply(.main, .{ .text_input = .{ .caret = InputMethodWindow.caret } });
    window_host.onKey(keycodeOf(window_host, .z).?, true);
    _ = polled.poll(window_host);
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("z", typedText(&polled, &buffer));
}

test "with ZUI_HOST_TEST_SHOWN_WINDOW set, keys typed into a shown X11 window go through the session's input method, which answers each within the bound" {
    _ = std.c.getenv("ZUI_HOST_TEST_SHOWN_WINDOW") orelse return error.SkipZigTest;
    var window_host: X11Host = undefined;
    window_host.forced_scale = 1;
    window_host.bus_addresses = null;
    window_host.service_fake = null;
    window_host.forced_window_manager_support = null;
    window_host.input_method_bus = null;
    window_host.init(testing.io, .{ .title = "zui host suite: input method", .size = .{ 320, 240 } }) catch |err| switch (err) {
        error.NoX11Display => return skipWithoutServer(),
        else => return err,
    };
    defer window_host.deinit();
    if (window_host.keymap == null) return error.SkipZigTest;
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    const give_up_at = deadlineIn(3);
    const focus_given_up_at = deadlineIn(1);
    while (window_host.input_context.phase == .creating or (!mainOf(&window_host).focused and window_host.now().isBefore(focus_given_up_at))) {
        if (!window_host.now().isBefore(give_up_at)) return error.Timeout;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.01) });
        _ = polled.poll(&window_host);
    }
    if (window_host.input_context.phase != .ready) {
        std.debug.print("skipped: no input method serves org.freedesktop.portal.IBus on the session bus\n", .{});
        return error.SkipZigTest;
    }
    if (!mainOf(&window_host).focused) {
        // The input method takes its focus from the context, not from the server.
        std.debug.print("note: the window manager did not focus the window, so the test focuses it as the server would\n", .{});
        window_host.onFocus(mainOf(&window_host), true);
    }
    window_host.zuiApply(.main, .{ .text_input = .{ .caret = .{ .x = 20, .y = 20, .width = 1, .height = 16 } } });
    try testing.expect(window_host.input_context.focused);

    var typed: [32]u8 = undefined;
    var typed_len: usize = 0;
    for ([_]zui.Key{ .z, .u, .i }) |key| {
        window_host.onKey(keycodeOf(&window_host, key).?, true);
        window_host.onKey(keycodeOf(&window_host, key).?, false);
    }
    while (window_host.input_context.answerDeadline() != null) {
        if (!window_host.now().isBefore(give_up_at.addSeconds(2))) return error.Timeout;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.005) });
        _ = polled.poll(&window_host);
        const text = typedText(&polled, typed[typed_len..]);
        typed_len += text.len;
    }
    _ = polled.poll(&window_host);
    typed_len += typedText(&polled, typed[typed_len..]).len;
    try testing.expect(window_host.input_context.answering);
    try testing.expectEqualStrings("zui", typed[0..typed_len]);
}

const second_window_options: zui.WindowOptions = .{ .title = "zui host suite on X11, second window", .size = .{ 320, 240 }, .visible = false };

fn keyEvent(code: u8, window: x11.Window, x_keycode: u8) x11.GenericEvent {
    return pointerButtonEvent(code, window, x_keycode, .{ 0, 0 });
}

test "on X11 a second window opens with an X window of its own, its close button closes it alone, and closing it frees its id" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const second = try window_host.zuiOpenWindow(second_window_options);
    try testing.expect(second != .main);
    const second_window = window_host.windowById(second).?;
    try testing.expect(second_window.x_window != mainOf(window_host).x_window);
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    try testing.expect(polled.pollWindow(window_host, second));
    try testing.expectEqual([2]f32{ 320, 240 }, polled.builder.params.viewport);
    try testing.expectEqual(@as(usize, 10), countOf(&polled, .environment));

    var event = std.mem.zeroes(x11.GenericEvent);
    const message: *x11.ClientMessageEvent = @ptrCast(&event);
    message.* = .{ .response_type = x11.client_message, .format = 32, .sequence = 0, .window = second_window.x_window, .type = window_host.atoms.wm_protocols, .data32 = .{ window_host.atoms.wm_delete_window, 0, 0, 0, 0 } };
    window_host.dispatch(&event);
    try testing.expect(!polled.pollWindow(window_host, second));
    try testing.expect(polled.poll(window_host));
    window_host.zuiCloseWindow(second);
    try testing.expectEqual(null, window_host.windowById(second));
    try testing.expect(!polled.pollWindow(window_host, second));
    try testing.expect(polled.poll(window_host));
}

test "on X11 the pointer's events reach the window they name, and keys the window with the keyboard's focus" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    if (window_host.keymap == null) {
        std.debug.print("skipped: the X server offers no XKB keymap\n", .{});
        return error.SkipZigTest;
    }
    const second = try window_host.zuiOpenWindow(second_window_options);
    const main_x_window = mainOf(window_host).x_window;
    const second_x_window = window_host.windowById(second).?.x_window;
    var first_polled: zui_testing.PolledRecord = .{};
    first_polled.init();
    var second_polled: zui_testing.PolledRecord = .{};
    second_polled.init();
    _ = first_polled.poll(window_host);
    _ = second_polled.pollWindow(window_host, second);

    var focus_in = focusEvent(x11.focus_in, main_x_window, 0);
    window_host.dispatch(&focus_in);
    var press = pointerButtonEvent(x11.button_press, second_x_window, 1, .{ 30, 40 });
    var release = pointerButtonEvent(x11.button_release, second_x_window, 1, .{ 30, 40 });
    window_host.dispatch(&press);
    window_host.dispatch(&release);
    var key_a = keyEvent(x11.key_press, main_x_window, keycodeOf(window_host, .a).?);
    window_host.dispatch(&key_a);
    _ = first_polled.poll(window_host);
    _ = second_polled.pollWindow(window_host, second);
    try testing.expectEqual(@as(?zui.PointerButton, null), first_polled.find(.pointer_down));
    try testing.expectEqual(zui.Key.a, first_polled.find(.key_down).?.key);
    try testing.expectEqual(true, first_polled.find(.environment).?.window_focused);
    try testing.expectEqual([2]f32{ 30, 40 }, second_polled.find(.pointer_down).?.pointer.position);
    try testing.expect(second_polled.find(.pointer_up) != null);
    try testing.expectEqual(@as(?zui.KeyEvent, null), second_polled.find(.key_down));

    var focus_out = focusEvent(x11.focus_out, main_x_window, 0);
    window_host.dispatch(&focus_out);
    var second_focus_in = focusEvent(x11.focus_in, second_x_window, 0);
    window_host.dispatch(&second_focus_in);
    var key_b = keyEvent(x11.key_press, second_x_window, keycodeOf(window_host, .b).?);
    window_host.dispatch(&key_b);
    _ = first_polled.poll(window_host);
    _ = second_polled.pollWindow(window_host, second);
    try testing.expectEqual(zui.EnvironmentChange{ .window_focused = false }, first_polled.find(.environment).?);
    try testing.expectEqual(@as(?zui.KeyEvent, null), first_polled.find(.key_down));
    try testing.expectEqual(zui.EnvironmentChange{ .window_focused = true }, second_polled.find(.environment).?);
    try testing.expectEqual(zui.Key.b, second_polled.find(.key_down).?.key);

    var leave = std.mem.zeroes(x11.GenericEvent);
    const crossing: *x11.CrossingEvent = @ptrCast(&leave);
    crossing.response_type = x11.leave_notify;
    crossing.event = main_x_window;
    window_host.dispatch(&leave);
    _ = second_polled.pollWindow(window_host, second);
    try testing.expectEqual(@as(?zui.PointerId, null), second_polled.find(.pointer_leave));
    crossing.event = second_x_window;
    window_host.dispatch(&leave);
    _ = second_polled.pollWindow(window_host, second);
    try testing.expectEqual(zui.PointerId.mouse, second_polled.find(.pointer_leave).?);
}

test "on X11 past the windows the host holds, one more is refused, and after one closes a new one opens with a new id" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    try testing.expectEqual(@as(usize, 4), X11Host.max_windows);
    try testing.expectEqual(.many, X11Host.zui_capabilities.windows);
    var opened: [X11Host.max_windows - 1]zui.WindowId = undefined;
    for (&opened) |*id| id.* = try window_host.zuiOpenWindow(second_window_options);
    try testing.expectError(error.TooManyWindows, window_host.zuiOpenWindow(second_window_options));

    window_host.zuiCloseWindow(opened[1]);
    const reopened = try window_host.zuiOpenWindow(second_window_options);
    for (opened) |id| try testing.expect(reopened != id);
    try testing.expect(reopened != .main);
}

const DialogReplies = struct {
    replies: [4]zui.ServiceReply(1024) = undefined,
    count: usize = 0,

    pub fn publish(self: *DialogReplies, reply: zui.ServiceReply(1024)) error{Full}!zui.Wake {
        if (self.count == self.replies.len) return error.Full;
        self.replies[self.count] = reply;
        self.count += 1;
        return .needed;
    }
};

test "on X11 with the main window closed, the clipboard is still owned, written and read, and a dialog over another window answers naming it" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var other: OtherClient = try .open();
    defer other.close();
    const second = try window_host.zuiOpenWindow(second_window_options);
    window_host.zuiCloseWindow(.main);
    try testing.expectEqual(null, window_host.windowById(.main));

    var pasted: ClipboardReplies = .{};
    try X11Host.zuiClipboard.write(window_host, "still here");
    try X11Host.zuiClipboard.read(window_host, .of("paste"), .of(&pasted));
    try testing.expectEqualStrings("still here", pasted.last().text());
    var dialogs: DialogReplies = .{};
    try testing.expectError(error.Unavailable, X11Host.zuiFileDialogs.show(window_host, .main, .of("open"), .{}, .of(&dialogs)));
    window.service_fake.scriptFileDialog("/zui/theme.zon\x00");
    try X11Host.zuiFileDialogs.show(window_host, second, .of("open"), .{}, .of(&dialogs));

    other.convert(other.atoms.clipboard, other.atoms.utf8_string);
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    const deadline = window_host.now().addSeconds(3);
    while (other.notified == null or dialogs.count == 0) {
        if (!window_host.now().isBefore(deadline)) return error.Timeout;
        try testing.expect(polled.pollWindow(window_host, second));
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.005) });
        other.receive();
    }
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("still here", other.converted(&buffer).value);
    try testing.expectEqual(second, dialogs.replies[0].window);
    try testing.expectEqual(.files_chosen, dialogs.replies[0].kind);
}

test "on X11 a terminate request reaches every window, and each then reports itself closed" {
    var window: UnmappedWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    if (!window_host.handlesSignal(.INT)) {
        std.debug.print("skipped: SIGINT already has a handler in this process\n", .{});
        return error.SkipZigTest;
    }
    const second = try window_host.zuiOpenWindow(second_window_options);
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    _ = polled.pollWindow(window_host, second);

    try std.posix.raise(.INT);
    window_host.zuiWait(.{ .at = window_host.now().addSeconds(2) });
    for ([_]zui.WindowId{ .main, second }) |id| {
        try testing.expect(polled.pollWindow(window_host, id));
        try testing.expectEqual(zui.Lifecycle.terminate_requested, polled.find(.lifecycle).?);
        try testing.expect(!polled.pollWindow(window_host, id));
    }
}

test "on X11 each window keeps its own chrome regions, and a press on one window's title bar moves that window alone" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    const window_host = titled.host();
    var second_options = second_window_options;
    second_options.title_bar = .custom;
    const second = try window_host.zuiOpenWindow(second_options);
    var second_polled: zui_testing.PolledRecord = .{};
    second_polled.init();
    _ = second_polled.pollWindow(window_host, second);
    try testing.expect(reportedEnvironment(&second_polled).custom_title_bar);
    var close_at_left = [_]zui.ChromeRegion{.{ .id = 1, .bounds = .{ .width = 30, .height = title_bar_height }, .kind = .close_button }};
    window_host.zuiChromeRegions(second, &close_at_left);

    const on_title_bar = titled.pointIn(.title_bar);
    const on_title_bar_pixels: [2]f32 = .{ @floatFromInt(on_title_bar[0]), @floatFromInt(on_title_bar[1]) };
    try testing.expectEqual(zui.ChromeKind.title_bar, window_host.chromeKindAt(.main, on_title_bar_pixels).?);
    try testing.expectEqual(@as(?zui.ChromeKind, null), window_host.chromeKindAt(second, on_title_bar_pixels));
    try testing.expectEqual(zui.ChromeKind.close_button, window_host.chromeKindAt(second, .{ 10, 10 }).?);
    try testing.expectEqual(zui.ChromeKind.title_bar, window_host.chromeKindAt(.main, .{ 10, 10 }).?);

    const second_window = window_host.windowById(second).?;
    var press = pointerButtonEvent(x11.button_press, second_window.x_window, 1, on_title_bar);
    window_host.dispatch(&press);
    _ = second_polled.pollWindow(window_host, second);
    try testing.expect(second_polled.find(.pointer_down) != null);
    try testing.expectEqual(@as(u32, 0), titled.windowChrome().requests_sent);
    try testing.expectEqual(@as(u32, 0), second_window.window_chrome.requests_sent);

    var release = pointerButtonEvent(x11.button_release, second_window.x_window, 1, on_title_bar);
    window_host.dispatch(&release);
    titled.click(on_title_bar);
    try testing.expectEqual(WindowManagerRequest{ .move_resize = .{ .direction = .move, .root_position = rootPositionOf(on_title_bar), .x_button = 1 } }, titled.lastRequest().?);
    try testing.expectEqual(@as(u32, 0), second_window.window_chrome.requests_sent);
}

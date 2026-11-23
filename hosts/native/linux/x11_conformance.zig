const std = @import("std");
const zui_host = @import("zui_host");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const X11Host = zui_host.linux.X11Host;
const x11 = zui_host.linux.x11;
const services = zui_host.linux.services;
const desktop_bus = zui_host.linux.desktop_bus;

const testing = std.testing;

const no_buses: desktop_bus.Addresses = .{ .session = null, .system = null };

/// An X11 window that is never mapped, so the server never shows it.
const UnmappedWindow = struct {
    window_host: X11Host = undefined,
    service_fake: services.ServiceFake = .{},

    /// With `forced_scale` set, a physical pixel is that many layout units
    /// at a zoom of 1. The window reads no bus, so its environment starts
    /// at zui's defaults.
    fn open(self: *UnmappedWindow, forced_scale: ?f32) !void {
        self.window_host.forced_scale = forced_scale;
        self.window_host.bus_addresses = no_buses;
        self.window_host.service_fake = &self.service_fake;
        self.window_host.init(testing.io, .{ .title = "zui host suite on X11", .size = .{ 320, 240 }, .visible = false }) catch |err| switch (err) {
            error.NoX11Display => return skipWithoutServer(),
            else => return err,
        };
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

/// Delivers each event the suite posts as the X server would, at the
/// physical pixels the last poll's scale and zoom put it at.
const ServerHarness = struct {
    window: UnmappedWindow = .{},

    pub fn host(self: *ServerHarness) *X11Host {
        return self.window.host();
    }

    pub fn post(self: *ServerHarness, event: zui.Event) bool {
        const window_host = self.host();
        switch (event) {
            .pointer_move => |move| window_host.onPointerMotion(physicalPixels(window_host, move.pointer.position)),
            .pointer_down, .pointer_up => |press| window_host.onButton(1, event == .pointer_down, physicalPixels(window_host, press.pointer.position)),
            .key_down, .key_up => |key| window_host.onKey(keycodeOf(window_host, key.key) orelse return false, event == .key_down),
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

fn physicalPixels(window_host: *X11Host, position: [2]f32) [2]f32 {
    const per_unit = window_host.surfaceCoordinatesPerUnit(.main);
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
    try testing.expectEqual(@as(usize, 9), countOf(&polled, .environment));
    try testing.expectEqual(zui.Surface{ .x11 = .{ .display = window.host().display, .window = window.host().window.id } }, window.host().zuiSurface(.main));
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

    window_host.onFocus(true);
    window_host.onFocus(false);
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
    _ = x11.xcb_configure_window(window_host.connection, window_host.window.id, x11.configure_width | x11.configure_height, &size);
    window_host.zuiWait(.{ .at = window_host.now().addSeconds(2) });
    try testing.expect(polled.poll(window_host));
    try testing.expectEqual([2]f32{ 400, 300 }, polled.builder.params.viewport);

    window_host.onConfigure(400, 300);
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
    const id = window_host.window.id;
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
    message.* = .{ .response_type = x11.client_message, .format = 32, .sequence = 0, .window = window_host.window.id, .type = window_host.atoms.wm_protocols, .data32 = .{ window_host.atoms.net_wm_name, 0, 0, 0, 0 } };
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

    window_host.onPointerEnter(.{ 5, 6 });
    window_host.onPointerLeave();
    _ = polled.poll(window_host);
    try testing.expectEqual([2]f32{ 5, 6 }, polled.find(.pointer_move).?.pointer.position);
    try testing.expectEqual(zui.PointerId.mouse, polled.find(.pointer_leave).?);

    window_host.zuiApply(.main, .{ .cursor = .text });
    const shown = window_host.shownCursor().?;
    window_host.zuiApply(.main, .{ .cursor = .default });
    window_host.zuiApply(.main, .{ .cursor = .text });
    try testing.expectEqual(shown, window_host.shownCursor().?);
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
            try testing.expectError(error.TooManyWindows, host.zuiOpenWindow(.{ .visible = false }));
            try testing.expectError(error.Unavailable, zui_host.Host.zuiClipboard.write(&host, "refused"));
            host.zuiChromeRegions(.main, &.{});
            try testing.expectEqual(@as(?zui.ChromeKind, null), host.chromeKindAt(.main, .{ 1, 1 }));
        }
    }
}

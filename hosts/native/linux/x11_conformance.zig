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
        _ = x11.xcb_flush(self.connection);
    }

    /// Watches the host's window's properties, as an `INCR` owner does to
    /// learn when its chunks are taken.
    fn watchPropertiesOf(self: *OtherClient, window: x11.Window) void {
        const event_mask: u32 = x11.event_mask_property_change;
        _ = x11.xcb_change_window_attributes(self.connection, window, x11.window_attribute_event_mask, &event_mask);
        _ = x11.xcb_flush(self.connection);
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
    other.watchPropertiesOf(window_host.window.id);
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
    cleared.* = .{ .response_type = x11.selection_clear, .pad0 = 0, .sequence = 0, .time = 0, .owner = window_host.window.id, .selection = window_host.atoms.clipboard };
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
    const host_window = window_host.window.id;
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
    const host_window = window_host.window.id;
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

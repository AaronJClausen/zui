//! zui's host suite and the Linux host's own tests, each against a window
//! the compositor never shows: a surface without a role. Events are
//! delivered to the host's handlers as the compositor's would be, so each
//! one has reached the host before the test polls. Without a Wayland
//! compositor to connect to, every Wayland test is skipped.

const std = @import("std");
const zui_host = @import("zui_host");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const Host = zui_host.linux.WaylandHost;
const keys = zui_host.linux.keys;
const desktop_bus = zui_host.linux.desktop_bus;
const services = zui_host.linux.services;

const testing = std.testing;

const UnshownWindow = struct {
    window_host: Host = undefined,
    service_fake: services.ServiceFake = .{},
    /// False hands services to the session bus, which the window reads
    /// only through `openReading`.
    fakes_services: bool = true,
    title_bar: zui.TitleBar = .native,
    /// True gives the surface a toplevel's role, which the compositor
    /// configures but, without a buffer, still never shows.
    has_toplevel: bool = false,
    material: zui.SystemMaterial = .none,
    /// What the compositor is played to offer to blur through; null binds
    /// what it advertises.
    blur_offers: ?zui_host.linux.material.BlurOffers = .{},
    system_material_unavailable: bool = false,

    /// With `forced_scale` set, a surface coordinate is that many layout
    /// units at a zoom of 1 and a buffer scale of 1. The window reads no
    /// bus, so its environment starts at zui's defaults.
    fn open(self: *UnshownWindow, forced_scale: ?f32) !void {
        return self.openReading(forced_scale, .{ .session = null, .system = null });
    }

    /// Null reads the session's and the system's buses.
    fn openReading(self: *UnshownWindow, forced_scale: ?f32, bus_addresses: ?desktop_bus.Addresses) !void {
        self.window_host.forced_scale = forced_scale;
        self.window_host.bus_addresses = bus_addresses;
        self.window_host.service_fake = if (self.fakes_services) &self.service_fake else null;
        self.window_host.forced_blur_offers = self.blur_offers;
        self.window_host.system_material_unavailable = self.system_material_unavailable;
        self.window_host.init(testing.io, .{ .title = "zui host suite", .size = .{ 320, 240 }, .visible = self.has_toplevel, .title_bar = self.title_bar, .material = self.material }) catch |err| switch (err) {
            error.NoWaylandDisplay => {
                std.debug.print("skipped: no Wayland compositor to connect to (WAYLAND_DISPLAY and XDG_RUNTIME_DIR)\n", .{});
                return error.SkipZigTest;
            },
            else => return err,
        };
        if (self.window_host.keymap == null) try self.window_host.useKeymap(null);
        // As if the seat's pointer and keyboard were already in the window,
        // without the events entering it reports.
        self.window_host.pointer_window = self.main();
        self.window_host.keyboard_window = self.main();
    }

    fn close(self: *UnshownWindow) void {
        self.window_host.deinit();
    }

    fn host(self: *UnshownWindow) *Host {
        return &self.window_host;
    }

    fn main(self: *UnshownWindow) *Host.Window {
        return mainOf(&self.window_host);
    }
};

fn mainOf(window_host: *Host) *Host.Window {
    return window_host.windowById(.main).?;
}

/// Delivers each event the suite posts as the compositor would, at the
/// surface coordinates the last poll's scale and zoom put it at, first
/// moving the pointer or the keyboard into the window it is posted to.
const CompositorHarness = struct {
    window: UnshownWindow = .{},

    pub fn host(self: *CompositorHarness) *Host {
        return self.window.host();
    }

    pub fn post(self: *CompositorHarness, event: zui.Event) bool {
        return self.postTo(.main, event);
    }

    pub fn postTo(self: *CompositorHarness, id: zui.WindowId, event: zui.Event) bool {
        const window_host = self.host();
        const target = window_host.windowById(id) orelse return false;
        switch (event) {
            .pointer_move => |move| {
                const position = surfaceCoordinates(target, move.pointer.position);
                if (window_host.pointer_window == target) window_host.onPointerMotion(position) else enterWithPointer(window_host, target, position);
            },
            .pointer_down, .pointer_up => |press| {
                if (window_host.pointer_window != target) enterWithPointer(window_host, target, surfaceCoordinates(target, press.pointer.position));
                window_host.onPointerButton(keys.evdev_button_left, event == .pointer_down);
            },
            .key_down, .key_up => |key| {
                const evdev_code = evdevCodeOf(window_host, key.key) orelse return false;
                if (window_host.keyboard_window != target) {
                    window_host.onKeyboardLeave();
                    window_host.onKeyboardEnter(target.surface);
                }
                window_host.onKey(evdev_code, event == .key_down);
            },
            .environment => |change| switch (change) {
                .accent => |accent| window_host.onDesktopReport(.{ .accent = accent }),
                else => return false,
            },
            else => return false,
        }
        return true;
    }

    fn enterWithPointer(window_host: *Host, target: *Host.Window, position: [2]f32) void {
        window_host.onPointerLeave();
        window_host.onPointerEnter(target.surface, 1, position);
    }

    pub fn openedUrl(self: *CompositorHarness) ?[]const u8 {
        return self.window.service_fake.openedUrl();
    }

    pub fn scriptServices(self: *CompositorHarness, script: zui_testing.ServiceScript) void {
        self.window.service_fake.scriptFileDialog(script.chosen_paths);
        self.window.service_fake.scriptNotification(switch (script.notification) {
            .activated => .activated,
            .dismissed => .dismissed,
        });
    }

    pub fn close(self: *CompositorHarness) void {
        self.host().close();
    }

    pub fn platformOffersClipboard(self: *CompositorHarness) bool {
        return self.host().data_device.device != null;
    }
};

fn surfaceCoordinates(window: *const Host.Window, position: [2]f32) [2]f32 {
    const per_unit = window.surface_coordinates_per_unit;
    return .{ position[0] * per_unit, position[1] * per_unit };
}

fn evdevCodeOf(window_host: *const Host, key: zui.Key) ?u32 {
    for (1..256) |code| {
        if (window_host.keyOf(@intCast(code)) == key) return @intCast(code);
    }
    return null;
}

test "the host passes zui's host suite" {
    var harness: CompositorHarness = .{};
    try harness.window.open(1);
    defer harness.window.close();
    try zui_testing.expectHostConforms(Host, &harness, .{ .io = testing.io });
}

test "the host passes zui's host suite on a window with a custom title bar" {
    var harness: CompositorHarness = .{};
    harness.window.title_bar = .custom;
    try harness.window.open(1);
    defer harness.window.close();
    try zui_testing.expectHostConforms(Host, &harness, .{ .io = testing.io });
}

fn typedText(polled: *const zui_testing.PolledRecord, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (polled.builder.events()) |event| if (event == .text) {
        @memcpy(buffer[len..][0..event.text.len], event.text);
        len += event.text.len;
    };
    return buffer[0..len];
}

test "the first poll reports focus, and a viewport in layout units" {
    var window: UnshownWindow = .{};
    try window.open(2);
    defer window.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    polled.builder.params.zoom = 1.25;
    try testing.expect(polled.poll(window.host()));
    try testing.expectEqual(@as(f32, 2), polled.builder.params.scale);
    try testing.expectEqual([2]f32{ 320 / 2.5, 240 / 2.5 }, polled.builder.params.viewport);
    try testing.expectEqual(false, polled.find(.environment).?.window_focused);
}

test "a new buffer scale moves the scale, and the window keeps its size in layout units" {
    var window: UnshownWindow = .{};
    try window.open(null);
    defer window.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window.host());
    const viewport = polled.builder.params.viewport;

    mainOf(window.host()).onPreferredBufferScale(2);
    _ = polled.poll(window.host());
    try testing.expectEqual(@as(f32, 2), polled.builder.params.scale);
    try testing.expectEqual(viewport, polled.builder.params.viewport);
}

test "a configured size is the window's size once the configure is done" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    mainOf(window.host()).onToplevelConfigure(500, 400, &.{});
    _ = polled.poll(window.host());
    try testing.expectEqual([2]f32{ 320, 240 }, polled.builder.params.viewport);
    mainOf(window.host()).onConfigure(1);
    _ = polled.poll(window.host());
    try testing.expectEqual([2]f32{ 500, 400 }, polled.builder.params.viewport);
}

test "a wheel's notch scrolls a step toward the end, and a touchpad its distance" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window.host());

    window.host().onPointerAxisNotches(0, 1);
    window.host().onPointerAxis(0, 15);
    _ = polled.poll(window.host());
    try testing.expectEqual([2]f32{ 0, Host.wheel_step }, polled.find(.wheel).?.delta);

    window.host().onPointerAxis(1, -7.5);
    _ = polled.poll(window.host());
    try testing.expectEqual([2]f32{ -7.5, 0 }, polled.find(.wheel).?.delta);
}

test "keys type their text, but not with Control held, and Enter types nothing" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);

    for ([_]zui.Key{ .h, .i, .enter }) |key| {
        window_host.onKey(evdevCodeOf(window_host, key).?, true);
        window_host.onKey(evdevCodeOf(window_host, key).?, false);
    }
    _ = polled.poll(window_host);
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("hi", typedText(&polled, &buffer));
    const pressed = polled.find(.key_down).?;
    try testing.expectEqual(zui.Key.h, pressed.key);
    try testing.expectEqual(evdevCodeOf(window_host, .h).?, pressed.scancode);

    window_host.modifiers.control = true;
    window_host.onKey(evdevCodeOf(window_host, .s).?, true);
    _ = polled.poll(window_host);
    try testing.expectEqualStrings("", typedText(&polled, &buffer));
    try testing.expect(polled.find(.key_down).?.modifiers.control);
}

test "the close button closes the window at the next poll" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    try testing.expect(polled.poll(window.host()));
    mainOf(window.host()).onClose();
    try testing.expect(!polled.poll(window.host()));
}

fn environmentOf(polled: *const zui_testing.PolledRecord) struct { environment: zui.Environment, changes: usize } {
    var environment: zui.Environment = .{};
    var changes: usize = 0;
    for (polled.builder.events()) |event| if (event == .environment and event.environment != .window_focused) {
        environment.apply(event.environment);
        changes += 1;
    };
    return .{ .environment = environment, .changes = changes };
}

test "without a bus to read, the first poll reports the environment at zui's defaults" {
    var window: UnshownWindow = .{};
    try window.openReading(1, .{ .session = "unix:path=/nonexistent/zui-host-session-bus", .system = "unix:path=/nonexistent/zui-host-system-bus" });
    defer window.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window.host());
    const reported = environmentOf(&polled);
    try testing.expectEqual(@as(usize, 9), reported.changes);
    try testing.expectEqual(zui.Environment{ .window_focused = true }, reported.environment);
    try testing.expectEqual(desktop_bus.Sources{}, window.host().environmentSources());
}

test "the desktop's own buses, where they run, report the whole environment within init's bound" {
    var window: UnshownWindow = .{};
    const started = std.Io.Timestamp.now(testing.io, .awake);
    try window.openReading(1, null);
    defer window.close();
    const init_ns = started.durationTo(std.Io.Timestamp.now(testing.io, .awake)).nanoseconds;
    try testing.expect(init_ns < std.time.ns_per_s);
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window.host());
    try testing.expectEqual(@as(usize, 9), environmentOf(&polled).changes);
}

test "a setting the desktop changes is reported, and only what changed" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);

    window_host.onDesktopReport(.{ .theme = .dark });
    window_host.onDesktopReport(.{ .contrast = .normal });
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(usize, 1), environmentOf(&polled).changes);
    try testing.expectEqual(zui.Environment.Theme.dark, polled.find(.environment).?.theme);

    const expected_power = [_]struct { desktop_bus.Report, zui.Environment.Power }{
        .{ .{ .on_battery = true }, .battery },
        .{ .{ .power_saver = true }, .saver },
        .{ .{ .power_saver = false }, .battery },
        .{ .{ .on_battery = false }, .plugged },
    };
    for (expected_power) |step| {
        window_host.onDesktopReport(step[0]);
        _ = polled.poll(window_host);
        try testing.expectEqual(step[1], polled.find(.environment).?.power);
    }
}

test "the desktop's accent is reported when set, as null when unset, and again when it changes" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    try testing.expectEqual(null, environmentOf(&polled).environment.accent);

    const steps = [_]struct { reported: ?zui.Color, polled: ?zui.EnvironmentChange }{
        .{ .reported = .rgb(0x3584e4), .polled = .{ .accent = .rgb(0x3584e4) } },
        .{ .reported = .rgb(0x3584e4), .polled = null },
        .{ .reported = .rgb(0xe66100), .polled = .{ .accent = .rgb(0xe66100) } },
        .{ .reported = null, .polled = .{ .accent = null } },
    };
    for (steps) |step| {
        window_host.onDesktopReport(.{ .accent = step.reported });
        _ = polled.poll(window_host);
        try testing.expectEqual(step.polled, polled.find(.environment));
    }
}

test "the system preparing to sleep is a suspend, and waking a resume" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    window.host().onDesktopReport(.{ .preparing_for_sleep = true });
    window.host().onDesktopReport(.{ .preparing_for_sleep = false });
    _ = polled.poll(window.host());
    var lifecycle: [2]zui.Lifecycle = undefined;
    var count: usize = 0;
    for (polled.builder.events()) |event| if (event == .lifecycle) {
        lifecycle[count] = event.lifecycle;
        count += 1;
    };
    try testing.expectEqualSlices(zui.Lifecycle, &.{ .@"suspend", .@"resume" }, lifecycle[0..count]);
}

test "SIGINT, SIGTERM and SIGHUP each wake the wait as a terminate request, after which the window reports closed" {
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |signal| {
        var window: UnshownWindow = .{};
        try window.open(1);
        defer window.close();
        const window_host = window.host();
        if (!window_host.handlesSignal(signal)) {
            std.debug.print("skipped: SIG{t} already has a handler in this process\n", .{signal});
            return error.SkipZigTest;
        }
        var polled: zui_testing.PolledRecord = .{};
        polled.init();
        _ = polled.poll(window_host);
        try std.posix.raise(signal);
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(2) });
        try testing.expect(polled.poll(window_host));
        try testing.expectEqual(zui.Lifecycle.terminate_requested, polled.find(.lifecycle).?);
        try testing.expect(!polled.poll(window_host));
    }
}

fn findRepeat(polled: *const zui_testing.PolledRecord) ?zui.KeyEvent {
    for (polled.builder.events()) |event| if (event == .key_down and event.key_down.repeat) return event.key_down;
    return null;
}

test "a held key repeats after the delay at the compositor's rate, typing each time, until it is released" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    const a = evdevCodeOf(window_host, .a).?;

    window_host.onRepeatInfo(100, 30);
    window_host.onKey(a, true);
    _ = polled.poll(window_host);
    const press = polled.find(.key_down).?;
    try testing.expect(!press.repeat);

    const pressed_at = press.at;
    window_host.zuiWait(.{ .at = pressed_at.addSeconds(2) });
    try testing.expect(window_host.now().secondsSince(pressed_at) < 1);
    _ = polled.poll(window_host);
    const repeat = findRepeat(&polled).?;
    try testing.expectEqual(zui.Key.a, repeat.key);
    try testing.expect(repeat.at.secondsSince(pressed_at) >= 0.03);
    var buffer: [32]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, typedText(&polled, &buffer), "a"));

    window_host.onKey(a, false);
    try testing.expectEqual(@as(?zui.Instant, null), window_host.nextRepeatAt());
    window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.1) });
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(?zui.KeyEvent, null), findRepeat(&polled));
}

fn secondsWaitedFor(window_host: *Host, next: zui.NextFrame) f64 {
    const started = window_host.now();
    window_host.zuiWait(next);
    return window_host.now().secondsSince(started);
}

/// The compositor's answer to `wl_display.sync`, which it sends once it
/// has read every request before it, as it answers a ping.
const SyncAnswer = struct {
    answered: bool = false,

    const display_sync = 0;

    const listener: wayland.CallbackListener = .{
        .done = struct {
            fn done(data: ?*anyopaque, callback: ?*wayland.Proxy, _: u32) callconv(.c) void {
                const self: *SyncAnswer = @ptrCast(@alignCast(data.?));
                self.answered = true;
                wayland.wl_proxy_destroy(callback.?);
            }
        }.done,
    };

    fn ask(self: *SyncAnswer, window_host: *Host) !void {
        const callback = wayland.create(wayland.displayProxy(window_host.display), display_sync, &wayland.wl_callback_interface, 1, .{wayland.no_id}) orelse return error.NoCallback;
        wayland.addListener(callback, &listener, self);
    }
};

test "once the compositor answers a window's frames, a due frame waits for the answer to the last, the display still dispatched" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    window.main().onFrameDone();
    _ = polled.poll(window_host);
    window_host.zuiApply(.main, .{});

    var sync: SyncAnswer = .{};
    try sync.ask(window_host);
    const a = evdevCodeOf(window_host, .a).?;
    window_host.onRepeatInfo(10, 100);
    window_host.onKey(a, true);
    _ = polled.poll(window_host);
    try testing.expect(secondsWaitedFor(window_host, .immediately) >= 0.09);
    try testing.expect(sync.answered);
    _ = polled.poll(window_host);
    try testing.expect(findRepeat(&polled) != null);

    window_host.onKey(a, false);
    window.main().onFrameDone();
    try testing.expect(secondsWaitedFor(window_host, .immediately) < 0.05);
}

test "a window the compositor has never answered a frame of, as one it never shows, is not held" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    window_host.zuiApply(.main, .{});
    try testing.expect(secondsWaitedFor(window_host, .immediately) < 0.05);
    const waited = secondsWaitedFor(window_host, .{ .at = window_host.now().addSeconds(0.05) });
    try testing.expect(waited >= 0.04 and waited < 0.5);
}

test "a window whose frame goes unanswered, as a hidden one's does, holds another's frame no longer than an answer takes" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const second = try window_host.zuiOpenWindow(second_window_options);
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    for ([_]zui.WindowId{ .main, second }) |id| {
        _ = polled.pollWindow(window_host, id);
        window_host.windowById(id).?.onFrameDone();
        _ = polled.pollWindow(window_host, id);
        window_host.zuiApply(id, .{});
    }
    window_host.windowById(second).?.onFrameDone();
    const waited = secondsWaitedFor(window_host, .immediately);
    try testing.expect(waited >= 0.09 and waited < 1);
    try testing.expect(secondsWaitedFor(window_host, .immediately) < 0.05);
}

test "a modifier pressed while a key is held leaves it repeating; losing focus, or a rate of 0, stops it" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const a = evdevCodeOf(window_host, .a).?;

    window_host.onKey(a, true);
    const repeat_at = window_host.nextRepeatAt().?;
    window_host.onKey(evdevCodeOf(window_host, .shift).?, true);
    try testing.expectEqual(repeat_at, window_host.nextRepeatAt().?);
    window_host.onKeyboardLeave();
    try testing.expectEqual(@as(?zui.Instant, null), window_host.nextRepeatAt());

    window_host.onRepeatInfo(0, 600);
    window_host.onKey(a, true);
    try testing.expectEqual(@as(?zui.Instant, null), window_host.nextRepeatAt());
}

test "a fractional scale of 1.25 or 1.5 is the record's scale, and the viewport keeps the surface's size while the buffer takes its pixels" {
    for ([_]struct { u32, f32 }{ .{ 150, 1.25 }, .{ 180, 1.5 } }) |step| {
        var window: UnshownWindow = .{};
        try window.open(null);
        defer window.close();
        const window_host = window.host();
        var polled: zui_testing.PolledRecord = .{};
        polled.init();
        _ = polled.poll(window_host);

        mainOf(window_host).onPreferredFractionalScale(step[0]);
        mainOf(window_host).onPreferredBufferScale(2);
        _ = polled.poll(window_host);
        const params = polled.builder.params;
        try testing.expectEqual(step[1], params.scale);
        try testing.expectEqual([2]f32{ 320, 240 }, params.viewport);
        try testing.expectEqual(@as(i32, 1), mainOf(window_host).buffer_scale);
        const buffer_width = @round(params.viewport[0] * params.scale * params.zoom);
        try testing.expectEqual(@round(320 * step[1]), buffer_width);

        polled.builder.params.zoom = 2;
        window_host.onPointerMotion(.{ 100, 50 });
        _ = polled.poll(window_host);
        try testing.expectEqual([2]f32{ 160, 120 }, polled.builder.params.viewport);
        try testing.expectEqual([2]f32{ 50, 25 }, polled.find(.pointer_move).?.pointer.position);
    }
}

test "a forced scale still wins over a fractional one, and the buffer still takes the surface's pixels" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    mainOf(window.host()).onPreferredFractionalScale(150);
    _ = polled.poll(window.host());
    try testing.expectEqual(@as(f32, 1), polled.builder.params.scale);
    try testing.expectApproxEqAbs(@as(f32, 400), polled.builder.params.viewport[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 300), polled.builder.params.viewport[1], 1e-3);
}

const ClipboardReplies = struct {
    replies: [2]zui.ServiceReply(128 * 1024) = undefined,
    count: usize = 0,

    pub fn publish(self: *ClipboardReplies, reply: zui.ServiceReply(128 * 1024)) error{Full}!zui.Wake {
        if (self.count == self.replies.len) return error.Full;
        self.replies[self.count] = reply;
        self.count += 1;
        return .needed;
    }
};

const transfer_bound_ns = 2 * std.time.ns_per_s;

/// Waits, as the loop would, until `done`, first taking what is already
/// pending, which would end every wait at once.
fn waitUntil(window_host: *Host, comptime done: fn (*Host, *const anyopaque) bool, context: *const anyopaque) !void {
    var pending: zui_testing.PolledRecord = .{};
    pending.init();
    _ = pending.poll(window_host);
    const deadline = window_host.now().addNanoseconds(transfer_bound_ns);
    while (!done(window_host, context)) {
        if (!window_host.now().isBefore(deadline)) return error.Timeout;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    }
}

fn answered(_: *Host, context: *const anyopaque) bool {
    const replies: *const ClipboardReplies = @ptrCast(@alignCast(context));
    return replies.count > 0;
}

fn pipe() ![2]i32 {
    var ends: [2]i32 = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&ends, .{ .CLOEXEC = true })) != .SUCCESS) return error.NoPipe;
    _ = std.os.linux.fcntl(ends[0], std.os.linux.F.SETFL, 1 << @bitOffsetOf(std.os.linux.O, "NONBLOCK"));
    return ends;
}

test "text the clipboard is given is written to a reader through a pipe, and read back from one, by the host's own wait" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    if (window_host.data_device.device == null) {
        std.debug.print("skipped: the compositor offers no wl_data_device_manager\n", .{});
        return error.SkipZigTest;
    }
    var text: [zui_host.linux.data_device.DataDevice.clipboard_text_capacity]u8 = undefined;
    for (&text, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
    try Host.zuiClipboard.write(window_host, &text);

    const ends = try pipe();
    // A pipe smaller than the text, so the write goes in pieces as the
    // reader drains it.
    _ = std.os.linux.fcntl(ends[1], std.os.linux.F.SETPIPE_SZ, 4096);
    window_host.data_device.sendSelectionTo(ends[1]);
    var replies: ClipboardReplies = .{};
    window_host.data_device.receiveClipboardFrom(.of("paste"), .of(&replies), window_host.zuiWaker(), ends[0]);
    try waitUntil(window_host, answered, &replies);
    const reply = &replies.replies[0];
    try testing.expectEqual(zui.ServiceRequest.of("paste"), reply.request);
    try testing.expectEqual(@as(usize, text.len), reply.text().len);
    try testing.expectEqualStrings(&text, reply.text());
    try testing.expectEqual(@as(u32, 0), reply.left_out_bytes);

    try testing.expectError(error.InvalidUtf8, Host.zuiClipboard.write(window_host, "\xff"));
    var too_large: [text.len + 1]u8 = @splat('z');
    try testing.expectError(error.TooLarge, Host.zuiClipboard.write(window_host, &too_large));
}

/// With SIGPIPE blocked on its thread, so a reader that gave up fails the
/// write rather than ending the process, and giving up itself once the
/// reader has not drained the pipe for twice a transfer's bound.
fn writeAndClose(fd: i32, bytes: []const u8) void {
    var pipe_signal = std.posix.sigemptyset();
    std.posix.sigaddset(&pipe_signal, .PIPE);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &pipe_signal, null);
    var written: usize = 0;
    while (written < bytes.len) {
        var writable = [_]std.os.linux.pollfd{.{ .fd = fd, .events = std.os.linux.POLL.OUT, .revents = 0 }};
        var bound: std.os.linux.timespec = .{ .sec = 2 * transfer_bound_ns / std.time.ns_per_s, .nsec = 0 };
        if (std.os.linux.ppoll(&writable, 1, &bound, null) != 1) break;
        const result = std.os.linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (std.os.linux.errno(result) != .SUCCESS) break;
        written += result;
    }
    _ = std.os.linux.close(fd);
}

test "a clipboard's text past what a read holds is cut at a character, and the rest counted as left out" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const capacity = zui_host.linux.data_device.DataDevice.clipboard_text_capacity;
    const check_mark = "\u{2713}";
    var text: [capacity + 100]u8 = @splat('x');
    @memcpy(text[capacity - 1 ..][0..check_mark.len], check_mark);

    const ends = try pipe();
    var replies: ClipboardReplies = .{};
    window_host.data_device.receiveClipboardFrom(.of("paste"), .of(&replies), window_host.zuiWaker(), ends[0]);
    const writer = try std.Thread.spawn(.{}, writeAndClose, .{ ends[1], @as([]const u8, &text) });
    defer writer.join();
    try waitUntil(window_host, answered, &replies);
    const reply = &replies.replies[0];
    try testing.expectEqual(@as(usize, capacity - 1), reply.text().len);
    try testing.expectEqual(@as(u32, text.len - (capacity - 1)), reply.left_out_bytes);
}

test "a clipboard holding no text is read as empty, and a second read while one is in flight is busy" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    window_host.data_device.onSelection(null);
    var replies: ClipboardReplies = .{};
    try Host.zuiClipboard.read(window_host, .of("empty"), .of(&replies));
    try testing.expectEqual(@as(usize, 1), replies.count);
    try testing.expectEqual(zui.ServiceReply(128 * 1024).Kind.clipboard_text, replies.replies[0].kind);
    try testing.expectEqualStrings("", replies.replies[0].text());

    const ends = try pipe();
    defer _ = std.os.linux.close(ends[1]);
    window_host.data_device.receiveClipboardFrom(.of("slow"), .of(&replies), window_host.zuiWaker(), ends[0]);
    try testing.expectError(error.Busy, Host.zuiClipboard.read(window_host, .of("second"), .of(&replies)));
}

test "a drop's URI list, read from the wait, arrives as files_dropped at the drag's position in layout units" {
    var window: UnshownWindow = .{};
    try window.open(2);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);

    window_host.onDragEnter(1, window.main().surface, null, .{ 100, 60 });
    window_host.onDragMotion(.{ 120, 80 });
    const ends = try pipe();
    window_host.receiveDropFrom(ends[0]);
    writeAndClose(ends[1], "file:///home/user/My%20Theme.zon\r\nhttps://ziglang.org/\r\nfile:///tmp/notes.txt\r\n");
    const deadline = window_host.now().addNanoseconds(transfer_bound_ns);
    const drop = while (true) {
        _ = polled.poll(window_host);
        if (polled.find(.files_dropped)) |drop| break drop;
        if (!window_host.now().isBefore(deadline)) return error.Timeout;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    };
    try testing.expectEqual([2]f32{ 60, 40 }, drop.position);
    var paths = drop.paths();
    try testing.expectEqualStrings("/home/user/My Theme.zon", paths.next().?);
    try testing.expectEqualStrings("/tmp/notes.txt", paths.next().?);
    try testing.expectEqual(@as(?[]const u8, null), paths.next());
}

const FileChanges = struct {
    changes: [64]zui.FileChange = undefined,
    count: usize = 0,

    pub fn publish(self: *FileChanges, change: zui.FileChange) zui.Wake {
        if (self.count == self.changes.len) return .already_pending;
        self.changes[self.count] = change;
        self.count += 1;
        return .needed;
    }

    fn has(self: *const FileChanges, kind: zui.FileChange.Kind, path: []const u8) bool {
        for (self.changes[0..self.count]) |change| if (change.kind == kind and std.mem.eql(u8, change.pathBytes(), path)) return true;
        return false;
    }
};

const ExpectedChange = struct { changes: *const FileChanges, kind: zui.FileChange.Kind, path: []const u8 };

fn changeSeen(_: *Host, context: *const anyopaque) bool {
    const expected: *const ExpectedChange = @ptrCast(@alignCast(context));
    return expected.changes.has(expected.kind, expected.path);
}

fn expectChange(window_host: *Host, changes: *const FileChanges, kind: zui.FileChange.Kind, path: []const u8) !void {
    const expected: ExpectedChange = .{ .changes = changes, .kind = kind, .path = path };
    waitUntil(window_host, changeSeen, &expected) catch |err| {
        std.debug.print("no .{t} of \"{s}\" within {d} s\n", .{ kind, path, transfer_bound_ns / std.time.ns_per_s });
        return err;
    };
}

test "a watched directory reports a file added, modified and removed, in it and in a subdirectory made after the watch" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = testing.io;
    try temporary.dir.createDir(io, "existing", .default_dir);
    var path_buffer: [256]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&temporary.sub_path});

    var changes: FileChanges = .{};
    try Host.zuiFileWatch.watch(window_host, directory, .of(&changes));
    try testing.expectEqual(@as(usize, 0), changes.count);

    try temporary.dir.writeFile(io, .{ .sub_path = "theme.zon", .data = ".{}" });
    try expectChange(window_host, &changes, .added, "theme.zon");
    try temporary.dir.writeFile(io, .{ .sub_path = "theme.zon", .data = ".{ .changed = true }" });
    try expectChange(window_host, &changes, .modified, "theme.zon");
    try temporary.dir.deleteFile(io, "theme.zon");
    try expectChange(window_host, &changes, .removed, "theme.zon");

    try temporary.dir.writeFile(io, .{ .sub_path = "existing/old.zon", .data = ".{}" });
    try expectChange(window_host, &changes, .added, "existing/old.zon");

    try temporary.dir.createDir(io, "made_after", .default_dir);
    try expectChange(window_host, &changes, .added, "made_after");
    try temporary.dir.writeFile(io, .{ .sub_path = "made_after/new.zon", .data = ".{}" });
    try expectChange(window_host, &changes, .added, "made_after/new.zon");
    try temporary.dir.writeFile(io, .{ .sub_path = "made_after/new.zon", .data = ".{ .changed = true }" });
    try expectChange(window_host, &changes, .modified, "made_after/new.zon");
    try temporary.dir.deleteFile(io, "made_after/new.zon");
    try expectChange(window_host, &changes, .removed, "made_after/new.zon");
}

test "a directory that cannot be opened is unavailable, and one past the host's watches is too many" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&temporary.sub_path});
    var changes: FileChanges = .{};
    try testing.expectError(error.DirectoryUnavailable, Host.zuiFileWatch.watch(window_host, "/nonexistent/zui-host-watch", .of(&changes)));
    for (0..zui_host.linux.file_watch.Watches.capacity) |_| try Host.zuiFileWatch.watch(window_host, directory, .of(&changes));
    try testing.expectError(error.TooManyWatches, Host.zuiFileWatch.watch(window_host, directory, .of(&changes)));
}

const wayland = zui_host.linux.wayland;
extern "wayland-client" const wl_shm_interface: wayland.Interface;
extern "wayland-client" const wl_shm_pool_interface: wayland.Interface;
extern "wayland-client" const wl_buffer_interface: wayland.Interface;

/// Gives a shown window a buffer of one color, so the compositor maps it
/// and gives it focus; the clipboard's selection reaches only the window
/// with focus.
const PlainBuffer = struct {
    shm: ?*wayland.Proxy = null,
    buffer: ?*wayland.Proxy = null,

    const shm_create_pool = 0;
    const shm_pool_create_buffer = 0;
    const shm_pool_destroy = 1;
    const buffer_destroy = 0;
    const surface_attach = 1;
    const format_xrgb8888 = 1;

    const registry_listener: wayland.RegistryListener = .{
        .global = struct {
            fn global(data: ?*anyopaque, registry: ?*wayland.Proxy, name: u32, interface_name: [*:0]const u8, _: u32) callconv(.c) void {
                const self: *PlainBuffer = @ptrCast(@alignCast(data.?));
                if (std.mem.eql(u8, std.mem.span(interface_name), "wl_shm")) self.shm = wayland.bind(registry.?, name, &wl_shm_interface, 1);
            }
        }.global,
        .global_remove = struct {
            fn globalRemove(_: ?*anyopaque, _: ?*wayland.Proxy, _: u32) callconv(.c) void {}
        }.globalRemove,
    };

    fn attach(self: *PlainBuffer, window_host: *Host) !void {
        const linux = std.os.linux;
        const registry = wayland.create(wayland.displayProxy(window_host.display), wayland.display_get_registry, &wayland.wl_registry_interface, 1, .{wayland.no_id}) orelse return error.NoRegistry;
        defer wayland.wl_proxy_destroy(registry);
        wayland.addListener(registry, &registry_listener, self);
        if (wayland.wl_display_roundtrip(window_host.display) < 0) return error.CompositorUnreachable;
        const shm = self.shm orelse return error.NoShm;
        const size = mainOf(window_host).surface_size;
        const stride: i32 = @intCast(size[0] * 4);
        const bytes: i32 = stride * @as(i32, @intCast(size[1]));
        const memory = linux.memfd_create("zui-host-test", linux.MFD.CLOEXEC);
        if (linux.errno(memory) != .SUCCESS) return error.NoSharedMemory;
        const memory_fd: i32 = @intCast(memory);
        defer _ = linux.close(memory_fd);
        if (linux.errno(linux.ftruncate(memory_fd, bytes)) != .SUCCESS) return error.NoSharedMemory;
        const pool = wayland.create(shm, shm_create_pool, &wl_shm_pool_interface, 1, .{ wayland.no_id, memory_fd, bytes }) orelse return error.NoSharedMemory;
        defer wayland.destroy(pool, shm_pool_destroy);
        self.buffer = wayland.create(pool, shm_pool_create_buffer, &wl_buffer_interface, 1, .{ wayland.no_id, @as(i32, 0), @as(i32, @intCast(size[0])), @as(i32, @intCast(size[1])), stride, @as(u32, format_xrgb8888) }) orelse return error.NoBuffer;
        wayland.send(mainOf(window_host).surface, surface_attach, .{ self.buffer.?, @as(i32, 0), @as(i32, 0) });
        wayland.send(mainOf(window_host).surface, wayland.surface_commit, .{});
        _ = wayland.wl_display_flush(window_host.display);
    }

    fn release(self: *PlainBuffer) void {
        if (self.buffer) |buffer| wayland.destroy(buffer, buffer_destroy);
        if (self.shm) |shm| wayland.wl_proxy_destroy(shm);
    }
};

test "with ZUI_HOST_TEST_SHOWN_WINDOW set, text written to the clipboard comes back through the compositor's own selection" {
    _ = std.c.getenv("ZUI_HOST_TEST_SHOWN_WINDOW") orelse return error.SkipZigTest;
    var window_host: Host = undefined;
    window_host.forced_scale = 1;
    window_host.bus_addresses = .{ .session = null, .system = null };
    try window_host.init(testing.io, .{ .title = "zui host suite: clipboard", .size = .{ 320, 240 } });
    defer window_host.deinit();
    var plain: PlainBuffer = .{};
    defer plain.release();
    try plain.attach(&window_host);

    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    const deadline = window_host.now().addNanoseconds(transfer_bound_ns);
    while (true) {
        _ = polled.poll(&window_host);
        if (polled.find(.environment)) |change| if (change == .window_focused and change.window_focused) break;
        if (!window_host.now().isBefore(deadline)) return error.WindowNotFocused;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    }

    const copied = "zui \u{2713} through the compositor";
    try Host.zuiClipboard.write(&window_host, copied);
    while (window_host.data_device.source_is_newest_selection) {
        _ = polled.poll(&window_host);
        if (polled.find(.environment)) |change| if (change == .window_focused and !change.window_focused) {
            std.debug.print("skipped: the window lost focus before the compositor named its selection\n", .{});
            return error.SkipZigTest;
        };
        if (!window_host.now().isBefore(deadline.addNanoseconds(transfer_bound_ns))) return error.SelectionNotNamed;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    }
    var replies: ClipboardReplies = .{};
    try Host.zuiClipboard.read(&window_host, .of("paste"), .of(&replies));
    try waitUntil(&window_host, answered, &replies);
    try testing.expectEqualStrings(copied, replies.replies[0].text());
}

const Replies = struct {
    replies: [4]Reply = undefined,
    count: usize = 0,

    const Reply = zui.ServiceReply(1024);

    pub fn publish(self: *Replies, reply: Reply) zui.Wake {
        self.replies[self.count] = reply;
        self.count += 1;
        return if (self.count == 1) .needed else .already_pending;
    }
};

test "a service is answered by the wait after the call, which it ends, and never by the call" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);

    var replies: Replies = .{};
    window.service_fake.scriptNotification(.dismissed);
    try Host.zuiNotifications.show(window_host, .of("saved"), .{ .title = "Saved" }, .of(&replies));
    window.service_fake.scriptFileDialog("/zui/picked.zon\x00");
    try Host.zuiFileDialogs.show(window_host, .main, .of("open"), .{}, .of(&replies));
    try testing.expectEqual(@as(usize, 0), replies.count);
    const waited_from = window_host.now();
    window_host.zuiWait(.{ .at = waited_from.addSeconds(2) });
    try testing.expect(window_host.now().secondsSince(waited_from) < 1);
    try testing.expectEqual(@as(usize, 2), replies.count);
    try testing.expectEqual(.notification_dismissed, replies.replies[0].kind);
    try testing.expectEqual(.files_chosen, replies.replies[1].kind);
    var paths = replies.replies[1].paths();
    try testing.expectEqualStrings("/zui/picked.zon", paths.next().?);
}

test "a file dialog over a window that is not open is unavailable" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var replies: Replies = .{};
    try testing.expectError(error.Unavailable, Host.zuiFileDialogs.show(window.host(), @enumFromInt(1), .of("open"), .{}, .of(&replies)));
    mainOf(window.host()).onClose();
    try testing.expectError(error.Unavailable, Host.zuiFileDialogs.show(window.host(), .main, .of("open"), .{}, .of(&replies)));
    try testing.expectEqual(@as(u32, 0), window.service_fake.fileDialogsShown());
}

test "without a session bus, each service is unavailable at once" {
    var window: UnshownWindow = .{ .fakes_services = false };
    try window.openReading(1, .{ .session = "unix:path=/nonexistent/zui-host-session-bus", .system = null });
    defer window.close();
    const window_host = window.host();
    var replies: Replies = .{};
    try testing.expectError(error.Unavailable, Host.zuiNotifications.show(window_host, .of("saved"), .{ .title = "Saved" }, .of(&replies)));
    try testing.expectError(error.Unavailable, Host.zuiFileDialogs.show(window_host, .main, .of("open"), .{}, .of(&replies)));
    try testing.expectError(error.Unavailable, Host.zuiOpenUrl.open(window_host, "https://ziglang.org/"));
}

const TextInput = zui_host.linux.text_input.TextInput;

fn askingForTextInputAt(caret: zui.Rect) zui.HostRequests {
    return .{ .text_input = .{ .caret = caret } };
}

test "a frame asking for text input enables the input method once the window has its focus, the caret in surface coordinates" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    const caret: zui.Rect = .{ .x = 10, .y = 20, .width = 2, .height = 16 };

    window_host.zuiApply(.main, askingForTextInputAt(caret));
    try testing.expectEqual(@as(u32, 0), window_host.text_input.requests_sent);

    window_host.onTextInputEnter(mainOf(window_host).surface);
    try testing.expectEqual(@as(u32, 1), window_host.text_input.commits);
    try testing.expectEqual(TextInput.CursorRectangle{ .x = 10, .y = 20, .width = 2, .height = 16 }, window_host.text_input.committed_caret.?);
}

test "at a fractional scale and a zoom, the caret's rectangle is in surface coordinates, not the buffer's pixels" {
    var window: UnshownWindow = .{};
    try window.open(null);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    mainOf(window_host).onPreferredFractionalScale(180);
    polled.builder.params.zoom = 1.25;
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(f32, 1.5), polled.builder.params.scale);

    window_host.onTextInputEnter(mainOf(window_host).surface);
    window_host.zuiApply(.main, askingForTextInputAt(.{ .x = 10, .y = 20, .width = 2, .height = 16 }));
    try testing.expectEqual(TextInput.CursorRectangle{ .x = 12, .y = 25, .width = 3, .height = 20 }, window_host.text_input.committed_caret.?);
}

test "a frame whose text-input request is unchanged, or absent while none was enabled, sends the compositor nothing" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    window_host.onTextInputEnter(mainOf(window_host).surface);

    window_host.zuiApply(.main, .{});
    window_host.zuiApply(.main, .{ .cursor = .pointer });
    try testing.expectEqual(@as(u32, 0), window_host.text_input.requests_sent);

    const caret: zui.Rect = .{ .x = 4, .y = 4, .width = 1, .height = 12 };
    window_host.zuiApply(.main, askingForTextInputAt(caret));
    const sent = window_host.text_input.requests_sent;
    try testing.expectEqual(@as(u32, 3), sent);
    window_host.zuiApply(.main, askingForTextInputAt(caret));
    window_host.zuiApply(.main, askingForTextInputAt(caret));
    try testing.expectEqual(sent, window_host.text_input.requests_sent);

    window_host.zuiApply(.main, askingForTextInputAt(.{ .x = 5, .y = 4, .width = 1, .height = 12 }));
    try testing.expectEqual(sent + 2, window_host.text_input.requests_sent);
    try testing.expectEqual(@as(u32, 2), window_host.text_input.commits);
}

test "an editable losing focus disables the input method" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    window_host.onTextInputEnter(mainOf(window_host).surface);
    window_host.zuiApply(.main, askingForTextInputAt(.{ .x = 4, .y = 4, .width = 1, .height = 12 }));
    const sent = window_host.text_input.requests_sent;

    window_host.zuiApply(.main, .{});
    try testing.expectEqual(@as(?TextInput.CursorRectangle, null), window_host.text_input.committed_caret);
    try testing.expectEqual(sent + 2, window_host.text_input.requests_sent);
    try testing.expectEqual(@as(u32, 2), window_host.text_input.commits);
    window_host.zuiApply(.main, .{});
    try testing.expectEqual(sent + 2, window_host.text_input.requests_sent);
}

test "text the input method commits arrives on done as one text event beside typed keys, and ends a wait" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    window_host.onTextInputEnter(mainOf(window_host).surface);
    window_host.zuiApply(.main, askingForTextInputAt(.{ .x = 4, .y = 4, .width = 1, .height = 12 }));

    window_host.onKey(evdevCodeOf(window_host, .a).?, true);
    window_host.onKey(evdevCodeOf(window_host, .a).?, false);
    window_host.onCommitString("\u{65e5}\u{672c}");
    _ = polled.poll(window_host);
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("a", typedText(&polled, &buffer));

    window_host.onTextInputDone(window_host.text_input.commits);
    const waited_from = window_host.now();
    window_host.zuiWait(.{ .at = waited_from.addSeconds(2) });
    try testing.expect(window_host.now().secondsSince(waited_from) < 1);
    _ = polled.poll(window_host);
    try testing.expectEqualStrings("\u{65e5}\u{672c}", typedText(&polled, &buffer));
    var text_events: usize = 0;
    for (polled.builder.events()) |event| text_events += @intFromBool(event == .text);
    try testing.expectEqual(@as(usize, 1), text_events);
}

test "a done whose serial lags the commits still applies its text, as the protocol says a client must" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    window_host.onTextInputEnter(mainOf(window_host).surface);
    window_host.zuiApply(.main, askingForTextInputAt(.{ .x = 4, .y = 4, .width = 1, .height = 12 }));
    window_host.zuiApply(.main, askingForTextInputAt(.{ .x = 5, .y = 4, .width = 1, .height = 12 }));

    window_host.onCommitString("late");
    window_host.onTextInputDone(window_host.text_input.commits - 1);
    _ = polled.poll(window_host);
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("late", typedText(&polled, &buffer));
}

test "composing text alone is kept, reports nothing and does not end a wait" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    window_host.onTextInputEnter(mainOf(window_host).surface);
    window_host.zuiApply(.main, askingForTextInputAt(.{ .x = 4, .y = 4, .width = 1, .height = 12 }));

    window_host.onPreeditString("ni", 2, 2);
    window_host.onTextInputDone(window_host.text_input.commits);
    try testing.expectEqualStrings("ni", window_host.text_input.preeditText());
    const waited_from = window_host.now();
    window_host.zuiWait(.{ .at = waited_from.addSeconds(0.05) });
    try testing.expect(window_host.now().secondsSince(waited_from) >= 0.05);
    _ = polled.poll(window_host);
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("", typedText(&polled, &buffer));

    window_host.onCommitString("\u{4f60}");
    window_host.onTextInputDone(window_host.text_input.commits);
    try testing.expectEqualStrings("", window_host.text_input.preeditText());
}

test "leaving and entering the window again enables the input method again, the caret resent" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const caret: zui.Rect = .{ .x = 4, .y = 4, .width = 1, .height = 12 };
    window_host.onTextInputEnter(mainOf(window_host).surface);
    window_host.zuiApply(.main, askingForTextInputAt(caret));
    window_host.onPreeditString("ni", 2, 2);
    window_host.onTextInputDone(window_host.text_input.commits);

    window_host.onTextInputLeave(mainOf(window_host).surface);
    try testing.expectEqual(@as(?TextInput.CursorRectangle, null), window_host.text_input.committed_caret);
    try testing.expectEqualStrings("", window_host.text_input.preeditText());
    const sent = window_host.text_input.requests_sent;
    window_host.zuiApply(.main, askingForTextInputAt(caret));
    try testing.expectEqual(sent, window_host.text_input.requests_sent);

    window_host.onTextInputEnter(mainOf(window_host).surface);
    try testing.expectEqual(sent + 3, window_host.text_input.requests_sent);
    try testing.expectEqual(TextInput.CursorRectangle{ .x = 4, .y = 4, .width = 1, .height = 12 }, window_host.text_input.committed_caret.?);
}

test "text-input focus on another surface leaves the input method alone" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    window_host.zuiApply(.main, askingForTextInputAt(.{ .x = 4, .y = 4, .width = 1, .height = 12 }));
    window_host.onTextInputEnter(null);
    try testing.expectEqual(@as(u32, 0), window_host.text_input.requests_sent);
}

const chrome = zui_host.linux.chrome;
const WindowManagerRequest = chrome.WindowManagerRequest;

fn reportedEnvironment(polled: *const zui_testing.PolledRecord) zui.Environment {
    var environment: zui.Environment = .{};
    for (polled.builder.events()) |event| if (event == .environment) environment.apply(event.environment);
    return environment;
}

fn queued(window_host: *Host, comptime tag: std.meta.Tag(zui.Event)) bool {
    const inbox = &mainOf(window_host).inbox;
    for (inbox.events[0..inbox.event_count]) |event| if (event == tag) return true;
    return false;
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

/// A window with a custom title bar, polled once at `zoom` and handed
/// `titleBarRegions` for its viewport from a buffer overwritten after the
/// call.
const TitleBarWindow = struct {
    window: UnshownWindow = .{ .title_bar = .custom },
    polled: zui_testing.PolledRecord = .{},
    regions: [6]zui.ChromeRegion = undefined,

    fn open(self: *TitleBarWindow, forced_scale: ?f32) !void {
        try self.window.open(forced_scale);
        self.polled.init();
        _ = self.polled.poll(self.host());
        self.handRegions();
    }

    fn handRegions(self: *TitleBarWindow) void {
        const viewport = self.polled.builder.params.viewport;
        self.regions = titleBarRegions(viewport[0], viewport[1]);
        var handed = self.regions;
        self.host().zuiChromeRegions(.main, &handed);
        @memset(std.mem.sliceAsBytes(&handed), 0xaa);
    }

    fn close(self: *TitleBarWindow) void {
        self.window.close();
    }

    fn host(self: *TitleBarWindow) *Host {
        return self.window.host();
    }

    /// The middle of `part`, in surface coordinates.
    fn pointIn(self: *TitleBarWindow, part: Part) [2]f32 {
        const bounds = self.regions[@intFromEnum(part)].bounds;
        return surfaceCoordinates(mainOf(self.host()), .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 });
    }

    fn press(self: *TitleBarWindow, point: [2]f32, evdev_button: u32, serial: u32) void {
        const window_host = self.host();
        window_host.onInputSerial(serial);
        window_host.onPointerMotion(point);
        window_host.onPointerButton(evdev_button, true);
    }

    fn release(self: *TitleBarWindow, point: [2]f32, evdev_button: u32) void {
        const window_host = self.host();
        window_host.onPointerMotion(point);
        window_host.onPointerButton(evdev_button, false);
    }

    fn click(self: *TitleBarWindow, point: [2]f32, serial: u32) void {
        self.press(point, keys.evdev_button_left, serial);
        self.release(point, keys.evdev_button_left);
    }

    fn lastRequest(self: *TitleBarWindow) ?WindowManagerRequest {
        return mainOf(self.host()).window_chrome.last_request;
    }

    fn requestsSent(self: *TitleBarWindow) u32 {
        return mainOf(self.host()).window_chrome.requests_sent;
    }

    fn configureMaximized(self: *TitleBarWindow, maximized: bool, serial: u32) void {
        const maximized_state: u32 = 1;
        const activated_state: u32 = 4;
        mainOf(self.host()).onToplevelConfigure(0, 0, if (maximized) &.{ activated_state, maximized_state } else &.{activated_state});
        mainOf(self.host()).onConfigure(serial);
    }
};

test "a custom title bar is reported, and a native one is not and keeps no chrome" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    const environment = reportedEnvironment(&titled.polled);
    try testing.expect(environment.custom_title_bar);
    try testing.expect(!environment.window_maximized);

    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window.host());
    try testing.expect(!reportedEnvironment(&polled).custom_title_bar);
    var regions = titleBarRegions(320, 240);
    window.host().zuiChromeRegions(.main, &regions);
    try testing.expectEqual(@as(usize, 0), mainOf(window.host()).window_chrome.snapshot.count);

    window.host().onInputSerial(5);
    window.host().onPointerMotion(.{ 100, 10 });
    window.host().onPointerButton(keys.evdev_button_left, true);
    _ = polled.poll(window.host());
    try testing.expect(polled.find(.pointer_down) != null);
    try testing.expectEqual(@as(u32, 0), mainOf(window.host()).window_chrome.requests_sent);
}

test "a press on the title bar moves the window with the press's serial, and neither it nor its release reaches zui" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    _ = titled.polled.poll(titled.host());

    titled.click(.{ 100, 10 }, 42);
    try testing.expectEqual(WindowManagerRequest{ .move = 42 }, titled.lastRequest().?);
    _ = titled.polled.poll(titled.host());
    try testing.expect(titled.polled.find(.pointer_move) != null);
    try testing.expectEqual(@as(?zui.PointerButton, null), titled.polled.find(.pointer_down));
    try testing.expectEqual(@as(?zui.PointerButton, null), titled.polled.find(.pointer_up));
}

test "a press on each edge and corner resizes the window from that edge" {
    var window: UnshownWindow = .{ .title_bar = .custom };
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const edges = [_]struct { zui.ChromeKind, chrome.ResizeEdge, u32 }{
        .{ .resize_top, .top, 1 },
        .{ .resize_bottom, .bottom, 2 },
        .{ .resize_left, .left, 4 },
        .{ .resize_top_left, .top_left, 5 },
        .{ .resize_bottom_left, .bottom_left, 6 },
        .{ .resize_right, .right, 8 },
        .{ .resize_top_right, .top_right, 9 },
        .{ .resize_bottom_right, .bottom_right, 10 },
    };
    var regions: [edges.len]zui.ChromeRegion = undefined;
    for (edges, &regions, 0..) |edge, *region, index| {
        region.* = .{ .id = index + 1, .bounds = .{ .x = @floatFromInt(index * 20), .y = 100, .width = 10, .height = 10 }, .kind = edge[0] };
    }
    window_host.zuiChromeRegions(.main, &regions);
    for (edges, 0..) |edge, index| {
        const serial: u32 = @intCast(100 + index);
        window_host.onInputSerial(serial);
        window_host.onPointerMotion(.{ @as(f32, @floatFromInt(index * 20)) + 5, 105 });
        window_host.onPointerButton(keys.evdev_button_left, true);
        window_host.onPointerButton(keys.evdev_button_left, false);
        const request = mainOf(window_host).window_chrome.last_request.?;
        try testing.expectEqual(WindowManagerRequest{ .resize = .{ .serial = serial, .edge = edge[1] } }, request);
        try testing.expectEqual(edge[2], @intFromEnum(request.resize.edge));
    }
}

test "a window that is not resizable takes presses on its grips as zui's" {
    var window: UnshownWindow = .{ .title_bar = .custom };
    try window.open(1);
    defer window.close();
    mainOf(window.host()).window_chrome.resizable = false;
    var regions = titleBarRegions(320, 240);
    window.host().zuiChromeRegions(.main, &regions);
    window.host().onPointerMotion(.{ 316, 236 });
    window.host().onPointerButton(keys.evdev_button_left, true);
    try testing.expectEqual(@as(u32, 0), mainOf(window.host()).window_chrome.requests_sent);
    try testing.expect(queued(window.host(), .pointer_down));
}

test "a double click on the title bar maximizes the window, and once the compositor has maximized it, restores it" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    const point = titled.pointIn(.title_bar);

    titled.click(point, 1);
    titled.click(point, 2);
    try testing.expectEqual(WindowManagerRequest.set_maximized, titled.lastRequest().?);
    try testing.expectEqual(@as(u32, 2), titled.requestsSent());

    titled.configureMaximized(true, 3);
    _ = titled.polled.poll(titled.host());
    try testing.expect(titled.polled.find(.environment).?.window_maximized);

    titled.click(point, 4);
    try testing.expectEqual(WindowManagerRequest{ .move = 4 }, titled.lastRequest().?);
    titled.click(point, 5);
    try testing.expectEqual(WindowManagerRequest.unset_maximized, titled.lastRequest().?);
}

test "a secondary click on the title bar opens the window menu at the pointer, and elsewhere reaches zui" {
    var titled: TitleBarWindow = .{};
    try titled.open(2);
    defer titled.close();
    _ = titled.polled.poll(titled.host());

    titled.press(.{ 150.5, 12.75 }, keys.evdev_button_right, 9);
    titled.release(.{ 150.5, 12.75 }, keys.evdev_button_right);
    try testing.expectEqual(WindowManagerRequest{ .show_window_menu = .{ .serial = 9, .position = .{ 150, 12 } } }, titled.lastRequest().?);
    _ = titled.polled.poll(titled.host());
    try testing.expectEqual(@as(?zui.PointerButton, null), titled.polled.find(.pointer_down));

    titled.press(titled.pointIn(.maximize), keys.evdev_button_right, 10);
    titled.press(titled.pointIn(.search), keys.evdev_button_right, 11);
    try testing.expectEqual(@as(u32, 1), titled.requestsSent());
    _ = titled.polled.poll(titled.host());
    try testing.expectEqual(zui.Button.secondary, titled.polled.find(.pointer_down).?.button);
}

test "a press and its release on a caption button reach zui as a press and a cancel, and the host minimizes or maximizes" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    _ = titled.polled.poll(titled.host());

    const expected = [_]struct { Part, WindowManagerRequest }{ .{ .minimize, .set_minimized }, .{ .maximize, .set_maximized } };
    for (expected, 0..) |step, index| {
        const sent = titled.requestsSent();
        titled.click(titled.pointIn(step[0]), @intCast(20 + index));
        try testing.expectEqual(sent + 1, titled.requestsSent());
        try testing.expectEqual(step[1], titled.lastRequest().?);
        _ = titled.polled.poll(titled.host());
        try testing.expect(titled.polled.find(.pointer_down) != null);
        try testing.expect(titled.polled.find(.pointer_cancel) != null);
        try testing.expectEqual(@as(?zui.PointerButton, null), titled.polled.find(.pointer_up));
    }
}

test "a press and its release on the close button close the window, as the compositor's close button does" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    _ = titled.polled.poll(titled.host());

    titled.click(titled.pointIn(.close), 30);
    try testing.expect(queued(titled.host(), .pointer_down));
    try testing.expect(queued(titled.host(), .pointer_cancel));
    try testing.expect(!queued(titled.host(), .pointer_up));
    try testing.expect(!titled.polled.poll(titled.host()));
}

test "a press on one caption button released on another, or the pointer leaving, works neither" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    _ = titled.polled.poll(titled.host());

    titled.press(titled.pointIn(.close), keys.evdev_button_left, 40);
    titled.release(titled.pointIn(.minimize), keys.evdev_button_left);
    titled.press(titled.pointIn(.maximize), keys.evdev_button_left, 41);
    titled.host().onPointerLeave();
    titled.host().onPointerButton(keys.evdev_button_left, false);
    try testing.expectEqual(@as(u32, 0), titled.requestsSent());
    try testing.expect(titled.polled.poll(titled.host()));
    var cancels: usize = 0;
    for (titled.polled.builder.events()) |event| cancels += @intFromBool(event == .pointer_cancel);
    try testing.expectEqual(@as(usize, 2), cancels);
}

test "the application's own parts inside the title bar, and the content, reach zui" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    _ = titled.polled.poll(titled.host());

    titled.click(titled.pointIn(.search), 50);
    try testing.expectEqual(@as(u32, 0), titled.requestsSent());
    _ = titled.polled.poll(titled.host());
    try testing.expect(titled.polled.find(.pointer_down) != null);
    try testing.expect(titled.polled.find(.pointer_up) != null);

    titled.click(.{ 100, 100 }, 51);
    try testing.expectEqual(@as(u32, 0), titled.requestsSent());
    _ = titled.polled.poll(titled.host());
    try testing.expect(titled.polled.find(.pointer_up) != null);
}

test "the regions are kept in surface coordinates at a scale of 2, and at a fractional scale with a zoom" {
    var doubled: TitleBarWindow = .{};
    try doubled.open(2);
    defer doubled.close();
    try testing.expectEqual(zui.ChromeKind.close_button, doubled.host().chromeKindAt(.main, .{ 2 * (320.0 / 2.0 - 10), 2 * 10 }).?);
    try testing.expectEqual(zui.ChromeKind.resize_bottom_right, doubled.host().chromeKindAt(.main, .{ 317, 237 }).?);
    try testing.expectEqual(@as(?zui.ChromeKind, null), doubled.host().chromeKindAt(.main, .{ 2 * 40, 2 * 10 }));

    var fractional: TitleBarWindow = .{};
    try fractional.window.open(null);
    defer fractional.close();
    fractional.polled.init();
    mainOf(fractional.host()).onPreferredFractionalScale(180);
    fractional.polled.builder.params.zoom = 1.25;
    _ = fractional.polled.poll(fractional.host());
    try testing.expectEqual(@as(f32, 1.5), fractional.polled.builder.params.scale);
    fractional.handRegions();
    try testing.expectEqual(@as(f32, 1.25), mainOf(fractional.host()).surface_coordinates_per_unit);
    const close_point = fractional.pointIn(.close);
    try testing.expectApproxEqAbs(@as(f32, 320 - 23.0 * 1.25 / 2.0), close_point[0], 1e-3);
    try testing.expectEqual(zui.ChromeKind.close_button, fractional.host().chromeKindAt(.main, close_point).?);
    fractional.click(close_point, 60);
    try testing.expect(!fractional.polled.poll(fractional.host()));
}

test "the maximized state follows the compositor's configures, reported only when it changes" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();

    titled.configureMaximized(false, 1);
    _ = titled.polled.poll(titled.host());
    try testing.expectEqual(@as(?zui.EnvironmentChange, null), titled.polled.find(.environment));

    mainOf(titled.host()).onToplevelConfigure(0, 0, &.{1});
    _ = titled.polled.poll(titled.host());
    try testing.expectEqual(@as(?zui.EnvironmentChange, null), titled.polled.find(.environment));
    mainOf(titled.host()).onConfigure(2);
    _ = titled.polled.poll(titled.host());
    try testing.expectEqual(zui.EnvironmentChange{ .window_maximized = true }, titled.polled.find(.environment).?);

    titled.configureMaximized(true, 3);
    _ = titled.polled.poll(titled.host());
    try testing.expectEqual(@as(?zui.EnvironmentChange, null), titled.polled.find(.environment));

    titled.configureMaximized(false, 4);
    _ = titled.polled.poll(titled.host());
    try testing.expectEqual(zui.EnvironmentChange{ .window_maximized = false }, titled.polled.find(.environment).?);
}

test "a compositor that insists on drawing its own title bar gets it: the window reports none, and presses on the chrome reach zui" {
    var titled: TitleBarWindow = .{};
    try titled.open(1);
    defer titled.close();
    _ = titled.polled.poll(titled.host());

    mainOf(titled.host()).onDecorationConfigure(.server_side);
    _ = titled.polled.poll(titled.host());
    try testing.expectEqual(zui.EnvironmentChange{ .custom_title_bar = false }, titled.polled.find(.environment).?);
    titled.handRegions();
    try testing.expectEqual(@as(usize, 0), mainOf(titled.host()).window_chrome.snapshot.count);
    titled.click(titled.pointIn(.title_bar), 70);
    try testing.expectEqual(@as(u32, 0), titled.requestsSent());
    _ = titled.polled.poll(titled.host());
    try testing.expect(titled.polled.find(.pointer_down) != null);

    mainOf(titled.host()).onDecorationConfigure(.client_side);
    _ = titled.polled.poll(titled.host());
    try testing.expectEqual(zui.EnvironmentChange{ .custom_title_bar = true }, titled.polled.find(.environment).?);
}

test "a toplevel asks the compositor for the decorations its title bar needs, and reports what it was given" {
    for ([_]zui.TitleBar{ .custom, .native }) |title_bar| {
        var window: UnshownWindow = .{ .title_bar = title_bar, .has_toplevel = true };
        try window.open(1);
        defer window.close();
        const window_host = window.host();
        var polled: zui_testing.PolledRecord = .{};
        polled.init();
        _ = polled.poll(window_host);
        const window_chrome = &mainOf(window_host).window_chrome;
        if (window_host.globals.decoration_manager != null) {
            try testing.expect(window_chrome.decoration != null);
            try testing.expect(window_chrome.decoration_mode != null);
        }
        const client_side = window_chrome.decoration_mode != .server_side;
        try testing.expectEqual(title_bar == .custom and client_side, reportedEnvironment(&polled).custom_title_bar);
    }
}

const second_window_options: zui.WindowOptions = .{ .title = "zui host suite, second window", .size = .{ 320, 240 }, .visible = false };

test "closing one window by its close button closes it alone, and closing it frees its id" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const second = try window_host.zuiOpenWindow(second_window_options);
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    try testing.expect(polled.pollWindow(window_host, second));

    window_host.windowById(second).?.onClose();
    try testing.expect(!polled.pollWindow(window_host, second));
    try testing.expect(polled.poll(window_host));
    window_host.zuiCloseWindow(second);
    try testing.expectEqual(null, window_host.windowById(second));
    try testing.expect(!polled.pollWindow(window_host, second));
    try testing.expect(polled.poll(window_host));
}

test "the pointer's events reach the window it entered, and keys the window with the keyboard's focus" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const second = try window_host.zuiOpenWindow(second_window_options);
    var first_polled: zui_testing.PolledRecord = .{};
    first_polled.init();
    var second_polled: zui_testing.PolledRecord = .{};
    second_polled.init();
    _ = first_polled.poll(window_host);
    _ = second_polled.pollWindow(window_host, second);

    window_host.onPointerLeave();
    window_host.onPointerEnter(window_host.windowById(second).?.surface, 7, .{ 30, 40 });
    window_host.onPointerButton(keys.evdev_button_left, true);
    window_host.onPointerButton(keys.evdev_button_left, false);
    window_host.onKey(evdevCodeOf(window_host, .a).?, true);
    _ = first_polled.poll(window_host);
    _ = second_polled.pollWindow(window_host, second);
    try testing.expect(first_polled.find(.pointer_leave) != null);
    try testing.expectEqual(@as(?zui.PointerButton, null), first_polled.find(.pointer_down));
    try testing.expectEqual(zui.Key.a, first_polled.find(.key_down).?.key);
    try testing.expectEqual([2]f32{ 30, 40 }, second_polled.find(.pointer_down).?.pointer.position);
    try testing.expect(second_polled.find(.pointer_up) != null);
    try testing.expectEqual(@as(?zui.KeyEvent, null), second_polled.find(.key_down));

    window_host.onKeyboardLeave();
    window_host.onKeyboardEnter(window_host.windowById(second).?.surface);
    window_host.onKey(evdevCodeOf(window_host, .b).?, true);
    _ = first_polled.poll(window_host);
    _ = second_polled.pollWindow(window_host, second);
    try testing.expectEqual(zui.EnvironmentChange{ .window_focused = false }, first_polled.find(.environment).?);
    try testing.expectEqual(@as(?zui.KeyEvent, null), first_polled.find(.key_down));
    try testing.expectEqual(zui.EnvironmentChange{ .window_focused = true }, second_polled.find(.environment).?);
    try testing.expectEqual(zui.Key.b, second_polled.find(.key_down).?.key);
}

test "past the windows the host holds, one more is refused, and after one closes a new one opens with a new id" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var opened: [Host.max_windows - 1]zui.WindowId = undefined;
    for (&opened) |*id| id.* = try window_host.zuiOpenWindow(second_window_options);
    try testing.expectError(error.TooManyWindows, window_host.zuiOpenWindow(second_window_options));

    window_host.zuiCloseWindow(opened[1]);
    const reopened = try window_host.zuiOpenWindow(second_window_options);
    for (opened) |id| try testing.expect(reopened != id);
    try testing.expect(reopened != .main);
}

test "with the main window closed, the clipboard still answers, and a dialog over another window answers naming it" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    if (window_host.data_device.device == null) {
        std.debug.print("skipped: the compositor offers no wl_data_device_manager\n", .{});
        return error.SkipZigTest;
    }
    const second = try window_host.zuiOpenWindow(second_window_options);
    window_host.zuiCloseWindow(.main);
    try testing.expectEqual(null, window_host.windowById(.main));

    var pasted: ClipboardReplies = .{};
    try Host.zuiClipboard.write(window_host, "still here");
    try Host.zuiClipboard.read(window_host, .of("paste"), .of(&pasted));
    var replies: Replies = .{};
    try testing.expectError(error.Unavailable, Host.zuiFileDialogs.show(window_host, .main, .of("open"), .{}, .of(&replies)));
    window.service_fake.scriptFileDialog("/zui/theme.zon\x00");
    try Host.zuiFileDialogs.show(window_host, second, .of("open"), .{}, .of(&replies));

    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    const deadline = window_host.now().addNanoseconds(transfer_bound_ns);
    while (pasted.count == 0 or replies.count == 0) {
        if (!window_host.now().isBefore(deadline)) return error.Timeout;
        try testing.expect(polled.pollWindow(window_host, second));
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    }
    try testing.expectEqualStrings("still here", pasted.replies[0].text());
    try testing.expectEqual(second, replies.replies[0].window);
    try testing.expectEqual(.files_chosen, replies.replies[0].kind);
}

test "a terminate request reaches every window, and each then reports itself closed" {
    var window: UnshownWindow = .{};
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

test "a buffer scale or a fractional scale the compositor prefers for one window moves that window's scale alone" {
    var window: UnshownWindow = .{};
    try window.open(null);
    defer window.close();
    const window_host = window.host();
    const second = try window_host.zuiOpenWindow(second_window_options);
    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.poll(window_host);
    const main_scale = polled.builder.params.scale;
    _ = polled.pollWindow(window_host, second);
    const second_scale = polled.builder.params.scale;

    window_host.windowById(second).?.onPreferredBufferScale(@as(i32, @intFromFloat(second_scale)) + 1);
    _ = polled.pollWindow(window_host, second);
    try testing.expectEqual(second_scale + 1, polled.builder.params.scale);
    _ = polled.poll(window_host);
    try testing.expectEqual(main_scale, polled.builder.params.scale);

    window.main().onPreferredFractionalScale(150);
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(f32, 1.25), polled.builder.params.scale);
    _ = polled.pollWindow(window_host, second);
    try testing.expectEqual(second_scale + 1, polled.builder.params.scale);
}

test "each window keeps its own chrome regions, and a press on one window's title bar moves that window alone" {
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
    var close_at_left = [_]zui.ChromeRegion{.{ .id = 1, .bounds = .{ .width = 30, .height = title_bar_height }, .kind = .close_button }};
    window_host.zuiChromeRegions(second, &close_at_left);

    const on_title_bar = titled.pointIn(.title_bar);
    try testing.expectEqual(zui.ChromeKind.title_bar, window_host.chromeKindAt(.main, on_title_bar).?);
    try testing.expectEqual(@as(?zui.ChromeKind, null), window_host.chromeKindAt(second, on_title_bar));
    try testing.expectEqual(zui.ChromeKind.close_button, window_host.chromeKindAt(second, .{ 10, 10 }).?);
    try testing.expectEqual(zui.ChromeKind.title_bar, window_host.chromeKindAt(.main, .{ 10, 10 }).?);

    const second_window = window_host.windowById(second).?;
    window_host.onPointerLeave();
    window_host.onPointerEnter(second_window.surface, 80, on_title_bar);
    window_host.onInputSerial(81);
    window_host.onPointerButton(keys.evdev_button_left, true);
    _ = second_polled.pollWindow(window_host, second);
    try testing.expect(second_polled.find(.pointer_down) != null);
    try testing.expectEqual(@as(u32, 0), titled.requestsSent());
    try testing.expectEqual(@as(u32, 0), second_window.window_chrome.requests_sent);

    window_host.onPointerButton(keys.evdev_button_left, false);
    window_host.onPointerLeave();
    window_host.onPointerEnter(titled.window.main().surface, 82, on_title_bar);
    window_host.onInputSerial(83);
    window_host.onPointerButton(keys.evdev_button_left, true);
    try testing.expectEqual(WindowManagerRequest{ .move = 83 }, titled.lastRequest().?);
    try testing.expectEqual(@as(u32, 0), second_window.window_chrome.requests_sent);
}

const material = zui_host.linux.material;
const BlurOffers = material.BlurOffers;

fn systemMaterialOf(polled: *const zui_testing.PolledRecord) ?bool {
    for (polled.builder.events()) |event| if (event == .environment and event.environment == .system_material) return event.environment.system_material;
    return null;
}

fn holdsAlpha(window_host: *Host, id: zui.WindowId) bool {
    return window_host.zuiSurface(id).wayland.transparent;
}

const MaterialWindow = struct {
    window: UnshownWindow,
    polled: zui_testing.PolledRecord = .{},

    fn open(self: *MaterialWindow) !void {
        try self.window.open(1);
        self.polled.init();
        _ = self.polled.poll(self.host());
    }

    fn close(self: *MaterialWindow) void {
        self.window.close();
    }

    fn host(self: *MaterialWindow) *Host {
        return self.window.host();
    }

    fn windowMaterial(self: *MaterialWindow) *const material.WindowMaterial {
        return &mainOf(self.host()).window_material;
    }

    fn resize(self: *MaterialWindow, size: [2]i32, serial: u32) void {
        mainOf(self.host()).onToplevelConfigure(size[0], size[1], &.{});
        mainOf(self.host()).onConfigure(serial);
        _ = self.polled.poll(self.host());
    }
};

test "a window with a material, where the background effect blurs, holds alpha and is blurred behind its whole size, resized with it" {
    var window: MaterialWindow = .{ .window = .{ .material = .window, .blur_offers = .{ .background_effect_blurs = true } } };
    try window.open();
    defer window.close();
    try testing.expect(holdsAlpha(window.host(), .main));
    try testing.expectEqual(material.BlurProtocol.background_effect, window.windowMaterial().protocol.?);
    try testing.expectEqual([2]u32{ 320, 240 }, window.windowMaterial().blur_region_size.?);
    try testing.expectEqual(true, systemMaterialOf(&window.polled).?);

    window.resize(.{ 400, 300 }, 7);
    try testing.expectEqual([2]u32{ 400, 300 }, window.windowMaterial().blur_region_size.?);
    try testing.expectEqual(@as(u32, 2), window.windowMaterial().blur_regions_sent);
    try testing.expectEqual(null, systemMaterialOf(&window.polled));
    _ = window.polled.poll(window.host());
    try testing.expectEqual(@as(u32, 2), window.windowMaterial().blur_regions_sent);
}

test "a transient material, where only KWin's blur is offered, is blurred through it, and the background effect wins where both are" {
    var kde: MaterialWindow = .{ .window = .{ .material = .transient, .blur_offers = .{ .kde_blur = true } } };
    try kde.open();
    defer kde.close();
    try testing.expect(holdsAlpha(kde.host(), .main));
    try testing.expectEqual(material.BlurProtocol.kde_blur, kde.windowMaterial().protocol.?);
    try testing.expectEqual([2]u32{ 320, 240 }, kde.windowMaterial().blur_region_size.?);
    try testing.expectEqual(true, systemMaterialOf(&kde.polled).?);
    kde.resize(.{ 500, 200 }, 3);
    try testing.expectEqual([2]u32{ 500, 200 }, kde.windowMaterial().blur_region_size.?);

    var both: MaterialWindow = .{ .window = .{ .material = .window, .blur_offers = .{ .background_effect_blurs = true, .kde_blur = true } } };
    try both.open();
    defer both.close();
    try testing.expectEqual(material.BlurProtocol.background_effect, both.windowMaterial().protocol.?);
}

test "where the compositor blurs through neither protocol, or the material is unavailable, the window stays opaque and reports none" {
    const neither = [_]UnshownWindow{
        .{ .material = .window, .blur_offers = .{} },
        .{ .material = .window, .blur_offers = .{ .background_effect_blurs = true }, .system_material_unavailable = true },
    };
    for (neither) |unshown| {
        var window: MaterialWindow = .{ .window = unshown };
        try window.open();
        defer window.close();
        try testing.expect(!holdsAlpha(window.host(), .main));
        try testing.expectEqual(null, window.windowMaterial().protocol);
        try testing.expectEqual(@as(u32, 0), window.windowMaterial().blur_regions_sent);
        try testing.expectEqual(false, systemMaterialOf(&window.polled).?);
    }
}

test "a window opened without a material never asks for a blur, wherever one is offered" {
    var window: MaterialWindow = .{ .window = .{ .material = .none, .blur_offers = .{ .background_effect_blurs = true, .kde_blur = true } } };
    try window.open();
    defer window.close();
    try testing.expect(!holdsAlpha(window.host(), .main));
    window.resize(.{ 400, 300 }, 2);
    try testing.expectEqual(@as(u32, 0), window.windowMaterial().blur_regions_sent);
    try testing.expectEqual(false, systemMaterialOf(&window.polled) orelse reportedEnvironment(&window.polled).system_material);
}

test "reduced transparency turns the system material off, and its end turns it on again" {
    var window: MaterialWindow = .{ .window = .{ .material = .window, .blur_offers = .{ .background_effect_blurs = true } } };
    try window.open();
    defer window.close();
    const window_host = window.host();

    window_host.onDesktopReport(.{ .reduced_transparency = true });
    _ = window.polled.poll(window_host);
    try testing.expectEqual(false, systemMaterialOf(&window.polled).?);
    try testing.expect(reportedEnvironment(&window.polled).reduced_transparency);
    try testing.expect(holdsAlpha(window_host, .main));

    window_host.onDesktopReport(.{ .reduced_transparency = false });
    _ = window.polled.poll(window_host);
    try testing.expectEqual(true, systemMaterialOf(&window.polled).?);
}

test "a background effect that stops blurring turns the system material off until it blurs again; one that never blurred leaves the window opaque" {
    var window: MaterialWindow = .{ .window = .{ .material = .window, .blur_offers = .{ .background_effect_blurs = true } } };
    try window.open();
    defer window.close();
    const window_host = window.host();
    window_host.onBackgroundEffectCapabilities(0);
    _ = window.polled.poll(window_host);
    try testing.expectEqual(false, systemMaterialOf(&window.polled).?);
    window_host.onBackgroundEffectCapabilities(1);
    _ = window.polled.poll(window_host);
    try testing.expectEqual(true, systemMaterialOf(&window.polled).?);

    var never: MaterialWindow = .{ .window = .{ .material = .window, .blur_offers = .{} } };
    try never.open();
    defer never.close();
    never.host().onBackgroundEffectCapabilities(1);
    _ = never.polled.poll(never.host());
    try testing.expectEqual(null, systemMaterialOf(&never.polled));
    try testing.expect(!holdsAlpha(never.host(), .main));
}

test "each window's material is its own" {
    var window: MaterialWindow = .{ .window = .{ .material = .window, .blur_offers = .{ .background_effect_blurs = true } } };
    try window.open();
    defer window.close();
    const window_host = window.host();
    const opaque_window = try window_host.zuiOpenWindow(second_window_options);
    var second_options = second_window_options;
    second_options.material = .transient;
    second_options.size = .{ 200, 100 };
    const blurred_window = try window_host.zuiOpenWindow(second_options);

    try testing.expect(holdsAlpha(window_host, .main));
    try testing.expect(!holdsAlpha(window_host, opaque_window));
    try testing.expect(holdsAlpha(window_host, blurred_window));
    try testing.expectEqual([2]u32{ 200, 100 }, window_host.windowById(blurred_window).?.window_material.blur_region_size.?);
    try testing.expectEqual(@as(u32, 0), window_host.windowById(opaque_window).?.window_material.blur_regions_sent);

    var polled: zui_testing.PolledRecord = .{};
    polled.init();
    _ = polled.pollWindow(window_host, opaque_window);
    try testing.expectEqual(false, systemMaterialOf(&polled).?);
    _ = polled.pollWindow(window_host, blurred_window);
    try testing.expectEqual(true, systemMaterialOf(&polled).?);
}

test "under the real compositor, a window with a material is blurred and holds alpha exactly where a blur protocol is bound" {
    var window: MaterialWindow = .{ .window = .{ .material = .window, .blur_offers = null, .has_toplevel = true } };
    try window.open();
    defer window.close();
    const window_host = window.host();
    const blurs = window_host.blur_offers.preferred() != null;
    try testing.expectEqual(blurs, holdsAlpha(window_host, .main));
    try testing.expectEqual(blurs, window.windowMaterial().effect != null);
    try testing.expectEqual(blurs, systemMaterialOf(&window.polled).?);
    if (window_host.globals.kde_blur_manager == null and window_host.globals.background_effect_manager == null) try testing.expect(!blurs);
}

test "a dead acute and e type é once, Multi_key o c types ©, and a cancelled sequence types nothing, each press still a key" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    try compose_testing.expectComposes(window.host(), struct {
        fn press(window_host: *Host, evdev_code: u32, pressed: bool) void {
            window_host.onKey(evdev_code, pressed);
        }
    }.press);
}

const compose_testing = @import("compose_testing.zig");

test {
    _ = @import("x11_conformance.zig");
}

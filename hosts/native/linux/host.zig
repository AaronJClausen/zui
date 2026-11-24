const std = @import("std");
const zui = @import("zui");
pub const wayland = @import("wayland.zig");
pub const x11 = @import("x11.zig");
pub const xkb = @import("xkb.zig");
pub const keys = @import("keys.zig");
pub const dbus = @import("dbus.zig");
pub const desktop_bus = @import("desktop_bus.zig");
pub const data_device = @import("data_device.zig");
pub const text_input = @import("text_input.zig");
pub const ibus = @import("ibus.zig");
pub const file_watch = @import("file_watch.zig");
pub const services = @import("services.zig");
pub const chrome = @import("chrome.zig");
pub const x11_chrome = @import("x11_chrome.zig");
pub const material = @import("material.zig");
pub const WaylandHost = @import("wayland_host.zig").WaylandHost;
pub const X11Host = @import("x11_host.zig").X11Host;

/// The display server a Linux host shows its windows on.
pub const Backend = enum { wayland, x11 };

/// The variable that forces a backend, `wayland` or `x11`.
pub const backend_variable = "ZUI_HOST_BACKEND";

/// zui's host contract on Linux: `WaylandHost` where a Wayland compositor
/// answers, and `X11Host` otherwise, chosen at `init`. `ZUI_HOST_BACKEND`
/// set to `wayland` or `x11` forces one, and `forced_backend` wins over
/// it. Each call is one switch on the backend chosen.
///
/// Its declarations are the Wayland host's, and both backends open up to
/// `max_windows` windows. On X11, which does not yet do all of them, a
/// call answers as on a compositor without the protocol: the environment
/// reports no system material.
///
/// ```zig
/// const App = struct {
///     pub const Host = zui_host.Host;
///     pub const Renderer = zui_sokol.Renderer;
///     // ...
/// };
/// ```
pub const Host = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initMany(&.{ .wayland, .x11 });
    pub const zui_capabilities: zui.HostCapabilities = WaylandHost.zui_capabilities;
    pub const max_windows = WaylandHost.max_windows;
    pub const wheel_step = WaylandHost.wheel_step;

    comptime {
        std.debug.assert(X11Host.max_windows == max_windows);
    }

    pub const zuiClipboard = struct {
        pub fn write(host: *Host, text: []const u8) zui.ServiceError!void {
            return switch (host.backend) {
                inline else => |*chosen| @TypeOf(chosen.*).zuiClipboard.write(chosen, text),
            };
        }

        pub fn read(host: *Host, request: zui.ServiceRequest, sink: zui.ServiceSink) zui.ServiceError!void {
            return switch (host.backend) {
                inline else => |*chosen| @TypeOf(chosen.*).zuiClipboard.read(chosen, request, sink),
            };
        }
    };

    pub const zuiFileWatch = struct {
        pub fn watch(host: *Host, directory: []const u8, sink: zui.FileChangeSink) zui.FileWatchError!void {
            return switch (host.backend) {
                inline else => |*chosen| @TypeOf(chosen.*).zuiFileWatch.watch(chosen, directory, sink),
            };
        }
    };

    pub const zuiOpenUrl = struct {
        pub fn open(host: *Host, url: []const u8) zui.ServiceError!void {
            return switch (host.backend) {
                inline else => |*chosen| @TypeOf(chosen.*).zuiOpenUrl.open(chosen, url),
            };
        }
    };

    pub const zuiNotifications = struct {
        pub fn show(host: *Host, request: zui.ServiceRequest, notification: zui.Notification, sink: zui.ServiceSink) zui.ServiceError!void {
            return switch (host.backend) {
                inline else => |*chosen| @TypeOf(chosen.*).zuiNotifications.show(chosen, request, notification, sink),
            };
        }
    };

    pub const zuiFileDialogs = struct {
        pub fn show(host: *Host, window: zui.WindowId, request: zui.ServiceRequest, dialog: zui.FileDialog, sink: zui.ServiceSink) zui.ServiceError!void {
            return switch (host.backend) {
                inline else => |*chosen| @TypeOf(chosen.*).zuiFileDialogs.show(chosen, window, request, dialog, sink),
            };
        }
    };

    /// The backend `init` connects to, in place of `ZUI_HOST_BACKEND` and
    /// the choice.
    forced_backend: ?Backend = null,
    /// Each of these is given to the backend `init` chooses; see
    /// `WaylandHost`'s.
    forced_scale: ?f32 = null,
    bus_addresses: ?desktop_bus.Addresses = null,
    service_fake: ?*services.ServiceFake = null,
    /// Wayland only: X11 shows no material yet.
    system_material_unavailable: bool = false,
    forced_blur_offers: ?material.BlurOffers = null,

    backend: union(Backend) { wayland: WaylandHost, x11: X11Host },

    /// What `init` does with no backend forced, or with one.
    pub const Choice = enum { wayland_then_x11, wayland, x11 };

    /// What the value of `ZUI_HOST_BACKEND` asks for; anything but
    /// `wayland` or `x11` is the usual choice.
    pub fn choiceOf(variable: ?[]const u8) Choice {
        const named = variable orelse return .wayland_then_x11;
        const backend = std.meta.stringToEnum(Backend, named) orelse return .wayland_then_x11;
        return switch (backend) {
            .wayland => .wayland,
            .x11 => .x11,
        };
    }

    /// Connects to Wayland, or where no compositor answers, to X11.
    pub fn init(self: *Host, io: std.Io, options: zui.WindowOptions) !void {
        const choice: Choice = if (self.forced_backend) |backend| switch (backend) {
            .wayland => .wayland,
            .x11 => .x11,
        } else choiceOf(if (std.c.getenv(backend_variable)) |value| std.mem.span(value) else null);
        if (choice != .x11) {
            if (self.initWayland(io, options)) return else |err| switch (err) {
                error.NoWaylandDisplay, error.CompositorUnreachable => if (choice == .wayland or std.c.getenv("DISPLAY") == null) return err,
                else => return err,
            }
        }
        try self.initX11(io, options);
    }

    fn initWayland(self: *Host, io: std.Io, options: zui.WindowOptions) !void {
        self.backend = .{ .wayland = undefined };
        const chosen = &self.backend.wayland;
        chosen.forced_scale = self.forced_scale;
        chosen.bus_addresses = self.bus_addresses;
        chosen.service_fake = self.service_fake;
        chosen.system_material_unavailable = self.system_material_unavailable;
        chosen.forced_blur_offers = self.forced_blur_offers;
        try chosen.init(io, options);
    }

    fn initX11(self: *Host, io: std.Io, options: zui.WindowOptions) !void {
        self.backend = .{ .x11 = undefined };
        const chosen = &self.backend.x11;
        chosen.forced_scale = self.forced_scale;
        chosen.bus_addresses = self.bus_addresses;
        chosen.service_fake = self.service_fake;
        chosen.forced_window_manager_support = null;
        chosen.input_method_bus = null;
        try chosen.init(io, options);
    }

    /// Call after the renderer's `deinit`.
    pub fn deinit(self: *Host) void {
        switch (self.backend) {
            inline else => |*chosen| chosen.deinit(),
        }
    }

    /// The backend `init` connected to.
    pub fn backendInUse(self: *const Host) Backend {
        return self.backend;
    }

    pub fn now(self: *const Host) zui.Instant {
        return switch (self.backend) {
            inline else => |*chosen| chosen.now(),
        };
    }

    pub fn zuiPoll(self: *Host, id: zui.WindowId, record: *zui.RecordBuilder) bool {
        return switch (self.backend) {
            inline else => |*chosen| chosen.zuiPoll(id, record),
        };
    }

    pub fn zuiWait(self: *Host, next: zui.NextFrame) void {
        switch (self.backend) {
            inline else => |*chosen| chosen.zuiWait(next),
        }
    }

    pub fn zuiWaker(self: *Host) zui.Waker {
        return switch (self.backend) {
            inline else => |*chosen| chosen.zuiWaker(),
        };
    }

    pub fn zuiSurface(self: *Host, id: zui.WindowId) zui.Surface {
        return switch (self.backend) {
            inline else => |*chosen| chosen.zuiSurface(id),
        };
    }

    pub fn zuiApply(self: *Host, id: zui.WindowId, requests: zui.HostRequests) void {
        switch (self.backend) {
            inline else => |*chosen| chosen.zuiApply(id, requests),
        }
    }

    /// See `WaylandHost.zuiOpenWindow` and `X11Host.zuiOpenWindow`.
    pub fn zuiOpenWindow(self: *Host, options: zui.WindowOptions) zui.OpenWindowError!zui.WindowId {
        return switch (self.backend) {
            inline else => |*chosen| chosen.zuiOpenWindow(options),
        };
    }

    /// Closes any window, `.main` included; its id then polls false.
    pub fn zuiCloseWindow(self: *Host, id: zui.WindowId) void {
        switch (self.backend) {
            inline else => |*chosen| chosen.zuiCloseWindow(id),
        }
    }

    /// See `WaylandHost.zuiChromeRegions` and `X11Host.zuiChromeRegions`.
    pub fn zuiChromeRegions(self: *Host, id: zui.WindowId, regions: []const zui.ChromeRegion) void {
        switch (self.backend) {
            inline else => |*chosen| chosen.zuiChromeRegions(id, regions),
        }
    }

    /// What a press at `position`, in `id`'s surface coordinates (an X11
    /// window's physical pixels), would be to the window manager: null
    /// where it reaches zui.
    pub fn chromeKindAt(self: *Host, id: zui.WindowId, position: [2]f32) ?zui.ChromeKind {
        return switch (self.backend) {
            inline else => |*chosen| chosen.chromeKindAt(id, position),
        };
    }

    /// What the last poll of `id` converted surface coordinates to layout
    /// units by, or 1 for a window that is not open.
    pub fn surfaceCoordinatesPerUnit(self: *Host, id: zui.WindowId) f32 {
        return switch (self.backend) {
            inline else => |*chosen| chosen.surfaceCoordinatesPerUnit(id),
        };
    }

    /// Answers services through `fake` instead of the bus, from the next
    /// call on.
    pub fn fakeServices(self: *Host, fake: *services.ServiceFake) void {
        self.service_fake = fake;
        switch (self.backend) {
            inline else => |*chosen| chosen.fakeServices(fake),
        }
    }

    /// Closes the main window as its close button does: the next poll
    /// returns false.
    pub fn close(self: *Host) void {
        switch (self.backend) {
            inline else => |*chosen| chosen.close(),
        }
    }

    /// Asks the compositor or the window manager to minimize the main
    /// window.
    pub fn minimize(self: *Host) void {
        switch (self.backend) {
            inline else => |*chosen| chosen.minimize(),
        }
    }

    /// Asks the compositor or the window manager to maximize or restore the
    /// main window.
    pub fn toggleMaximized(self: *Host) void {
        switch (self.backend) {
            inline else => |*chosen| chosen.toggleMaximized(),
        }
    }
};

test {
    _ = keys;
    _ = dbus;
    _ = desktop_bus;
    _ = data_device;
    _ = text_input;
    _ = ibus;
    _ = file_watch;
    _ = services;
    _ = chrome;
    _ = x11_chrome;
    _ = material;
    _ = @import("x11_host.zig");
    _ = @import("x11_selections.zig");
}

test "ZUI_HOST_BACKEND forces wayland or x11, and anything else leaves the choice to the compositor" {
    try std.testing.expectEqual(Host.Choice.wayland_then_x11, Host.choiceOf(null));
    try std.testing.expectEqual(Host.Choice.wayland, Host.choiceOf("wayland"));
    try std.testing.expectEqual(Host.Choice.x11, Host.choiceOf("x11"));
    try std.testing.expectEqual(Host.Choice.wayland_then_x11, Host.choiceOf("X11"));
    try std.testing.expectEqual(Host.Choice.wayland_then_x11, Host.choiceOf(""));
}

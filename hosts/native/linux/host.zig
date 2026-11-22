const std = @import("std");
const zui = @import("zui");
const linux = std.os.linux;
pub const wayland = @import("wayland.zig");
pub const xkb = @import("xkb.zig");
pub const keys = @import("keys.zig");
pub const dbus = @import("dbus.zig");
pub const desktop_bus = @import("desktop_bus.zig");
pub const data_device = @import("data_device.zig");
pub const text_input = @import("text_input.zig");
pub const file_watch = @import("file_watch.zig");
pub const services = @import("services.zig");
pub const chrome = @import("chrome.zig");
pub const material = @import("material.zig");

const Proxy = wayland.Proxy;

/// zui's host contract on Wayland windows, through libwayland-client and
/// xdg-shell, on the thread that polls them: a Wayland client has no modal
/// loop to escape, so events are read and dispatched in `zuiPoll` and
/// `zuiWait`.
///
/// It reports the scale the compositor prefers, fractional where it
/// offers fractional scales and viewports, the pointer, the wheel, keys
/// through the compositor's keymap with their modifiers, evdev codes and
/// repeats, typed text, focus, files dropped and the close button; the
/// environment the desktop reports over D-Bus (theme, contrast, reduced
/// motion, power); and SIGINT, SIGTERM and SIGHUP as terminate requests
/// and the system sleeping and waking as lifecycle events. It sets the
/// cursor where the compositor offers cursor shapes, enables an input
/// method's text at the caret of a frame's text-input request where it
/// offers text input, reads and writes the clipboard, watches
/// directories, offers notifications, file dialogs and opening URLs over
/// the session bus, and waits for `nextFrame` on the
/// display, the desktop's buses, its transfers and watches, a wake and a
/// deadline.
///
/// `init` opens `.main`, and `zuiOpenWindow` up to `max_windows - 1` more,
/// each a surface with its own events, scale, requests and chrome. The
/// pointer's and the keyboard's events reach the window whose surface
/// they entered. The seat, the clipboard, the watches and the services
/// belong to the host, so they work whichever windows are open, and a
/// terminate request, the system sleeping and the desktop's settings
/// reach every window.
///
/// A window opened with `title_bar = .custom` asks the compositor, through
/// xdg-decoration where it is offered, to leave the decorations to the
/// window. Presses on the frame's chrome regions go to the compositor: the
/// title bar moves the window, maximizes it on a double click and opens
/// the window menu on a secondary click, and the edges resize it. The host
/// works the caption buttons itself, and reports `custom_title_bar` and
/// `window_maximized`. A compositor that insists on drawing its own title
/// bar gets it, and `custom_title_bar` is then false.
///
/// A window opened with a `material` other than `.none` gets a surface
/// that holds alpha and a blur behind the whole of it, through
/// `ext_background_effect_v1`, or KWin's `org_kde_kwin_blur` where only
/// that is offered, and reports `system_material` true unless reduced
/// transparency is on. Where the compositor blurs through neither, the
/// window stays opaque and reports it false.
///
/// `deinit` closes every window; the host must not move after `init`,
/// since the compositor's listeners and the signal handler hold pointers
/// into it. A window opened with `visible = false` is a surface without a
/// role, which the compositor never shows.
///
/// ```zig
/// const App = struct {
///     pub const Host = zui_host.Host;
///     pub const Renderer = zui_sokol.Renderer;
///     // ...
/// };
/// ```
pub const Host = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.wayland);
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .many, .system_material = true, .custom_title_bar = true };

    /// The windows open at once, `.main` among them.
    pub const max_windows = 4;

    /// The clipboard's selection, as text. `write` offers it as UTF-8 to
    /// any reader, up to `data_device.DataDevice.clipboard_text_capacity`
    /// bytes. `read` answers from the host's wait once the selection's
    /// owner has written it, with up to that many bytes, `""` when the
    /// clipboard holds no text, or `.failed` when its owner takes longer
    /// than `data_device.DataDevice.transfer_timeout_ns`. While no other
    /// selection has been named since the last `write`, it answers that
    /// text at once.
    pub const zuiClipboard = struct {
        pub fn write(host: *Host, text: []const u8) zui.ServiceError!void {
            try host.data_device.writeSelection(host.globals.data_device_manager, text, host.latest_input_serial);
            _ = wayland.wl_display_flush(host.display);
        }

        pub fn read(host: *Host, request: zui.ServiceRequest, sink: zui.ServiceSink) zui.ServiceError!void {
            try host.data_device.readSelection(request, sink, host.zuiWaker());
            _ = wayland.wl_display_flush(host.display);
        }
    };

    /// Watches up to `file_watch.Watches.capacity` directories, each with
    /// its subdirectories, until `deinit`, publishing from the host's wait.
    pub const zuiFileWatch = struct {
        pub fn watch(host: *Host, directory: []const u8, sink: zui.FileChangeSink) zui.FileWatchError!void {
            return host.file_watches.start(directory, sink, host.zuiWaker());
        }
    };

    /// Hands a URL to the XDG desktop portal's `OpenURI`, which opens it
    /// with the handler for its scheme, refusing paths and `file:` URLs and
    /// ones longer than `services.Services.url_capacity` bytes.
    pub const zuiOpenUrl = struct {
        pub fn open(host: *Host, url: []const u8) zui.ServiceError!void {
            return host.services.openUrl(host.io, url);
        }
    };

    /// A notification from the desktop's notification daemon, through
    /// `org.freedesktop.Notifications`: its title cut at a character to
    /// `services.Services.notification_title_capacity` bytes and its body
    /// to `notification_body_capacity`. It answers `.notification_activated`
    /// when clicked, `.notification_dismissed` when it expires, is closed,
    /// or the next one replaces it, and `.failed = .unavailable` when no
    /// daemon answers; one still showing at `deinit` is closed and not
    /// answered. Until the daemon has taken one, the next is
    /// `error.Busy`.
    pub const zuiNotifications = struct {
        pub fn show(host: *Host, request: zui.ServiceRequest, notification: zui.Notification, sink: zui.ServiceSink) zui.ServiceError!void {
            return host.services.showNotification(host.io, request, notification, sink);
        }
    };

    /// The XDG desktop portal's `FileChooser` dialogs, `OpenFile` and
    /// `SaveFile`, one at a time. They answer `.files_chosen` with
    /// file-system paths, up to `services.Services.chosen_paths_capacity`
    /// bytes of them, `.canceled`, or `.failed = .unavailable` when no
    /// portal answers, naming the window. One still open at `deinit` is
    /// closed and not answered; a window that is not open is
    /// `error.Unavailable`.
    pub const zuiFileDialogs = struct {
        pub fn show(host: *Host, window: zui.WindowId, request: zui.ServiceRequest, dialog: zui.FileDialog, sink: zui.ServiceSink) zui.ServiceError!void {
            const target = host.windowById(window) orelse return error.Unavailable;
            if (target.closed) return error.Unavailable;
            return host.services.showFileDialog(host.io, request, window, dialog, sink);
        }
    };

    /// Layout units scrolled per notch of the mouse wheel.
    pub const wheel_step = 40;

    io: std.Io,
    /// Physical pixels per layout unit in place of the buffer scale, for
    /// tests that must not depend on the monitor.
    forced_scale: ?f32 = null,
    /// The buses the environment is read from in place of the session's
    /// and the system's, for tests that must not depend on the desktop.
    bus_addresses: ?desktop_bus.Addresses = null,
    /// Answers services as a test says instead of handing them to the
    /// bus, so nothing shows or opens.
    service_fake: ?*services.ServiceFake = null,
    /// Behaves as under a compositor that blurs behind no window, so the
    /// fallback can be seen where one does.
    system_material_unavailable: bool = false,
    /// What the compositor offers to blur through, in place of what it
    /// advertises, for tests that must not depend on the compositor: the
    /// blur managers are then not bound, and nothing is sent.
    forced_blur_offers: ?material.BlurOffers = null,

    display: *wayland.Display,
    registry: *Proxy,
    globals: Globals,
    blur_offers: material.BlurOffers,
    pointer: ?*Proxy,
    keyboard: ?*Proxy,
    cursor_shape_device: ?*Proxy,
    xkb_context: *xkb.Context,
    keymap: ?*xkb.Keymap,
    key_state: ?*xkb.State,
    /// An eventfd: any thread writes it, and the wait reads it after it
    /// returns, so a wake that came before the wait ends it.
    wake_fd: i32,

    windows: [max_windows]Window,
    /// The id the next window opens with; ids are never given twice.
    next_window_id: u32,
    /// The window whose surface the pointer entered, until it leaves.
    pointer_window: ?*Window,
    /// The window whose surface has the keyboard's focus.
    keyboard_window: ?*Window,
    /// The window whose surface has the seat's text-input focus.
    text_input_window: ?*Window,
    /// The window the last drag entered, which its drop's files reach.
    drag_window: ?*Window,

    /// In the surface coordinates of `pointer_window`.
    pointer_position: [2]f32,
    pointer_enter_serial: ?u32,
    /// The serial of the last key, button or focus, which setting the
    /// clipboard's selection names.
    latest_input_serial: u32,
    /// In the surface coordinates of `drag_window`.
    drag_position: [2]f32,
    wheel_notches: [2]?i32,
    modifiers: zui.Modifiers,
    key_repeat: KeyRepeat,

    data_device: data_device.DataDevice,
    text_input: text_input.TextInput,
    file_watches: file_watch.Watches,
    desktop: desktop_bus.DesktopBus,
    desktop_settings: DesktopSettings,
    services: services.Services,

    /// Set by the signal handler, and delivered by the next poll.
    termination_signalled: std.atomic.Value(bool),
    /// For each of `termination_signals`, whether this host handles it,
    /// and what `deinit` gives it back.
    handled_signals: [termination_signals.len]bool,
    replaced_signal_actions: [termination_signals.len]std.posix.Sigaction,

    const event_capacity = 512;
    const text_capacity = 1024;
    const path_capacity = 16 * 1024;
    const app_id = "zui";
    /// How long `init` waits for the desktop's settings, so the first frame
    /// has them; later answers arrive as changes.
    const desktop_answer_ns = 250 * std.time.ns_per_ms;
    /// A frame late by more repeats than this gets this many, not a burst.
    const most_repeats_at_once = 4;
    /// Keys per second; a compositor asking for more gets this many.
    const fastest_repeat_rate = 1000;
    const termination_signals = [_]std.posix.SIG{ .INT, .TERM, .HUP };

    const KeyRepeat = struct {
        /// Keys per second; 0 turns repeating off. Until the compositor
        /// says otherwise, which before wl_keyboard version 4 it never
        /// does, X's usual rate and delay.
        rate: u32 = 25,
        delay_ns: u64 = 600 * std.time.ns_per_ms,
        held: ?HeldKey = null,

        const HeldKey = struct { evdev_code: u32, next_at: zui.Instant };
    };

    const DesktopSettings = struct {
        theme: zui.Environment.Theme = .light,
        contrast: zui.Environment.Contrast = .normal,
        reduced_motion: bool = false,
        reduced_transparency: bool = false,
        on_battery: bool = false,
        power_saver: bool = false,
    };

    /// The fields of `zui.Environment` the desktop's settings and the
    /// compositor's configures decide.
    const ReportedEnvironment = struct {
        theme: zui.Environment.Theme,
        contrast: zui.Environment.Contrast,
        reduced_motion: bool,
        reduced_transparency: bool,
        power: zui.Environment.Power,
        system_material: bool,
        custom_title_bar: bool,
        window_maximized: bool,
    };

    const Globals = struct {
        compositor: ?*Proxy = null,
        wm_base: ?*Proxy = null,
        seat: ?*Proxy = null,
        cursor_shape_manager: ?*Proxy = null,
        data_device_manager: ?*Proxy = null,
        viewporter: ?*Proxy = null,
        fractional_scale_manager: ?*Proxy = null,
        text_input_manager: ?*Proxy = null,
        decoration_manager: ?*Proxy = null,
        background_effect_manager: ?*Proxy = null,
        kde_blur_manager: ?*Proxy = null,
    };

    const Inbox = struct {
        /// Positions are in surface coordinates until a poll converts them.
        events: [event_capacity]zui.Event = undefined,
        event_count: usize = 0,
        text: [text_capacity]u8 = undefined,
        text_len: usize = 0,
        paths: [path_capacity]u8 = undefined,
        path_len: usize = 0,
        dropped_events: u32 = 0,
        dropped_bytes: u32 = 0,

        fn push(self: *Inbox, event: zui.Event) void {
            if (self.event_count == event_capacity) {
                self.dropped_events +|= 1;
                return;
            }
            self.events[self.event_count] = event;
            self.event_count += 1;
        }

        /// Consecutive characters become one text event.
        fn pushText(self: *Inbox, utf8: []const u8) void {
            if (utf8.len > text_capacity - self.text_len) {
                self.dropped_bytes +|= @intCast(utf8.len);
                return;
            }
            const start = self.text_len;
            @memcpy(self.text[start..][0..utf8.len], utf8);
            self.text_len += utf8.len;
            if (self.event_count > 0) {
                const last = &self.events[self.event_count - 1];
                if (last.* == .text and last.text.ptr + last.text.len == self.text[start..].ptr) {
                    last.text = self.text[start - last.text.len .. self.text_len];
                    return;
                }
            }
            self.push(.{ .text = self.text[start..self.text_len] });
        }

        /// One event for the local files a URI list names; none when it
        /// names none that fit.
        fn pushFilesDropped(self: *Inbox, position: [2]f32, uri_list: []const u8, at: zui.Instant) void {
            const start = self.path_len;
            const decoded = data_device.pathsFromUriList(uri_list, self.paths[start..]);
            self.dropped_bytes +|= decoded.left_out_bytes;
            if (decoded.len == 0) return;
            self.path_len += decoded.len;
            self.push(.{ .files_dropped = .{ .position = position, .path_list = self.paths[start..self.path_len], .at = at } });
        }

        fn clear(self: *Inbox) void {
            self.* = .{};
        }
    };

    /// One of the host's windows: its surface and the role that shows it,
    /// what it has been told and asked since its last poll, its size and
    /// scale, and its chrome.
    pub const Window = struct {
        host: *Host,
        id: zui.WindowId = .main,
        /// Holds an open window, from `zuiOpenWindow` to `zuiCloseWindow`.
        in_use: bool = false,
        surface: *Proxy = undefined,
        xdg_surface: ?*Proxy = null,
        toplevel: ?*Proxy = null,
        /// Both null unless the compositor offers fractional scales and
        /// viewports, which the host uses together.
        fractional_scale: ?*Proxy = null,
        viewport: ?*Proxy = null,

        inbox: Inbox = .{},
        /// Something reached the inbox, or changed the next frame's size or
        /// scale, since the last poll.
        input_arrived: bool = false,
        closed: bool = false,
        configured: bool = false,
        /// The poll after the one that delivered a terminate request reports
        /// the window closed.
        terminate_delivered: bool = false,
        /// In surface coordinates, which are physical pixels over
        /// `pixelsPerSurfaceCoordinate()`.
        surface_size: [2]u32 = .{ 0, 0 },
        configured_size: ?[2]u32 = null,
        buffer_scale: i32 = 1,
        /// In 120ths, null until the compositor first prefers one; from then
        /// on the buffer scale stays 1 and the viewport sizes the surface.
        preferred_fractional_scale: ?u32 = null,
        /// The surface size the viewport was last given.
        viewport_destination: ?[2]u32 = null,
        /// What the last poll converted surface coordinates to layout units by.
        surface_coordinates_per_unit: f32 = 1,
        requests: zui.HostRequests = .{},
        applied_cursor: ?zui.Cursor = null,
        window_chrome: chrome.WindowChrome = .{},
        window_material: material.WindowMaterial = .{},
        /// Null until the window has reported the whole environment.
        reported_environment: ?ReportedEnvironment = null,

        fn deliver(self: *Window, event: zui.Event) void {
            self.inbox.push(event);
            self.input_arrived = true;
        }

        fn deliverText(self: *Window, utf8: []const u8) void {
            self.inbox.pushText(utf8);
            self.input_arrived = true;
        }

        /// The buffer's physical pixels per surface coordinate: the fractional
        /// scale once the compositor prefers one, the buffer scale until then.
        /// The renderer sizes the buffer at the viewport times the scale,
        /// which is the surface's size times this.
        pub fn pixelsPerSurfaceCoordinate(self: *const Window) f32 {
            if (self.preferred_fractional_scale) |scale_120ths| return @as(f32, @floatFromInt(scale_120ths)) / wayland.fractional_scale_denominator;
            return @floatFromInt(self.buffer_scale);
        }

        /// At a fractional scale the buffer is drawn at physical pixels, so
        /// the viewport gives the surface its size in surface coordinates; the
        /// renderer's next commit applies it.
        fn sizeViewport(self: *Window) void {
            if (self.preferred_fractional_scale == null) return;
            const viewport = self.viewport orelse return;
            if (std.meta.eql(self.viewport_destination, @as(?[2]u32, self.surface_size))) return;
            self.viewport_destination = self.surface_size;
            wayland.send(viewport, wayland.viewport_set_destination, .{ @as(i32, @intCast(self.surface_size[0])), @as(i32, @intCast(self.surface_size[1])) });
        }

        fn windowManager(self: *const Window) chrome.WindowManager {
            return .{ .toplevel = self.toplevel, .seat = self.host.globals.seat };
        }

        fn workCaptionButton(self: *Window, kind: zui.ChromeKind) void {
            switch (kind) {
                .minimize_button => self.window_chrome.minimize(self.windowManager()),
                .maximize_button => self.window_chrome.toggleMaximized(self.windowManager()),
                .close_button => self.onClose(),
                else => {},
            }
        }

        /// Until the host reports the whole environment, a change waits for it.
        fn reportEnvironmentOnceReported(self: *Window) void {
            if (self.reported_environment != null) self.reportEnvironment(self.host.desktop_settings);
        }

        /// Reports each setting that differs from what the window last
        /// reported, or every one the first time.
        fn reportEnvironment(self: *Window, settings: DesktopSettings) void {
            const current: ReportedEnvironment = .{
                .theme = settings.theme,
                .contrast = settings.contrast,
                .reduced_motion = settings.reduced_motion,
                .reduced_transparency = settings.reduced_transparency,
                .power = if (settings.power_saver) .saver else if (settings.on_battery) .battery else .plugged,
                .system_material = self.showsBlur() and !settings.reduced_transparency,
                .custom_title_bar = self.window_chrome.isCustom(),
                .window_maximized = self.window_chrome.maximized,
            };
            const reported = self.reported_environment;
            inline for (std.meta.fields(ReportedEnvironment)) |field| {
                const value = @field(current, field.name);
                if (reported == null or @field(reported.?, field.name) != value) {
                    self.deliver(.{ .environment = @unionInit(zui.EnvironmentChange, field.name, value) });
                }
            }
            self.reported_environment = current;
        }

        /// The window holds alpha and the compositor still offers the blur
        /// it was opened with.
        fn showsBlur(self: *const Window) bool {
            const protocol = self.window_material.protocol orelse return false;
            return self.host.blur_offers.offers(protocol);
        }

        fn coverWithBlur(self: *Window) void {
            self.window_material.cover(self.host.globals.compositor.?, self.surface_size);
        }

        fn destroyObjects(self: *Window) void {
            self.window_material.deinit();
            if (self.fractional_scale) |fractional_scale| wayland.destroy(fractional_scale, wayland.fractional_scale_destroy);
            if (self.viewport) |viewport| wayland.destroy(viewport, wayland.viewport_destroy);
            self.window_chrome.deinit();
            if (self.toplevel) |toplevel| wayland.destroy(toplevel, wayland.xdg_toplevel_destroy);
            if (self.xdg_surface) |xdg_surface| wayland.destroy(xdg_surface, wayland.xdg_surface_destroy);
            wayland.destroy(self.surface, wayland.surface_destroy);
            self.fractional_scale = null;
            self.viewport = null;
            self.toplevel = null;
            self.xdg_surface = null;
        }

        // =============================================================
        // What the compositor reports about this window. A harness calls
        // these as the compositor's events would.
        // =============================================================

        pub fn onConfigure(self: *Window, serial: u32) void {
            if (self.xdg_surface) |xdg_surface| wayland.send(xdg_surface, wayland.xdg_surface_ack_configure, .{serial});
            if (self.configured_size) |size| self.surface_size = size;
            self.configured = true;
            self.input_arrived = true;
            if (self.window_chrome.applyConfigure()) self.reportEnvironmentOnceReported();
        }

        /// A size of zero leaves the window's size to the client. `states` are
        /// `xdg_toplevel.state`s, of which the host reads `maximized`.
        pub fn onToplevelConfigure(self: *Window, width: i32, height: i32, states: []const u32) void {
            self.configured_size = if (width > 0 and height > 0) .{ @intCast(width), @intCast(height) } else null;
            self.window_chrome.configured_maximized = chrome.statesHoldMaximized(states);
        }

        /// The compositor says who draws the decorations. Drawing its own, it
        /// takes the title bar back from a custom window.
        pub fn onDecorationConfigure(self: *Window, mode: chrome.DecorationMode) void {
            const was_custom = self.window_chrome.isCustom();
            self.window_chrome.onDecorationMode(mode);
            if (was_custom != self.window_chrome.isCustom()) self.reportEnvironmentOnceReported();
        }

        pub fn onClose(self: *Window) void {
            self.closed = true;
            self.input_arrived = true;
        }

        /// Ignored once the compositor has preferred a fractional scale.
        pub fn onPreferredBufferScale(self: *Window, factor: i32) void {
            if (self.preferred_fractional_scale != null) return;
            if (factor < 1 or factor == self.buffer_scale) return;
            self.buffer_scale = factor;
            if (wayland.wl_proxy_get_version(self.surface) >= 3) wayland.send(self.surface, wayland.surface_set_buffer_scale, .{factor});
            self.input_arrived = true;
        }

        /// In 120ths. The buffer scale returns to 1, since the buffer is then
        /// drawn at physical pixels.
        pub fn onPreferredFractionalScale(self: *Window, scale_120ths: u32) void {
            if (scale_120ths == 0 or self.preferred_fractional_scale == scale_120ths) return;
            if (self.buffer_scale != 1 and wayland.wl_proxy_get_version(self.surface) >= 3) wayland.send(self.surface, wayland.surface_set_buffer_scale, .{@as(i32, 1)});
            self.buffer_scale = 1;
            self.preferred_fractional_scale = scale_120ths;
            self.input_arrived = true;
        }
    };

    pub fn init(self: *Host, io: std.Io, options: zui.WindowOptions) !void {
        const display = wayland.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        errdefer wayland.wl_display_disconnect(display);
        const forced_scale = self.forced_scale;
        const bus_addresses = self.bus_addresses;
        const service_fake = self.service_fake;
        const system_material_unavailable = self.system_material_unavailable;
        const forced_blur_offers = self.forced_blur_offers;
        self.* = .{
            .io = io,
            .forced_scale = forced_scale,
            .bus_addresses = bus_addresses,
            .service_fake = service_fake,
            .system_material_unavailable = system_material_unavailable,
            .forced_blur_offers = forced_blur_offers,
            .display = display,
            .registry = undefined,
            .globals = .{},
            .blur_offers = forced_blur_offers orelse .{},
            .pointer = null,
            .keyboard = null,
            .cursor_shape_device = null,
            .xkb_context = xkb.xkb_context_new(0) orelse return error.NoKeyboardContext,
            .keymap = null,
            .key_state = null,
            .wake_fd = undefined,
            .windows = @splat(.{ .host = self }),
            .next_window_id = @intFromEnum(zui.WindowId.main) + 1,
            .pointer_window = null,
            .keyboard_window = null,
            .text_input_window = null,
            .drag_window = null,
            .pointer_position = .{ 0, 0 },
            .pointer_enter_serial = null,
            .latest_input_serial = 0,
            .drag_position = .{ 0, 0 },
            .wheel_notches = .{ null, null },
            .modifiers = .{},
            .key_repeat = .{},
            .data_device = .{ .io = io },
            .text_input = .{},
            .file_watches = .{},
            .desktop = .{},
            .desktop_settings = .{},
            .services = .{ .fake = service_fake },
            .termination_signalled = .init(false),
            .handled_signals = @splat(false),
            .replaced_signal_actions = undefined,
        };
        errdefer xkb.xkb_context_unref(self.xkb_context);
        const wake_fd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(wake_fd) != .SUCCESS) return error.NoWakeEvent;
        self.wake_fd = @intCast(wake_fd);
        errdefer _ = linux.close(self.wake_fd);

        self.registry = wayland.create(wayland.displayProxy(display), wayland.display_get_registry, &wayland.wl_registry_interface, 1, .{wayland.no_id}) orelse return error.NoRegistry;
        wayland.addListener(self.registry, &registry_listener, self);
        if (wayland.wl_display_roundtrip(display) < 0) return error.CompositorUnreachable;
        if (self.globals.compositor == null) return error.NoCompositor;
        const wm_base = self.globals.wm_base orelse return error.NoXdgShell;
        wayland.addListener(wm_base, &wm_base_listener, self);
        if (self.globals.seat) |seat| wayland.addListener(seat, &seat_listener, self);
        self.openDataDevice();
        self.openTextInput();

        // The seat's devices and their keymap each answer what the round
        // trip before them asked for.
        try self.openWindowIn(&self.windows[0], .main, options, 2);

        self.readDesktopEnvironment();
        self.handleTerminationSignals();
    }

    /// Opens a window as `init` opens `.main`, hidden or shown as `options`
    /// say, and returns once the compositor has configured it.
    pub fn zuiOpenWindow(self: *Host, options: zui.WindowOptions) zui.OpenWindowError!zui.WindowId {
        const window = for (&self.windows) |*window| {
            if (!window.in_use) break window;
        } else return error.TooManyWindows;
        const id: zui.WindowId = @enumFromInt(self.next_window_id);
        self.openWindowIn(window, id, options, 0) catch return error.WindowNotCreated;
        self.next_window_id += 1;
        window.reportEnvironment(self.desktop_settings);
        return id;
    }

    /// Destroys `window`'s surface and frees its slot; its id polls false
    /// from now on.
    pub fn zuiCloseWindow(self: *Host, id: zui.WindowId) void {
        const window = self.windowById(id) orelse return;
        if (self.pointer_window == window) self.pointer_window = null;
        if (self.keyboard_window == window) {
            self.keyboard_window = null;
            self.key_repeat.held = null;
        }
        if (self.text_input_window == window) {
            self.text_input_window = null;
            self.text_input.onLeave();
        }
        if (self.drag_window == window) self.drag_window = null;
        window.destroyObjects();
        window.in_use = false;
        _ = wayland.wl_display_flush(self.display);
    }

    /// The open window `id` names, or null.
    pub fn windowById(self: *Host, id: zui.WindowId) ?*Window {
        for (&self.windows) |*window| if (window.in_use and window.id == id) return window;
        return null;
    }

    fn windowOfSurface(self: *Host, surface: ?*Proxy) ?*Window {
        const entered = surface orelse return null;
        for (&self.windows) |*window| if (window.in_use and window.surface == entered) return window;
        return null;
    }

    /// Round trips until the compositor has configured the window, and at
    /// least `least_round_trips` times.
    fn openWindowIn(self: *Host, window: *Window, id: zui.WindowId, options: zui.WindowOptions, least_round_trips: u32) !void {
        window.* = .{
            .host = self,
            .id = id,
            .in_use = true,
            .surface_size = options.size,
            .window_chrome = .{ .asked_for_custom = options.title_bar == .custom, .resizable = options.resizable },
        };
        errdefer window.in_use = false;
        window.deliver(.{ .environment = .{ .window_focused = false } });

        const compositor = self.globals.compositor.?;
        window.surface = wayland.create(compositor, wayland.compositor_create_surface, &wayland.wl_surface_interface, wayland.wl_proxy_get_version(compositor), .{wayland.no_id}) orelse return error.NoSurface;
        errdefer window.destroyObjects();
        wayland.addListener(window.surface, &surface_listener, window);
        self.useFractionalScale(window);
        if (options.visible) {
            try self.giveToplevelRole(window, options);
        } else {
            window.configured = true;
        }
        wayland.send(window.surface, wayland.surface_commit, .{});

        const most_round_trips = 3;
        var round_trips: u32 = 0;
        while (round_trips < most_round_trips and (!window.configured or round_trips < least_round_trips)) : (round_trips += 1) {
            if (wayland.wl_display_roundtrip(self.display) < 0) return error.CompositorUnreachable;
        }
        if (!window.configured) return error.WindowNotConfigured;
        // After the round trips, which bring the background effect's
        // capabilities.
        const offers: material.BlurOffers = if (self.system_material_unavailable) .{} else self.blur_offers;
        window.window_material.begin(options.material, offers, .{ .background_effect = self.globals.background_effect_manager, .kde_blur = self.globals.kde_blur_manager }, window.surface);
        window.coverWithBlur();
    }

    fn giveToplevelRole(self: *Host, window: *Window, options: zui.WindowOptions) !void {
        const wm_base = self.globals.wm_base.?;
        const xdg_surface = wayland.create(wm_base, wayland.xdg_wm_base_get_xdg_surface, &wayland.xdg_surface_interface, 1, .{ wayland.no_id, window.surface }) orelse return error.NoXdgSurface;
        window.xdg_surface = xdg_surface;
        wayland.addListener(xdg_surface, &xdg_surface_listener, window);
        const toplevel = wayland.create(xdg_surface, wayland.xdg_surface_get_toplevel, &wayland.xdg_toplevel_interface, 1, .{wayland.no_id}) orelse return error.NoToplevel;
        window.toplevel = toplevel;
        wayland.addListener(toplevel, &toplevel_listener, window);
        if (self.globals.decoration_manager) |manager| {
            if (window.window_chrome.decorate(manager, toplevel)) |decoration| wayland.addListener(decoration, &toplevel_decoration_listener, window);
        }
        var title: [256:0]u8 = @splat(0);
        const title_len = @min(options.title.len, title.len);
        @memcpy(title[0..title_len], options.title[0..title_len]);
        wayland.send(toplevel, wayland.xdg_toplevel_set_title, .{@as([*:0]const u8, &title)});
        wayland.send(toplevel, wayland.xdg_toplevel_set_app_id, .{@as([*:0]const u8, app_id)});
        if (!options.resizable) {
            const width: i32 = @intCast(options.size[0]);
            const height: i32 = @intCast(options.size[1]);
            wayland.send(toplevel, wayland.xdg_toplevel_set_min_size, .{ width, height });
            wayland.send(toplevel, wayland.xdg_toplevel_set_max_size, .{ width, height });
        }
    }

    fn useFractionalScale(self: *Host, window: *Window) void {
        const manager = self.globals.fractional_scale_manager orelse return;
        const viewporter = self.globals.viewporter orelse return;
        const viewport = wayland.create(viewporter, wayland.viewporter_get_viewport, &wayland.viewport_interface, 1, .{ wayland.no_id, window.surface }) orelse return;
        const fractional_scale = wayland.create(manager, wayland.fractional_scale_manager_get_fractional_scale, &wayland.fractional_scale_interface, 1, .{ wayland.no_id, window.surface }) orelse {
            wayland.destroy(viewport, wayland.viewport_destroy);
            return;
        };
        window.viewport = viewport;
        window.fractional_scale = fractional_scale;
        wayland.addListener(fractional_scale, &fractional_scale_listener, window);
    }

    fn openDataDevice(self: *Host) void {
        const manager = self.globals.data_device_manager orelse return;
        const seat = self.globals.seat orelse return;
        const device = wayland.create(manager, wayland.data_device_manager_get_data_device, &wayland.wl_data_device_interface, wayland.wl_proxy_get_version(manager), .{ wayland.no_id, seat }) orelse return;
        self.data_device.device = device;
        wayland.addListener(device, &data_device_listener, self);
    }

    fn openTextInput(self: *Host) void {
        const manager = self.globals.text_input_manager orelse return;
        const seat = self.globals.seat orelse return;
        const proxy = self.text_input.open(manager, seat) orelse return;
        wayland.addListener(proxy, &text_input_listener, self);
    }

    /// Call after the renderer's `deinit`, whose EGL objects live on this
    /// display.
    pub fn deinit(self: *Host) void {
        self.restoreTerminationSignals();
        self.services.close(self.io);
        self.desktop.close();
        self.file_watches.stopAll();
        self.data_device.deinit();
        if (self.globals.data_device_manager) |manager| wayland.wl_proxy_destroy(manager);
        self.text_input.deinit();
        if (self.globals.text_input_manager) |manager| wayland.destroy(manager, wayland.text_input_manager_destroy);
        for (&self.windows) |*window| if (window.in_use) window.destroyObjects();
        if (self.globals.fractional_scale_manager) |manager| wayland.destroy(manager, wayland.fractional_scale_manager_destroy);
        if (self.globals.viewporter) |viewporter| wayland.destroy(viewporter, wayland.viewporter_destroy);
        self.releaseDevices(.{});
        if (self.globals.decoration_manager) |manager| wayland.destroy(manager, wayland.decoration_manager_destroy);
        if (self.globals.background_effect_manager) |manager| wayland.destroy(manager, wayland.background_effect_manager_destroy);
        if (self.globals.kde_blur_manager) |manager| wayland.wl_proxy_destroy(manager);
        if (self.globals.cursor_shape_manager) |manager| wayland.destroy(manager, wayland.cursor_shape_manager_destroy);
        if (self.globals.seat) |seat| {
            if (wayland.wl_proxy_get_version(seat) >= 5) wayland.destroy(seat, wayland.seat_release) else wayland.wl_proxy_destroy(seat);
        }
        if (self.globals.wm_base) |wm_base| wayland.destroy(wm_base, wayland.xdg_wm_base_destroy);
        if (self.globals.compositor) |compositor| wayland.wl_proxy_destroy(compositor);
        wayland.wl_proxy_destroy(self.registry);
        _ = wayland.wl_display_flush(self.display);
        if (self.key_state) |state| xkb.xkb_state_unref(state);
        if (self.keymap) |keymap| xkb.xkb_keymap_unref(keymap);
        xkb.xkb_context_unref(self.xkb_context);
        _ = linux.close(self.wake_fd);
        wayland.wl_display_disconnect(self.display);
    }

    pub fn now(self: *const Host) zui.Instant {
        return .fromTimestamp(std.Io.Timestamp.now(self.io, .awake));
    }

    pub fn zuiPoll(self: *Host, id: zui.WindowId, record: *zui.RecordBuilder) bool {
        const window = self.windowById(id) orelse return false;
        if (window.terminate_delivered) return false;
        self.readAvailableEvents();
        if (window.closed) return false;

        const pixels_per_surface_coordinate = window.pixelsPerSurfaceCoordinate();
        const scale = self.forced_scale orelse pixels_per_surface_coordinate;
        const surface_coordinates_per_unit = scale * record.params.zoom / pixels_per_surface_coordinate;
        window.surface_coordinates_per_unit = surface_coordinates_per_unit;
        window.sizeViewport();
        window.coverWithBlur();
        record.begin(.{
            .now = self.now(),
            .viewport = .{ @as(f32, @floatFromInt(window.surface_size[0])) / surface_coordinates_per_unit, @as(f32, @floatFromInt(window.surface_size[1])) / surface_coordinates_per_unit },
            .scale = scale,
        });
        const inbox = &window.inbox;
        for (inbox.events[0..inbox.event_count]) |queued| {
            const converted = inLayoutUnits(queued, surface_coordinates_per_unit);
            switch (converted) {
                .text => |text| record.appendText(text),
                .files_dropped => |drop| record.appendFilesDropped(drop),
                .lifecycle => |change| {
                    if (change == .terminate_requested) window.terminate_delivered = true;
                    record.append(converted);
                },
                else => record.append(converted),
            }
        }
        record.dropped_events +|= inbox.dropped_events;
        record.dropped_text_bytes +|= inbox.dropped_bytes;
        inbox.clear();
        window.input_arrived = false;
        return true;
    }

    fn inLayoutUnits(queued: zui.Event, surface_coordinates_per_unit: f32) zui.Event {
        var converted = queued;
        switch (converted) {
            .pointer_down, .pointer_up => |*press| scalePosition(&press.pointer.position, surface_coordinates_per_unit),
            .pointer_move => |*move| scalePosition(&move.pointer.position, surface_coordinates_per_unit),
            .wheel => |*wheel| scalePosition(&wheel.position, surface_coordinates_per_unit),
            .files_dropped => |*drop| scalePosition(&drop.position, surface_coordinates_per_unit),
            else => {},
        }
        return converted;
    }

    fn scalePosition(position: *[2]f32, surface_coordinates_per_unit: f32) void {
        position.* = .{ position[0] / surface_coordinates_per_unit, position[1] / surface_coordinates_per_unit };
    }

    /// What the last poll of `id` converted surface coordinates to layout
    /// units by, or 1 for a window that is not open.
    pub fn surfaceCoordinatesPerUnit(self: *Host, id: zui.WindowId) f32 {
        const window = self.windowById(id) orelse return 1;
        return window.surface_coordinates_per_unit;
    }

    /// Reads whatever the compositor and the desktop have sent, without
    /// waiting, and dispatches it, with any repeats and signals that came due.
    fn readAvailableEvents(self: *Host) void {
        _ = self.waitForEvents(0);
        self.deliverDueRepeats();
        self.deliverTerminationSignal();
    }

    pub fn zuiWaker(self: *Host) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }

    fn wake(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
    }

    /// Something reached a window since its last poll, or one closed.
    fn anyWindowAwaitsPoll(self: *const Host) bool {
        for (&self.windows) |*window| if (window.in_use and (window.input_arrived or window.closed)) return true;
        return false;
    }

    /// Returns on a wake, input in any window, a key's repeat, a signal, or
    /// a change of size, scale or environment, and for `.at` also at the
    /// instant. The compositor's and the buses' other messages, such as a
    /// buffer released after each frame, are dispatched without ending it.
    pub fn zuiWait(self: *Host, next: zui.NextFrame) void {
        defer self.clearWake();
        const frame_at: ?zui.Instant = switch (next) {
            .immediately => return,
            .on_event => null,
            .at => |instant| instant,
        };
        while (!self.anyWindowAwaitsPoll()) {
            self.deliverDueRepeats();
            self.deliverTerminationSignal();
            if (self.anyWindowAwaitsPoll()) return;
            const now_instant = self.now();
            if (frame_at) |instant| if (!now_instant.isBefore(instant)) return;
            const wake_at = earlier(earlier(frame_at, self.nextRepeatAt()), self.data_device.nextDeadline());
            const timeout_ns: ?u64 = if (wake_at) |instant| instant.nanoseconds -| now_instant.nanoseconds else null;
            if (self.waitForEvents(timeout_ns) == .woken) return;
        }
    }

    fn earlier(first: ?zui.Instant, second: ?zui.Instant) ?zui.Instant {
        const one = first orelse return second;
        const other = second orelse return one;
        return if (other.isBefore(one)) other else one;
    }

    const Waited = enum { events, woken, timed_out };

    /// Waits up to `timeout_ns` (forever for null) for the display, the
    /// desktop's buses, a transfer, a watch or a wake, then reads and
    /// dispatches what they sent.
    fn waitForEvents(self: *Host, timeout_ns: ?u64) Waited {
        self.services.publishPending(self.io, self.zuiWaker());
        const display = self.display;
        while (wayland.wl_display_prepare_read(display) != 0) _ = wayland.wl_display_dispatch_pending(display);
        if (timeout_ns != 0 and self.anyWindowAwaitsPoll()) {
            wayland.wl_display_cancel_read(display);
            return .events;
        }
        _ = wayland.wl_display_flush(display);
        const bus_fds = self.desktop.descriptors();
        const first_transfer = 6;
        var descriptors = [_]linux.pollfd{
            .{ .fd = wayland.wl_display_get_fd(display), .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = bus_fds[0], .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = bus_fds[1], .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.file_watches.descriptor(), .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = self.services.descriptor(), .events = linux.POLL.IN, .revents = 0 },
        } ++ self.data_device.descriptors();
        var timeout: linux.timespec = undefined;
        if (timeout_ns) |nanoseconds| {
            timeout = .{ .sec = @intCast(nanoseconds / std.time.ns_per_s), .nsec = @intCast(nanoseconds % std.time.ns_per_s) };
        }
        const ready = linux.ppoll(&descriptors, descriptors.len, if (timeout_ns != null) &timeout else null, null);
        const polled = linux.errno(ready) == .SUCCESS;
        const display_events = descriptors[0].revents;
        if (polled and display_events & linux.POLL.IN != 0) {
            if (wayland.wl_display_read_events(display) < 0) self.closeAfterLostDisplay();
        } else {
            wayland.wl_display_cancel_read(display);
            if (polled and display_events & (linux.POLL.HUP | linux.POLL.ERR) != 0) self.closeAfterLostDisplay();
        }
        if (wayland.wl_display_dispatch_pending(display) < 0) self.closeAfterLostDisplay();
        if (polled and descriptors[2].revents | descriptors[3].revents != 0) self.desktop.receive(self);
        if (polled and descriptors[4].revents != 0) self.file_watches.receive();
        if (polled and descriptors[5].revents != 0) self.services.receive(self.io, self.zuiWaker());
        if (!polled) for (descriptors[first_transfer..]) |*descriptor| {
            descriptor.revents = 0;
        };
        if (self.data_device.transfer(descriptors[first_transfer..])) |drop| {
            if (self.drag_window) |window| {
                window.inbox.dropped_bytes +|= drop.left_out_bytes;
                window.inbox.pushFilesDropped(self.drag_position, drop.uri_list, self.now());
                window.input_arrived = true;
            }
        }
        _ = wayland.wl_display_flush(display);
        if (polled and descriptors[1].revents & linux.POLL.IN != 0) return .woken;
        return if (polled and ready > 0) .events else .timed_out;
    }

    fn closeAfterLostDisplay(self: *Host) void {
        for (&self.windows) |*window| if (window.in_use) window.onClose();
    }

    fn clearWake(self: *Host) void {
        var count: u64 = 0;
        _ = linux.read(self.wake_fd, std.mem.asBytes(&count), @sizeOf(u64));
    }

    /// Asking for a window that is not open panics.
    pub fn zuiSurface(self: *Host, id: zui.WindowId) zui.Surface {
        const window = self.windowById(id) orelse std.debug.panic("zui_host: window {d} is not open", .{@intFromEnum(id)});
        return .{ .wayland = .{ .display = self.display, .surface = window.surface, .transparent = window.window_material.holdsAlpha() } };
    }

    pub fn zuiApply(self: *Host, id: zui.WindowId, requests: zui.HostRequests) void {
        const window = self.windowById(id) orelse return;
        window.requests = requests;
        if (self.pointer_window == window) self.applyCursor();
        if (self.text_input_window == window) self.applyTextInput();
        _ = wayland.wl_display_flush(self.display);
    }

    /// Answers services through `fake` instead of the bus, from the next
    /// call on.
    pub fn fakeServices(self: *Host, fake: *services.ServiceFake) void {
        self.service_fake = fake;
        self.services.fake = fake;
    }

    /// Keeps up to `chrome.ChromeSnapshot.capacity` of `regions`, in
    /// surface coordinates, to hit-test presses against; the rest are cut
    /// from the end and counted in the window's
    /// `window_chrome.snapshot.dropped`. A window without a custom title bar
    /// keeps none.
    pub fn zuiChromeRegions(self: *Host, id: zui.WindowId, regions: []const zui.ChromeRegion) void {
        const window = self.windowById(id) orelse return;
        window.window_chrome.publish(regions, window.surface_coordinates_per_unit);
    }

    /// What a press at `position`, in `id`'s surface coordinates, would be
    /// to the window manager, from the window's last frame's chrome
    /// regions: null where it reaches zui.
    pub fn chromeKindAt(self: *Host, id: zui.WindowId, position: [2]f32) ?zui.ChromeKind {
        const window = self.windowById(id) orelse return null;
        return window.window_chrome.kindAt(position);
    }

    /// Closes the main window as its close button does: the next poll
    /// returns false.
    pub fn close(self: *Host) void {
        const window = self.windowById(.main) orelse return;
        window.onClose();
    }

    /// Asks the compositor to minimize the main window, as its minimize
    /// button does, for an application that works its drawn caption buttons
    /// from `clicked`, as the keyboard and a screen reader press them.
    pub fn minimize(self: *Host) void {
        const window = self.windowById(.main) orelse return;
        window.window_chrome.minimize(window.windowManager());
        _ = wayland.wl_display_flush(self.display);
    }

    /// Asks the compositor to maximize the main window, or to restore it
    /// when it is maximized.
    pub fn toggleMaximized(self: *Host) void {
        const window = self.windowById(.main) orelse return;
        window.window_chrome.toggleMaximized(window.windowManager());
        _ = wayland.wl_display_flush(self.display);
    }

    fn deliverToEveryWindow(self: *Host, event: zui.Event) void {
        for (&self.windows) |*window| if (window.in_use) window.deliver(event);
    }

    // =================================================================
    // What the compositor reports about the seat. A harness calls these
    // as the compositor's events would.
    // =================================================================

    /// The seat's text-input focus came to `surface`; on one of the
    /// windows', the input method is enabled again if its last frame asked
    /// for it.
    pub fn onTextInputEnter(self: *Host, surface: ?*Proxy) void {
        const window = self.windowOfSurface(surface) orelse return;
        self.text_input_window = window;
        self.text_input.onEnter();
        self.applyTextInput();
    }

    pub fn onTextInputLeave(self: *Host, surface: ?*Proxy) void {
        const window = self.windowOfSurface(surface) orelse return;
        if (self.text_input_window != window) return;
        self.text_input_window = null;
        self.text_input.onLeave();
    }

    /// Kept, not reported, from the next `done` on.
    pub fn onPreeditString(self: *Host, utf8: ?[]const u8, cursor_begin: i32, cursor_end: i32) void {
        self.text_input.onPreeditString(utf8, cursor_begin, cursor_end);
    }

    /// Typed at the next `done`.
    pub fn onCommitString(self: *Host, utf8: ?[]const u8) void {
        self.text_input.onCommitString(utf8);
    }

    /// Text committed since the last `done` is typed into the window with
    /// the text-input focus, and ends a wait; a `done` that commits none
    /// does not. The serial is not compared with the commits: text is
    /// applied whatever it is, and the host answers no `done` with requests
    /// whose state a stale one would change.
    pub fn onTextInputDone(self: *Host, serial: u32) void {
        _ = serial;
        const applied = self.text_input.onDone();
        const window = self.text_input_window orelse return;
        window.inbox.dropped_bytes +|= applied.left_out_bytes;
        if (applied.committed_text.len > 0) window.deliverText(applied.committed_text);
    }

    /// A drag entered `surface`, at `position` in its surface coordinates;
    /// one that offers a URI list is accepted.
    pub fn onDragEnter(self: *Host, serial: u32, surface: ?*Proxy, offer: ?*Proxy, position: [2]f32) void {
        self.drag_window = self.windowOfSurface(surface);
        self.data_device.onDragEnter(serial, offer);
        self.drag_position = position;
    }

    /// In surface coordinates.
    pub fn onDragMotion(self: *Host, position: [2]f32) void {
        self.drag_position = position;
    }

    /// The drag left without dropping.
    pub fn onDragLeave(self: *Host) void {
        self.data_device.onDragLeave();
    }

    /// The files arrive as `files_dropped`, at the drag's last position,
    /// once the drag's source has written their URI list.
    pub fn onDrop(self: *Host) void {
        self.data_device.onDrop();
    }

    /// Reads a URI list from `read_fd` as if it had been dropped at the
    /// drag's last position; a harness calls this as a drop's transfer
    /// would. `read_fd` is then the host's to close.
    pub fn receiveDropFrom(self: *Host, read_fd: i32) void {
        self.data_device.receiveDropFrom(read_fd);
    }

    /// The pointer entered `surface`, at `position` in its surface
    /// coordinates; until it leaves, its events reach that surface's window.
    pub fn onPointerEnter(self: *Host, surface: ?*Proxy, serial: u32, position: [2]f32) void {
        const window = self.windowOfSurface(surface);
        self.pointer_window = window;
        self.pointer_enter_serial = serial;
        if (window) |entered| {
            entered.applied_cursor = null;
            self.applyCursor();
            entered.window_chrome.onPointerEnter();
        }
        self.onPointerMotion(position);
    }

    pub fn onPointerLeave(self: *Host) void {
        self.pointer_enter_serial = null;
        const window = self.pointer_window orelse return;
        self.pointer_window = null;
        if (window.window_chrome.onPointerLeave()) window.deliver(.{ .pointer_cancel = .mouse });
        window.deliver(.{ .pointer_leave = .mouse });
    }

    pub fn onPointerMotion(self: *Host, position: [2]f32) void {
        self.pointer_position = position;
        const window = self.pointer_window orelse return;
        window.deliver(.{ .pointer_move = .{ .pointer = self.mouseAt(self.now()) } });
    }

    /// A press on the title bar or an edge goes to the compositor, with
    /// the serial `onInputSerial` gave last, and neither it nor its release
    /// reaches zui. A caption button's press does, and its release arrives
    /// as `pointer_cancel`: the host works the button, so zui shows the
    /// press and reports no click.
    pub fn onPointerButton(self: *Host, evdev_button: u32, pressed: bool) void {
        const window = self.pointer_window orelse return;
        const button = keys.buttonFromEvdev(evdev_button) orelse return;
        const press: zui.PointerButton = .{ .pointer = self.mouseAt(self.now()), .button = button };
        if (pressed) {
            const handled = window.window_chrome.press(button, self.pointer_position, self.latest_input_serial, press.pointer.at, window.windowManager());
            if (handled == .handed_to_window_manager) {
                _ = wayland.wl_display_flush(self.display);
                return;
            }
        } else switch (window.window_chrome.release(button, self.pointer_position)) {
            .reaches_zui => {},
            .swallowed => return,
            .cancels_press => |worked| {
                window.deliver(.{ .pointer_cancel = .mouse });
                if (worked) |kind| {
                    window.workCaptionButton(kind);
                    _ = wayland.wl_display_flush(self.display);
                }
                return;
            },
        }
        window.deliver(if (pressed) .{ .pointer_down = press } else .{ .pointer_up = press });
    }

    /// Wheels move in notches, reported before the axis they turn.
    pub fn onPointerAxisNotches(self: *Host, axis: u32, notches: i32) void {
        if (axis > wayland.pointer_axis_horizontal) return;
        self.wheel_notches[axis] = notches;
    }

    /// Positive scrolls toward the end of the content, as zui's wheel does.
    pub fn onPointerAxis(self: *Host, axis: u32, value: f32) void {
        if (axis > wayland.pointer_axis_horizontal) return;
        const distance = if (self.wheel_notches[axis]) |notches| @as(f32, @floatFromInt(notches)) * wheel_step else value;
        self.wheel_notches[axis] = null;
        const window = self.pointer_window orelse return;
        const delta: [2]f32 = if (axis == wayland.pointer_axis_vertical) .{ 0, distance } else .{ distance, 0 };
        window.deliver(.{ .wheel = .{ .position = self.pointer_position, .delta = delta, .at = self.now() } });
    }

    fn mouseAt(self: *const Host, at: zui.Instant) zui.Pointer {
        return .{ .id = .mouse, .kind = .mouse, .position = self.pointer_position, .at = at };
    }

    /// Takes the keymap as the compositor sent it, or the system's
    /// default for null, which a harness without a seat uses.
    pub fn useKeymap(self: *Host, text: ?[*:0]const u8) error{InvalidKeymap}!void {
        const keymap = if (text) |keymap_text|
            xkb.xkb_keymap_new_from_string(self.xkb_context, keymap_text, xkb.keymap_format_text_v1, 0)
        else
            xkb.xkb_keymap_new_from_names(self.xkb_context, null, 0);
        const new_keymap = keymap orelse return error.InvalidKeymap;
        const state = xkb.xkb_state_new(new_keymap) orelse {
            xkb.xkb_keymap_unref(new_keymap);
            return error.InvalidKeymap;
        };
        if (self.key_state) |old| xkb.xkb_state_unref(old);
        if (self.keymap) |old| xkb.xkb_keymap_unref(old);
        self.keymap = new_keymap;
        self.key_state = state;
    }

    /// The serial of the input event a clipboard write that follows
    /// answers.
    pub fn onInputSerial(self: *Host, serial: u32) void {
        self.latest_input_serial = serial;
    }

    /// The keyboard's focus came to `surface`; until it leaves, keys reach
    /// that surface's window.
    pub fn onKeyboardEnter(self: *Host, surface: ?*Proxy) void {
        const window = self.windowOfSurface(surface) orelse return;
        self.keyboard_window = window;
        window.deliver(.{ .environment = .{ .window_focused = true } });
    }

    pub fn onKeyboardLeave(self: *Host) void {
        self.modifiers = .{};
        self.key_repeat.held = null;
        const window = self.keyboard_window orelse return;
        self.keyboard_window = null;
        window.deliver(.{ .environment = .{ .window_focused = false } });
    }

    pub fn onModifiers(self: *Host, depressed: u32, latched: u32, locked: u32, group: u32) void {
        const state = self.key_state orelse return;
        _ = xkb.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
        const active = struct {
            fn named(key_state: *xkb.State, name: [*:0]const u8) bool {
                return xkb.xkb_state_mod_name_is_active(key_state, name, xkb.state_mods_effective) > 0;
            }
        }.named;
        self.modifiers = .{ .shift = active(state, "Shift"), .control = active(state, "Control"), .alt = active(state, "Mod1"), .super = active(state, "Mod4") };
    }

    /// A key held past the repeat delay repeats until it is released or
    /// another key that repeats is pressed; a modifier pressed meanwhile
    /// leaves it repeating.
    pub fn onKey(self: *Host, evdev_code: u32, pressed: bool) void {
        const at = self.now();
        self.deliverKey(evdev_code, pressed, false, at);
        const repeat = &self.key_repeat;
        if (pressed and repeat.rate > 0 and self.keyboard_window != null and self.keyRepeats(evdev_code)) {
            repeat.held = .{ .evdev_code = evdev_code, .next_at = at.addNanoseconds(repeat.delay_ns) };
        } else if (!pressed) if (repeat.held) |held| if (held.evdev_code == evdev_code) {
            repeat.held = null;
        };
    }

    /// Keys per second and the delay before the first repeat, in
    /// milliseconds; a rate of 0 turns repeating off.
    pub fn onRepeatInfo(self: *Host, rate: i32, delay_ms: i32) void {
        self.key_repeat.rate = @intCast(std.math.clamp(rate, 0, fastest_repeat_rate));
        self.key_repeat.delay_ns = @as(u64, @intCast(@max(delay_ms, 0))) * std.time.ns_per_ms;
        if (self.key_repeat.rate == 0) self.key_repeat.held = null;
    }

    /// When the held key repeats next, or null when none is held.
    pub fn nextRepeatAt(self: *const Host) ?zui.Instant {
        const held = self.key_repeat.held orelse return null;
        return held.next_at;
    }

    fn deliverKey(self: *Host, evdev_code: u32, pressed: bool, repeat: bool, at: zui.Instant) void {
        const window = self.keyboard_window orelse return;
        const key_event: zui.KeyEvent = .{ .key = self.keyOf(evdev_code), .modifiers = self.modifiers, .repeat = repeat, .scancode = evdev_code, .at = at };
        window.deliver(if (pressed) .{ .key_down = key_event } else .{ .key_up = key_event });
        if (pressed) self.typeKey(window, evdev_code);
    }

    fn keyRepeats(self: *const Host, evdev_code: u32) bool {
        const keymap = self.keymap orelse return false;
        return xkb.xkb_keymap_key_repeats(keymap, evdev_code + xkb.evdev_offset) != 0;
    }

    /// Each repeat is delivered at the instant it was due.
    fn deliverDueRepeats(self: *Host) void {
        const held = if (self.key_repeat.held) |*held| held else return;
        const interval_ns = std.time.ns_per_s / self.key_repeat.rate;
        const now_instant = self.now();
        var delivered: u32 = 0;
        while (!now_instant.isBefore(held.next_at)) : (held.next_at = held.next_at.addNanoseconds(interval_ns)) {
            if (delivered == most_repeats_at_once) {
                held.next_at = now_instant.addNanoseconds(interval_ns);
                break;
            }
            self.deliverKey(held.evdev_code, true, true, held.next_at);
            delivered += 1;
        }
    }

    /// The logical key at an evdev code in the current keymap.
    pub fn keyOf(self: *const Host, evdev_code: u32) zui.Key {
        const keymap = self.keymap orelse return keys.keyFromEvdev(evdev_code);
        const key_state = self.key_state.?;
        const keycode = evdev_code + xkb.evdev_offset;
        var symbols: ?[*]const xkb.Keysym = null;
        const layout = xkb.xkb_state_key_get_layout(key_state, keycode);
        const count = xkb.xkb_keymap_key_get_syms_by_level(keymap, keycode, layout, 0, &symbols);
        if (count > 0) {
            const key = keys.keyFromKeysym(symbols.?[0]);
            if (key != .unidentified) return key;
        }
        return keys.keyFromEvdev(evdev_code);
    }

    /// Shortcuts type nothing: Ctrl, Alt and Super keep their letters to
    /// themselves, and control characters are keys.
    fn typeKey(self: *Host, window: *Window, evdev_code: u32) void {
        const state = self.key_state orelse return;
        if (self.modifiers.control or self.modifiers.alt or self.modifiers.super) return;
        var utf8: [64]u8 = undefined;
        const len = xkb.xkb_state_key_get_utf8(state, evdev_code + xkb.evdev_offset, &utf8, utf8.len);
        if (len <= 0 or len >= utf8.len) return;
        const typed = utf8[0..@intCast(len)];
        if (typed.len == 1 and (typed[0] < 0x20 or typed[0] == 0x7F)) return;
        window.deliverText(typed);
    }

    /// What the desktop reports, to every window; a harness calls this as
    /// the buses' replies and signals would.
    pub fn onDesktopReport(self: *Host, report: desktop_bus.Report) void {
        const settings = &self.desktop_settings;
        switch (report) {
            .theme => |theme| settings.theme = theme,
            .contrast => |contrast| settings.contrast = contrast,
            .reduced_motion => |reduced_motion| settings.reduced_motion = reduced_motion,
            .reduced_transparency => |reduced_transparency| settings.reduced_transparency = reduced_transparency,
            .on_battery => |on_battery| settings.on_battery = on_battery,
            .power_saver => |power_saver| settings.power_saver = power_saver,
            .preparing_for_sleep => |sleeping| return self.deliverToEveryWindow(.{ .lifecycle = if (sleeping) .@"suspend" else .@"resume" }),
        }
        for (&self.windows) |*window| if (window.in_use) window.reportEnvironmentOnceReported();
    }

    /// Which of the desktop's services answered. The settings of one that
    /// did not, or of a bus that could not be reached, as in a container
    /// or under a compositor without a session bus, stay at zui's defaults.
    pub fn environmentSources(self: *const Host) desktop_bus.Sources {
        return self.desktop.sources;
    }

    fn readDesktopEnvironment(self: *Host) void {
        var session_address: [256]u8 = undefined;
        const addresses = self.bus_addresses orelse desktop_bus.DesktopBus.addressesFromEnvironment(&session_address);
        const deadline = self.now().addNanoseconds(desktop_answer_ns);
        self.desktop.open(self.io, addresses, deadline);
        if (addresses.session) |session| self.services.open(self.io, session, deadline);
        while (self.desktop.awaitingReplies()) {
            const remaining_ns = deadline.nanoseconds -| self.now().nanoseconds;
            if (remaining_ns == 0) break;
            const bus_fds = self.desktop.descriptors();
            var descriptors = [_]linux.pollfd{
                .{ .fd = bus_fds[0], .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = bus_fds[1], .events = linux.POLL.IN, .revents = 0 },
            };
            var timeout: linux.timespec = .{ .sec = @intCast(remaining_ns / std.time.ns_per_s), .nsec = @intCast(remaining_ns % std.time.ns_per_s) };
            _ = linux.ppoll(&descriptors, descriptors.len, &timeout, null);
            self.desktop.receive(self);
        }
        for (&self.windows) |*window| if (window.in_use) window.reportEnvironment(self.desktop_settings);
    }

    /// Leaves alone a signal the application handles or ignores. Each
    /// handler is reset as it runs, so a second Ctrl+C ends a process that
    /// did not end at the first.
    fn handleTerminationSignals(self: *Host) void {
        if (signalled_host.cmpxchgStrong(null, self, .acq_rel, .monotonic) != null) return;
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = onTerminationSignal },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESETHAND,
        };
        for (termination_signals, &self.handled_signals, &self.replaced_signal_actions) |signal, *handled, *replaced| {
            std.posix.sigaction(signal, null, replaced);
            handled.* = replaced.handler.handler == std.posix.SIG.DFL;
            if (handled.*) std.posix.sigaction(signal, &action, null);
        }
    }

    fn restoreTerminationSignals(self: *Host) void {
        if (signalled_host.load(.acquire) != self) return;
        for (termination_signals, self.handled_signals, &self.replaced_signal_actions) |signal, handled, *replaced| {
            if (handled) std.posix.sigaction(signal, replaced, null);
        }
        signalled_host.store(null, .release);
    }

    /// Whether this host turns `signal` into a terminate request.
    pub fn handlesSignal(self: *const Host, signal: std.posix.SIG) bool {
        if (signalled_host.load(.acquire) != self) return false;
        for (termination_signals, self.handled_signals) |handled_signal, handled| if (handled_signal == signal) return handled;
        return false;
    }

    fn deliverTerminationSignal(self: *Host) void {
        if (self.termination_signalled.swap(false, .acq_rel)) self.deliverToEveryWindow(.{ .lifecycle = .terminate_requested });
    }

    fn applyTextInput(self: *Host) void {
        const window = self.text_input_window orelse return;
        const area = window.requests.text_input orelse return self.text_input.apply(null);
        self.text_input.apply(.covering(area.caret, window.surface_coordinates_per_unit));
    }

    fn applyCursor(self: *Host) void {
        const window = self.pointer_window orelse return;
        const serial = self.pointer_enter_serial orelse return;
        const device = self.cursor_shape_device orelse return;
        const cursor = window.requests.cursor;
        if (window.applied_cursor == cursor) return;
        window.applied_cursor = cursor;
        wayland.send(device, wayland.cursor_shape_device_set_shape, .{ serial, cursorShape(cursor) });
    }

    /// wp_cursor_shape_device_v1's shapes, named as CSS names cursors.
    fn cursorShape(cursor: zui.Cursor) u32 {
        return switch (cursor) {
            .default => 1,
            .help => 3,
            .pointer => 4,
            .progress => 5,
            .wait => 6,
            .crosshair => 8,
            .text => 9,
            .move => 13,
            .not_allowed => 15,
            .grab => 16,
            .grabbing => 17,
            .resize_horizontal => 26,
            .resize_vertical => 27,
            .resize_nesw => 28,
            .resize_nwse => 29,
        };
    }

    const Devices = struct { keep_pointer: bool = false, keep_keyboard: bool = false };

    fn releaseDevices(self: *Host, devices: Devices) void {
        if (!devices.keep_pointer) if (self.pointer) |pointer| {
            if (self.cursor_shape_device) |device| wayland.destroy(device, wayland.cursor_shape_device_destroy);
            self.cursor_shape_device = null;
            if (wayland.wl_proxy_get_version(pointer) >= 3) wayland.destroy(pointer, wayland.pointer_release) else wayland.wl_proxy_destroy(pointer);
            self.pointer = null;
            self.pointer_enter_serial = null;
        };
        if (!devices.keep_keyboard) if (self.keyboard) |keyboard| {
            if (wayland.wl_proxy_get_version(keyboard) >= 3) wayland.destroy(keyboard, wayland.keyboard_release) else wayland.wl_proxy_destroy(keyboard);
            self.keyboard = null;
        };
    }

    fn onSeatCapabilities(self: *Host, seat: *Proxy, capabilities: u32) void {
        const has_pointer = capabilities & wayland.seat_capability_pointer != 0;
        const has_keyboard = capabilities & wayland.seat_capability_keyboard != 0;
        self.releaseDevices(.{ .keep_pointer = has_pointer, .keep_keyboard = has_keyboard });
        const version = wayland.wl_proxy_get_version(seat);
        if (has_pointer and self.pointer == null) {
            if (wayland.create(seat, wayland.seat_get_pointer, &wayland.wl_pointer_interface, version, .{wayland.no_id})) |pointer| {
                self.pointer = pointer;
                wayland.addListener(pointer, &pointer_listener, self);
                if (self.globals.cursor_shape_manager) |manager| {
                    self.cursor_shape_device = wayland.create(manager, wayland.cursor_shape_manager_get_pointer, &wayland.cursor_shape_device_interface, 1, .{ wayland.no_id, pointer });
                }
            }
        }
        if (has_keyboard and self.keyboard == null) {
            if (wayland.create(seat, wayland.seat_get_keyboard, &wayland.wl_keyboard_interface, version, .{wayland.no_id})) |keyboard| {
                self.keyboard = keyboard;
                wayland.addListener(keyboard, &keyboard_listener, self);
            }
        }
    }

    fn onKeymap(self: *Host, format: u32, fd: i32, size: u32) void {
        defer _ = linux.close(fd);
        if (format != wayland.keymap_format_xkb_v1 or size == 0) return;
        const mapped = std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
        defer std.posix.munmap(mapped);
        // The compositor's keymap ends with a 0 byte inside `size`.
        if (mapped[size - 1] != 0) return;
        self.useKeymap(@ptrCast(mapped.ptr)) catch {};
    }

    /// Whether `ext_background_effect_manager_v1` blurs, as its
    /// `capabilities` event says; a change reaches every window.
    pub fn onBackgroundEffectCapabilities(self: *Host, capabilities: u32) void {
        self.blur_offers.background_effect_blurs = capabilities & wayland.background_effect_capability_blur != 0;
        for (&self.windows) |*window| if (window.in_use) window.reportEnvironmentOnceReported();
    }

    fn onGlobal(self: *Host, registry: *Proxy, name: u32, interface_name: []const u8, version: u32) void {
        const Wanted = struct { interface: *const wayland.Interface, slot: *?*Proxy, highest_version: u32 };
        const wanted = [_]Wanted{
            .{ .interface = &wayland.wl_compositor_interface, .slot = &self.globals.compositor, .highest_version = 6 },
            .{ .interface = &wayland.xdg_wm_base_interface, .slot = &self.globals.wm_base, .highest_version = 1 },
            .{ .interface = &wayland.wl_seat_interface, .slot = &self.globals.seat, .highest_version = 5 },
            .{ .interface = &wayland.cursor_shape_manager_interface, .slot = &self.globals.cursor_shape_manager, .highest_version = 1 },
            .{ .interface = &wayland.wl_data_device_manager_interface, .slot = &self.globals.data_device_manager, .highest_version = 3 },
            .{ .interface = &wayland.viewporter_interface, .slot = &self.globals.viewporter, .highest_version = 1 },
            .{ .interface = &wayland.fractional_scale_manager_interface, .slot = &self.globals.fractional_scale_manager, .highest_version = 1 },
            .{ .interface = &wayland.text_input_manager_interface, .slot = &self.globals.text_input_manager, .highest_version = 1 },
            .{ .interface = &wayland.decoration_manager_interface, .slot = &self.globals.decoration_manager, .highest_version = 1 },
        };
        for (wanted) |global| {
            if (global.slot.* != null or !std.mem.eql(u8, interface_name, std.mem.span(global.interface.name))) continue;
            global.slot.* = wayland.bind(registry, name, global.interface, @min(version, global.highest_version));
        }
        if (self.forced_blur_offers == null) self.bindBlurManager(registry, name, interface_name);
    }

    fn bindBlurManager(self: *Host, registry: *Proxy, name: u32, interface_name: []const u8) void {
        const globals = &self.globals;
        if (globals.background_effect_manager == null and std.mem.eql(u8, interface_name, std.mem.span(wayland.background_effect_manager_interface.name))) {
            const manager = wayland.bind(registry, name, &wayland.background_effect_manager_interface, 1) orelse return;
            globals.background_effect_manager = manager;
            wayland.addListener(manager, &background_effect_manager_listener, self);
        } else if (globals.kde_blur_manager == null and std.mem.eql(u8, interface_name, std.mem.span(wayland.kde_blur_manager_interface.name))) {
            globals.kde_blur_manager = wayland.bind(registry, name, &wayland.kde_blur_manager_interface, 1);
            self.blur_offers.kde_blur = globals.kde_blur_manager != null;
        }
    }

    fn hostFrom(data: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(data.?));
    }

    fn windowFrom(data: ?*anyopaque) *Window {
        return @ptrCast(@alignCast(data.?));
    }

    const registry_listener: wayland.RegistryListener = .{
        .global = struct {
            fn global(data: ?*anyopaque, registry: ?*Proxy, name: u32, interface_name: [*:0]const u8, version: u32) callconv(.c) void {
                hostFrom(data).onGlobal(registry.?, name, std.mem.span(interface_name), version);
            }
        }.global,
        .global_remove = struct {
            fn globalRemove(_: ?*anyopaque, _: ?*Proxy, _: u32) callconv(.c) void {}
        }.globalRemove,
    };

    const wm_base_listener: wayland.XdgWmBaseListener = .{
        .ping = struct {
            fn ping(_: ?*anyopaque, wm_base: ?*Proxy, serial: u32) callconv(.c) void {
                wayland.send(wm_base.?, wayland.xdg_wm_base_pong, .{serial});
            }
        }.ping,
    };

    const xdg_surface_listener: wayland.XdgSurfaceListener = .{
        .configure = struct {
            fn configure(data: ?*anyopaque, _: ?*Proxy, serial: u32) callconv(.c) void {
                windowFrom(data).onConfigure(serial);
            }
        }.configure,
    };

    const toplevel_listener: wayland.XdgToplevelListener = .{
        .configure = struct {
            fn configure(data: ?*anyopaque, _: ?*Proxy, width: i32, height: i32, states: ?*wayland.Array) callconv(.c) void {
                windowFrom(data).onToplevelConfigure(width, height, wayland.Array.slice(states, u32));
            }
        }.configure,
        .close = struct {
            fn close(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
                windowFrom(data).onClose();
            }
        }.close,
    };

    const background_effect_manager_listener: wayland.BackgroundEffectManagerListener = .{
        .capabilities = struct {
            fn capabilities(data: ?*anyopaque, _: ?*Proxy, flags: u32) callconv(.c) void {
                hostFrom(data).onBackgroundEffectCapabilities(flags);
            }
        }.capabilities,
    };

    const toplevel_decoration_listener: wayland.ToplevelDecorationListener = .{
        .configure = struct {
            fn configure(data: ?*anyopaque, _: ?*Proxy, mode: u32) callconv(.c) void {
                windowFrom(data).onDecorationConfigure(@enumFromInt(mode));
            }
        }.configure,
    };

    const surface_listener: wayland.SurfaceListener = .{
        .enter = ignoreOutput,
        .leave = ignoreOutput,
        .preferred_buffer_scale = struct {
            fn preferredBufferScale(data: ?*anyopaque, _: ?*Proxy, factor: i32) callconv(.c) void {
                windowFrom(data).onPreferredBufferScale(factor);
            }
        }.preferredBufferScale,
        .preferred_buffer_transform = struct {
            fn preferredBufferTransform(_: ?*anyopaque, _: ?*Proxy, _: u32) callconv(.c) void {}
        }.preferredBufferTransform,
    };

    fn ignoreOutput(_: ?*anyopaque, _: ?*Proxy, _: ?*Proxy) callconv(.c) void {}

    const fractional_scale_listener: wayland.FractionalScaleListener = .{
        .preferred_scale = struct {
            fn preferredScale(data: ?*anyopaque, _: ?*Proxy, scale_120ths: u32) callconv(.c) void {
                windowFrom(data).onPreferredFractionalScale(scale_120ths);
            }
        }.preferredScale,
    };

    const data_device_listener: wayland.DataDeviceListener = .{
        .data_offer = struct {
            fn dataOffer(data: ?*anyopaque, _: ?*Proxy, offer: ?*Proxy) callconv(.c) void {
                hostFrom(data).data_device.onDataOffer(offer.?);
            }
        }.dataOffer,
        .enter = struct {
            fn enter(data: ?*anyopaque, _: ?*Proxy, serial: u32, surface: ?*Proxy, x: wayland.Fixed, y: wayland.Fixed, offer: ?*Proxy) callconv(.c) void {
                hostFrom(data).onDragEnter(serial, surface, offer, .{ wayland.fixedToFloat(x), wayland.fixedToFloat(y) });
            }
        }.enter,
        .leave = struct {
            fn leave(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
                hostFrom(data).onDragLeave();
            }
        }.leave,
        .motion = struct {
            fn motion(data: ?*anyopaque, _: ?*Proxy, _: u32, x: wayland.Fixed, y: wayland.Fixed) callconv(.c) void {
                hostFrom(data).onDragMotion(.{ wayland.fixedToFloat(x), wayland.fixedToFloat(y) });
            }
        }.motion,
        .drop = struct {
            fn drop(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
                hostFrom(data).onDrop();
            }
        }.drop,
        .selection = struct {
            fn selection(data: ?*anyopaque, _: ?*Proxy, offer: ?*Proxy) callconv(.c) void {
                hostFrom(data).data_device.onSelection(offer);
            }
        }.selection,
    };

    const text_input_listener: wayland.TextInputListener = .{
        .enter = struct {
            fn enter(data: ?*anyopaque, _: ?*Proxy, surface: ?*Proxy) callconv(.c) void {
                hostFrom(data).onTextInputEnter(surface);
            }
        }.enter,
        .leave = struct {
            fn leave(data: ?*anyopaque, _: ?*Proxy, surface: ?*Proxy) callconv(.c) void {
                hostFrom(data).onTextInputLeave(surface);
            }
        }.leave,
        .preedit_string = struct {
            fn preeditString(data: ?*anyopaque, _: ?*Proxy, utf8: ?[*:0]const u8, cursor_begin: i32, cursor_end: i32) callconv(.c) void {
                hostFrom(data).onPreeditString(if (utf8) |text| std.mem.span(text) else null, cursor_begin, cursor_end);
            }
        }.preeditString,
        .commit_string = struct {
            fn commitString(data: ?*anyopaque, _: ?*Proxy, utf8: ?[*:0]const u8) callconv(.c) void {
                hostFrom(data).onCommitString(if (utf8) |text| std.mem.span(text) else null);
            }
        }.commitString,
        .delete_surrounding_text = struct {
            fn ignoredSinceNoSurroundingTextIsSent(_: ?*anyopaque, _: ?*Proxy, _: u32, _: u32) callconv(.c) void {}
        }.ignoredSinceNoSurroundingTextIsSent,
        .done = struct {
            fn done(data: ?*anyopaque, _: ?*Proxy, serial: u32) callconv(.c) void {
                hostFrom(data).onTextInputDone(serial);
            }
        }.done,
    };

    const seat_listener: wayland.SeatListener = .{
        .capabilities = struct {
            fn capabilities(data: ?*anyopaque, seat: ?*Proxy, flags: u32) callconv(.c) void {
                hostFrom(data).onSeatCapabilities(seat.?, flags);
            }
        }.capabilities,
        .name = struct {
            fn name(_: ?*anyopaque, _: ?*Proxy, _: [*:0]const u8) callconv(.c) void {}
        }.name,
    };

    const pointer_listener: wayland.PointerListener = .{
        .enter = struct {
            fn enter(data: ?*anyopaque, _: ?*Proxy, serial: u32, surface: ?*Proxy, x: wayland.Fixed, y: wayland.Fixed) callconv(.c) void {
                hostFrom(data).onPointerEnter(surface, serial, .{ wayland.fixedToFloat(x), wayland.fixedToFloat(y) });
            }
        }.enter,
        .leave = struct {
            fn leave(data: ?*anyopaque, _: ?*Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
                hostFrom(data).onPointerLeave();
            }
        }.leave,
        .motion = struct {
            fn motion(data: ?*anyopaque, _: ?*Proxy, _: u32, x: wayland.Fixed, y: wayland.Fixed) callconv(.c) void {
                hostFrom(data).onPointerMotion(.{ wayland.fixedToFloat(x), wayland.fixedToFloat(y) });
            }
        }.motion,
        .button = struct {
            fn button(data: ?*anyopaque, _: ?*Proxy, serial: u32, _: u32, evdev_button: u32, state: u32) callconv(.c) void {
                hostFrom(data).onInputSerial(serial);
                hostFrom(data).onPointerButton(evdev_button, state == wayland.pointer_button_pressed);
            }
        }.button,
        .axis = struct {
            fn axis(data: ?*anyopaque, _: ?*Proxy, _: u32, which: u32, value: wayland.Fixed) callconv(.c) void {
                hostFrom(data).onPointerAxis(which, wayland.fixedToFloat(value));
            }
        }.axis,
        .frame = struct {
            fn frame(_: ?*anyopaque, _: ?*Proxy) callconv(.c) void {}
        }.frame,
        .axis_source = struct {
            fn axisSource(_: ?*anyopaque, _: ?*Proxy, _: u32) callconv(.c) void {}
        }.axisSource,
        .axis_stop = struct {
            fn axisStop(_: ?*anyopaque, _: ?*Proxy, _: u32, _: u32) callconv(.c) void {}
        }.axisStop,
        .axis_discrete = struct {
            fn axisDiscrete(data: ?*anyopaque, _: ?*Proxy, which: u32, notches: i32) callconv(.c) void {
                hostFrom(data).onPointerAxisNotches(which, notches);
            }
        }.axisDiscrete,
    };

    const keyboard_listener: wayland.KeyboardListener = .{
        .keymap = struct {
            fn keymap(data: ?*anyopaque, _: ?*Proxy, format: u32, fd: i32, size: u32) callconv(.c) void {
                hostFrom(data).onKeymap(format, fd, size);
            }
        }.keymap,
        .enter = struct {
            fn enter(data: ?*anyopaque, _: ?*Proxy, serial: u32, surface: ?*Proxy, _: ?*wayland.Array) callconv(.c) void {
                hostFrom(data).onInputSerial(serial);
                hostFrom(data).onKeyboardEnter(surface);
            }
        }.enter,
        .leave = struct {
            fn leave(data: ?*anyopaque, _: ?*Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
                hostFrom(data).onKeyboardLeave();
            }
        }.leave,
        .key = struct {
            fn key(data: ?*anyopaque, _: ?*Proxy, serial: u32, _: u32, evdev_code: u32, state: u32) callconv(.c) void {
                hostFrom(data).onInputSerial(serial);
                hostFrom(data).onKey(evdev_code, state == wayland.keyboard_key_pressed);
            }
        }.key,
        .modifiers = struct {
            fn modifiers(data: ?*anyopaque, _: ?*Proxy, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
                hostFrom(data).onModifiers(depressed, latched, locked, group);
            }
        }.modifiers,
        .repeat_info = struct {
            fn repeatInfo(data: ?*anyopaque, _: ?*Proxy, rate: i32, delay_ms: i32) callconv(.c) void {
                hostFrom(data).onRepeatInfo(rate, delay_ms);
            }
        }.repeatInfo,
    };
};

/// A signal handler has no context, so it reaches the host that installed
/// it through here.
var signalled_host: std.atomic.Value(?*Host) = .init(null);

/// Only sets a flag and wakes, which a signal handler may do.
fn onTerminationSignal(_: std.posix.SIG) callconv(.c) void {
    const host = signalled_host.load(.acquire) orelse return;
    host.termination_signalled.store(true, .release);
    Host.wake(host);
}

test {
    _ = keys;
    _ = dbus;
    _ = desktop_bus;
    _ = data_device;
    _ = text_input;
    _ = file_watch;
    _ = services;
    _ = chrome;
    _ = material;
}

const std = @import("std");
const zui = @import("zui");
const linux = std.os.linux;
const x11 = @import("x11.zig");
const xkb = @import("xkb.zig");
const keys = @import("keys.zig");
const key_translation = @import("keyboard.zig");
const desktop_bus = @import("desktop_bus.zig");
const services = @import("services.zig");
const session_module = @import("session.zig");
const Session = session_module.Session;
const DesktopSettings = session_module.DesktopSettings;
const ReportedEnvironment = session_module.ReportedEnvironment;
const Inbox = @import("inbox.zig").Inbox;
const x11_selections = @import("x11_selections.zig");
const x11_chrome = @import("x11_chrome.zig");
const x11_material = @import("x11_material.zig");
const ibus = @import("ibus.zig");
const TextInput = @import("text_input.zig").TextInput;

/// zui's host contract on X11 windows, through Xlib's display and the xcb
/// connection beneath it, on the thread that polls it: events are read and
/// dispatched in `zuiPoll` and `zuiWait`.
///
/// It reports the scale `Xft.dpi` gives in the resource manager's string
/// (96 dots an inch is 1, and without it the scale is 1), each window's
/// size from `ConfigureNotify`, the pointer, the wheel by notch, keys
/// through the server's XKB keymap with their modifiers, evdev codes and
/// repeats, typed text, focus, files dropped through XDND and the close
/// button; the desktop's environment over D-Bus; SIGINT, SIGTERM and
/// SIGHUP as terminate requests and the system sleeping and waking as
/// lifecycle events, to every window. It sets each window's cursor from
/// the cursor theme, reads and writes the `CLIPBOARD` selection as text,
/// watches directories, offers notifications, file dialogs and opening
/// URLs over the session bus, and waits for `nextFrame` on the
/// connection, the desktop's buses, its watches, a wake and a deadline.
///
/// It opens up to `max_windows` windows, `.main` from `init` and the rest
/// from `zuiOpenWindow`; any of them, `.main` included, closes with
/// `zuiCloseWindow`. Each X event names its window, and reaches that
/// window's record: the pointer the window it entered or pressed in, keys
/// the window with the keyboard's focus. The clipboard is owned by an
/// unmapped window of the host's own, so it outlives every window the
/// application closes.
///
/// A window opened with `title_bar = .custom` asks the window manager for
/// no decorations through `_MOTIF_WM_HINTS`. Where the window manager
/// moves windows through `_NET_WM_MOVERESIZE` and draws no frame of its
/// own around it, presses on the frame's chrome regions go to the window
/// manager: the title bar moves the window, a double click on it toggles
/// maximize and a secondary press shows the window menu where
/// `_GTK_SHOW_WINDOW_MENU` is offered, the edges resize it, and the host
/// works the caption buttons itself; `custom_title_bar` reports it, and
/// `window_maximized` follows `_NET_WM_STATE`.
///
/// A window opened with a `material` other than `.none`, where the root
/// window announces `_KDE_NET_WM_BLUR_BEHIND_REGION` and a compositing
/// manager owns `_NET_WM_CM_S<screen>`, is made with the screen's 32-bit
/// visual, so its surface is `transparent`, and its blur region covers
/// the whole window; it reports `system_material` true unless reduced
/// transparency is on, or the blur is no longer announced. Elsewhere the
/// window stays on the root's visual, opaque, and reports it false.
///
/// Typed text goes through the session's input method over IBus's D-Bus
/// protocol, where the portal `org.freedesktop.portal.IBus` answers, as
/// ibus-daemon and fcitx5 do: while the focused window's last frame asks
/// for text input, the input context is focused with its caret in root
/// coordinates, and each key is held until the input method answers for
/// it, for at most `ibus.InputContext.answer_bound_ns`. A key it consumes
/// reaches the record as a key and types nothing; text it commits is
/// typed. Otherwise keys type through the keymap and the locale's compose
/// sequences.
///
/// A window opened with `visible = false` stays unmapped, so the server
/// never shows it. `deinit` closes every window, after the renderer's
/// `deinit`; the host must not move after `init`, since its windows and
/// the signal handler hold pointers into it.
///
/// ```zig
/// var host: X11Host = undefined;
/// host.forced_scale = null;
/// host.bus_addresses = null;
/// host.service_fake = null;
/// host.forced_window_manager_support = null;
/// host.input_method_bus = null;
/// host.system_material_unavailable = false;
/// host.forced_blur_offers = null;
/// try host.init(io, .{ .title = "zui", .material = .window });
/// defer host.deinit();
/// const inspector = try host.zuiOpenWindow(.{ .title = "Inspector" });
/// defer host.zuiCloseWindow(inspector);
/// ```
pub const X11Host = struct {
    const Host = X11Host;
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.x11);
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .many, .system_material = true, .custom_title_bar = true };

    /// The windows open at once, `.main` among them.
    pub const max_windows = 4;

    /// The `CLIPBOARD` selection, as text, owned by the host's own window
    /// whichever windows are open. `write` owns it with up to
    /// `x11_selections.Clipboard.text_capacity` bytes of UTF-8, answering
    /// other clients' requests for `TARGETS`, `UTF8_STRING`,
    /// `text/plain;charset=utf-8`, `TEXT` and `STRING`. `read` answers the
    /// host's own text at once, and another owner's from the host's wait
    /// once it has written it, whole or in `INCR`'s chunks, up to that
    /// many bytes with the rest counted as left out; `""` when no client
    /// owns it or its owner gives no text, and `.failed` when the owner
    /// takes longer than `transfer_timeout_ns` for it or a chunk of it.
    pub const zuiClipboard = struct {
        pub fn write(host: *Host, text: []const u8) zui.ServiceError!void {
            try host.clipboard.write(host.clipboardEndpoint(), text, host.latest_server_time);
            _ = x11.xcb_flush(host.connection);
        }

        pub fn read(host: *Host, request: zui.ServiceRequest, sink: zui.ServiceSink) zui.ServiceError!void {
            try host.clipboard.startRead(host.clipboardEndpoint(), request, sink, host.zuiWaker(), host.latest_server_time, host.now());
            _ = x11.xcb_flush(host.connection);
        }
    };

    /// Watches up to `file_watch.Watches.capacity` directories, each with
    /// its subdirectories, until `deinit`, publishing from the host's wait.
    pub const zuiFileWatch = struct {
        pub fn watch(host: *Host, directory: []const u8, sink: zui.FileChangeSink) zui.FileWatchError!void {
            return host.session.file_watches.start(directory, sink, host.zuiWaker());
        }
    };

    /// Hands a URL to the XDG desktop portal's `OpenURI`, refusing paths
    /// and `file:` URLs.
    pub const zuiOpenUrl = struct {
        pub fn open(host: *Host, url: []const u8) zui.ServiceError!void {
            return host.session.services.openUrl(host.io, url);
        }
    };

    /// A notification through `org.freedesktop.Notifications`, answered
    /// when it is clicked, dismissed or replaced.
    pub const zuiNotifications = struct {
        pub fn show(host: *Host, request: zui.ServiceRequest, notification: zui.Notification, sink: zui.ServiceSink) zui.ServiceError!void {
            return host.session.services.showNotification(host.io, request, notification, sink);
        }
    };

    /// The XDG desktop portal's `FileChooser` dialogs, one at a time, over
    /// the window named; a window that is not open is `error.Unavailable`.
    pub const zuiFileDialogs = struct {
        pub fn show(host: *Host, window: zui.WindowId, request: zui.ServiceRequest, dialog: zui.FileDialog, sink: zui.ServiceSink) zui.ServiceError!void {
            const target = host.windowById(window) orelse return error.Unavailable;
            if (target.closed) return error.Unavailable;
            return host.session.services.showFileDialog(host.io, request, window, dialog, sink);
        }
    };

    /// Layout units scrolled per notch of the mouse wheel.
    pub const wheel_step = 40;
    /// UTF-8 bytes of text the clipboard is given, or a read answers with.
    pub const clipboard_text_capacity = x11_selections.Clipboard.text_capacity;
    /// The dots an inch of a scale of 1.
    pub const unscaled_dpi = 96;

    io: std.Io,
    /// Physical pixels per layout unit in place of `Xft.dpi`'s, for tests
    /// that must not depend on the desktop.
    forced_scale: ?f32 = null,
    /// The buses the environment is read from in place of the session's
    /// and the system's, for tests that must not depend on the desktop.
    bus_addresses: ?desktop_bus.Addresses = null,
    /// Answers services as a test says instead of handing them to the
    /// bus, so nothing shows or opens.
    service_fake: ?*services.ServiceFake = null,
    /// What the window manager offers a custom title bar in place of the
    /// root window's `_NET_SUPPORTED`, for tests that must not depend on
    /// the window manager.
    forced_window_manager_support: ?x11_chrome.WindowManagerSupport = null,
    /// The bus the input method is reached on in place of the session's,
    /// for tests that play one there and read nothing else from it.
    input_method_bus: ?[]const u8 = null,
    /// Behaves as on a desktop that blurs behind no window, so the
    /// fallback can be seen where one does.
    system_material_unavailable: bool = false,
    /// What the desktop offers to blur through, in place of what the root
    /// window and the compositing manager's selection say, for tests that
    /// must not depend on the desktop.
    forced_blur_offers: ?x11_material.BlurOffers = null,

    display: *x11.Display,
    connection: *x11.Connection,
    screen: *x11.Screen,
    atoms: x11.Atoms,
    /// The server's time of the last key or button, which owning and
    /// converting a selection name; 0, the current time, before one.
    latest_server_time: u32,
    /// An unmapped, input-only window of the host's, from `init` to
    /// `deinit`, which owns the clipboard and reads other owners' text.
    selection_window: x11.Window,
    clipboard: x11_selections.Clipboard,
    /// Physical pixels per layout unit, from `Xft.dpi`.
    resource_scale: f32,
    /// `_NET_WM_CM_S<screen>`.
    compositing_manager_selection: x11.Atom,
    blur_offers: x11_material.BlurOffers,
    cursor_context: ?*x11.CursorContext,
    /// Each cursor a window has shown, loaded from the theme once.
    loaded_cursors: [cursor_count]?u32,

    xkb_context: *xkb.Context,
    keymap: ?*xkb.Keymap,
    key_state: ?*xkb.State,
    /// The locale's compose sequences, which typed text goes through.
    compose: key_translation.Compose,
    /// Null where the server lacks XKB, whose keymap and events the host
    /// then goes without.
    xkb_keyboard: ?XkbKeyboard,
    /// The server sends a held key's repeats as presses alone, so a press
    /// of a key already down is a repeat.
    detectable_repeat: bool,
    keys_down: std.StaticBitSet(256),
    modifiers: zui.Modifiers,
    /// In the physical pixels of `pointer_window`.
    pointer_position: [2]f32,
    /// On the root window, as the last press or motion gave it.
    pointer_root_position: [2]i32,

    windows: [max_windows]Window,
    /// The id the next window opens with; ids are never given twice.
    next_window_id: u32,
    /// The window the pointer last entered, moved or pressed in.
    pointer_window: ?*Window,
    /// The window with the keyboard's focus, or the last one a key named.
    keyboard_window: ?*Window,
    /// The window the input method's answers and commits reach: the one
    /// the last key was taken for, or the input context last focused for.
    input_method_window: ?*Window,

    session: Session,
    input_context: ibus.InputContext,

    const cursor_count = std.meta.fields(zui.Cursor).len;
    const wm_class = "zui\x00zui\x00";

    const XkbKeyboard = struct { device_id: i32, first_event: u8 };

    /// One of the host's windows: its X window, what it has been told
    /// since its last poll, its size, its chrome, the drag over it, and
    /// what the last frame asked of it.
    pub const Window = struct {
        host: *Host,
        id: zui.WindowId = .main,
        /// Holds an open window, from its open to `zuiCloseWindow`.
        in_use: bool = false,
        x_window: x11.Window = 0,
        inbox: Inbox = .{},
        /// Something reached the inbox, or changed the next frame's size or
        /// scale, since the last poll.
        input_arrived: bool = false,
        closed: bool = false,
        /// The poll after the one that delivered a terminate request
        /// reports the window closed.
        terminate_delivered: bool = false,
        /// In physical pixels, as the server sizes windows.
        size: [2]u32 = .{ 0, 0 },
        focused: bool = false,
        /// What the last poll converted physical pixels to layout units by.
        surface_coordinates_per_unit: f32 = 1,
        requests: zui.HostRequests = .{},
        applied_cursor: ?zui.Cursor = null,
        window_chrome: x11_chrome.WindowChrome = .{},
        window_material: x11_material.WindowMaterial = .{},
        drop: x11_selections.Drop = .{},
        /// Its top-left corner on the root window, which the input method
        /// places its candidates by; null until asked for, and after the
        /// window is configured.
        origin_on_root: ?[2]i32 = null,
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

        /// A window that delivered a terminate request awaits the poll that
        /// reports it closed, or a wait after it would never end.
        fn awaitsPoll(self: *const Window) bool {
            return self.in_use and (self.input_arrived or self.closed or self.terminate_delivered);
        }

        /// Reports each setting that differs from what the window last
        /// reported, or every one the first time.
        fn reportEnvironment(self: *Window, settings: DesktopSettings) void {
            const current: ReportedEnvironment = .of(settings, .{
                .shows_material = self.showsBlur(),
                .custom_title_bar = self.window_chrome.isCustom(),
                .maximized = self.window_chrome.maximized,
            });
            if (ReportedEnvironment.deliverChanges(self.reported_environment, current, &self.inbox)) self.input_arrived = true;
            self.reported_environment = current;
        }

        /// The window holds alpha and the desktop still blurs behind it.
        fn showsBlur(self: *const Window) bool {
            return self.window_material.holdsAlpha() and self.host.blur_offers.blurs();
        }

        fn coverWithBlur(self: *Window) void {
            self.window_material.cover(self.host.connection, self.x_window, &self.host.atoms, self.size);
        }

        /// Until the window reports the whole environment, a change waits
        /// for it.
        fn reportEnvironmentOnceReported(self: *Window) void {
            if (self.reported_environment != null) self.reportEnvironment(self.host.session.settings);
        }

        fn dropEndpoint(self: *Window) x11_selections.Endpoint {
            return .{ .connection = self.host.connection, .window = self.x_window, .atoms = &self.host.atoms };
        }

        fn chromeEndpoint(self: *Window) x11_chrome.Endpoint {
            const host = self.host;
            return .{ .connection = host.connection, .root = host.screen.root, .window = self.x_window, .atoms = &host.atoms };
        }

        fn deliverDrop(self: *Window, dropped: x11_selections.Drop.Dropped) void {
            self.inbox.dropped_bytes +|= dropped.received.left_out_bytes;
            self.inbox.pushFilesDropped(dropped.position, dropped.received.uri_list, self.host.now());
            self.input_arrived = true;
        }

        fn workCaptionButton(self: *Window, kind: zui.ChromeKind) void {
            switch (kind) {
                .minimize_button => self.window_chrome.minimize(self.chromeEndpoint()),
                .maximize_button => self.window_chrome.toggleMaximized(self.chromeEndpoint()),
                .close_button => self.onClose(),
                else => {},
            }
            _ = x11.xcb_flush(self.host.connection);
        }

        fn applyCursor(self: *Window) void {
            const cursor = self.requests.cursor;
            if (self.applied_cursor == cursor) return;
            self.applied_cursor = cursor;
            const loaded = self.host.cursorOf(cursor);
            _ = x11.xcb_change_window_attributes(self.host.connection, self.x_window, x11.window_attribute_cursor, &loaded);
        }

        fn originOnRoot(self: *Window) [2]i32 {
            if (self.origin_on_root) |origin| return origin;
            const connection = self.host.connection;
            const cookie = x11.xcb_translate_coordinates(connection, self.x_window, self.host.screen.root, 0, 0);
            const reply = x11.xcb_translate_coordinates_reply(connection, cookie, null) orelse return .{ 0, 0 };
            defer x11.free(reply);
            const origin: [2]i32 = .{ reply.dst_x, reply.dst_y };
            self.origin_on_root = origin;
            return origin;
        }

        fn readWindowState(self: *Window) void {
            var states: [32]x11.Atom = undefined;
            self.onWindowState(x11.readCardinals(self.host.connection, self.x_window, self.host.atoms.net_wm_state, &states));
        }

        fn readFrameExtents(self: *Window) void {
            var extents: [4]u32 = undefined;
            self.onFrameExtents(x11.readCardinals(self.host.connection, self.x_window, self.host.atoms.net_frame_extents, &extents));
        }

        // =============================================================
        // What the server reports about this window. A harness calls
        // these as the server's events would.
        // =============================================================

        /// In physical pixels.
        pub fn onConfigure(self: *Window, width: u16, height: u16) void {
            const size: [2]u32 = .{ @max(width, 1), @max(height, 1) };
            if (std.meta.eql(size, self.size)) return;
            self.size = size;
            self.input_arrived = true;
        }

        /// The window's close button: its next poll returns false.
        pub fn onClose(self: *Window) void {
            self.closed = true;
            self.input_arrived = true;
        }

        /// `WM_PROTOCOLS`' `WM_DELETE_WINDOW` is the close button, and XDND's
        /// messages a drag over the window.
        pub fn onClientMessage(self: *Window, message_type: x11.Atom, data: [5]u32) void {
            const host = self.host;
            const atoms = &host.atoms;
            const endpoint = self.dropEndpoint();
            if (message_type == atoms.wm_protocols) {
                if (data[0] == atoms.wm_delete_window) self.onClose();
            } else if (message_type == atoms.xdnd_enter) {
                self.drop.onEnter(endpoint, data);
            } else if (message_type == atoms.xdnd_position) {
                self.drop.onPosition(endpoint, data, host.screen.root);
            } else if (message_type == atoms.xdnd_leave) {
                self.drop.onLeave(data);
            } else if (message_type == atoms.xdnd_drop) {
                self.drop.onDrop(endpoint, data, host.now());
            }
            _ = x11.xcb_flush(host.connection);
        }

        /// A drag's source answered the window's conversion of its list,
        /// into `property`, or `None`.
        pub fn onDropSelectionNotify(self: *Window, property: x11.Atom) void {
            if (self.drop.onSelectionNotify(self.dropEndpoint(), property, self.host.now())) |dropped| self.deliverDrop(dropped);
            _ = x11.xcb_flush(self.host.connection);
        }

        /// The window's `_NET_WM_STATE`, the atoms it holds.
        pub fn onWindowState(self: *Window, states: []const x11.Atom) void {
            if (self.window_chrome.onWindowState(states, &self.host.atoms)) self.reportEnvironmentOnceReported();
        }

        /// The window's `_NET_FRAME_EXTENTS`: left, right, top and bottom, or
        /// none once removed.
        pub fn onFrameExtents(self: *Window, extents: []const u32) void {
            if (self.window_chrome.onFrameExtents(extents)) self.reportEnvironmentOnceReported();
        }
    };

    pub fn init(self: *Host, io: std.Io, options: zui.WindowOptions) !void {
        const display = x11.XOpenDisplay(null) orelse return error.NoX11Display;
        errdefer _ = x11.XCloseDisplay(display);
        const connection = x11.XGetXCBConnection(display) orelse return error.NoX11Display;
        x11.XSetEventQueueOwner(display, x11.xcb_owns_event_queue);
        const screen = x11.screenOf(connection, x11.XDefaultScreen(display)) orelse return error.NoX11Screen;
        const forced_scale = self.forced_scale;
        const bus_addresses = self.bus_addresses;
        const service_fake = self.service_fake;
        const forced_window_manager_support = self.forced_window_manager_support;
        const input_method_bus = self.input_method_bus;
        const system_material_unavailable = self.system_material_unavailable;
        const forced_blur_offers = self.forced_blur_offers;
        self.* = .{
            .io = io,
            .forced_scale = forced_scale,
            .bus_addresses = bus_addresses,
            .service_fake = service_fake,
            .forced_window_manager_support = forced_window_manager_support,
            .input_method_bus = input_method_bus,
            .system_material_unavailable = system_material_unavailable,
            .forced_blur_offers = forced_blur_offers,
            .display = display,
            .connection = connection,
            .screen = screen,
            .atoms = .{},
            .latest_server_time = x11.current_time,
            .selection_window = 0,
            .clipboard = .{},
            .resource_scale = 1,
            .compositing_manager_selection = x11.atom_none,
            .blur_offers = forced_blur_offers orelse .{},
            .cursor_context = null,
            .loaded_cursors = @splat(null),
            .xkb_context = xkb.xkb_context_new(0) orelse return error.NoKeyboardContext,
            .keymap = null,
            .key_state = null,
            .compose = .{},
            .xkb_keyboard = null,
            .detectable_repeat = false,
            .keys_down = .initEmpty(),
            .modifiers = .{},
            .pointer_position = .{ 0, 0 },
            .pointer_root_position = .{ 0, 0 },
            .windows = @splat(.{ .host = self }),
            .next_window_id = @intFromEnum(zui.WindowId.main) + 1,
            .pointer_window = null,
            .keyboard_window = null,
            .input_method_window = null,
            .session = undefined,
            .input_context = .{},
        };
        errdefer xkb.xkb_context_unref(self.xkb_context);
        self.compose = .fromLocale(self.xkb_context);
        errdefer self.compose.deinit();
        try self.session.open(io, service_fake);
        errdefer self.session.close();

        self.atoms = .intern(connection);
        self.compositing_manager_selection = x11_material.compositingManagerSelection(connection, x11.XDefaultScreen(display));
        self.blur_offers = self.blurOffers();
        const root_mask: u32 = x11.event_mask_property_change;
        _ = x11.xcb_change_window_attributes(connection, screen.root, x11.window_attribute_event_mask, &root_mask);
        self.readResourceManager();
        self.useServerKeyboard();
        if (x11.xcb_cursor_context_new(connection, screen, &self.cursor_context) < 0) self.cursor_context = null;
        errdefer self.releaseKeyboardAndCursors();

        self.selection_window = x11.xcb_generate_id(connection);
        const selection_mask: u32 = x11.event_mask_property_change;
        _ = x11.xcb_create_window(connection, x11.copy_from_parent, self.selection_window, screen.root, -1, -1, 1, 1, 0, x11.window_class_input_only, x11.copy_from_parent, x11.window_attribute_event_mask, &selection_mask);
        errdefer _ = x11.xcb_destroy_window(connection, self.selection_window);

        const main_window = &self.windows[0];
        try self.openWindowIn(main_window, .main, options);
        errdefer _ = x11.xcb_destroy_window(connection, main_window.x_window);

        var session_address: [256]u8 = undefined;
        const addresses = self.bus_addresses orelse desktop_bus.DesktopBus.addressesFromEnvironment(&session_address);
        const deadline = self.now().addNanoseconds(Session.desktop_answer_ns);
        if (input_method_bus orelse addresses.session) |address| self.input_context.open(io, address, deadline);
        self.session.readDesktopUntil(addresses, self, deadline);
        main_window.reportEnvironment(self.session.settings);
        self.session.handleTerminationSignals();
    }

    /// Opens a window as `init` opens `.main`, mapped unless
    /// `options.visible` is false, and reports the whole environment to it.
    pub fn zuiOpenWindow(self: *Host, options: zui.WindowOptions) zui.OpenWindowError!zui.WindowId {
        const window = for (&self.windows) |*window| {
            if (!window.in_use) break window;
        } else return error.TooManyWindows;
        const id: zui.WindowId = @enumFromInt(self.next_window_id);
        self.openWindowIn(window, id, options) catch return error.WindowNotCreated;
        self.next_window_id += 1;
        window.reportEnvironment(self.session.settings);
        return id;
    }

    /// Destroys the window's X window and frees its slot, forgetting the
    /// pointer, the keyboard and the input method there; its id polls
    /// false from now on.
    pub fn zuiCloseWindow(self: *Host, id: zui.WindowId) void {
        const window = self.windowById(id) orelse return;
        window.in_use = false;
        if (self.pointer_window == window) self.pointer_window = null;
        if (self.input_method_window == window) self.input_method_window = null;
        if (self.keyboard_window == window) {
            self.keyboard_window = null;
            self.keys_down = .initEmpty();
            self.compose.reset();
            self.applyInputMethod();
        }
        _ = x11.xcb_destroy_window(self.connection, window.x_window);
        window.window_material.deinit(self.connection);
        _ = x11.xcb_flush(self.connection);
    }

    /// The open window `id` names, or null.
    pub fn windowById(self: *Host, id: zui.WindowId) ?*Window {
        for (&self.windows) |*window| if (window.in_use and window.id == id) return window;
        return null;
    }

    /// The open window whose X window is `x_window`, or null.
    pub fn windowOfX(self: *Host, x_window: x11.Window) ?*Window {
        for (&self.windows) |*window| if (window.in_use and window.x_window == x_window) return window;
        return null;
    }

    fn openWindowIn(self: *Host, window: *Window, id: zui.WindowId, options: zui.WindowOptions) !void {
        const connection = self.connection;
        const scale = self.forced_scale orelse self.resource_scale;
        const size: [2]u32 = .{ physicalLength(options.size[0], scale), physicalLength(options.size[1], scale) };
        window.* = .{
            .host = self,
            .id = id,
            .in_use = true,
            .x_window = x11.xcb_generate_id(connection),
            .size = size,
            .window_chrome = .{ .asked_for_custom = options.title_bar == .custom, .resizable = options.resizable },
        };
        errdefer window.in_use = false;
        const offers: x11_material.BlurOffers = if (self.system_material_unavailable) .{} else self.blur_offers;
        window.window_material = .choose(options.material, offers, self.screen);
        errdefer window.window_material.deinit(connection);
        _ = window.window_chrome.onSupport(self.windowManagerSupport());
        window.deliver(.{ .environment = .{ .window_focused = false } });
        const event_mask: u32 = x11.event_mask_key_press | x11.event_mask_key_release | x11.event_mask_button_press | x11.event_mask_button_release |
            x11.event_mask_enter_window | x11.event_mask_leave_window | x11.event_mask_pointer_motion | x11.event_mask_exposure |
            x11.event_mask_structure_notify | x11.event_mask_focus_change | x11.event_mask_property_change;
        const x_window = window.x_window;
        const creation = window.window_material.creation(connection, self.screen.root, event_mask);
        const created = x11.xcb_create_window_checked(connection, creation.depth, x_window, self.screen.root, 0, 0, @intCast(size[0]), @intCast(size[1]), 0, x11.window_class_input_output, creation.visual, creation.value_mask, &creation.values);
        if (x11.xcb_request_check(connection, created)) |refused| {
            x11.free(refused);
            return error.WindowNotCreated;
        }
        errdefer _ = x11.xcb_destroy_window(connection, x_window);

        const title = options.title;
        _ = x11.xcb_change_property(connection, x11.property_mode_replace, x_window, self.atoms.net_wm_name, self.atoms.utf8_string, 8, @intCast(title.len), title.ptr);
        _ = x11.xcb_change_property(connection, x11.property_mode_replace, x_window, x11.atom_wm_name, x11.atom_string, 8, @intCast(title.len), title.ptr);
        _ = x11.xcb_change_property(connection, x11.property_mode_replace, x_window, x11.atom_wm_class, x11.atom_string, 8, wm_class.len, wm_class);
        _ = x11.xcb_change_property(connection, x11.property_mode_replace, x_window, self.atoms.wm_protocols, x11.atom_atom, 32, 1, &self.atoms.wm_delete_window);
        x11_selections.Drop.advertise(window.dropEndpoint());
        window.window_chrome.askForNoDecorations(window.chromeEndpoint());
        if (!options.resizable) {
            const hints: x11.SizeHints = .{
                .flags = x11.SizeHints.program_min_size | x11.SizeHints.program_max_size,
                .min_width = @intCast(size[0]),
                .min_height = @intCast(size[1]),
                .max_width = @intCast(size[0]),
                .max_height = @intCast(size[1]),
            };
            _ = x11.xcb_change_property(connection, x11.property_mode_replace, x_window, x11.atom_wm_normal_hints, x11.atom_wm_size_hints, 32, @sizeOf(x11.SizeHints) / 4, &hints);
        }
        window.coverWithBlur();
        if (options.visible) _ = x11.xcb_map_window(connection, x_window);
        if (x11.xcb_flush(connection) <= 0 or x11.xcb_connection_has_error(connection) != 0) return error.X11ServerUnreachable;
    }

    fn clipboardEndpoint(self: *Host) x11_selections.Endpoint {
        return .{ .connection = self.connection, .window = self.selection_window, .atoms = &self.atoms };
    }

    fn blurOffers(self: *Host) x11_material.BlurOffers {
        if (self.forced_blur_offers) |forced| return forced;
        return .read(self.connection, self.screen.root, &self.atoms, self.compositing_manager_selection);
    }

    fn windowManagerSupport(self: *Host) x11_chrome.WindowManagerSupport {
        if (self.forced_window_manager_support) |forced| return forced;
        var supported: [x11_chrome.WindowManagerSupport.supported_capacity]x11.Atom = undefined;
        return .of(x11.readCardinals(self.connection, self.screen.root, self.atoms.net_supported, &supported), &self.atoms);
    }

    fn physicalLength(units: u32, scale: f32) u32 {
        return @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(units)) * scale))));
    }

    /// XKB's keymap and state for the core keyboard, its events, and
    /// repeats reported as presses alone, where the server offers them.
    fn useServerKeyboard(self: *Host) void {
        const connection = self.connection;
        var first_event: u8 = 0;
        if (x11.xkb_x11_setup_xkb_extension(connection, x11.xkb_x11_min_major_version, x11.xkb_x11_min_minor_version, 0, null, null, &first_event, null) != 1) return;
        const device_id = x11.xkb_x11_get_core_keyboard_device_id(connection);
        if (device_id < 0) return;
        self.xkb_keyboard = .{ .device_id = device_id, .first_event = first_event };
        self.reloadKeymap();
        const details: x11.XkbSelectEventsDetails = .{
            .affect_new_keyboard = x11.xkb_new_keyboard_detail_keycodes,
            .new_keyboard_details = x11.xkb_new_keyboard_detail_keycodes,
            .affect_state = x11.xkb_state_parts,
            .state_details = x11.xkb_state_parts,
        };
        const events = x11.xkb_event_type_new_keyboard_notify | x11.xkb_event_type_map_notify | x11.xkb_event_type_state_notify;
        _ = x11.xcb_xkb_select_events_aux(connection, @intCast(device_id), events, 0, 0, x11.xkb_map_parts, x11.xkb_map_parts, &details);
        const repeat_flag = x11.xkb_per_client_flag_detectable_auto_repeat;
        const cookie = x11.xcb_xkb_per_client_flags(connection, @intCast(device_id), repeat_flag, repeat_flag, 0, 0, 0);
        if (x11.xcb_xkb_per_client_flags_reply(connection, cookie, null)) |reply| {
            defer x11.free(reply);
            self.detectable_repeat = reply.value & repeat_flag != 0;
        }
    }

    fn reloadKeymap(self: *Host) void {
        const keyboard_device = self.xkb_keyboard orelse return;
        const keymap = x11.xkb_x11_keymap_new_from_device(self.xkb_context, self.connection, keyboard_device.device_id, 0) orelse return;
        const state = x11.xkb_x11_state_new_from_device(keymap, self.connection, keyboard_device.device_id) orelse {
            xkb.xkb_keymap_unref(keymap);
            return;
        };
        if (self.key_state) |old| xkb.xkb_state_unref(old);
        if (self.keymap) |old| xkb.xkb_keymap_unref(old);
        self.keymap = keymap;
        self.key_state = state;
        self.modifiers = key_translation.modifiersOf(state);
    }

    fn releaseKeyboardAndCursors(self: *Host) void {
        for (self.loaded_cursors) |loaded| if (loaded) |cursor| if (cursor != 0) {
            _ = x11.xcb_free_cursor(self.connection, cursor);
        };
        if (self.cursor_context) |context| x11.xcb_cursor_context_free(context);
        if (self.key_state) |state| xkb.xkb_state_unref(state);
        if (self.keymap) |keymap| xkb.xkb_keymap_unref(keymap);
    }

    /// Call after the renderer's `deinit`, whose EGL objects live on this
    /// display.
    pub fn deinit(self: *Host) void {
        self.input_context.close();
        self.session.close();
        self.releaseKeyboardAndCursors();
        for (&self.windows) |*window| if (window.in_use) {
            _ = x11.xcb_destroy_window(self.connection, window.x_window);
            window.window_material.deinit(self.connection);
        };
        _ = x11.xcb_destroy_window(self.connection, self.selection_window);
        _ = x11.xcb_flush(self.connection);
        self.compose.deinit();
        xkb.xkb_context_unref(self.xkb_context);
        _ = x11.XCloseDisplay(self.display);
    }

    pub fn now(self: *const Host) zui.Instant {
        return self.session.now();
    }

    pub fn zuiPoll(self: *Host, id: zui.WindowId, record: *zui.RecordBuilder) bool {
        const window = self.windowById(id) orelse return false;
        if (window.terminate_delivered) return false;
        self.readAvailableEvents();
        if (!window.in_use or window.closed) return false;
        window.coverWithBlur();

        const scale = self.forced_scale orelse self.resource_scale;
        const surface_coordinates_per_unit = scale * record.params.zoom;
        window.surface_coordinates_per_unit = surface_coordinates_per_unit;
        record.begin(.{
            .now = self.now(),
            .viewport = .{ @as(f32, @floatFromInt(window.size[0])) / surface_coordinates_per_unit, @as(f32, @floatFromInt(window.size[1])) / surface_coordinates_per_unit },
            .scale = scale,
        });
        if (window.inbox.drainInto(record, surface_coordinates_per_unit)) window.terminate_delivered = true;
        window.input_arrived = false;
        return true;
    }

    /// What the last poll of `id` converted physical pixels to layout
    /// units by, or 1 for a window that is not open.
    pub fn surfaceCoordinatesPerUnit(self: *Host, id: zui.WindowId) f32 {
        const window = self.windowById(id) orelse return 1;
        return window.surface_coordinates_per_unit;
    }

    fn readAvailableEvents(self: *Host) void {
        _ = self.waitForEvents(0);
        self.deliverTerminationSignal();
    }

    pub fn zuiWaker(self: *Host) zui.Waker {
        return self.session.waker();
    }

    /// Something reached a window since its last poll, or one closed.
    fn anyWindowAwaitsPoll(self: *const Host) bool {
        for (&self.windows) |*window| if (window.awaitsPoll()) return true;
        return false;
    }

    /// Returns on a wake, input in any window, a signal, or a change of
    /// size, scale or environment, and for `.at` also at the instant. The
    /// server's other events are dispatched without ending it.
    pub fn zuiWait(self: *Host, next: zui.NextFrame) void {
        defer self.session.clearWake();
        const frame_at: ?zui.Instant = switch (next) {
            .immediately => return,
            .on_event => null,
            .at => |instant| instant,
        };
        while (!self.anyWindowAwaitsPoll()) {
            self.deliverTerminationSignal();
            if (self.anyWindowAwaitsPoll()) return;
            const now_instant = self.now();
            if (frame_at) |instant| if (!now_instant.isBefore(instant)) return;
            const wake_at = earlier(earlier(earlier(frame_at, self.clipboard.deadline()), self.earliestDropDeadline()), self.input_context.answerDeadline());
            const timeout_ns: ?u64 = if (wake_at) |instant| instant.nanoseconds -| now_instant.nanoseconds else null;
            if (self.waitForEvents(timeout_ns) == .woken) return;
        }
    }

    fn earliestDropDeadline(self: *const Host) ?zui.Instant {
        var earliest: ?zui.Instant = null;
        for (&self.windows) |*window| if (window.in_use) {
            earliest = earlier(earliest, window.drop.deadline());
        };
        return earliest;
    }

    fn earlier(first: ?zui.Instant, second: ?zui.Instant) ?zui.Instant {
        const one = first orelse return second;
        const other = second orelse return one;
        return if (other.isBefore(one)) other else one;
    }

    const Waited = enum { events, woken, timed_out };

    /// Waits up to `timeout_ns` (forever for null) for the connection, the
    /// desktop's buses, a watch, the input method or a wake, then reads and
    /// dispatches what they sent. Events xcb read while waiting for a reply
    /// are dispatched before the wait, since the socket no longer holds
    /// them.
    fn waitForEvents(self: *Host, timeout_ns: ?u64) Waited {
        self.session.publishPending();
        self.dispatchQueuedEvents();
        if (timeout_ns != 0 and self.anyWindowAwaitsPoll()) return .events;
        _ = x11.xcb_flush(self.connection);
        const first_session = 1;
        const input_method = first_session + Session.descriptor_count;
        var descriptors = [_]linux.pollfd{
            .{ .fd = x11.xcb_get_file_descriptor(self.connection), .events = linux.POLL.IN, .revents = 0 },
        } ++ self.session.pollDescriptors() ++ [_]linux.pollfd{
            .{ .fd = self.input_context.descriptor(), .events = linux.POLL.IN, .revents = 0 },
        };
        var timeout: linux.timespec = undefined;
        if (timeout_ns) |nanoseconds| timeout = Session.timespecOf(nanoseconds);
        const ready = linux.ppoll(&descriptors, descriptors.len, if (timeout_ns != null) &timeout else null, null);
        const polled = linux.errno(ready) == .SUCCESS;
        if (polled and descriptors[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) self.closeEveryWindow();
        self.dispatchQueuedEvents();
        const now_instant = self.now();
        self.clipboard.expire(now_instant);
        for (&self.windows) |*window| if (window.in_use) window.drop.expire(window.dropEndpoint(), now_instant);
        var listener: InputMethodListener = .{ .host = self };
        if (polled and descriptors[input_method].revents != 0) self.input_context.receive(self.io, &listener);
        self.input_context.expire(now_instant, &listener);
        const woken = polled and self.session.receive(descriptors[first_session..input_method].*, self);
        _ = x11.xcb_flush(self.connection);
        if (woken) return .woken;
        return if (polled and ready > 0) .events else .timed_out;
    }

    fn dispatchQueuedEvents(self: *Host) void {
        while (x11.xcb_poll_for_event(self.connection)) |event| {
            defer x11.free(event);
            self.dispatch(event);
        }
        if (x11.xcb_connection_has_error(self.connection) != 0) self.closeEveryWindow();
    }

    fn closeEveryWindow(self: *Host) void {
        for (&self.windows) |*window| if (window.in_use) window.onClose();
    }

    /// Hands one of the server's events to the handler of the window it
    /// names, or the host's.
    pub fn dispatch(self: *Host, event: *const x11.GenericEvent) void {
        switch (event.code()) {
            x11.key_press, x11.key_release => {
                const key: *const x11.InputEvent = @ptrCast(event);
                self.latest_server_time = key.time;
                const window = self.windowOfX(key.event) orelse return;
                self.sendKeysTo(window);
                self.onKey(key.detail, event.code() == x11.key_press);
            },
            x11.button_press, x11.button_release => {
                const button: *const x11.InputEvent = @ptrCast(event);
                self.latest_server_time = button.time;
                self.pointer_root_position = .{ button.root_x, button.root_y };
                self.pointer_window = self.windowOfX(button.event) orelse return;
                self.onButton(button.detail, event.code() == x11.button_press, .{ @floatFromInt(button.event_x), @floatFromInt(button.event_y) });
            },
            x11.motion_notify => {
                const motion: *const x11.InputEvent = @ptrCast(event);
                self.pointer_root_position = .{ motion.root_x, motion.root_y };
                self.pointer_window = self.windowOfX(motion.event) orelse return;
                self.onPointerMotion(.{ @floatFromInt(motion.event_x), @floatFromInt(motion.event_y) });
            },
            x11.enter_notify => {
                const crossing: *const x11.CrossingEvent = @ptrCast(event);
                const window = self.windowOfX(crossing.event) orelse return;
                self.onPointerEnter(window, .{ @floatFromInt(crossing.event_x), @floatFromInt(crossing.event_y) });
            },
            x11.leave_notify => {
                const crossing: *const x11.CrossingEvent = @ptrCast(event);
                const window = self.windowOfX(crossing.event) orelse return;
                if (self.pointer_window == window) self.onPointerLeave();
            },
            x11.focus_in, x11.focus_out => {
                const focus: *const x11.FocusEvent = @ptrCast(event);
                const window = self.windowOfX(focus.event) orelse return;
                // A grab moves the keyboard for a moment, as the window
                // manager's own shortcuts do, without the window losing focus.
                if (focus.mode != x11.notify_mode_grab and focus.mode != x11.notify_mode_ungrab) self.onFocus(window, event.code() == x11.focus_in);
            },
            x11.expose => {
                const exposed: *const x11.ExposeEvent = @ptrCast(event);
                const window = self.windowOfX(exposed.window) orelse return;
                window.input_arrived = true;
            },
            x11.configure_notify => {
                const configure: *const x11.ConfigureNotifyEvent = @ptrCast(event);
                const window = self.windowOfX(configure.window) orelse return;
                window.origin_on_root = null;
                window.onConfigure(configure.width, configure.height);
                if (self.keyboard_window == window) self.applyInputMethod();
            },
            x11.client_message => {
                const message: *const x11.ClientMessageEvent = @ptrCast(event);
                const window = self.windowOfX(message.window) orelse return;
                if (message.format == 32) window.onClientMessage(message.type, message.data32);
            },
            x11.selection_request => {
                const request: *const x11.SelectionRequestEvent = @ptrCast(event);
                if (request.owner == self.selection_window) self.onSelectionRequest(request.*);
            },
            x11.selection_notify => {
                const notify: *const x11.SelectionNotifyEvent = @ptrCast(event);
                if (notify.requestor == self.selection_window) {
                    self.onSelectionNotify(notify.selection, notify.property);
                } else if (notify.selection == self.atoms.xdnd_selection) {
                    if (self.windowOfX(notify.requestor)) |window| window.onDropSelectionNotify(notify.property);
                }
            },
            x11.selection_clear => {
                const clear: *const x11.SelectionClearEvent = @ptrCast(event);
                if (clear.owner == self.selection_window) self.onSelectionClear(clear.selection);
            },
            x11.property_notify => self.dispatchPropertyNotify(@ptrCast(event)),
            else => |code| if (self.xkb_keyboard) |keyboard_device| if (code == keyboard_device.first_event) self.dispatchXkb(@ptrCast(event), keyboard_device),
        }
    }

    fn dispatchPropertyNotify(self: *Host, property: *const x11.PropertyNotifyEvent) void {
        const atoms = &self.atoms;
        if (property.window == self.screen.root) {
            if (property.atom == x11.atom_resource_manager) self.readResourceManager();
            if (property.atom == atoms.net_supported) self.onWindowManagerSupport(self.windowManagerSupport());
            if (property.atom == atoms.net_supported or property.atom == atoms.kde_net_wm_blur_behind_region) self.onBlurOffers(self.blurOffers());
            return;
        }
        const new_value = property.state == x11.property_new_value;
        if (property.window == self.selection_window) {
            if (new_value and property.atom == atoms.clipboard_property) self.onPropertyNewValue(property.atom);
            return;
        }
        const window = self.windowOfX(property.window) orelse return;
        if (new_value and property.atom == atoms.drop_property) {
            if (window.drop.onPropertyNewValue(window.dropEndpoint(), self.now())) |dropped| window.deliverDrop(dropped);
        }
        if (property.atom == atoms.net_wm_state) window.readWindowState();
        if (property.atom == atoms.net_frame_extents) window.readFrameExtents();
    }

    fn dispatchXkb(self: *Host, event: *const x11.XkbEventHeader, keyboard_device: XkbKeyboard) void {
        if (event.device_id != keyboard_device.device_id) return;
        switch (event.xkb_type) {
            x11.xkb_new_keyboard_notify, x11.xkb_map_notify => self.reloadKeymap(),
            x11.xkb_state_notify => {
                const state: *const x11.XkbStateNotifyEvent = @ptrCast(event);
                self.onXkbState(state.base_mods, state.latched_mods, state.locked_mods, state.base_group, state.latched_group, state.locked_group);
            },
            else => {},
        }
    }

    fn readResourceManager(self: *Host) void {
        const cookie = x11.xcb_get_property(self.connection, 0, self.screen.root, x11.atom_resource_manager, x11.atom_string, 0, 64 * 1024);
        const reply = x11.xcb_get_property_reply(self.connection, cookie, null) orelse return self.onResourceManager("");
        defer x11.free(reply);
        const length: usize = @intCast(@max(x11.xcb_get_property_value_length(reply), 0));
        const value = x11.xcb_get_property_value(reply) orelse return self.onResourceManager("");
        self.onResourceManager(value[0..length]);
    }

    /// The scale `Xft.dpi` gives in `resources`, the resource manager's
    /// lines, or null where it gives none.
    pub fn scaleFromResources(resources: []const u8) ?f32 {
        var lines = std.mem.splitScalar(u8, resources, '\n');
        while (lines.next()) |line| {
            const name = "Xft.dpi:";
            if (!std.mem.startsWith(u8, line, name)) continue;
            const dpi = std.fmt.parseFloat(f32, std.mem.trim(u8, line[name.len..], " \t\r")) catch return null;
            if (!(dpi > 0)) return null;
            return dpi / unscaled_dpi;
        }
        return null;
    }

    /// Asking for a window that is not open panics.
    pub fn zuiSurface(self: *Host, id: zui.WindowId) zui.Surface {
        const window = self.windowById(id) orelse std.debug.panic("zui_host: window {d} is not open", .{@intFromEnum(id)});
        return .{ .x11 = .{ .display = self.display, .window = window.x_window, .transparent = window.window_material.holdsAlpha() } };
    }

    pub fn zuiApply(self: *Host, id: zui.WindowId, requests: zui.HostRequests) void {
        const window = self.windowById(id) orelse return;
        window.requests = requests;
        window.applyCursor();
        if (self.keyboard_window == window) self.applyInputMethod();
        _ = x11.xcb_flush(self.connection);
    }

    /// Keys a window's events name reach it; a window other than the one
    /// with the input context's focus moves that focus to it.
    fn sendKeysTo(self: *Host, window: *Window) void {
        if (self.keyboard_window == window) return;
        self.keyboard_window = window;
        self.applyInputMethod();
    }

    /// Focuses the input context at the caret while the focused window's
    /// last frame asked for text input, and otherwise takes its focus
    /// away.
    fn applyInputMethod(self: *Host) void {
        if (!self.input_context.bus.isOpen()) return;
        const window = self.keyboard_window orelse return self.input_context.want(self.io, null);
        if (!window.focused) return self.input_context.want(self.io, null);
        const area = window.requests.text_input orelse return self.input_context.want(self.io, null);
        const origin = window.originOnRoot();
        var caret: TextInput.CursorRectangle = .covering(area.caret, window.surface_coordinates_per_unit);
        caret.x +|= origin[0];
        caret.y +|= origin[1];
        self.input_method_window = window;
        self.input_context.want(self.io, caret);
    }

    /// Hands what the input context answers to the window it answers for.
    const InputMethodListener = struct {
        host: *Host,

        pub fn onKeyAnswered(self: *InputMethodListener, key: *const ibus.HeldKey, types: bool) void {
            const host = self.host;
            const window = host.input_method_window orelse return;
            window.deliver(key.event);
            if (!types) return;
            const pressed_key = key.pressed_key orelse return;
            var utf8: [64]u8 = undefined;
            if (pressed_key.composedText(&host.compose, &utf8)) |typed| window.deliverText(typed);
        }

        pub fn onCommittedText(self: *InputMethodListener, utf8: []const u8) void {
            const window = self.host.input_method_window orelse return;
            window.deliverText(utf8);
        }

        /// The key the input method names, typing its keysym's text unless
        /// Control, Alt or Super is held.
        pub fn onForwardedKey(self: *InputMethodListener, forwarded: ibus.ForwardedKey) void {
            const host = self.host;
            const window = host.input_method_window orelse return;
            const named = keys.keyFromKeysym(forwarded.keysym);
            const key_event: zui.KeyEvent = .{
                .key = if (named != .unidentified) named else host.keyOf(forwarded.evdev_code),
                .modifiers = host.modifiers,
                .scancode = forwarded.evdev_code,
                .at = host.now(),
            };
            if (forwarded.isRelease()) return window.deliver(.{ .key_up = key_event });
            window.deliver(.{ .key_down = key_event });
            if (forwarded.state & (x11_control_mask | x11_alt_mask | x11_super_mask) != 0) return;
            var utf8: [64]u8 = undefined;
            if (key_translation.textOfKeysym(forwarded.keysym, &utf8)) |typed| window.deliverText(typed);
        }

        pub fn onLeftOut(self: *InputMethodListener, events: u32, bytes: u32) void {
            const window = self.host.input_method_window orelse return;
            window.inbox.dropped_events +|= events;
            window.inbox.dropped_bytes +|= bytes;
            window.input_arrived = true;
        }
    };

    const x11_control_mask: u32 = 1 << 2;
    const x11_alt_mask: u32 = 1 << 3;
    const x11_super_mask: u32 = 1 << 6;

    /// Answers services through `fake` instead of the bus, from the next
    /// call on.
    pub fn fakeServices(self: *Host, fake: *services.ServiceFake) void {
        self.service_fake = fake;
        self.session.services.fake = fake;
    }

    /// Closes the main window as its close button does: its next poll
    /// returns false.
    pub fn close(self: *Host) void {
        const window = self.windowById(.main) orelse return;
        window.onClose();
    }

    /// Keeps up to `chrome.ChromeSnapshot.capacity` of `regions`, in
    /// physical pixels, to hit-test presses on `id` against; the rest are
    /// cut from the end and counted in the window's
    /// `window_chrome.snapshot.dropped`. A window without a custom title
    /// bar keeps none.
    pub fn zuiChromeRegions(self: *Host, id: zui.WindowId, regions: []const zui.ChromeRegion) void {
        const window = self.windowById(id) orelse return;
        window.window_chrome.publish(regions, window.surface_coordinates_per_unit);
    }

    /// What a press at `position`, in `id`'s physical pixels, would be to
    /// the window manager, from the window's last frame's chrome regions:
    /// null where it reaches zui.
    pub fn chromeKindAt(self: *Host, id: zui.WindowId, position: [2]f32) ?zui.ChromeKind {
        const window = self.windowById(id) orelse return null;
        return window.window_chrome.kindAt(position);
    }

    /// Asks the window manager to iconify the main window, as its minimize
    /// button does, for an application that works its drawn caption buttons
    /// from `clicked`, as the keyboard and a screen reader press them.
    pub fn minimize(self: *Host) void {
        const window = self.windowById(.main) orelse return;
        window.workCaptionButton(.minimize_button);
    }

    /// Asks the window manager to maximize the main window, or to restore
    /// it when it is maximized.
    pub fn toggleMaximized(self: *Host) void {
        const window = self.windowById(.main) orelse return;
        window.workCaptionButton(.maximize_button);
    }

    /// The theme's cursor for `cursor`, by its CSS name or the X cursor
    /// font's, or 0, which shows the root window's.
    fn cursorOf(self: *Host, cursor: zui.Cursor) u32 {
        const slot = &self.loaded_cursors[@intFromEnum(cursor)];
        if (slot.*) |loaded| return loaded;
        const context = self.cursor_context orelse return 0;
        const names = cursorNames(cursor);
        var loaded = x11.xcb_cursor_load_cursor(context, names.css);
        if (loaded == 0) loaded = x11.xcb_cursor_load_cursor(context, names.x_cursor_font);
        slot.* = loaded;
        return loaded;
    }

    const CursorNames = struct { css: [*:0]const u8, x_cursor_font: [*:0]const u8 };

    fn cursorNames(cursor: zui.Cursor) CursorNames {
        return switch (cursor) {
            .default => .{ .css = "default", .x_cursor_font = "left_ptr" },
            .help => .{ .css = "help", .x_cursor_font = "question_arrow" },
            .pointer => .{ .css = "pointer", .x_cursor_font = "hand2" },
            .progress => .{ .css = "progress", .x_cursor_font = "watch" },
            .wait => .{ .css = "wait", .x_cursor_font = "watch" },
            .crosshair => .{ .css = "crosshair", .x_cursor_font = "crosshair" },
            .text => .{ .css = "text", .x_cursor_font = "xterm" },
            .move => .{ .css = "move", .x_cursor_font = "fleur" },
            .not_allowed => .{ .css = "not-allowed", .x_cursor_font = "X_cursor" },
            .grab => .{ .css = "grab", .x_cursor_font = "hand1" },
            .grabbing => .{ .css = "grabbing", .x_cursor_font = "fleur" },
            .resize_horizontal => .{ .css = "ew-resize", .x_cursor_font = "sb_h_double_arrow" },
            .resize_vertical => .{ .css = "ns-resize", .x_cursor_font = "sb_v_double_arrow" },
            .resize_nesw => .{ .css = "nesw-resize", .x_cursor_font = "bottom_left_corner" },
            .resize_nwse => .{ .css = "nwse-resize", .x_cursor_font = "bottom_right_corner" },
        };
    }

    /// The cursor window `id` shows, for tests: 0 for the root window's,
    /// and null before one is asked for or for a window not open.
    pub fn shownCursor(self: *Host, id: zui.WindowId) ?u32 {
        const window = self.windowById(id) orelse return null;
        const applied = window.applied_cursor orelse return null;
        return self.loaded_cursors[@intFromEnum(applied)];
    }

    fn deliverToEveryWindow(self: *Host, event: zui.Event) void {
        for (&self.windows) |*window| if (window.in_use) window.deliver(event);
    }

    fn deliverTerminationSignal(self: *Host) void {
        if (self.session.takeTerminationSignal()) self.deliverToEveryWindow(.{ .lifecycle = .terminate_requested });
    }

    // =================================================================
    // What the server reports about the display, the pointer and the
    // keyboard. A harness calls these as the server's events would.
    // =================================================================

    /// What the desktop reports, to every window; a harness calls this as
    /// the buses' replies and signals would.
    pub fn onDesktopReport(self: *Host, report: desktop_bus.Report) void {
        if (self.session.settle(report)) |lifecycle| return self.deliverToEveryWindow(.{ .lifecycle = lifecycle });
        for (&self.windows) |*window| if (window.in_use) window.reportEnvironmentOnceReported();
    }

    /// Which of the desktop's services answered.
    pub fn environmentSources(self: *const Host) desktop_bus.Sources {
        return self.session.desktop.sources;
    }

    /// Whether this host turns `signal` into a terminate request.
    pub fn handlesSignal(self: *const Host, signal: std.posix.SIG) bool {
        return self.session.handlesSignal(signal);
    }

    /// The resource manager's string changed; a new `Xft.dpi` moves every
    /// window's scale.
    pub fn onResourceManager(self: *Host, resources: []const u8) void {
        const scale = scaleFromResources(resources) orelse 1;
        if (scale == self.resource_scale) return;
        self.resource_scale = scale;
        for (&self.windows) |*window| if (window.in_use) {
            window.input_arrived = true;
        };
    }

    /// Another client asks for the clipboard the host owns.
    pub fn onSelectionRequest(self: *Host, request: x11.SelectionRequestEvent) void {
        self.clipboard.answerRequest(self.clipboardEndpoint(), request);
        _ = x11.xcb_flush(self.connection);
    }

    /// The clipboard's owner answered the host's conversion of it, into
    /// `property`, or `None`.
    pub fn onSelectionNotify(self: *Host, selection: x11.Atom, property: x11.Atom) void {
        if (selection != self.atoms.clipboard) return;
        self.clipboard.onSelectionNotify(self.clipboardEndpoint(), property, self.now());
        _ = x11.xcb_flush(self.connection);
    }

    /// For `INCR`, the clipboard's owner wrote the next chunk into
    /// `property`.
    pub fn onPropertyNewValue(self: *Host, property: x11.Atom) void {
        if (property == self.atoms.clipboard_property) self.clipboard.onPropertyNewValue(self.clipboardEndpoint(), self.now());
    }

    /// Another client took the selection, and the text the host held is
    /// dropped.
    pub fn onSelectionClear(self: *Host, selection: x11.Atom) void {
        if (selection == self.atoms.clipboard) self.clipboard.onSelectionClear();
    }

    /// `window` gained or lost the keyboard's focus; losing it forgets the
    /// keys held, whose releases go elsewhere, and a compose sequence in
    /// progress.
    pub fn onFocus(self: *Host, window: *Window, focused: bool) void {
        if (focused) {
            self.keyboard_window = window;
        } else {
            self.keys_down = .initEmpty();
            self.compose.reset();
        }
        if (window.focused == focused) return;
        window.focused = focused;
        window.deliver(.{ .environment = .{ .window_focused = focused } });
        self.applyInputMethod();
    }

    /// The pointer entered `window`, at `position` in its physical pixels;
    /// its events reach that window until another names a window.
    pub fn onPointerEnter(self: *Host, window: *Window, position: [2]f32) void {
        self.pointer_window = window;
        window.window_chrome.onPointerEnter();
        self.onPointerMotion(position);
    }

    pub fn onPointerLeave(self: *Host) void {
        const window = self.pointer_window orelse return;
        self.pointer_window = null;
        if (window.window_chrome.onPointerLeave()) window.deliver(.{ .pointer_cancel = .mouse });
        window.deliver(.{ .pointer_leave = .mouse });
    }

    /// The root window's `_NET_SUPPORTED` changed, as a window manager
    /// starting or leaving changes it.
    pub fn onWindowManagerSupport(self: *Host, support: x11_chrome.WindowManagerSupport) void {
        for (&self.windows) |*window| if (window.in_use and window.window_chrome.onSupport(support)) window.reportEnvironmentOnceReported();
    }

    /// What the desktop offers to blur through changed, as the blur
    /// effect loading or unloading changes the root window's properties.
    /// A window keeps the visual it opened with.
    pub fn onBlurOffers(self: *Host, offers: x11_material.BlurOffers) void {
        self.blur_offers = offers;
        for (&self.windows) |*window| if (window.in_use) window.reportEnvironmentOnceReported();
    }

    /// In the physical pixels of the pointer's window.
    pub fn onPointerMotion(self: *Host, position: [2]f32) void {
        self.pointer_position = position;
        const window = self.pointer_window orelse return;
        window.deliver(.{ .pointer_move = .{ .pointer = self.mouseAt(self.now()) } });
    }

    /// X's buttons, in the pointer's window: 1 to 3 are the primary,
    /// middle and secondary buttons, and each press of 4 to 7 a wheel's
    /// notch up, down, left or right. Others, such as back and forward,
    /// have no zui button.
    ///
    /// A press on the title bar or an edge goes to the window manager, at
    /// the root position the last press or motion gave, and neither it nor
    /// its release reaches zui. A caption button's press does, and its
    /// release arrives as `pointer_cancel`: the host works the button, so
    /// zui shows the press and reports no click.
    pub fn onButton(self: *Host, x_button: u8, pressed: bool, position: [2]f32) void {
        self.pointer_position = position;
        const window = self.pointer_window orelse return;
        if (wheelNotch(x_button)) |delta| {
            if (pressed) window.deliver(.{ .wheel = .{ .position = position, .delta = delta, .at = self.now() } });
            return;
        }
        const button: zui.Button = switch (x_button) {
            1 => .primary,
            2 => .middle,
            3 => .secondary,
            else => return,
        };
        const press: zui.PointerButton = .{ .pointer = self.mouseAt(self.now()), .button = button };
        const window_chrome = &window.window_chrome;
        if (pressed) {
            if (window_chrome.press(button, position, self.pointer_root_position, x_button, press.pointer.at, window.chromeEndpoint()) == .handed_to_window_manager) {
                _ = x11.xcb_flush(self.connection);
                return;
            }
        } else switch (window_chrome.release(button, position)) {
            .reaches_zui => {},
            .swallowed => return,
            .cancels_press => |worked| {
                window.deliver(.{ .pointer_cancel = .mouse });
                if (worked) |kind| window.workCaptionButton(kind);
                return;
            },
        }
        window.deliver(if (pressed) .{ .pointer_down = press } else .{ .pointer_up = press });
    }

    /// Positive scrolls toward the end of the content, as zui's wheel does.
    fn wheelNotch(x_button: u8) ?[2]f32 {
        return switch (x_button) {
            4 => .{ 0, -wheel_step },
            5 => .{ 0, wheel_step },
            6 => .{ -wheel_step, 0 },
            7 => .{ wheel_step, 0 },
            else => null,
        };
    }

    fn mouseAt(self: *const Host, at: zui.Instant) zui.Pointer {
        return .{ .id = .mouse, .kind = .mouse, .position = self.pointer_position, .at = at };
    }

    /// XKB's modifier state, base, latched and locked, as its state
    /// events report it.
    pub fn onXkbState(self: *Host, base_mods: u8, latched_mods: u8, locked_mods: u8, base_group: i16, latched_group: i16, locked_group: u8) void {
        const state = self.key_state orelse return;
        _ = xkb.xkb_state_update_mask(state, base_mods, latched_mods, locked_mods, @bitCast(@as(i32, base_group)), @bitCast(@as(i32, latched_group)), locked_group);
        self.modifiers = key_translation.modifiersOf(state);
    }

    /// An X key code, which is the evdev code plus 8, for the keyboard's
    /// window. A press of a key already down is a repeat. While the input
    /// context is focused, the key waits for the input method's answer
    /// before it reaches the window.
    pub fn onKey(self: *Host, x_keycode: u8, pressed: bool) void {
        if (x_keycode < xkb.evdev_offset) return;
        const evdev_code: u32 = x_keycode - xkb.evdev_offset;
        const repeat = pressed and self.keys_down.isSet(x_keycode);
        self.keys_down.setValue(x_keycode, pressed);
        self.input_method_window = self.keyboard_window orelse return;
        const key_event: zui.KeyEvent = .{ .key = self.keyOf(evdev_code), .modifiers = self.modifiers, .repeat = repeat, .scancode = evdev_code, .at = self.now() };
        const state = self.key_state;
        const release_bit: u32 = if (pressed) 0 else ibus.release_mask;
        const key: ibus.HeldKey = .{
            .event = if (pressed) .{ .key_down = key_event } else .{ .key_up = key_event },
            .pressed_key = if (pressed and state != null) key_translation.PressedKey.read(state.?, self.modifiers, evdev_code, repeat) else null,
            .keysym = if (state) |key_state| xkb.xkb_state_key_get_one_sym(key_state, x_keycode) else 0,
            .evdev_code = evdev_code,
            .state = release_bit | if (state) |key_state| xkb.xkb_state_serialize_mods(key_state, xkb.state_mods_effective) else 0,
        };
        var listener: InputMethodListener = .{ .host = self };
        self.input_context.takeKey(self.io, key, key_event.at, &listener);
    }

    /// The logical key at an evdev code in the server's keymap.
    pub fn keyOf(self: *const Host, evdev_code: u32) zui.Key {
        return key_translation.keyOf(self.keymap, self.key_state, evdev_code);
    }
};

test "Xft.dpi gives the scale, 96 dots an inch being 1, and nothing gives none" {
    try std.testing.expectEqual(@as(?f32, 1), X11Host.scaleFromResources("Xft.dpi:\t96\n"));
    try std.testing.expectEqual(@as(?f32, 1.5), X11Host.scaleFromResources("Xcursor.size:\t24\nXft.dpi:\t144\nXft.antialias:\t1\n"));
    try std.testing.expectEqual(@as(?f32, 1.25), X11Host.scaleFromResources("Xft.dpi: 120"));
    try std.testing.expectEqual(@as(?f32, null), X11Host.scaleFromResources("Xcursor.size:\t24\n"));
    try std.testing.expectEqual(@as(?f32, null), X11Host.scaleFromResources("Xft.dpi:\tlarge\n"));
    try std.testing.expectEqual(@as(?f32, null), X11Host.scaleFromResources(""));
}

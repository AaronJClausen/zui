//! ```zig
//! const App = struct {
//!     pub const Host = zui_raylib.Host;
//!     pub const Renderer = zui_raylib.Renderer;
//!     pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{}));
//!
//!     clicks: u32 = 0,
//!
//!     pub fn zuiDeclare(app: *App, ui: *Ui) void {
//!         if (widgets.button(ui, .of("more"), "More", .{})) app.clicks += 1;
//!     }
//! };
//!
//! pub fn main(init: std.process.Init) !void {
//!     try zui_app.run(App, init, .{ .title = "zui demo", .size = .{ 1280, 720 } });
//! }
//! ```

const std = @import("std");
const zui = @import("zui");

/// A `zui.Config` for `Renderer`: its optional commands, whether it draws
/// `zui.ExtendedColor`, its payload types, and the renderer itself as the
/// text contract when it declares `zuiMeasure` and `overrides` names no
/// `Text`. Every other field comes from `overrides`, `Color` among them.
///
/// ```zig
/// const Ui = zui.Context(zui_app.contextConfig(zui_raylib.Renderer, .{ .Sources = AppSources }));
/// // Fonts that are not the renderer, which the application also names as `pub const Text`:
/// const Ui = zui.Context(zui_app.contextConfig(MyRenderer, .{ .Text = MyFonts }));
/// ```
pub fn contextConfig(comptime Renderer: type, comptime overrides: zui.Config) zui.Config {
    comptime zui.checkRenderer(Renderer);
    var result = overrides;
    result.commands = if (@hasDecl(Renderer, "zui_commands")) Renderer.zui_commands else .initEmpty();
    result.extended_color = @hasDecl(Renderer, "zui_extended_color") and Renderer.zui_extended_color;
    result.ImageHandle = rendererType(Renderer, "ImageHandle", void);
    result.CustomData = rendererType(Renderer, "CustomData", void);
    result.MaterialHandle = rendererType(Renderer, "MaterialHandle", void);
    result.FontId = rendererType(Renderer, "FontId", u16);
    if (overrides.Text == void and @hasDecl(Renderer, "zuiMeasure")) result.Text = Renderer;
    return result;
}

fn rendererType(comptime Renderer: type, comptime declaration: []const u8, comptime default: type) type {
    return if (@hasDecl(Renderer, declaration)) @field(Renderer, declaration) else default;
}

pub const Options = struct {
    title: [:0]const u8 = "zui",
    /// The window's content area, in layout units at a scale of 1.
    size: [2]u32 = .{ 1280, 720 },
    visible: bool = true,
    resizable: bool = true,
    /// What shows behind the window where nothing is drawn, when the host
    /// has a system material; `Environment.system_material` says whether
    /// it does on this machine.
    material: zui.SystemMaterial = .none,
    /// Who draws the title bar. `.custom` needs
    /// `Config.features.chrome_regions`, or `start` returns
    /// `error.CustomTitleBarWithoutChromeRegions`; on a host without
    /// `custom_title_bar` the window keeps the system's, and
    /// `Environment.custom_title_bar` stays false.
    title_bar: zui.TitleBar = .native,
    /// The application's zoom, multiplied into layout.
    zoom: f32 = 1,
    /// Submit on a thread of its own when the renderer declares
    /// `zui_render_thread` and the `Config` has more than one frame in
    /// flight.
    render_thread: bool = true,
    /// Receives each notice once: what the loop runs with when it starts,
    /// then the first time each limit is exceeded. The default logs them.
    notify: *const fn (Notice) void = logNotice,
};

/// What `zui_app` tells the developer, each at most once a run.
pub const Notice = union(enum) {
    started: Report,
    /// The host's record had no room: raise `limits.max_events_per_frame`,
    /// `limits.max_text_input_bytes` or `limits.max_dropped_path_bytes`.
    input_dropped: struct { events: u32, text_bytes: u32 },
    limit_exceeded: struct { limit: zui.Limit, allowed: u32, needed: u32, first_dropped_id: u64 },
    /// A full source refused publishes; raise the capacity of `source`.
    publishes_refused: struct { source: []const u8, count: u32 },
    duplicate_ids: u32,
    unbalanced_tree,
    /// The host's accessibility bridge had no room for the end of the
    /// list; an assistive technology sees what came before.
    semantics_dropped: zui.SemanticsDropped,

    pub fn format(self: Notice, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .started => |report| try writer.print("{f}", .{report}),
            .input_dropped => |dropped| try writer.print("the host dropped {d} events and {d} bytes of typed text or dropped paths that did not fit the record; raise limits.max_events_per_frame, limits.max_text_input_bytes or limits.max_dropped_path_bytes", .{ dropped.events, dropped.text_bytes }),
            .limit_exceeded => |exceeded| try writer.print("limits.{t} is {d}, but a frame needed {d}; what fit was drawn (first dropped id 0x{x})", .{ exceeded.limit, exceeded.allowed, exceeded.needed, exceeded.first_dropped_id }),
            .publishes_refused => |refused| try writer.print("the full source `{s}` refused {d} publishes; raise its capacity", .{ refused.source, refused.count }),
            .duplicate_ids => |count| try writer.print("{d} ids were declared twice in one frame; the second of each is not interactive", .{count}),
            .unbalanced_tree => try writer.writeAll("open and close were unbalanced; the frame closed what was left open"),
            .semantics_dropped => |dropped| try writer.print("the host's accessibility bridge had no room for {d} semantic nodes and {d} bytes of their text; an assistive technology sees the rest", .{ dropped.nodes, dropped.text_bytes }),
        }
    }
};

pub fn logNotice(notice: Notice) void {
    const log = std.log.scoped(.zui_app);
    switch (notice) {
        .started => log.info("{f}", .{notice}),
        else => log.warn("{f}", .{notice}),
    }
}

/// What the loop runs with, and every fallback in effect.
pub const Report = struct {
    host: []const u8,
    renderer: []const u8,
    /// The kinds of surface both give and draw into.
    surfaces: zui.SurfaceKinds,
    /// The output formats both support, which the window was opened with;
    /// its surface says which one the host chose.
    output_formats: zui.OutputFormats,
    capabilities: zui.HostCapabilities,
    submission: Submission,
    /// Optional commands the renderer does not draw, which zui lowers.
    lowered: zui.CommandSet,
    /// Host services that are absent.
    missing_services: Services,
    accessibility: Accessibility,

    pub fn format(self: Report, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s} with {s}; {s}", .{ self.host, self.renderer, if (self.capabilities.windows == .many) "many windows" else "one window" });
        if (!self.capabilities.system_material) try writer.writeAll("; no system material, so the root draws its own background");
        switch (self.submission) {
            .render_thread => try writer.writeAll("; submitting on a render thread"),
            .ui_thread => |reason| try writer.print("; submitting on the UI thread, since {s}", .{reason.describe()}),
        }
        try writeSet(writer, "; output: ", self.output_formats);
        try writeSet(writer, "; lowered: ", self.lowered);
        try writeSet(writer, "; no host ", self.missing_services);
        if (self.accessibility == .not_bridged) try writer.writeAll("; semantics on, but the host bridges none to an accessibility API");
    }

    fn writeSet(writer: *std.Io.Writer, comptime prefix: []const u8, set: anytype) std.Io.Writer.Error!void {
        var members = set.iterator();
        var first = true;
        while (members.next()) |member| : (first = false) {
            try writer.print("{s}{t}", .{ if (first) prefix else ", ", member });
        }
    }
};

pub const Accessibility = enum {
    /// `Config.features.semantics` is off.
    off,
    /// The host bridges `Frame.semantics()` to the platform's API.
    bridged,
    /// Semantics are on, but the host declares no `zuiSemantics`, so an
    /// assistive technology sees only the window.
    not_bridged,
};

pub const Submission = union(enum) {
    render_thread,
    ui_thread: Reason,

    pub const Reason = enum {
        /// It does not declare `zui_render_thread`.
        renderer_needs_its_thread,
        one_frame_in_flight,
        turned_off_in_options,
        io_cannot_run_concurrently,

        fn describe(self: Reason) []const u8 {
            return switch (self) {
                .renderer_needs_its_thread => "the renderer does not declare zui_render_thread",
                .one_frame_in_flight => "the Config has one frame in flight",
                .turned_off_in_options => "Options.render_thread is false",
                .io_cannot_run_concurrently => "the Io cannot run a task concurrently",
            };
        }
    };
};

pub const Service = enum { clipboard, notifications, file_dialogs, open_url, menus, file_watch };
pub const Services = std.EnumSet(Service);

/// The host's services, each behind a guard known at compile time, so a
/// call inside it is not compiled for a host without the service, and a
/// call outside it is a compile error naming the guard. Services are work:
/// call them between frames, as from `zuiLoader`, never from declaration.
///
/// ```zig
/// const services = zui_app.ServicesOf(App.Host);
///
/// pub fn zuiLoader(app: *App, _: *const Ui, _: std.Io) void {
///     if (services.has_file_dialogs and app.wants_theme) {
///         app.wants_theme = false;
///         services.file_dialogs.show(app.host, .main, open_theme, .{ .filters = &.{themes} }, .of(&app.sources.replies)) catch {};
///     }
/// }
/// ```
pub fn ServicesOf(comptime Host: type) type {
    return struct {
        pub const has_clipboard = @hasDecl(Host, "zuiClipboard");
        pub const has_notifications = @hasDecl(Host, "zuiNotifications");
        pub const has_file_dialogs = @hasDecl(Host, "zuiFileDialogs");
        pub const has_open_url = @hasDecl(Host, "zuiOpenUrl");
        pub const has_menus = @hasDecl(Host, "zuiMenus");
        pub const has_menu_bar = if (has_menus) @hasDecl(Host.zuiMenus, "setBar") else false;
        pub const has_file_watch = @hasDecl(Host, "zuiFileWatch");

        pub const clipboard = serviceOrGuardError(Host, .clipboard);
        pub const notifications = serviceOrGuardError(Host, .notifications);
        pub const file_dialogs = serviceOrGuardError(Host, .file_dialogs);
        pub const open_url = serviceOrGuardError(Host, .open_url);
        pub const menus = serviceOrGuardError(Host, .menus);
        pub const file_watch = serviceOrGuardError(Host, .file_watch);
    };
}

fn serviceOrGuardError(comptime Host: type, comptime service: Service) type {
    const declaration = serviceDeclaration(service);
    if (@hasDecl(Host, declaration)) return @field(Host, declaration);
    @compileError("zui_app: " ++ @typeName(Host) ++ " has no `" ++ declaration ++ "`; guard the call with `if (zui_app.ServicesOf(" ++
        @typeName(Host) ++ ").has_" ++ @tagName(service) ++ ")`");
}

fn serviceDeclaration(service: Service) []const u8 {
    return switch (service) {
        .clipboard => "zuiClipboard",
        .notifications => "zuiNotifications",
        .file_dialogs => "zuiFileDialogs",
        .open_url => "zuiOpenUrl",
        .menus => "zuiMenus",
        .file_watch => "zuiFileWatch",
    };
}

/// What an application's `init` receives.
pub fn Start(comptime App: type) type {
    return struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        /// Null when a test starts the `Runner` itself.
        process: ?std.process.Init,
        host: *App.Host,
        /// For the renderer's own settings. While frames are submitted on a
        /// render thread, that thread uses it too.
        renderer: *App.Renderer,
        /// For the application's producers, as a source's publish asks.
        waker: zui.Waker,
        /// Opens and closes windows, for an application whose `zuiDeclare`
        /// takes a `zui.WindowId`; `void` for one with one window.
        windows: if (declaresWindows(App)) Windows(App) else void,
    };
}

/// How many windows `zui_app` runs at once: opening one more fails with
/// `error.TooManyWindows`.
pub const max_windows = 8;

/// The windows of an application whose `zuiDeclare` takes a
/// `zui.WindowId`, from `Start(App).windows`. Keep it to open and close
/// windows from `init`, `zuiLoader` or `zuiWindowClosed`: opening one
/// during `zuiDeclare` panics, since declaration does no I/O and a
/// replayed frame must open no window.
///
/// ```zig
/// pub fn zuiLoader(app: *App, _: *const Ui, window: zui.WindowId, _: std.Io) void {
///     if (window == .main and app.wants_inspector) {
///         app.wants_inspector = false;
///         app.inspector_window = app.windows.open(.{ .title = "Inspector", .size = .{ 480, 720 } }) catch null;
///     }
/// }
/// ```
pub fn Windows(comptime App: type) type {
    return struct {
        const Self = @This();
        /// The host opens more than one window; guard `open` with it.
        pub const has_many_windows = hostOpensManyWindows(App.Host);

        runner: *anyopaque,
        openFn: *const fn (*anyopaque, zui.WindowOptions) anyerror!zui.WindowId,
        closeFn: *const fn (*anyopaque, zui.WindowId) void,

        /// Opens a window and its context, which allocates as `init` does;
        /// its first frame runs by the next turn. `output_formats` and
        /// `semantics` are `zui_app`'s. On a host with one window this is a
        /// compile error.
        pub fn open(self: Self, options: zui.WindowOptions) anyerror!zui.WindowId {
            if (comptime !has_many_windows) {
                @compileError("zui_app: " ++ @typeName(App.Host) ++ " opens one window (its zui_capabilities.windows is .one), so " ++ @typeName(App) ++ " cannot open another");
            }
            return self.openFn(self.runner, options);
        }

        /// Closes `window` once this turn's frames are done; then
        /// `zuiWindowClosed` runs. A window that is not open is ignored.
        pub fn close(self: Self, window: zui.WindowId) void {
            self.closeFn(self.runner, window);
        }
    };
}

/// What `Runner.start` takes; `run` fills it from the process.
pub const Setup = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    process: ?std.process.Init = null,
};

/// Opens `App.Host`'s window and runs the loop of SPEC.md §6.1 until it
/// closes. `App` declares:
/// - `pub const Host` and `pub const Renderer`, which share a surface kind;
/// - `pub fn zuiDeclare(app: *App, ui: *Ui) void`, where `Ui` is a
///   `zui.Context` built with `contextConfig(Renderer, ...)`;
/// - `pub const Text` when the `Config`'s text contract is not the
///   renderer: `zui_app` makes one and gives the context and the renderer
///   a pointer to it;
/// - optionally `pub fn zuiRecord(app: *App, record: *zui.RecordBuilder) void`,
///   run after the host's poll, for the application's zoom and the events
///   it makes itself, after the host's;
/// - optionally `pub fn zuiObserve(app: *App, ui: *const Ui, frame: *const
///   Ui.Frame) void`, run on the UI thread with each frame `endFrame`
///   returns, before it is submitted, for an inspector that reads it:
///
///   ```zig
///   pub fn zuiObserve(app: *App, ui: *const Ui, frame: *const Ui.Frame) void {
///       app.inspector.observe(frame, if (ui.primaryPointer()) |pointer| pointer.position else null);
///   }
///   ```
/// - optionally `pub fn zuiLoader(app: *App, ui: *const Ui, io: std.Io) void`,
///   run after each frame and before the wait;
/// - a field `sources` when the `Config` has `Sources`, holding them or
///   pointing to them;
/// - optionally `pub fn init(app: *App, start: zui_app.Start(App)) !void`
///   and `pub fn deinit(app: *App) void`; without `init`, every field
///   needs a default.
///
/// An application with many windows declares `zuiDeclare(app: *App, ui:
/// *Ui, window: zui.WindowId)`, and each hook takes the window too:
/// `zuiRecord(app, window, record)`, `zuiObserve(app, ui, window, frame)`
/// and `zuiLoader(app, ui, window, io)`. Each window has a context of its
/// own, and a source has one reader, so with `Sources` it declares
/// `zuiSources(app: *App, window: zui.WindowId) *Ui.Sources` in place of
/// the field, and optionally `zuiWindowClosed(app: *App, window:
/// zui.WindowId) void`, run once a window's context is freed. Each turn
/// polls every window and declares only those with input, a new viewport,
/// scale, zoom or output format, or a `nextFrame` that is due, then waits
/// once for the earliest `nextFrame` of all. A window the user closes is
/// closed, and `run` returns once none is open.
///
/// The host declares `pub fn init(self: *Host, io: std.Io, window:
/// zui.WindowOptions) !void` and `pub fn deinit(self: *Host) void`. With
/// `features.semantics`, a host that declares `zuiSemantics` opens the
/// window with room for `Config.limits`' elements and text, and is handed
/// each frame's list on the UI thread, after `zuiObserve` and before the
/// frame is submitted. With `features.chrome_regions`, a host that declares
/// `zuiChromeRegions` is handed each frame's chrome regions at the same
/// point. The renderer may declare `pub fn init(self: *Renderer, surface:
/// zui.Surface) !void`, or with `App.Text` `pub fn init(self: *Renderer,
/// surface: zui.Surface, text: *const Text) !void`, or with `text: anytype`
/// for a renderer that draws any text's fonts, and `pub fn deinit(self:
/// *Renderer) void`. `App.Text` may declare `pub fn init(self:
/// *Text) !void` and `pub fn deinit(self: *Text) void`. Without `init`,
/// every field needs a default; with it, the fields that have a default
/// hold it when `init` is called.
pub fn run(comptime App: type, init: std.process.Init, options: Options) !void {
    const runner = try init.gpa.create(Runner(App));
    defer init.gpa.destroy(runner);
    try runner.start(.{ .gpa = init.gpa, .io = init.io, .process = init }, options);
    defer runner.stop();
    while (try runner.frame()) {}
}

/// `run`, one frame at a time, for tests and for applications that drive
/// the loop themselves. It must not move after `start`.
pub fn Runner(comptime App: type) type {
    comptime checkApp(App);
    return struct {
        const Self = @This();
        pub const Ui = UiOf(App);
        pub const Host = App.Host;
        pub const Renderer = App.Renderer;
        /// The text contract `zui_app` makes; `void` when the renderer
        /// measures, or nothing does.
        pub const Text = SeparateText(App);

        const windowed = declaresWindows(App);
        const host_opens_many_windows = hostOpensManyWindows(Host);
        const renderer_keeps_surfaces = @hasDecl(Renderer, "zuiAttachSurface");
        const EventBuffer = [Ui.limits.max_events_per_frame]zui.Event;
        const TextBuffer = [Ui.limits.max_text_input_bytes + Ui.limits.max_dropped_path_bytes]u8;

        /// One open window of an application with many: its context and
        /// what the loop keeps for it between turns.
        const Window = struct {
            id: zui.WindowId,
            ui: Ui,
            event_buffer: EventBuffer,
            text_buffer: TextBuffer,
            builder: zui.RecordBuilder,
            has_drawn: bool = false,
            drawn_params: zui.FrameParams = undefined,
            drawn_format: zui.OutputFormat = .sdr,
            closing: bool = false,
        };

        const OneWindowPending = struct { frame: *const Ui.Frame, surface: zui.Surface };
        /// What the UI thread asks of the render thread for a window, which
        /// it waits for, so the renderer is used by one thread at a time.
        const SurfaceChange = struct {
            surface: zui.Surface,
            done: std.Io.Event = .unset,
            error_code: u16 = 0,
        };
        const WindowedPending = union(enum) {
            frame: struct { frame: *const Ui.Frame, surface: zui.Surface, ui: *Ui },
            attach: *SurfaceChange,
            /// Comes after the window's last frame, so when it is done every
            /// frame of the window has been released.
            detach: *SurfaceChange,
        };
        const Pending = if (windowed) WindowedPending else OneWindowPending;
        const pending_capacity = if (windowed) Ui.frames_in_flight * max_windows + 1 else Ui.frames_in_flight;

        app: App,
        host: Host,
        text: Text,
        renderer: Renderer,
        ui: if (windowed) void else Ui,
        gpa: std.mem.Allocator,
        io: std.Io,
        notify: *const fn (Notice) void,
        report: Report,
        event_buffer: if (windowed) void else EventBuffer,
        text_buffer: if (windowed) void else TextBuffer,
        builder: if (windowed) void else zui.RecordBuilder,
        windows: if (windowed) [max_windows]?*Window else void,
        /// Set while `zuiDeclare` runs, when opening a window panics.
        declaring: bool,
        pending_buffer: [pending_capacity]Pending,
        pending: std.Io.Queue(Pending),
        render_task: std.Io.Group,
        render_thread_started: bool,
        /// The first error the render thread's `zuiSubmit` returned, as
        /// `@intFromError`; 0 for none.
        render_error: std.atomic.Value(u16),
        noticed: Noticed,

        const Noticed = struct {
            input_dropped: bool = false,
            limits: std.EnumSet(zui.Limit) = .initEmpty(),
            publishes_refused: bool = false,
            duplicate_ids: bool = false,
            unbalanced_tree: bool = false,
            semantics_dropped: bool = false,
        };

        pub fn start(self: *Self, setup: Setup, options: Options) !void {
            self.gpa = setup.gpa;
            self.io = setup.io;
            self.notify = options.notify;
            self.noticed = .{};
            self.render_error = .init(0);
            self.render_task = .init;
            self.render_thread_started = false;
            self.declaring = false;
            self.pending = .init(&self.pending_buffer);

            if (options.title_bar == .custom and !Ui.features.chrome_regions) return error.CustomTitleBarWithoutChromeRegions;
            setFieldDefaults(Host, &self.host);
            try self.host.init(setup.io, .{ .title = options.title, .size = options.size, .visible = options.visible, .resizable = options.resizable, .material = options.material, .output_formats = output_formats, .semantics = window_semantics, .title_bar = options.title_bar });
            errdefer self.host.deinit();
            if (Text != void) {
                if (@hasDecl(Text, "init")) {
                    setFieldDefaults(Text, &self.text);
                    try self.text.init();
                } else {
                    self.text = .{};
                }
            }
            errdefer if (Text != void and @hasDecl(Text, "deinit")) self.text.deinit();
            if (@hasDecl(Renderer, "init")) {
                setFieldDefaults(Renderer, &self.renderer);
                if (comptime rendererInitTakesText(App)) {
                    try self.renderer.init(self.host.zuiSurface(.main), &self.text);
                } else {
                    try self.renderer.init(self.host.zuiSurface(.main));
                }
            } else {
                self.renderer = .{};
            }
            errdefer if (@hasDecl(Renderer, "deinit")) self.renderer.deinit();
            if (windowed) {
                self.windows = @splat(null);
                self.windows[0] = try self.makeWindow(.main, options.zoom);
            } else {
                self.ui = try self.initUi();
                self.builder = .init(&self.event_buffer, &self.text_buffer);
                self.builder.params.zoom = options.zoom;
            }
            errdefer self.freeWindows();
            if (@hasDecl(App, "init")) {
                try self.app.init(.{
                    .gpa = setup.gpa,
                    .io = setup.io,
                    .process = setup.process,
                    .host = &self.host,
                    .renderer = &self.renderer,
                    .waker = self.host.zuiWaker(),
                    .windows = if (windowed) .{ .runner = self, .openFn = openWindow, .closeFn = closeWindow } else {},
                });
            } else {
                self.app = .{};
            }
            errdefer if (@hasDecl(App, "deinit")) self.app.deinit();

            self.report = .{
                .host = @typeName(Host),
                .renderer = @typeName(Renderer),
                .surfaces = Host.zui_surfaces.intersectWith(Renderer.zui_surfaces),
                .output_formats = output_formats,
                .capabilities = if (@hasDecl(Host, "zui_capabilities")) Host.zui_capabilities else .{},
                .submission = self.startRenderThread(options),
                .lowered = lowered,
                .missing_services = missing_services,
                .accessibility = accessibility,
            };
            self.notify(.{ .started = self.report });
        }

        const output_formats = zui.sharedOutputFormats(Host, Renderer);
        const bridges_semantics = Ui.features.semantics and @hasDecl(Host, "zuiSemantics");
        const hands_over_chrome = Ui.features.chrome_regions and @hasDecl(Host, "zuiChromeRegions");
        const window_semantics: zui.SemanticsCapacity = if (bridges_semantics) .{ .nodes = Ui.limits.max_elements, .text_bytes = Ui.limits.max_text_bytes } else .{};
        const accessibility: Accessibility = if (!Ui.features.semantics) .off else if (bridges_semantics) .bridged else .not_bridged;
        const lowered = if (@hasDecl(Renderer, "zui_commands")) Renderer.zui_commands.complement() else zui.CommandSet.initFull();
        const missing_services = blk: {
            var missing: Services = .initEmpty();
            for (std.enums.values(Service)) |service| {
                if (!@hasDecl(Host, serviceDeclaration(service))) missing.insert(service);
            }
            break :blk missing;
        };
        /// A wake can be told apart only when every source reports what it
        /// holds: otherwise every window is due on every turn.
        const sources_report_pending = blk: {
            if (!Ui.has_sources) break :blk true;
            for (@typeInfo(Ui.Sources).@"struct".fields) |field| {
                if (!@hasDecl(field.type, "zuiPending")) break :blk false;
            }
            break :blk true;
        };

        fn initUi(self: *Self) !Ui {
            if (!Ui.has_text) return Ui.init(self.gpa, self.io);
            if (Text != void) return Ui.init(self.gpa, self.io, &self.text);
            return Ui.init(self.gpa, self.io, &self.renderer);
        }

        fn makeWindow(self: *Self, id: zui.WindowId, zoom: f32) !*Window {
            const window = try self.gpa.create(Window);
            errdefer self.gpa.destroy(window);
            window.* = .{ .id = id, .ui = try self.initUi(), .event_buffer = undefined, .text_buffer = undefined, .builder = undefined };
            window.builder = .init(&window.event_buffer, &window.text_buffer);
            window.builder.params.zoom = zoom;
            return window;
        }

        fn destroyWindow(self: *Self, window: *Window) void {
            window.ui.deinit(self.gpa);
            self.gpa.destroy(window);
        }

        fn freeWindows(self: *Self) void {
            if (!windowed) return self.ui.deinit(self.gpa);
            for (&self.windows) |*slot| if (slot.*) |window| {
                self.destroyWindow(window);
                slot.* = null;
            };
        }

        fn startRenderThread(self: *Self, options: Options) Submission {
            if (!(@hasDecl(Renderer, "zui_render_thread") and Renderer.zui_render_thread)) return .{ .ui_thread = .renderer_needs_its_thread };
            if (Ui.frames_in_flight < 2) return .{ .ui_thread = .one_frame_in_flight };
            if (!options.render_thread) return .{ .ui_thread = .turned_off_in_options };
            self.render_task.concurrent(self.io, submitPending, .{self}) catch return .{ .ui_thread = .io_cannot_run_concurrently };
            self.render_thread_started = true;
            return .render_thread;
        }

        /// One turn of the loop: false once every window has closed.
        pub fn frame(self: *Self) !bool {
            const render_error = self.render_error.load(.acquire);
            if (render_error != 0) return @errorFromInt(render_error);
            if (windowed) return self.frameEveryDueWindow();

            if (!self.host.zuiPoll(.main, &self.builder)) return false;
            if (@hasDecl(App, "zuiRecord")) self.app.zuiRecord(&self.builder);
            self.noticeDroppedInput(&self.builder);
            try self.frameWindow(&self.ui, &self.builder, .main);
            self.host.zuiWait(self.nextFrameOf(&self.ui, .main));
            return true;
        }

        fn frameEveryDueWindow(self: *Self) !bool {
            for (&self.windows) |*slot| {
                const window = slot.* orelse continue;
                if (window.closing) continue;
                if (!self.host.zuiPoll(window.id, &window.builder)) {
                    window.closing = true;
                    continue;
                }
                if (@hasDecl(App, "zuiRecord")) self.app.zuiRecord(window.id, &window.builder);
                self.noticeDroppedInput(&window.builder);
                const format = self.host.zuiSurface(window.id).outputFormat();
                if (!self.isDue(window, format)) continue;
                window.has_drawn = true;
                window.drawn_params = window.builder.params;
                window.drawn_format = format;
                try self.frameWindow(&window.ui, &window.builder, window.id);
            }
            while (self.closeOneClosingWindow()) {}
            const next = self.earliestNextFrame() orelse return false;
            self.host.zuiWait(next);
            return true;
        }

        fn isDue(self: *Self, window: *Window, format: zui.OutputFormat) bool {
            if (!sources_report_pending or !window.has_drawn) return true;
            const params = window.builder.params;
            const drawn = window.drawn_params;
            if (window.builder.events().len != 0) return true;
            if (!std.meta.eql(params.viewport, drawn.viewport) or params.scale != drawn.scale or params.zoom != drawn.zoom) return true;
            if (format != window.drawn_format) return true;
            return switch (self.nextFrameOf(&window.ui, window.id)) {
                .immediately => true,
                .at => |instant| !params.now.isBefore(instant),
                .on_event => false,
            };
        }

        /// The soonest any open window needs a frame; null when none is open.
        fn earliestNextFrame(self: *Self) ?zui.NextFrame {
            var earliest: ?zui.NextFrame = null;
            for (self.windows) |slot| {
                const window = slot orelse continue;
                const next = if (window.has_drawn) self.nextFrameOf(&window.ui, window.id) else .immediately;
                earliest = switch (next) {
                    .immediately => return .immediately,
                    .at => |instant| if (earliest) |sooner| switch (sooner) {
                        .at => |other| .{ .at = if (other.isBefore(instant)) other else instant },
                        else => next,
                    } else next,
                    .on_event => earliest orelse next,
                };
            }
            return earliest;
        }

        /// Begins, declares and ends one frame of `ui`, hands it to the host
        /// and the renderer, and runs the loader.
        fn frameWindow(self: *Self, ui: *Ui, builder: *zui.RecordBuilder, window: zui.WindowId) !void {
            if (Ui.has_sources) {
                ui.beginFrame(&builder.recordWith(Ui.Deliveries), self.sourcesOf(window));
            } else {
                ui.beginFrame(&builder.record());
            }
            if (windowed) {
                self.declaring = true;
                self.app.zuiDeclare(ui, window);
                self.declaring = false;
            } else {
                self.app.zuiDeclare(ui);
            }
            const drawn = ui.endFrame();
            self.noticeDiagnostics(drawn.diagnostics);
            if (@hasDecl(App, "zuiObserve")) {
                if (windowed) self.app.zuiObserve(ui, window, drawn) else self.app.zuiObserve(ui, drawn);
            }
            if (bridges_semantics) self.noticeDroppedSemantics(self.host.zuiSemantics(window, drawn.semantics()));
            if (hands_over_chrome) self.host.zuiChromeRegions(window, drawn.chromeRegions());

            const surface = self.host.zuiSurface(window);
            if (self.render_thread_started) {
                self.host.zuiApply(window, drawn.requests());
                const pending: Pending = if (windowed) .{ .frame = .{ .frame = drawn, .surface = surface, .ui = ui } } else .{ .frame = drawn, .surface = surface };
                self.pending.putOneUncancelable(self.io, pending) catch unreachable;
            } else {
                self.renderer.zuiSubmit(surface, drawn) catch |err| {
                    ui.release(drawn);
                    return err;
                };
                self.host.zuiApply(window, drawn.requests());
                ui.release(drawn);
            }

            if (@hasDecl(App, "zuiLoader")) {
                if (windowed) self.app.zuiLoader(ui, window, self.io) else self.app.zuiLoader(ui, self.io);
            }
        }

        fn nextFrameOf(self: *Self, ui: *const Ui, window: zui.WindowId) zui.NextFrame {
            return if (Ui.has_sources) ui.nextFrame(self.sourcesOf(window)) else ui.nextFrame();
        }

        fn sourcesOf(self: *Self, window: zui.WindowId) *Ui.Sources {
            if (windowed) return self.app.zuiSources(window);
            return if (@FieldType(App, "sources") == Ui.Sources) &self.app.sources else self.app.sources;
        }

        fn openWindow(context: *anyopaque, options: zui.WindowOptions) anyerror!zui.WindowId {
            const self: *Self = @ptrCast(@alignCast(context));
            if (!host_opens_many_windows) unreachable;
            if (self.declaring) @panic("zui_app: a window was opened during zuiDeclare; declaration does no I/O, so open it from init, zuiLoader or zuiWindowClosed");
            const slot = for (&self.windows) |*slot| {
                if (slot.* == null) break slot;
            } else return error.TooManyWindows;
            if (options.title_bar == .custom and !Ui.features.chrome_regions) return error.CustomTitleBarWithoutChromeRegions;
            var window_options = options;
            window_options.output_formats = output_formats;
            window_options.semantics = window_semantics;
            const id = try self.host.zuiOpenWindow(window_options);
            errdefer self.host.zuiCloseWindow(id);
            const surface = self.host.zuiSurface(id);
            try self.attachSurface(surface);
            errdefer self.detachSurface(surface);
            slot.* = try self.makeWindow(id, 1);
            return id;
        }

        fn closeWindow(context: *anyopaque, id: zui.WindowId) void {
            const self: *Self = @ptrCast(@alignCast(context));
            for (self.windows) |slot| if (slot) |window| if (window.id == id) {
                window.closing = true;
            };
        }

        /// Closes one window marked closing, and false when there is none.
        /// The application's `zuiWindowClosed` may mark another.
        fn closeOneClosingWindow(self: *Self) bool {
            const slot = for (&self.windows) |*slot| {
                if (slot.*) |window| if (window.closing) break slot;
            } else return false;
            const window = slot.*.?;
            const id = window.id;
            slot.* = null;
            self.detachSurface(self.host.zuiSurface(id));
            self.destroyWindow(window);
            if (host_opens_many_windows) self.host.zuiCloseWindow(id);
            if (@hasDecl(App, "zuiWindowClosed")) self.app.zuiWindowClosed(id);
            return true;
        }

        fn attachSurface(self: *Self, surface: zui.Surface) !void {
            if (!renderer_keeps_surfaces) return;
            if (!self.render_thread_started) return self.renderer.zuiAttachSurface(surface);
            var change: SurfaceChange = .{ .surface = surface };
            self.pending.putOneUncancelable(self.io, .{ .attach = &change }) catch unreachable;
            change.done.waitUncancelable(self.io);
            if (change.error_code != 0) return @errorFromInt(change.error_code);
        }

        /// On the render thread, also waits until it has released every
        /// frame queued before.
        fn detachSurface(self: *Self, surface: zui.Surface) void {
            if (!self.render_thread_started) {
                if (renderer_keeps_surfaces) self.renderer.zuiDetachSurface(surface);
                return;
            }
            var change: SurfaceChange = .{ .surface = surface };
            self.pending.putOneUncancelable(self.io, .{ .detach = &change }) catch unreachable;
            change.done.waitUncancelable(self.io);
        }

        /// Submits what is left on the render thread, then frees everything
        /// `start` made, the application first, so it can join its work
        /// before its sources go.
        pub fn stop(self: *Self) void {
            if (self.render_thread_started) {
                self.pending.close(self.io);
                self.render_task.await(self.io) catch {};
            }
            if (@hasDecl(App, "deinit")) self.app.deinit();
            self.freeWindows();
            if (@hasDecl(Renderer, "deinit")) self.renderer.deinit();
            if (Text != void and @hasDecl(Text, "deinit")) self.text.deinit();
            self.host.deinit();
        }

        fn submitPending(self: *Self) void {
            while (self.pending.getOneUncancelable(self.io)) |pending| {
                if (!windowed) {
                    self.submitOnRenderThread(pending.surface, pending.frame, &self.ui);
                } else switch (pending) {
                    .frame => |queued| self.submitOnRenderThread(queued.surface, queued.frame, queued.ui),
                    .attach => |change| {
                        if (renderer_keeps_surfaces) self.renderer.zuiAttachSurface(change.surface) catch |err| {
                            change.error_code = @intFromError(err);
                        };
                        change.done.set(self.io);
                    },
                    .detach => |change| {
                        if (renderer_keeps_surfaces) self.renderer.zuiDetachSurface(change.surface);
                        change.done.set(self.io);
                    },
                }
            } else |_| {}
        }

        fn submitOnRenderThread(self: *Self, surface: zui.Surface, drawn: *const Ui.Frame, ui: *Ui) void {
            self.renderer.zuiSubmit(surface, drawn) catch |err| {
                _ = self.render_error.cmpxchgStrong(0, @intFromError(err), .release, .monotonic);
            };
            ui.release(drawn);
        }

        fn noticeDroppedSemantics(self: *Self, dropped: zui.SemanticsDropped) void {
            if (self.noticed.semantics_dropped or !dropped.any()) return;
            self.noticed.semantics_dropped = true;
            self.notify(.{ .semantics_dropped = dropped });
        }

        fn noticeDroppedInput(self: *Self, builder: *const zui.RecordBuilder) void {
            if (self.noticed.input_dropped) return;
            if (builder.dropped_events == 0 and builder.dropped_text_bytes == 0) return;
            self.noticed.input_dropped = true;
            self.notify(.{ .input_dropped = .{ .events = builder.dropped_events, .text_bytes = builder.dropped_text_bytes } });
        }

        fn noticeDiagnostics(self: *Self, diagnostics: zui.Diagnostics) void {
            var newly_exceeded = diagnostics.exceeded.differenceWith(self.noticed.limits).iterator();
            while (newly_exceeded.next()) |limit| {
                self.noticed.limits.insert(limit);
                self.notify(.{ .limit_exceeded = .{ .limit = limit, .allowed = allowed(limit), .needed = diagnostics.needed.get(limit), .first_dropped_id = diagnostics.first_dropped_id } });
            }
            if (diagnostics.refused_publishes != 0 and !self.noticed.publishes_refused) {
                self.noticed.publishes_refused = true;
                self.notify(.{ .publishes_refused = .{ .source = diagnostics.first_refusing_source, .count = diagnostics.refused_publishes } });
            }
            if (diagnostics.duplicate_ids != 0 and !self.noticed.duplicate_ids) {
                self.noticed.duplicate_ids = true;
                self.notify(.{ .duplicate_ids = diagnostics.duplicate_ids });
            }
            if (diagnostics.unbalanced and !self.noticed.unbalanced_tree) {
                self.noticed.unbalanced_tree = true;
                self.notify(.unbalanced_tree);
            }
        }

        fn allowed(limit: zui.Limit) u32 {
            return switch (limit) {
                inline else => |field| @intCast(@field(Ui.limits, @tagName(field))),
            };
        }
    };
}

/// The application's `zuiDeclare` takes a `zui.WindowId`, so it declares
/// each of many windows.
fn declaresWindows(comptime App: type) bool {
    if (!@hasDecl(App, "zuiDeclare")) return false;
    const info = @typeInfo(@TypeOf(App.zuiDeclare));
    return info == .@"fn" and info.@"fn".params.len == 3 and info.@"fn".params[2].type == zui.WindowId;
}

fn hostOpensManyWindows(comptime Host: type) bool {
    return @hasDecl(Host, "zui_capabilities") and Host.zui_capabilities.windows == .many;
}

fn UiOf(comptime App: type) type {
    return @typeInfo(@typeInfo(@TypeOf(App.zuiDeclare)).@"fn".params[1].type.?).pointer.child;
}

fn SeparateText(comptime App: type) type {
    return if (@hasDecl(App, "Text") and App.Text != App.Renderer) App.Text else void;
}

fn rendererInitTakesText(comptime App: type) bool {
    if (SeparateText(App) == void or !@hasDecl(App.Renderer, "init")) return false;
    const init = @typeInfo(@TypeOf(App.Renderer.init));
    return init == .@"fn" and init.@"fn".params.len == 3;
}

/// Leaves the fields without a default undefined, for `init` to set.
fn setFieldDefaults(comptime T: type, value: *T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.is_comptime) continue;
        if (field.default_value_ptr) |pointer| {
            const default: *const field.type = @ptrCast(@alignCast(pointer));
            @field(value, field.name) = default.*;
        }
    }
}

/// `zui_app`'s part of the composition root: what `Runner(App)` needs of
/// `App`, its host and its renderer, each mistake a compile error.
pub fn checkApp(comptime App: type) void {
    const name = @typeName(App);
    if (@typeInfo(App) != .@"struct") @compileError("zui_app: an application must be a struct type, got " ++ name);
    for (@typeInfo(App).@"struct".decls) |declaration| {
        if (!std.mem.startsWith(u8, declaration.name, "zui")) continue;
        const known = for ([_][]const u8{ "zuiDeclare", "zuiLoader", "zuiObserve", "zuiRecord", "zuiSources", "zuiWindowClosed" }) |known_name| {
            if (std.mem.eql(u8, declaration.name, known_name)) break true;
        } else false;
        if (!known) {
            @compileError("zui_app: " ++ name ++ " declares unknown `" ++ declaration.name ++ "`");
        }
    }
    if (!@hasDecl(App, "Host")) @compileError("zui_app: " ++ name ++ " must declare `pub const Host`, the host it runs on");
    if (!@hasDecl(App, "Renderer")) @compileError("zui_app: " ++ name ++ " must declare `pub const Renderer`, the renderer that draws it");
    if (!@hasDecl(App, "zuiDeclare")) @compileError("zui_app: " ++ name ++ " does not implement zui_app's application: missing `zuiDeclare`");
    zui.checkHostAndRenderer(App.Host, App.Renderer);

    const expected_declare = "fn (*" ++ name ++ ", *Ui) void, or fn (*" ++ name ++ ", *Ui, zui.WindowId) void for many windows, where Ui is a zui.Context";
    const Declare = @TypeOf(App.zuiDeclare);
    const declares_a_frame = switch (@typeInfo(Declare)) {
        .@"fn" => |function| (function.params.len == 2 or (function.params.len == 3 and function.params[2].type == zui.WindowId)) and
            function.return_type == void and function.params[0].type == *App and function.params[1].type != null and isContextPointer(function.params[1].type.?),
        else => false,
    };
    // Not "found ...": a Context's type name spells out its whole Config.
    if (!declares_a_frame) @compileError("zui_app: " ++ name ++ ".zuiDeclare must be " ++ expected_declare);
    const Ui = UiOf(App);
    const windowed = declaresWindows(App);
    const window_parameter = if (windowed) ", zui.WindowId" else "";
    const because_windowed = if (windowed) ", since its zuiDeclare takes a zui.WindowId" else "";
    const Loader = if (windowed) fn (*App, *const Ui, zui.WindowId, std.Io) void else fn (*App, *const Ui, std.Io) void;
    if (@hasDecl(App, "zuiLoader") and @TypeOf(App.zuiLoader) != Loader) {
        @compileError("zui_app: " ++ name ++ ".zuiLoader must be fn (*" ++ name ++ ", *const Ui" ++ window_parameter ++ ", std.Io) void" ++ because_windowed ++ ", found " ++ @typeName(@TypeOf(App.zuiLoader)));
    }
    const Observe = if (windowed) fn (*App, *const Ui, zui.WindowId, *const Ui.Frame) void else fn (*App, *const Ui, *const Ui.Frame) void;
    if (@hasDecl(App, "zuiObserve") and @TypeOf(App.zuiObserve) != Observe) {
        @compileError("zui_app: " ++ name ++ ".zuiObserve must be fn (*" ++ name ++ ", *const Ui" ++ window_parameter ++ ", *const Ui.Frame) void" ++ because_windowed);
    }
    const Record = if (windowed) fn (*App, zui.WindowId, *zui.RecordBuilder) void else fn (*App, *zui.RecordBuilder) void;
    if (@hasDecl(App, "zuiRecord") and @TypeOf(App.zuiRecord) != Record) {
        @compileError("zui_app: " ++ name ++ ".zuiRecord must be fn (*" ++ name ++ window_parameter ++ ", *zui.RecordBuilder) void" ++ because_windowed ++ ", found " ++ @typeName(@TypeOf(App.zuiRecord)));
    }
    for ([_][]const u8{ "zuiSources", "zuiWindowClosed" }) |window_hook| {
        if (!windowed and @hasDecl(App, window_hook)) {
            @compileError("zui_app: " ++ name ++ " declares `" ++ window_hook ++ "`, but its zuiDeclare takes no zui.WindowId, so it has one window");
        }
    }
    if (@hasDecl(App, "zuiWindowClosed") and @TypeOf(App.zuiWindowClosed) != fn (*App, zui.WindowId) void) {
        @compileError("zui_app: " ++ name ++ ".zuiWindowClosed must be fn (*" ++ name ++ ", zui.WindowId) void, found " ++ @typeName(@TypeOf(App.zuiWindowClosed)));
    }
    if (@hasDecl(App, "Text")) {
        if (Ui.Text != App.Text) @compileError("zui_app: " ++ name ++ ".Text is " ++ @typeName(App.Text) ++ ", but its Ui measures text with " ++ @typeName(Ui.Text));
    } else if (Ui.Text != void and Ui.Text != App.Renderer) {
        @compileError("zui_app: " ++ name ++ "'s Ui measures text with " ++ @typeName(Ui.Text) ++ ", which zui_app makes only when " ++ name ++ " declares `pub const Text = " ++ @typeName(Ui.Text) ++ "`");
    }
    const Text = SeparateText(App);
    if (Text != void) {
        const text_name = @typeName(Text);
        if (@hasDecl(Text, "init")) {
            expectFunction(Text, "init", fn (*Text) anyerror!void, "fn (*" ++ text_name ++ ") !void");
        } else for (@typeInfo(Text).@"struct".fields) |field| {
            if (field.default_value_ptr == null) @compileError("zui_app: " ++ text_name ++ " has no `init`, so every field needs a default; `" ++ field.name ++ "` has none");
        }
        if (@hasDecl(Text, "deinit")) expectFunction(Text, "deinit", fn (*Text) void, "fn (*" ++ text_name ++ ") void");
    }
    if (windowed and Ui.has_sources) {
        const expected_sources = "fn (*" ++ name ++ ", zui.WindowId) *" ++ @typeName(Ui.Sources);
        if (!@hasDecl(App, "zuiSources")) {
            @compileError("zui_app: " ++ name ++ " declares each window's UI, so it needs `pub fn zuiSources(app: *" ++ name ++ ", window: zui.WindowId) *" ++ @typeName(Ui.Sources) ++ "`, the sources of each window's context");
        }
        if (@TypeOf(App.zuiSources) != fn (*App, zui.WindowId) *Ui.Sources) {
            @compileError("zui_app: " ++ name ++ ".zuiSources must be " ++ expected_sources ++ ", found " ++ @typeName(@TypeOf(App.zuiSources)));
        }
    }
    const holds_sources = @hasField(App, "sources") and (@FieldType(App, "sources") == Ui.Sources or @FieldType(App, "sources") == *Ui.Sources);
    if (!windowed and Ui.has_sources and !holds_sources) {
        @compileError("zui_app: " ++ name ++ " needs a field `sources: " ++ @typeName(Ui.Sources) ++ "`, the Config's Sources or a pointer to them, for zui_app to swap");
    }
    if (@hasDecl(App, "init")) {
        expectFunction(App, "init", fn (*App, Start(App)) anyerror!void, "fn (*" ++ name ++ ", zui_app.Start(" ++ name ++ ")) !void");
    } else for (@typeInfo(App).@"struct".fields) |field| {
        if (field.default_value_ptr == null) @compileError("zui_app: " ++ name ++ " has no `init`, so every field needs a default; `" ++ field.name ++ "` has none");
    }
    if (@hasDecl(App, "deinit")) expectFunction(App, "deinit", fn (*App) void, "fn (*" ++ name ++ ") void");

    const host_name = @typeName(App.Host);
    if (!@hasDecl(App.Host, "init")) @compileError("zui_app: " ++ host_name ++ " must declare `pub fn init(self: *" ++ host_name ++ ", io: std.Io, window: zui.WindowOptions) !void`, which opens its window");
    expectFunction(App.Host, "init", fn (*App.Host, std.Io, zui.WindowOptions) anyerror!void, "fn (*" ++ host_name ++ ", std.Io, zui.WindowOptions) !void");
    if (!@hasDecl(App.Host, "deinit")) @compileError("zui_app: " ++ host_name ++ " must declare `pub fn deinit(self: *" ++ host_name ++ ") void`, which closes its window");
    expectFunction(App.Host, "deinit", fn (*App.Host) void, "fn (*" ++ host_name ++ ") void");

    const renderer_name = @typeName(App.Renderer);
    if (rendererInitTakesText(App)) {
        const expected_name = "fn (*" ++ renderer_name ++ ", zui.Surface, *const " ++ @typeName(Text) ++ ") !void";
        const parameters = @typeInfo(@TypeOf(App.Renderer.init)).@"fn".params;
        if (parameters[2].type == null) {
            if (parameters[0].type != *App.Renderer or parameters[1].type != zui.Surface) @compileError("zui_app: " ++ renderer_name ++ ".init must be " ++ expected_name ++ ", or take its text as `anytype`");
        } else if (parameters[2].type == *Text) {
            expectFunction(App.Renderer, "init", fn (*App.Renderer, zui.Surface, *Text) anyerror!void, expected_name);
        } else {
            expectFunction(App.Renderer, "init", fn (*App.Renderer, zui.Surface, *const Text) anyerror!void, expected_name);
        }
    } else if (@hasDecl(App.Renderer, "init")) {
        expectFunction(App.Renderer, "init", fn (*App.Renderer, zui.Surface) anyerror!void, "fn (*" ++ renderer_name ++ ", zui.Surface) !void");
    } else for (@typeInfo(App.Renderer).@"struct".fields) |field| {
        if (field.default_value_ptr == null) @compileError("zui_app: " ++ renderer_name ++ " has no `init`, so every field needs a default; `" ++ field.name ++ "` has none");
    }
    if (@hasDecl(App.Renderer, "deinit")) expectFunction(App.Renderer, "deinit", fn (*App.Renderer) void, "fn (*" ++ renderer_name ++ ") void");
}

fn isContextPointer(comptime Pointer: type) bool {
    const info = @typeInfo(Pointer);
    if (info != .pointer or info.pointer.size != .one or info.pointer.is_const) return false;
    const Child = info.pointer.child;
    return @typeInfo(Child) == .@"struct" and @hasDecl(Child, "beginFrame") and @hasDecl(Child, "endFrame") and @hasDecl(Child, "FrameRecord");
}

/// `Expected`'s error set, if any, is `anyerror`: any error set matches.
fn expectFunction(comptime Implementer: type, comptime declaration: []const u8, comptime Expected: type, comptime expected_name: []const u8) void {
    const Found = @TypeOf(@field(Implementer, declaration));
    const found = @typeInfo(Found);
    const expected = @typeInfo(Expected).@"fn";
    const matches = found == .@"fn" and found.@"fn".params.len == expected.params.len and blk: {
        for (found.@"fn".params, expected.params) |found_parameter, expected_parameter| {
            if (found_parameter.type != expected_parameter.type) break :blk false;
        }
        const Returned = found.@"fn".return_type orelse break :blk false;
        if (expected.return_type.? == void) break :blk Returned == void;
        break :blk @typeInfo(Returned) == .error_union and @typeInfo(Returned).error_union.payload == void;
    };
    if (!matches) @compileError("zui_app: " ++ @typeName(Implementer) ++ "." ++ declaration ++ " must be " ++ expected_name ++ ", found " ++ @typeName(Found));
}

test {
    _ = @import("tests.zig");
}

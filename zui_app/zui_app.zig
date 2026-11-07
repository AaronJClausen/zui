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

/// A `zui.Config` for `Renderer`: its optional commands, its payload
/// types, and the renderer itself as the text contract when it declares
/// `zuiMeasure`. Every other field comes from `overrides`.
///
/// ```zig
/// const Ui = zui.Context(zui_app.contextConfig(zui_raylib.Renderer, .{ .Sources = AppSources }));
/// ```
pub fn contextConfig(comptime Renderer: type, comptime overrides: zui.Config) zui.Config {
    comptime zui.checkRenderer(Renderer);
    var result = overrides;
    result.commands = if (@hasDecl(Renderer, "zui_commands")) Renderer.zui_commands else .initEmpty();
    result.ImageHandle = rendererType(Renderer, "ImageHandle", void);
    result.CustomData = rendererType(Renderer, "CustomData", void);
    result.MaterialHandle = rendererType(Renderer, "MaterialHandle", void);
    result.FontId = rendererType(Renderer, "FontId", u16);
    if (@hasDecl(Renderer, "zuiMeasure")) result.Text = Renderer;
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
    /// The host's record had no room: raise `limits.max_events_per_frame`
    /// or `limits.max_text_input_bytes`.
    input_dropped: struct { events: u32, text_bytes: u32 },
    limit_exceeded: struct { limit: zui.Limit, allowed: u32, needed: u32, first_dropped_id: u64 },
    /// A full source refused publishes; raise the capacity of `source`.
    publishes_refused: struct { source: []const u8, count: u32 },
    duplicate_ids: u32,
    unbalanced_tree,

    pub fn format(self: Notice, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .started => |report| try writer.print("{f}", .{report}),
            .input_dropped => |dropped| try writer.print("the host dropped {d} events and {d} bytes of typed text that did not fit the record; raise limits.max_events_per_frame or limits.max_text_input_bytes", .{ dropped.events, dropped.text_bytes }),
            .limit_exceeded => |exceeded| try writer.print("limits.{t} is {d}, but a frame needed {d}; what fit was drawn (first dropped id 0x{x})", .{ exceeded.limit, exceeded.allowed, exceeded.needed, exceeded.first_dropped_id }),
            .publishes_refused => |refused| try writer.print("the full source `{s}` refused {d} publishes; raise its capacity", .{ refused.source, refused.count }),
            .duplicate_ids => |count| try writer.print("{d} ids were declared twice in one frame; the second of each is not interactive", .{count}),
            .unbalanced_tree => try writer.writeAll("open and close were unbalanced; the frame closed what was left open"),
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
    capabilities: zui.HostCapabilities,
    submission: Submission,
    /// Optional commands the renderer does not draw, which zui lowers.
    lowered: zui.CommandSet,
    /// Host services that are absent.
    missing_services: Services,

    pub fn format(self: Report, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s} with {s}; {s}", .{ self.host, self.renderer, if (self.capabilities.windows == .many) "many windows" else "one window" });
        if (!self.capabilities.system_material) try writer.writeAll("; no system material, so the root draws its own background");
        switch (self.submission) {
            .render_thread => try writer.writeAll("; submitting on a render thread"),
            .ui_thread => |reason| try writer.print("; submitting on the UI thread, since {s}", .{reason.describe()}),
        }
        try writeSet(writer, "; lowered: ", self.lowered);
        try writeSet(writer, "; no host ", self.missing_services);
    }

    fn writeSet(writer: *std.Io.Writer, comptime prefix: []const u8, set: anytype) std.Io.Writer.Error!void {
        var members = set.iterator();
        var first = true;
        while (members.next()) |member| : (first = false) {
            try writer.print("{s}{t}", .{ if (first) prefix else ", ", member });
        }
    }
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
        /// For the application's producers, as a source's publish asks.
        waker: zui.Waker,
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
/// - optionally `pub fn zuiLoader(app: *App, ui: *const Ui, io: std.Io) void`,
///   run after each frame and before the wait;
/// - a field `sources` when the `Config` has `Sources`;
/// - optionally `pub fn init(app: *App, start: zui_app.Start(App)) !void`
///   and `pub fn deinit(app: *App) void`; without `init`, every field
///   needs a default.
///
/// The host declares `pub fn init(self: *Host, io: std.Io, window:
/// zui.WindowOptions) !void` and `pub fn deinit(self: *Host) void`. The
/// renderer may declare `pub fn init(self: *Renderer, surface:
/// zui.Surface) !void` and `pub fn deinit(self: *Renderer) void`; without
/// `init`, every field needs a default.
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

        const window: zui.WindowId = .main;
        const Pending = struct { frame: *const Ui.Frame, surface: zui.Surface };

        app: App,
        host: Host,
        renderer: Renderer,
        ui: Ui,
        gpa: std.mem.Allocator,
        io: std.Io,
        notify: *const fn (Notice) void,
        report: Report,
        event_buffer: [Ui.limits.max_events_per_frame]zui.Event,
        text_buffer: [Ui.limits.max_text_input_bytes]u8,
        builder: zui.RecordBuilder,
        pending_buffer: [Ui.frames_in_flight]Pending,
        pending: std.Io.Queue(Pending),
        render_task: std.Io.Group,
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
        };

        pub fn start(self: *Self, setup: Setup, options: Options) !void {
            self.gpa = setup.gpa;
            self.io = setup.io;
            self.notify = options.notify;
            self.noticed = .{};
            self.render_error = .init(0);
            self.render_task = .init;

            try self.host.init(setup.io, .{ .title = options.title, .size = options.size, .visible = options.visible, .resizable = options.resizable });
            errdefer self.host.deinit();
            if (@hasDecl(Renderer, "init")) {
                try self.renderer.init(self.host.zuiSurface(window));
            } else {
                self.renderer = .{};
            }
            errdefer if (@hasDecl(Renderer, "deinit")) self.renderer.deinit();
            self.ui = if (Ui.has_text) try Ui.init(setup.gpa, setup.io, &self.renderer) else try Ui.init(setup.gpa, setup.io);
            errdefer self.ui.deinit(setup.gpa);
            if (@hasDecl(App, "init")) {
                try self.app.init(.{ .gpa = setup.gpa, .io = setup.io, .process = setup.process, .host = &self.host, .waker = self.host.zuiWaker() });
            } else {
                self.app = .{};
            }
            errdefer if (@hasDecl(App, "deinit")) self.app.deinit();

            self.builder = .init(&self.event_buffer, &self.text_buffer);
            self.builder.params.zoom = options.zoom;
            self.pending = .init(&self.pending_buffer);
            self.report = .{
                .host = @typeName(Host),
                .renderer = @typeName(Renderer),
                .surfaces = Host.zui_surfaces.intersectWith(Renderer.zui_surfaces),
                .capabilities = if (@hasDecl(Host, "zui_capabilities")) Host.zui_capabilities else .{},
                .submission = self.startRenderThread(options),
                .lowered = lowered,
                .missing_services = missing_services,
            };
            self.notify(.{ .started = self.report });
        }

        const lowered = if (@hasDecl(Renderer, "zui_commands")) Renderer.zui_commands.complement() else zui.CommandSet.initFull();
        const missing_services = blk: {
            var missing: Services = .initEmpty();
            for (std.enums.values(Service)) |service| {
                if (!@hasDecl(Host, serviceDeclaration(service))) missing.insert(service);
            }
            break :blk missing;
        };

        fn startRenderThread(self: *Self, options: Options) Submission {
            if (!(@hasDecl(Renderer, "zui_render_thread") and Renderer.zui_render_thread)) return .{ .ui_thread = .renderer_needs_its_thread };
            if (Ui.frames_in_flight < 2) return .{ .ui_thread = .one_frame_in_flight };
            if (!options.render_thread) return .{ .ui_thread = .turned_off_in_options };
            self.render_task.concurrent(self.io, submitPending, .{self}) catch return .{ .ui_thread = .io_cannot_run_concurrently };
            return .render_thread;
        }

        /// One turn of the loop: false once the window has closed.
        pub fn frame(self: *Self) !bool {
            const render_error = self.render_error.load(.acquire);
            if (render_error != 0) return @errorFromInt(render_error);
            if (!self.host.zuiPoll(window, &self.builder)) return false;
            self.noticeDroppedInput();

            if (Ui.has_sources) {
                self.ui.beginFrame(&self.builder.recordWith(Ui.Deliveries), &self.app.sources);
            } else {
                self.ui.beginFrame(&self.builder.record());
            }
            self.app.zuiDeclare(&self.ui);
            const drawn = self.ui.endFrame();
            self.noticeDiagnostics(drawn.diagnostics);

            const surface = self.host.zuiSurface(window);
            if (self.report.submission == .render_thread) {
                self.host.zuiApply(window, drawn.requests());
                self.pending.putOneUncancelable(self.io, .{ .frame = drawn, .surface = surface }) catch unreachable;
            } else {
                self.renderer.zuiSubmit(surface, drawn) catch |err| {
                    self.ui.release(drawn);
                    return err;
                };
                self.host.zuiApply(window, drawn.requests());
                self.ui.release(drawn);
            }

            if (@hasDecl(App, "zuiLoader")) self.app.zuiLoader(&self.ui, self.io);
            self.host.zuiWait(if (Ui.has_sources) self.ui.nextFrame(&self.app.sources) else self.ui.nextFrame());
            return true;
        }

        /// Submits what is left on the render thread, then frees everything
        /// `start` made, the application first, so it can join its work
        /// before its sources go.
        pub fn stop(self: *Self) void {
            if (self.report.submission == .render_thread) {
                self.pending.close(self.io);
                self.render_task.await(self.io) catch {};
            }
            if (@hasDecl(App, "deinit")) self.app.deinit();
            self.ui.deinit(self.gpa);
            if (@hasDecl(Renderer, "deinit")) self.renderer.deinit();
            self.host.deinit();
        }

        fn submitPending(self: *Self) void {
            while (self.pending.getOneUncancelable(self.io)) |pending| {
                self.renderer.zuiSubmit(pending.surface, pending.frame) catch |err| {
                    _ = self.render_error.cmpxchgStrong(0, @intFromError(err), .release, .monotonic);
                };
                self.ui.release(pending.frame);
            } else |_| {}
        }

        fn noticeDroppedInput(self: *Self) void {
            if (self.noticed.input_dropped) return;
            if (self.builder.dropped_events == 0 and self.builder.dropped_text_bytes == 0) return;
            self.noticed.input_dropped = true;
            self.notify(.{ .input_dropped = .{ .events = self.builder.dropped_events, .text_bytes = self.builder.dropped_text_bytes } });
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

fn UiOf(comptime App: type) type {
    return @typeInfo(@typeInfo(@TypeOf(App.zuiDeclare)).@"fn".params[1].type.?).pointer.child;
}

/// `zui_app`'s part of the composition root: what `Runner(App)` needs of
/// `App`, its host and its renderer, each mistake a compile error.
pub fn checkApp(comptime App: type) void {
    const name = @typeName(App);
    if (@typeInfo(App) != .@"struct") @compileError("zui_app: an application must be a struct type, got " ++ name);
    for (@typeInfo(App).@"struct".decls) |declaration| {
        if (!std.mem.startsWith(u8, declaration.name, "zui")) continue;
        if (!std.mem.eql(u8, declaration.name, "zuiDeclare") and !std.mem.eql(u8, declaration.name, "zuiLoader")) {
            @compileError("zui_app: " ++ name ++ " declares unknown `" ++ declaration.name ++ "`");
        }
    }
    if (!@hasDecl(App, "Host")) @compileError("zui_app: " ++ name ++ " must declare `pub const Host`, the host it runs on");
    if (!@hasDecl(App, "Renderer")) @compileError("zui_app: " ++ name ++ " must declare `pub const Renderer`, the renderer that draws it");
    if (!@hasDecl(App, "zuiDeclare")) @compileError("zui_app: " ++ name ++ " does not implement zui_app's application: missing `zuiDeclare`");
    zui.checkHostAndRenderer(App.Host, App.Renderer);

    const expected_declare = "fn (*" ++ name ++ ", *Ui) void, where Ui is a zui.Context";
    const Declare = @TypeOf(App.zuiDeclare);
    const declares_a_frame = switch (@typeInfo(Declare)) {
        .@"fn" => |function| function.params.len == 2 and function.return_type == void and
            function.params[0].type == *App and function.params[1].type != null and isContextPointer(function.params[1].type.?),
        else => false,
    };
    // Not "found ...": a Context's type name spells out its whole Config.
    if (!declares_a_frame) @compileError("zui_app: " ++ name ++ ".zuiDeclare must be " ++ expected_declare);
    const Ui = UiOf(App);
    if (@hasDecl(App, "zuiLoader") and @TypeOf(App.zuiLoader) != fn (*App, *const Ui, std.Io) void) {
        @compileError("zui_app: " ++ name ++ ".zuiLoader must be fn (*" ++ name ++ ", *const Ui, std.Io) void, found " ++ @typeName(@TypeOf(App.zuiLoader)));
    }
    if (Ui.Text != void and Ui.Text != App.Renderer) {
        @compileError("zui_app: " ++ name ++ "'s Ui measures text with " ++ @typeName(Ui.Text) ++ ", but zui_app gives it the renderer; build its Config with zui_app.contextConfig(" ++ @typeName(App.Renderer) ++ ", ...)");
    }
    if (Ui.has_sources and !(@hasField(App, "sources") and @FieldType(App, "sources") == Ui.Sources)) {
        @compileError("zui_app: " ++ name ++ " needs a field `sources: " ++ @typeName(Ui.Sources) ++ "`, the Config's Sources, for zui_app to swap");
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
    if (@hasDecl(App.Renderer, "init")) {
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

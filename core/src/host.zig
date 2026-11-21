const std = @import("std");
const Wake = @import("sources.zig").Wake;
const NextFrame = @import("record.zig").NextFrame;
const OutputFormats = @import("surface.zig").OutputFormats;
const SemanticsCapacity = @import("semantics.zig").SemanticsCapacity;

/// One of a host's windows. `init` opens `.main`; a host whose
/// `zui_capabilities.windows` is `.many` opens others with `zuiOpenWindow`,
/// each with an id it never gives again in the run.
pub const WindowId = enum(u32) {
    main = 0,
    _,
};

/// What a host can do beyond the required contract. The application reads
/// them through `zui_app`; what this machine lacks at run time is a status
/// returned by the call instead.
pub const HostCapabilities = struct {
    /// `.many`: the host declares `zuiOpenWindow` and `zuiCloseWindow`.
    windows: Windows = .one,
    /// The desktop can show through the window, as Mica or vibrancy.
    system_material: bool = false,
    /// The host can leave a window's title bar to the application,
    /// `WindowOptions.title_bar = .custom`, and declares
    /// `zuiChromeRegions`, so the OS still moves, resizes and snaps it.
    custom_title_bar: bool = false,

    pub const Windows = enum { one, many };
};

/// What a host opens a window with: `zui_app` passes it to the host's
/// `init`, and to `zuiOpenWindow` for each window after the first.
pub const WindowOptions = struct {
    /// UTF-8.
    title: [:0]const u8 = "zui",
    /// The window's content area, in layout units at a scale of 1.
    size: [2]u32 = .{ 1280, 720 },
    /// False for a window that never shows, as tests and offscreen
    /// captures want.
    visible: bool = true,
    resizable: bool = true,
    /// What shows behind the window's content where nothing is drawn, on a
    /// host whose `zui_capabilities.system_material` is true. Whether it
    /// shows on this machine arrives as `Environment.system_material`.
    material: SystemMaterial = .none,
    /// The formats the host may open the window's surface in: those it
    /// and the renderer share, `zui.sharedOutputFormats`. It picks the
    /// best its display shows, such as `.scrgb_fp16` on an HDR display,
    /// and falls back to `.sdr`.
    output_formats: OutputFormats = .initOne(.sdr),
    /// Room for the window's accessibility bridge, which the host takes
    /// when it opens the window; without it, a host leaves the window to
    /// the OS's default accessibility.
    semantics: SemanticsCapacity = .{},
    /// Who draws the title bar. With `.custom`, on a host whose
    /// `zui_capabilities.custom_title_bar` is true, the application draws
    /// it and marks its parts with `Element.chrome`. Whether the window got
    /// one arrives as `Environment.custom_title_bar`.
    title_bar: TitleBar = .native,
};

/// Why `zuiOpenWindow` could not open a window.
pub const OpenWindowError = error{
    /// The host has as many windows open as it holds.
    TooManyWindows,
    /// The OS refused the window, or its surface.
    WindowNotCreated,
};

/// Who draws a window's title bar.
pub const TitleBar = enum {
    /// The system, with its own caption buttons.
    native,
    /// The application, inside the window's content.
    custom,
};

/// The system's backdrop for a window, by role; each host maps it to the
/// closest its OS has.
pub const SystemMaterial = enum {
    /// The window draws its own background.
    none,
    /// A long-lived main window: Mica on Windows 11.
    window,
    /// A short-lived or floating window, more see-through: Acrylic on
    /// Windows 11.
    transient,
};

/// One change a host's file watch saw in a directory it watches. Plain
/// data, so a source of them relays, replays and goes over the wire.
pub const FileChange = struct {
    kind: Kind,
    /// Relative to the watched directory, in UTF-8, with `/` between
    /// directories; empty for `.rescan`.
    path: Path = .{},

    pub const Kind = enum(u8) {
        added,
        removed,
        modified,
        /// The path's old name; a `.renamed_to` with the new one follows.
        renamed_from,
        renamed_to,
        /// Changes were lost (the OS's buffer overflowed, or a path was
        /// longer than `Path.capacity`): read the directory again.
        rescan,
    };

    pub const Path = struct {
        bytes: [capacity]u8 = @splat(0),
        len: u8 = 0,

        pub const capacity = 255;

        pub fn slice(self: *const Path) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    /// A change to `path`, or `.rescan` when `path` does not fit, since a
    /// path cut short would name another file.
    pub fn of(kind: Kind, path: []const u8) FileChange {
        if (path.len > Path.capacity) return .{ .kind = .rescan };
        var change: FileChange = .{ .kind = kind, .path = .{ .len = @intCast(path.len) } };
        @memcpy(change.path.bytes[0..path.len], path);
        return change;
    }

    pub fn pathBytes(self: *const FileChange) []const u8 {
        return self.path.slice();
    }
};

/// Where a host's file watch publishes each change, from a thread of the
/// host's: usually a source in the application's `Sources`, which the host
/// wakes for when the publish made it fresh.
///
/// ```zig
/// try Host.zuiFileWatch.watch(host, "themes", .of(&app.sources.theme_files));
/// ```
pub const FileChangeSink = struct {
    /// The source's own pointer, passed back to `publishFn`.
    context: *anyopaque,
    publishFn: *const fn (*anyopaque, FileChange) Wake,

    pub fn publish(self: FileChangeSink, change: FileChange) Wake {
        return self.publishFn(self.context, change);
    }

    /// A sink into any source whose `publish(change)` returns a `zui.Wake`
    /// or `error{Full}!zui.Wake`, such as `zui_async.Stream(zui.FileChange,
    /// ...)`. A change a full source refuses is the source's to count.
    pub fn of(source: anytype) FileChangeSink {
        const Source = @typeInfo(@TypeOf(source)).pointer.child;
        const adapter = struct {
            fn publish(context: *anyopaque, change: FileChange) Wake {
                const target: *Source = @ptrCast(@alignCast(context));
                const published = target.publish(change);
                return if (@typeInfo(@TypeOf(published)) == .error_union) published catch .already_pending else published;
            }
        };
        return .{ .context = source, .publishFn = adapter.publish };
    }
};

/// Why a host's file watch could not start.
pub const FileWatchError = error{
    /// The host watches as many directories as it can.
    TooManyWatches,
    /// The directory does not exist or cannot be opened.
    DirectoryUnavailable,
};

/// What a host that runs its own loop is handed by `zui_app`, through
/// `zuiRun`, to call from the platform's callbacks: one per run, as a host
/// hands out its `Waker`. Every call is made on the thread that polls.
///
/// ```zig
/// pub fn zuiRun(self: *Host, io: std.Io, window: zui.WindowOptions, driver: zui.Driver) !void {
///     try self.openCanvas(window);
///     try driver.start(io);
///     defer driver.stop();
///     while (self.nextAnimationFrame()) {
///         const next = try driver.step() orelse return;
///         self.schedule(next);
///     }
/// }
/// ```
pub const Driver = struct {
    context: *anyopaque,
    calls: *const Calls,

    pub const Calls = struct {
        start: *const fn (*anyopaque, std.Io) anyerror!void,
        step: *const fn (*anyopaque) anyerror!?NextFrame,
        suspendSurfaces: *const fn (*anyopaque) void,
        resumeSurfaces: *const fn (*anyopaque) anyerror!void,
        stop: *const fn (*anyopaque) void,
    };

    /// Once the main window is open and `zuiSurface(.main)` names its
    /// surface: makes the text, the renderer, the contexts and the
    /// application, whose tasks run on `io`, which may be the host's own.
    pub fn start(self: Driver, io: std.Io) anyerror!void {
        return self.calls.start(self.context, io);
    }

    /// One turn, which never blocks: polls every window and declares,
    /// ends and submits those that are due. Returns when the next turn is
    /// wanted, for the host to schedule, or null once every window has
    /// closed, when the host calls `stop`.
    pub fn step(self: Driver) anyerror!?NextFrame {
        return self.calls.step(self.context);
    }

    /// The platform took the windows' surfaces away, as Android does on
    /// pause or a GPU does when its device is lost: the renderer lets go
    /// of what it keeps for each, and turns until `resumeSurfaces`
    /// declare nothing.
    pub fn suspendSurfaces(self: Driver) void {
        self.calls.suspendSurfaces(self.context);
    }

    /// Each window has a surface again, as `zuiSurface` now names it: the
    /// renderer is handed each one, and every window is due.
    pub fn resumeSurfaces(self: Driver) anyerror!void {
        return self.calls.resumeSurfaces(self.context);
    }

    /// Frees what `start` made, the application first. Call it before
    /// the window closes; a second call, or one without `start`, does
    /// nothing.
    pub fn stop(self: Driver) void {
        self.calls.stop(self.context);
    }
};

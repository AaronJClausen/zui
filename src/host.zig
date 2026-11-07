const Wake = @import("sources.zig").Wake;

/// One of a host's windows. A host with one window calls it `.main`.
pub const WindowId = enum(u32) {
    main = 0,
    _,
};

/// What a host can do beyond the required contract. The application reads
/// them through `zui_app`; what this machine lacks at run time is a status
/// returned by the call instead.
pub const HostCapabilities = struct {
    windows: Windows = .one,
    /// The desktop can show through the window, as Mica or vibrancy.
    system_material: bool = false,

    pub const Windows = enum { one, many };
};

/// What a host opens a window with: `zui_app` passes it to the host's
/// `init`, and a host with many windows will open each one with it.
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

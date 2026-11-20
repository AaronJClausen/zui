const std = @import("std");
const Wake = @import("sources.zig").Wake;
const WindowId = @import("host.zig").WindowId;
const Chord = @import("input.zig").Chord;

/// Names one call to a host service, so its answer can be told from
/// others'. The application chooses it.
///
/// ```zig
/// const open_theme: zui.ServiceRequest = .of("open theme");
/// ```
pub const ServiceRequest = enum(u32) {
    _,

    pub fn of(comptime name: []const u8) ServiceRequest {
        return @enumFromInt(comptime std.hash.Fnv1a_32.hash(name));
    }
};

/// Why a host's service refused a call, before it began.
pub const ServiceError = error{
    /// The host is still answering an earlier call of the same kind: a
    /// dialog or a menu still open, a clipboard read or a URL not yet
    /// handed over. A host shows one dialog or menu at a time.
    Busy,
    /// More than the host holds: the text to copy, a URL, a menu's items
    /// or labels, a dialog's strings or filters.
    TooLarge,
    InvalidUtf8,
    /// Not a URL with a scheme of two letters or more, or a `file:` URL,
    /// which would open, and so run, whatever it names.
    InvalidUrl,
    /// The system cannot do it now, or on this machine.
    Unavailable,
};

/// Why a service that began could not finish.
pub const ServiceFailure = enum(u8) {
    /// Another application holds the clipboard, or the dialog failed to open.
    unavailable,
    /// The user or the system refused, as notifications turned off.
    denied,
};

/// What one call answered, borrowed for the publish: a sink copies it.
pub const ServiceAnswer = struct {
    request: ServiceRequest,
    window: WindowId = .main,
    outcome: Outcome,
    /// Text or paths the host itself could not hold, beyond the outcome's.
    left_out_bytes: u32 = 0,

    pub const Outcome = union(enum) {
        /// UTF-8.
        clipboard_text: []const u8,
        /// Each path in UTF-8, followed by a 0 byte, as `FilesDropped.path_list`.
        files_chosen: []const u8,
        menu_item_chosen: MenuItemId,
        notification_activated,
        /// Closed, timed out, or replaced by the next notification.
        notification_dismissed,
        canceled,
        failed: ServiceFailure,
    };
};

/// A service's answer as plain data, its text or paths inline, so a source
/// of them relays, replays and goes over the wire. The application chooses
/// how many bytes it holds.
///
/// ```zig
/// replies: zui_async.Stream(zui.ServiceReply(16 * 1024), .{ .capacity = 8 }) = .{},
/// ```
pub fn ServiceReply(comptime byte_capacity: u32) type {
    return struct {
        const Self = @This();

        request: ServiceRequest,
        window: WindowId = .main,
        kind: Kind,
        menu_item: MenuItemId = @enumFromInt(0),
        failure: ServiceFailure = .unavailable,
        /// Text past `capacity`, cut at a character, or paths that did not
        /// fit whole and were left out, here or by the host.
        left_out_bytes: u32 = 0,
        len: u32 = 0,
        bytes: [byte_capacity]u8 = @splat(0),

        pub const capacity = byte_capacity;
        pub const Kind = std.meta.Tag(ServiceAnswer.Outcome);

        /// Copies what fits: text cut at a character, paths kept whole.
        pub fn of(answer: *const ServiceAnswer) Self {
            var reply: Self = .{ .request = answer.request, .window = answer.window, .kind = std.meta.activeTag(answer.outcome) };
            switch (answer.outcome) {
                .clipboard_text => |text_bytes| reply.keepText(text_bytes),
                .files_chosen => |path_list| reply.keepPaths(path_list),
                .menu_item_chosen => |item| reply.menu_item = item,
                .failed => |failure| reply.failure = failure,
                .notification_activated, .notification_dismissed, .canceled => {},
            }
            reply.left_out_bytes +|= answer.left_out_bytes;
            return reply;
        }

        fn keepText(self: *Self, text_bytes: []const u8) void {
            var kept = @min(text_bytes.len, capacity);
            while (kept > 0 and kept < text_bytes.len and isContinuationByte(text_bytes[kept])) kept -= 1;
            @memcpy(self.bytes[0..kept], text_bytes[0..kept]);
            self.len = @intCast(kept);
            self.left_out_bytes = std.math.lossyCast(u32, text_bytes.len - kept);
        }

        fn keepPaths(self: *Self, path_list: []const u8) void {
            var paths_in_answer = std.mem.tokenizeScalar(u8, path_list, 0);
            while (paths_in_answer.next()) |path| {
                if (path.len + 1 > capacity - self.len) {
                    self.left_out_bytes +|= std.math.lossyCast(u32, path.len + 1);
                    continue;
                }
                @memcpy(self.bytes[self.len..][0..path.len], path);
                self.bytes[self.len + path.len] = 0;
                self.len += @intCast(path.len + 1);
            }
        }

        /// `.clipboard_text`'s text.
        pub fn text(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        /// `.files_chosen`'s paths, one at a time.
        pub fn paths(self: *const Self) std.mem.TokenIterator(u8, .scalar) {
            return std.mem.tokenizeScalar(u8, self.bytes[0..self.len], 0);
        }
    };
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

fn isServiceReply(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "capacity") and @TypeOf(T.capacity) == u32 and T == ServiceReply(T.capacity);
}

/// Where a host publishes each answer, never from two threads at once:
/// usually a source in the application's `Sources`, so answers reach
/// declaration, relay and replay as deliveries do.
///
/// ```zig
/// try services.file_dialogs.show(app.host, .main, open_theme, .{ .filters = &.{themes} }, .of(&app.sources.replies));
/// ```
pub const ServiceSink = struct {
    /// The source's own pointer, passed back to `publishFn`.
    context: *anyopaque,
    publishFn: *const fn (*anyopaque, *const ServiceAnswer) Wake,

    pub fn publish(self: ServiceSink, answer: *const ServiceAnswer) Wake {
        return self.publishFn(self.context, answer);
    }

    /// A sink into any source whose `publish` takes a `zui.ServiceReply(n)`
    /// and returns `zui.Wake` or `error{Full}!zui.Wake`. An answer a full
    /// source refuses is the source's to count.
    pub fn of(source: anytype) ServiceSink {
        const Source = @typeInfo(@TypeOf(source)).pointer.child;
        const Reply = @typeInfo(@TypeOf(Source.publish)).@"fn".params[1].type.?;
        if (comptime !isServiceReply(Reply)) @compileError("zui: zui.ServiceSink.of needs a source whose publish takes a zui.ServiceReply(n), found " ++ @typeName(Reply));
        const adapter = struct {
            fn publish(context: *anyopaque, answer: *const ServiceAnswer) Wake {
                const target: *Source = @ptrCast(@alignCast(context));
                const published = target.publish(Reply.of(answer));
                return if (@typeInfo(@TypeOf(published)) == .error_union) published catch .already_pending else published;
            }
        };
        return .{ .context = source, .publishFn = adapter.publish };
    }
};

pub const Notification = struct {
    /// UTF-8. What does not fit the system's notification is cut at a character.
    title: []const u8,
    body: []const u8 = "",
};

pub const FileDialog = struct {
    kind: Kind = .open_file,
    title: []const u8 = "",
    /// Where it opens; empty for the system's choice.
    directory: []const u8 = "",
    /// The name a save dialog suggests.
    file_name: []const u8 = "",
    filters: []const FileFilter = &.{},

    pub const Kind = enum { open_file, open_files, save_file, choose_folder };
};

pub const FileFilter = struct {
    /// "Themes"
    name: []const u8,
    /// Without the dot: `&.{ "zon", "json" }`.
    extensions: []const []const u8,
};

/// The application's number for a menu item, given back when it is chosen.
pub const MenuItemId = enum(u32) { _ };

pub const MenuItem = struct {
    /// Ignored for a separator and for an item with a submenu.
    id: MenuItemId = @enumFromInt(0),
    /// UTF-8; empty for a separator.
    label: []const u8 = "",
    /// Opens beside it instead of being chosen.
    submenu: []const MenuItem = &.{},
    enabled: bool = true,
    /// Null for an item that is not checkable.
    checked: ?bool = null,
    /// Shown beside the label; the application still handles the keys.
    shortcut: ?Chord = null,

    pub const separator: MenuItem = .{};
};

/// Whether `url` names a scheme a URL opener may hand to the system: two
/// letters or more, so a drive letter is not one, and not `file`, whose
/// handler opens and so runs what it names.
///
/// ```zig
/// if (!zui.isOpenableUrl(url)) return error.InvalidUrl;
/// ```
pub fn isOpenableUrl(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    const scheme = url[0..colon];
    if (scheme.len < 2 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-' or byte == '.')) return false;
    }
    return !std.ascii.eqlIgnoreCase(scheme, "file");
}

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

/// Reports what the test queues as the OS's events, waits on an `Io.Event`
/// for the real awake clock, and keeps the requests it was asked to apply.
const TestHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initMany(&.{ .offscreen, .library });
    pub const zui_capabilities: zui.HostCapabilities = .{};

    io: std.Io,
    woken: std.Io.Event = .unset,
    queued: [16]zui.Event = undefined,
    queued_count: usize = 0,
    queued_text: []const u8 = "",
    window_open: bool = true,
    applied: zui.HostRequests = .{},
    file_sink: ?zui.FileChangeSink = null,

    /// An `.on_event` wait gives up after this long, so a lost wake fails a
    /// test instead of hanging it.
    const longest_wait_ns = 5 * std.time.ns_per_s;
    const surface_size: [2]u32 = .{ 1600, 1200 };

    pub fn zuiPoll(self: *TestHost, window: zui.WindowId, record: *zui.RecordBuilder) bool {
        std.debug.assert(window == .main);
        if (!self.window_open) return false;
        record.begin(.{ .now = self.now(), .viewport = .{ 800, 600 }, .scale = 2 });
        for (self.queued[0..self.queued_count]) |event| record.append(event);
        if (self.queued_text.len != 0) record.appendText(self.queued_text);
        self.queued_count = 0;
        self.queued_text = "";
        return true;
    }

    pub fn zuiWaker(self: *TestHost) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }

    /// Resets the flag after waiting, never before: a wake that arrives
    /// between `nextFrame` and the wait must end it, and one that arrives
    /// after the reset is for a publish the next swap will see anyway.
    pub fn zuiWait(self: *TestHost, next: zui.NextFrame) void {
        const deadline: zui.Instant = switch (next) {
            .immediately => self.now(),
            .at => |instant| instant,
            .on_event => self.now().addNanoseconds(longest_wait_ns),
        };
        const awake_deadline: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = deadline.nanoseconds }, .clock = .awake };
        while (!self.woken.isSet() and self.now().isBefore(deadline)) {
            self.woken.waitTimeout(self.io, .{ .deadline = awake_deadline }) catch {};
        }
        self.woken.reset();
    }

    pub fn zuiSurface(_: *TestHost, window: zui.WindowId) zui.Surface {
        std.debug.assert(window == .main);
        return .{ .offscreen = .{ .size = surface_size } };
    }

    pub fn zuiApply(self: *TestHost, window: zui.WindowId, requests: zui.HostRequests) void {
        std.debug.assert(window == .main);
        self.applied = requests;
    }

    fn wake(context: *anyopaque) void {
        const self: *TestHost = @ptrCast(@alignCast(context));
        self.woken.set(self.io);
    }

    /// Watches one directory, named "themes"; the test reports its changes
    /// as the OS would, with `fileChanged`.
    pub const zuiFileWatch = struct {
        pub fn watch(host: *TestHost, directory: []const u8, sink: zui.FileChangeSink) zui.FileWatchError!void {
            if (host.file_sink != null) return error.TooManyWatches;
            if (!std.mem.eql(u8, directory, "themes")) return error.DirectoryUnavailable;
            host.file_sink = sink;
        }
    };

    fn fileChanged(self: *TestHost, change: zui.FileChange) void {
        self.zuiWaker().wakeIf(self.file_sink.?.publish(change));
    }

    fn queue(self: *TestHost, event: zui.Event) void {
        self.queued[self.queued_count] = event;
        self.queued_count += 1;
    }

    fn now(self: *const TestHost) zui.Instant {
        return .fromTimestamp(std.Io.Timestamp.now(self.io, .awake));
    }
};

const OffscreenRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    rectangles: u32 = 0,
    surface_size: [2]u32 = .{ 0, 0 },

    pub fn zuiSubmit(self: *OffscreenRenderer, surface: zui.Surface, frame: anytype) !void {
        if (surface != .offscreen) return error.UnsupportedSurface;
        self.surface_size = surface.offscreen.size;
        for (frame.commands()) |command| {
            if (command.payload == .rectangle) self.rectangles += 1;
        }
    }
};

comptime {
    zui.checkHostAndRenderer(TestHost, OffscreenRenderer);
}

test "the loop runs on a host: its record in, its surface drawn, its requests applied" {
    var text_contract: support.FixedMetricsText = .{};
    var ui = try support.Ui.init(testing.allocator, testing.io, &text_contract);
    defer ui.deinit(testing.allocator);
    var host: TestHost = .{ .io = testing.io };
    var renderer: OffscreenRenderer = .{};
    var event_buffer: [8]zui.Event = undefined;
    var text_buffer: [16]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&event_buffer, &text_buffer);
    builder.params.zoom = 1.5;

    const save: zui.Id = .of("save");
    var clicks: u32 = 0;
    var typed: [16]u8 = undefined;
    var typed_len: usize = 0;
    var frames: u32 = 0;
    while (host.zuiPoll(.main, &builder)) : (frames += 1) {
        ui.beginFrame(&builder.record());
        if (ui.clicked(save)) clicks += 1;
        const text = ui.typedText();
        @memcpy(typed[typed_len..][0..text.len], text);
        typed_len += text.len;
        ui.box(.{ .id = save, .interactive = true, .cursor = .pointer, .decoration = .{ .background = .black }, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
        const frame = ui.endFrame();
        try testing.expectEqual(@as(f32, 2), frame.params.scale);
        try testing.expectEqual(@as(f32, 1.5), frame.params.zoom);
        try renderer.zuiSubmit(host.zuiSurface(.main), frame);
        host.zuiApply(.main, frame.requests());
        ui.release(frame);

        switch (frames) {
            0 => {
                const pointer: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 10, 10 }, .at = builder.params.now };
                host.queue(.{ .pointer_move = .{ .pointer = pointer } });
                host.queue(.{ .pointer_down = .{ .pointer = pointer } });
                host.queue(.{ .pointer_up = .{ .pointer = pointer } });
                host.queued_text = "ok";
                host.zuiWaker().wake();
            },
            1 => host.window_open = false,
            else => unreachable,
        }
        host.zuiWait(ui.nextFrame());
    }

    try testing.expectEqual(@as(u32, 2), frames);
    try testing.expectEqual(@as(u32, 1), clicks);
    try testing.expectEqualStrings("ok", typed[0..typed_len]);
    try testing.expectEqual(zui.Cursor.pointer, host.applied.cursor);
    try testing.expectEqual(@as(u32, 2), renderer.rectangles);
    try testing.expectEqual(TestHost.surface_size, renderer.surface_size);
}

/// Keeps up to two changes, refusing the rest, and reports `.needed` only
/// for the first change since `take`.
const TwoFileChanges = struct {
    changes: [2]zui.FileChange = undefined,
    len: usize = 0,
    refused: u32 = 0,

    pub fn publish(self: *TwoFileChanges, change: zui.FileChange) error{Full}!zui.Wake {
        if (self.len == self.changes.len) {
            self.refused += 1;
            return error.Full;
        }
        self.changes[self.len] = change;
        self.len += 1;
        return if (self.len == 1) .needed else .already_pending;
    }

    fn take(self: *TwoFileChanges) []const zui.FileChange {
        defer self.len = 0;
        return self.changes[0..self.len];
    }
};

test "a host's file watch publishes each change into a source, waking the host for the first" {
    var host: TestHost = .{ .io = testing.io };
    var changes: TwoFileChanges = .{};
    try testing.expectError(error.DirectoryUnavailable, TestHost.zuiFileWatch.watch(&host, "assets", .of(&changes)));
    try TestHost.zuiFileWatch.watch(&host, "themes", .of(&changes));
    try testing.expectError(error.TooManyWatches, TestHost.zuiFileWatch.watch(&host, "themes", .of(&changes)));

    host.fileChanged(.of(.modified, "dark/theme.zon"));
    try testing.expect(host.woken.isSet());
    host.woken.reset();
    host.fileChanged(.of(.renamed_to, "light.zon"));
    host.fileChanged(.of(.added, "refused.zon"));
    try testing.expect(!host.woken.isSet());
    try testing.expectEqual(@as(u32, 1), changes.refused);

    const taken = changes.take();
    try testing.expectEqual(@as(usize, 2), taken.len);
    try testing.expectEqual(zui.FileChange.Kind.modified, taken[0].kind);
    try testing.expectEqualStrings("dark/theme.zon", taken[0].pathBytes());
    try testing.expectEqualStrings("light.zon", taken[1].pathBytes());
}

test "a file change whose path does not fit asks for a rescan rather than naming another file" {
    const longest = "p" ** zui.FileChange.Path.capacity;
    try testing.expectEqualStrings(longest, zui.FileChange.of(.added, longest).pathBytes());
    const too_long = zui.FileChange.of(.added, longest ++ "q");
    try testing.expectEqual(zui.FileChange.Kind.rescan, too_long.kind);
    try testing.expectEqualStrings("", too_long.pathBytes());
}

test "a record builder keeps events in order and drops the newest that do not fit" {
    var event_buffer: [2]zui.Event = undefined;
    var text_buffer: [4]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&event_buffer, &text_buffer);
    builder.params.zoom = 2;
    builder.begin(.{ .now = .fromNanoseconds(7), .viewport = .{ 320, 240 }, .scale = 1.25 });
    builder.append(.{ .pointer_leave = .mouse });
    builder.append(.{ .pointer_cancel = .mouse });
    builder.append(.{ .pointer_leave = @enumFromInt(1) });
    builder.appendText("lost");

    const record = builder.record();
    try testing.expectEqual(@as(usize, 2), record.events.len);
    try testing.expectEqual(zui.PointerId.mouse, record.events[0].pointer_leave);
    try testing.expectEqual(zui.PointerId.mouse, record.events[1].pointer_cancel);
    try testing.expectEqual(@as(u32, 2), builder.dropped_events);
    try testing.expectEqual(@as(u32, 4), builder.dropped_text_bytes);
    try testing.expectEqual(zui.FrameParams{ .now = .fromNanoseconds(7), .viewport = .{ 320, 240 }, .scale = 1.25, .zoom = 2 }, record.params);

    builder.begin(.{ .now = .fromNanoseconds(8), .viewport = .{ 320, 240 } });
    try testing.expectEqual(@as(usize, 0), builder.events().len);
    try testing.expectEqual(@as(u32, 0), builder.dropped_events);
    try testing.expectEqual(@as(f32, 2), builder.params.zoom);
}

test "a record builder copies text, and cuts what does not fit at a character boundary" {
    var event_buffer: [4]zui.Event = undefined;
    var text_buffer: [6]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&event_buffer, &text_buffer);
    builder.begin(.{ .now = .zero, .viewport = .{ 100, 100 } });

    var host_text = "ab".*;
    builder.appendText(&host_text);
    host_text = "xx".*;
    builder.appendText("cé€");

    const events = builder.events();
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqualStrings("ab", events[0].text);
    try testing.expectEqualStrings("cé", events[1].text);
    try testing.expectEqual(@as(u32, 3), builder.dropped_text_bytes);
    try testing.expectEqual(@as(u32, 0), builder.dropped_events);
}

test "a record builder copies dropped paths, and drops whole the paths that do not fit" {
    var event_buffer: [4]zui.Event = undefined;
    var text_buffer: [16]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&event_buffer, &text_buffer);
    builder.begin(.{ .now = .zero, .viewport = .{ 100, 100 } });

    var host_paths = "C:\\a\x00C:\\long\\b\x00".*;
    builder.appendFilesDropped(.{ .position = .{ 5, 6 }, .path_list = &host_paths, .at = .fromNanoseconds(3) });
    host_paths = @splat('x');
    builder.appendFilesDropped(.{ .position = .{ 7, 8 }, .path_list = "too long a path\x00", .at = .zero });

    const events = builder.events();
    try testing.expectEqual(@as(usize, 1), events.len);
    const drop = events[0].files_dropped;
    try testing.expectEqual([2]f32{ 5, 6 }, drop.position);
    var paths = drop.paths();
    try testing.expectEqualStrings("C:\\a", paths.next().?);
    try testing.expectEqualStrings("C:\\long\\b", paths.next().?);
    try testing.expectEqual(@as(?[]const u8, null), paths.next());
    try testing.expectEqual(@as(u32, 16), builder.dropped_text_bytes);
}

test "a record builder makes the record of a context with sources" {
    const Deliveries = struct { count: ?u32 = null };
    var event_buffer: [1]zui.Event = undefined;
    var builder: zui.RecordBuilder = .init(&event_buffer, &.{});
    builder.begin(.{ .now = .fromNanoseconds(3), .viewport = .{ 10, 10 } });
    builder.append(.{ .pointer_leave = .mouse });
    const record = builder.recordWith(Deliveries);
    try testing.expectEqual(zui.FrameRecordWith(Deliveries), @TypeOf(record));
    try testing.expectEqual(@as(usize, 1), record.events.len);
    try testing.expectEqual(@as(?*const Deliveries, null), record.deliveries);
}

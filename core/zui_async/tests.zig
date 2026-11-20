const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_async = @import("zui_async.zig");

const testing = std.testing;

const WakeCounter = struct {
    wakes: std.atomic.Value(u32) = .init(0),

    fn wake(context: *anyopaque) void {
        const counter: *WakeCounter = @ptrCast(@alignCast(context));
        _ = counter.wakes.fetchAdd(1, .monotonic);
    }

    fn waker(counter: *WakeCounter) zui.Waker {
        return .{ .context = counter, .wakeFn = wake };
    }

    fn count(counter: *const WakeCounter) u32 {
        return counter.wakes.load(.monotonic);
    }
};

fn endFrame(source: anytype, frame_number: u64) void {
    source.zuiEndFrame(.{ .frame_number = frame_number, .frames_in_flight = 2 });
}

fn singleThreadedIo() std.Io {
    const instance = struct {
        var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return instance.threaded.io();
}

const conformance_ios = [_]struct { name: []const u8, io: *const fn () std.Io }{
    .{ .name = "threads", .io = threadedIo },
    .{ .name = "single-threaded", .io = singleThreadedIo },
};

fn threadedIo() std.Io {
    return testing.io;
}

const LatestHarness = struct {
    const Source = zui_async.Latest(u64);
    pub const order: zui_testing.SourceOrder = .newest_only;
    pub const single_producer = true;

    pub fn publish(_: *LatestHarness, source: *Source, item: u64, _: bool, waker: zui.Waker) error{Full}!void {
        waker.wakeIf(source.publish(item));
    }

    pub fn delivered(_: *LatestHarness, delivery: *const Source.Delivery, items: []u64) []u64 {
        const value = delivery.* orelse return items[0..0];
        items[0] = value;
        return items[0..1];
    }

    pub fn expectViewShows(_: *LatestHarness, view: Source.View, delivery: *const Source.Delivery) !void {
        try testing.expectEqual(delivery.* != null, view.changed());
        if (delivery.*) |value| try testing.expectEqual(value, view.get().?);
    }
};

fn StreamHarness(comptime producers: zui_async.Producers) type {
    return struct {
        const Self = @This();
        const Source = zui_async.Stream(u64, .{ .capacity = 64, .producers = producers });
        pub const order: zui_testing.SourceOrder = .every_item;
        pub const single_producer = producers == .one;

        pub fn publish(_: *Self, source: *Source, item: u64, _: bool, waker: zui.Waker) error{Full}!void {
            waker.wakeIf(try source.publish(item));
        }

        pub fn delivered(_: *Self, delivery: *const Source.Delivery, items: []u64) []u64 {
            @memcpy(items[0..delivery.len], delivery.slice());
            return items[0..delivery.len];
        }

        pub fn expectViewShows(_: *Self, view: Source.View, delivery: *const Source.Delivery) !void {
            try testing.expectEqual(@as(usize, delivery.len), view.count());
            var items = view.items();
            for (delivery.slice()) |expected| try testing.expectEqual(expected, items.next().?.*);
            try testing.expectEqual(null, items.next());
        }
    };
}

/// Progress and results are the item plus one, so the zero progress that
/// `begin` publishes is not mistaken for the first item.
const TaskHarness = struct {
    const Source = zui_async.Task(u64, .{ .Progress = u64 });
    pub const order: zui_testing.SourceOrder = .newest_only;
    pub const single_producer = true;

    run: ?Source.Run = null,

    pub fn prepare(harness: *TaskHarness, source: *Source, waker: zui.Waker, _: zui_testing.SourceConformance) void {
        harness.run = source.begin(waker) catch unreachable;
    }

    pub fn publish(harness: *TaskHarness, _: *Source, item: u64, last: bool, _: zui.Waker) error{Full}!void {
        if (last) harness.run.?.finish(item + 1) else harness.run.?.progress(item + 1);
    }

    pub fn delivered(_: *TaskHarness, delivery: *const Source.Delivery, items: []u64) []u64 {
        const shifted = switch (delivery.* orelse return items[0..0]) {
            .running => |progress| progress,
            .ready => |value| value,
            .idle, .canceled => 0,
        };
        if (shifted == 0) return items[0..0];
        items[0] = shifted - 1;
        return items[0..1];
    }

    pub fn expectViewShows(_: *TaskHarness, view: Source.View, delivery: *const Source.Delivery) !void {
        if (delivery.*) |status| try testing.expectEqual(status, view.status());
    }
};

const KeyedHarness = struct {
    const capacity = 256;
    const Source = zui_async.KeyedLoads(u64, u64, .{ .capacity = capacity });
    pub const order: zui_testing.SourceOrder = .every_item;

    loads: [capacity]Source.Load = undefined,
    producers: u32 = 0,
    items_per_producer: u32 = 0,

    fn keyAt(harness: *const KeyedHarness, index: usize) u64 {
        return zui_testing.sourceItem(@intCast(index / harness.items_per_producer), @intCast(index % harness.items_per_producer));
    }

    pub fn prepare(harness: *KeyedHarness, source: *Source, waker: zui.Waker, conformance: zui_testing.SourceConformance) void {
        harness.producers = conformance.producers;
        harness.items_per_producer = conformance.items_per_producer;
        harness.declare(source.zuiView());
        var to_start = source.toStart(waker);
        while (to_start.next()) |load| {
            const producer: usize = @intCast(load.key >> 32);
            const sequence: usize = @as(u32, @truncate(load.key));
            harness.loads[producer * harness.items_per_producer + sequence] = load;
        }
    }

    pub fn declare(harness: *KeyedHarness, view: Source.View) void {
        for (0..harness.producers * harness.items_per_producer) |index| _ = view.get(harness.keyAt(index));
    }

    pub fn publish(harness: *KeyedHarness, _: *Source, item: u64, _: bool, _: zui.Waker) error{Full}!void {
        const producer: usize = @intCast(item >> 32);
        const sequence: usize = @as(u32, @truncate(item));
        harness.loads[producer * harness.items_per_producer + sequence].finish(item);
    }

    pub fn delivered(_: *KeyedHarness, delivery: *const Source.Delivery, items: []u64) []u64 {
        for (delivery.slice(), items[0..delivery.len]) |completion, *item| item.* = completion.key;
        return items[0..delivery.len];
    }

    pub fn expectViewShows(_: *KeyedHarness, view: Source.View, delivery: *const Source.Delivery) !void {
        for (delivery.slice()) |completion| try testing.expectEqual(Source.Status{ .ready = completion.result }, view.get(completion.key));
    }
};

test "Latest conforms, with threads and on a single-threaded Io" {
    for (conformance_ios) |conformance_io| {
        var harness: LatestHarness = .{};
        try zui_testing.expectSourceConforms(LatestHarness.Source, &harness, .{ .io = conformance_io.io(), .items_per_producer = 20_000 });
    }
}

test "Stream conforms with one producer and with many, with threads and on a single-threaded Io" {
    for (conformance_ios) |conformance_io| {
        var one: StreamHarness(.one) = .{};
        try zui_testing.expectSourceConforms(StreamHarness(.one).Source, &one, .{ .io = conformance_io.io(), .items_per_producer = 20_000 });
        var many: StreamHarness(.many) = .{};
        try zui_testing.expectSourceConforms(StreamHarness(.many).Source, &many, .{ .io = conformance_io.io(), .producers = 4, .items_per_producer = 5_000 });
    }
}

test "Task conforms, with threads and on a single-threaded Io" {
    for (conformance_ios) |conformance_io| {
        var harness: TaskHarness = .{};
        try zui_testing.expectSourceConforms(TaskHarness.Source, &harness, .{ .io = conformance_io.io(), .items_per_producer = 20_000 });
    }
}

test "KeyedLoads conforms, with threads and on a single-threaded Io" {
    for (conformance_ios) |conformance_io| {
        var harness: KeyedHarness = .{};
        try zui_testing.expectSourceConforms(KeyedHarness.Source, &harness, .{ .io = conformance_io.io(), .producers = 4, .items_per_producer = KeyedHarness.capacity / 4 });
    }
}

test "Latest keeps the newest value, and only the publish that made it fresh asks for a wake" {
    var latest: zui_async.Latest(u32) = .{};
    try testing.expectEqual(null, latest.zuiView().get());
    try testing.expect(!latest.zuiPending());

    try testing.expectEqual(zui.Wake.needed, latest.publish(1));
    try testing.expectEqual(zui.Wake.already_pending, latest.publish(2));
    try testing.expect(latest.zuiPending());
    latest.zuiSwap();
    try testing.expectEqual(@as(?u32, 2), latest.zuiView().get());
    try testing.expect(latest.zuiView().changed());
    try testing.expect(!latest.zuiPending());

    latest.zuiSwap();
    try testing.expectEqual(@as(?u32, 2), latest.zuiView().get());
    try testing.expect(!latest.zuiView().changed());
    var delivery: zui_async.Latest(u32).Delivery = undefined;
    latest.zuiDelivery(&delivery);
    try testing.expectEqual(null, delivery);

    try testing.expectEqual(zui.Wake.needed, latest.publish(3));
    latest.zuiInject(&@as(?u32, 9));
    try testing.expectEqual(@as(?u32, 9), latest.zuiView().get());
    latest.zuiSwap();
    try testing.expectEqual(@as(u32, 3), latest.zuiView().getPtr().?.*);
}

test "a Stream delivers each item once, in order, across many trips around its ring" {
    var stream: zui_async.Stream(u32, .{ .capacity = 4 }) = .{};
    var next: u32 = 0;
    var expected: u32 = 0;
    for (0..50) |round| {
        for (0..round % 5) |_| {
            _ = stream.publish(next) catch break;
            next += 1;
        }
        stream.zuiSwap();
        var items = stream.zuiView().items();
        while (items.next()) |item| {
            try testing.expectEqual(expected, item.*);
            expected += 1;
        }
    }
    try testing.expect(expected > 50);
}

test "a full Stream refuses the newest item and reports it to the frame" {
    const QuoteSources = struct { quotes: zui_async.Stream(u32, .{ .capacity = 2 }) = .{} };
    const Ui = zui.Context(.{ .limits = .{ .max_elements = 8 }, .Sources = QuoteSources });
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    var sources: QuoteSources = .{};

    _ = try sources.quotes.publish(1);
    _ = try sources.quotes.publish(2);
    try testing.expectError(error.Full, sources.quotes.publish(3));
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 10, 10 } } }, &sources);
    try testing.expectEqual(@as(usize, 2), ui.source(.quotes).count());
    // The two items read this frame hold the ring until the next swap.
    try testing.expectError(error.Full, sources.quotes.publish(4));
    const frame = ui.endFrame();
    try testing.expectEqual(@as(u32, 1), frame.diagnostics.refused_publishes);
    try testing.expectEqualStrings("quotes", frame.diagnostics.first_refusing_source);
    ui.release(frame);
    try testing.expectEqual(zui.NextFrame.on_event, ui.nextFrame(&sources));

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 10, 10 } } }, &sources);
    try testing.expectEqual(@as(usize, 0), ui.source(.quotes).count());
    const next_frame = ui.endFrame();
    try testing.expectEqual(@as(u32, 1), next_frame.diagnostics.refused_publishes);
    ui.release(next_frame);
    _ = try sources.quotes.publish(5);
    try testing.expectEqual(zui.NextFrame.immediately, ui.nextFrame(&sources));
}

test "a Stream of file changes takes a host's file watch, and its frame reads each change" {
    const ThemeSources = struct { theme_files: zui_async.Stream(zui.FileChange, .{ .capacity = 2 }) = .{} };
    const Ui = zui.Context(.{ .limits = .{ .max_elements = 8 }, .Sources = ThemeSources });
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    var sources: ThemeSources = .{};
    const sink: zui.FileChangeSink = .of(&sources.theme_files);

    try testing.expectEqual(zui.Wake.needed, sink.publish(.of(.modified, "theme.zon")));
    try testing.expectEqual(zui.Wake.already_pending, sink.publish(.of(.renamed_to, "dark.zon")));
    try testing.expectEqual(zui.Wake.already_pending, sink.publish(.of(.added, "refused.zon")));
    try testing.expectEqual(zui.NextFrame.immediately, ui.nextFrame(&sources));

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 10, 10 } } }, &sources);
    var changes = ui.source(.theme_files).items();
    try testing.expectEqualStrings("theme.zon", changes.next().?.pathBytes());
    try testing.expectEqual(zui.FileChange.Kind.renamed_to, changes.next().?.kind);
    try testing.expectEqual(null, changes.next());
    const frame = ui.endFrame();
    try testing.expectEqual(@as(u32, 1), frame.diagnostics.refused_publishes);
    ui.release(frame);
}

const Catalog = struct { items: u32 };
const FetchError = error{ Offline, Canceled };
const CatalogTask = zui_async.Task(FetchError!*const Catalog, .{ .Progress = f32 });

test "a Task runs one at a time: begin, progress, finish, then clear once no frame in flight read it" {
    var counter: WakeCounter = .{};
    var task: CatalogTask = .{};
    try testing.expect(task.isIdle());
    try testing.expectEqual(CatalogTask.Status.idle, task.zuiView().status());

    const run = try task.begin(counter.waker());
    try testing.expectError(error.Busy, task.begin(counter.waker()));
    try testing.expect(!task.isIdle());
    task.zuiSwap();
    try testing.expectEqual(CatalogTask.Status{ .running = 0 }, task.zuiView().status());
    endFrame(&task, 0);

    run.progress(0.5);
    try testing.expectEqual(@as(u32, 1), counter.count());
    const catalog: Catalog = .{ .items = 3 };
    run.finish(&catalog);
    try testing.expectEqual(@as(u32, 1), counter.count());
    try testing.expectError(error.Busy, task.begin(counter.waker()));

    task.zuiSwap();
    try testing.expectEqual(CatalogTask.Status{ .ready = &catalog }, task.zuiView().status());
    try testing.expect(!task.isIdle());
    endFrame(&task, 1);
    try testing.expectEqual(null, task.clear());
    task.zuiSwap();
    endFrame(&task, 2);
    try testing.expectEqual(null, task.clear());
    task.zuiSwap();
    endFrame(&task, 3);
    try testing.expectEqual(CatalogTask.Status{ .ready = &catalog }, task.clear().?);
    try testing.expect(task.isIdle());
    try testing.expectEqual(CatalogTask.Status.idle, task.zuiView().status());
}

fn fetchCatalog(catalog: *const Catalog, fails: bool) FetchError!*const Catalog {
    return if (fails) error.Offline else catalog;
}

test "publishing finishes a run with what a plain function returns, and abandoning is the producer's to notice" {
    var counter: WakeCounter = .{};
    var task: CatalogTask = .{};
    const catalog: Catalog = .{ .items = 1 };

    var group: std.Io.Group = .init;
    const failing_run = try task.begin(counter.waker());
    group.async(testing.io, CatalogTask.publishing(fetchCatalog), .{ failing_run, .{ &catalog, true } });
    try group.await(testing.io);
    task.zuiSwap();
    try testing.expectEqual(CatalogTask.Status{ .failed = error.Offline }, task.zuiView().status());

    const abandoned_run = try task.begin(counter.waker());
    try testing.expect(!abandoned_run.abandoned());
    task.abandon();
    try testing.expect(abandoned_run.abandoned());
    abandoned_run.finish(error.Canceled);
    task.zuiSwap();
    try testing.expectEqual(CatalogTask.Status.canceled, task.zuiView().status());

    const run = try task.begin(counter.waker());
    try testing.expect(!run.abandoned());
    group.async(testing.io, CatalogTask.publishing(fetchCatalog), .{ run, .{ &catalog, false } });
    try group.await(testing.io);
    task.zuiSwap();
    try testing.expectEqual(CatalogTask.Status{ .ready = &catalog }, task.zuiView().status());
}

const Texture = struct { id: u32 };
const DecodeError = error{ Corrupt, Canceled };
const ThumbnailLoads = zui_async.KeyedLoads(u64, DecodeError!Texture, .{ .capacity = 4, .unread_frames_before_release = 3, .owns_resources = true, .Progress = f32 });

test "KeyedLoads: wanted, loading, ready, then released after going unread" {
    var counter: WakeCounter = .{};
    var loads: ThumbnailLoads = .{};
    var frame_number: u64 = 0;

    loads.zuiSwap();
    try testing.expectEqual(ThumbnailLoads.Status.idle, loads.zuiView().get(10));
    endFrame(&loads, frame_number);
    frame_number += 1;

    var to_start = loads.toStart(counter.waker());
    const load = to_start.next().?;
    try testing.expectEqual(@as(u64, 10), load.key);
    try testing.expectEqual(null, to_start.next());

    load.progress(0.25);
    loads.zuiSwap();
    try testing.expectEqual(ThumbnailLoads.Status{ .running = 0.25 }, loads.zuiView().get(10));
    endFrame(&loads, frame_number);
    frame_number += 1;

    load.finish(.{ .id = 77 });
    try testing.expect(loads.zuiPending());
    loads.zuiSwap();
    var delivery: ThumbnailLoads.Delivery = undefined;
    loads.zuiDelivery(&delivery);
    try testing.expectEqual(@as(usize, 1), delivery.slice().len);
    try testing.expectEqual(@as(u64, 10), delivery.slice()[0].key);
    try testing.expectEqual(ThumbnailLoads.Status{ .ready = .{ .id = 77 } }, loads.zuiView().get(10));
    endFrame(&loads, frame_number);
    frame_number += 1;

    var to_release = loads.toRelease();
    for (0..3) |_| {
        try testing.expectEqual(null, to_release.next());
        loads.zuiSwap();
        endFrame(&loads, frame_number);
        frame_number += 1;
    }
    const released = to_release.next().?;
    try testing.expectEqual(@as(u32, 77), (try released).id);
    try testing.expectEqual(null, to_release.next());
    try testing.expectEqual(ThumbnailLoads.Status.idle, loads.zuiView().get(10));
}

test "KeyedLoads abandons a load whose key went unread, and hands its result back when it finishes" {
    var counter: WakeCounter = .{};
    var loads: ThumbnailLoads = .{};
    _ = loads.zuiView().get(1);
    var to_start = loads.toStart(counter.waker());
    const load = to_start.next().?;
    for (0..4) |frame_number| {
        loads.zuiSwap();
        endFrame(&loads, frame_number);
    }
    try testing.expect(load.abandoned());
    try testing.expectEqual(ThumbnailLoads.Status.idle, loads.zuiView().get(1));

    load.finish(error.Canceled);
    loads.zuiSwap();
    var delivery: ThumbnailLoads.Delivery = undefined;
    loads.zuiDelivery(&delivery);
    try testing.expectEqual(@as(usize, 0), delivery.slice().len);
    var to_release = loads.toRelease();
    try testing.expectError(error.Canceled, to_release.next().?);
    try testing.expectEqual(null, to_release.next());
}

test "a value is never released before frames_in_flight unread frames, whatever the option says" {
    const Eager = zui_async.KeyedLoads(u32, u32, .{ .capacity = 2, .unread_frames_before_release = 0 });
    var counter: WakeCounter = .{};
    var loads: Eager = .{};
    _ = loads.zuiView().get(5);
    var to_start = loads.toStart(counter.waker());
    to_start.next().?.finish(50);
    loads.zuiSwap();
    endFrame(&loads, 0);
    loads.zuiSwap();
    endFrame(&loads, 1);
    try testing.expectEqual(Eager.Status{ .ready = 50 }, loads.zuiView().get(5));
}

test "a full KeyedLoads refuses new keys, and a forgotten release shows as a full source" {
    const ThumbnailSources = struct { thumbnails: ThumbnailLoads = .{} };
    const Ui = zui.Context(.{ .limits = .{ .max_elements = 8 }, .Sources = ThumbnailSources });
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    var sources: ThumbnailSources = .{};

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 10, 10 } } }, &sources);
    for (0..5) |key| _ = ui.source(.thumbnails).get(key);
    ui.release(ui.endFrame());

    // A refusal in declaration is reported by the next frame's swap.
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 10, 10 } } }, &sources);
    const frame = ui.endFrame();
    try testing.expectEqual(@as(u32, 1), frame.diagnostics.refused_publishes);
    try testing.expectEqualStrings("thumbnails", frame.diagnostics.first_refusing_source);
    ui.release(frame);
}

test "100 loads finishing between two frames cause one wake" {
    const Loads = zui_async.KeyedLoads(u64, DecodeError!Texture, .{ .capacity = 128 });
    const Finisher = struct {
        fn finish(load: Loads.Load) void {
            load.finish(.{ .id = @intCast(load.key) });
        }
    };
    var counter: WakeCounter = .{};
    var loads: Loads = .{};
    for (0..100) |key| _ = loads.zuiView().get(key);
    loads.zuiSwap();
    endFrame(&loads, 0);

    var group: std.Io.Group = .init;
    var to_start = loads.toStart(counter.waker());
    var started: u32 = 0;
    while (to_start.next()) |load| : (started += 1) {
        group.concurrent(testing.io, Finisher.finish, .{load}) catch group.async(testing.io, Finisher.finish, .{load});
    }
    try group.await(testing.io);
    try testing.expectEqual(@as(u32, 100), started);
    try testing.expectEqual(@as(u32, 1), counter.count());

    loads.zuiSwap();
    var delivery: Loads.Delivery = undefined;
    loads.zuiDelivery(&delivery);
    try testing.expectEqual(@as(usize, 100), delivery.slice().len);
    for (0..100) |key| try testing.expectEqual(Loads.Status{ .ready = .{ .id = @intCast(key) } }, loads.zuiView().get(key));
}

const AppSources = struct {
    battery: zui_async.Latest(f32) = .{},
    quotes: zui_async.Stream(u32, .{ .capacity = 8, .producers = .many }) = .{},
    catalog: CatalogTask = .{},
    thumbnails: ThumbnailLoads = .{},
};
const AppUi = zui.Context(.{ .limits = .{ .max_elements = 32 }, .Sources = AppSources });

const App = struct {
    sources: AppSources = .{},
    battery: ?f32 = null,
    quote_total: u32 = 0,
    catalog_items: ?u32 = null,
    thumbnail: ThumbnailLoads.Status = .idle,

    fn declare(app: *App, ui: *AppUi) void {
        app.battery = ui.source(.battery).get();
        var quotes = ui.source(.quotes).items();
        while (quotes.next()) |quote| app.quote_total += quote.*;
        app.catalog_items = switch (ui.source(.catalog).status()) {
            .ready => |catalog| catalog.items,
            .idle, .running, .failed, .canceled => null,
        };
        app.thumbnail = ui.source(.thumbnails).get(42);
    }
};

test "the driver delivers to the default sources without threads" {
    var ui: AppUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    var app: App = .{};
    var driver: zui_testing.Driver(AppUi) = .{ .ui = &ui, .sources = &app.sources };

    _ = app.sources.battery.publish(0.5);
    _ = try app.sources.quotes.publish(4);
    _ = try driver.frame(&app, App.declare, &.{});
    try testing.expectEqual(@as(?f32, 0.5), app.battery);
    try testing.expectEqual(@as(u32, 4), app.quote_total);
    try testing.expectEqual(ThumbnailLoads.Status.idle, app.thumbnail);

    const catalog: Catalog = .{ .items = 12 };
    _ = try driver.frameDelivering(&app, App.declare, .{
        .catalog = .{ .ready = &catalog },
        .quotes = .init(&.{ 1, 2 }),
        .thumbnails = .init(&.{.{ .key = 42, .result = .{ .id = 9 } }}),
    });
    try testing.expectEqual(@as(?u32, 12), app.catalog_items);
    try testing.expectEqual(@as(u32, 7), app.quote_total);
    try testing.expectEqual(ThumbnailLoads.Status{ .ready = .{ .id = 9 } }, app.thumbnail);
    try testing.expectEqual(@as(?f32, 0.5), app.battery);
}

const TileLoads = zui_async.KeyedLoads(u64, DecodeError!u32, .{ .capacity = 16 });
const GallerySources = struct {
    battery: zui_async.Latest(f32) = .{},
    log: zui_async.Stream(u32, .{ .capacity = 8 }) = .{},
    tiles: TileLoads = .{},
};
const GalleryUi = zui.Context(.{ .limits = .{ .max_elements = 64, .max_render_commands = 128 }, .Sources = GallerySources });

/// A grid of tiles loaded by key, as the demo's thumbnail grid is: the
/// declaration asks, and the loader starts what it asked for.
const Gallery = struct {
    sources: GallerySources = .{},
    loads_started: u32 = 0,
    running: [16]TileLoads.Load = undefined,
    running_count: usize = 0,
    log_total: u32 = 0,

    fn declare(gallery: *Gallery, ui: *GalleryUi) void {
        const level = ui.source(.battery).get() orelse 1;
        var log = ui.source(.log).items();
        while (log.next()) |line| gallery.log_total += line.*;
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 2 } });
        ui.box(.{ .decoration = .{ .background = .rgb(0x00ff00) }, .layout = .{ .sizing = .{ .width = .fixed(100 * level), .height = .fixed(4) } } });
        for (0..12) |tile| {
            const color: zui.Color = switch (ui.source(.tiles).get(tile)) {
                .idle => .rgb(0x404040),
                .running => .rgb(0x808080),
                .ready => |texture| .{ .r = @intCast(texture % 256), .g = 0, .b = 0 },
                .failed, .canceled => .rgb(0xff0000),
            };
            ui.box(.{ .id = .indexed("tile", @intCast(tile)), .decoration = .{ .background = color }, .layout = .{ .sizing = .{ .width = .fixed(20), .height = .fixed(@floatFromInt(4 + gallery.log_total % 7)) } } });
        }
        ui.close();
    }

    /// Each load finishes at the loader's next call, so frames between
    /// see it running.
    fn load(gallery: *Gallery, waker: zui.Waker) void {
        for (gallery.running[0..gallery.running_count]) |tile| tile.finish(if (tile.key == 7) error.Corrupt else @intCast(tile.key * 10));
        gallery.running_count = 0;
        var to_start = gallery.sources.tiles.toStart(waker);
        while (to_start.next()) |tile| {
            gallery.loads_started += 1;
            gallery.running[gallery.running_count] = tile;
            gallery.running_count += 1;
        }
    }
};

test "a recorded gallery session replays to identical commands without starting any work" {
    var counter: WakeCounter = .{};
    var ui: GalleryUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    var gallery: Gallery = .{};
    var driver: zui_testing.Driver(GalleryUi) = .{ .ui = &ui, .sources = &gallery.sources };
    var recording: zui_testing.Recording(GalleryUi) = try .init(testing.allocator, .{ .records = 8 });
    defer recording.deinit(testing.allocator);
    ui.relayTo(recording.listener());

    var drawn: [8][128]GalleryUi.RenderCommand = undefined;
    var drawn_counts: [8]usize = undefined;
    for (&drawn, &drawn_counts, 0..) |*commands, *count, index| {
        if (index == 2) _ = gallery.sources.battery.publish(0.5);
        if (index % 3 == 1) _ = try gallery.sources.log.publish(@intCast(index));
        const frame = try driver.frame(&gallery, Gallery.declare, &.{});
        count.* = frame.commands().len;
        @memcpy(commands[0..count.*], frame.commands());
        gallery.load(counter.waker());
    }
    ui.relayTo(null);
    try testing.expectEqual(12, gallery.loads_started);
    try testing.expectEqual(0, recording.dropped);

    var replayed_ui: GalleryUi = try .init(testing.allocator, testing.io);
    defer replayed_ui.deinit(testing.allocator);
    var replayed: Gallery = .{};
    var replay_driver: zui_testing.Driver(GalleryUi) = .{ .ui = &replayed_ui, .sources = &replayed.sources };
    for (recording.records(), drawn, drawn_counts) |*record, commands, count| {
        const frame = try replay_driver.replay(&replayed, Gallery.declare, record);
        try testing.expectEqualSlices(GalleryUi.RenderCommand, commands[0..count], frame.commands());
    }
    try testing.expectEqual(0, replayed.loads_started);
    try testing.expectEqual(gallery.log_total, replayed.log_total);
}

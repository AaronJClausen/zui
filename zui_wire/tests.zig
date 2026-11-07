const std = @import("std");
const zui = @import("zui");
const zui_async = @import("zui_async");
const zui_testing = @import("zui_testing");
const zui_wire = @import("zui_wire.zig");

const testing = std.testing;

const Text = zui_testing.FixedMetricsText(u16);
const small_limits: zui.Limits = .{ .max_elements = 64, .max_text_bytes = 1024, .max_render_commands = 64, .measure_cache_entries = 64, .string_cache_entries = 64, .max_events_per_frame = 32 };

/// Writes into memory a test reads back.
const Stream = struct {
    out: std.Io.Writer.Allocating,

    fn init() Stream {
        return .{ .out = .init(testing.allocator) };
    }

    fn deinit(self: *Stream) void {
        self.out.deinit();
    }

    fn writer(self: *Stream) *std.Io.Writer {
        return &self.out.writer;
    }

    fn reader(self: *Stream) std.Io.Reader {
        return .fixed(self.out.written());
    }
};

fn at(milliseconds: u64) zui.Instant {
    return .fromNanoseconds(milliseconds * std.time.ns_per_ms);
}

const EventsUi = zui.Context(.{ .limits = small_limits, .Text = Text });

const pen: zui.Pointer = .{ .id = @enumFromInt(3), .kind = .pen, .position = .{ 12.5, -4 }, .at = at(7), .pressure = 0.25, .tilt = .{ 0.1, -0.2 } };
const every_event = [_]zui.Event{
    .{ .pointer_down = .{ .pointer = pen, .button = .secondary } },
    .{ .pointer_up = .{ .pointer = pen } },
    .{ .pointer_move = .{ .pointer = pen } },
    .{ .pointer_cancel = pen.id },
    .{ .pointer_leave = .mouse },
    .{ .wheel = .{ .position = .{ 1, 2 }, .delta = .{ 0, -120 }, .at = at(8) } },
    .{ .key_down = .{ .key = .z, .modifiers = .{ .control = true, .shift = true }, .repeat = true, .scancode = 0x2c, .at = at(9) } },
    .{ .key_up = .{ .key = .unidentified, .scancode = 0xe05b, .at = at(10) } },
    .{ .text = "héllo" },
    .{ .environment = .{ .theme = .dark } },
    .{ .environment = .{ .contrast = .high } },
    .{ .environment = .{ .reduced_motion = true } },
    .{ .environment = .{ .reduced_transparency = true } },
    .{ .environment = .{ .text_scale = 1.25 } },
    .{ .environment = .{ .locale = zui.Locale.parse("fr-CA") catch unreachable } },
    .{ .environment = .{ .direction = .right_to_left } },
    .{ .environment = .{ .hdr_headroom = 4 } },
    .{ .environment = .{ .power = .saver } },
    .{ .environment = .{ .window_focused = false } },
    .{ .environment = .{ .system_material = true } },
    .{ .files_dropped = .{ .position = .{ 30, 40 }, .path_list = "C:\\a.png\x00/b/c.txt\x00", .at = at(11) } },
    .{ .lifecycle = .terminate_requested },
};

test "every kind of event round-trips, with each record's parameters written as changes" {
    for (std.meta.tags(std.meta.Tag(zui.Event))) |kind| {
        for (every_event) |event| {
            if (std.meta.activeTag(event) == kind) break;
        } else return error.EventKindNotCovered;
    }
    for (std.meta.tags(std.meta.Tag(zui.EnvironmentChange))) |kind| {
        for (every_event) |event| {
            if (event == .environment and std.meta.activeTag(event.environment) == kind) break;
        } else return error.EnvironmentChangeNotCovered;
    }

    const records = [_]EventsUi.FrameRecord{
        .{ .params = .{ .now = at(16), .viewport = .{ 800, 600 }, .scale = 1.5, .zoom = 1.25 }, .events = &every_event },
        .{ .params = .{ .now = at(32), .viewport = .{ 800, 600 }, .scale = 1.5, .zoom = 1.25 } },
        .{ .params = .{ .now = at(48), .viewport = .{ 640, 480 }, .scale = 2, .zoom = 1 }, .events = every_event[8..9] },
        .{ .params = .{ .now = at(1), .viewport = .{ 640, 480 }, .scale = 2, .zoom = 1 } },
    };
    var stream: Stream = .init();
    defer stream.deinit();
    var encoder: zui_wire.Encoder(EventsUi) = try .init(testing.allocator);
    defer encoder.deinit(testing.allocator);
    try zui_wire.writeHeader(stream.writer(), null);
    var sizes: [records.len]usize = undefined;
    for (&records, &sizes) |*record, *size| {
        const before = stream.out.written().len;
        try encoder.writeRecord(stream.writer(), record);
        size.* = stream.out.written().len - before;
    }
    try testing.expect(sizes[1] <= 7);

    var reader = stream.reader();
    try zui_wire.readHeader(&reader, null);
    var decoder: zui_wire.Decoder(EventsUi) = try .init(testing.allocator, .of(EventsUi));
    defer decoder.deinit(testing.allocator);
    for (&records) |*record| {
        const message = (try decoder.next(&reader)).?;
        try testing.expectEqualDeep(record.*, message.record.*);
    }
    try testing.expectEqual(null, try decoder.next(&reader));
}

/// A catalog this process owns. The wire carries its number, and the
/// reading side finds its own copy by that number.
const Catalog = struct {
    number: u32,
    title: []const u8,

    var known = [_]Catalog{ .{ .number = 0, .title = "shoes" }, .{ .number = 1, .title = "hats" } };
};

const CatalogDelivery = struct {
    catalog: ?*const Catalog,

    pub fn zuiSerialize(self: *const CatalogDelivery, serializer: anytype) !void {
        try serializer.write(if (self.catalog) |catalog| catalog.number else null);
    }

    pub fn zuiDeserialize(deserializer: anytype) !CatalogDelivery {
        const number = try deserializer.read(?u32) orelse return .{ .catalog = null };
        if (number >= Catalog.known.len) return error.UnknownCatalog;
        return .{ .catalog = &Catalog.known[number] };
    }
};

const CatalogSource = struct {
    pub const Delivery = CatalogDelivery;
    pub const View = ?*const Catalog;

    received: Delivery = .{ .catalog = null },

    pub fn zuiSwap(_: *CatalogSource) void {}

    pub fn zuiView(self: *CatalogSource) View {
        return self.received.catalog;
    }

    pub fn zuiDelivery(self: *const CatalogSource, delivery: *Delivery) void {
        delivery.* = self.received;
    }

    pub fn zuiInject(self: *CatalogSource, delivery: *const Delivery) void {
        self.received = delivery.*;
    }
};

const LoadError = error{ NotFound, Canceled };

const DeliveringSources = struct {
    battery: zui_async.Latest(f32) = .{},
    log: zui_async.Stream(u32, .{ .capacity = 8 }) = .{},
    export_job: zui_async.Task(LoadError!u64, .{ .Progress = f32 }) = .{},
    thumbnails: zui_async.KeyedLoads(u64, LoadError!u32, .{ .capacity = 4 }) = .{},
    catalog: CatalogSource = .{},
};

const DeliveringUi = zui.Context(.{ .limits = small_limits, .Text = Text, .Sources = DeliveringSources });
const Thumbnails = @FieldType(DeliveringSources, "thumbnails");

test "every kind of delivery round-trips, and one holding a pointer sends what it declares" {
    const export_running: DeliveringUi.Deliveries = .{
        .battery = 0.75,
        .log = .init(&.{ 3, 1, 4 }),
        .export_job = .{ .running = 0.5 },
        .thumbnails = .init(&.{ .{ .key = 9, .result = 120 }, .{ .key = 10, .result = error.NotFound } }),
        .catalog = .{ .catalog = &Catalog.known[1] },
    };
    const export_finished: DeliveringUi.Deliveries = .{
        .battery = null,
        .log = .empty,
        .export_job = .{ .failed = error.NotFound },
        .thumbnails = .empty,
        .catalog = .{ .catalog = null },
    };
    const records = [_]DeliveringUi.FrameRecord{
        .{ .params = .{ .now = at(0), .viewport = .{ 100, 100 } }, .deliveries = &export_running },
        .{ .params = .{ .now = at(16), .viewport = .{ 100, 100 } }, .deliveries = &export_finished },
        .{ .params = .{ .now = at(32), .viewport = .{ 100, 100 } } },
    };
    var stream: Stream = .init();
    defer stream.deinit();
    var encoder: zui_wire.Encoder(DeliveringUi) = try .init(testing.allocator);
    defer encoder.deinit(testing.allocator);
    for (&records) |*record| try encoder.writeRecord(stream.writer(), record);

    var reader = stream.reader();
    var decoder: zui_wire.Decoder(DeliveringUi) = try .init(testing.allocator, .of(DeliveringUi));
    defer decoder.deinit(testing.allocator);
    for (&records) |*record| {
        const decoded = (try decoder.next(&reader)).?.record;
        try testing.expectEqualDeep(record.params, decoded.params);
        const sent = record.deliveries orelse {
            try testing.expectEqual(null, decoded.deliveries);
            continue;
        };
        const received = decoded.deliveries.?;
        try testing.expectEqual(sent.battery, received.battery);
        try testing.expectEqualSlices(u32, sent.log.slice(), received.log.slice());
        try testing.expectEqualDeep(sent.export_job, received.export_job);
        try testing.expectEqualDeep(sent.thumbnails.slice(), received.thumbnails.slice());
        try testing.expectEqual(sent.catalog.catalog, received.catalog.catalog);
    }
}

test "a delivery's own decoding error means the stream is malformed" {
    const unknown_catalog: Catalog = .{ .number = 7, .title = "gloves" };
    const deliveries: DeliveringUi.Deliveries = .{ .battery = null, .log = .empty, .export_job = null, .thumbnails = .empty, .catalog = .{ .catalog = &unknown_catalog } };
    var stream: Stream = .init();
    defer stream.deinit();
    var encoder: zui_wire.Encoder(DeliveringUi) = try .init(testing.allocator);
    defer encoder.deinit(testing.allocator);
    try encoder.writeRecord(stream.writer(), &.{ .params = .{ .now = at(0), .viewport = .{ 1, 1 } }, .deliveries = &deliveries });
    var reader = stream.reader();
    var decoder: zui_wire.Decoder(DeliveringUi) = try .init(testing.allocator, .of(DeliveringUi));
    defer decoder.deinit(testing.allocator);
    try testing.expectError(error.Malformed, decoder.next(&reader));
}

const EveryCommandUi = zui.Context(.{
    .limits = small_limits,
    .Text = Text,
    .ImageHandle = u32,
    .CustomData = struct { camera: [3]f32, layer: u8 },
    .MaterialHandle = enum(u8) { glass, frost },
    .commands = .initFull(),
});
const Command = EveryCommandUi.RenderCommand;

/// What an encoder reads of a frame, as a decoded frame provides it.
const ListedFrame = struct {
    number: u64,
    params: zui.FrameParams,
    host_requests: zui.HostRequests = .{},
    list: []const Command,

    pub fn commands(self: *const ListedFrame) []const Command {
        return self.list;
    }

    pub fn requests(self: *const ListedFrame) zui.HostRequests {
        return self.host_requests;
    }
};

const rounded: zui.CornerRadius = .all(4);
const text_style: EveryCommandUi.TextStyle = .{ .size = 14, .color = .white, .letter_spacing = 0.5 };
const every_command = [_]Command{
    .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 }, .id = 1, .payload = .{ .rectangle = .{ .color = .rgb(0x202020), .corner_radius = rounded } } },
    .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 }, .id = 1, .payload = .{ .clip_begin = .{ .x = 0, .y = 0, .width = 100, .height = 50 } } },
    .{ .bounds = .{ .x = 4, .y = 4, .width = 60, .height = 14 }, .id = 2, .payload = .{ .text = .{ .content = "first line", .style = text_style, .line = 0 } } },
    .{ .bounds = .{ .x = 4, .y = 18, .width = 60, .height = 14 }, .id = 2, .payload = .{ .text = .{ .content = "second", .style = text_style, .line = 1 } } },
    .{ .bounds = .{ .x = 70, .y = 4, .width = 20, .height = 20 }, .id = 3, .payload = .{ .image = .{ .handle = 42 } } },
    .{ .bounds = .{ .x = 0, .y = 30, .width = 50, .height = 20 }, .id = 4, .payload = .{ .custom = .{ .camera = .{ 1, 2, 3 }, .layer = 2 } } },
    .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 }, .id = 5, .z = 3, .payload = .{ .gradient = .{ .from = .black, .to = .white, .angle = 1.5, .corner_radius = rounded } } },
    .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 }, .id = 5, .z = 3, .payload = .{ .shadow = .{ .color = .rgba(0x00000080), .offset = .{ 0, 2 }, .blur = 8, .spread = 1 } } },
    .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 }, .id = 6, .z = -1, .payload = .{ .backdrop_blur = .{ .radius = 12, .tint = .rgba(0xffffff40) } } },
    .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 }, .id = 7, .payload = .{ .transform_begin = .{ .translation = .{ 5, 5 }, .scale = .{ 2, 2 }, .rotation = 0.3 } } },
    .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 }, .id = 7, .payload = .{ .material = .{ .handle = .frost, .fallback = .white } } },
    .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 }, .id = 7, .payload = .transform_end },
    .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 }, .id = 1, .payload = .clip_end },
    .{ .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 }, .id = 1, .payload = .{ .border = .{ .color = .black, .widths = .all(1), .corner_radius = rounded } } },
};

/// `every_command` after a frame of changes: scrolled, retitled, an
/// element added at the front and the image removed.
const changed_commands = changed: {
    var commands: [every_command.len]Command = every_command;
    commands[2].bounds.y -= 10;
    commands[2].payload.text.content = "first line, edited";
    commands[3].bounds.y -= 10;
    commands[6].z = 4;
    const added: Command = .{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .id = 99, .payload = .{ .rectangle = .{ .color = .white, .corner_radius = .zero } } };
    break :changed [_]Command{added} ++ commands[0..4] ++ commands[5..];
};

test "every kind of command round-trips, whole and as changes from the frame before" {
    for (std.meta.tags(std.meta.Tag(Command.Payload))) |kind| {
        for (every_command) |command| {
            if (std.meta.activeTag(command.payload) == kind) break;
        } else return error.CommandKindNotCovered;
    }

    const params: zui.FrameParams = .{ .now = at(16), .viewport = .{ 100, 50 }, .scale = 2 };
    const frames = [_]ListedFrame{
        .{ .number = 10, .params = params, .list = &every_command },
        .{ .number = 11, .params = params, .list = changed_commands, .host_requests = .{ .cursor = .text, .text_input = .{ .caret = .{ .x = 4, .y = 8, .width = 1, .height = 14 } } } },
        .{ .number = 12, .params = params, .list = changed_commands, .host_requests = .{ .cursor = .text, .text_input = .{ .caret = .{ .x = 4, .y = 8, .width = 1, .height = 14 } } } },
        .{ .number = 14, .params = .{ .now = at(48), .viewport = .{ 120, 50 }, .scale = 2 }, .list = &every_command },
        .{ .number = 15, .params = params, .list = &.{} },
        .{ .number = 3, .params = params, .list = every_command[0..3] },
    };
    var stream: Stream = .init();
    defer stream.deinit();
    var encoder: zui_wire.Encoder(EveryCommandUi) = try .init(testing.allocator);
    defer encoder.deinit(testing.allocator);
    var sizes: [frames.len]usize = undefined;
    for (&frames, &sizes) |*frame, *size| {
        const before = stream.out.written().len;
        try encoder.writeFrame(stream.writer(), frame);
        size.* = stream.out.written().len - before;
    }
    try testing.expect(sizes[1] < sizes[0] / 2);
    try testing.expect(sizes[2] <= 7);
    try testing.expect(sizes[3] < sizes[0] / 2);

    var reader = stream.reader();
    var decoder: zui_wire.Decoder(EveryCommandUi) = try .init(testing.allocator, .of(EveryCommandUi));
    defer decoder.deinit(testing.allocator);
    for (&frames) |*frame| {
        const decoded = (try decoder.next(&reader)).?.frame;
        try testing.expectEqual(frame.number, decoded.number);
        try testing.expectEqualDeep(frame.params, decoded.params);
        try testing.expectEqualDeep(frame.requests(), decoded.requests());
        try testing.expectEqualDeep(frame.commands(), decoded.commands());
    }
}

test "a key frame lets a reader join a stream, and a change before any frame is malformed" {
    var stream: Stream = .init();
    defer stream.deinit();
    var encoder: zui_wire.Encoder(EveryCommandUi) = try .init(testing.allocator);
    defer encoder.deinit(testing.allocator);
    const params: zui.FrameParams = .{ .now = at(16), .viewport = .{ 100, 50 } };
    try encoder.writeFrame(stream.writer(), &ListedFrame{ .number = 0, .params = params, .list = &every_command });
    const joined_at = stream.out.written().len;
    try encoder.writeKeyFrame(stream.writer(), &ListedFrame{ .number = 1, .params = params, .list = changed_commands });
    try encoder.writeFrame(stream.writer(), &ListedFrame{ .number = 2, .params = params, .list = &every_command });

    var decoder: zui_wire.Decoder(EveryCommandUi) = try .init(testing.allocator, .of(EveryCommandUi));
    defer decoder.deinit(testing.allocator);
    var joining: std.Io.Reader = .fixed(stream.out.written()[joined_at..]);
    try testing.expectEqualDeep(@as([]const Command, changed_commands), (try decoder.next(&joining)).?.frame.commands());
    try testing.expectEqualDeep(@as([]const Command, &every_command), (try decoder.next(&joining)).?.frame.commands());

    var late: zui_wire.Decoder(EveryCommandUi) = try .init(testing.allocator, .of(EveryCommandUi));
    defer late.deinit(testing.allocator);
    var after_key: std.Io.Reader = .fixed(stream.out.written()[joined_at..]);
    _ = try late.next(&after_key);
    var change_only: std.Io.Reader = .fixed(after_key.buffered());
    var fresh: zui_wire.Decoder(EveryCommandUi) = try .init(testing.allocator, .of(EveryCommandUi));
    defer fresh.deinit(testing.allocator);
    try testing.expectError(error.Malformed, fresh.next(&change_only));
}

test "a message beyond the decoder's capacity fails instead of overrunning it" {
    var stream: Stream = .init();
    defer stream.deinit();
    var encoder: zui_wire.Encoder(EveryCommandUi) = try .init(testing.allocator);
    defer encoder.deinit(testing.allocator);
    try encoder.writeFrame(stream.writer(), &ListedFrame{ .number = 0, .params = .{ .now = at(0), .viewport = .{ 1, 1 } }, .list = &every_command });
    try encoder.writeRecord(stream.writer(), &.{ .params = .{ .now = at(0), .viewport = .{ 1, 1 } }, .events = &every_event });

    var capacity: zui_wire.Capacity = .of(EveryCommandUi);
    capacity.commands = every_command.len - 1;
    capacity.events = every_event.len - 1;
    var decoder: zui_wire.Decoder(EveryCommandUi) = try .init(testing.allocator, capacity);
    defer decoder.deinit(testing.allocator);
    var reader = stream.reader();
    try testing.expectError(error.CapacityExceeded, decoder.next(&reader));

    var text_capacity: zui_wire.Capacity = .of(EveryCommandUi);
    text_capacity.frame_bytes = 8;
    var short_of_text: zui_wire.Decoder(EveryCommandUi) = try .init(testing.allocator, text_capacity);
    defer short_of_text.deinit(testing.allocator);
    reader = stream.reader();
    try testing.expectError(error.CapacityExceeded, short_of_text.next(&reader));

    var truncated: std.Io.Reader = .fixed(stream.out.written()[0 .. stream.out.written().len - 1]);
    var reading_truncated: zui_wire.Decoder(EveryCommandUi) = try .init(testing.allocator, .of(EveryCommandUi));
    defer reading_truncated.deinit(testing.allocator);
    _ = try reading_truncated.next(&truncated);
    try testing.expectError(error.EndOfStream, reading_truncated.next(&truncated));
}

const FingerprintedText = struct {
    fonts: u64,

    pub fn zuiMeasure(_: *FingerprintedText, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(run.len)) * key.size / 2, key.size };
    }

    pub fn zuiFingerprint(self: *const FingerprintedText) u64 {
        return self.fonts;
    }
};

test "a stream carries the fingerprint of its fonts, and a reader with other fonts rejects it" {
    const sender: FingerprintedText = .{ .fonts = 0xf0f0 };
    var stream: Stream = .init();
    defer stream.deinit();
    try zui_wire.writeHeader(stream.writer(), zui_wire.fingerprintOf(&sender));

    var same = stream.reader();
    try zui_wire.readHeader(&same, zui_wire.fingerprintOf(&FingerprintedText{ .fonts = 0xf0f0 }));
    var other = stream.reader();
    try testing.expectError(error.FontsDiffer, zui_wire.readHeader(&other, zui_wire.fingerprintOf(&FingerprintedText{ .fonts = 0xbeef })));
    var unknown = stream.reader();
    try zui_wire.readHeader(&unknown, zui_wire.fingerprintOf(&Text{}));
    try testing.expectEqual(null, zui_wire.fingerprintOf(&Text{}));

    var bytes: [32]u8 = undefined;
    @memcpy(bytes[0..stream.out.written().len], stream.out.written());
    bytes[4] +%= 1;
    var future: std.Io.Reader = .fixed(bytes[0..stream.out.written().len]);
    try testing.expectError(error.UnsupportedVersion, zui_wire.readHeader(&future, null));
    var not_wire: std.Io.Reader = .fixed("GIF89a....");
    try testing.expectError(error.NotAWireStream, zui_wire.readHeader(&not_wire, null));
}

const SessionUi = zui.Context(.{ .limits = small_limits, .Text = Text, .Sources = struct { battery: zui_async.Latest(f32) = .{} } });
const SessionSources = SessionUi.Sources;

/// Writes each record the context applies, as a relay listener.
const Recorder = struct {
    encoder: *zui_wire.Encoder(SessionUi),
    writer: *std.Io.Writer,
    failed: bool = false,

    fn keep(context: *anyopaque, record: *const SessionUi.FrameRecord) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.encoder.writeRecord(self.writer, record) catch {
            self.failed = true;
        };
    }
};

const list_id: zui.Id = .of("list");

fn declareSession(ui: *SessionUi) void {
    ui.open(.{ .id = .of("root"), .layout = .{ .sizing = .grow_both, .direction = .top_to_bottom, .padding = .all(4), .child_gap = 2 }, .decoration = .{ .background = .white } });
    if (ui.source(.battery).get()) |level| {
        var buffer: [32]u8 = undefined;
        ui.text(std.fmt.bufPrint(&buffer, "battery {d:.0}%", .{level * 100}) catch unreachable, .{});
    }
    ui.text(ui.typedText(), .{});
    ui.open(.{ .id = list_id, .scroll = .{}, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(60) }, .direction = .top_to_bottom } });
    for (0..12) |row| {
        const row_id: zui.Id = .indexed("row", @intCast(row));
        ui.open(.{ .id = row_id, .interactive = true, .decoration = .{ .background = if (ui.hovered(row_id)) .black else .rgb(0xdddddd) }, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(12) } } });
        ui.text("a row of the list", .{ .color = if (ui.hovered(row_id)) .white else .black });
        ui.close();
    }
    ui.close();
    ui.close();
}

test "a live session's records and frames decode to what was applied and drawn, and the records replay to the same commands" {
    var text: Text = .{};
    var ui: SessionUi = try .init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);
    var sources: SessionSources = .{};

    var records: Stream = .init();
    defer records.deinit();
    var frames: Stream = .init();
    defer frames.deinit();
    var record_encoder: zui_wire.Encoder(SessionUi) = try .init(testing.allocator);
    defer record_encoder.deinit(testing.allocator);
    var frame_encoder: zui_wire.Encoder(SessionUi) = try .init(testing.allocator);
    defer frame_encoder.deinit(testing.allocator);
    var recorder: Recorder = .{ .encoder = &record_encoder, .writer = records.writer() };
    ui.relayTo(.{ .context = &recorder, .relayFn = Recorder.keep });

    const mouse = struct {
        fn moveTo(position: [2]f32, frame: u64) zui.Event {
            return .{ .pointer_move = .{ .pointer = .{ .id = .mouse, .kind = .mouse, .position = position, .at = at(frame * 16) } } };
        }
    };
    const session = [_][]const zui.Event{
        &.{},
        &.{mouse.moveTo(.{ 20, 40 }, 1)},
        &.{ mouse.moveTo(.{ 20, 52 }, 2), .{ .text = "typed" } },
        &.{.{ .wheel = .{ .position = .{ 20, 52 }, .delta = .{ 0, 9 }, .at = at(48) } }},
        &.{},
        &.{.{ .environment = .{ .theme = .dark } }},
    };
    var frame_decoder: zui_wire.Decoder(SessionUi) = try .init(testing.allocator, .of(SessionUi));
    defer frame_decoder.deinit(testing.allocator);
    for (session, 0..) |events, index| {
        if (index == 3) _ = sources.battery.publish(0.5);
        ui.beginFrame(&.{ .params = .{ .now = at(index * 16), .viewport = .{ 200, 120 } }, .events = events }, &sources);
        declareSession(&ui);
        const frame = ui.endFrame();
        defer ui.release(frame);
        try testing.expect(frame.diagnostics.ok());
        const written = frames.out.written().len;
        try frame_encoder.writeFrame(frames.writer(), frame);
        var reader: std.Io.Reader = .fixed(frames.out.written()[written..]);
        const decoded = (try frame_decoder.next(&reader)).?.frame;
        try testing.expectEqualDeep(frame.commands(), decoded.commands());
        try testing.expectEqualDeep(frame.requests(), decoded.requests());
    }
    ui.relayTo(null);
    try testing.expect(!recorder.failed);

    var replayed: SessionUi = try .init(testing.allocator, testing.io, &text);
    defer replayed.deinit(testing.allocator);
    var replayed_sources: SessionSources = .{};
    var record_decoder: zui_wire.Decoder(SessionUi) = try .init(testing.allocator, .of(SessionUi));
    defer record_decoder.deinit(testing.allocator);
    var replayed_frame_decoder: zui_wire.Decoder(SessionUi) = try .init(testing.allocator, .of(SessionUi));
    defer replayed_frame_decoder.deinit(testing.allocator);
    var record_reader = records.reader();
    var frame_reader = frames.reader();
    for (session) |_| {
        const record = (try record_decoder.next(&record_reader)).?.record;
        try testing.expect(record.deliveries != null);
        replayed.beginFrame(record, &replayed_sources);
        declareSession(&replayed);
        const frame = replayed.endFrame();
        defer replayed.release(frame);
        try testing.expectEqualDeep((try replayed_frame_decoder.next(&frame_reader)).?.frame.commands(), frame.commands());
    }
    try testing.expectEqual(null, try record_decoder.next(&record_reader));
}

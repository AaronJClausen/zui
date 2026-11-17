const std = @import("std");
const zui = @import("zui");
const zui_wire = @import("zui_wire");

pub const FrameStream = @import("frame_stream.zig").FrameStream;
pub const DemoUi = @import("demo_ui.zig").DemoUi;
pub const DrawList = @import("draw_list.zig").DrawList;
pub const Text = @import("text.zig").Text;
pub const RecordStream = @import("record_stream.zig").RecordStream;
const browser_input = @import("browser_input.zig");

const testing = std.testing;

const SmallUi = zui.Context(.{
    .limits = .{ .max_elements = 16, .max_render_commands = 16, .max_text_bytes = 256 },
    .commands = .initMany(&.{.gradient}),
});
const Command = SmallUi.RenderCommand;

const ListedFrame = struct {
    number: u64,
    params: zui.FrameParams,
    list: []const Command,

    pub fn commands(self: *const ListedFrame) []const Command {
        return self.list;
    }

    pub fn requests(_: *const ListedFrame) zui.HostRequests {
        return .{ .cursor = .pointer };
    }
};

fn at(milliseconds: u64) zui.Instant {
    return .fromNanoseconds(milliseconds * std.time.ns_per_ms);
}

const panel = [_]Command{
    .{ .bounds = .{ .x = 0, .y = 0, .width = 200, .height = 100 }, .id = 1, .payload = .{ .rectangle = .{ .color = .rgb(0x202830), .corner_radius = .all(6) } } },
    .{ .bounds = .{ .x = 8, .y = 8, .width = 120, .height = 16 }, .id = 2, .payload = .{ .text = .{ .content = "Hello, browser", .style = .{ .size = 16, .color = .white }, .line = 0 } } },
    .{ .bounds = .{ .x = 0, .y = 60, .width = 200, .height = 40 }, .id = 3, .payload = .{ .gradient = .{ .from = .black, .to = .white, .angle = 0.5 } } },
};
const scrolled = scrolled: {
    var commands = panel;
    commands[1].bounds.y = 4;
    commands[1].payload.text.content = "Hello again";
    break :scrolled commands;
};
const frames = [_]ListedFrame{
    .{ .number = 1, .params = .{ .now = at(16), .viewport = .{ 200, 100 } }, .list = &panel },
    .{ .number = 2, .params = .{ .now = at(32), .viewport = .{ 200, 100 } }, .list = &scrolled },
    .{ .number = 4, .params = .{ .now = at(64), .viewport = .{ 240, 100 } }, .list = panel[0..2] },
};

/// A header and `frames`, the first whole and the rest as changes.
fn writeStream(out: *std.Io.Writer.Allocating, fingerprint: ?u64) !void {
    var encoder: zui_wire.Encoder(SmallUi) = try .init(testing.allocator);
    defer encoder.deinit(testing.allocator);
    try zui_wire.writeHeader(&out.writer, fingerprint);
    for (&frames) |*frame| try encoder.writeFrame(&out.writer, frame);
}

fn expectFrame(expected: *const ListedFrame, decoded: *const FrameStream(SmallUi).Frame) !void {
    try testing.expectEqual(expected.number, decoded.number);
    try testing.expectEqualDeep(expected.params, decoded.params);
    try testing.expectEqualDeep(expected.requests(), decoded.requests());
    try testing.expectEqualDeep(expected.commands(), decoded.commands());
}

test "a stream that arrives in pieces of any size decodes to every frame written" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeStream(&out, 0xf0f0);
    const written = out.written();

    for ([_]usize{ 1, 2, 3, 7, 64, written.len }) |piece_size| {
        var stream: FrameStream(SmallUi) = try .init(testing.allocator, .{ .max_pending_bytes = 512, .fingerprint = 0xf0f0 });
        defer stream.deinit(testing.allocator);
        var next_expected: usize = 0;
        var offset: usize = 0;
        while (offset < written.len) {
            const piece = written[offset..@min(written.len, offset + piece_size)];
            offset += piece.len;
            try stream.receive(piece);
            while (try stream.nextFrame()) |frame| {
                try expectFrame(&frames[next_expected], frame);
                next_expected += 1;
            }
        }
        try testing.expectEqual(frames.len, next_expected);
    }
}

test "a transport writes the stream in place" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeStream(&out, null);
    var stream: FrameStream(SmallUi) = try .init(testing.allocator, .{ .max_pending_bytes = 512 });
    defer stream.deinit(testing.allocator);
    const room = try stream.roomFor(out.written().len);
    @memcpy(room, out.written());
    stream.received(room.len);
    for (&frames) |*expected| try expectFrame(expected, (try stream.nextFrame()).?);
    try testing.expectEqual(null, try stream.nextFrame());
}

test "a stream measured with other fonts, or not a wire stream, is rejected" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeStream(&out, 0xf0f0);

    var other_fonts: FrameStream(SmallUi) = try .init(testing.allocator, .{ .max_pending_bytes = 512, .fingerprint = 0x0f0f });
    defer other_fonts.deinit(testing.allocator);
    try other_fonts.receive(out.written());
    try testing.expectError(error.FontsDiffer, other_fonts.nextFrame());

    var not_wire: FrameStream(SmallUi) = try .init(testing.allocator, .{ .max_pending_bytes = 512 });
    defer not_wire.deinit(testing.allocator);
    try not_wire.receive("GET / HTTP/1.1\r\n");
    try testing.expectError(error.NotAWireStream, not_wire.nextFrame());
}

test "a record in a stream of frames is rejected" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var encoder: zui_wire.Encoder(SmallUi) = try .init(testing.allocator);
    defer encoder.deinit(testing.allocator);
    try zui_wire.writeHeader(&out.writer, null);
    try encoder.writeRecord(&out.writer, &.{ .params = .{ .now = at(0), .viewport = .{ 1, 1 } } });

    var stream: FrameStream(SmallUi) = try .init(testing.allocator, .{ .max_pending_bytes = 512 });
    defer stream.deinit(testing.allocator);
    try stream.receive(out.written());
    try testing.expectError(error.UnexpectedRecord, stream.nextFrame());
}

test "a message larger than the bytes held fails instead of waiting forever" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeStream(&out, null);
    const header_bytes = 7;

    var stream: FrameStream(SmallUi) = try .init(testing.allocator, .{ .max_pending_bytes = header_bytes + 16 });
    defer stream.deinit(testing.allocator);
    try stream.receive(out.written()[0..stream.pending.len]);
    try testing.expectEqual(null, try stream.nextFrame());
    try stream.receive(out.written()[stream.pending.len..][0..header_bytes]);
    try testing.expectError(error.CapacityExceeded, stream.nextFrame());
    try testing.expectError(error.CapacityExceeded, stream.receive("more"));
}

test "the demo's context decodes a stream" {
    var stream: FrameStream(DemoUi) = try .init(testing.allocator, .{});
    defer stream.deinit(testing.allocator);
    try testing.expectEqual(null, try stream.nextFrame());
}

/// What a `zui_wire.Host` reads of the records a `RecordStream` sent.
const RecordReader = struct {
    decoder: zui_wire.Decoder(SmallUi),
    header_read: bool = false,

    fn init() !RecordReader {
        return .{ .decoder = try .init(testing.allocator, .of(SmallUi)) };
    }

    fn deinit(self: *RecordReader) void {
        self.decoder.deinit(testing.allocator);
    }

    fn read(self: *RecordReader, bytes: []const u8) !*const SmallUi.FrameRecord {
        var reader: std.Io.Reader = .fixed(bytes);
        if (!self.header_read) {
            try zui_wire.readHeader(&reader, null);
            self.header_read = true;
        }
        const message = (try self.decoder.next(&reader)).?;
        try testing.expectEqual(bytes.len, reader.seek);
        return message.record;
    }
};

test "a record goes back only with events, or when the canvas's size or scale changed" {
    var records: RecordStream(SmallUi) = try .init(testing.allocator, .{});
    defer records.deinit(testing.allocator);
    var reader: RecordReader = try .init();
    defer reader.deinit();

    records.measure(.{ 1280, 800 }, 1.5);
    const first = try reader.read((try records.take(at(10))).?);
    try testing.expectEqualDeep(zui.FrameParams{ .now = at(10), .viewport = .{ 1280, 800 }, .scale = 1.5 }, first.params);
    try testing.expectEqual(0, first.events.len);
    try testing.expectEqual(null, try records.take(at(26)));

    const mouse: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 40, 30 }, .at = at(30) };
    records.builder.append(.{ .pointer_down = .{ .pointer = mouse } });
    records.builder.appendText("é");
    const pressed = try reader.read((try records.take(at(42))).?);
    try testing.expectEqual(at(42), pressed.params.now);
    try testing.expectEqualDeep(&[_]zui.Event{ .{ .pointer_down = .{ .pointer = mouse } }, .{ .text = "é" } }, pressed.events);
    try testing.expectEqual(null, try records.take(at(58)));

    records.measure(.{ 1280, 800 }, 2);
    const rescaled = try reader.read((try records.take(at(74))).?);
    try testing.expectEqualDeep(zui.FrameParams{ .now = at(74), .viewport = .{ 1280, 800 }, .scale = 2 }, rescaled.params);
    records.measure(.{ 1024, 768 }, 2);
    const resized = try reader.read((try records.take(at(90))).?);
    try testing.expectEqualDeep([2]f32{ 1024, 768 }, resized.params.viewport);
    try testing.expectEqual(0, records.dropped_events);
}

/// A source of the kind the tour declares, which delivers values.
const Counter = struct {
    count: ?u32 = null,

    pub const Delivery = ?u32;
    pub const View = ?u32;

    pub fn zuiSwap(_: *Counter) void {}
    pub fn zuiView(self: *Counter) ?u32 {
        return self.count;
    }
    pub fn zuiDelivery(self: *const Counter, delivery: *?u32) void {
        delivery.* = self.count;
    }
    pub fn zuiInject(self: *Counter, delivery: *const ?u32) void {
        self.count = delivery.*;
    }
};

const CountingUi = zui.Context(.{ .Sources = struct { counter: Counter = .{} } });

test "the demo's records are read by an application with sources of its own" {
    var records: RecordStream(DemoUi) = try .init(testing.allocator, .{});
    defer records.deinit(testing.allocator);
    var decoder: zui_wire.Decoder(CountingUi) = try .init(testing.allocator, .of(CountingUi));
    defer decoder.deinit(testing.allocator);

    records.measure(.{ 640, 480 }, 1);
    records.builder.append(.{ .key_down = .{ .key = .tab, .at = at(4) } });
    var reader: std.Io.Reader = .fixed((try records.take(at(5))).?);
    try zui_wire.readHeader(&reader, null);
    const record = (try decoder.next(&reader)).?.record;
    try testing.expectEqual(reader.end, reader.seek);
    try testing.expectEqual(null, record.deliveries);
    try testing.expectEqualDeep(&[_]zui.Event{.{ .key_down = .{ .key = .tab, .at = at(4) } }}, record.events);
}

test "a record of every event the demo's records hold, each as large as it is written, fits" {
    var records: RecordStream(DemoUi) = try .init(testing.allocator, .{ .fingerprint = std.math.maxInt(u64) });
    defer records.deinit(testing.allocator);
    const farthest: zui.Instant = .fromNanoseconds(std.math.maxInt(u64));
    const widest: zui.Pointer = .{ .id = @enumFromInt(std.math.maxInt(u32)), .kind = .pen, .position = .{ -1e30, 1e30 }, .at = farthest, .pressure = 0.5, .tilt = .{ 1, -1 } };
    const largest = [_]zui.Event{
        .{ .pointer_down = .{ .pointer = widest, .button = .middle } },
        .{ .key_down = .{ .key = .unidentified, .modifiers = .{ .shift = true, .super = true }, .repeat = true, .scancode = std.math.maxInt(u32), .at = farthest } },
        .{ .environment = .{ .locale = comptime zui.Locale.parse("x" ** zui.Locale.capacity) catch unreachable } },
        .{ .wheel = .{ .position = .{ 1, 2 }, .delta = .{ 3, 4 }, .at = farthest } },
    };
    records.builder.appendText("x" ** DemoUi.limits.max_text_input_bytes);
    while (records.builder.event_count < records.builder.event_buffer.len) {
        records.builder.append(largest[records.builder.event_count % largest.len]);
    }
    records.measure(.{ 1e30, 1e30 }, 3);
    try testing.expect(try records.take(farthest) != null);
    try testing.expectEqual(0, records.dropped_events);
}

test "a browser's key is the one its name or its place on the keyboard means" {
    try testing.expectEqual(zui.Key.a, browser_input.logicalKey("a", "KeyA"));
    try testing.expectEqual(zui.Key.a, browser_input.logicalKey("A", "KeyA"));
    try testing.expectEqual(zui.Key.q, browser_input.logicalKey("q", "KeyA"));
    try testing.expectEqual(zui.Key.digit_1, browser_input.logicalKey("!", "Digit1"));
    try testing.expectEqual(zui.Key.digit_2, browser_input.logicalKey("é", "Digit2"));
    try testing.expectEqual(zui.Key.apostrophe, browser_input.logicalKey("Dead", "Quote"));
    try testing.expectEqual(zui.Key.page_down, browser_input.logicalKey("PageDown", "PageDown"));
    try testing.expectEqual(zui.Key.space, browser_input.logicalKey(" ", "Space"));
    try testing.expectEqual(zui.Key.super, browser_input.logicalKey("Meta", "MetaLeft"));
    try testing.expectEqual(zui.Key.unidentified, browser_input.logicalKey("AudioVolumeUp", "AudioVolumeUp"));
    try testing.expectEqual(0, browser_input.scancode(""));
    try testing.expect(browser_input.scancode("KeyA") != browser_input.scancode("KeyB"));
    try testing.expectEqual(zui.Modifiers{ .control = true, .super = true }, browser_input.modifiers(0b1010));
}

test "a browser's pointers, buttons and wheel are zui's" {
    try testing.expectEqual(zui.PointerId.mouse, browser_input.pointerId(.mouse, 1));
    try testing.expect(browser_input.pointerId(.touch, 0) != .mouse);
    try testing.expect(browser_input.pointerId(.pen, std.math.maxInt(u32)) != .mouse);
    try testing.expectEqual(zui.PointerKind.touch, browser_input.pointerKind(1));
    try testing.expectEqual(zui.Button.secondary, browser_input.button(2));
    try testing.expectEqual(null, browser_input.button(3));
    try testing.expectEqualDeep([2]f32{ 0, 40 }, browser_input.wheelDelta(.{ 0, 3 }, 1, .{ 800, 600 }));
    try testing.expectEqualDeep([2]f32{ -800, 600 }, browser_input.wheelDelta(.{ -1, 1 }, 2, .{ 800, 600 }));
    try testing.expectEqualDeep([2]f32{ 2.5, 120 }, browser_input.wheelDelta(.{ 2.5, 120 }, 0, .{ 800, 600 }));
}

test "every cursor has a CSS name of its own" {
    const cursors = std.enums.values(zui.Cursor);
    for (cursors, 0..) |cursor, index| {
        try testing.expect(browser_input.cursorName(cursor).len > 0);
        for (cursors[0..index]) |earlier| try testing.expect(!std.mem.eql(u8, browser_input.cursorName(earlier), browser_input.cursorName(cursor)));
    }
    try testing.expectEqualStrings("not-allowed", browser_input.cursorName(.not_allowed));
}

const DemoCommand = DemoUi.RenderCommand;
const demo_params: zui.FrameParams = .{ .now = .zero, .viewport = .{ 200, 100 }, .scale = 2 };

const LaidOut = struct {
    draw_list: DrawList,
    text: Text,

    fn deinit(self: *LaidOut) void {
        self.draw_list.deinit(testing.allocator);
        self.text.deinit(testing.allocator);
    }
};

fn layOutForTest(commands: []const DemoCommand) !LaidOut {
    var text: Text = try .init(testing.allocator);
    errdefer text.deinit(testing.allocator);
    var draw_list: DrawList = try .init(testing.allocator);
    draw_list.layOut(commands, demo_params, &text);
    return .{ .draw_list = draw_list, .text = text };
}

test "a vertex is the 56 bytes the page reads" {
    try testing.expectEqual(56, @sizeOf(DrawList.Vertex));
    try testing.expectEqual(8, @offsetOf(DrawList.Vertex, "color"));
    try testing.expectEqual(12, @offsetOf(DrawList.Vertex, "texture"));
    try testing.expectEqual(16, @offsetOf(DrawList.Vertex, "texture_coordinates"));
    try testing.expectEqual(24, @offsetOf(DrawList.Vertex, "texture_per_unit"));
    try testing.expectEqual(40, @offsetOf(DrawList.Vertex, "texture_bounds"));
}

test "a square rectangle is two triangles in its color, in one batch over the whole target" {
    var laid_out = try layOutForTest(&.{
        .{ .bounds = .{ .x = 10, .y = 20, .width = 30, .height = 40 }, .id = 1, .payload = .{ .rectangle = .{ .color = .rgb(0x336699), .corner_radius = .zero } } },
    });
    defer laid_out.deinit();
    const draw_list = &laid_out.draw_list;
    try testing.expectEqual(6, draw_list.vertices().len);
    try testing.expectEqualDeep([2]f32{ 40, 60 }, draw_list.vertices()[2].position);
    try testing.expectEqualDeep(zui.Color.rgb(0x336699), draw_list.vertices()[0].color);
    try testing.expectEqual(1, draw_list.batches().len);
    try testing.expectEqualDeep(DrawList.Scissor{ .x = 0, .y = 0, .width = 400, .height = 200 }, draw_list.batches()[0].scissor);
}

test "a clip starts a batch scissored in pixels from the bottom, and its end restores the one around it" {
    var laid_out = try layOutForTest(&.{
        .{ .bounds = .{ .width = 200, .height = 100 }, .id = 1, .payload = .{ .rectangle = .{ .color = .black, .corner_radius = .zero } } },
        .{ .bounds = .{}, .id = 2, .payload = .{ .clip_begin = .{ .x = 10.75, .y = 20, .width = 30, .height = 10 } } },
        .{ .bounds = .{ .width = 200, .height = 100 }, .id = 3, .payload = .{ .rectangle = .{ .color = .white, .corner_radius = .all(4) } } },
        .{ .bounds = .{}, .id = 2, .payload = .clip_end },
        .{ .bounds = .{}, .id = 4, .payload = .{ .clip_begin = .{ .width = 1, .height = 1 } } },
        .{ .bounds = .{}, .id = 4, .payload = .clip_end },
        .{ .bounds = .{ .width = 5, .height = 5 }, .id = 5, .payload = .{ .border = .{ .color = .white, .widths = .all(1), .corner_radius = .zero } } },
    });
    defer laid_out.deinit();
    const batches = laid_out.draw_list.batches();
    try testing.expectEqual(3, batches.len);
    try testing.expectEqualDeep(DrawList.Scissor{ .x = 21, .y = 200 - 60, .width = 60, .height = 20 }, batches[1].scissor);
    try testing.expectEqual(6, batches[1].first_vertex);
    try testing.expectEqual(4 * (DrawList.corner_segments + 1) * 3, batches[1].vertex_count);
    try testing.expectEqualDeep(DrawList.Scissor{ .x = 0, .y = 0, .width = 400, .height = 200 }, batches[2].scissor);
    try testing.expectEqual(4 * (DrawList.corner_segments + 1) * 6, batches[2].vertex_count);
}

test "a transform moves every vertex up to its end" {
    const square: zui.Rect = .{ .width = 10, .height = 10 };
    var laid_out = try layOutForTest(&.{
        .{ .bounds = square, .id = 1, .payload = .{ .transform_begin = .{ .translation = .{ 50, 0 } } } },
        .{ .bounds = square, .id = 2, .payload = .{ .rectangle = .{ .color = .white, .corner_radius = .zero } } },
        .{ .bounds = square, .id = 1, .payload = .transform_end },
        .{ .bounds = square, .id = 3, .payload = .{ .rectangle = .{ .color = .white, .corner_radius = .zero } } },
    });
    defer laid_out.deinit();
    const draw_list = &laid_out.draw_list;
    try testing.expectEqualDeep([2]f32{ 50, 0 }, draw_list.vertices()[0].position);
    try testing.expectEqualDeep([2]f32{ 0, 0 }, draw_list.vertices()[6].position);
}

test "a gradient's vertices take its colors at their points, and a shadow fades to clear" {
    var laid_out = try layOutForTest(&.{
        .{ .bounds = .{ .width = 100, .height = 10 }, .id = 1, .payload = .{ .gradient = .{ .from = .black, .to = .white } } },
    });
    defer laid_out.deinit();
    const draw_list = &laid_out.draw_list;
    const gradient_vertices = draw_list.vertices();
    var bands_reached_end = false;
    for (gradient_vertices) |drawn| {
        if (drawn.position[0] == 0) try testing.expectEqualDeep(zui.Color.black, drawn.color);
        if (drawn.position[0] == 50) try testing.expect(drawn.color.r > 0 and drawn.color.r < 255);
        if (drawn.position[0] == 100) {
            try testing.expectEqualDeep(zui.Color.white, drawn.color);
            bands_reached_end = true;
        }
    }
    try testing.expect(bands_reached_end);

    draw_list.layOut(&[_]DemoCommand{
        .{ .bounds = .{ .width = 20, .height = 20 }, .id = 1, .payload = .{ .shadow = .{ .color = .black, .blur = 6 } } },
    }, demo_params, &laid_out.text);
    const shadow_vertices = draw_list.vertices();
    try testing.expectEqual(255, shadow_vertices[0].color.a);
    const outermost = shadow_vertices[shadow_vertices.len - 2];
    try testing.expectEqual(0, outermost.color.a);
    try testing.expectApproxEqAbs(@as(f32, -6), outermost.position[0], 0.001);
}

test "a shape that does not fit is left out whole, and the frame after starts again" {
    var laid_out = try layOutForTest(&.{});
    defer laid_out.deinit();
    const draw_list = &laid_out.draw_list;
    const rounded: DemoCommand = .{ .bounds = .{ .width = 10, .height = 10 }, .id = 1, .payload = .{ .rectangle = .{ .color = .white, .corner_radius = .all(2) } } };
    const rounded_vertices = 4 * (DrawList.corner_segments + 1) * 3;
    const too_many = try testing.allocator.alloc(DemoCommand, DrawList.max_vertices / rounded_vertices + 1);
    defer testing.allocator.free(too_many);
    @memset(too_many, rounded);
    draw_list.layOut(too_many, demo_params, &laid_out.text);
    try testing.expectEqual(1, draw_list.vertex_overflows);
    try testing.expectEqual((too_many.len - 1) * rounded_vertices, draw_list.vertices().len);
    try testing.expectEqual(draw_list.vertices().len, draw_list.batches()[0].vertex_count);
    draw_list.layOut(too_many[0..1], demo_params, &laid_out.text);
    try testing.expectEqual(rounded_vertices, draw_list.vertices().len);
}

test "bitmap text is a quad per glyph in its font's row, drawn once the fonts are loaded" {
    const line: DemoCommand = .{ .bounds = .{ .x = 10, .y = 0, .width = 24, .height = 20 }, .id = 1, .payload = .{ .text = .{ .content = "A\u{e9}", .style = .{ .size = 16, .color = .white, .font = 2 }, .line = 0 } } };
    var laid_out = try layOutForTest(&.{line});
    defer laid_out.deinit();
    try testing.expectEqual(0, laid_out.draw_list.vertices().len);

    var rows: [Text.bitmap_font_bytes]u8 = @splat(0);
    laid_out.text.loadBitmapFonts(&rows);
    laid_out.draw_list.layOut(&[_]DemoCommand{line}, demo_params, &laid_out.text);
    const vertices = laid_out.draw_list.vertices();
    try testing.expectEqual(2 * 6, vertices.len);
    const glyph_size = 16 * Text.bitmap_glyph_scale;
    try testing.expectEqualDeep([2]f32{ 10, (20 - glyph_size) / 2 }, vertices[0].position);
    try testing.expectEqualDeep([2]f32{ 10 + glyph_size, (20 + glyph_size) / 2 }, vertices[2].position);
    try testing.expectEqual(DrawList.Texture.bitmap_glyphs, vertices[0].texture);
    try testing.expectEqualDeep([2]f32{ 'A' * 8.0 / 2048.0, 16.0 / 48.0 }, vertices[0].texture_coordinates);
    try testing.expectEqualDeep([2]f32{ '?' * 8.0 / 2048.0, 16.0 / 48.0 }, vertices[6].texture_coordinates);
    try testing.expectEqualDeep([2]f32{ 10 + glyph_size, (20 - glyph_size) / 2 }, vertices[6].position);
}

test "text in a font id past the bitmap fonts that no TrueType font was added for draws in the last bitmap font" {
    const line: DemoCommand = .{ .bounds = .{ .width = 12, .height = 16 }, .id = 1, .payload = .{ .text = .{ .content = "x", .style = .{ .size = 16, .color = .white, .font = Text.bitmap_font_count }, .line = 0 } } };
    var laid_out = try layOutForTest(&.{});
    defer laid_out.deinit();
    var rows: [Text.bitmap_font_bytes]u8 = @splat(0);
    laid_out.text.loadBitmapFonts(&rows);
    laid_out.draw_list.layOut(&[_]DemoCommand{line}, demo_params, &laid_out.text);
    try testing.expectEqual(40.0 / 48.0, laid_out.draw_list.vertices()[0].texture_coordinates[1]);
}

test "a batch, a blur and a material are what the page reads" {
    try testing.expectEqual(28, @sizeOf(DrawList.Batch));
    try testing.expectEqual(24, @offsetOf(DrawList.Batch, "material"));
    try testing.expectEqual(28, @sizeOf(DrawList.BackdropBlur));
    try testing.expectEqual(12, @offsetOf(DrawList.BackdropBlur, "region"));
    try testing.expectEqual(8, @sizeOf(DrawList.BlurTap));
    try testing.expectEqual(64, @sizeOf(DrawList.Material));
}

const frost: DemoCommand = .{
    .bounds = .{ .x = 10.25, .y = 20, .width = 30, .height = 40 },
    .id = 2,
    .payload = .{ .backdrop_blur = .{ .radius = 5, .tint = .{ .r = 255, .g = 255, .b = 255, .a = 51 }, .corner_radius = .all(4) } },
};
const backdrop: DemoCommand = .{ .bounds = .{ .width = 200, .height = 100 }, .id = 1, .payload = .{ .rectangle = .{ .color = .black, .corner_radius = .zero } } };
const fan_vertices = 4 * (DrawList.corner_segments + 1) * 3;

test "a backdrop blur runs before a batch of its own, which samples it inside the outline and then draws the tint" {
    var laid_out = try layOutForTest(&.{ backdrop, frost });
    defer laid_out.deinit();
    const draw_list = &laid_out.draw_list;
    try testing.expectEqual(2, draw_list.batches().len);
    const blurs = draw_list.backdropBlurs();
    try testing.expectEqual(1, blurs.len);
    try testing.expectEqual(1, blurs[0].before_batch);
    try testing.expectEqualDeep([4]f32{ 20, 40, 81, 120 }, blurs[0].region);
    var total: f32 = 0;
    for (draw_list.blurTaps()[blurs[0].first_tap..][0..blurs[0].tap_count]) |tap| total += tap.weight;
    try testing.expectApproxEqAbs(@as(f32, 1), total, 0.25 / 255.0);
    const blurred = draw_list.vertices()[draw_list.batches()[1].first_vertex..];
    try testing.expectEqual(DrawList.Texture.backdrop_blur, blurred[0].texture);
    try testing.expectEqual(DrawList.Texture.none, blurred[fan_vertices].texture);
    try testing.expectEqual(51, blurred[fan_vertices].color.a);
}

test "a blur the page cannot run is its tint alone" {
    var laid_out = try layOutForTest(&.{});
    defer laid_out.deinit();
    const draw_list = &laid_out.draw_list;
    draw_list.blurs_backdrops = false;
    draw_list.layOut(&[_]DemoCommand{ backdrop, frost }, demo_params, &laid_out.text);
    try testing.expectEqual(0, draw_list.backdropBlurs().len);
    try testing.expectEqual(1, draw_list.batches().len);
    try testing.expectEqual(6 + fan_vertices, draw_list.vertices().len);
    try testing.expectEqual(0, draw_list.effect_overflows);
}

test "blurs past the frame's limit are their tint alone, and counted" {
    var laid_out = try layOutForTest(&.{});
    defer laid_out.deinit();
    const draw_list = &laid_out.draw_list;
    const too_many: [DrawList.max_backdrop_blurs + 1]DemoCommand = @splat(frost);
    draw_list.layOut(&too_many, demo_params, &laid_out.text);
    try testing.expectEqual(DrawList.max_backdrop_blurs, draw_list.backdropBlurs().len);
    try testing.expectEqual(1, draw_list.effect_overflows);
}

test "a material is a batch of its own, its vertices at their place in the element, and the batch after it has none" {
    const material: DemoCommand = .{ .bounds = .{ .x = 10, .y = 20, .width = 40, .height = 30 }, .id = 3, .payload = .{ .material = .{
        .handle = .{ .pattern = .sheen, .first = .rgb(0x336699), .second = .white, .phase = 0.25, .scale = 32 },
        .fallback = .rgb(0x336699),
        .corner_radius = .all(6),
    } } };
    var laid_out = try layOutForTest(&.{ backdrop, material, backdrop });
    defer laid_out.deinit();
    const draw_list = &laid_out.draw_list;
    const batches = draw_list.batches();
    try testing.expectEqual(3, batches.len);
    try testing.expectEqual(DrawList.no_material, batches[0].material);
    try testing.expectEqual(0, batches[1].material);
    try testing.expectEqual(fan_vertices, batches[1].vertex_count);
    try testing.expectEqual(DrawList.no_material, batches[2].material);
    const drawn = draw_list.materials()[0];
    try testing.expectEqualDeep([4]f32{ 0x33.0 / 255.0, 0x66.0 / 255.0, 0x99.0 / 255.0, 1 }, drawn.first_color);
    try testing.expectEqualDeep([4]f32{ 1, 1, 1, 1 }, drawn.second_color);
    try testing.expectEqualDeep([4]f32{ 40, 30, 32, 0 }, drawn.size_and_scale);
    try testing.expectEqualDeep([4]f32{ 1, 0.25, 0, 0 }, drawn.pattern_and_phase);
    const center = draw_list.vertices()[batches[1].first_vertex];
    try testing.expectEqual(DrawList.Texture.material, center.texture);
    try testing.expectEqualDeep([2]f32{ 30, 35 }, center.position);
    try testing.expectEqualDeep([2]f32{ 20, 15 }, center.texture_coordinates);
}

test {
    _ = @import("backdrop_blur.zig");
    _ = @import("draw_list.zig");
    _ = @import("glyph_atlas.zig");
    _ = @import("text.zig");
}

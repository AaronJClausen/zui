const std = @import("std");
const zui = @import("zui");
const zui_wire = @import("zui_wire");

pub const FrameStream = @import("frame_stream.zig").FrameStream;
pub const DemoUi = @import("demo_ui.zig").DemoUi;
pub const DrawList = @import("draw_list.zig").DrawList;
pub const Text = @import("text.zig").Text;

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

test {
    _ = @import("draw_list.zig");
    _ = @import("glyph_atlas.zig");
    _ = @import("text.zig");
}

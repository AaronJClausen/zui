const std = @import("std");
const zui = @import("zui");
const zui_wire = @import("zui_wire");

pub const FrameStream = @import("frame_stream.zig").FrameStream;
pub const DemoUi = @import("demo_ui.zig").DemoUi;

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

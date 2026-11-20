//! Wrapping at a text contract's own break opportunities. A byte is 8
//! wide and 16 tall, so each of these CJK characters, three bytes in
//! UTF-8, is 24 wide.

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

/// Breaks before every character that starts with a three-byte sequence,
/// and after a run of spaces, as a line breaker for CJK does.
const CharacterBreakingText = struct {
    saw_newline: bool = false,

    pub fn zuiMeasure(_: *CharacterBreakingText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * key.size / 2, key.size };
    }

    pub fn zuiSegment(self: *CharacterBreakingText, paragraph: []const u8, breaks: *zui.BreakSink) void {
        if (std.mem.indexOfScalar(u8, paragraph, '\n') != null) self.saw_newline = true;
        for (paragraph[1..], 1..) |byte, offset| {
            if (byte == ' ') continue;
            if (paragraph[offset - 1] == ' ' or byte >= 0xe0) breaks.add(offset);
        }
    }
};

const Ui = zui.Context(.{
    .limits = .{ .max_elements = 64, .max_text_bytes = 1024, .max_render_commands = 128 },
    .Text = CharacterBreakingText,
});

fn wrapped(text_contract: *CharacterBreakingText, content: []const u8, width: f32, buffer: []u8) ![]const u8 {
    var ui = try Ui.init(testing.allocator, testing.io, text_contract);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(width) } } });
    ui.text(content, .{});
    ui.close();
    const frame = ui.endFrame();
    defer ui.release(frame);
    try frame.diagnostics.check();
    return support.snapshot(frame, buffer);
}

test "CJK text wraps between characters" {
    var text_contract: CharacterBreakingText = .{};
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\text 0 0 96 16 "日本語の"
        \\text 0 16 96 16 "テキスト"
        \\text 0 32 48 16 "です"
        \\
    , try wrapped(&text_contract, "日本語のテキストです", 100, &buffer));
}

test "Latin words stay whole beside CJK, and the space before a break hangs" {
    var text_contract: CharacterBreakingText = .{};
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\text 0 0 80 16 "zui 日本"
        \\text 0 16 48 16 "語 is"
        \\text 0 32 32 16 "fast"
        \\
    , try wrapped(&text_contract, "zui 日本語 is fast", 80, &buffer));
}

test "each paragraph is segmented on its own" {
    var text_contract: CharacterBreakingText = .{};
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\text 0 0 48 16 "日本"
        \\text 0 32 72 16 "テキス"
        \\text 0 48 24 16 "ト"
        \\
    , try wrapped(&text_contract, "日本\n\nテキスト", 72, &buffer));
    try testing.expect(!text_contract.saw_newline);
}

test "a text that fits stays one line" {
    var text_contract: CharacterBreakingText = .{};
    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\text 0 0 72 16 "日本語"
        \\
    , try wrapped(&text_contract, "日本語", 100, &buffer));
}

test "a cached string wraps as a freshly measured one, past the widths a cache entry keeps" {
    var text_contract: CharacterBreakingText = .{};
    var ui = try Ui.init(testing.allocator, testing.io, &text_contract);
    defer ui.deinit(testing.allocator);
    const content = "日本語のテキストを二十文字より長く折り返して表示します";
    var snapshots: [2][1024]u8 = undefined;
    var lengths: [2]usize = undefined;
    var measure_calls: [2]u64 = undefined;
    for (&snapshots, &lengths, &measure_calls) |*buffer, *length, *calls| {
        ui.beginFrame(&support.record(.zero, &.{}));
        ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(120) } } });
        ui.text(content, .{});
        ui.close();
        const frame = ui.endFrame();
        defer ui.release(frame);
        try frame.diagnostics.check();
        length.* = (try support.snapshot(frame, buffer)).len;
        calls.* = ui.measureCalls();
    }
    try testing.expectEqualStrings(snapshots[0][0..lengths[0]], snapshots[1][0..lengths[1]]);
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, snapshots[0][0..lengths[0]], "\n"));
    try testing.expectEqual(measure_calls[0], measure_calls[1]);
}

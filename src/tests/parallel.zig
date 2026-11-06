const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

/// The same metrics as `support.FixedMetricsText`, safe to call from
/// several threads at once, counting its calls.
const ThreadSafeText = struct {
    pub const zui_thread_safe = true;

    calls: std.atomic.Value(u32) = .init(0),

    pub fn zuiMeasure(self: *ThreadSafeText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        _ = self.calls.fetchAdd(1, .monotonic);
        return .{ @as(f32, @floatFromInt(text.len)) * key.size / 2, key.size };
    }
};

const limits: zui.Limits = .{
    .max_elements = 1024,
    .max_text_bytes = 32 * 1024,
    .max_render_commands = 4096,
    .measure_cache_entries = 8192,
    .parallel_measure_threshold = 64,
};
const ParallelUi = zui.Context(.{ .limits = limits, .Text = ThreadSafeText });
const SerialUi = zui.Context(.{ .limits = limits, .Text = support.FixedMetricsText });

/// `paragraph_count` paragraphs of distinct made-up words, wrapped in
/// 120-unit columns.
fn declareParagraphs(ui: anytype, paragraph_count: usize, word_seed: u64) void {
    var prng: std.Random.DefaultPrng = .init(word_seed);
    const random = prng.random();
    var buffer: [256]u8 = undefined;
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(120) } } });
    for (0..paragraph_count) |_| {
        var length: usize = 0;
        for (0..12) |word_index| {
            if (word_index != 0) {
                buffer[length] = ' ';
                length += 1;
            }
            const word_length = 2 + random.uintLessThan(usize, 8);
            for (buffer[length..][0..word_length]) |*byte| byte.* = 'a' + random.uintLessThan(u8, 26);
            length += word_length;
        }
        ui.text(buffer[0..length], .{ .wrap = .words });
    }
    ui.close();
}

fn expectSameCommands(expected: []const SerialUi.RenderCommand, actual: []const ParallelUi.RenderCommand) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_command, actual_command| {
        try testing.expectEqual(expected_command.bounds, actual_command.bounds);
        switch (expected_command.payload) {
            .text => |expected_text| try testing.expectEqualStrings(expected_text.content, actual_command.payload.text.content),
            else => {},
        }
    }
}

test "parallel measurement lays out exactly like serial measurement" {
    var parallel_text: ThreadSafeText = .{};
    var parallel_ui: ParallelUi = try .init(testing.allocator, testing.io, &parallel_text);
    defer parallel_ui.deinit(testing.allocator);
    var serial_text: support.FixedMetricsText = .{};
    var serial_ui: SerialUi = try .init(testing.allocator, testing.io, &serial_text);
    defer serial_ui.deinit(testing.allocator);

    for (0..3) |frame_number| {
        const seed = 7 + frame_number;
        parallel_ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 800, 600 } } });
        declareParagraphs(&parallel_ui, 40, seed);
        const parallel_frame = parallel_ui.endFrame();
        serial_ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 800, 600 } } });
        declareParagraphs(&serial_ui, 40, seed);
        const serial_frame = serial_ui.endFrame();
        try expectSameCommands(serial_frame.commands(), parallel_frame.commands());
        // The batch's measurements were used, not measured again inline.
        try testing.expectEqual(serial_ui.measureCalls(), parallel_text.calls.load(.monotonic));
        parallel_ui.release(parallel_frame);
        serial_ui.release(serial_frame);
    }
}

test "each distinct run is measured once, in the batch" {
    var text_contract: ThreadSafeText = .{};
    var ui: ParallelUi = try .init(testing.allocator, testing.io, &text_contract);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 800, 600 } } });
    declareParagraphs(&ui, 40, 1);
    ui.release(ui.endFrame());
    const first_frame_calls = text_contract.calls.load(.monotonic);
    try testing.expect(first_frame_calls > limits.parallel_measure_threshold);
    try testing.expectEqual(@as(u64, first_frame_calls), ui.measureCalls());
    // At least `threshold` calls were inline (the switch waits for the end
    // of a text); the rest went to the batch.
    const batch = &ui.memory.measure_batch;
    try testing.expect(batch.pending_count > 0);
    try testing.expect(batch.pending_count <= first_frame_calls - limits.parallel_measure_threshold);
    for (batch.pending[0..batch.pending_count]) |entry| try testing.expect(entry.done);

    // The same words again: everything is cached.
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 800, 600 } } });
    declareParagraphs(&ui, 40, 1);
    ui.release(ui.endFrame());
    try testing.expectEqual(first_frame_calls, text_contract.calls.load(.monotonic));
}

test "below the threshold, misses are measured inline" {
    var text_contract: ThreadSafeText = .{};
    var ui: ParallelUi = try .init(testing.allocator, testing.io, &text_contract);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 800, 600 } } });
    declareParagraphs(&ui, 2, 3);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expect(text_contract.calls.load(.monotonic) < limits.parallel_measure_threshold);
    try testing.expectEqual(@as(u32, 0), ui.memory.measure_batch.pending_count);
    try testing.expect(frame.commands().len > 2);
}

test "the batch keeps each key once and stops when full" {
    const Batch = @import("../parallel_measure.zig").MeasureBatch(zui.MeasureKey(u16), ThreadSafeText, 4);
    var batch: Batch = undefined;
    batch.clearAll();
    const key: zui.MeasureKey(u16) = .{ .font = 0, .size = 16, .letter_spacing = 0 };
    try testing.expect(batch.add(10, "a", key));
    try testing.expect(batch.add(10, "a", key));
    try testing.expect(batch.add(20, "b", key));
    try testing.expect(batch.add(30, "c", key));
    try testing.expect(batch.add(40, "d", key));
    try testing.expect(!batch.add(50, "e", key));
    try testing.expectEqual(@as(u32, 4), batch.pending_count);
    batch.reset();
    try testing.expect(batch.add(10, "a", key));
    try testing.expectEqual(@as(u32, 1), batch.pending_count);
}

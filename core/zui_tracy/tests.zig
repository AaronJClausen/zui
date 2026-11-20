const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_tracy = @import("zui_tracy.zig");

const testing = std.testing;
const Text = zui_testing.FixedMetricsText(u16);
const Ui = zui.Context(.{
    .limits = .{ .max_elements = 16, .max_text_bytes = 256, .max_render_commands = 32, .measure_cache_entries = 16 },
    .Text = Text,
    .features = .{ .Tracer = zui_tracy.Tracer },
});

test "the tracer is Tracy's only when Tracy is linked" {
    try testing.expectEqual(zui_tracy.enabled, zui_tracy.Tracer != void);
    try testing.expectEqual(zui_tracy.enabled, Ui.Tracing.enabled);
}

test "frames run with zones sent to Tracy" {
    var text: Text = .{};
    var ui: Ui = try .init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);

    for (0..3) |frame_number| {
        ui.beginFrame(&.{ .params = .{ .now = .fromNanoseconds(frame_number * std.time.ns_per_ms), .viewport = .{ 200, 100 } } });
        ui.text("traced", .{});
        ui.box(.{ .floating = .{ .z = 1 }, .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } }, .decoration = .{ .background = .black } });
        const frame = ui.endFrame();
        try testing.expectEqual(@as(usize, 2), frame.commands().len);
        ui.release(frame);
        zui_tracy.frameMark();
    }
}

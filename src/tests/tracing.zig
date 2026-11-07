const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;
const Tracer = support.RecordingTracer;

const TracedUi = zui.Context(.{
    .limits = .{ .max_elements = 16, .max_text_bytes = 256, .max_render_commands = 32, .measure_cache_entries = 16 },
    .Text = support.FixedMetricsText,
    .Sources = struct { idle: support.IdleSource = .{} },
    .features = .{ .Tracer = Tracer },
});

fn ignoreRecord(_: *anyopaque, _: *const TracedUi.FrameRecord) void {}

test "every step of beginFrame and endFrame is a zone, nested in its call" {
    var text_contract: support.FixedMetricsText = .{};
    var ui: TracedUi = try .init(testing.allocator, testing.io, &text_contract);
    defer ui.deinit(testing.allocator);
    ui.relayTo(.{ .context = &text_contract, .relayFn = ignoreRecord });

    Tracer.clear();
    var sources: TracedUi.Sources = .{};
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 800, 600 } } }, &sources);
    ui.text("traced", .{});
    ui.box(.{ .floating = .{ .z = 1 }, .decoration = .{ .background = .black } });
    ui.release(ui.endFrame());

    const Mark = Tracer.Mark;
    const expected = [_]Mark{
        .{ .zone = .begin_frame, .edge = .begin },
        .{ .zone = .wait_for_frame, .edge = .begin },
        .{ .zone = .wait_for_frame, .edge = .end },
        .{ .zone = .evict_state, .edge = .begin },
        .{ .zone = .evict_state, .edge = .end },
        .{ .zone = .apply_events, .edge = .begin },
        .{ .zone = .apply_events, .edge = .end },
        .{ .zone = .swap_sources, .edge = .begin },
        .{ .zone = .swap_sources, .edge = .end },
        .{ .zone = .relay, .edge = .begin },
        .{ .zone = .relay, .edge = .end },
        .{ .zone = .begin_frame, .edge = .end },
        .{ .zone = .end_frame, .edge = .begin },
        .{ .zone = .measure_text, .edge = .begin },
        .{ .zone = .measure_text, .edge = .end },
        .{ .zone = .fit_widths, .edge = .begin },
        .{ .zone = .fit_widths, .edge = .end },
        .{ .zone = .distribute_widths, .edge = .begin },
        .{ .zone = .distribute_widths, .edge = .end },
        .{ .zone = .wrap_text, .edge = .begin },
        .{ .zone = .wrap_text, .edge = .end },
        .{ .zone = .fit_heights, .edge = .begin },
        .{ .zone = .fit_heights, .edge = .end },
        .{ .zone = .distribute_heights, .edge = .begin },
        .{ .zone = .distribute_heights, .edge = .end },
        .{ .zone = .position, .edge = .begin },
        .{ .zone = .position, .edge = .end },
        .{ .zone = .emit, .edge = .begin },
        .{ .zone = .emit, .edge = .end },
        .{ .zone = .sort_layers, .edge = .begin },
        .{ .zone = .sort_layers, .edge = .end },
        .{ .zone = .end_frame, .edge = .end },
    };
    const recorded = try Tracer.recorded();
    try testing.expectEqualSlices(Mark, &expected, recorded);

    var zones_seen: std.EnumSet(zui.TraceZone) = .initEmpty();
    for (recorded) |mark| zones_seen.insert(mark.zone);
    try testing.expectEqual(std.EnumSet(zui.TraceZone).initFull(), zones_seen);
}

test "tryBeginFrame traces the same steps as beginFrame, without a relay zone when no listener is attached" {
    var text_contract: support.FixedMetricsText = .{};
    var ui: TracedUi = try .init(testing.allocator, testing.io, &text_contract);
    defer ui.deinit(testing.allocator);

    Tracer.clear();
    var sources: TracedUi.Sources = .{};
    try ui.tryBeginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 800, 600 } } }, &sources);
    const recorded = try Tracer.recorded();
    try testing.expectEqual(@as(usize, 10), recorded.len);
    try testing.expectEqual(Tracer.Mark{ .zone = .begin_frame, .edge = .end }, recorded[9]);
    ui.release(ui.endFrame());
}

test "without a tracer, a zone is zero-sized" {
    try testing.expectEqual(0, @sizeOf(support.Ui.Tracing.Zone));
    try testing.expect(!support.Ui.Tracing.enabled);
}

test "a context without sources has no swap_sources zone" {
    const UntracedSourcesUi = zui.Context(.{ .limits = .{ .max_elements = 8 }, .features = .{ .Tracer = Tracer } });
    var ui: UntracedSourcesUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);

    Tracer.clear();
    ui.beginFrame(&support.record(.zero, &.{}));
    for (try Tracer.recorded()) |mark| try testing.expect(mark.zone != .swap_sources);
    ui.release(ui.endFrame());
}

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const InspectedUi = zui.Context(.{
    .limits = .{ .max_elements = 32, .max_text_bytes = 256, .max_render_commands = 64, .measure_cache_entries = 32 },
    .Text = support.FixedMetricsText,
    .ImageHandle = u32,
});

const toolbar_id: zui.Id = .of("toolbar");
const raised_shadow: zui.Shadow = .{ .color = .black, .offset = .{ 0, 2 }, .blur = 4 };

fn declareToolbar(ui: *InspectedUi) void {
    ui.open(.{ .id = toolbar_id, .layout = .{ .padding = .all(4), .child_gap = 2 }, .decoration = .{ .background = .white } });
    ui.text("Save", .{});
    ui.image(.{ .handle = 7, .natural_size = .{ 16, 16 } }, .{ .id = toolbar_id.child("icon") });
    ui.box(.{
        .id = toolbar_id.child("badge"),
        .layout = .{ .sizing = .{ .width = .fixed(6), .height = .fixed(6) } },
        .floating = .{ .attach_point = .top_right, .z = 2 },
        .effects = &.{ .shadow = raised_shadow },
    });
    ui.close();
}

test "inspect reports each element in declaration order, from the root at 0" {
    var text_contract: support.FixedMetricsText = .{};
    var ui = try InspectedUi.init(testing.allocator, testing.io, &text_contract);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(&support.record(.zero, &.{}));
    declareToolbar(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try frame.diagnostics.check();

    try testing.expectEqual(@as(InspectedUi.Index, 5), frame.elementCount());

    const root = frame.inspect(0);
    try testing.expectEqual(@as(?InspectedUi.Index, null), root.parent);
    try testing.expectEqual(@as(InspectedUi.Index, 5), root.subtree_end);

    const toolbar = frame.inspect(1);
    try testing.expectEqual(toolbar_id.hash, toolbar.id);
    if (@TypeOf(toolbar.name) != void) try testing.expectEqualStrings("toolbar", toolbar.name);
    try testing.expectEqual(@as(?InspectedUi.Index, 0), toolbar.parent);
    try testing.expectEqual(frame.rectOf(toolbar_id).?, toolbar.rect);
    try testing.expectEqual(@as(f32, 4), toolbar.layout.padding.left);
    try testing.expectEqual(zui.Color.white, toolbar.decoration.?.background.?);
    try testing.expectEqual(InspectedUi.ElementContent.none, toolbar.content);
    try testing.expect(toolbar.effects == null and toolbar.floating == null);

    const label = frame.inspect(2);
    try testing.expectEqual(@as(?InspectedUi.Index, 1), label.parent);
    try testing.expectEqualStrings("Save", label.content.text.bytes);
    try testing.expectEqual(@as(f32, 32), label.rect.width);

    const icon = frame.inspect(3);
    try testing.expectEqual(@as(u32, 7), icon.content.image.handle);

    const badge = frame.inspect(4);
    try testing.expect(badge.flags.floating);
    try testing.expectEqual(@as(i16, 2), badge.floating.?.z);
    try testing.expectEqual(raised_shadow, badge.effects.?.shadow.?);
    try testing.expectEqual(@as(InspectedUi.Index, 5), badge.subtree_end);
}

test "inspect finds each element's own effects among several" {
    var text_contract: support.FixedMetricsText = .{};
    var ui = try InspectedUi.init(testing.allocator, testing.io, &text_contract);
    defer ui.deinit(testing.allocator);

    ui.beginFrame(&support.record(.zero, &.{}));
    for (0..6) |index| {
        const offset: f32 = @floatFromInt(index);
        if (index % 2 == 0) {
            ui.box(.{ .effects = &.{ .shadow = .{ .color = .black, .offset = .{ offset, 0 } } } });
        } else ui.box(.{});
    }
    const frame = ui.endFrame();
    defer ui.release(frame);

    for (1..frame.elementCount()) |index| {
        const effects = frame.inspect(@intCast(index)).effects;
        if ((index - 1) % 2 == 0) {
            try testing.expectEqual(@as(f32, @floatFromInt(index - 1)), effects.?.shadow.?.offset[0]);
        } else try testing.expect(effects == null);
    }
}

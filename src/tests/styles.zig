const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const panel_style = zui.static(zui.Style{
    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(120), .height = .fixed(40) }, .padding = .all(4), .child_gap = 2 },
    .decoration = .{ .background = .rgb(0x203040), .border = .{ .color = .rgb(0xffffff), .widths = .all(1) } },
});
const plain_style = zui.static(zui.Style{ .layout = .{ .sizing = .{ .width = .fixed(30), .height = .fixed(10) } } });

fn declarePanels(ui: *support.Ui, comptime static: bool) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom } });
    if (static) ui.open(.{ .id = .of("panel"), .style = panel_style }) else ui.open(.{ .id = .of("panel"), .layout = panel_style.value.layout, .decoration = panel_style.value.decoration });
    if (static) ui.box(.{ .id = .of("plain"), .style = plain_style }) else ui.box(.{ .id = .of("plain"), .layout = plain_style.value.layout });
    ui.close();
    ui.close();
}

test "an element with a static style lays out and draws as one with the same configs copied" {
    var commands: [2][16]zui.Rect = undefined;
    var command_counts: [2]usize = undefined;
    inline for (.{ false, true }, 0..) |static, run| {
        var harness: support.Harness = .{};
        try harness.init();
        defer harness.deinit();
        const ui = harness.begin();
        declarePanels(ui, static);
        const frame = try harness.end();
        try testing.expectEqual(zui.Rect{ .x = 4, .y = 4, .width = 30, .height = 10 }, frame.rectOf(.of("plain")).?);
        command_counts[run] = frame.commands().len;
        for (frame.commands(), 0..) |command, index| commands[run][index] = command.bounds;
    }
    try testing.expectEqual(command_counts[0], command_counts[1]);
    try testing.expectEqualSlices(zui.Rect, commands[0][0..command_counts[0]], commands[1][0..command_counts[1]]);
}

test "a static style is referenced, not copied, and the element's own configs replace the style's" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    const ui = harness.begin();
    ui.open(.{});
    ui.box(.{ .id = .of("styled"), .style = panel_style });
    ui.box(.{ .id = .of("own layout"), .style = panel_style, .layout = .{ .sizing = .{ .width = .fixed(7), .height = .fixed(7) } } });
    ui.box(.{ .id = .of("no decoration"), .style = panel_style, .decoration = .{} });
    ui.box(.{ .id = .of("undecorated style"), .style = plain_style });
    ui.close();
    const frame = try harness.end();

    const styled = frame.lookup(zui.Id.of("styled").hash).?;
    try testing.expectEqual(&panel_style.value.layout, frame.layoutOf(styled));
    try testing.expectEqual(&panel_style.value.decoration, frame.decorationOf(styled).?);

    const own_layout = frame.lookup(zui.Id.of("own layout").hash).?;
    try testing.expectEqual(@as(f32, 7), frame.rectOf(.of("own layout")).?.width);
    try testing.expectEqual(&panel_style.value.decoration, frame.decorationOf(own_layout).?);

    try testing.expectEqual(null, frame.decorationOf(frame.lookup(zui.Id.of("no decoration").hash).?));
    try testing.expectEqual(null, frame.decorationOf(frame.lookup(zui.Id.of("undecorated style").hash).?));
    try testing.expectEqual(@as(f32, 120), frame.rectOf(.of("no decoration")).?.width);

    var rectangles: usize = 0;
    var borders: usize = 0;
    for (frame.commands()) |command| switch (command.payload) {
        .rectangle => rectangles += 1,
        .border => borders += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), rectangles);
    try testing.expectEqual(@as(usize, 2), borders);
}

test "a static style's direction flows its children" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    const ui = harness.begin();
    ui.open(.{ .style = panel_style });
    ui.box(.{ .id = .of("first"), .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(5) } } });
    ui.box(.{ .id = .of("second"), .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(5) } } });
    ui.close();
    const frame = try harness.end();
    try testing.expectEqual(@as(f32, 4 + 5 + 2), frame.rectOf(.of("second")).?.y);
}

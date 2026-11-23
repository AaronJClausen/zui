const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const Ui = zui.Context(.{ .limits = .{ .max_elements = 32, .max_render_commands = 64 } });

const control_bounds: zui.Rect = .{ .x = 20, .y = 10, .width = 100, .height = 40 };

fn declareControl(ui: *Ui, corner_radius: zui.CornerRadius, border: zui.Border) void {
    ui.open(.{ .layout = .{ .padding = .{ .left = control_bounds.x, .top = control_bounds.y } } });
    ui.box(.{
        .layout = .{ .sizing = .{ .width = .fixed(control_bounds.width), .height = .fixed(control_bounds.height) } },
        .decoration = .{ .background = .white, .border = border, .corner_radius = corner_radius },
    });
    ui.close();
}

fn borderCommandOf(frame: anytype) !Ui.RenderCommand {
    for (frame.commands()) |command| if (command.payload == .border) return command;
    return error.NoBorderCommand;
}

test "a border without an offset is drawn inside its element" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    declareControl(&ui, .all(6), .{ .color = .black, .widths = .all(2) });
    const frame = ui.endFrame();
    defer ui.release(frame);

    const border = try borderCommandOf(frame);
    try testing.expectEqual(control_bounds, border.bounds);
    try testing.expectEqual(zui.CornerRadius.all(6), border.payload.border.corner_radius);
    try testing.expectEqual(zui.Edges.all(2), border.payload.border.widths);
}

test "a border with an offset is drawn that far outside its element, its rounded corners concentric" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    declareControl(&ui, .{ .top_left = 6, .top_right = 6, .bottom_left = 1000 }, .{ .color = .black, .widths = .all(2), .offset = 3 });
    const frame = ui.endFrame();
    defer ui.release(frame);

    const border = try borderCommandOf(frame);
    try testing.expectEqual(zui.Rect{ .x = 15, .y = 5, .width = 110, .height = 50 }, border.bounds);
    try testing.expectEqual(zui.CornerRadius{ .top_left = 11, .top_right = 11, .bottom_left = 25, .bottom_right = 0 }, border.payload.border.corner_radius);
    try testing.expectEqual(zui.Edges.all(2), border.payload.border.widths);
}

test "a border with an offset takes no space and leaves the element's own commands where they were" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    declareControl(&ui, .zero, .{ .color = .black, .widths = .all(2), .offset = 2 });
    const frame = ui.endFrame();
    defer ui.release(frame);

    var background: ?zui.Rect = null;
    for (frame.commands()) |command| if (command.payload == .rectangle) {
        background = command.bounds;
    };
    try testing.expectEqual(control_bounds, background.?);
    const border = try borderCommandOf(frame);
    try testing.expectEqual(zui.Rect{ .x = 16, .y = 6, .width = 108, .height = 48 }, border.bounds);
    try testing.expectEqual(zui.CornerRadius.zero, border.payload.border.corner_radius);
}

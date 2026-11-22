const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const limits: zui.Limits = .{ .max_elements = 32, .max_render_commands = 64 };
const RoundUi = zui.Context(.{ .limits = limits, .ImageHandle = u32 });
const ChamferingUi = zui.Context(.{ .limits = limits, .ImageHandle = u32, .corner_shapes = .initMany(&.{ .round, .chamfer }) });
const EveryShapeUi = zui.Context(.{ .limits = limits, .commands = .initOne(.shadow), .corner_shapes = .initFull() });

const card_size: zui.Sizing2 = .{ .width = .fixed(100), .height = .fixed(40) };

fn beginFrame(ui: anytype) void {
    ui.beginFrame(&support.record(.zero, &.{}));
}

fn declareShapedCards(ui: anytype) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom } });
    for ([_]zui.CornerShape{ .round, .continuous, .chamfer }) |shape| ui.box(.{
        .layout = .{ .sizing = card_size },
        .decoration = .{ .background = .white, .border = .{ .color = .black, .widths = .all(1) }, .corner_radius = .all(8), .corner_shape = shape },
    });
    ui.image(.{ .handle = 7, .corner_radius = .all(8), .corner_shape = .continuous }, .{ .layout = .{ .sizing = card_size } });
    ui.close();
}

test "a context whose renderer draws only round corners emits commands without a shape" {
    try testing.expect(!RoundUi.RenderCommand.carries_corner_shape);
    try testing.expect(RoundUi.RenderCommand.CornerShape == void);
    try testing.expect(@FieldType(RoundUi.RenderCommand.Rectangle, "corner_shape") == void);
    try testing.expect(@FieldType(RoundUi.RenderCommand.Border, "corner_shape") == void);
    try testing.expect(@FieldType(RoundUi.RenderCommand.Image, "corner_shape") == void);
    try testing.expect(ChamferingUi.RenderCommand.carries_corner_shape);
    try testing.expect(@FieldType(ChamferingUi.RenderCommand.Rectangle, "corner_shape") == zui.CornerShape);
}

test "emission clamps each corner to half the element's shorter side" {
    var ui: RoundUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    var pill: zui.CornerRadius = .all(1000);
    pill.top_left = 6;
    ui.box(.{ .layout = .{ .sizing = card_size }, .decoration = .{ .background = .white, .border = .{ .color = .black, .widths = .all(1) }, .corner_radius = pill } });
    const frame = ui.endFrame();
    defer ui.release(frame);

    const clamped: zui.CornerRadius = .{ .top_left = 6, .top_right = 20, .bottom_left = 20, .bottom_right = 20 };
    const commands = frame.commands();
    try testing.expectEqual(2, commands.len);
    try testing.expectEqual(clamped, commands[0].payload.rectangle.corner_radius);
    try testing.expectEqual(clamped, commands[1].payload.border.corner_radius);
}

test "a shape the renderer does not draw is emitted round and reported lowered" {
    var ui: RoundUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    declareShapedCards(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expect(frame.diagnostics.ok());
    try testing.expectEqual(zui.CornerShapeSet.initMany(&.{ .continuous, .chamfer }), frame.diagnostics.lowered_corner_shapes);
    try testing.expectEqual(7, frame.commands().len);

    beginFrame(&ui);
    ui.box(.{ .layout = .{ .sizing = card_size }, .decoration = .{ .background = .white, .corner_radius = .all(8) } });
    const plain = ui.endFrame();
    defer ui.release(plain);
    try testing.expectEqual(0, plain.diagnostics.lowered_corner_shapes.count());
}

test "a renderer that draws some shapes gets them in its commands, and the rest round" {
    var ui: ChamferingUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    declareShapedCards(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expectEqual(zui.CornerShapeSet.initOne(.continuous), frame.diagnostics.lowered_corner_shapes);

    const commands = frame.commands();
    const expected = [_]struct { zui.CornerShape, zui.CornerShape }{ .{ .round, .round }, .{ .round, .round }, .{ .chamfer, .chamfer } };
    for (expected, 0..) |shapes, card| {
        const fill_shape, const border_shape = shapes;
        try testing.expectEqual(fill_shape, commands[2 * card].payload.rectangle.corner_shape);
        try testing.expectEqual(border_shape, commands[2 * card + 1].payload.border.corner_shape);
    }
    try testing.expectEqual(zui.CornerShape.round, commands[6].payload.image.corner_shape);
}

test "a renderer that draws every shape gets each as declared, on its effects too, and nothing lowered" {
    var ui: EveryShapeUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    ui.box(.{
        .layout = .{ .sizing = card_size },
        .decoration = .{ .background = .white, .corner_radius = .all(8), .corner_shape = .continuous },
        .effects = &.{ .shadow = .{ .color = .black, .blur = 4 } },
    });
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expectEqual(0, frame.diagnostics.lowered_corner_shapes.count());
    const commands = frame.commands();
    try testing.expectEqual(zui.CornerShape.continuous, commands[0].payload.shadow.corner_shape);
    try testing.expectEqual(zui.CornerShape.continuous, commands[1].payload.rectangle.corner_shape);
}

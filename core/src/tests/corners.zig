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

const NestingUi = zui.Context(.{ .limits = limits, .corner_shapes = .initFull(), .features = .{ .nested_corners = true } });

const nested_card_size: zui.Sizing2 = .{ .width = .fixed(100), .height = .fixed(60) };
const fills_parent: zui.Sizing2 = .{ .width = .grow, .height = .grow };

fn openCard(ui: *NestingUi, radius: f32, padding: zui.Edges, shape: zui.CornerShape) void {
    ui.open(.{
        .layout = .{ .sizing = nested_card_size, .padding = padding },
        .decoration = .{ .background = .white, .corner_radius = .all(radius), .corner_shape = shape },
    });
}

fn nestedBox(ui: *NestingUi, sizing: zui.Sizing2, nested: zui.NestedCorners, shape: zui.CornerShape) void {
    ui.box(.{ .layout = .{ .sizing = sizing }, .decoration = .{ .background = .black, .corner_shape = shape, .nested_corners = nested } });
}

fn rectangleRadius(frame: *const NestingUi.Frame, command: usize) zui.CornerRadius {
    return frame.commands()[command].payload.rectangle.corner_radius;
}

test "without the feature a decoration holds no nested corners and stays its size" {
    try testing.expectEqual(0, @sizeOf(@FieldType(zui.Decoration, "nested_corners")));
    try testing.expectEqual(56, @sizeOf(zui.Decoration));
    try testing.expect(RoundUi.Decoration == zui.Decoration);
    try testing.expect(NestingUi.Decoration != zui.Decoration);
}

test "a card of radius 16 and padding 6 gives its filling child radius 10" {
    var ui: NestingUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    openCard(&ui, 16, .all(6), .round);
    nestedBox(&ui, fills_parent, .{}, .round);
    ui.close();
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expect(frame.diagnostics.ok());
    try testing.expectEqual(zui.CornerRadius.all(16), rectangleRadius(frame, 0));
    try testing.expectEqual(zui.CornerRadius.all(10), rectangleRadius(frame, 1));
}

test "a child that touches only the card's top edge follows only the top corners" {
    var ui: NestingUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    openCard(&ui, 16, .{ .left = 6, .right = 6 }, .continuous);
    nestedBox(&ui, .{ .width = .grow, .height = .fixed(20) }, .{ .minimum = 2 }, .continuous);
    ui.close();
    const frame = ui.endFrame();
    defer ui.release(frame);
    const expected: zui.CornerRadius = .{ .top_left = 10, .top_right = 10, .bottom_left = 2, .bottom_right = 2 };
    try testing.expectEqual(expected, rectangleRadius(frame, 1));
}

test "a chamfer nests by (2 - sqrt 2) times its inset" {
    var ui: NestingUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    openCard(&ui, 16, .all(6), .chamfer);
    nestedBox(&ui, fills_parent, .{}, .chamfer);
    ui.close();
    const frame = ui.endFrame();
    defer ui.release(frame);
    const shortened_cut = 16 - (2 - std.math.sqrt2) * 6.0;
    const radius = rectangleRadius(frame, 1);
    inline for (.{ "top_left", "top_right", "bottom_left", "bottom_right" }) |corner| {
        try testing.expectApproxEqAbs(shortened_cut, @field(radius, corner), 1e-4);
    }
    try testing.expectEqual(zui.CornerShape.chamfer, frame.commands()[1].payload.rectangle.corner_shape);
}

test "three nested levels resolve outermost first, past an undecorated wrapper" {
    var ui: NestingUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    openCard(&ui, 16, .all(4), .round);
    ui.open(.{ .layout = .{ .sizing = fills_parent, .padding = .all(4) }, .decoration = .{ .background = .black, .nested_corners = .{} } });
    ui.open(.{ .layout = .{ .sizing = fills_parent } });
    nestedBox(&ui, fills_parent, .{}, .round);
    ui.close();
    ui.close();
    ui.close();
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expectEqual(3, frame.commands().len);
    try testing.expectEqual(zui.CornerRadius.all(12), rectangleRadius(frame, 1));
    try testing.expectEqual(zui.CornerRadius.all(8), rectangleRadius(frame, 2));
}

test "a corner below its minimum, or past the parent's radius, or with no decorated parent, takes the minimum" {
    var ui: NestingUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    ui.open(.{ .layout = .{ .direction = .top_to_bottom } });
    openCard(&ui, 16, .all(12), .round);
    nestedBox(&ui, fills_parent, .{ .minimum = 6 }, .round);
    ui.close();
    openCard(&ui, 16, .all(20), .round);
    nestedBox(&ui, fills_parent, .{ .minimum = 3 }, .round);
    ui.close();
    nestedBox(&ui, nested_card_size, .{ .minimum = 5 }, .round);
    ui.close();
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expectEqual(5, frame.commands().len);
    try testing.expectEqual(zui.CornerRadius.all(6), rectangleRadius(frame, 1));
    try testing.expectEqual(zui.CornerRadius.all(3), rectangleRadius(frame, 3));
    try testing.expectEqual(zui.CornerRadius.all(5), rectangleRadius(frame, 4));
}

test "nested corners follow on a border and on effects too" {
    const NestingEffectsUi = zui.Context(.{ .limits = limits, .commands = .initOne(.shadow), .features = .{ .nested_corners = true } });
    var ui: NestingEffectsUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    ui.open(.{ .layout = .{ .sizing = nested_card_size, .padding = .all(6) }, .decoration = .{ .background = .white, .corner_radius = .all(16) } });
    ui.box(.{
        .layout = .{ .sizing = fills_parent },
        .decoration = .{ .border = .{ .color = .black, .widths = .all(1) }, .nested_corners = .{} },
        .effects = &.{ .shadow = .{ .color = .black, .blur = 4 } },
    });
    ui.close();
    const frame = ui.endFrame();
    defer ui.release(frame);
    const commands = frame.commands();
    try testing.expectEqual(3, commands.len);
    try testing.expectEqual(zui.CornerRadius.all(10), commands[1].payload.shadow.corner_radius);
    try testing.expectEqual(zui.CornerRadius.all(10), commands[2].payload.border.corner_radius);
}

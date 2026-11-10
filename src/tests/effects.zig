const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const EffectsUi = zui.Context(.{
    .limits = .{ .max_elements = 32, .max_render_commands = 64 },
    .commands = .initMany(&.{ .gradient, .shadow }),
});

const BaseUi = zui.Context(.{ .limits = .{ .max_elements = 32, .max_render_commands = 64 } });

const dusk: zui.Gradient = .{ .from = .rgb(0x3a1c71), .to = .rgb(0xffaf7b) };
const card_shadow: zui.Shadow = .{ .color = .rgba(0x00000060), .offset = .{ 0, 4 }, .blur = 12 };
const card_size: zui.Sizing2 = .{ .width = .fixed(100), .height = .fixed(40) };

fn beginFrame(ui: anytype) void {
    ui.beginFrame(&support.record(.zero, &.{}));
}

fn declareCard(ui: anytype) void {
    ui.open(.{ .layout = .{ .padding = .all(20) } });
    ui.box(.{
        .layout = .{ .sizing = card_size },
        .decoration = .{ .background = .white, .border = .{ .color = .black, .widths = .all(1) }, .corner_radius = .all(6) },
        .effects = .{ .gradient = dusk, .shadow = card_shadow },
    });
    ui.close();
}

test "mixing in OKLab keeps its ends, and the middle of black and white is darker than sRGB's" {
    try testing.expectEqual(zui.Color.rgb(0x636363), zui.Color.black.mixOklab(.white, 0.5));
    try testing.expectEqual(zui.Color.black, zui.Color.black.mixOklab(.white, 0));
    try testing.expectEqual(zui.Color.white, zui.Color.black.mixOklab(.white, 1));
    try testing.expectEqual(zui.Color.white, zui.Color.black.mixOklab(.white, 7));
    const translucent = zui.Color.rgba(0xff000000).mixOklab(.rgba(0xff0000ff), 0.5);
    try testing.expectEqual(zui.Color.rgba(0xff000080), translucent);
}

test "a gradient's line runs through the center, long enough that the far corners take its ends" {
    const bounds: zui.Rect = .{ .x = 10, .y = 20, .width = 100, .height = 40 };
    const across: zui.Gradient = .{ .from = .black, .to = .white };
    try testing.expectEqual(@as(f32, 0), across.amountAt(bounds, .{ 10, 30 }));
    try testing.expectEqual(@as(f32, 0.5), across.amountAt(bounds, .{ 60, 55 }));
    try testing.expectEqual(@as(f32, 1), across.amountAt(bounds, .{ 110, 20 }));

    const down: zui.Gradient = .{ .from = .black, .to = .white, .angle = std.math.pi / 2.0 };
    try testing.expectApproxEqAbs(@as(f32, 0), down.amountAt(bounds, .{ 90, 20 }), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.75), down.amountAt(bounds, .{ 0, 50 }), 1e-5);

    const diagonal: zui.Gradient = .{ .from = .black, .to = .white, .angle = std.math.pi / 4.0 };
    try testing.expectApproxEqAbs(@as(f32, 0), diagonal.amountAt(bounds, .{ 10, 20 }), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), diagonal.amountAt(bounds, .{ 110, 60 }), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), diagonal.amountAt(bounds, .{ 60, 40 }), 1e-5);

    try testing.expectEqual(dusk.from.mixOklab(dusk.to, 0.5), dusk.meanColor());
}

test "a renderer that draws gradients and shadows gets the shadow, background, gradient and border in that order" {
    var ui: EffectsUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    declareCard(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try frame.diagnostics.check();

    const card: zui.Rect = .{ .x = 20, .y = 20, .width = 100, .height = 40 };
    const commands = frame.commands();
    try testing.expectEqual(4, commands.len);
    try testing.expectEqual(EffectsUi.RenderCommand.Payload{ .shadow = .{
        .color = card_shadow.color,
        .offset = card_shadow.offset,
        .blur = card_shadow.blur,
        .corner_radius = .all(6),
    } }, commands[0].payload);
    try testing.expectEqual(zui.Color.white, commands[1].payload.rectangle.color);
    try testing.expectEqual(EffectsUi.RenderCommand.Payload{ .gradient = .{ .from = dusk.from, .to = dusk.to, .corner_radius = .all(6) } }, commands[2].payload);
    try testing.expectEqual(zui.Color.black, commands[3].payload.border.color);
    for (commands) |command| try testing.expectEqual(card, command.bounds);
    try testing.expect(frame.diagnostics.lowered.count() == 0);
    try testing.expectEqual(dusk.colorAt(card, .{ 70, 40 }), commands[2].payload.gradient.colorAt(card, .{ 70, 40 }));
}

test "for a renderer that draws neither, a gradient is lowered to its mean color and a shadow to nothing" {
    var ui: BaseUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    declareCard(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expect(frame.diagnostics.ok());

    const commands = frame.commands();
    try testing.expectEqual(3, commands.len);
    try testing.expectEqual(zui.Color.white, commands[0].payload.rectangle.color);
    try testing.expectEqual(BaseUi.RenderCommand.Payload{ .rectangle = .{ .color = dusk.meanColor(), .corner_radius = .all(6) } }, commands[1].payload);
    try testing.expectEqual(zui.Color.black, commands[2].payload.border.color);
    try testing.expectEqual(zui.CommandSet.initMany(&.{ .gradient, .shadow }), frame.diagnostics.lowered);

    beginFrame(&ui);
    ui.box(.{ .layout = .{ .sizing = card_size }, .decoration = .{ .background = .white } });
    const plain = ui.endFrame();
    defer ui.release(plain);
    try testing.expect(plain.diagnostics.lowered.count() == 0);
}

test "a shadow is culled by what it paints, not by its element's box" {
    var ui: EffectsUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    ui.open(.{ .clip = .both, .layout = .{ .sizing = .{ .width = .fixed(200), .height = .fixed(100) }, .direction = .top_to_bottom, .child_gap = 4 } });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(200), .height = .fixed(100) } } });
    ui.box(.{ .layout = .{ .sizing = card_size }, .effects = .{ .shadow = .{ .color = .black, .offset = .{ 0, -8 } } } });
    ui.box(.{ .layout = .{ .sizing = card_size }, .effects = .{ .shadow = .glow(.white, 2) } });
    ui.close();
    const frame = ui.endFrame();
    defer ui.release(frame);

    var shadows: usize = 0;
    for (frame.commands()) |command| {
        if (command.payload != .shadow) continue;
        shadows += 1;
        try testing.expectEqual(@as(f32, -8), command.payload.shadow.offset[1]);
    }
    try testing.expectEqual(1, shadows);
}

test "a static style's effects are drawn, and an element's own replace them" {
    const raised = zui.static(zui.Style{ .layout = .{ .sizing = card_size }, .effects = .{ .shadow = .glow(.white, 8) } });
    var ui: EffectsUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    ui.box(.{ .style = raised });
    ui.box(.{ .style = raised, .effects = .{ .gradient = dusk } });
    const frame = ui.endFrame();
    defer ui.release(frame);
    const commands = frame.commands();
    try testing.expectEqual(2, commands.len);
    try testing.expect(commands[0].payload == .shadow);
    try testing.expect(commands[1].payload == .gradient);
}

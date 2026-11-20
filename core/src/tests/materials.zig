const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const Material = enum(u8) { frosted_glass, brushed_metal };

const limits: zui.Limits = .{ .max_elements = 32, .max_render_commands = 64 };

const MaterialUi = zui.Context(.{ .limits = limits, .commands = .initOne(.material), .MaterialHandle = Material });

const UndeclaredMaterialUi = zui.Context(.{ .limits = limits, .MaterialHandle = Material });

const BaseUi = zui.Context(.{ .limits = limits });

const pane_size: zui.Sizing2 = .{ .width = .fixed(100), .height = .fixed(40) };
const pane_fallback: zui.Color = .rgb(0x202830);

fn beginFrame(ui: anytype) void {
    ui.beginFrame(&support.record(.zero, &.{}));
}

fn declarePane(ui: anytype) void {
    ui.open(.{ .layout = .{ .padding = .all(20) } });
    ui.box(.{
        .layout = .{ .sizing = pane_size },
        .decoration = .{ .background = pane_fallback, .material = .frosted_glass, .border = .{ .color = .black, .widths = .all(1) }, .corner_radius = .all(6) },
    });
    ui.close();
}

test "without a MaterialHandle, a context's element, decoration and style are zui's own, and the material takes no room" {
    comptime {
        std.debug.assert(BaseUi.Element == zui.Element);
        std.debug.assert(BaseUi.Decoration == zui.Decoration);
        std.debug.assert(BaseUi.Style == zui.Style);
        std.debug.assert(@sizeOf(@FieldType(zui.Decoration, "material")) == 0);
        std.debug.assert(MaterialUi.Element != zui.Element);
        std.debug.assert(MaterialUi.Element == UndeclaredMaterialUi.Element);
    }
}

test "a renderer that draws materials gets the material in place of the background, its fallback, under the border" {
    var ui: MaterialUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    declarePane(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try frame.diagnostics.check();

    const commands = frame.commands();
    try testing.expectEqual(2, commands.len);
    try testing.expectEqual(MaterialUi.RenderCommand.Payload{ .material = .{
        .handle = .frosted_glass,
        .fallback = pane_fallback,
        .corner_radius = .all(6),
    } }, commands[0].payload);
    try testing.expectEqual(zui.Color.black, commands[1].payload.border.color);
    try testing.expectEqual(zui.Rect{ .x = 20, .y = 20, .width = 100, .height = 40 }, commands[0].bounds);
    try testing.expect(frame.diagnostics.lowered.count() == 0);
}

test "for a renderer that does not draw materials, a material is lowered to its fallback background" {
    var ui: UndeclaredMaterialUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    declarePane(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expect(frame.diagnostics.ok());

    const commands = frame.commands();
    try testing.expectEqual(2, commands.len);
    try testing.expectEqual(UndeclaredMaterialUi.RenderCommand.Payload{ .rectangle = .{ .color = pane_fallback, .corner_radius = .all(6) } }, commands[0].payload);
    try testing.expectEqual(zui.CommandSet.initOne(.material), frame.diagnostics.lowered);

    beginFrame(&ui);
    ui.box(.{ .layout = .{ .sizing = pane_size }, .decoration = .{ .background = pane_fallback } });
    const plain = ui.endFrame();
    defer ui.release(plain);
    try testing.expect(plain.diagnostics.lowered.count() == 0);
}

const metal_style = zui.static(MaterialUi.Style{ .layout = .{ .sizing = pane_size }, .decoration = .{ .material = .brushed_metal, .corner_radius = .all(4) } });
const undeclared_metal_style = zui.static(UndeclaredMaterialUi.Style{ .layout = .{ .sizing = pane_size }, .decoration = .{ .material = .brushed_metal } });

test "a material without a background is kept, declared or static, and falls back to transparent or to nothing" {
    var ui: MaterialUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    ui.open(.{ .layout = .{ .direction = .top_to_bottom } });
    ui.box(.{ .layout = .{ .sizing = pane_size }, .decoration = .{ .material = .frosted_glass } });
    ui.box(.{ .style = metal_style });
    ui.close();
    const frame = ui.endFrame();
    defer ui.release(frame);

    const commands = frame.commands();
    try testing.expectEqual(2, commands.len);
    try testing.expectEqual(MaterialUi.RenderCommand.Payload{ .material = .{ .handle = .frosted_glass, .fallback = .transparent } }, commands[0].payload);
    try testing.expectEqual(MaterialUi.RenderCommand.Payload{ .material = .{ .handle = .brushed_metal, .fallback = .transparent, .corner_radius = .all(4) } }, commands[1].payload);

    var lowering: UndeclaredMaterialUi = try .init(testing.allocator, testing.io);
    defer lowering.deinit(testing.allocator);
    beginFrame(&lowering);
    lowering.open(.{ .layout = .{ .direction = .top_to_bottom } });
    lowering.box(.{ .layout = .{ .sizing = pane_size }, .decoration = .{ .material = .frosted_glass } });
    lowering.box(.{ .style = undeclared_metal_style });
    lowering.close();
    const lowered = lowering.endFrame();
    defer lowering.release(lowered);
    try testing.expectEqual(0, lowered.commands().len);
    try testing.expectEqual(zui.CommandSet.initOne(.material), lowered.diagnostics.lowered);
}

test "a material is painted over the shadow and backdrop blur and under the gradient" {
    const LayeredUi = zui.Context(.{ .limits = limits, .commands = .initMany(&.{ .material, .shadow, .backdrop_blur, .gradient }), .MaterialHandle = Material });
    var ui: LayeredUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    beginFrame(&ui);
    ui.box(.{
        .layout = .{ .sizing = pane_size },
        .decoration = .{ .material = .frosted_glass },
        .effects = &.{
            .shadow = .{ .color = .black, .blur = 4 },
            .backdrop_blur = .{ .radius = 8, .tint = .rgba(0xffffff20) },
            .gradient = .{ .from = .rgba(0xffffff00), .to = .rgba(0xffffff40) },
        },
    });
    const frame = ui.endFrame();
    defer ui.release(frame);

    var order: [4]std.meta.Tag(LayeredUi.RenderCommand.Payload) = undefined;
    for (frame.commands(), &order) |command, *tag| tag.* = command.payload;
    try testing.expectEqualSlices(std.meta.Tag(LayeredUi.RenderCommand.Payload), &.{ .shadow, .backdrop_blur, .material, .gradient }, &order);
}

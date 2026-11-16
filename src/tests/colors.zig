const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const limits: zui.Limits = .{ .max_elements = 32, .max_render_commands = 64, .max_text_bytes = 256, .measure_cache_entries = 64, .string_cache_entries = 64 };

const ClampingUi = zui.Context(.{ .limits = limits, .Text = support.FixedMetricsText, .Color = zui.ExtendedColor });

const ExtendedUi = zui.Context(.{ .limits = limits, .Text = support.FixedMetricsText, .Color = zui.ExtendedColor, .extended_color = true, .commands = .initOne(.gradient) });

const hdr_white: zui.ExtendedColor = .linear(4, 4, 4, 1);
const brighter_white: zui.ExtendedColor = .linear(8, 8, 8, 1);
const wide_red: zui.ExtendedColor = .linear(1.2, -0.1, -0.05, 1);
const panel: zui.ExtendedColor = .rgb(0x202830);
const pane_size: zui.Sizing2 = .{ .width = .fixed(100), .height = .fixed(40) };

var fixed_text: support.FixedMetricsText = .{};

fn declareScene(ui: anytype) void {
    ui.beginFrame(&support.record(.zero, &.{}));
    ui.open(.{ .layout = .{ .direction = .top_to_bottom }, .decoration = .{ .background = panel } });
    ui.box(.{ .layout = .{ .sizing = pane_size }, .decoration = .{ .background = hdr_white, .border = .{ .color = wide_red, .widths = .all(1) } } });
    ui.text("glow", .{ .color = hdr_white });
    ui.close();
}

test "ExtendedColor names sRGB colors exactly, and clamps HDR and wide gamut into Color" {
    try testing.expectEqual(zui.Color.rgb(0x202830), panel.toColor());
    try testing.expectEqual(zui.Color.rgba(0x3366ff80), zui.ExtendedColor.rgba(0x3366ff80).toColor());
    try testing.expectEqual(zui.Color.white, hdr_white.toColor());
    try testing.expectEqual(zui.Color.rgb(0xff0000), wide_red.toColor());
    try testing.expect(panel.isStandard());
    try testing.expect(zui.ExtendedColor.white.isStandard());
    try testing.expect(!hdr_white.isStandard());
    try testing.expect(!wide_red.isStandard());
}

test "ExtendedColor mixes without clamping, so the middle of two HDR colors stays HDR" {
    const middle = hdr_white.mixOklab(brighter_white, 0.5);
    try testing.expect(middle.r > 4 and middle.r < 8);
    try testing.expectApproxEqAbs(@as(f32, middle.r), middle.b, 0.01);
    try testing.expectEqual(zui.ExtendedColor.linear(2, 2, 2, 1), zui.ExtendedColor.black.mix(hdr_white, 0.5));
    try testing.expectEqual(zui.Color.black.mixOklab(.white, 0.5), zui.ExtendedColor.black.mixOklab(.white, 0.5).toColor());
}

test "a context in Color keeps zui's own types and commands, and clamps nothing" {
    const BaseUi = zui.Context(.{ .limits = limits });
    comptime {
        std.debug.assert(BaseUi.Color == zui.Color);
        std.debug.assert(BaseUi.CommandColor == zui.Color);
        std.debug.assert(!BaseUi.clamps_colors);
        std.debug.assert(BaseUi.Decoration == zui.Decoration);
        std.debug.assert(BaseUi.Effects == zui.Effects);
        std.debug.assert(BaseUi.Element == zui.Element);
        std.debug.assert(@sizeOf(zui.ExtendedColor) == 8);
        if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(zui.Diagnostics) == 96);
    }
}

test "for a renderer that draws only Color, ExtendedColor is clamped as it is emitted, and the frame says so" {
    comptime std.debug.assert(@FieldType(ClampingUi.RenderCommand.Rectangle, "color") == zui.Color);
    var ui: ClampingUi = try .init(testing.allocator, testing.io, &fixed_text);
    defer ui.deinit(testing.allocator);
    declareScene(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expect(frame.diagnostics.ok());
    try testing.expect(frame.diagnostics.clamped_colors);

    var buffer: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\rect 0 0 100 56 #202830
        \\rect 0 0 100 40 #ffffff
        \\border 0 0 100 40 #ff0000
        \\text 0 40 32 16 "glow"
        \\
    , try support.snapshot(frame, &buffer));
    try testing.expectEqual(zui.Color.white, frame.commands()[3].payload.text.style.color);
}

test "colors inside SDR and sRGB's gamut are not reported as clamped" {
    var ui: ClampingUi = try .init(testing.allocator, testing.io, &fixed_text);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    ui.box(.{ .layout = .{ .sizing = pane_size }, .decoration = .{ .background = panel, .border = .{ .color = .white, .widths = .all(1) } } });
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expect(!frame.diagnostics.clamped_colors);
    try testing.expectEqual(zui.Color.rgb(0x202830), frame.commands()[0].payload.rectangle.color);
}

test "a renderer that draws ExtendedColor is given every color as declared" {
    var ui: ExtendedUi = try .init(testing.allocator, testing.io, &fixed_text);
    defer ui.deinit(testing.allocator);
    declareScene(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expect(!frame.diagnostics.clamped_colors);

    const commands = frame.commands();
    try testing.expectEqual(4, commands.len);
    try testing.expectEqual(panel, commands[0].payload.rectangle.color);
    try testing.expectEqual(hdr_white, commands[1].payload.rectangle.color);
    try testing.expectEqual(wide_red, commands[2].payload.border.color);
    try testing.expectEqual(hdr_white, commands[3].payload.text.style.color);
}

test "effects take the context's colors: a drawn gradient keeps its HDR ends, a lowered one is clamped from its mean color" {
    const effects: ExtendedUi.Effects = .{ .gradient = .{ .from = panel, .to = hdr_white } };
    var drawing: ExtendedUi = try .init(testing.allocator, testing.io, &fixed_text);
    defer drawing.deinit(testing.allocator);
    drawing.beginFrame(&support.record(.zero, &.{}));
    drawing.box(.{ .layout = .{ .sizing = pane_size }, .effects = &effects });
    const drawn = drawing.endFrame();
    defer drawing.release(drawn);
    try testing.expectEqual(ExtendedUi.RenderCommand.Payload{ .gradient = .{ .from = panel, .to = hdr_white } }, drawn.commands()[0].payload);

    const clamping_effects: ClampingUi.Effects = .{ .gradient = .{ .from = hdr_white, .to = brighter_white } };
    var lowering: ClampingUi = try .init(testing.allocator, testing.io, &fixed_text);
    defer lowering.deinit(testing.allocator);
    lowering.beginFrame(&support.record(.zero, &.{}));
    lowering.box(.{ .layout = .{ .sizing = pane_size }, .effects = &clamping_effects });
    const lowered = lowering.endFrame();
    defer lowering.release(lowered);
    try testing.expectEqual(zui.CommandSet.initOne(.gradient), lowered.diagnostics.lowered);
    try testing.expect(lowered.diagnostics.clamped_colors);
    try testing.expectEqual(zui.Color.white, lowered.commands()[0].payload.rectangle.color);
}

const hdr_card = zui.static(ExtendedUi.Style{ .layout = .{ .sizing = pane_size }, .decoration = .{ .background = .rgb(0x3366ff) } });

test "a static style is written in the context's colors" {
    var ui: ExtendedUi = try .init(testing.allocator, testing.io, &fixed_text);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    ui.box(.{ .style = hdr_card });
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expectEqual(zui.ExtendedColor.rgb(0x3366ff), frame.commands()[0].payload.rectangle.color);
}

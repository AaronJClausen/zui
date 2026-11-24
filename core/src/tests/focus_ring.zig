const std = @import("std");
const zui = @import("../root.zig");

const testing = std.testing;

const Ui = zui.Context(.{ .limits = .{ .max_elements = 32, .max_render_commands = 64 }, .commands = .initMany(&.{ .shadow, .transform }) });

const scales = [_]f32{ 1, 1.25, 1.5, 2 };
const fractional_origins = [_][2]f32{ .{ 20, 10 }, .{ 20.3, 10.6 }, .{ 20.5, 10.5 }, .{ 20.71, 10.13 }, .{ 33.9, 7.45 } };
const fractional_sizes = [_][2]f32{ .{ 100, 40 }, .{ 100.4, 39.7 }, .{ 77.55, 31.2 } };

fn recordAt(scale: f32) zui.FrameRecord {
    return .{ .params = .{ .now = .zero, .viewport = .{ 800, 600 }, .scale = scale } };
}

const PixelRect = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    fn of(rect: zui.Rect, scale: f32) PixelRect {
        return .{ .left = rect.x * scale, .top = rect.y * scale, .right = (rect.x + rect.width) * scale, .bottom = (rect.y + rect.height) * scale };
    }
};

fn expectWholePixels(pixels: f32) !void {
    try testing.expectApproxEqAbs(@round(pixels), pixels, 1e-3);
}

fn declareFilledControl(ui: *Ui, origin: [2]f32, size: [2]f32, border: zui.Border) void {
    ui.open(.{ .layout = .{ .padding = .{ .left = origin[0], .top = origin[1] } } });
    ui.box(.{
        .layout = .{ .sizing = .{ .width = .fixed(size[0]), .height = .fixed(size[1]) } },
        .decoration = .{ .background = .white, .border = border, .corner_radius = .all(6) },
    });
    ui.close();
}

fn commandOf(frame: anytype, comptime tag: std.meta.Tag(Ui.RenderCommand.Payload)) !Ui.RenderCommand {
    for (frame.commands()) |command| if (command.payload == tag) return command;
    return error.CommandNotFound;
}

test "the gap between a ring and its control's fill is the same whole number of pixels on every side" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    for (scales) |scale| for (fractional_origins) |origin| for (fractional_sizes) |size| {
        ui.beginFrame(&recordAt(scale));
        declareFilledControl(&ui, origin, size, .{ .color = .black, .widths = .all(2), .offset = 2 });
        const frame = ui.endFrame();
        defer ui.release(frame);

        const fill = PixelRect.of((try commandOf(frame, .rectangle)).bounds, scale);
        const ring_command = try commandOf(frame, .border);
        const ring = PixelRect.of(ring_command.bounds, scale);
        const widths = ring_command.payload.border.widths;
        const width = widths.left * scale;
        try expectWholePixels(width);
        try testing.expect(width >= 1);
        inline for (.{ "right", "top", "bottom" }) |edge| try testing.expectApproxEqAbs(width, @field(widths, edge) * scale, 1e-3);

        const gap_left = fill.left - (ring.left + width);
        try expectWholePixels(gap_left);
        try testing.expectApproxEqAbs(@round(2 * scale), gap_left, 1e-3);
        try testing.expectApproxEqAbs(gap_left, (ring.right - width) - fill.right, 1e-3);
        try testing.expectApproxEqAbs(gap_left, fill.top - (ring.top + width), 1e-3);
        try testing.expectApproxEqAbs(gap_left, (ring.bottom - width) - fill.bottom, 1e-3);
    };
}

test "a ring's corners grow from its control's by the whole pixels it grows" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    for (scales) |scale| {
        ui.beginFrame(&recordAt(scale));
        declareFilledControl(&ui, .{ 20.3, 10.6 }, .{ 100.4, 39.7 }, .{ .color = .black, .widths = .all(2), .offset = 2 });
        const frame = ui.endFrame();
        defer ui.release(frame);

        const fill_radius = (try commandOf(frame, .rectangle)).payload.rectangle.corner_radius.top_left;
        const ring = (try commandOf(frame, .border)).payload.border;
        const growth = 2 * @round(2 * scale) / scale;
        try testing.expectApproxEqAbs(fill_radius + growth, ring.corner_radius.top_left, 1e-4);
        try testing.expectEqual(ring.corner_radius.top_left, ring.corner_radius.bottom_right);
    }
}

test "a border without an offset lies on its control's snapped edges" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    for (scales) |scale| for (fractional_origins) |origin| {
        ui.beginFrame(&recordAt(scale));
        declareFilledControl(&ui, origin, .{ 100.4, 39.7 }, .{ .color = .black, .widths = .all(1) });
        const frame = ui.endFrame();
        defer ui.release(frame);

        const fill = (try commandOf(frame, .rectangle)).bounds;
        const border = try commandOf(frame, .border);
        try testing.expectEqual(fill, border.bounds);
        try testing.expectEqual(zui.Edges.all(1), border.payload.border.widths);
    };
}

test "a hairline ring at a fractional scale is one pixel wide, never none" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&recordAt(1.25));
    declareFilledControl(&ui, .{ 20, 10 }, .{ 100, 40 }, .{ .color = .black, .widths = .all(0.25), .offset = 2 });
    const frame = ui.endFrame();
    defer ui.release(frame);

    try testing.expectApproxEqAbs(@as(f32, 1), (try commandOf(frame, .border)).payload.border.widths.left * 1.25, 1e-4);
}

test "dividers are each the same whole number of pixels thick, inset evenly from the border" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    for (scales) |scale| for (fractional_origins) |origin| {
        ui.beginFrame(&recordAt(scale));
        ui.open(.{ .layout = .{ .padding = .{ .left = origin[0], .top = origin[1] } } });
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .child_gap = 3.3, .padding = .all(1.3) },
            .decoration = .{ .border = .{ .color = .black, .widths = .all(1), .between_children = 1 } },
        });
        for (0..4) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(60.7), .height = .fixed(13.35) } } });
        ui.close();
        ui.close();
        const frame = ui.endFrame();
        defer ui.release(frame);

        const border = try commandOf(frame, .border);
        const outline = PixelRect.of(border.bounds, scale);
        const border_width = border.payload.border.widths.left * scale;
        var divider_count: usize = 0;
        for (frame.commands()) |command| if (command.payload == .rectangle) {
            const divider = PixelRect.of(command.bounds, scale);
            divider_count += 1;
            try testing.expectApproxEqAbs(@round(scale), divider.bottom - divider.top, 1e-3);
            try expectWholePixels(divider.top);
            try testing.expectApproxEqAbs(divider.left - outline.left, outline.right - divider.right, 1e-3);
            try testing.expectApproxEqAbs(@max(@round(border_width), 1), divider.left - outline.left, 1e-3);
        };
        try testing.expectEqual(@as(usize, 3), divider_count);
    };
}

test "a shadow's offset and spread are whole pixels, so it reaches as far on each side" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    const effects: zui.Effects = .{ .shadow = .{ .color = .black, .offset = .{ 0.7, 2.6 }, .blur = 3, .spread = 1.3 } };
    for (scales) |scale| {
        ui.beginFrame(&recordAt(scale));
        ui.box(.{ .effects = &effects, .layout = .{ .sizing = .{ .width = .fixed(40), .height = .fixed(20) } } });
        const frame = ui.endFrame();
        defer ui.release(frame);

        const shadow = (try commandOf(frame, .shadow)).payload.shadow;
        try expectWholePixels(shadow.offset[0] * scale);
        try expectWholePixels(shadow.offset[1] * scale);
        try expectWholePixels(shadow.spread * scale);
    }
}

const Neighbours = struct {
    const control: zui.Id = .of("control");
    const neighbour: zui.Id = .of("neighbour");

    const Around = enum { nothing, clip, transform };
    const nudge: zui.Effects = .{ .transform = .{ .translation = .{ 5, 0 } } };

    fn declare(ui: *Ui, around: Around) void {
        ui.open(.{ .clip = if (around == .clip) .both else .none, .effects = if (around == .transform) &nudge else null, .layout = .{ .padding = .all(20) } });
        ui.box(.{
            .id = control,
            .focusable = true,
            .layout = .{ .sizing = .{ .width = .fixed(60), .height = .fixed(30) } },
            .decoration = .{ .background = .white, .border = .{ .color = .black, .widths = .all(2), .offset = 2 } },
        });
        ui.box(.{
            .id = neighbour,
            .interactive = true,
            .layout = .{ .sizing = .{ .width = .fixed(60), .height = .fixed(30) } },
            .decoration = .{ .background = if (ui.hovered(neighbour)) .rgb(0x808080) else .rgb(0x404040) },
        });
        ui.close();
    }
};

fn indexOf(frame: anytype, id: zui.Id, comptime tag: std.meta.Tag(Ui.RenderCommand.Payload)) !usize {
    for (frame.commands(), 0..) |command, index| if (command.id == id.hash and command.payload == tag) return index;
    return error.CommandNotFound;
}

fn pressTab(ui: *Ui, around: Neighbours.Around, events: []const zui.Event) void {
    ui.beginFrame(&recordAt(1));
    Neighbours.declare(ui, around);
    ui.release(ui.endFrame());
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 800, 600 } }, .events = events });
}

test "a sibling declared after a focused control, hovered, draws under its ring" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    const over_neighbour: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 110, 35 }, .at = .zero };
    pressTab(&ui, .nothing, &.{
        .{ .pointer_move = .{ .pointer = over_neighbour } },
        .{ .key_down = .{ .key = .tab, .at = .zero } },
    });
    try testing.expect(ui.focused(Neighbours.control));
    try testing.expect(ui.hovered(Neighbours.neighbour));
    Neighbours.declare(&ui, .nothing);
    const frame = ui.endFrame();
    defer ui.release(frame);

    const ring = try indexOf(frame, Neighbours.control, .border);
    try testing.expect(ring > try indexOf(frame, Neighbours.neighbour, .rectangle));
    try testing.expectEqual(frame.commands().len - 1, ring);
    var rings: usize = 0;
    for (frame.commands()) |command| rings += @intFromBool(command.payload == .border);
    try testing.expectEqual(1, rings);
}

test "a kept ring is drawn inside the clip it was declared in" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    pressTab(&ui, .clip, &.{.{ .key_down = .{ .key = .tab, .at = .zero } }});
    Neighbours.declare(&ui, .clip);
    const frame = ui.endFrame();
    defer ui.release(frame);

    const commands = frame.commands();
    const ring = try indexOf(frame, Neighbours.control, .border);
    try testing.expect(commands[ring - 1].payload == .clip_begin);
    try testing.expect(commands[ring + 1].payload == .clip_end);
    try testing.expectEqual(zui.Rect{ .x = 0, .y = 0, .width = 160, .height = 70 }, commands[ring - 1].payload.clip_begin);
}

test "a kept ring is drawn inside the transforms it was declared in" {
    var ui: Ui = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    pressTab(&ui, .transform, &.{.{ .key_down = .{ .key = .tab, .at = .zero } }});
    Neighbours.declare(&ui, .transform);
    const frame = ui.endFrame();
    defer ui.release(frame);

    const commands = frame.commands();
    const ring = try indexOf(frame, Neighbours.control, .border);
    try testing.expectEqual(zui.Transform{ .translation = .{ 5, 0 } }, commands[ring - 2].payload.transform_begin);
    try testing.expect(commands[ring + 2].payload == .transform_end);
    var begun: i32 = 0;
    for (commands) |command| switch (command.payload) {
        .transform_begin => begun += 1,
        .transform_end => begun -= 1,
        else => {},
    };
    try testing.expectEqual(0, begun);
}

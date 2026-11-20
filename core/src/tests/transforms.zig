const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const TransformUi = zui.Context(.{
    .limits = .{ .max_elements = 32, .max_render_commands = 64 },
    .commands = .initMany(&.{ .transform, .shadow }),
});

const UntransformedUi = zui.Context(.{ .limits = .{ .max_elements = 32, .max_render_commands = 64 } });

const button: zui.Id = .of("button");
const panel: zui.Id = .of("panel");

const quarter_turn: zui.Transform = .{ .rotation = std.math.pi / 2.0 };

fn fixedSize(width: f32, height: f32) zui.Sizing2 {
    return .{ .width = .fixed(width), .height = .fixed(height) };
}

fn expectPoint(expected: [2]f32, found: [2]f32) !void {
    try testing.expectApproxEqAbs(expected[0], found[0], 1e-4);
    try testing.expectApproxEqAbs(expected[1], found[1], 1e-4);
}

fn endChecked(ui: anytype) !@TypeOf(ui.endFrame()) {
    const frame = ui.endFrame();
    ui.release(frame);
    try frame.diagnostics.check();
    return frame;
}

/// Begins each frame with the pointer as sampled, a frame interval after
/// the last.
fn Pointing(comptime Ui: type) type {
    return struct {
        ui: Ui = undefined,
        sampler: zui.InputSampler = .{},
        now: zui.Instant = .zero,
        events: [16]zui.Event = undefined,

        fn begin(self: *@This(), sample: zui.InputSampler.Sample) *Ui {
            self.now = self.now.addNanoseconds(support.frame_interval_ns);
            self.ui.beginFrame(&support.record(self.now, self.sampler.sample(self.now, sample, &self.events)));
            return &self.ui;
        }

        /// Presses and releases at `point` over three frames of `declare`,
        /// and says whether `id` was clicked.
        fn clicks(self: *@This(), comptime declare: anytype, id: zui.Id, point: [2]f32) !bool {
            for ([_]zui.InputSampler.Sample{
                .{ .pointer = point },
                .{ .pointer = point, .buttons = support.primaryDown() },
            }) |sample| {
                declare(self.begin(sample));
                _ = try endChecked(&self.ui);
            }
            const ui = self.begin(.{ .pointer = point });
            const clicked = ui.clicked(id);
            declare(ui);
            _ = try endChecked(ui);
            return clicked;
        }
    };
}

test "a transform scales, then rotates, about its origin, then translates, and its inverse undoes it" {
    const bounds: zui.Rect = .{ .x = 10, .y = 20, .width = 100, .height = 40 };
    const turned = quarter_turn.affine(bounds);
    try expectPoint(.{ 60, 40 }, turned.apply(.{ 60, 40 }));
    try expectPoint(.{ 80, -10 }, turned.apply(.{ 10, 20 }));
    try expectPoint(.{ 40, 90 }, turned.apply(.{ 110, 60 }));

    const moved: zui.Transform = .{ .translation = .{ 5, -5 }, .scale = .{ 2, 0.5 }, .rotation = 0.3, .origin = .{ 0, 1 } };
    const affine = moved.affine(bounds);
    try expectPoint(.{ 15, 55 }, affine.apply(.{ 10, 60 }));
    const inverse = affine.inverse().?;
    for ([_][2]f32{ .{ 0, 0 }, .{ 33, -7 }, .{ 110, 60 } }) |point| try expectPoint(point, inverse.apply(affine.apply(point)));
    try expectPoint(.{ 3, 4 }, inverse.after(affine).apply(.{ 3, 4 }));

    const around = turned.boundsOf(bounds);
    try testing.expectApproxEqAbs(@as(f32, 40), around.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 40), around.width, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 100), around.height, 1e-4);

    try testing.expect((zui.Transform{ .scale = .{ 0, 1 } }).affine(bounds).inverse() == null);
}

fn declareTurnedCard(ui: anytype) void {
    ui.open(.{ .layout = .{ .padding = .all(20) } });
    ui.open(.{
        .id = panel,
        .clip = .both,
        .layout = .{ .sizing = fixedSize(100, 40) },
        .decoration = .{ .background = .white, .border = .{ .color = .black, .widths = .all(1) } },
        .effects = &.{ .transform = quarter_turn, .shadow = .glow(.black, 4) },
    });
    ui.box(.{ .layout = .{ .sizing = fixedSize(20, 20) }, .decoration = .{ .background = .rgb(0xff0000) } });
    ui.close();
    ui.close();
}

test "a transform begins before its element's shadow and ends after its subtree and clip" {
    var ui: TransformUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    declareTurnedCard(&ui);
    const frame = try endChecked(&ui);

    const Tag = std.meta.Tag(TransformUi.RenderCommand.Payload);
    const expected = [_]Tag{ .transform_begin, .shadow, .rectangle, .clip_begin, .rectangle, .border, .clip_end, .transform_end };
    const commands = frame.commands();
    try testing.expectEqual(expected.len, commands.len);
    for (expected, commands) |tag, command| try testing.expectEqual(tag, std.meta.activeTag(command.payload));
    try testing.expectEqual(quarter_turn, commands[0].payload.transform_begin);
    try testing.expectEqual(zui.Rect{ .x = 20, .y = 20, .width = 100, .height = 40 }, commands[0].bounds);
    try testing.expectEqual(zui.Rect{ .x = 20, .y = 20, .width = 100, .height = 40 }, frame.rectOf(panel).?);
    try testing.expect(frame.diagnostics.lowered.count() == 0);
}

test "for a renderer that does not transform, the element is drawn as laid out and the transform is listed as lowered" {
    var ui: UntransformedUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    declareTurnedCard(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    try testing.expect(frame.diagnostics.ok());

    const Tag = std.meta.Tag(UntransformedUi.RenderCommand.Payload);
    const expected = [_]Tag{ .rectangle, .clip_begin, .rectangle, .border, .clip_end };
    const commands = frame.commands();
    try testing.expectEqual(expected.len, commands.len);
    for (expected, commands) |tag, command| try testing.expectEqual(tag, std.meta.activeTag(command.payload));
    try testing.expectEqual(zui.CommandSet.initMany(&.{ .shadow, .transform }), frame.diagnostics.lowered);
}

test "an element laid out outside the clip is drawn when its transform moves it inside" {
    var ui: TransformUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    ui.open(.{ .clip = .both, .layout = .{ .sizing = fixedSize(100, 100) } });
    ui.box(.{ .layout = .{ .sizing = fixedSize(150, 10) } });
    ui.box(.{
        .layout = .{ .sizing = fixedSize(20, 20) },
        .decoration = .{ .background = .white },
        .effects = &.{ .transform = .{ .translation = .{ -100, 0 } } },
    });
    ui.box(.{ .layout = .{ .sizing = fixedSize(20, 20) }, .decoration = .{ .background = .black } });
    ui.close();
    const frame = try endChecked(&ui);

    var drawn: usize = 0;
    for (frame.commands()) |command| if (command.payload == .rectangle) {
        try testing.expectEqual(zui.Color.white, command.payload.rectangle.color);
        drawn += 1;
    };
    try testing.expectEqual(1, drawn);
}

const nudge: zui.Transform = .{ .translation = .{ 5, 5 } };

test "a floating element on another layer begins the transforms around it again there" {
    var ui: TransformUi = try .init(testing.allocator, testing.io);
    defer ui.deinit(testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    ui.open(.{ .layout = .{ .sizing = fixedSize(100, 100) }, .effects = &.{ .transform = .{ .scale = .{ 2, 2 }, .origin = .{ 0, 0 } } } });
    ui.open(.{ .layout = .{ .sizing = fixedSize(50, 50) }, .effects = &.{ .transform = nudge } });
    ui.box(.{ .floating = .{ .z = 1 }, .layout = .{ .sizing = fixedSize(10, 10) }, .decoration = .{ .background = .white } });
    ui.close();
    ui.close();
    const frame = try endChecked(&ui);

    const commands = frame.commands();
    const Tag = std.meta.Tag(TransformUi.RenderCommand.Payload);
    const expected = [_]Tag{ .transform_begin, .transform_begin, .transform_end, .transform_end, .transform_begin, .transform_begin, .rectangle, .transform_end, .transform_end };
    try testing.expectEqual(expected.len, commands.len);
    for (expected, commands) |tag, command| try testing.expectEqual(tag, std.meta.activeTag(command.payload));
    try testing.expectEqual(@as(f32, 2), commands[4].payload.transform_begin.scale[0]);
    try testing.expectEqual(nudge, commands[5].payload.transform_begin);
    try testing.expectEqual(@as(i16, 1), commands[4].z);
}

/// A 100×20 button turned a quarter about its center at (60, 20), so it
/// is drawn standing from (50, -30) to (70, 70).
fn declareTurnedButton(ui: anytype) void {
    ui.open(.{ .layout = .{ .padding = .all(10) } });
    ui.box(.{ .id = button, .interactive = true, .layout = .{ .sizing = fixedSize(100, 20) }, .effects = &.{ .transform = quarter_turn } });
    ui.close();
}

test "a rotated button is clicked where it is drawn, and not where it was laid out" {
    var pointing: Pointing(TransformUi) = .{};
    pointing.ui = try .init(testing.allocator, testing.io);
    defer pointing.ui.deinit(testing.allocator);
    declareTurnedButton(pointing.begin(.{}));
    _ = try endChecked(&pointing.ui);

    try testing.expect(try pointing.clicks(declareTurnedButton, button, .{ 60, 60 }));
    try testing.expect(!try pointing.clicks(declareTurnedButton, button, .{ 20, 20 }));
    try testing.expect(try pointing.clicks(declareTurnedButton, button, .{ 60, 20 }));
}

test "for a renderer that does not transform, a rotated button is clicked where it was laid out" {
    var pointing: Pointing(UntransformedUi) = .{};
    pointing.ui = try .init(testing.allocator, testing.io);
    defer pointing.ui.deinit(testing.allocator);
    declareTurnedButton(pointing.begin(.{}));
    _ = try endChecked(&pointing.ui);

    try testing.expect(!try pointing.clicks(declareTurnedButton, button, .{ 60, 60 }));
    try testing.expect(try pointing.clicks(declareTurnedButton, button, .{ 20, 20 }));
}

/// A 50×50 button in a panel moved 80 right, inside a 100×100 clip, so
/// the clip cuts it off at x = 100.
fn declareMovedButton(ui: anytype) void {
    ui.open(.{ .clip = .both, .layout = .{ .sizing = fixedSize(100, 100) } });
    ui.open(.{ .id = panel, .layout = .{ .sizing = fixedSize(50, 50) }, .effects = &.{ .transform = .{ .translation = .{ 40, 0 } } } });
    ui.box(.{ .id = button, .interactive = true, .layout = .{ .sizing = fixedSize(50, 50) }, .effects = &.{ .transform = .{ .translation = .{ 40, 0 } } } });
    ui.close();
    ui.close();
}

test "a button inside nested transforms is hit through both, and not past the clip around them" {
    var pointing: Pointing(TransformUi) = .{};
    pointing.ui = try .init(testing.allocator, testing.io);
    defer pointing.ui.deinit(testing.allocator);
    declareMovedButton(pointing.begin(.{}));
    _ = try endChecked(&pointing.ui);

    try testing.expect(try pointing.clicks(declareMovedButton, button, .{ 90, 25 }));
    try testing.expect(!try pointing.clicks(declareMovedButton, button, .{ 120, 25 }));
    try testing.expect(!try pointing.clicks(declareMovedButton, button, .{ 30, 25 }));
}

fn declareFlattenedButton(ui: anytype) void {
    ui.open(.{});
    ui.box(.{ .id = button, .interactive = true, .layout = .{ .sizing = fixedSize(50, 50) }, .decoration = .{ .background = .white }, .effects = &.{ .transform = .{ .scale = .{ 0, 1 } } } });
    ui.close();
}

test "an element scaled to nothing draws nothing and is never hit" {
    var pointing: Pointing(TransformUi) = .{};
    pointing.ui = try .init(testing.allocator, testing.io);
    defer pointing.ui.deinit(testing.allocator);
    declareFlattenedButton(pointing.begin(.{}));
    const frame = try endChecked(&pointing.ui);
    for (frame.commands()) |command| try testing.expect(command.payload != .rectangle);

    try testing.expect(!try pointing.clicks(declareFlattenedButton, button, .{ 25, 25 }));
}

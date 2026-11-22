const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

const ghost_limits: zui.Limits = .{
    .max_elements = 64,
    .max_depth = 8,
    .max_text_bytes = 256,
    .max_render_commands = 128,
    .measure_cache_entries = 64,
    .string_cache_entries = 64,
    .exit_ghost_commands = 32,
};

fn GhostUi(comptime limits: zui.Limits, comptime frames_in_flight: u8) type {
    return zui.Context(.{
        .limits = limits,
        .Text = support.FixedMetricsText,
        .frames_in_flight = frames_in_flight,
        .features = .{ .safety_sweeps = true },
    });
}

const ids = zui.ids(.{ "toast", "below", "backdrop", "list", "outer", "inner", "first", "second" });

const red: zui.Color = .rgb(0xff0000);
const blue: zui.Color = .rgb(0x0000ff);

/// Each frame 16 ms after the last, so an exit of 0.064 s lasts four frames.
fn Fixture(comptime Ui: type) type {
    return struct {
        const Self = @This();

        text_contract: support.FixedMetricsText = .{},
        ui: Ui = undefined,
        now: zui.Instant = .zero,

        fn init(self: *Self) !void {
            self.ui = try Ui.init(testing.allocator, testing.io, &self.text_contract);
        }

        fn deinit(self: *Self) void {
            self.ui.deinit(testing.allocator);
        }

        fn begin(self: *Self) *Ui {
            return self.beginEvents(&.{});
        }

        fn beginEvents(self: *Self, events: []const zui.Event) *Ui {
            self.now = self.now.addNanoseconds(support.frame_interval_ns);
            self.ui.beginFrame(&support.record(self.now, events));
            return &self.ui;
        }

        /// Ends the frame and releases it; it stays readable until another
        /// frame begins on its memory.
        fn end(self: *Self) *const Ui.Frame {
            const frame = self.ui.endFrame();
            self.ui.release(frame);
            return frame;
        }
    };
}

fn fixed(width: f32, height: f32) zui.Layout {
    return .{ .sizing = .{ .width = .fixed(width), .height = .fixed(height) } };
}

fn rectangles(frame: anytype, color: zui.Color) usize {
    var count: usize = 0;
    for (frame.commands()) |command| switch (command.payload) {
        .rectangle => |rectangle| if (rectangle.color.r == color.r and rectangle.color.g == color.g and rectangle.color.b == color.b) {
            count += 1;
        },
        else => {},
    };
    return count;
}

fn alphaOf(frame: anytype, color: zui.Color) ?u8 {
    for (frame.commands()) |command| switch (command.payload) {
        .rectangle => |rectangle| if (rectangle.color.r == color.r and rectangle.color.g == color.g and rectangle.color.b == color.b) return rectangle.color.a,
        else => {},
    };
    return null;
}

fn declareToast(ui: anytype, exit: zui.Exit) void {
    ui.box(.{ .id = ids.toast, .layout = fixed(100, 40), .decoration = .{ .background = red }, .exit = exit });
}

test "an element that stops being declared keeps drawing, fading linearly, for its seconds and then not" {
    var fixture: Fixture(GhostUi(ghost_limits, 2)) = .{};
    try fixture.init();
    defer fixture.deinit();

    declareToast(fixture.begin(), .{ .seconds = 0.064 });
    try testing.expectEqual(255, alphaOf(fixture.end(), red));

    for ([_]u8{ 191, 128, 64 }) |alpha| {
        _ = fixture.begin();
        const frame = fixture.end();
        try testing.expectEqual(alpha, alphaOf(frame, red));
        try testing.expectEqual(zui.NextFrame.immediately, fixture.ui.nextFrame());
        try testing.expect(frame.diagnostics.ok());
    }

    _ = fixture.begin();
    const after = fixture.end();
    try testing.expectEqual(0, after.commands().len);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

test "an eased ghost fades by its curve, and one without a fade holds and asks only for the instant it ends" {
    var fixture: Fixture(GhostUi(ghost_limits, 2)) = .{};
    try fixture.init();
    defer fixture.deinit();

    declareToast(fixture.begin(), .{ .seconds = 0.032, .fade = .ease_out });
    _ = fixture.end();
    _ = fixture.begin();
    try testing.expectEqual(32, alphaOf(fixture.end(), red));

    _ = fixture.begin();
    _ = fixture.end();
    declareToast(fixture.begin(), .{ .seconds = 0.032, .fade = .none });
    const declared_at = fixture.now;
    _ = fixture.end();
    _ = fixture.begin();
    try testing.expectEqual(255, alphaOf(fixture.end(), red));
    try testing.expectEqual(zui.NextFrame{ .at = declared_at.addSeconds(@as(f32, 0.032)) }, fixture.ui.nextFrame());
    _ = fixture.begin();
    try testing.expectEqual(null, alphaOf(fixture.end(), red));
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

test "every fade is opaque at the start and gone at the end" {
    inline for (@typeInfo(zui.ExitFade).@"enum".fields) |field| {
        const fade: zui.ExitFade = @enumFromInt(field.value);
        try testing.expectEqual(1, fade.opacityAt(0));
        try testing.expectEqual(if (fade == .none) 1 else 0, fade.opacityAt(1));
    }
    try testing.expectEqual(0.5, zui.ExitFade.linear.opacityAt(0.5));
    try testing.expectEqual(0.875, zui.ExitFade.ease_in.opacityAt(0.5));
    try testing.expectEqual(0.125, zui.ExitFade.ease_out.opacityAt(0.5));
    try testing.expectEqual(0.5, zui.ExitFade.ease_in_out.opacityAt(0.5));
}

test "a ghost takes no space and no hits" {
    var fixture: Fixture(GhostUi(ghost_limits, 2)) = .{};
    try fixture.init();
    defer fixture.deinit();
    const pointer: zui.Event = .{ .pointer_move = .{ .pointer = support.mouse(.{ 20, 20 }) } };

    var ui = fixture.beginEvents(&.{pointer});
    ui.open(.{ .id = ids.backdrop, .interactive = true, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both } });
    ui.box(.{ .id = ids.toast, .interactive = true, .layout = fixed(100, 40), .decoration = .{ .background = red }, .exit = .{ .seconds = 1 } });
    ui.box(.{ .id = ids.below, .layout = fixed(100, 40) });
    ui.close();
    _ = fixture.end();

    ui = fixture.begin();
    try testing.expect(ui.hovered(ids.toast));
    ui.open(.{ .id = ids.backdrop, .interactive = true, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both } });
    ui.box(.{ .id = ids.below, .layout = fixed(100, 40) });
    ui.close();
    const frame = fixture.end();
    try testing.expectEqual(1, rectangles(frame, red));
    try testing.expectEqual(null, frame.rectOf(ids.toast));
    try support.expectRect(frame, ids.below, 0, 0, 100, 40);

    ui = fixture.begin();
    try testing.expect(!ui.hovered(ids.toast));
    try testing.expect(ui.hovered(ids.backdrop));
    _ = fixture.end();
}

test "a ghost's text outlives the frame it came from" {
    var fixture: Fixture(GhostUi(ghost_limits, 1)) = .{};
    try fixture.init();
    defer fixture.deinit();

    var ui = fixture.begin();
    ui.open(.{ .id = ids.toast, .layout = fixed(100, 40), .exit = .{ .seconds = 1 } });
    ui.text("bye", .{});
    ui.close();
    _ = fixture.end();

    ui = fixture.begin();
    ui.text("XXXXXXXX", .{});
    const frame = fixture.end();
    var texts: [2][]const u8 = undefined;
    var count: usize = 0;
    for (frame.commands()) |command| if (command.payload == .text) {
        texts[count] = command.payload.text.content;
        count += 1;
    };
    try testing.expectEqual(2, count);
    try testing.expectEqualStrings("XXXXXXXX", texts[0]);
    try testing.expectEqualStrings("bye", texts[1]);
}

test "a ghost keeps its layer and the clip around it" {
    var fixture: Fixture(GhostUi(ghost_limits, 2)) = .{};
    try fixture.init();
    defer fixture.deinit();

    var ui = fixture.begin();
    ui.open(.{ .id = ids.list, .clip = .vertical, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(100), .height = .fixed(50) } } });
    ui.box(.{ .id = ids.first, .layout = fixed(100, 40), .decoration = .{ .background = blue } });
    ui.box(.{ .id = ids.toast, .layout = fixed(100, 40), .decoration = .{ .background = red }, .exit = .{ .seconds = 1 } });
    ui.close();
    ui.box(.{ .id = ids.outer, .floating = .{ .z = 3 }, .layout = fixed(10, 10), .decoration = .{ .background = blue }, .exit = .{ .seconds = 1 } });
    _ = fixture.end();

    ui = fixture.begin();
    ui.open(.{ .id = ids.list, .clip = .vertical, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(100), .height = .fixed(50) } } });
    ui.box(.{ .id = ids.first, .layout = fixed(100, 40), .decoration = .{ .background = blue } });
    ui.close();
    const frame = fixture.end();
    try testing.expectEqual(null, frame.sweep());

    const commands = frame.commands();
    const ghost = for (commands, 0..) |command, index| {
        if (command.payload == .rectangle and command.payload.rectangle.color.r == 0xff) break index;
    } else return error.GhostNotDrawn;
    try testing.expectEqual(zui.Rect{ .x = 0, .y = 40, .width = 100, .height = 40 }, commands[ghost].bounds);
    try testing.expectEqual(zui.Rect{ .x = 0, .y = 0, .width = 800, .height = 50 }, commands[ghost - 1].payload.clip_begin);
    try testing.expect(commands[ghost + 1].payload == .clip_end);
    try testing.expectEqual(3, commands[commands.len - 1].z);
    try testing.expect(commands[commands.len - 1].payload == .rectangle);
}

test "a ghost inside a transform begins it again, and fades every color it draws" {
    const TransformGhostUi = zui.Context(.{
        .limits = ghost_limits,
        .Text = support.FixedMetricsText,
        .commands = .initMany(&.{ .transform, .gradient }),
        .features = .{ .safety_sweeps = true },
    });
    var fixture: Fixture(TransformGhostUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const moved: TransformGhostUi.Effects = .{ .transform = .{ .translation = .{ 10, 0 } } };
    const shaded: TransformGhostUi.Effects = .{ .gradient = .{ .from = red, .to = blue } };

    var ui = fixture.begin();
    ui.open(.{ .id = ids.backdrop, .effects = &moved, .layout = fixed(200, 200) });
    ui.box(.{ .id = ids.toast, .effects = &shaded, .layout = fixed(100, 40), .exit = .{ .seconds = 0.032 } });
    ui.close();
    _ = fixture.end();

    ui = fixture.begin();
    ui.box(.{ .id = ids.backdrop, .effects = &moved, .layout = fixed(200, 200) });
    const frame = fixture.end();
    try testing.expectEqual(null, frame.sweep());
    const commands = frame.commands();
    const ghost = commands[commands.len - 5 ..];
    try testing.expectEqual(zui.Transform{ .translation = .{ 10, 0 } }, ghost[0].payload.transform_begin);
    try testing.expect(ghost[1].payload == .clip_begin);
    try testing.expectEqual(128, ghost[2].payload.gradient.from.a);
    try testing.expectEqual(128, ghost[2].payload.gradient.to.a);
    try testing.expect(ghost[3].payload == .clip_end);
    try testing.expect(ghost[4].payload == .transform_end);
}

test "an exiting element inside another that exits with it is drawn once" {
    var fixture: Fixture(GhostUi(ghost_limits, 2)) = .{};
    try fixture.init();
    defer fixture.deinit();

    var ui = fixture.begin();
    ui.open(.{ .id = ids.outer, .layout = fixed(100, 100), .decoration = .{ .background = blue }, .exit = .{ .seconds = 1 } });
    ui.box(.{ .id = ids.inner, .layout = fixed(50, 50), .decoration = .{ .background = red }, .exit = .{ .seconds = 1 } });
    ui.close();
    _ = fixture.end();

    _ = fixture.begin();
    const frame = fixture.end();
    try testing.expectEqual(1, rectangles(frame, blue));
    try testing.expectEqual(1, rectangles(frame, red));
}

test "a ghost is dropped when its element is declared again" {
    var fixture: Fixture(GhostUi(ghost_limits, 2)) = .{};
    try fixture.init();
    defer fixture.deinit();

    declareToast(fixture.begin(), .{ .seconds = 1 });
    _ = fixture.end();
    _ = fixture.begin();
    try testing.expectEqual(1, rectangles(fixture.end(), red));
    declareToast(fixture.begin(), .{ .seconds = 1 });
    const frame = fixture.end();
    try testing.expectEqual(1, rectangles(frame, red));
    try testing.expectEqual(255, alphaOf(frame, red));
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

test "reduced motion drops every ghost at once and keeps none" {
    var fixture: Fixture(GhostUi(ghost_limits, 2)) = .{};
    try fixture.init();
    defer fixture.deinit();

    declareToast(fixture.begin(), .{ .seconds = 1 });
    _ = fixture.end();
    _ = fixture.begin();
    try testing.expectEqual(1, rectangles(fixture.end(), red));

    _ = fixture.beginEvents(&.{.{ .environment = .{ .reduced_motion = true } }});
    try testing.expectEqual(0, fixture.end().commands().len);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());

    declareToast(fixture.begin(), .{ .seconds = 1 });
    _ = fixture.end();
    _ = fixture.begin();
    try testing.expectEqual(0, fixture.end().commands().len);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

test "a full ghost store keeps what fits and reports the limit" {
    const limits = comptime limits: {
        var limits = ghost_limits;
        limits.exit_ghost_commands = 4;
        break :limits limits;
    };
    var fixture: Fixture(GhostUi(limits, 2)) = .{};
    try fixture.init();
    defer fixture.deinit();

    var ui = fixture.begin();
    ui.box(.{ .id = ids.first, .layout = fixed(10, 10), .decoration = .{ .background = red }, .exit = .{ .seconds = 1 } });
    ui.box(.{ .id = ids.second, .layout = fixed(10, 10), .decoration = .{ .background = blue }, .exit = .{ .seconds = 1 } });
    const declared = fixture.end();
    try testing.expect(declared.diagnostics.exceeded.contains(.exit_ghost_commands));
    try testing.expectEqual(6, declared.diagnostics.needed.get(.exit_ghost_commands));
    try testing.expectEqual(ids.second.hash, declared.diagnostics.first_dropped_id);

    _ = fixture.begin();
    const frame = fixture.end();
    try testing.expectEqual(1, rectangles(frame, red));
    try testing.expectEqual(0, rectangles(frame, blue));
    try testing.expect(frame.diagnostics.ok());
}

test "a ghost whose text does not fit the store is not kept, and is reported" {
    const limits = comptime limits: {
        var limits = ghost_limits;
        limits.max_text_bytes = 8;
        break :limits limits;
    };
    var fixture: Fixture(GhostUi(limits, 2)) = .{};
    try fixture.init();
    defer fixture.deinit();

    var ui = fixture.begin();
    ui.open(.{ .id = ids.first, .layout = fixed(100, 20), .exit = .{ .seconds = 1 } });
    ui.text("abcdefgh", .{});
    ui.close();
    _ = fixture.end();

    ui = fixture.begin();
    ui.open(.{ .id = ids.second, .layout = fixed(100, 20), .exit = .{ .seconds = 1 } });
    ui.text("12345678", .{});
    ui.close();
    const frame = fixture.end();
    try testing.expect(frame.diagnostics.exceeded.contains(.exit_ghost_commands));
    try testing.expectEqual(ids.first.hash, frame.diagnostics.first_dropped_id);
    for (frame.commands()) |command| if (command.payload == .text) try testing.expectEqualStrings("12345678", command.payload.text.content);
}

test "exit is ignored while exit_ghost_commands is 0" {
    var fixture: Fixture(GhostUi(.{ .max_elements = 16, .max_depth = 4, .max_render_commands = 16, .measure_cache_entries = 16, .string_cache_entries = 16 }, 2)) = .{};
    try fixture.init();
    defer fixture.deinit();
    try testing.expectEqual(0, @sizeOf(@TypeOf(fixture.ui).ExitGhosts));

    declareToast(fixture.begin(), .{ .seconds = 1 });
    try testing.expectEqual(1, rectangles(fixture.end(), red));
    _ = fixture.begin();
    try testing.expectEqual(0, fixture.end().commands().len);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

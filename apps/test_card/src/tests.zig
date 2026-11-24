const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_design = @import("zui_design");
const zui_glyphs = @import("zui_glyphs");
const zui_truetype = @import("zui_truetype");
const test_card = @import("zui_test_card");

const testing = std.testing;
const io = if (builtin.os.tag == .freestanding) std.Io.failing else testing.io;
const cells: zui_glyphs.Placement = .{ .cells = .{ 8, 16 } };

/// Draws nothing, and declares that it draws every optional command and
/// corner shape, or none of them but round corners, in `placement`.
fn FakeRenderer(comptime draws_every_command: bool, comptime placement: zui_glyphs.Placement) type {
    return struct {
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const zui_commands: zui.CommandSet = if (draws_every_command) .initFull() else .initEmpty();
        pub const zui_corner_shapes: zui.CornerShapeSet = if (draws_every_command) .initFull() else .initOne(.round);
        pub const MaterialHandle = if (draws_every_command) FlatMaterial else void;
        pub const glyph_placement = placement;

        clear_color: zui.Color = .black,

        pub fn zuiSubmit(_: *@This(), _: zui.Surface, _: anytype) !void {}
    };
}

/// A renderer's own material, which the card never draws.
const FlatMaterial = struct { color: zui.Color };

const renderers = .{
    FakeRenderer(true, .pixel_grid),
    FakeRenderer(false, .pixel_grid),
    FakeRenderer(true, cells),
    FakeRenderer(false, cells),
};

/// The card without a host: its text measures, and nothing is drawn.
fn Harness(comptime Renderer: type) type {
    return struct {
        const Self = @This();
        const Text = test_card.Text(zui_truetype.Text, Renderer);
        const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .Text = Text }));
        const CardOnUi = test_card.Card(Ui);

        text: Text = .{},
        ui: Ui = undefined,
        tokens: CardOnUi.Tokens = .{},
        card: CardOnUi = undefined,
        events: [64]zui.Event = undefined,
        text_bytes: [256]u8 = undefined,
        builder: zui.RecordBuilder = undefined,

        fn init(harness: *Self) !void {
            try harness.text.init();
            harness.ui = try .init(testing.allocator, io, &harness.text);
            CardOnUi.resolveTokens(&harness.tokens, harness.text.fonts);
            harness.card.init(&harness.tokens, .{
                .renderer_name = "a fake renderer",
                .host_name = "no host",
                .fonts_fingerprint = harness.text.zuiFingerprint(),
                .placement = zui_glyphs.placementOf(Renderer),
            });
            harness.builder = .init(&harness.events, &harness.text_bytes);
        }

        fn deinit(harness: *Self) void {
            harness.ui.deinit(testing.allocator);
            harness.text.deinit();
        }

        fn frame(harness: *Self, scene: test_card.Scene, next: test_card.Scene) *const Ui.Frame {
            return harness.card.declareWithoutHost(&harness.ui, &harness.builder, scene, next);
        }

        /// `scene` held for the frames it takes to settle; the caller
        /// releases the last.
        fn heldFrame(harness: *Self, scene: test_card.Scene) *const Ui.Frame {
            for (1..test_card.settling_frames) |_| harness.ui.release(harness.frame(scene, scene));
            return harness.frame(scene, scene);
        }

        fn expectSceneState(harness: *Self, scene: test_card.Scene, drawn: *const Ui.Frame) !void {
            const ui = &harness.ui;
            try testing.expect(drawn.diagnostics.ok());
            try testing.expectEqual(scene == .hovered, ui.hovered(test_card.ids.button) and !ui.pressed(test_card.ids.button));
            try testing.expectEqual(scene == .pressed, ui.pressed(test_card.ids.button));
            try testing.expectEqual(scene == .focused, ui.focused(test_card.ids.tooltip_anchor));
            try testing.expectEqual(scene == .focused, drawn.rectOf(test_card.ids.tooltip_anchor.child("tooltip")) != null);
            try testing.expectEqual(scene == .dialog, drawn.rectOf(test_card.ids.dialog.child("panel")) != null);
            if (scene != .focused and scene != .pressed) try testing.expect(ui.focusedId().isNone());
            try testing.expectEqual(@as(f32, if (scene == .scrolled) 52 else 20), ui.scrollOffset(test_card.ids.scroll_box)[1]);
        }

        fn expectEverySceneInTurnThenHeld() !void {
            var harness: Self = .{};
            try harness.init();
            defer harness.deinit();
            for (0..2 * test_card.Scene.count) |index| {
                const scene: test_card.Scene = .inTurn(index);
                const drawn = harness.frame(scene, .inTurn(index + 1));
                defer harness.ui.release(drawn);
                try harness.expectSceneState(scene, drawn);
            }
            try testing.expectEqual(test_card.Values{}, harness.card.values);
            try testing.expectEqualStrings("zui", harness.card.field.slice());

            for (std.enums.values(test_card.Scene)) |scene| {
                var held: Self = .{};
                try held.init();
                defer held.deinit();
                const drawn = held.heldFrame(scene);
                defer held.ui.release(drawn);
                try held.expectSceneState(scene, drawn);
            }
        }

        const expected_regions = [_]struct { test_card.Region, zui.Rect }{
            .{ .identity, .{ .x = 0, .y = 0, .width = 640, .height = 32 } },
            .{ .swatches, .{ .x = 0, .y = 32, .width = 640, .height = 64 } },
            .{ .text, .{ .x = 0, .y = 96, .width = 320, .height = 208 } },
            .{ .geometry, .{ .x = 0, .y = 304, .width = 320, .height = 80 } },
            .{ .clip_and_scroll, .{ .x = 320, .y = 96, .width = 320, .height = 96 } },
            .{ .layers, .{ .x = 320, .y = 192, .width = 320, .height = 96 } },
            .{ .controls, .{ .x = 320, .y = 288, .width = 320, .height = 96 } },
        };

        fn expectRegionsWhereTheyBelong() !void {
            var harness: Self = .{};
            try harness.init();
            defer harness.deinit();
            for (std.enums.values(test_card.Scene)) |scene| {
                const drawn = harness.heldFrame(scene);
                defer harness.ui.release(drawn);
                try testing.expectEqual(zui.Rect{ .width = test_card.size[0], .height = test_card.size[1] }, drawn.rectOf(test_card.ids.card).?);
                for (expected_regions) |expected| {
                    const region_id = expected[0].id();
                    try testing.expectEqual(expected[1], drawn.rectOf(region_id).?);
                    const content = drawn.content_size[drawn.lookup(region_id.hash).?];
                    if (content[0] > expected[1].width or content[1] > expected[1].height) {
                        std.debug.print("{t}: content {d}x{d} in {d}x{d}\n", .{ expected[0], content[0], content[1], expected[1].width, expected[1].height });
                        return error.TestUnexpectedResult;
                    }
                }
            }
        }

        fn expectEverySceneAlikeInTurnAndHeld() !void {
            var in_turn: Self = .{};
            try in_turn.init();
            defer in_turn.deinit();
            for (0..test_card.Scene.count) |index| {
                const scene: test_card.Scene = .inTurn(index);
                var held: Self = .{};
                try held.init();
                defer held.deinit();
                const drawn_held = held.heldFrame(scene);
                defer held.ui.release(drawn_held);
                const drawn_in_turn = in_turn.frame(scene, .inTurn(index + 1));
                defer in_turn.ui.release(drawn_in_turn);
                try expectSameCommands(scene, drawn_held, drawn_in_turn);
            }
        }

        fn expectEverySceneToAuditClean() !void {
            var harness: Self = .{};
            try harness.init();
            defer harness.deinit();
            var room: [64]zui_design.Finding = undefined;
            var finding_count: usize = 0;
            for (std.enums.values(test_card.Scene)) |scene| {
                const drawn = harness.heldFrame(scene);
                defer harness.ui.release(drawn);
                const findings = zui_design.audit(drawn, .{
                    .checks = .initMany(&.{ .text_contrast, .focus_ring_contrast }),
                    .page_background = harness.card.background(),
                    .focus_ring_color = harness.tokens.colors.get(.focused).get(.focus),
                }, &room);
                try testing.expectEqual(0, findings.dropped);
                for (findings.slice()) |finding| std.debug.print("{t}: {any}\n", .{ scene, finding });
                finding_count += findings.slice().len;
            }
            try testing.expectEqual(0, finding_count);
        }
    };
}

fn expectSameCommands(scene: test_card.Scene, expected: anytype, actual: anytype) !void {
    const expected_commands = expected.commands();
    const actual_commands = actual.commands();
    var expected_line: [4096]u8 = undefined;
    var actual_line: [4096]u8 = undefined;
    for (expected_commands[0..@min(expected_commands.len, actual_commands.len)], actual_commands[0..@min(expected_commands.len, actual_commands.len)], 0..) |expected_command, actual_command, index| {
        const expected_text = try std.fmt.bufPrint(&expected_line, "{any}", .{expected_command});
        const actual_text = try std.fmt.bufPrint(&actual_line, "{any}", .{actual_command});
        if (!std.mem.eql(u8, expected_text, actual_text)) {
            std.debug.print("{t}, command {d}:\n  held:    {s}\n  in turn: {s}\n", .{ scene, index, expected_text, actual_text });
            return error.TestExpectedEqual;
        }
    }
    try testing.expectEqual(expected_commands.len, actual_commands.len);
}

test "every scene declares within its limits, in turn and held, on renderers that draw every command and none, in pixels and in cells" {
    inline for (renderers) |Renderer| try Harness(Renderer).expectEverySceneInTurnThenHeld();
}

test "each region is where the card puts it, its content inside it, in every scene" {
    inline for (renderers) |Renderer| try Harness(Renderer).expectRegionsWhereTheyBelong();
}

test "a scene drawn in turn, after the one before it, is the scene held" {
    inline for (renderers) |Renderer| try Harness(Renderer).expectEverySceneAlikeInTurnAndHeld();
}

test "every scene's text and focus ring meet their contrast targets" {
    inline for (renderers) |Renderer| try Harness(Renderer).expectEverySceneToAuditClean();
}

test "every color role has a swatch label of its own" {
    const roles = std.enums.values(zui.design.ColorRole);
    for (roles, 0..) |role, index| {
        try testing.expect(test_card.swatchCode(role).len <= 4);
        for (roles[index + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, test_card.swatchCode(role), test_card.swatchCode(other)));
    }
}

test "the card's options are its flags" {
    const options = try test_card.Options.parse(&.{ "test-card", "--scene", "dialog", "--frames", "6", "--hidden" });
    try testing.expectEqual(test_card.Scene.dialog, options.scene);
    try testing.expectEqual(6, options.frame_limit);
    try testing.expect(options.hidden);
    try testing.expectEqual(test_card.Scene.dialog, options.sceneOf(4));
    const in_turn = try test_card.Options.parse(&.{ "test-card", "--frames", "6" });
    for (std.enums.values(test_card.Scene), 0..) |scene, index| try testing.expectEqual(scene, in_turn.sceneOf(index));
    try testing.expectEqual(test_card.Scene.rest, (test_card.Options{}).sceneOf(4));
    try testing.expectError(error.UnknownScene, test_card.Options.parse(&.{ "test-card", "--scene", "sideways" }));
    try testing.expectError(error.UnknownArgument, test_card.Options.parse(&.{ "test-card", "--dump" }));
}

/// Opens a window of the card's size that closes after five frames, and
/// hands the card a pointer and a key of its own, which it ignores.
const TestHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    polls: u32 = 0,

    pub fn init(_: *TestHost, _: std.Io, _: zui.WindowOptions) !void {}

    pub fn deinit(_: *TestHost) void {}

    pub fn zuiPoll(self: *TestHost, _: zui.WindowId, record: *zui.RecordBuilder) bool {
        if (self.polls == 5) return false;
        self.polls += 1;
        const at: zui.Instant = .fromNanoseconds(self.polls * 7 * std.time.ns_per_ms);
        record.begin(.{ .now = at, .viewport = .{ 1280, 720 } });
        record.append(.{ .key_down = .{ .key = .tab, .at = at } });
        record.append(.{ .pointer_move = .{ .pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ 400, 330 }, .at = at } } });
        return true;
    }

    pub fn zuiWaker(self: *TestHost) zui.Waker {
        return .{ .context = self, .wakeFn = ignoreWake };
    }

    pub fn zuiWait(_: *TestHost, _: zui.NextFrame) void {}

    pub fn zuiSurface(_: *TestHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 1280, 720 }, .format = .sdr } };
    }

    pub fn zuiApply(_: *TestHost, _: zui.WindowId, _: zui.HostRequests) void {}

    fn ignoreWake(_: *anyopaque) void {}
};

fn ignoreNotice(_: zui_app.Notice) void {}

test "a target runs the card through zui_app at its own size, ignoring the host's input" {
    if (builtin.os.tag == .freestanding) return error.SkipZigTest;
    inline for (.{ FakeRenderer(true, .pixel_grid), FakeRenderer(false, cells) }) |Renderer| {
        const App = test_card.App(.{ .Host = TestHost, .Renderer = Renderer, .Text = zui_truetype.Text, .renderer_name = "a fake renderer" });
        var session: zui_app.Session(App) = undefined;
        try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = ignoreNotice });
        defer session.stop();
        while (try session.frame()) {}
        try testing.expectEqual(5, session.app.frames);
        try testing.expect(session.app.diagnostics_ok);
        try testing.expectEqual(zui.Rect{ .width = test_card.size[0], .height = test_card.size[1] }, session.ui.rectOf(test_card.ids.card).?);
        try testing.expectEqual(session.app.card.background(), session.renderer.clear_color);
        try testing.expect(session.ui.focusedId().isNone());
        try testing.expect(!session.ui.hovered(test_card.ids.button));
    }
}

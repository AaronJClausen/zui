const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_design = @import("zui_design");
const zui_glyphs = @import("zui_glyphs");
const zui_testing = @import("zui_testing");
const zui_truetype = @import("zui_truetype");
const tour = @import("zui_tour");

const testing = std.testing;

/// The window the tour opens with.
const default_window: [2]f32 = .{ 1440, 900 };
const cells: zui_glyphs.Placement = .{ .cells = .{ 8, 16 } };

/// A pattern between two colors, as a renderer's `MaterialHandle` offers
/// the materials screen one.
const PatternMaterial = struct {
    pattern: Pattern = .flat,
    first: zui.Color,
    second: zui.Color = .transparent,
    phase: f32 = 0,
    scale: f32 = 48,

    pub const Pattern = enum { flat, stripes };
};

/// Draws nothing, and declares that it draws every optional command and
/// corner shape, or none of them but round corners, in `placement`.
fn FakeRenderer(comptime draws_every_command: bool, comptime placement: zui_glyphs.Placement) type {
    return struct {
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const zui_commands: zui.CommandSet = if (draws_every_command) .initFull() else .initEmpty();
        pub const zui_corner_shapes: zui.CornerShapeSet = if (draws_every_command) .initFull() else .initOne(.round);
        pub const MaterialHandle = if (draws_every_command) PatternMaterial else void;
        pub const glyph_placement = placement;

        clear_color: zui.Color = .black,

        pub fn zuiSubmit(_: *@This(), _: zui.Surface, _: anytype) !void {}
    };
}

fn KitFor(comptime Renderer: type) type {
    return tour.Kit(.{ .Renderer = Renderer, .FontSystem = zui_truetype.Text, .inspector = true, .renderer_name = "a fake renderer" });
}

/// The tour without a window: its text measures, and nothing is drawn.
fn Harness(comptime kit: type) type {
    return struct {
        const Self = @This();
        const Ui = kit.Ui;

        text: kit.Text = .{},
        ui: Ui = undefined,
        tour: *tour.Tour(kit) = undefined,
        frame_number: u64 = 0,

        fn init(harness: *Self) !void {
            try harness.text.init();
            harness.ui = try .init(testing.allocator, testing.io, &harness.text);
            harness.tour = try testing.allocator.create(tour.Tour(kit));
            harness.tour.init(testing.io, .zero, harness.text.fonts);
        }

        fn deinit(harness: *Self) void {
            harness.tour.deinit();
            testing.allocator.destroy(harness.tour);
            harness.ui.deinit(testing.allocator);
        }

        fn frame(harness: *Self, viewport: [2]f32) *const Ui.Frame {
            return harness.frameWith(viewport, &.{});
        }

        fn frameWith(harness: *Self, viewport: [2]f32, input: []const zui.Event) *const Ui.Frame {
            harness.frame_number += 1;
            var events: [16]zui.Event = undefined;
            @memcpy(events[0..input.len], input);
            var event_count: usize = input.len;
            for (harness.tour.environment_changes.drain()) |change| {
                events[event_count] = .{ .environment = change };
                event_count += 1;
            }
            const params: zui.FrameParams = .{ .now = .fromNanoseconds(harness.frame_number * std.time.ns_per_s / 60), .viewport = viewport };
            harness.ui.beginFrame(&.{ .params = params, .events = events[0..event_count] }, &harness.tour.sources);
            harness.tour.declare(&harness.ui);
            const result = harness.ui.endFrame();
            harness.tour.observe(&harness.ui, result);
            harness.tour.afterFrame(&harness.ui);
            return result;
        }

        /// A mouse click on the center of `element_id` as the last frame
        /// placed it, then a frame for the click's effect to show in.
        fn click(harness: *Self, element_id: zui.Id) !void {
            const placed = harness.frame(default_window);
            const rect = placed.rectOf(element_id) orelse return error.NotPlaced;
            harness.ui.release(placed);
            const pointer: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ rect.x + rect.width / 2, rect.y + rect.height / 2 }, .at = .fromNanoseconds(harness.frame_number * std.time.ns_per_s / 60) };
            harness.ui.release(harness.frameWith(default_window, &.{
                .{ .pointer_move = .{ .pointer = pointer } },
                .{ .pointer_down = .{ .pointer = pointer } },
                .{ .pointer_up = .{ .pointer = pointer } },
            }));
            harness.ui.release(harness.frame(default_window));
        }

        fn pressKey(harness: *Self, key: zui.Key) void {
            const at: zui.Instant = .fromNanoseconds(harness.frame_number * std.time.ns_per_s / 60);
            harness.ui.release(harness.frameWith(default_window, &.{ .{ .key_down = .{ .key = key, .at = at } }, .{ .key_up = .{ .key = key, .at = at } } }));
            harness.ui.release(harness.frame(default_window));
        }

        fn settledFrame(harness: *Self, screen: tour.Screen, viewport: [2]f32) *const Ui.Frame {
            harness.tour.show(screen);
            for (0..3) |_| harness.ui.release(harness.frame(viewport));
            return harness.frame(viewport);
        }

        /// Lines of text that run past the right edge of the stage, the
        /// area every screen lays out in. Text cut off by a clip deeper
        /// inside a screen, like the marquee's, is deliberate and not counted.
        fn textPastStage(frame_to_check: *const Ui.Frame) u32 {
            const stage = frame_to_check.rectOf(tour.stage_id).?;
            var clip_depth: usize = 0;
            var cut_off: u32 = 0;
            for (frame_to_check.commands()) |command| switch (command.payload) {
                .clip_begin => clip_depth += 1,
                .clip_end => clip_depth -= 1,
                .text => {
                    const inside_stage_clip_only = clip_depth == 1;
                    if (inside_stage_clip_only and command.bounds.x + command.bounds.width > stage.x + stage.width + 1) cut_off += 1;
                },
                else => {},
            };
            return cut_off;
        }

        /// How far the screen's content reaches past the stage that scrolls it.
        fn stageOverflow(frame_to_check: *const Ui.Frame) [2]f32 {
            const stage = frame_to_check.rectOf(tour.stage_id).?;
            const content = frame_to_check.content_size[frame_to_check.lookup(tour.stage_id.hash).?];
            return .{ @max(0, content[0] - stage.width), @max(0, content[1] - stage.height) };
        }

        /// `screen` in `theme`, settled, with Tab pressed so the first
        /// control is focused and shows its ring; the caller releases it.
        /// The first frame takes the theme the tour asks for when it starts,
        /// so `theme` is given after it.
        fn frameToAudit(harness: *Self, screen: tour.Screen, theme: zui.Environment.Theme) *const Ui.Frame {
            harness.tour.show(screen);
            harness.ui.release(harness.frame(default_window));
            harness.ui.release(harness.frameWith(default_window, &.{.{ .environment = .{ .theme = theme } }}));
            for (0..30) |_| harness.ui.release(harness.frame(default_window));
            const tab: zui.Event = .{ .key_down = .{ .key = .tab, .at = .zero } };
            harness.ui.release(harness.frameWith(default_window, &.{tab}));
            return harness.frame(default_window);
        }

        /// `screen` settled with the preferences menu open, pinned or not;
        /// the caller releases it.
        fn frameWithMenu(harness: *Self, screen: tour.Screen, pinned: bool, viewport: [2]f32) *const Ui.Frame {
            harness.tour.show(screen);
            harness.tour.preferences_menu.open = true;
            harness.tour.preferences_menu.pinned = pinned;
            for (0..30) |_| harness.ui.release(harness.frame(viewport));
            return harness.frame(viewport);
        }

        /// The menu lies inside the window, and every element in it inside
        /// the menu's width.
        fn expectMenuFits(frame_to_check: *const Ui.Frame, viewport: [2]f32) !void {
            const panel_id = tour.preferences_menu_id.child("panel");
            const panel = frame_to_check.rectOf(panel_id).?;
            try testing.expect(panel.x >= 0 and panel.y >= 0);
            try testing.expect(panel.x + panel.width <= viewport[0] + 0.01 and panel.y + panel.height <= viewport[1] + 0.01);
            const panel_index = frame_to_check.lookup(panel_id.hash).?;
            for (panel_index..frame_to_check.inspect(panel_index).subtree_end) |index| {
                const inside = frame_to_check.inspect(@intCast(index)).rect;
                if (inside.width == 0) continue;
                try testing.expect(inside.x >= panel.x - 0.01 and inside.x + inside.width <= panel.x + panel.width + 0.01);
            }
            const settings = frame_to_check.rectOf(tour.preferences_settings_id).?;
            try testing.expect(frame_to_check.rectOf(tour.preferences_settings_id.child("content")).?.width <= settings.width + 0.01);
        }

        fn expectTheMenuFitsOnEveryScreen() !void {
            var harness: Self = .{};
            try harness.init();
            defer harness.deinit();
            for ([_][2]f32{ default_window, .{ 1100, 700 } }) |viewport| {
                for (kit.offered_screens) |screen| {
                    for ([_]bool{ false, true }) |pinned| {
                        const opened = harness.frameWithMenu(screen, pinned, viewport);
                        defer harness.ui.release(opened);
                        try testing.expect(opened.diagnostics.ok());
                        try expectMenuFits(opened, viewport);
                    }
                }
            }
        }

        fn expectEveryScreenWithinLimits() !void {
            var harness: Self = .{};
            try harness.init();
            defer harness.deinit();
            for ([_][2]f32{ default_window, .{ 1100, 700 } }) |viewport| {
                for (kit.offered_screens) |screen| {
                    const settled = harness.settledFrame(screen, viewport);
                    defer harness.ui.release(settled);
                    try testing.expectEqual(screen, harness.tour.current);
                    try testing.expect(settled.diagnostics.ok());
                    try testing.expect(settled.elementCount() > 20);
                }
            }
        }

        fn expectEveryScreenFitsTheDefaultWindow() !void {
            var harness: Self = .{};
            try harness.init();
            defer harness.deinit();
            for (kit.offered_screens) |screen| {
                const settled = harness.settledFrame(screen, default_window);
                defer harness.ui.release(settled);
                const root = settled.rectOf(tour.root_id).?;
                try testing.expect(root.width <= default_window[0] and root.height <= default_window[1]);
                try testing.expectEqual([2]f32{ 0, 0 }, stageOverflow(settled));
                try testing.expectEqual(@as(u32, 0), textPastStage(settled));
            }
        }
    };
}

const renderers = .{
    FakeRenderer(true, .pixel_grid),
    FakeRenderer(false, .pixel_grid),
    FakeRenderer(true, cells),
    FakeRenderer(false, cells),
};

test "every screen a renderer is offered declares within its limits, in the default window and a small one" {
    inline for (renderers) |Renderer| try Harness(KitFor(Renderer)).expectEveryScreenWithinLimits();
}

test "every screen a renderer is offered fits the default window: no scrolling, no text cut off" {
    inline for (renderers) |Renderer| try Harness(KitFor(Renderer)).expectEveryScreenFitsTheDefaultWindow();
}

fn printFinding(theme: zui.Environment.Theme, screen: tour.Screen, finding: zui_design.Finding) void {
    switch (finding.measured) {
        .text_contrast => |text| std.debug.print("{t} {t}: element {?d}, text #{x:0>2}{x:0>2}{x:0>2} on #{x:0>2}{x:0>2}{x:0>2}, Lc {d:.1} and {d:.2}:1\n", .{
            theme,                            screen,              finding.element,
            text.foreground.r,                text.foreground.g,   text.foreground.b,
            text.background.r,                text.background.g,   text.background.b,
            text.measured.lightness_contrast, text.measured.ratio,
        }),
        .target_size => |size| std.debug.print("{t} {t}: element {?d}, a target {d:.1} by {d:.1}, under {d}\n", .{ theme, screen, finding.element, size.size[0], size.size[1], size.floor }),
        else => std.debug.print("{t} {t}: {any}\n", .{ theme, screen, finding }),
    }
}

test "every screen audits clean, in light and dark, after Tab focuses a control" {
    const kit = KitFor(FakeRenderer(true, .pixel_grid));
    var harness: Harness(kit) = .{};
    try harness.init();
    defer harness.deinit();
    const room = try testing.allocator.alloc(zui_design.Finding, 1024);
    defer testing.allocator.free(room);
    var finding_count: usize = 0;
    for ([_]zui.Environment.Theme{ .light, .dark }) |theme| {
        for (kit.offered_screens) |screen| {
            const audited = harness.frameToAudit(screen, theme);
            defer harness.ui.release(audited);
            try testing.expectEqual(theme, harness.ui.environment().theme);
            const tokens = &harness.tour.appearance.tokens;
            const findings = zui_design.audit(audited, .{ .page_background = tokens.colors.get(.idle).get(.background), .focus_ring_color = tokens.colors.get(.focused).get(.focus) }, room);
            try testing.expectEqual(0, findings.dropped);
            for (findings.slice()) |finding| printFinding(theme, screen, finding);
            finding_count += findings.slice().len;
        }
    }
    try testing.expectEqual(0, finding_count);
}

test "the preferences menu opens on every screen, pinned and not, within its limits and inside the window, in pixels and in cells" {
    inline for (renderers) |Renderer| try Harness(KitFor(Renderer)).expectTheMenuFitsOnEveryScreen();
}

test "the preferences menu audits clean over every screen, pinned and not, in light and dark" {
    const kit = KitFor(FakeRenderer(true, .pixel_grid));
    var harness: Harness(kit) = .{};
    try harness.init();
    defer harness.deinit();
    const room = try testing.allocator.alloc(zui_design.Finding, 1024);
    defer testing.allocator.free(room);
    var finding_count: usize = 0;
    for ([_]zui.Environment.Theme{ .light, .dark }) |theme| {
        for (kit.offered_screens) |screen| {
            for ([_]bool{ false, true }) |pinned| {
                harness.tour.preferences_menu.open = true;
                harness.tour.preferences_menu.pinned = pinned;
                const audited = harness.frameToAudit(screen, theme);
                defer harness.ui.release(audited);
                try testing.expect(audited.rectOf(tour.preferences_menu_id.child("panel")) != null);
                const tokens = &harness.tour.appearance.tokens;
                const findings = zui_design.audit(audited, .{ .page_background = tokens.colors.get(.idle).get(.background), .focus_ring_color = tokens.colors.get(.focused).get(.focus) }, room);
                try testing.expectEqual(0, findings.dropped);
                for (findings.slice()) |finding| printFinding(theme, screen, finding);
                finding_count += findings.slice().len;
            }
        }
    }
    try testing.expectEqual(0, finding_count);
}

/// The tour as `zui_testing.Driver` runs it, in the default window.
fn Driven(comptime kit: type) type {
    return struct {
        const Self = @This();
        const Tour = tour.Tour(kit);

        text: kit.Text = .{},
        ui: kit.Ui = undefined,
        tour: *Tour = undefined,
        driver: zui_testing.Driver(kit.Ui) = undefined,

        fn init(driven: *Self) !void {
            try driven.text.init();
            driven.ui = try .init(testing.allocator, testing.io, &driven.text);
            driven.tour = try testing.allocator.create(Tour);
            driven.tour.init(testing.io, .zero, driven.text.fonts);
            driven.driver = .{ .ui = &driven.ui, .sources = &driven.tour.sources, .viewport = default_window };
        }

        fn deinit(driven: *Self) void {
            driven.tour.deinit();
            testing.allocator.destroy(driven.tour);
            driven.ui.deinit(testing.allocator);
        }

        fn frames(driven: *Self, count: usize) !void {
            for (0..count) |_| _ = try driven.driver.frame(driven.tour, Tour.declare, &.{});
        }

        fn press(driven: *Self, keys: []const zui.Key) !void {
            _ = try driven.driver.pressKeys(driven.tour, Tour.declare, keys);
            try driven.frames(1);
        }

        fn chord(driven: *Self, key: zui.Key) !void {
            driven.driver.modifiers = .{ .control = true };
            defer driven.driver.modifiers = .{};
            try driven.press(&.{key});
        }

        fn click(driven: *Self, element_id: zui.Id) !void {
            _ = try driven.driver.click(driven.tour, Tour.declare, element_id);
            try driven.frames(1);
        }

        fn focused(driven: *const Self, element_id: zui.Id) bool {
            return driven.ui.focused(element_id);
        }

        /// Presses Tab until focus comes back to where it started, at most
        /// `most` times, and returns whether it passed `element_id`.
        fn tabReaches(driven: *Self, element_id: zui.Id, most: usize) !bool {
            for (0..most) |_| {
                try driven.press(&.{.tab});
                if (driven.focused(element_id)) return true;
            }
            return false;
        }
    };
}

test "the keyboard opens the preferences menu, reaches and changes every setting in it, and Escape gives focus back to its button" {
    const kit = KitFor(FakeRenderer(true, .pixel_grid));
    var driven: Driven(kit) = .{};
    try driven.init();
    defer driven.deinit();
    const app = driven.tour;
    try driven.frames(3);

    try driven.press(&.{.tab});
    try testing.expect(driven.focused(tour.preferences_button_id));
    try driven.press(&.{.enter});
    try testing.expect(app.preferences_menu.open);
    try testing.expect(driven.focused(tour.preferences_pin_id));

    const settings = [_]zui.Id{
        .of("zoom_out"),
        .of("zoom_reset"),
        .of("zoom_in"),
        zui.Id.of("theme").indexedChild("segment", @intFromEnum(driven.ui.environment().theme)),
        .of("preferences.density"),
        .of("preferences.color_vision"),
        .of("preferences.contrast"),
        .of("preferences.system_text"),
        .of("live"),
        .of("heartbeat"),
        .of("inspector_toggle"),
    };
    for (settings) |setting| try testing.expect(try driven.tabReaches(setting, 40));
    try testing.expect(try driven.tabReaches(tour.preferences_pin_id, 40));
    try testing.expect(!try driven.tabReaches(tour.rail_screens_id.indexedChild("item", tour.RailRows(kit).rowOf(.overview)), 40));

    try testing.expect(try driven.tabReaches(.of("preferences.system_text"), 40));
    try driven.press(&.{.space});
    try testing.expectEqual(@as(?f32, 1), app.preference_choices.text_scale);
    try testing.expect(try driven.tabReaches(.of("preferences.text_scale"), 40));
    try driven.press(&.{.right});
    try testing.expectEqual(@as(?f32, 1.05), app.preference_choices.text_scale);
    try testing.expect(try driven.tabReaches(.of("preferences.reset"), 40));

    try testing.expect(try driven.tabReaches(.of("preferences.density"), 40));
    try driven.press(&.{.down});
    try testing.expectEqual(zui.design.Density.roomy, app.preference_choices.density);

    const zoom_before = app.zoom;
    try testing.expect(try driven.tabReaches(.of("zoom_in"), 40));
    try driven.press(&.{.enter});
    try testing.expect(app.zoom > zoom_before);

    try testing.expect(try driven.tabReaches(.of("live"), 40));
    try driven.press(&.{.space});
    try testing.expect(app.live);

    try driven.press(&.{.escape});
    try testing.expect(!app.preferences_menu.open);
    try testing.expect(driven.focused(tour.preferences_button_id));
}

test "a pinned preferences menu stays open while the screen beside it takes clicks and Tab, and Ctrl+, closes it" {
    const kit = KitFor(FakeRenderer(true, .pixel_grid));
    var driven: Driven(kit) = .{};
    try driven.init();
    defer driven.deinit();
    const app = driven.tour;
    try driven.frames(3);

    try driven.chord(.comma);
    try testing.expect(app.preferences_menu.open);
    try testing.expect(driven.focused(tour.preferences_pin_id));
    try driven.press(&.{.space});
    try testing.expect(app.preferences_menu.pinned);

    try driven.click(tour.rail_screens_id.indexedChild("item", tour.RailRows(kit).rowOf(.quiet_machine)));
    try testing.expectEqual(tour.Screen.quiet_machine, app.current);
    try testing.expect(app.preferences_menu.open);

    const game_loop: zui.Id = .of("menu.quiet_machine.game_loop");
    try driven.click(game_loop);
    try testing.expect(app.screens.quiet_machine.game_loop);
    try driven.press(&.{.escape});
    try testing.expect(app.preferences_menu.open);

    try testing.expect(try driven.tabReaches(tour.rail_screens_id.indexedChild("item", tour.RailRows(kit).rowOf(.quiet_machine)), 60));

    const zoom_before = app.zoom;
    try driven.chord(.equals);
    try testing.expect(app.zoom > zoom_before);
    try driven.chord(.l);
    try testing.expect(app.live);

    try driven.chord(.comma);
    try testing.expect(!app.preferences_menu.open);
    try driven.frames(1);
    try testing.expect(driven.ui.rectOf(game_loop) == null);
}

test "each screen's own toggles show in the menu only while that screen is open" {
    const kit = KitFor(FakeRenderer(true, .pixel_grid));
    var harness: Harness(kit) = .{};
    try harness.init();
    defer harness.deinit();
    const toggles = [_]struct { tour.Screen, zui.Id }{
        .{ .x_ray, .of("menu.x_ray.outline") },
        .{ .log_tail, .of("menu.log_tail.follow") },
        .{ .field_guide, .of("menu.field_guide.compact") },
        .{ .quiet_machine, .of("menu.quiet_machine.game_loop") },
        .{ .gesture_arena, .of("menu.gesture_arena.lasso_tool") },
        .{ .light_lab, .of("menu.light_lab.animate") },
        .{ .clickable_chaos, .of("menu.clickable_chaos.layout_boxes") },
    };
    for (kit.offered_screens) |screen| {
        const opened = harness.frameWithMenu(screen, false, default_window);
        defer harness.ui.release(opened);
        for (toggles) |toggle| try testing.expectEqual(toggle[0] == screen, opened.rectOf(toggle[1]) != null);
    }
    harness.ui.release(harness.frameWithMenu(.x_ray, true, default_window));
    try harness.click(.of("menu.x_ray.outline"));
    try testing.expect(harness.tour.screens.harbor.outline_regions);
}

test "the preferences menu's choices resolve the tour's tokens again, over the environment's, and the tokens screen audits clean" {
    const kit = KitFor(FakeRenderer(true, .pixel_grid));
    var harness: Harness(kit) = .{};
    try harness.init();
    defer harness.deinit();
    harness.ui.release(harness.frameToAudit(.preferences, .light));
    const before = harness.tour.appearance.tokens;
    const before_preferences = harness.tour.appearance.preferences.?;
    try testing.expectEqual(zui.design.Density.comfortable, before_preferences.density);

    harness.tour.preference_choices = .{ .density = .compact, .color_vision = .protan, .contrast = .high, .text_scale = 1.5 };
    const audited = harness.frameToAudit(.preferences, .light);
    defer harness.ui.release(audited);
    const after = harness.tour.appearance.preferences.?;
    try testing.expectEqual(zui.design.Density.compact, after.density);
    try testing.expectEqual(zui_design.ColorVision.protan, after.color_vision);
    try testing.expectEqual(zui.Environment.Contrast.high, after.contrast);
    try testing.expectEqual(@as(f32, 1.5), after.text_scale);
    try testing.expectEqual(zui.Environment.Contrast.normal, harness.ui.environment().contrast);
    const tokens = &harness.tour.appearance.tokens;
    try testing.expect(tokens.control_heights.get(.medium) < before.control_heights.get(.medium));
    try testing.expect(!tokens.colors.get(.idle).get(.danger).eql(before.colors.get(.idle).get(.danger)));
    try testing.expect(!tokens.colors.get(.idle).get(.outline_muted).eql(before.colors.get(.idle).get(.outline_muted)));

    const room = try testing.allocator.alloc(zui_design.Finding, 256);
    defer testing.allocator.free(room);
    const findings = zui_design.audit(audited, .{ .page_background = tokens.colors.get(.idle).get(.background), .focus_ring_color = tokens.colors.get(.focused).get(.focus) }, room);
    for (findings.slice()) |finding| printFinding(.light, .preferences, finding);
    try testing.expectEqual(0, findings.slice().len + findings.dropped);
}

test "the rail lists every screen under its lane, and a click or Down on it shows another" {
    const kit = KitFor(FakeRenderer(true, .pixel_grid));
    const rail = tour.RailRows(kit);
    for (kit.offered_screens) |screen| {
        var heading = rail.rowOf(screen);
        while (!rail.items[heading].heading) heading -= 1;
        try testing.expectEqualStrings(kit.info(screen).lane.name(), rail.items[heading].label);
        try testing.expectEqualStrings(kit.info(screen).title, rail.items[rail.rowOf(screen)].label);
    }
    try testing.expectEqualStrings("Ctrl+1", rail.items[rail.rowOf(.overview)].shortcut);
    try testing.expectEqualStrings("", rail.items[rail.rowOf(.clickable_chaos)].shortcut);

    var harness: Harness(kit) = .{};
    try harness.init();
    defer harness.deinit();
    harness.ui.release(harness.settledFrame(.overview, default_window));
    try harness.click(tour.rail_screens_id.indexedChild("item", rail.rowOf(.harbor)));
    try testing.expectEqual(tour.Screen.harbor, harness.tour.current);
    harness.pressKey(.down);
    try testing.expectEqual(tour.Screen.x_ray, harness.tour.current);
    harness.pressKey(.down);
    try testing.expectEqual(tour.Screen.photo_cull, harness.tour.current);
}

test "the rail's rows are the xs tier apart at every density, and every one a target of at least 24" {
    const kit = KitFor(FakeRenderer(true, .pixel_grid));
    const rail = tour.RailRows(kit);
    const expected_gaps = std.EnumArray(zui.design.Density, f32).init(.{ .compact = 2, .comfortable = 4, .roomy = 6 });
    var harness: Harness(kit) = .{};
    try harness.init();
    defer harness.deinit();
    for (std.enums.values(zui.design.Density)) |density| {
        harness.tour.preference_choices.density = density;
        const settled = harness.settledFrame(.overview, default_window);
        defer harness.ui.release(settled);
        try testing.expectEqual(expected_gaps.get(density), harness.tour.appearance.tokens.space(.xs));
        const overview = settled.rectOf(tour.rail_screens_id.indexedChild("item", rail.rowOf(.overview))).?;
        const preferences = settled.rectOf(tour.rail_screens_id.indexedChild("item", rail.rowOf(.preferences))).?;
        try testing.expectApproxEqAbs(expected_gaps.get(density), preferences.y - (overview.y + overview.height), 0.01);
        for (rail.items, 0..) |item, row| {
            if (item.heading) continue;
            const placed = settled.rectOf(tour.rail_screens_id.indexedChild("item", row)).?;
            try testing.expect(placed.height >= 24);
        }
    }
}

/// The text of the first line in `frame` that starts with `prefix`.
fn textStartingWith(frame: anytype, prefix: []const u8) ?[]const u8 {
    for (frame.commands()) |command| {
        if (command.payload == .text and std.mem.startsWith(u8, command.payload.text.content, prefix)) return command.payload.text.content;
    }
    return null;
}

fn semanticLabel(frame: anytype, element_id: zui.Id) ?[]const u8 {
    for (frame.semantics()) |node| {
        if (node.id == element_id.hash) return node.label;
    }
    return null;
}

test "each section of the field guide shows its own guides, counted truly, and the trail follows the selection" {
    const kit = KitFor(FakeRenderer(true, .pixel_grid));
    var harness: Harness(kit) = .{};
    try harness.init();
    defer harness.deinit();
    harness.ui.release(harness.settledFrame(.field_guide, default_window));
    const sections: zui.Id = .of("field_guide.sections");
    const views: zui.Id = .of("field_guide.views");
    const path: zui.Id = .of("field_guide.path");
    const section_count = 6;

    var first_guides: [section_count][]const u8 = undefined;
    for (0..section_count) |section| {
        try harness.click(sections.indexedChild("tab", section));
        const shown = harness.frame(default_window);
        defer harness.ui.release(shown);
        var guides: usize = 0;
        while (shown.rectOf(.indexed("field_guide.guide", guides)) != null) guides += 1;
        try testing.expect(guides >= 3);
        first_guides[section] = semanticLabel(shown, .indexed("field_guide.guide", 0)).?;

        const title = semanticLabel(shown, sections.indexedChild("tab", section)).?;
        var expected_count: [64]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expected_count, "{d} guides in {s}", .{ guides, title }), textStartingWith(shown, try std.fmt.bufPrint(&expected_count, "{d} guide", .{guides})).?);
        try testing.expectEqualStrings(title, semanticLabel(shown, path.indexedChild("crumb", 2)).?);
    }
    for (first_guides[0 .. section_count - 1], 1..) |guide, next| {
        for (first_guides[next..]) |other| try testing.expect(!std.mem.eql(u8, guide, other));
    }

    try harness.click(views.indexedChild("tab", 1));
    const examples = harness.frame(default_window);
    defer harness.ui.release(examples);
    try testing.expect(examples.rectOf(.of("field_guide.example")) != null);
    try testing.expect(examples.rectOf(.indexed("field_guide.guide", 0)) == null);
    var examples_shown: usize = 0;
    for (examples.commands()) |command| {
        if (command.payload == .text and std.mem.eql(u8, command.payload.text.content, "Examples")) examples_shown += 1;
    }
    try testing.expectEqual(@as(usize, 2), examples_shown);
}

test "a renderer is offered the screens and the frost it draws everything of" {
    const every = KitFor(FakeRenderer(true, .pixel_grid));
    const plain = KitFor(FakeRenderer(false, cells));
    try testing.expectEqualSlices(tour.Screen, std.enums.values(tour.Screen), every.offered_screens);
    try testing.expect(every.draws_frost);
    try testing.expect(std.mem.indexOfScalar(tour.Screen, plain.offered_screens, .clickable_chaos) == null);
    try testing.expectEqual(std.enums.values(tour.Screen).len - 1, plain.offered_screens.len);
    try testing.expect(!plain.draws_frost);

    var harness: Harness(plain) = .{};
    try harness.init();
    defer harness.deinit();
    harness.tour.show(.clickable_chaos);
    try testing.expectEqual(tour.Screen.overview, harness.tour.current);
}

test "Harbor's continuous corners are drawn by a renderer that draws them, and drawn round and reported by one that does not" {
    inline for (.{ FakeRenderer(true, .pixel_grid), FakeRenderer(false, .pixel_grid) }) |Renderer| {
        const kit = KitFor(Renderer);
        var harness: Harness(kit) = .{};
        try harness.init();
        defer harness.deinit();
        const settled = harness.settledFrame(.harbor, default_window);
        defer harness.ui.release(settled);
        const lowered = settled.diagnostics.lowered_corner_shapes;
        if (kit.draws_every_corner_shape) {
            try testing.expectEqual(0, lowered.count());
        } else {
            try testing.expectEqual(zui.CornerShapeSet.initOne(kit.panel_corner_shape), lowered);
        }
        try testing.expect(settled.diagnostics.ok());
    }
}

test "a material without patterns is not shown as one" {
    const NumberedMaterials = struct {
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const zui_commands: zui.CommandSet = .initOne(.material);
        pub const MaterialHandle = u32;

        pub fn zuiSubmit(_: *@This(), _: zui.Surface, _: anytype) !void {}
    };
    try testing.expect(!KitFor(NumberedMaterials).draws_material_patterns);
}

test "F12 opens zui_debug's panel over the overview, listing its elements, and closes it" {
    const kit = KitFor(FakeRenderer(true, .pixel_grid));
    var harness: Harness(kit) = .{};
    try harness.init();
    defer harness.deinit();
    harness.ui.release(harness.settledFrame(.overview, default_window));

    const f12: zui.Event = .{ .key_down = .{ .key = .f12, .at = .zero } };
    harness.ui.release(harness.frameWith(default_window, &.{f12}));
    const opened = harness.frame(default_window);
    defer harness.ui.release(opened);
    try testing.expect(opened.diagnostics.ok());
    const panel = opened.lookup(kit.Inspector.default_panel_id.hash).?;
    const panel_elements = opened.inspect(panel).subtree_end - panel;
    try testing.expectEqual(opened.elementCount() - panel_elements, harness.tour.zui_debug_inspector.rows().len);
    var rail_titles: usize = 0;
    for (harness.tour.zui_debug_inspector.rows()) |row| {
        if (row.kind == .text and std.mem.eql(u8, row.textPreview(), "Harbor X-ray")) rail_titles += 1;
    }
    try testing.expect(rail_titles > 0);

    harness.ui.release(harness.frameWith(default_window, &.{f12}));
    const closed = harness.frame(default_window);
    defer harness.ui.release(closed);
    try testing.expectEqual(@as(?kit.Ui.Index, null), closed.lookup(kit.Inspector.default_panel_id.hash));
}

test "without the inspector, F12 opens nothing and every screen still declares" {
    const kit = tour.Kit(.{ .Renderer = FakeRenderer(true, .pixel_grid), .FontSystem = zui_truetype.Text, .inspector = false, .renderer_name = "a fake renderer" });
    try testing.expect(kit.Inspector == void and kit.ZoneTimer == void);
    try Harness(kit).expectEveryScreenWithinLimits();
}

test "the tour's fonts come from adding them, and measure proportionally or monospaced" {
    const Text = KitFor(FakeRenderer(true, .pixel_grid)).Text;
    var text: Text = .{};
    try text.init();
    try testing.expectEqual(std.enums.values(tour.Typeface).len, text.font_system.face_count);
    for ([_]u16{ text.fonts.body, text.fonts.bold }) |font| {
        const narrow = text.zuiMeasure("iiii", .{ .font = font, .size = 16, .letter_spacing = 0 });
        const wide = text.zuiMeasure("WWWW", .{ .font = font, .size = 16, .letter_spacing = 0 });
        try testing.expect(narrow[0] * 2 < wide[0]);
        try testing.expectEqual(@as(f32, 16), narrow[1]);
    }
    const regular = text.zuiMeasure("Hello", .{ .font = text.fonts.body, .size = 16, .letter_spacing = 0 });
    const bold = text.zuiMeasure("Hello", .{ .font = text.fonts.bold, .size = 16, .letter_spacing = 0 });
    try testing.expect(bold[0] > regular[0]);
    const mono_narrow = text.zuiMeasure("iiii", .{ .font = text.fonts.mono, .size = 16, .letter_spacing = 0 });
    const mono_wide = text.zuiMeasure("WWWW", .{ .font = text.fonts.mono, .size = 16, .letter_spacing = 0 });
    try testing.expectApproxEqAbs(mono_narrow[0], mono_wide[0], 0.001);
}

test "on a renderer that draws cells, every glyph of every font measures one cell" {
    const Text = KitFor(FakeRenderer(false, cells)).Text;
    var text: Text = .{};
    try text.init();
    try testing.expectEqual(cells, text.font_system.placement);
    for ([_]u16{ text.fonts.body, text.fonts.bold, text.fonts.mono }) |font| {
        try testing.expectEqual([2]f32{ 4 * 8, 16 }, text.zuiMeasure("iiWW", .{ .font = font, .size = 16, .letter_spacing = 0 }));
    }
}

/// An offscreen window on a clock that advances a frame per poll, which
/// closes when asked to.
const ScriptedHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    polls: u64 = 0,
    closed: bool = false,

    pub fn init(self: *ScriptedHost, _: std.Io, _: zui.WindowOptions) !void {
        self.* = .{};
    }

    pub fn deinit(_: *ScriptedHost) void {}

    pub fn close(self: *ScriptedHost) void {
        self.closed = true;
    }

    pub fn zuiPoll(self: *ScriptedHost, _: zui.WindowId, record: *zui.RecordBuilder) bool {
        if (self.closed) return false;
        self.polls += 1;
        record.begin(.{ .now = .fromNanoseconds(self.polls * std.time.ns_per_s / 60), .viewport = default_window, .scale = 1 });
        return true;
    }

    pub fn zuiWaker(self: *ScriptedHost) zui.Waker {
        return .{ .context = self, .wakeFn = ignoreWake };
    }

    pub fn zuiWait(_: *ScriptedHost, _: zui.NextFrame) void {}

    pub fn zuiSurface(_: *ScriptedHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 1440, 900 } } };
    }

    pub fn zuiApply(_: *ScriptedHost, _: zui.WindowId, _: zui.HostRequests) void {}

    fn ignoreWake(_: *anyopaque) void {}
};

test "zui_app runs the tour through every screen it is offered, and stops at the frame limit" {
    const App = tour.App(.{ .Host = ScriptedHost, .Renderer = FakeRenderer(false, .pixel_grid), .Text = zui_truetype.Text, .renderer_name = "a fake renderer" });
    const cycle_every = 3;
    const frame_limit = cycle_every * App.kit.offered_screens.len + 2;
    const session = try testing.allocator.create(zui_app.Session(App));
    defer testing.allocator.destroy(session);
    try session.start(.{ .gpa = testing.allocator, .io = testing.io }, .{ .notify = ignoreNotice });
    defer session.stop();
    session.app.options.frame_limit = frame_limit;
    session.app.tour.cycle_every = cycle_every;

    var screens_shown: std.EnumSet(tour.Screen) = .initEmpty();
    while (try session.frame()) screens_shown.insert(session.app.tour.current);
    try testing.expectEqual(@as(u64, frame_limit), session.app.frames);
    try testing.expectEqual(App.kit.offered_screens.len, screens_shown.count());
    try testing.expect(session.app.tour.perf.diagnostics.ok());
    try testing.expectEqual(@as(u64, frame_limit), session.app.tour.perf.zui_frames);
    try testing.expectEqual(session.app.tour.background(), session.renderer.clear_color);
    try testing.expectEqual(App.kit.backgroundOf(&.{ .theme = .dark }), session.renderer.clear_color);
}

fn ignoreNotice(_: zui_app.Notice) void {}

test "the options take the targets' flags" {
    const arguments = [_][:0]const u8{ "tour", "--screen", "photo_cull", "--frames", "600", "--cycle", "50", "--zui-debug", "--screenshot", "tour.png" };
    const options: tour.Options = try .parse(&arguments);
    try testing.expectEqual(tour.Screen.photo_cull, options.screen.?);
    try testing.expectEqual(@as(u64, 600), options.frame_limit.?);
    try testing.expectEqual(@as(u32, 50), options.cycle_every.?);
    try testing.expect(options.zui_debug and options.hidden);
    try testing.expectEqualStrings("tour.png", options.screenshot_path.?);
    try testing.expectError(error.UnknownScreen, tour.Options.parse(&.{ "tour", "--screen", "nowhere" }));
    try testing.expectError(error.UnknownArgument, tour.Options.parse(&.{ "tour", "--fast" }));
}

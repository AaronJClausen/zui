const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_widgets = @import("zui_widgets.zig");
const zui_design = @import("zui_design");

const testing = std.testing;
const Text = zui_testing.FixedMetricsText(u16);
const limits: zui.Limits = .{
    .max_elements = 512,
    .max_text_bytes = 8192,
    .max_depth = 24,
    .max_render_commands = 1024,
    .state_slots = 512,
    .measure_cache_entries = 1024,
};
const ghost_limits: zui.Limits = .{
    .max_elements = 512,
    .max_text_bytes = 8192,
    .max_depth = 24,
    .max_render_commands = 1024,
    .state_slots = 512,
    .measure_cache_entries = 1024,
    .exit_ghost_commands = 256,
};
const Ui = zui.Context(.{ .limits = limits, .Text = Text, .features = .{ .semantics = true }, .commands = .initOne(.shadow) });
const DrawingUi = zui.Context(.{ .limits = limits, .Text = Text, .commands = .initMany(&.{ .transform, .shadow }) });
const GhostUi = zui.Context(.{ .limits = ghost_limits, .Text = Text, .commands = .initOne(.shadow) });

fn TokensIn(comptime ContextType: type, comptime preferences: zui_design.Preferences) zui.design.Tokens(ContextType, void) {
    @setEvalBranchQuota(10_000_000);
    var resolved: zui.design.Tokens(ContextType, void) = .{};
    _ = zui_design.resolve(zui_design.default, preferences, &resolved);
    return resolved;
}

const tokens = TokensIn(Ui, .{ .theme = .dark });
const drawing_tokens = TokensIn(DrawingUi, .{ .theme = .dark });
const ghost_tokens = TokensIn(GhostUi, .{ .theme = .dark });
const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui));
const widgets: Widgets = .{ .skin = .{ .tokens = &tokens } };
const drawing_widgets: zui_widgets.Widgets(DrawingUi, zui_widgets.DesignSkin(DrawingUi)) = .{ .skin = .{ .tokens = &drawing_tokens } };
const ghost_widgets: zui_widgets.Widgets(GhostUi, zui_widgets.DesignSkin(GhostUi)) = .{ .skin = .{ .tokens = &ghost_tokens } };

fn Fixture(comptime ContextType: type) type {
    return struct {
        text: Text = .{},
        ui: ContextType = undefined,
        driver: zui_testing.Driver(ContextType) = undefined,

        fn init(fixture: *@This()) !void {
            fixture.ui = try .init(testing.allocator, testing.io, &fixture.text);
            fixture.driver = .{ .ui = &fixture.ui };
        }

        fn deinit(fixture: *@This()) void {
            fixture.ui.deinit(testing.allocator);
        }
    };
}

fn nodeOf(frame: anytype, id: zui.Id) !zui.SemanticNode {
    for (frame.semantics()) |listed| {
        if (listed.id == id.hash) return listed;
    }
    return error.NotListed;
}

fn textCommand(frame: anytype, content: []const u8) ?@TypeOf(frame.commands()[0]) {
    for (frame.commands()) |command| {
        if (command.payload == .text and std.mem.eql(u8, command.payload.text.content, content)) return command;
    }
    return null;
}

fn rectangles(frame: anytype, fill: zui.Color) usize {
    var count: usize = 0;
    for (frame.commands()) |command| {
        if (command.payload == .rectangle and command.payload.rectangle.color.eql(fill)) count += 1;
    }
    return count;
}

fn color(role: zui.design.ColorRole) zui.Color {
    return tokens.colors.get(.idle).get(role);
}

fn mouse(driver: anytype, position: [2]f32) zui.Pointer {
    return .{ .id = .mouse, .kind = .mouse, .position = position, .at = driver.now };
}

fn moveTo(driver: anytype, app: anytype, comptime declare: anytype, position: [2]f32) !*const @TypeOf(driver.ui.*).Frame {
    return driver.frame(app, declare, &.{.{ .pointer_move = .{ .pointer = mouse(driver, position) } }});
}

fn rightClick(driver: anytype, app: anytype, comptime declare: anytype, position: [2]f32) !*const @TypeOf(driver.ui.*).Frame {
    const pointer = mouse(driver, position);
    return driver.frame(app, declare, &.{
        .{ .pointer_move = .{ .pointer = pointer } },
        .{ .pointer_down = .{ .pointer = pointer, .button = .secondary } },
        .{ .pointer_up = .{ .pointer = pointer, .button = .secondary } },
    });
}

fn reducedMotion(driver: anytype, app: anytype, comptime declare: anytype) !void {
    _ = try driver.frame(app, declare, &.{.{ .environment = .{ .reduced_motion = true } }});
}

fn waitFor(driver: anytype, app: anytype, comptime declare: anytype, seconds: f64) !*const @TypeOf(driver.ui.*).Frame {
    const interval = driver.frame_interval_ns;
    defer driver.frame_interval_ns = interval;
    driver.frame_interval_ns = @intFromFloat(seconds * std.time.ns_per_s);
    return driver.frame(app, declare, &.{});
}

fn expectFrameAt(ui: anytype, instant: zui.Instant) !void {
    switch (ui.nextFrame()) {
        .at => |due| try testing.expectEqual(instant.nanoseconds, due.nanoseconds),
        else => |other| {
            std.debug.print("expected a frame at an instant, got {any}\n", .{other});
            return error.TestUnexpectedResult;
        },
    }
}

// =============================================================
// Tooltip
// =============================================================

const Toolbar = struct {
    const share: zui.Id = .of("share");
    const pin: zui.Id = .of("pin");
    const close: zui.Id = .of("close");

    fn declare(_: *Toolbar, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .all(40), .child_gap = 40 } });
        _ = widgets.button(ui, share, "Share", .{});
        widgets.tooltip(ui, share, "Copy a link", .{ .shortcut = "Ctrl+L" });
        _ = widgets.button(ui, pin, "Pin", .{});
        widgets.tooltip(ui, pin, "Keep it on top", .{});
        _ = widgets.iconButton(ui, close, .close, .{ .label = "Close the board" });
        ui.close();
    }

    fn bubble(anchor: zui.Id) zui.Id {
        return anchor.child("tooltip");
    }
};

test "a tooltip shows after half a second of hover, asking an idle app only for a frame then" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Toolbar = .{};
    _ = try driver.frame(&app, Toolbar.declare, &.{});
    var frame = try driver.hover(&app, Toolbar.declare, Toolbar.share);
    const hovered_at = driver.now;
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Toolbar.bubble(Toolbar.share)));
    try expectFrameAt(&fixture.ui, hovered_at.addSeconds(0.5));

    frame = try waitFor(driver, &app, Toolbar.declare, 0.3);
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Toolbar.bubble(Toolbar.share)));
    frame = try waitFor(driver, &app, Toolbar.declare, 0.2);
    try testing.expect(frame.rectOf(Toolbar.bubble(Toolbar.share)) != null);
    frame = try waitFor(driver, &app, Toolbar.declare, tokens.motion.popover_enter.duration);
    const bubble = frame.rectOf(Toolbar.bubble(Toolbar.share)).?;
    const anchor = frame.rectOf(Toolbar.share).?;
    try testing.expect(bubble.y >= anchor.y + anchor.height);
    const node = try nodeOf(frame, Toolbar.bubble(Toolbar.share));
    try testing.expectEqual(zui.SemanticRole.tooltip, node.role);
    try testing.expectEqualStrings("Copy a link", node.label);
    try testing.expectEqual(color(.on_surface_inverse), textCommand(frame, "Copy a link").?.payload.text.style.color);
    const shortcut = textCommand(frame, "Ctrl+L").?.bounds;
    try testing.expect(shortcut.x > textCommand(frame, "Copy a link").?.bounds.x);
    try testing.expectEqual(1, rectangles(frame, color(.surface_inverse)));
}

test "within 0.3 s of one tooltip closing the next shows at once, and later it waits again" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Toolbar = .{};
    _ = try driver.frame(&app, Toolbar.declare, &.{});
    _ = try driver.hover(&app, Toolbar.declare, Toolbar.share);
    _ = try waitFor(driver, &app, Toolbar.declare, 0.6);
    var frame = try driver.hover(&app, Toolbar.declare, Toolbar.pin);
    try testing.expect(frame.rectOf(Toolbar.bubble(Toolbar.pin)) != null);
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Toolbar.bubble(Toolbar.share)));

    _ = try moveTo(driver, &app, Toolbar.declare, .{ 790, 590 });
    _ = try waitFor(driver, &app, Toolbar.declare, 0.5);
    frame = try driver.hover(&app, Toolbar.declare, Toolbar.share);
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Toolbar.bubble(Toolbar.share)));
}

test "a tooltip shows at once on keyboard focus but not after a click, and Escape hides it" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Toolbar = .{};
    _ = try driver.frame(&app, Toolbar.declare, &.{});
    var frame = try driver.pressKeys(&app, Toolbar.declare, &.{.tab});
    try testing.expect(fixture.ui.focused(Toolbar.share));
    try testing.expect(frame.rectOf(Toolbar.bubble(Toolbar.share)) != null);
    frame = try driver.pressKeys(&app, Toolbar.declare, &.{.escape});
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Toolbar.bubble(Toolbar.share)));
    frame = try driver.pressKeys(&app, Toolbar.declare, &.{.tab});
    try testing.expect(frame.rectOf(Toolbar.bubble(Toolbar.pin)) != null);

    _ = try driver.click(&app, Toolbar.declare, Toolbar.share);
    _ = try moveTo(driver, &app, Toolbar.declare, .{ 790, 590 });
    frame = try waitFor(driver, &app, Toolbar.declare, 1);
    try testing.expect(fixture.ui.focused(Toolbar.share));
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Toolbar.bubble(Toolbar.share)));
}

test "an icon button's label is its tooltip" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Toolbar = .{};
    _ = try driver.frame(&app, Toolbar.declare, &.{});
    const frame = try driver.focus(&app, Toolbar.declare, Toolbar.close);
    try testing.expectEqualStrings("Close the board", (try nodeOf(frame, Toolbar.bubble(Toolbar.close))).label);
}

const EdgeTip = struct {
    const anchor: zui.Id = .of("edge");
    position: [2]f32,

    fn declare(app: *EdgeTip, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both } });
        ui.box(.{ .id = anchor, .focusable = true, .floating = .{ .attach_to = .root, .offset = app.position }, .layout = .{ .sizing = .{ .width = .fixed(40), .height = .fixed(30) } } });
        widgets.tooltip(ui, anchor, "Shares the board with everyone in the workspace", .{});
        ui.close();
    }
};

test "a tooltip flips above an anchor at the window's bottom and stays inside it at a side" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: EdgeTip = .{ .position = .{ 770, 560 } };
    try reducedMotion(driver, &app, EdgeTip.declare);
    _ = try driver.focus(&app, EdgeTip.declare, EdgeTip.anchor);
    for (0..2) |_| {
        const frame = try driver.frame(&app, EdgeTip.declare, &.{});
        const bubble = frame.rectOf(EdgeTip.anchor.child("tooltip")).?;
        try testing.expect(bubble.y + bubble.height <= 560);
        try testing.expect(bubble.x + bubble.width <= 800);
        try testing.expect(bubble.width <= 240);
    }
}

// =============================================================
// Menu
// =============================================================

const FileMenu = struct {
    const anchor: zui.Id = .of("file");
    const id: zui.Id = .of("file.menu");

    open: bool = false,
    autosave: bool = true,
    chosen: [5]u32 = @splat(0),

    fn declare(app: *FileMenu, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .all(40), .child_gap = 20 } });
        _ = widgets.button(ui, anchor, "File", .{ .variant = .tertiary });
        _ = widgets.button(ui, .of("after"), "After", .{});
        if (widgets.menu(ui, id, anchor, &app.open, .{ .label = "File" })) |file| {
            file.section(ui, "Document");
            if (file.item(ui, "Open", .{ .shortcut = "Ctrl+O", .icon = .arrow_up })) app.chosen[0] += 1;
            if (file.item(ui, "Autosave", .{ .checked = app.autosave })) {
                app.chosen[1] += 1;
                app.autosave = !app.autosave;
            }
            if (file.item(ui, "Print", .{ .disabled = true })) app.chosen[2] += 1;
            if (file.item(ui, "Publish", .{})) app.chosen[3] += 1;
            file.separator(ui);
            if (file.item(ui, "Delete", .{ .danger = true, .shortcut = "Del" })) app.chosen[4] += 1;
            file.end(ui);
        }
        ui.close();
    }

    fn item(index: usize) zui.Id {
        return id.indexedChild("item", index);
    }
};

test "a menu opens from its anchor focusing its first item, and the arrows, Home and End skip the disabled one" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: FileMenu = .{};
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    _ = try driver.click(&app, FileMenu.declare, FileMenu.anchor);
    var frame = try waitFor(driver, &app, FileMenu.declare, tokens.motion.popover_enter.duration);
    try testing.expect(app.open);
    const panel = frame.rectOf(FileMenu.id.child("panel")).?;
    const anchor = frame.rectOf(FileMenu.anchor).?;
    try testing.expect(panel.y >= anchor.y + anchor.height);
    try testing.expect(panel.width >= 200);
    try testing.expect(fixture.ui.focused(FileMenu.item(0)));

    const steps = [_]struct { key: zui.Key, focused: usize }{
        .{ .key = .down, .focused = 1 },
        .{ .key = .down, .focused = 3 },
        .{ .key = .down, .focused = 4 },
        .{ .key = .down, .focused = 0 },
        .{ .key = .up, .focused = 4 },
        .{ .key = .home, .focused = 0 },
        .{ .key = .end, .focused = 4 },
    };
    for (steps) |step| {
        _ = try driver.pressKeys(&app, FileMenu.declare, &.{step.key});
        frame = try driver.frame(&app, FileMenu.declare, &.{});
        try testing.expect(fixture.ui.focused(FileMenu.item(step.focused)));
    }
    for (0..5) |_| {
        _ = try driver.pressKeys(&app, FileMenu.declare, &.{.tab});
        const focus = fixture.ui.focusedId();
        try testing.expect(focus.eql(FileMenu.item(0)) or focus.eql(FileMenu.item(1)) or focus.eql(FileMenu.item(3)) or focus.eql(FileMenu.item(4)));
    }
}

test "a letter jumps to the next item that starts with it" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: FileMenu = .{};
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    _ = try driver.click(&app, FileMenu.declare, FileMenu.anchor);
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    _ = try driver.typeText(&app, FileMenu.declare, "p");
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    try testing.expect(fixture.ui.focused(FileMenu.item(3)));
    _ = try driver.typeText(&app, FileMenu.declare, "D");
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    try testing.expect(fixture.ui.focused(FileMenu.item(4)));
    _ = try driver.typeText(&app, FileMenu.declare, "o");
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    try testing.expect(fixture.ui.focused(FileMenu.item(0)));
}

test "choosing an item by click, Enter or Space closes the menu and gives focus back to its anchor" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: FileMenu = .{};
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    for ([_]?zui.Key{ null, .enter, .space }, 1..) |key, times| {
        _ = try driver.click(&app, FileMenu.declare, FileMenu.anchor);
        _ = try driver.frame(&app, FileMenu.declare, &.{});
        if (key) |pressed| {
            _ = try driver.pressKeys(&app, FileMenu.declare, &.{pressed});
        } else _ = try driver.click(&app, FileMenu.declare, FileMenu.item(0));
        try testing.expectEqual(@as(u32, @intCast(times)), app.chosen[0]);
        try testing.expect(!app.open);
        const frame = try driver.frame(&app, FileMenu.declare, &.{});
        try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(FileMenu.id.child("panel")));
        try testing.expect(fixture.ui.focused(FileMenu.anchor));
    }
    _ = try driver.click(&app, FileMenu.declare, FileMenu.anchor);
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    _ = try driver.click(&app, FileMenu.declare, FileMenu.item(2));
    try testing.expectEqual(@as(u32, 0), app.chosen[2]);
    try testing.expect(app.open);
}

test "Escape, a click outside and a dismiss action close a menu without choosing" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: FileMenu = .{};
    _ = try driver.frame(&app, FileMenu.declare, &.{});

    _ = try driver.click(&app, FileMenu.declare, FileMenu.anchor);
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    _ = try driver.pressKeys(&app, FileMenu.declare, &.{.escape});
    try testing.expect(!app.open);
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    try testing.expect(fixture.ui.focused(FileMenu.anchor));

    _ = try driver.click(&app, FileMenu.declare, FileMenu.anchor);
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    _ = try driver.clickAt(&app, FileMenu.declare, FileMenu.id.child("backdrop"), .{ 0.95, 0.95 });
    try testing.expect(!app.open);

    _ = try driver.click(&app, FileMenu.declare, FileMenu.anchor);
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    _ = try driver.action(&app, FileMenu.declare, FileMenu.id.child("panel"), .dismiss);
    try testing.expect(!app.open);
    try testing.expectEqual([_]u32{ 0, 0, 0, 0, 0 }, app.chosen);
}

test "a menu's items list what they are, a checked one its check, and a danger one in the danger colors" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: FileMenu = .{ .open = true };
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    const frame = try driver.frame(&app, FileMenu.declare, &.{});
    const panel = try nodeOf(frame, FileMenu.id.child("panel"));
    try testing.expectEqual(zui.SemanticRole.menu, panel.role);
    try testing.expect(panel.actions.contains(.dismiss));
    const autosave = try nodeOf(frame, FileMenu.item(1));
    try testing.expectEqual(zui.SemanticRole.menu_item, autosave.role);
    try testing.expectEqual(@as(?bool, true), autosave.state.checked);
    try testing.expectEqual(@as(?bool, null), (try nodeOf(frame, FileMenu.item(0))).state.checked);
    try testing.expect((try nodeOf(frame, FileMenu.item(2))).state.disabled);
    try testing.expect(textCommand(frame, "•") != null);
    try testing.expectEqual(color(.on_danger_container), textCommand(frame, "Delete").?.payload.text.style.color);
    try testing.expectEqual(color(.on_danger_container), textCommand(frame, "Del").?.payload.text.style.color);
    try testing.expectEqual(tokens.colors.get(.focused).get(.on_surface_muted), textCommand(frame, "Ctrl+O").?.payload.text.style.color);
    try testing.expectEqual(color(.on_surface_muted), textCommand(frame, "Document").?.payload.text.style.color);
    const open_label = textCommand(frame, "Open").?.bounds;
    const print_label = textCommand(frame, "Print").?.bounds;
    try testing.expectEqual(open_label.x, print_label.x);
    const shortcut = textCommand(frame, "Ctrl+O").?.bounds;
    const item = frame.rectOf(FileMenu.item(0)).?;
    try testing.expect(shortcut.x + shortcut.width > item.x + item.width - tokens.space(.s) - 1);
    try testing.expectEqual(tokens.control_heights.get(.medium), item.height);
    try testing.expect(frame.diagnostics.missing_icons > 0);
}

test "hovering a menu item fills it in secondary_container, and a danger item in danger_container" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: FileMenu = .{ .open = true };
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    _ = try driver.frame(&app, FileMenu.declare, &.{});
    var frame = try driver.hover(&app, FileMenu.declare, FileMenu.item(3));
    frame = try driver.frame(&app, FileMenu.declare, &.{});
    try testing.expectEqual(1, rectangles(frame, tokens.colors.get(.hovered).get(.secondary_container)));
    frame = try driver.hover(&app, FileMenu.declare, FileMenu.item(4));
    frame = try driver.frame(&app, FileMenu.declare, &.{});
    try testing.expectEqual(1, rectangles(frame, tokens.colors.get(.hovered).get(.danger_container)));
}

const Board = struct {
    const region: zui.Id = .of("board");
    const id: zui.Id = .of("board.menu");
    open: bool = false,
    renamed: u32 = 0,

    fn declare(app: *Board, ui: *Ui) void {
        ui.open(.{ .id = region, .focusable = true, .layout = .{ .sizing = .grow_both } });
        ui.close();
        if (widgets.contextMenu(ui, id, region, &app.open, .{ .label = "Board" })) |board| {
            if (board.item(ui, "Rename", .{ .shortcut = "F2" })) app.renamed += 1;
            _ = board.item(ui, "Duplicate", .{});
            _ = board.item(ui, "Archive", .{});
            board.end(ui);
        }
    }
};

test "a context menu opens at the pointer on a right click, flipped to fit the window, and at the region on the menu key" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Board = .{};
    try reducedMotion(driver, &app, Board.declare);
    _ = try rightClick(driver, &app, Board.declare, .{ 100, 120 });
    try testing.expect(app.open);
    var frame = try driver.frame(&app, Board.declare, &.{});
    var panel = frame.rectOf(Board.id.child("panel")).?;
    try testing.expectEqual(@as(f32, 100), panel.x);
    try testing.expectEqual(@as(f32, 120), panel.y);
    try testing.expect(fixture.ui.focused(Board.id.indexedChild("item", 0)));
    _ = try driver.pressKeys(&app, Board.declare, &.{.escape});
    try testing.expect(!app.open);

    _ = try rightClick(driver, &app, Board.declare, .{ 780, 590 });
    for (0..2) |_| {
        frame = try driver.frame(&app, Board.declare, &.{});
        panel = frame.rectOf(Board.id.child("panel")).?;
        try testing.expectEqual(@as(f32, 780), panel.x + panel.width);
        try testing.expectEqual(@as(f32, 590), panel.y + panel.height);
    }
    _ = try driver.pressKeys(&app, Board.declare, &.{.escape});

    _ = try driver.focus(&app, Board.declare, Board.region);
    _ = try driver.pressKeys(&app, Board.declare, &.{.menu});
    frame = try driver.frame(&app, Board.declare, &.{});
    panel = frame.rectOf(Board.id.child("panel")).?;
    try testing.expectEqual(@as(f32, 400), panel.x);
    try testing.expectEqual(@as(f32, 300), panel.y);
    _ = try driver.pressKeys(&app, Board.declare, &.{.enter});
    try testing.expectEqual(@as(u32, 1), app.renamed);
    _ = try driver.frame(&app, Board.declare, &.{});
    try testing.expect(fixture.ui.focused(Board.region));
}

const DrawnMenu = struct {
    const anchor: zui.Id = .of("drawn");
    const id: zui.Id = .of("drawn.menu");
    open: bool = false,

    fn declare(app: *DrawnMenu, ui: *DrawingUi) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .all(40) } });
        _ = drawing_widgets.button(ui, anchor, "Drawn", .{});
        if (drawing_widgets.menu(ui, id, anchor, &app.open, .{})) |drawn| {
            _ = drawn.item(ui, "One", .{});
            drawn.end(ui);
        }
        ui.close();
    }
};

fn scaleOf(frame: anytype) ?f32 {
    for (frame.commands()) |command| {
        if (command.payload == .transform_begin) return command.payload.transform_begin.scale[0];
    }
    return null;
}

test "a menu slides and grows in through popover_enter, and at once under reduced motion" {
    var fixture: Fixture(DrawingUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: DrawnMenu = .{};
    _ = try driver.frame(&app, DrawnMenu.declare, &.{});
    _ = try driver.click(&app, DrawnMenu.declare, DrawnMenu.anchor);
    var frame = try driver.frame(&app, DrawnMenu.declare, &.{});
    const entering = frame.rectOf(DrawnMenu.id.child("panel")).?;
    try testing.expect(scaleOf(frame).? < 1);
    frame = try waitFor(driver, &app, DrawnMenu.declare, drawing_tokens.motion.popover_enter.duration + 0.1);
    frame = try driver.frame(&app, DrawnMenu.declare, &.{});
    const entered = frame.rectOf(DrawnMenu.id.child("panel")).?;
    try testing.expect(entering.y < entered.y);
    try testing.expectEqual(@as(?f32, null), scaleOf(frame));
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());

    _ = try driver.pressKeys(&app, DrawnMenu.declare, &.{.escape});
    _ = try driver.frame(&app, DrawnMenu.declare, &.{.{ .environment = .{ .reduced_motion = true } }});
    _ = try driver.click(&app, DrawnMenu.declare, DrawnMenu.anchor);
    frame = try driver.frame(&app, DrawnMenu.declare, &.{});
    try testing.expectEqual(entered, frame.rectOf(DrawnMenu.id.child("panel")).?);
    try testing.expectEqual(@as(?f32, null), scaleOf(frame));
}

// =============================================================
// Popover
// =============================================================

const Pinnable = struct {
    const anchor: zui.Id = .of("filters");
    const id: zui.Id = .of("filters.panel");
    const inside: zui.Id = .of("filters.unread");
    const page: zui.Id = .of("page_button");

    open: bool = false,
    pinned: bool = false,
    position: [2]f32 = .{ 300, 200 },
    placement: zui_widgets.Placement = .below,
    unread: bool = false,
    page_clicks: u32 = 0,

    fn declare(app: *Pinnable, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both } });
        if (widgets.button(ui, page, "Page", .{})) app.page_clicks += 1;
        ui.open(.{ .id = anchor, .focusable = true, .floating = .{ .attach_to = .root, .offset = app.position }, .layout = .{ .sizing = .{ .width = .fixed(80), .height = .fixed(30) } } });
        ui.close();
        if (widgets.popover(ui, id, anchor, &app.open, .{ .placement = app.placement, .pinned = app.pinned, .label = "Filters" })) |panel| {
            _ = widgets.checkbox(ui, inside, "Unread only", &app.unread, .{});
            ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(200), .height = .fixed(100) } } });
            panel.end(ui);
        }
        ui.close();
    }
};

test "a popover opens on its side of the anchor and flips to the opposite one at each edge of the window" {
    const Case = struct { position: [2]f32, placement: zui_widgets.Placement, expect: enum { below, above, left, right } };
    const cases = [_]Case{
        .{ .position = .{ 300, 200 }, .placement = .below, .expect = .below },
        .{ .position = .{ 300, 540 }, .placement = .below, .expect = .above },
        .{ .position = .{ 300, 20 }, .placement = .above, .expect = .below },
        .{ .position = .{ 680, 200 }, .placement = .trailing, .expect = .left },
        .{ .position = .{ 20, 200 }, .placement = .leading, .expect = .right },
    };
    for (cases) |case| {
        var fixture: Fixture(Ui) = .{};
        try fixture.init();
        defer fixture.deinit();
        const driver = &fixture.driver;
        var app: Pinnable = .{ .position = case.position, .placement = case.placement, .open = true };
        try reducedMotion(driver, &app, Pinnable.declare);
        for (0..2) |_| {
            const frame = try driver.frame(&app, Pinnable.declare, &.{});
            const panel = frame.rectOf(Pinnable.id.child("panel")).?;
            const anchor = frame.rectOf(Pinnable.anchor).?;
            switch (case.expect) {
                .below => try testing.expect(panel.y >= anchor.y + anchor.height),
                .above => try testing.expect(panel.y + panel.height <= anchor.y),
                .left => try testing.expect(panel.x + panel.width <= anchor.x),
                .right => try testing.expect(panel.x >= anchor.x + anchor.width),
            }
            try testing.expect(panel.x >= 0 and panel.y >= 0 and panel.x + panel.width <= 800 and panel.y + panel.height <= 600);
        }
    }
}

test "a popover near the window's side moves along it to stay inside" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Pinnable = .{ .position = .{ 740, 200 }, .open = true };
    try reducedMotion(driver, &app, Pinnable.declare);
    _ = try driver.frame(&app, Pinnable.declare, &.{});
    const frame = try driver.frame(&app, Pinnable.declare, &.{});
    const panel = frame.rectOf(Pinnable.id.child("panel")).?;
    try testing.expect(panel.x + panel.width <= 800 - 8 + 0.01);
    try testing.expect(panel.y >= 230);
    try testing.expect(panel.width <= 360);
}

test "Escape, a click outside and a dismiss action close a popover and give focus back to its anchor" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Pinnable = .{};
    _ = try driver.frame(&app, Pinnable.declare, &.{});
    _ = try driver.click(&app, Pinnable.declare, Pinnable.anchor);
    try testing.expect(app.open);
    _ = try driver.frame(&app, Pinnable.declare, &.{});
    _ = try driver.click(&app, Pinnable.declare, Pinnable.inside);
    try testing.expect(app.unread);
    _ = try driver.pressKeys(&app, Pinnable.declare, &.{.escape});
    try testing.expect(!app.open);
    _ = try driver.frame(&app, Pinnable.declare, &.{});
    try testing.expect(fixture.ui.focused(Pinnable.anchor));

    _ = try driver.click(&app, Pinnable.declare, Pinnable.anchor);
    _ = try driver.frame(&app, Pinnable.declare, &.{});
    _ = try driver.click(&app, Pinnable.declare, Pinnable.page);
    try testing.expect(!app.open);
    try testing.expectEqual(@as(u32, 0), app.page_clicks);

    _ = try driver.click(&app, Pinnable.declare, Pinnable.anchor);
    _ = try driver.frame(&app, Pinnable.declare, &.{});
    const frame = try driver.frame(&app, Pinnable.declare, &.{});
    const node = try nodeOf(frame, Pinnable.id.child("panel"));
    try testing.expectEqual(zui.SemanticRole.dialog, node.role);
    try testing.expectEqualStrings("Filters", node.label);
    _ = try driver.action(&app, Pinnable.declare, Pinnable.id.child("panel"), .dismiss);
    try testing.expect(!app.open);
    _ = try driver.frame(&app, Pinnable.declare, &.{});
    try testing.expect(fixture.ui.focused(Pinnable.anchor));
}

test "a pinned popover stays open while the page beneath it takes clicks, and its anchor closes it" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Pinnable = .{ .pinned = true };
    _ = try driver.frame(&app, Pinnable.declare, &.{});
    _ = try driver.click(&app, Pinnable.declare, Pinnable.anchor);
    _ = try driver.frame(&app, Pinnable.declare, &.{});
    _ = try driver.click(&app, Pinnable.declare, Pinnable.page);
    try testing.expect(app.open);
    try testing.expectEqual(@as(u32, 1), app.page_clicks);
    _ = try driver.click(&app, Pinnable.declare, Pinnable.anchor);
    try testing.expect(!app.open);
}

// =============================================================
// Dialog
// =============================================================

const Booking = struct {
    const book: zui.Id = .of("book");
    const id: zui.Id = .of("confirm");
    const cancel: zui.Id = .of("confirm.cancel");
    const confirm: zui.Id = .of("confirm.book");

    open: bool = false,
    dismissible: bool = true,
    booked: u32 = 0,

    fn declare(app: *Booking, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(40), .child_gap = 20 } });
        _ = widgets.button(ui, .of("before"), "Before", .{});
        if (widgets.button(ui, book, "Book", .{})) app.open = true;
        if (widgets.dialog(ui, id, &app.open, .{ .title = "Book this cabin?", .description = "Three nights from Friday.", .dismissible = app.dismissible, .initial_focus = confirm })) |dialog| {
            dialog.actions(ui);
            if (widgets.button(ui, cancel, "Cancel", .{ .variant = .secondary })) app.open = false;
            if (widgets.button(ui, confirm, "Book", .{})) {
                app.booked += 1;
                app.open = false;
            }
            ui.close();
            dialog.end(ui);
        }
        ui.close();
    }
};

test "a dialog over the scrim focuses its initial element, keeps Tab inside, and gives focus back to its opener" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Booking = .{};
    _ = try driver.frame(&app, Booking.declare, &.{});
    _ = try driver.focus(&app, Booking.declare, Booking.book);
    _ = try driver.pressKeys(&app, Booking.declare, &.{.enter});
    try testing.expect(app.open);
    var frame = try driver.frame(&app, Booking.declare, &.{});
    try testing.expect(fixture.ui.focused(Booking.confirm));
    const node = try nodeOf(frame, Booking.id.child("panel"));
    try testing.expectEqual(zui.SemanticRole.dialog, node.role);
    try testing.expectEqualStrings("Book this cabin?", node.label);
    const scrim = frame.rectOf(Booking.id.child("scrim")).?;
    try testing.expectEqual(zui.Rect{ .x = 0, .y = 0, .width = 800, .height = 600 }, scrim);
    const panel = frame.rectOf(Booking.id.child("panel")).?;
    try testing.expectEqual(@as(f32, 480), panel.width);
    try testing.expectEqual(tokens.text_styles.get(.headline).size, textCommand(frame, "Book this cabin?").?.payload.text.style.size);
    try testing.expectEqual(color(.on_surface_muted), textCommand(frame, "Three nights from Friday.").?.payload.text.style.color);
    const cancel = frame.rectOf(Booking.cancel).?;
    const confirm = frame.rectOf(Booking.confirm).?;
    try testing.expect(cancel.x < confirm.x);
    try testing.expect(confirm.x + confirm.width > panel.x + panel.width - tokens.space(.xl) - 1);

    for (0..6) |_| {
        _ = try driver.pressKeys(&app, Booking.declare, &.{.tab});
        const focus = fixture.ui.focusedId();
        try testing.expect(focus.eql(Booking.cancel) or focus.eql(Booking.confirm) or focus.eql(Booking.id.child("close")));
    }
    _ = try driver.click(&app, Booking.declare, Booking.confirm);
    try testing.expectEqual(@as(u32, 1), app.booked);
    frame = try driver.frame(&app, Booking.declare, &.{});
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Booking.id.child("panel")));
    _ = try driver.frame(&app, Booking.declare, &.{});
    try testing.expect(fixture.ui.focused(Booking.book));
}

test "a dismissible dialog closes by Escape, its scrim, its close button and a dismiss action; one that is not stays" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Booking = .{};
    _ = try driver.frame(&app, Booking.declare, &.{});
    const closers = [_]enum { escape, scrim, close, dismiss }{ .escape, .scrim, .close, .dismiss };
    for (closers) |closer| {
        _ = try driver.click(&app, Booking.declare, Booking.book);
        _ = try driver.frame(&app, Booking.declare, &.{});
        switch (closer) {
            .escape => _ = try driver.pressKeys(&app, Booking.declare, &.{.escape}),
            .scrim => _ = try driver.clickAt(&app, Booking.declare, Booking.id.child("scrim"), .{ 0.02, 0.02 }),
            .close => _ = try driver.click(&app, Booking.declare, Booking.id.child("close")),
            .dismiss => _ = try driver.action(&app, Booking.declare, Booking.id.child("panel"), .dismiss),
        }
        try testing.expect(!app.open);
        _ = try driver.frame(&app, Booking.declare, &.{});
        try testing.expect(fixture.ui.focused(Booking.book));
    }
    try testing.expectEqual(@as(u32, 0), app.booked);

    app.dismissible = false;
    _ = try driver.click(&app, Booking.declare, Booking.book);
    var frame = try driver.frame(&app, Booking.declare, &.{});
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Booking.id.child("close")));
    try testing.expect(!(try nodeOf(frame, Booking.id.child("panel"))).actions.contains(.dismiss));
    _ = try driver.pressKeys(&app, Booking.declare, &.{.escape});
    _ = try driver.clickAt(&app, Booking.declare, Booking.id.child("scrim"), .{ 0.02, 0.02 });
    frame = try driver.frame(&app, Booking.declare, &.{});
    try testing.expect(app.open);
    try testing.expect(frame.rectOf(Booking.id.child("panel")) != null);
}

test "a dialog in a narrow window is a sheet along its bottom" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    driver.viewport = .{ 360, 640 };
    var app: Booking = .{ .open = true };
    try reducedMotion(driver, &app, Booking.declare);
    const frame = try driver.frame(&app, Booking.declare, &.{});
    const panel = frame.rectOf(Booking.id.child("panel")).?;
    try testing.expectEqual(@as(f32, 360), panel.width);
    try testing.expectEqual(@as(f32, 640), panel.y + panel.height);
}

test "a dialog's scrim fades in through dialog_enter, and at once under reduced motion" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Booking = .{};
    _ = try driver.frame(&app, Booking.declare, &.{});
    const scrim = color(.scrim);
    _ = try driver.click(&app, Booking.declare, Booking.book);
    var frame = try driver.frame(&app, Booking.declare, &.{});
    try testing.expectEqual(0, rectangles(frame, scrim));
    frame = try waitFor(driver, &app, Booking.declare, tokens.motion.dialog_enter.duration + 0.1);
    frame = try driver.frame(&app, Booking.declare, &.{});
    try testing.expectEqual(1, rectangles(frame, scrim));

    _ = try driver.pressKeys(&app, Booking.declare, &.{.escape});
    try reducedMotion(driver, &app, Booking.declare);
    _ = try driver.click(&app, Booking.declare, Booking.book);
    frame = try driver.frame(&app, Booking.declare, &.{});
    try testing.expectEqual(1, rectangles(frame, scrim));
}

// =============================================================
// Toasts
// =============================================================

const Notices = struct {
    const id: zui.Id = .of("notices");
    storage: [4]zui_widgets.ToastEntry = undefined,
    queue: zui_widgets.ToastQueue = undefined,
    undone: ?u32 = null,

    fn init(app: *Notices) void {
        app.queue = .init(&app.storage);
    }

    fn declare(app: *Notices, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both } });
        _ = widgets.button(ui, .of("page"), "Page", .{});
        ui.close();
        if (widgets.toasts(ui, id, &app.queue)) |tag| app.undone = tag;
    }

    fn toast(key: u32) zui.Id {
        return id.indexedChild("toast", key);
    }
};

test "toasts show the oldest three, the newest in front, each leaving after five seconds, and an idle app asks for a frame only then" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Notices = .{};
    app.init();
    for ([_][]const u8{ "One", "Two", "Three", "Four" }) |message| try testing.expect(app.queue.push(.{ .message = message }));
    try testing.expect(!app.queue.push(.{ .message = "Five" }));
    try testing.expectEqual(4, app.queue.waiting().len);

    try reducedMotion(driver, &app, Notices.declare);
    const shown_at = driver.now;
    var frame = try driver.frame(&app, Notices.declare, &.{});
    for (0..3) |key| try testing.expect(frame.rectOf(Notices.toast(@intCast(key))) != null);
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Notices.toast(3)));
    const newest = frame.rectOf(Notices.toast(2)).?;
    const oldest = frame.rectOf(Notices.toast(0)).?;
    try testing.expect(oldest.y < newest.y);
    try testing.expect(newest.y + newest.height <= 600 - tokens.space(.xl) + 0.01);
    try testing.expectEqual(3, rectangles(frame, color(.surface_inverse)));
    try testing.expectEqual(color(.on_surface_inverse), textCommand(frame, "Three").?.payload.text.style.color);
    const node = try nodeOf(frame, Notices.toast(2));
    try testing.expectEqual(zui.SemanticRole.status, node.role);
    try testing.expectEqualStrings("Three", node.label);
    try expectFrameAt(&fixture.ui, shown_at.addSeconds(5));

    frame = try waitFor(driver, &app, Notices.declare, 4.5);
    try testing.expect(frame.rectOf(Notices.toast(0)) != null);
    _ = try waitFor(driver, &app, Notices.declare, 0.6);
    frame = try driver.frame(&app, Notices.declare, &.{});
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Notices.toast(0)));
    try testing.expect(frame.rectOf(Notices.toast(3)) != null);
    try testing.expectEqual(1, app.queue.waiting().len);
}

test "a toast waits while the pointer is over it, and its action returns its tag and takes it away" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Notices = .{};
    app.init();
    _ = app.queue.push(.{ .message = "Booking confirmed", .action = "Undo", .tone = .success, .tag = 42 });
    try reducedMotion(driver, &app, Notices.declare);
    _ = try driver.frame(&app, Notices.declare, &.{});
    _ = try driver.hover(&app, Notices.declare, Notices.toast(0));
    var frame = try waitFor(driver, &app, Notices.declare, 6);
    try testing.expect(frame.rectOf(Notices.toast(0)) != null);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
    _ = try moveTo(driver, &app, Notices.declare, .{ 10, 10 });
    frame = try waitFor(driver, &app, Notices.declare, 4);
    try testing.expect(frame.rectOf(Notices.toast(0)) != null);

    _ = try driver.click(&app, Notices.declare, Notices.toast(0).child("action"));
    try testing.expectEqual(@as(?u32, 42), app.undone);
    frame = try driver.frame(&app, Notices.declare, &.{});
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Notices.toast(0)));
    try testing.expectEqual(0, app.queue.waiting().len);
}

test "Escape on a toast's action or a dismiss action takes it away, and a long message is cut at a character" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Notices = .{};
    app.init();
    _ = app.queue.push(.{ .message = "Saved", .action = "View" });
    _ = app.queue.push(.{ .message = "é" ** 100 });
    try testing.expectEqual(160, app.queue.waiting()[1].message().len);
    _ = try driver.frame(&app, Notices.declare, &.{});
    _ = try driver.focus(&app, Notices.declare, Notices.toast(0).child("action"));
    _ = try driver.pressKeys(&app, Notices.declare, &.{.escape});
    _ = try driver.frame(&app, Notices.declare, &.{});
    try testing.expectEqual(1, app.queue.waiting().len);
    _ = try driver.action(&app, Notices.declare, Notices.toast(1), .dismiss);
    _ = try driver.frame(&app, Notices.declare, &.{});
    try testing.expectEqual(0, app.queue.waiting().len);
    try testing.expectEqual(@as(?u32, null), app.undone);
}

const GhostNotices = struct {
    storage: [2]zui_widgets.ToastEntry = undefined,
    queue: zui_widgets.ToastQueue = undefined,

    fn declare(app: *GhostNotices, ui: *GhostUi) void {
        _ = ghost_widgets.toasts(ui, .of("ghosts"), &app.queue);
    }
};

test "a toast that leaves fades out through toast_exit where the context keeps ghosts, and at once under reduced motion" {
    var fixture: Fixture(GhostUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: GhostNotices = .{};
    app.queue = .init(&app.storage);
    const panel = ghost_tokens.colors.get(.idle).get(.surface_inverse);
    _ = app.queue.push(.{ .message = "Leaving" });
    _ = try driver.frame(&app, GhostNotices.declare, &.{});
    _ = try waitFor(driver, &app, GhostNotices.declare, 5.1);
    var frame = try driver.frame(&app, GhostNotices.declare, &.{});
    try testing.expectEqual(0, app.queue.waiting().len);
    var ghosts: usize = 0;
    for (frame.commands()) |command| {
        const drawn = if (command.payload == .rectangle) command.payload.rectangle.color else continue;
        if (drawn.r == panel.r and drawn.g == panel.g and drawn.b == panel.b) ghosts += 1;
    }
    try testing.expectEqual(1, ghosts);
    frame = try waitFor(driver, &app, GhostNotices.declare, ghost_tokens.motion.toast_exit.duration + 0.1);
    try testing.expectEqual(0, frame.commands().len);

    _ = try driver.frame(&app, GhostNotices.declare, &.{.{ .environment = .{ .reduced_motion = true } }});
    _ = app.queue.push(.{ .message = "Leaving at once" });
    _ = try driver.frame(&app, GhostNotices.declare, &.{});
    _ = try waitFor(driver, &app, GhostNotices.declare, 5.1);
    frame = try driver.frame(&app, GhostNotices.declare, &.{});
    try testing.expectEqual(0, frame.commands().len);
}

// =============================================================
// Every component, under review
// =============================================================

const page_room = 16;

fn auditGlance(comptime Component: type, permutation: zui_design.Permutation, preview: anytype) !void {
    var resolved: zui.design.Tokens(Ui, void) = .{};
    _ = zui_design.resolve(zui_design.default, permutation.axes.preferences(.{}), &resolved);
    const skinned: Widgets = .{ .skin = .{ .tokens = &resolved } };
    var events: [zui_design.Axes.environment_change_count]zui.Event = undefined;
    for (permutation.axes.environmentChanges(), &events) |change, *event| event.* = .{ .environment = change };

    const Shown = struct {
        widgets: Widgets,
        preview: @TypeOf(preview),

        fn declare(shown: *@This(), ui: *Ui) void {
            ui.open(.{
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(16) },
                .decoration = .{ .background = shown.widgets.skin.tokens.colors.get(.idle).get(.surface) },
            });
            Component.declare(shown.widgets, ui, shown.preview);
            ui.close();
        }
    };
    var shown: Shown = .{ .widgets = skinned, .preview = preview };
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.driver.frame(&shown, Shown.declare, &events);
    _ = try fixture.driver.frame(&shown, Shown.declare, &.{});
    const frame = try fixture.driver.pressKeys(&shown, Shown.declare, &.{.tab});
    const options: zui_design.AuditOptions = .fromTokens(&resolved, permutation.axes.contrast);
    var room: [page_room]zui_design.Finding = undefined;
    const findings = zui_design.audit(frame, options, &room);
    for (findings.slice()) |finding| std.debug.print("{s} {any}: {any}\n", .{ @typeName(Component), permutation.axes, finding.measured });
    try testing.expectEqual(0, findings.slice().len + findings.dropped);
}

test "every overlay's glance permutations audit clean" {
    inline for (zui_widgets.previews.overlays) |Component| {
        const Glance = zui_design.Permutations(Component, .glance);
        for (0..Glance.count) |index| {
            const permutation = Glance.at(index);
            try auditGlance(Component, permutation, Glance.preview(permutation));
        }
    }
}

test "every overlay audits clean in every scheme and density" {
    inline for (zui_widgets.previews.overlays) |Component| {
        const Glance = zui_design.Permutations(Component, .glance);
        for (std.enums.values(zui_design.Scheme)) |scheme| {
            for (std.enums.values(zui.design.Density)) |density| {
                for (0..Glance.preview_count) |preview| {
                    const permutation: zui_design.Permutation = .{
                        .axes = .{ .theme = if (scheme == .light or scheme == .light_high_contrast) .light else .dark, .contrast = scheme.environmentContrast(), .density = density },
                        .preview = @intCast(preview),
                    };
                    try auditGlance(Component, permutation, Glance.preview(permutation));
                }
            }
        }
    }
}

/// Declares every part of the overlays a skin styles: a tooltip on an
/// anchor focused from the keyboard, a menu of every kind of item, a
/// popover, a dialog and a toast of each tone, once `open` is set.
pub fn EveryOverlay(comptime SkinnedWidgets: type) type {
    return struct {
        const Self = @This();
        pub const ids = struct {
            pub const anchor: zui.Id = .of("overlay.anchor");
        };

        widgets: SkinnedWidgets,
        open: bool = false,
        menu_open: bool = true,
        popover_open: bool = true,
        dialog_open: bool = true,
        storage: [3]zui_widgets.ToastEntry = undefined,
        queue: zui_widgets.ToastQueue = undefined,

        pub fn init(form: *Self, skinned: SkinnedWidgets) void {
            form.* = .{ .widgets = skinned };
            form.queue = .init(&form.storage);
            _ = form.queue.push(.{ .message = "neutral" });
            _ = form.queue.push(.{ .message = "success", .tone = .success, .action = "Undo" });
            _ = form.queue.push(.{ .message = "danger", .tone = .danger });
        }

        pub fn declare(form: *Self, ui: anytype) void {
            const used = form.widgets;
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(200) }, .child_gap = 10 } });
            _ = used.button(ui, ids.anchor, "anchor", .{});
            used.tooltip(ui, ids.anchor, "tooltip", .{ .shortcut = "Ctrl+T" });
            ui.close();
            if (!form.open) return;
            if (used.menu(ui, .of("overlay.menu"), ids.anchor, &form.menu_open, .{})) |shown| {
                shown.section(ui, "section");
                _ = shown.item(ui, "checked", .{ .checked = true, .shortcut = "Ctrl+1" });
                _ = shown.item(ui, "icon", .{ .icon = .info });
                shown.separator(ui);
                _ = shown.item(ui, "danger", .{ .danger = true });
                shown.end(ui);
            }
            if (used.popover(ui, .of("overlay.popover"), ids.anchor, &form.popover_open, .{})) |shown| {
                used.label(ui, "popover");
                shown.end(ui);
            }
            if (used.dialog(ui, .of("overlay.dialog"), &form.dialog_open, .{ .title = "title", .description = "description" })) |shown| {
                shown.actions(ui);
                ui.close();
                shown.end(ui);
            }
            _ = used.toasts(ui, .of("overlay.toasts"), &form.queue);
        }
    };
}

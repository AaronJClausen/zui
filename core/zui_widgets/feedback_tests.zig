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
const Ui = zui.Context(.{ .limits = limits, .Text = Text, .ImageHandle = u32, .features = .{ .semantics = true } });
const ImagelessUi = zui.Context(.{ .limits = limits, .Text = Text });

fn TokensIn(comptime ContextType: type, comptime preferences: zui_design.Preferences) zui.design.Tokens(ContextType, void) {
    @setEvalBranchQuota(10_000_000);
    var resolved: zui.design.Tokens(ContextType, void) = .{};
    _ = zui_design.resolve(zui_design.default, preferences, &resolved);
    return resolved;
}

const tokens = TokensIn(Ui, .{ .theme = .dark });
const imageless_tokens = TokensIn(ImagelessUi, .{ .theme = .dark });
const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui));
const widgets: Widgets = .{ .skin = .{ .tokens = &tokens } };
const imageless_widgets: zui_widgets.Widgets(ImagelessUi, zui_widgets.DesignSkin(ImagelessUi)) = .{ .skin = .{ .tokens = &imageless_tokens } };

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

fn rectanglesIn(frame: anytype, fill: zui.Color, found: []zui.Rect) []zui.Rect {
    var count: usize = 0;
    for (frame.commands()) |command| {
        if (command.payload == .rectangle and command.payload.rectangle.color.eql(fill) and count < found.len) {
            found[count] = command.bounds;
            count += 1;
        }
    }
    return found[0..count];
}

fn rectangles(frame: anytype, fill: zui.Color) usize {
    var room: [64]zui.Rect = undefined;
    return rectanglesIn(frame, fill, &room).len;
}

fn rectangleAt(frame: anytype, bounds: zui.Rect) ?zui.Color {
    for (frame.commands()) |command| {
        const drawn = command.bounds;
        const covers = @abs(drawn.x - bounds.x) < 1 and @abs(drawn.y - bounds.y) < 1 and @abs(drawn.width - bounds.width) < 1 and @abs(drawn.height - bounds.height) < 1;
        if (command.payload == .rectangle and covers) return command.payload.rectangle.color;
    }
    return null;
}

fn imageCommand(frame: anytype) ?@TypeOf(frame.commands()[0]) {
    for (frame.commands()) |command| {
        if (command.payload == .image) return command;
    }
    return null;
}

fn skinColor(part: zui_widgets.Part) zui.Color {
    return widgets.skin.zuiStyle(part, .idle, &.{}).background.?;
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

fn centerOf(rect: zui.Rect) [2]f32 {
    return .{ rect.x + rect.width / 2, rect.y + rect.height / 2 };
}

// =============================================================
// Banner
// =============================================================

const Notice = struct {
    const id: zui.Id = .of("offline");
    const action = id.child("action");
    const close = id.child("close");

    tone: zui_widgets.BannerTone = .warning,
    dismissible: bool = true,
    acted: u32 = 0,
    dismissed: u32 = 0,

    fn declare(app: *Notice, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(480) } } });
        const shown = widgets.banner(ui, id, .{ .tone = app.tone, .title = "You are offline", .message = "Changes are saved here and sent when you reconnect.", .action = "Retry", .dismissible = app.dismissible });
        if (shown.acted) app.acted += 1;
        if (shown.dismissed) app.dismissed += 1;
        ui.close();
    }
};

test "a banner is a status in its tone's container, titled, with its message wrapped to its width" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Notice = .{};
    for (std.enums.values(zui_widgets.BannerTone)) |tone| {
        app.tone = tone;
        const frame = try fixture.driver.frame(&app, Notice.declare, &.{});
        const node = try nodeOf(frame, Notice.id);
        try testing.expectEqual(zui.SemanticRole.status, node.role);
        try testing.expectEqualStrings("You are offline", node.label);
        try testing.expectEqual(1, rectangles(frame, skinColor(tone.part())));
        const banner = frame.rectOf(Notice.id).?;
        try testing.expectEqual(480, banner.width);
        const ink = widgets.skin.zuiStyle(tone.part(), .idle, &.{}).text.color;
        try testing.expectEqual(ink, textCommand(frame, "You are offline").?.payload.text.style.color);
        try testing.expect(textCommand(frame, "Retry") != null);
    }
}

test "a banner's action answers a click, Enter and Space" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Notice = .{};
    _ = try driver.frame(&app, Notice.declare, &.{});
    _ = try driver.click(&app, Notice.declare, Notice.action);
    try testing.expectEqual(1, app.acted);
    _ = try driver.focus(&app, Notice.declare, Notice.action);
    _ = try driver.pressKeys(&app, Notice.declare, &.{.enter});
    _ = try driver.pressKeys(&app, Notice.declare, &.{.space});
    try testing.expectEqual(3, app.acted);
    try testing.expectEqual(0, app.dismissed);
}

test "a dismissible banner is dismissed by its close button, Escape on a button and a dismiss action; one that is not has none" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Notice = .{};
    var frame = try driver.frame(&app, Notice.declare, &.{});
    try testing.expect((try nodeOf(frame, Notice.id)).actions.contains(.dismiss));
    try testing.expectEqualStrings("Dismiss", (try nodeOf(frame, Notice.close)).label);
    _ = try driver.click(&app, Notice.declare, Notice.close);
    try testing.expectEqual(1, app.dismissed);
    _ = try driver.focus(&app, Notice.declare, Notice.action);
    _ = try driver.pressKeys(&app, Notice.declare, &.{.escape});
    try testing.expectEqual(2, app.dismissed);
    _ = try driver.action(&app, Notice.declare, Notice.id, .dismiss);
    try testing.expectEqual(3, app.dismissed);
    try testing.expectEqual(0, app.acted);

    app.dismissible = false;
    frame = try driver.frame(&app, Notice.declare, &.{});
    try testing.expect(!(try nodeOf(frame, Notice.id)).actions.contains(.dismiss));
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Notice.close));
    _ = try driver.focus(&app, Notice.declare, Notice.action);
    _ = try driver.pressKeys(&app, Notice.declare, &.{.escape});
    try testing.expectEqual(3, app.dismissed);
}

// =============================================================
// Badge
// =============================================================

const Badges = struct {
    const pill: zui.Id = .of("plan");
    const dot: zui.Id = .of("unread");
    const counted: zui.Id = .of("inbox");
    const few: zui.Id = .of("drafts");

    tone: zui_widgets.BadgeTone = .accent,

    fn declare(app: *Badges, ui: *Ui) void {
        ui.open(.{ .layout = .{ .child_gap = 8 } });
        widgets.badge(ui, pill, "Beta", .{ .tone = app.tone });
        widgets.badge(ui, dot, "", .{ .tone = app.tone, .label = "Unread messages" });
        widgets.badgeCount(ui, counted, 128, .{ .tone = app.tone, .label = "Unread" });
        widgets.badgeCount(ui, few, 7, .{ .tone = app.tone });
        ui.close();
    }
};

test "a badge is its text in a pill of its tone, and without text a labeled dot" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Badges = .{};
    for (std.enums.values(zui_widgets.BadgeTone)) |tone| {
        app.tone = tone;
        const frame = try fixture.driver.frame(&app, Badges.declare, &.{});
        const look = widgets.skin.zuiStyle(tone.part(), .idle, &.{});
        try testing.expectEqual(look.text.color, textCommand(frame, "Beta").?.payload.text.style.color);
        for ([_]zui.Id{ Badges.pill, Badges.counted, Badges.few }) |pill_id| {
            try testing.expectEqual(look.background.?, rectangleAt(frame, frame.rectOf(pill_id).?).?);
        }
        try testing.expectEqualStrings("Beta", (try nodeOf(frame, Badges.pill)).label);
        const pill = frame.rectOf(Badges.pill).?;
        try testing.expect(pill.width >= pill.height);
        const dot = frame.rectOf(Badges.dot).?;
        const dot_look = widgets.skin.zuiStyle(tone.dotPart(), .idle, &.{});
        try testing.expectEqual(dot_look.size[0], dot.width);
        try testing.expectEqual(dot.width, dot.height);
        try testing.expect(dot_look.border != null);
        try testing.expectEqualStrings("Unread messages", (try nodeOf(frame, Badges.dot)).label);
    }
}

test "a count past 99 shows 99+, and its label names what is counted" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Badges = .{};
    const frame = try fixture.driver.frame(&app, Badges.declare, &.{});
    try testing.expect(textCommand(frame, "99+") != null);
    try testing.expect(textCommand(frame, "128") == null);
    try testing.expectEqualStrings("Unread: 99+", (try nodeOf(frame, Badges.counted)).label);
    try testing.expect(textCommand(frame, "7") != null);
    try testing.expectEqualStrings("7", (try nodeOf(frame, Badges.few)).label);
    const numerals = widgets.skin.zuiStyle(.label_numeric, .idle, &.{}).text.font;
    try testing.expectEqual(numerals, textCommand(frame, "7").?.payload.text.style.font);
}

// =============================================================
// Spinner
// =============================================================

const Waiting = struct {
    const id: zui.Id = .of("saving");

    fn declare(_: *Waiting, ui: *Ui) void {
        ui.open(.{ .layout = .{ .padding = .all(20) } });
        widgets.spinner(ui, id, .{ .label = "Saving" });
        ui.close();
    }
};

fn middleArcDot(frame: anytype) ![2]f32 {
    var room: [16]zui.Rect = undefined;
    const dots = rectanglesIn(frame, skinColor(.spinner_arc), &room);
    if (dots.len != 7) return error.TestUnexpectedResult;
    return centerOf(dots[3]);
}

test "a spinner turns its arc, asking for every frame, and reports itself as progress without a value" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Waiting = .{};
    var frame = try driver.frame(&app, Waiting.declare, &.{});
    const node = try nodeOf(frame, Waiting.id);
    try testing.expectEqual(zui.SemanticRole.progress_bar, node.role);
    try testing.expectEqualStrings("Saving", node.label);
    try testing.expectEqual(zui.SemanticValue.none, node.value);
    try testing.expectEqual(zui.NextFrame.immediately, fixture.ui.nextFrame());
    const before = try middleArcDot(frame);
    frame = try waitFor(driver, &app, Waiting.declare, 0.2);
    const after = try middleArcDot(frame);
    try testing.expect(before[0] != after[0] or before[1] != after[1]);
    const circle = frame.rectOf(Waiting.id).?;
    try testing.expectEqual(circle.width, circle.height);
}

test "under reduced motion a spinner holds its arc at the top and asks for no frame" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Waiting = .{};
    try reducedMotion(driver, &app, Waiting.declare);
    const frame = try waitFor(driver, &app, Waiting.declare, 0.3);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
    const circle = frame.rectOf(Waiting.id).?;
    const top = try middleArcDot(frame);
    try testing.expectApproxEqAbs(centerOf(circle)[0], top[0], 0.01);
    try testing.expect(top[1] < centerOf(circle)[1]);
    const again = try middleArcDot(try waitFor(driver, &app, Waiting.declare, 0.3));
    try testing.expectEqual(top, again);
}

// =============================================================
// Skeleton
// =============================================================

const Placeholder = struct {
    const lines: zui.Id = .of("profile.bio");
    const block: zui.Id = .of("profile.cover");
    const circle: zui.Id = .of("profile.photo");

    fn declare(_: *Placeholder, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(300) }, .child_gap = 12 } });
        widgets.skeleton(ui, circle, .{ .shape = .{ .circle = 48 } });
        widgets.skeleton(ui, lines, .{ .shape = .{ .lines = 3 } });
        widgets.skeleton(ui, block, .{ .shape = .{ .block = 2 } });
        ui.close();
    }
};

test "a skeleton's lines end in a shorter one, its block keeps its aspect and its circle is round" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Placeholder = .{};
    const frame = try fixture.driver.frame(&app, Placeholder.declare, &.{});
    const first = frame.rectOf(Placeholder.lines.indexedChild("line", 0)).?;
    const last = frame.rectOf(Placeholder.lines.indexedChild("line", 2)).?;
    try testing.expectEqual(300, first.width);
    try testing.expectApproxEqAbs(0.6 * first.width, last.width, 0.5);
    try testing.expect(last.y > first.y);
    try testing.expectEqual(skinColor(.skeleton_line), rectangleAt(frame, first).?);
    const block = frame.rectOf(Placeholder.block).?;
    try testing.expectApproxEqAbs(block.width / 2, block.height, 0.5);
    const circle = frame.rectOf(Placeholder.circle).?;
    try testing.expectEqual(48, circle.width);
    try testing.expectEqual(48, circle.height);
    try testing.expectEqualStrings("Loading", (try nodeOf(frame, Placeholder.lines)).label);
    try testing.expectEqual(zui.SemanticRole.progress_bar, (try nodeOf(frame, Placeholder.block)).role);
}

test "a skeleton shimmers across its lines and pulses its circle, asking for every frame" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Placeholder = .{};
    _ = try driver.frame(&app, Placeholder.declare, &.{});
    var frame = try waitFor(driver, &app, Placeholder.declare, 0.4);
    try testing.expectEqual(zui.NextFrame.immediately, fixture.ui.nextFrame());
    var room: [8]zui.Rect = undefined;
    const band_before = rectanglesIn(frame, skinColor(.skeleton_shimmer), &room)[0].x;
    try testing.expectEqual(4, rectangles(frame, skinColor(.skeleton_shimmer)));
    const circle = frame.rectOf(Placeholder.circle).?;
    try testing.expect(!rectangleAt(frame, circle).?.eql(skinColor(.skeleton_circle)));
    frame = try waitFor(driver, &app, Placeholder.declare, 0.4);
    try testing.expect(rectanglesIn(frame, skinColor(.skeleton_shimmer), &room)[0].x > band_before);
}

test "under reduced motion a skeleton holds still and asks for no frame" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Placeholder = .{};
    try reducedMotion(driver, &app, Placeholder.declare);
    const frame = try waitFor(driver, &app, Placeholder.declare, 0.4);
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
    try testing.expectEqual(0, rectangles(frame, skinColor(.skeleton_shimmer)));
    try testing.expectEqual(skinColor(.skeleton_circle), rectangleAt(frame, frame.rectOf(Placeholder.circle).?).?);
}

// =============================================================
// Progress bar
// =============================================================

const Upload = struct {
    const id: zui.Id = .of("upload");

    done: ?f32 = 0.4,

    fn declare(app: *Upload, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(200) } } });
        widgets.progressBar(ui, id, app.done, .{ .label = "Uploading" });
        ui.close();
    }
};

fn fillOf(frame: anytype) !zui.Rect {
    var room: [4]zui.Rect = undefined;
    const fills = rectanglesIn(frame, skinColor(.progress_fill), &room);
    if (fills.len != 1) return error.TestUnexpectedResult;
    return fills[0];
}

test "a progress bar fills to its value, easing to each new one, and reports it" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Upload = .{};
    var frame = try driver.frame(&app, Upload.declare, &.{});
    const node = try nodeOf(frame, Upload.id);
    try testing.expectEqual(zui.SemanticRole.progress_bar, node.role);
    try testing.expectEqualStrings("Uploading", node.label);
    try testing.expectApproxEqAbs(0.4, node.value.range.value, 1e-6);
    try testing.expectApproxEqAbs(80, (try fillOf(frame)).width, 0.5);

    app.done = 0.9;
    _ = try driver.frame(&app, Upload.declare, &.{});
    frame = try driver.frame(&app, Upload.declare, &.{});
    const easing = (try fillOf(frame)).width;
    try testing.expect(easing > 80 and easing < 180);
    try testing.expectApproxEqAbs(0.9, (try nodeOf(frame, Upload.id)).value.range.value, 1e-6);
    frame = try waitFor(driver, &app, Upload.declare, 0.4);
    try testing.expectApproxEqAbs(180, (try fillOf(frame)).width, 0.5);

    app.done = 7;
    _ = try driver.frame(&app, Upload.declare, &.{});
    frame = try waitFor(driver, &app, Upload.declare, 0.4);
    try testing.expectApproxEqAbs(1, (try nodeOf(frame, Upload.id)).value.range.value, 1e-6);
    try testing.expectApproxEqAbs(200, (try fillOf(frame)).width, 0.5);
}

test "an indeterminate progress bar slides a third of its track, or holds it at the middle under reduced motion" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Upload = .{ .done = null };
    var frame = try driver.frame(&app, Upload.declare, &.{});
    try testing.expectEqual(zui.SemanticValue.none, (try nodeOf(frame, Upload.id)).value);
    try testing.expectEqual(zui.NextFrame.immediately, fixture.ui.nextFrame());
    const before = try fillOf(frame);
    try testing.expectApproxEqAbs(60, before.width, 0.5);
    frame = try waitFor(driver, &app, Upload.declare, 0.3);
    try testing.expect((try fillOf(frame)).x != before.x);

    try reducedMotion(driver, &app, Upload.declare);
    frame = try waitFor(driver, &app, Upload.declare, 0.3);
    const track = frame.rectOf(Upload.id).?;
    var middle: ?zui.Rect = null;
    for (frame.commands()) |command| {
        if (command.payload == .rectangle and command.bounds.width < track.width) middle = command.bounds;
    }
    try testing.expectApproxEqAbs(centerOf(track)[0], centerOf(middle.?)[0], 0.5);
}

// =============================================================
// Empty state
// =============================================================

const NoResults = struct {
    const id: zui.Id = .of("no_results");

    with_action: bool = true,
    cleared: u32 = 0,

    fn declare(app: *NoResults, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(600) } } });
        if (widgets.emptyState(ui, id, .{ .icon = .search, .title = "No matches", .message = "Try fewer filters or another word.", .action = if (app.with_action) "Clear filters" else "", .action_variant = .secondary })) app.cleared += 1;
        ui.close();
    }
};

test "an empty state centers its icon, title, message and action, and reports its action" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: NoResults = .{};
    var frame = try driver.frame(&app, NoResults.declare, &.{});
    const area = frame.rectOf(NoResults.id).?;
    const title = textCommand(frame, "No matches").?.bounds;
    try testing.expectApproxEqAbs(centerOf(area)[0], centerOf(title)[0], 1);
    try testing.expectEqual(1, rectangles(frame, skinColor(.empty_state_illustration)));
    try testing.expectEqualStrings("No matches", (try nodeOf(frame, NoResults.id)).label);
    const button = frame.rectOf(NoResults.id.child("action")).?;
    try testing.expect(button.y > title.y);
    try testing.expectApproxEqAbs(centerOf(area)[0], centerOf(button)[0], 1);
    _ = try driver.click(&app, NoResults.declare, NoResults.id.child("action"));
    try testing.expectEqual(1, app.cleared);

    app.with_action = false;
    frame = try driver.frame(&app, NoResults.declare, &.{});
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(NoResults.id.child("action")));
}

// =============================================================
// Avatar
// =============================================================

const People = struct {
    const author: zui.Id = .of("author");
    const editors: zui.Id = .of("editors");
    const names = [_][]const u8{ "Ana Ribeiro", "Kofi Mensah", "Mei Chen", "Lars Berg", "Priya Nair" };

    image: ?u32 = null,
    presence: ?zui_widgets.Presence = .online,

    fn declare(app: *People, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .padding = .all(20), .child_gap = 20 } });
        widgets.avatar(ui, author, .{ .name = "Ana Ribeiro", .image = app.image, .size = .large, .presence = app.presence });
        widgets.avatarStack(ui, editors, &names, .{});
        ui.close();
    }
};

test "an avatar without its image shows the initials of a name on its category's container" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: People = .{};
    const frame = try fixture.driver.frame(&app, People.declare, &.{});
    const colors = tokens.categories.get(.of("Ana Ribeiro"));
    try testing.expectEqual(colors.on_container, textCommand(frame, "AR").?.payload.text.style.color);
    try testing.expect(rectangles(frame, colors.container) >= 1);
    const circle = frame.rectOf(People.author).?;
    try testing.expectEqual(48, circle.width);
    try testing.expectEqual(48, circle.height);
    const node = try nodeOf(frame, People.author);
    try testing.expectEqual(zui.SemanticRole.image, node.role);
    try testing.expectEqualStrings("Ana Ribeiro, online", node.label);
    try testing.expect(imageCommand(frame) == null);
}

test "an avatar's presence dot sits at its trailing bottom corner, the left one right to left" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: People = .{};
    for ([_]zui.ReadingDirection{ .left_to_right, .right_to_left }) |direction| {
        const frame = try driver.frame(&app, People.declare, &.{.{ .environment = .{ .direction = direction } }});
        const circle = frame.rectOf(People.author).?;
        var room: [4]zui.Rect = undefined;
        const dots = rectanglesIn(frame, skinColor(.avatar_presence_online), &room);
        try testing.expectEqual(1, dots.len);
        const dot = dots[0];
        try testing.expectApproxEqAbs(circle.y + circle.height, dot.y + dot.height, 0.01);
        switch (direction) {
            .left_to_right => try testing.expectApproxEqAbs(circle.x + circle.width, dot.x + dot.width, 0.01),
            .right_to_left => try testing.expectApproxEqAbs(circle.x, dot.x, 0.01),
        }
    }
    app.presence = null;
    const frame = try driver.frame(&app, People.declare, &.{});
    try testing.expectEqualStrings("Ana Ribeiro", (try nodeOf(frame, People.author)).label);
    try testing.expectEqual(0, rectangles(frame, skinColor(.avatar_presence_online)));
}

test "an avatar with its image draws it in place of the initials" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: People = .{ .image = 17 };
    const frame = try fixture.driver.frame(&app, People.declare, &.{});
    const image = imageCommand(frame).?;
    try testing.expectEqual(17, image.payload.image.handle);
    const circle = frame.rectOf(People.author).?;
    try testing.expectEqual(circle, image.bounds);
    for (frame.commands()) |command| {
        if (command.payload == .text) try testing.expect(!circle.contains(centerOf(command.bounds)));
    }
}

test "a stack overlaps its avatars by a quarter, ringed, and counts the rest" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: People = .{};
    const frame = try fixture.driver.frame(&app, People.declare, &.{});
    const node = try nodeOf(frame, People.editors);
    try testing.expectEqual(zui.SemanticRole.group, node.role);
    try testing.expectEqualStrings("5 people", node.label);
    const first = frame.rectOf(People.editors.indexedChild("avatar", 0)).?;
    const second = frame.rectOf(People.editors.indexedChild("avatar", 1)).?;
    try testing.expectEqual(24, first.width);
    try testing.expectApproxEqAbs(first.x + 18, second.x, 0.01);
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(People.editors.indexedChild("avatar", 3)));
    try testing.expect(textCommand(frame, "+2") != null);
    try testing.expect(textCommand(frame, "KM") != null);
    try testing.expect(textCommand(frame, "LB") == null);
    var ringed: usize = 0;
    const ring = widgets.skin.zuiStyle(.avatar_stack, .idle, &.{}).border.?;
    const stack = frame.rectOf(People.editors).?;
    for (frame.commands()) |command| {
        if (command.payload == .border and command.payload.border.color.eql(ring.color) and stack.contains(centerOf(command.bounds))) ringed += 1;
    }
    try testing.expectEqual(4, ringed);
}

test "initials take the first letter of the first and last words, upper-cased where they are ASCII" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("AR", zui_widgets.initialsOf("Ana Ribeiro", &buffer));
    try testing.expectEqualStrings("AR", zui_widgets.initialsOf("  ana maria   ribeiro ", &buffer));
    try testing.expectEqualStrings("M", zui_widgets.initialsOf("mei", &buffer));
    try testing.expectEqualStrings("ÉZ", zui_widgets.initialsOf("Émile Zola", &buffer));
    try testing.expectEqualStrings("", zui_widgets.initialsOf(" \t", &buffer));
}

test "a name always takes the same category, and the eight are all taken" {
    try testing.expectEqual(zui.design.Category.of("Ana Ribeiro"), zui.design.Category.of("Ana Ribeiro"));
    var taken: std.EnumSet(zui.design.Category) = .initEmpty();
    for (0..64) |index| {
        var name_bytes: [16]u8 = undefined;
        taken.insert(.of(try std.fmt.bufPrint(&name_bytes, "person {d}", .{index})));
    }
    try testing.expectEqual(8, taken.count());
}

// =============================================================
// Async image
// =============================================================

const ImageStatus = zui.Status(error{NotFound}!u32);

const Cover = struct {
    const id: zui.Id = .of("cover");

    status: ImageStatus = .{ .running = {} },

    fn declare(app: *Cover, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(300) } } });
        widgets.asyncImage(ui, id, app.status, .{ .aspect = 3.0 / 2.0, .label = "The book's cover" });
        ui.close();
    }
};

test "an async image shimmers while it loads, fades its image in once ready and shows a broken image once failed" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Cover = .{};
    _ = try driver.frame(&app, Cover.declare, &.{});
    var frame = try driver.frame(&app, Cover.declare, &.{});
    const box = frame.rectOf(Cover.id).?;
    try testing.expectEqual(300, box.width);
    try testing.expectApproxEqAbs(200, box.height, 0.5);
    try testing.expectEqual(1, rectangles(frame, skinColor(.skeleton_shimmer)));
    try testing.expectEqual(zui.NextFrame.immediately, fixture.ui.nextFrame());
    const node = try nodeOf(frame, Cover.id);
    try testing.expectEqual(zui.SemanticRole.image, node.role);
    try testing.expectEqualStrings("The book's cover", node.label);

    app.status = .{ .ready = 5 };
    frame = try driver.frame(&app, Cover.declare, &.{});
    const fading = imageCommand(frame).?;
    try testing.expectEqual(5, fading.payload.image.handle);
    try testing.expect(fading.payload.image.tint.a < 1);
    _ = try waitFor(driver, &app, Cover.declare, 0.3);
    frame = try driver.frame(&app, Cover.declare, &.{});
    try testing.expectEqual(zui.Color.white, imageCommand(frame).?.payload.image.tint);
    try testing.expectEqual(0, rectangles(frame, skinColor(.async_image)));

    app.status = .{ .failed = error.NotFound };
    frame = try driver.frame(&app, Cover.declare, &.{});
    try testing.expect(imageCommand(frame) == null);
    try testing.expect(textCommand(frame, "!") != null);
}

test "under reduced motion a loading image holds still and asks for no frame" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Cover = .{};
    try reducedMotion(driver, &app, Cover.declare);
    const frame = try driver.frame(&app, Cover.declare, &.{});
    try testing.expectEqual(0, rectangles(frame, skinColor(.skeleton_shimmer)));
    try testing.expectEqual(1, rectangles(frame, skinColor(.async_image)));
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());
}

test "an async image takes a value with a status, and a context without images draws a ready image's frame alone" {
    const ImagelessStatus = zui.Status(error{NotFound}!void);
    const Imageless = struct {
        const Self = @This();
        const id: zui.Id = .of("thumbnail");

        status: ImagelessStatus = .canceled,

        const View = struct {
            shown: *const Self,

            pub fn status(view: View) ImagelessStatus {
                return view.shown.status;
            }
        };

        fn declare(app: *@This(), ui: *ImagelessUi) void {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(100) } } });
            imageless_widgets.asyncImage(ui, id, View{ .shown = app }, .{ .aspect = 1 });
            ui.close();
        }
    };
    var fixture: Fixture(ImagelessUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Imageless = .{};
    var frame = try driver.frame(&app, Imageless.declare, &.{});
    try testing.expect(textCommand(frame, "!") != null);
    app.status = .{ .ready = {} };
    _ = try waitFor(driver, &app, Imageless.declare, 0.3);
    frame = try driver.frame(&app, Imageless.declare, &.{});
    try testing.expect(textCommand(frame, "!") == null);
    const box = frame.rectOf(Imageless.id).?;
    try testing.expectEqual(100, box.width);
    try testing.expectEqual(100, box.height);
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

test "every feedback and media component's glance permutations audit clean" {
    inline for (zui_widgets.previews.feedback ++ zui_widgets.previews.media) |Component| {
        const Glance = zui_design.Permutations(Component, .glance);
        for (0..Glance.count) |index| {
            const permutation = Glance.at(index);
            try auditGlance(Component, permutation, Glance.preview(permutation));
        }
    }
}

test "every feedback and media component audits clean in every scheme and density" {
    inline for (zui_widgets.previews.feedback ++ zui_widgets.previews.media) |Component| {
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

test "an avatar of every category meets its text's contrast in every scheme" {
    const Everyone = struct {
        widgets: Widgets,

        fn declare(shown: *@This(), ui: *Ui) void {
            ui.open(.{
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(16), .child_gap = 8 },
                .decoration = .{ .background = shown.widgets.skin.tokens.colors.get(.idle).get(.surface) },
            });
            inline for (comptime std.enums.values(zui.design.Category)) |category| {
                shown.widgets.avatar(ui, .of(@tagName(category)), .{ .name = comptime nameIn(category), .size = .large });
            }
            ui.close();
        }
    };
    inline for (comptime std.enums.values(zui_design.Scheme)) |scheme| {
        const theme: zui.Environment.Theme = if (scheme == .light or scheme == .light_high_contrast) .light else .dark;
        const resolved = comptime TokensIn(Ui, .{ .theme = theme, .contrast = scheme.environmentContrast() });
        var shown: Everyone = .{ .widgets = .{ .skin = .{ .tokens = &resolved } } };
        var fixture: Fixture(Ui) = .{};
        try fixture.init();
        defer fixture.deinit();
        const frame = try fixture.driver.frame(&shown, Everyone.declare, &.{.{ .environment = .{ .theme = theme } }});
        var room: [page_room]zui_design.Finding = undefined;
        const findings = zui_design.audit(frame, .fromTokens(&resolved, scheme.environmentContrast()), &room);
        for (findings.slice()) |finding| std.debug.print("{s}: {any}\n", .{ scheme.name(), finding.measured });
        try testing.expectEqual(0, findings.slice().len + findings.dropped);
    }
}

/// A name of two words that falls in `category`.
pub fn nameIn(comptime category: zui.design.Category) []const u8 {
    @setEvalBranchQuota(100_000);
    var index: usize = 0;
    while (true) : (index += 1) {
        const name = std.fmt.comptimePrint("Person {d}", .{index});
        if (zui.design.Category.of(name) == category) return name;
    }
}

/// Declares every part of the feedback and media components a skin
/// styles: a banner and a badge of each tone, a dot and a count, a spinner,
/// a skeleton of each shape, both kinds of progress bar, an empty state, an
/// avatar of each size, category and presence, a stack with its count, and
/// an image loading and failed.
pub fn EveryFeedback(comptime SkinnedWidgets: type) type {
    return struct {
        const Self = @This();

        widgets: SkinnedWidgets,

        pub fn declare(form: *Self, ui: anytype) void {
            const used = form.widgets;
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(300) }, .child_gap = 4 } });
            inline for (comptime std.enums.values(zui_widgets.BannerTone)) |tone| {
                _ = used.banner(ui, .of("feedback.banner." ++ @tagName(tone)), .{ .tone = tone, .title = "title", .message = "message", .action = "action", .dismissible = true });
            }
            inline for (comptime std.enums.values(zui_widgets.BadgeTone)) |tone| {
                used.badge(ui, .of("feedback.badge." ++ @tagName(tone)), "badge", .{ .tone = tone });
                used.badge(ui, .of("feedback.dot." ++ @tagName(tone)), "", .{ .tone = tone, .label = "dot" });
            }
            used.badgeCount(ui, .of("feedback.count"), 3, .{});
            used.spinner(ui, .of("feedback.spinner"), .{});
            used.skeleton(ui, .of("feedback.lines"), .{ .shape = .{ .lines = 2 } });
            used.skeleton(ui, .of("feedback.block"), .{ .shape = .{ .block = 4 } });
            used.skeleton(ui, .of("feedback.circle"), .{ .shape = .{ .circle = 24 } });
            used.progressBar(ui, .of("feedback.progress"), 0.5, .{});
            used.progressBar(ui, .of("feedback.indeterminate"), null, .{});
            _ = used.emptyState(ui, .of("feedback.empty"), .{ .icon = .search, .title = "title", .message = "message", .action = "action" });
            inline for (comptime std.enums.values(zui_widgets.AvatarSize)) |size| {
                used.avatar(ui, .of("feedback.avatar." ++ @tagName(size)), .{ .name = "Avatar", .size = size });
            }
            inline for (comptime std.enums.values(zui.design.Category)) |category| {
                used.avatar(ui, .of("feedback.category." ++ @tagName(category)), .{ .name = comptime nameIn(category), .size = .small });
            }
            inline for (comptime std.enums.values(zui_widgets.Presence)) |presence| {
                used.avatar(ui, .of("feedback.presence." ++ @tagName(presence)), .{ .name = "Avatar", .size = .small, .presence = presence });
            }
            used.avatarStack(ui, .of("feedback.stack"), &.{ "a", "b", "c", "d" }, .{ .most = 2 });
            const Loading = zui.Status(error{NotFound}!@TypeOf(used).ImageHandle);
            used.asyncImage(ui, .of("feedback.loading"), Loading{ .running = {} }, .{ .width = .fixed(40) });
            used.asyncImage(ui, .of("feedback.failed"), Loading{ .failed = error.NotFound }, .{ .width = .fixed(40) });
            ui.close();
        }
    };
}

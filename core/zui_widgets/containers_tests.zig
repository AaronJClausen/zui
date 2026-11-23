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
const Ui = zui.Context(.{ .limits = limits, .Text = Text, .features = .{ .semantics = true }, .commands = .initOne(.shadow) });
const DrawingUi = zui.Context(.{ .limits = limits, .Text = Text, .commands = .initMany(&.{ .gradient, .transform, .shadow }) });

fn TokensIn(comptime ContextType: type, comptime preferences: zui_design.Preferences) zui.design.Tokens(ContextType, void) {
    @setEvalBranchQuota(10_000_000);
    var resolved: zui.design.Tokens(ContextType, void) = .{};
    _ = zui_design.resolve(zui_design.default, preferences, &resolved);
    return resolved;
}

const tokens = TokensIn(Ui, .{ .theme = .dark });
const drawing_tokens = TokensIn(DrawingUi, .{ .theme = .dark });
const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui));
const widgets: Widgets = .{ .skin = .{ .tokens = &tokens } };
const DrawingWidgets = zui_widgets.Widgets(DrawingUi, zui_widgets.DesignSkin(DrawingUi));
const drawing_widgets: DrawingWidgets = .{ .skin = .{ .tokens = &drawing_tokens } };

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

fn rectangleOf(frame: anytype, id: zui.Id) ?@TypeOf(frame.commands()[0].payload.rectangle) {
    for (frame.commands()) |command| {
        if (command.id == id.hash and command.payload == .rectangle) return command.payload.rectangle;
    }
    return null;
}

fn shadowOf(frame: anytype, id: zui.Id) ?@TypeOf(frame.commands()[0].payload.shadow) {
    for (frame.commands()) |command| {
        if (command.id == id.hash and command.payload == .shadow) return command.payload.shadow;
    }
    return null;
}

fn textBounds(frame: anytype, content: []const u8) ?zui.Rect {
    for (frame.commands()) |command| {
        if (command.payload == .text and std.mem.eql(u8, command.payload.text.content, content)) return command.bounds;
    }
    return null;
}

/// Equal but for snapping to whole pixels.
fn expectNear(expected: zui.Rect, actual: zui.Rect) !void {
    inline for (.{ "x", "y", "width", "height" }) |field| try testing.expectApproxEqAbs(@field(expected, field), @field(actual, field), 0.5);
}

fn sameShadow(declared: anytype, drawn: anytype) bool {
    return declared.color.eql(drawn.color) and std.meta.eql(declared.offset, drawn.offset) and declared.blur == drawn.blur;
}

fn expectShadow(declared: anytype, drawn: anytype) !void {
    const shadow = drawn orelse return error.NoShadow;
    try testing.expect(sameShadow(declared, shadow));
}

/// The `.vertical` scrollbar's thumb, as the box drawn inside its hit area.
fn thumbRectangle(frame: anytype, area: zui.Id) !zui.Rect {
    const thumb = area.child("vertical_track").child("thumb");
    const hit = frame.rectOf(thumb) orelse return error.NoThumb;
    for (frame.commands()) |command| {
        if (command.payload != .rectangle) continue;
        const bounds = command.bounds;
        if (bounds.x >= hit.x and bounds.x + bounds.width <= hit.x + hit.width + 0.01 and bounds.y >= hit.y - 0.01 and bounds.height > 0 and bounds.width < hit.width) return bounds;
    }
    return error.NoThumb;
}

fn thumbAlpha(frame: anytype, area: zui.Id) !u8 {
    const thumb = try thumbRectangle(frame, area);
    for (frame.commands()) |command| {
        if (command.payload == .rectangle and std.meta.eql(command.bounds, thumb)) return command.payload.rectangle.color.a;
    }
    return error.NoThumb;
}

// =============================================================
// Card
// =============================================================

const Cards = struct {
    const ids = zui.ids(.{ "plain", "open" });

    opened: u32 = 0,
    plain_clicks: u32 = 0,

    fn declare(app: *Cards, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(400) }, .padding = .all(10), .child_gap = 10 } });
        if (widgets.card(ui, ids.plain, .{})) app.plain_clicks += 1;
        widgets.cardTitle(ui, "Storage");
        widgets.cardBody(ui, "12 GB used");
        ui.close();
        if (widgets.card(ui, ids.open, .{ .interactive = true, .label = "Release notes" })) app.opened += 1;
        widgets.cardTitle(ui, "Release notes");
        ui.close();
        ui.close();
    }
};

test "a card stands at the raised elevation, and an interactive one is a button that lifts while hovered" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Cards = .{};
    var frame = try driver.frame(&app, Cards.declare, &.{});

    const raised = tokens.elevations.get(.raised);
    try testing.expectEqual(tokens.colors.get(.idle).get(raised.surface), rectangleOf(frame, Cards.ids.plain).?.color);
    try expectShadow(raised.shadow, shadowOf(frame, Cards.ids.plain));
    const plain = frame.rectOf(Cards.ids.plain).?;
    const title = textBounds(frame, "Storage").?;
    try testing.expectApproxEqAbs(plain.x + tokens.space(.l), title.x, 0.5);
    try testing.expectApproxEqAbs(plain.y + tokens.space(.l), title.y, 0.5);
    try testing.expectApproxEqAbs(title.y + title.height + tokens.space(.m), textBounds(frame, "12 GB used").?.y, 0.5);
    try testing.expectError(error.NotListed, nodeOf(frame, Cards.ids.plain));
    const open = try nodeOf(frame, Cards.ids.open);
    try testing.expectEqual(zui.SemanticRole.button, open.role);
    try testing.expectEqualStrings("Release notes", open.label);

    frame = try driver.hover(&app, Cards.declare, Cards.ids.open);
    try expectShadow(tokens.elevations.get(.floating).shadow, shadowOf(frame, Cards.ids.open));
    try expectShadow(raised.shadow, shadowOf(frame, Cards.ids.plain));

    _ = try driver.click(&app, Cards.declare, Cards.ids.plain);
    _ = try driver.click(&app, Cards.declare, Cards.ids.open);
    try testing.expectEqual(@as(u32, 1), app.opened);
    _ = try driver.focus(&app, Cards.declare, Cards.ids.open);
    _ = try driver.pressKeys(&app, Cards.declare, &.{.enter});
    _ = try driver.action(&app, Cards.declare, Cards.ids.open, .invoke);
    try testing.expectEqual(@as(u32, 3), app.opened);
    try testing.expectEqual(@as(u32, 0), app.plain_clicks);
}

const PressedCard = struct {
    const id: zui.Id = .of("card");

    fn declare(_: *PressedCard, ui: *DrawingUi) void {
        _ = drawing_widgets.card(ui, id, .{ .interactive = true, .width = .fixed(200) });
        ui.text("Open", drawing_widgets.style(ui, .card_title, .idle).text);
        ui.close();
    }

    fn scale(frame: *const DrawingUi.Frame) ?f32 {
        for (frame.commands()) |command| {
            if (command.payload == .transform_begin) return command.payload.transform_begin.scale[0];
        }
        return null;
    }
};

test "a pressed card scales down through the press motion, and at once under reduced motion" {
    var fixture: Fixture(DrawingUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: PressedCard = .{};
    _ = try driver.frame(&app, PressedCard.declare, &.{});
    const center = try driver.pointOn(PressedCard.id, .{ 0.5, 0.5 });
    const mouse: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = center, .at = driver.now };
    _ = try driver.frame(&app, PressedCard.declare, &.{ .{ .pointer_move = .{ .pointer = mouse } }, .{ .pointer_down = .{ .pointer = mouse } } });
    var frame = try driver.frame(&app, PressedCard.declare, &.{});
    const partway = PressedCard.scale(frame) orelse return error.NotScaled;
    try testing.expect(partway < 1 and partway > 0.985);
    for (0..20) |_| frame = try driver.frame(&app, PressedCard.declare, &.{});
    try testing.expectApproxEqAbs(@as(f32, 0.985), PressedCard.scale(frame).?, 1e-4);
    _ = try driver.frame(&app, PressedCard.declare, &.{.{ .pointer_up = .{ .pointer = mouse } }});
    for (0..20) |_| frame = try driver.frame(&app, PressedCard.declare, &.{});
    try testing.expectEqual(@as(?f32, null), PressedCard.scale(frame));

    _ = try driver.frame(&app, PressedCard.declare, &.{ .{ .environment = .{ .reduced_motion = true } }, .{ .pointer_down = .{ .pointer = mouse } } });
    frame = try driver.frame(&app, PressedCard.declare, &.{});
    try testing.expectApproxEqAbs(@as(f32, 0.985), PressedCard.scale(frame).?, 1e-4);
}

// =============================================================
// Divider
// =============================================================

const Dividers = struct {
    const ids = zui.ids(.{ "plain", "inset", "both", "labeled", "column" });
    fn declare(_: *Dividers, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(400) }, .child_gap = 10 } });
        inline for (.{ .{ ids.plain, zui_widgets.DividerInset.none }, .{ ids.inset, .leading }, .{ ids.both, .both } }) |each| {
            ui.open(.{ .id = each[0], .layout = .{ .sizing = .{ .width = .grow } } });
            widgets.divider(ui, .{ .inset = each[1] });
            ui.close();
        }
        ui.open(.{ .id = ids.labeled, .layout = .{ .sizing = .{ .width = .grow } } });
        widgets.divider(ui, .{ .label = "or" });
        ui.close();
        ui.open(.{ .id = ids.column, .layout = .{ .sizing = .{ .height = .fixed(50) } } });
        widgets.divider(ui, .{ .axis = .vertical });
        ui.close();
        ui.close();
    }

    fn lines(frame: *const Ui.Frame, within: zui.Rect, found: []zui.Rect) []zui.Rect {
        var count: usize = 0;
        for (frame.commands()) |command| {
            if (command.payload != .rectangle or !command.payload.rectangle.color.eql(tokens.colors.get(.idle).get(.outline_muted))) continue;
            const bounds = command.bounds;
            if (bounds.y < within.y or bounds.y >= within.y + within.height + 0.01 or bounds.x < within.x - 0.01 or bounds.x >= within.x + within.width) continue;
            found[count] = bounds;
            count += 1;
        }
        return found[0..count];
    }
};

test "a divider is a one-unit line in outline_muted, inset at its leading edge or both, broken by a label, or upright" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Dividers = .{};
    const frame = try fixture.driver.frame(&app, Dividers.declare, &.{});
    const inset = tokens.space(.l);
    var room: [4]zui.Rect = undefined;

    const plain = Dividers.lines(frame, frame.rectOf(Dividers.ids.plain).?, &room);
    try testing.expectEqual(1, plain.len);
    try testing.expectEqual(zui.Rect{ .x = 0, .y = plain[0].y, .width = 400, .height = 1 }, plain[0]);
    const leading = Dividers.lines(frame, frame.rectOf(Dividers.ids.inset).?, &room)[0];
    try testing.expectEqual(inset, leading.x);
    try testing.expectEqual(400 - inset, leading.width);
    const both = Dividers.lines(frame, frame.rectOf(Dividers.ids.both).?, &room)[0];
    try testing.expectEqual(400 - 2 * inset, both.width);

    const labeled = Dividers.lines(frame, frame.rectOf(Dividers.ids.labeled).?, &room);
    try testing.expectEqual(2, labeled.len);
    const label_width = textBounds(frame, "or").?.width;
    try testing.expectApproxEqAbs(400 - label_width - 2 * tokens.space(.m), labeled[0].width + labeled[1].width, 1);
    try testing.expectApproxEqAbs(labeled[0].width, labeled[1].width, 0.5);

    const upright = Dividers.lines(frame, frame.rectOf(Dividers.ids.column).?, &room)[0];
    try testing.expectEqual(1, upright.width);
    try testing.expectEqual(50, upright.height);
}

// =============================================================
// Scroll area
// =============================================================

const Inbox = struct {
    const area: zui.Id = .of("inbox");
    const track = area.child("vertical_track");
    const thumb = track.child("thumb");

    rows: usize = 40,

    fn declare(app: *Inbox, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(300) } } });
        const scrolled = widgets.scrollArea(ui, area, .{ .height = .fixed(200), .label = "Inbox" });
        for (0..app.rows) |index| ui.box(.{ .id = .indexed("row", index), .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(20) } } });
        scrolled.end(ui);
        ui.close();
    }

    fn offset(fixture: *Fixture(Ui)) f32 {
        return fixture.ui.scrollOffset(area)[1];
    }
};

fn startInbox(fixture: *Fixture(Ui), app: *Inbox) !*const Ui.Frame {
    try fixture.init();
    _ = try fixture.driver.frame(app, Inbox.declare, &.{});
    return fixture.driver.frame(app, Inbox.declare, &.{});
}

test "a scroll area scrolls with the wheel, and its thumb shows where and how much" {
    var fixture: Fixture(Ui) = .{};
    var app: Inbox = .{};
    var frame = try startInbox(&fixture, &app);
    defer fixture.deinit();
    const driver = &fixture.driver;

    const track_width = tokens.target_floors.get(.pointer);
    const track = frame.rectOf(Inbox.track).?;
    try testing.expectEqual(zui.Rect{ .x = 300 - track_width, .y = 0, .width = track_width, .height = 200 }, track);
    try testing.expectEqual(@as(f32, 300 - track_width), frame.rectOf(.indexed("row", 0)).?.width);
    const at_top = try thumbRectangle(frame, Inbox.area);
    try testing.expectEqual(@as(f32, 2), at_top.y);
    try testing.expectApproxEqAbs((200 - 4) * 200.0 / 800.0, at_top.height, 0.5);
    try testing.expectEqual((tokens.control_heights.get(.medium) - 4) / 4, at_top.width);
    try testing.expectEqual(@as(f32, 300 - 2), at_top.x + at_top.width);

    const middle = try driver.pointOn(Inbox.area, .{ 0.5, 0.5 });
    frame = try driver.frame(&app, Inbox.declare, &.{.{ .wheel = .{ .position = middle, .delta = .{ 0, 300 }, .at = driver.now } }});
    try testing.expectEqual(@as(f32, 300), Inbox.offset(&fixture));
    const moved = try thumbRectangle(frame, Inbox.area);
    try testing.expectApproxEqAbs(2 + (196 - at_top.height) * 300.0 / 600.0, moved.y, 0.5);
    try testing.expectEqual(zui.SemanticScroll{ .offset = .{ 0, 300 }, .content = .{ 300, 800 }, .viewport = .{ 300, 200 }, .axes = .{ false, true } }, (try nodeOf(frame, Inbox.area)).scroll.?);
}

test "the thumb is thin at rest, wider and darker while the pointer is over its track, and darker still while dragged" {
    var fixture: Fixture(Ui) = .{};
    var app: Inbox = .{};
    var frame = try startInbox(&fixture, &app);
    defer fixture.deinit();
    const driver = &fixture.driver;
    const resting = (tokens.control_heights.get(.medium) - 4) / 4;
    const at_rest_alpha = try thumbAlpha(frame, Inbox.area);

    frame = try driver.hover(&app, Inbox.declare, Inbox.track);
    for (0..30) |_| frame = try driver.frame(&app, Inbox.declare, &.{});
    try testing.expectEqual(resting + 4, (try thumbRectangle(frame, Inbox.area)).width);
    const hovered_alpha = try thumbAlpha(frame, Inbox.area);
    try testing.expect(hovered_alpha > at_rest_alpha);
    const track_fill = rectangleOf(frame, Inbox.track) orelse return error.NoTrackFill;
    try testing.expect(track_fill.color.a > 0 and track_fill.color.a < 32);

    const thumb_center = try driver.pointOn(Inbox.thumb, .{ 0.5, 0.5 });
    const mouse: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = thumb_center, .at = driver.now };
    _ = try driver.frame(&app, Inbox.declare, &.{.{ .pointer_down = .{ .pointer = mouse } }});
    for (0..30) |_| frame = try driver.frame(&app, Inbox.declare, &.{});
    try testing.expect(try thumbAlpha(frame, Inbox.area) > hovered_alpha);
}

test "dragging the thumb scrolls in proportion, and a click on the track beside it pages" {
    var fixture: Fixture(Ui) = .{};
    var app: Inbox = .{};
    _ = try startInbox(&fixture, &app);
    defer fixture.deinit();
    const driver = &fixture.driver;

    const thumb = fixture.ui.rectOf(Inbox.thumb).?;
    const travel = 196 - thumb.height;
    _ = try driver.drag(&app, Inbox.declare, Inbox.thumb, .{ 0.5, 0.5 }, .{ 0.5, 0.5 + travel / 2 / thumb.height });
    try testing.expectApproxEqAbs(@as(f32, 300), Inbox.offset(&fixture), 1);
    _ = try driver.drag(&app, Inbox.declare, Inbox.thumb, .{ 0.5, 0.5 }, .{ 0.5, 20 });
    try testing.expectEqual(@as(f32, 600), Inbox.offset(&fixture));

    _ = try driver.clickAt(&app, Inbox.declare, Inbox.track, .{ 0.5, 0.02 });
    try testing.expectApproxEqAbs(@as(f32, 600 - 180), Inbox.offset(&fixture), 0.01);
    _ = try driver.frame(&app, Inbox.declare, &.{});
    _ = try driver.clickAt(&app, Inbox.declare, Inbox.track, .{ 0.5, 0.99 });
    try testing.expectEqual(@as(f32, 600), Inbox.offset(&fixture));
}

test "a focused scroll area scrolls with the arrow keys, Page Up and Down, Home and End" {
    var fixture: Fixture(Ui) = .{};
    var app: Inbox = .{};
    _ = try startInbox(&fixture, &app);
    defer fixture.deinit();
    const driver = &fixture.driver;

    _ = try driver.pressKeys(&app, Inbox.declare, &.{.down});
    try testing.expectEqual(@as(f32, 0), Inbox.offset(&fixture));
    _ = try driver.pressKeys(&app, Inbox.declare, &.{.tab});
    try testing.expect(fixture.ui.focused(Inbox.area));
    _ = try driver.pressKeys(&app, Inbox.declare, &.{ .down, .down });
    try testing.expectEqual(@as(f32, 80), Inbox.offset(&fixture));
    _ = try driver.pressKeys(&app, Inbox.declare, &.{.up});
    try testing.expectEqual(@as(f32, 40), Inbox.offset(&fixture));
    _ = try driver.pressKeys(&app, Inbox.declare, &.{.page_down});
    try testing.expectEqual(@as(f32, 220), Inbox.offset(&fixture));
    _ = try driver.pressKeys(&app, Inbox.declare, &.{.end});
    try testing.expectEqual(@as(f32, 600), Inbox.offset(&fixture));
    _ = try driver.pressKeys(&app, Inbox.declare, &.{ .down, .page_down });
    try testing.expectEqual(@as(f32, 600), Inbox.offset(&fixture));
    _ = try driver.pressKeys(&app, Inbox.declare, &.{.page_up});
    try testing.expectEqual(@as(f32, 420), Inbox.offset(&fixture));
    _ = try driver.pressKeys(&app, Inbox.declare, &.{.home});
    try testing.expectEqual(@as(f32, 0), Inbox.offset(&fixture));
}

test "the thumb fades once scrolling has stopped for its idle time, unless the pointer is over the track" {
    var fixture: Fixture(Ui) = .{};
    var app: Inbox = .{};
    var frame = try startInbox(&fixture, &app);
    defer fixture.deinit();
    const driver = &fixture.driver;
    try testing.expect(try thumbAlpha(frame, Inbox.area) > 0);
    try testing.expect(fixture.ui.nextFrame() != .on_event);

    driver.now = driver.now.addSeconds(1);
    for (0..20) |_| frame = try driver.frame(&app, Inbox.declare, &.{});
    try testing.expectEqual(@as(u8, 0), try thumbAlpha(frame, Inbox.area));
    try testing.expectEqual(zui.NextFrame.on_event, fixture.ui.nextFrame());

    const middle = try driver.pointOn(Inbox.area, .{ 0.3, 0.5 });
    _ = try driver.frame(&app, Inbox.declare, &.{.{ .wheel = .{ .position = middle, .delta = .{ 0, 40 }, .at = driver.now } }});
    for (0..20) |_| frame = try driver.frame(&app, Inbox.declare, &.{});
    try testing.expect(try thumbAlpha(frame, Inbox.area) > 0);

    _ = try driver.hover(&app, Inbox.declare, Inbox.track);
    driver.now = driver.now.addSeconds(2);
    for (0..20) |_| frame = try driver.frame(&app, Inbox.declare, &.{});
    try testing.expect(try thumbAlpha(frame, Inbox.area) > 0);
}

test "content that fits draws no scrollbar and takes no Tab stop" {
    var fixture: Fixture(Ui) = .{};
    var app: Inbox = .{ .rows = 5 };
    const frame = try startInbox(&fixture, &app);
    defer fixture.deinit();
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Inbox.track));
    try testing.expectEqual(@as(f32, 300), frame.rectOf(Inbox.area.child("content")).?.width);
    _ = try fixture.driver.pressKeys(&app, Inbox.declare, &.{.tab});
    try testing.expect(!fixture.ui.focused(Inbox.area));
    const node = try nodeOf(frame, Inbox.area);
    try testing.expectEqual(zui.SemanticRole.scroll_area, node.role);
    try testing.expectEqualStrings("Inbox", node.label);
}

const FadingInbox = struct {
    const area: zui.Id = .of("inbox");

    fade: zui_widgets.EdgeFade = .page,

    fn declare(app: *FadingInbox, ui: *DrawingUi) void {
        const scrolled = drawing_widgets.scrollArea(ui, area, .{ .width = .fixed(300), .height = .fixed(200), .edge_fade = app.fade });
        for (0..40) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(20) } } });
        scrolled.end(ui);
    }

    fn fades(frame: *const DrawingUi.Frame, found: []zui.Rect) []zui.Rect {
        var count: usize = 0;
        for (frame.commands()) |command| if (command.payload == .gradient) {
            found[count] = command.bounds;
            count += 1;
        };
        return found[0..count];
    }
};

test "an edge with more content beyond it fades into the surface beneath the area" {
    var fixture: Fixture(DrawingUi) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: FadingInbox = .{};
    _ = try driver.frame(&app, FadingInbox.declare, &.{});
    var frame = try driver.frame(&app, FadingInbox.declare, &.{});
    var room: [4]zui.Rect = undefined;
    var found = FadingInbox.fades(frame, &room);
    try testing.expectEqual(1, found.len);
    try testing.expectEqual(zui.Rect{ .x = 0, .y = 184, .width = 300, .height = 16 }, found[0]);

    fixture.ui.setScrollOffset(FadingInbox.area, .{ 0, 100 });
    _ = try driver.frame(&app, FadingInbox.declare, &.{});
    frame = try driver.frame(&app, FadingInbox.declare, &.{});
    found = FadingInbox.fades(frame, &room);
    try testing.expectEqual(2, found.len);
    for (frame.commands()) |command| if (command.payload == .gradient) {
        const gradient = command.payload.gradient;
        const surface = drawing_tokens.colors.get(.idle).get(.surface);
        try testing.expect(gradient.from.eql(surface) or gradient.to.eql(surface));
    };

    app.fade = .card;
    frame = try driver.frame(&app, FadingInbox.declare, &.{});
    for (frame.commands()) |command| if (command.payload == .gradient) {
        const gradient = command.payload.gradient;
        const raised = drawing_tokens.colors.get(.idle).get(.surface_raised);
        try testing.expect(gradient.from.eql(raised) or gradient.to.eql(raised));
    };

    app.fade = .none;
    try testing.expectEqual(0, FadingInbox.fades(try driver.frame(&app, FadingInbox.declare, &.{}), &room).len);
}

// =============================================================
// Group box
// =============================================================

const Account = struct {
    const id: zui.Id = .of("account");
    fn declare(_: *Account, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(400) } } });
        const group = widgets.groupBox(ui, id, "Account", .{ .description = "Your team sees your name." });
        ui.box(.{ .id = .of("row"), .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(40) } } });
        group.end(ui);
        ui.close();
    }
};

test "a group box titles a raised box of rows, with its description below" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    var app: Account = .{};
    const frame = try fixture.driver.frame(&app, Account.declare, &.{});
    const row = frame.rectOf(.of("row")).?;
    const title = textBounds(frame, "Account").?;
    const description = textBounds(frame, "Your team sees your name.").?;
    const body_padding = tokens.space(.s);
    try testing.expectApproxEqAbs(tokens.space(.l), title.x, 0.5);
    try testing.expectApproxEqAbs(title.y + title.height + tokens.space(.s) + body_padding, row.y, 0.5);
    try testing.expectEqual(tokens.space(.l), row.x);
    try testing.expectEqual(400 - 2 * tokens.space(.l), row.width);
    try testing.expectApproxEqAbs(row.y + row.height + body_padding + tokens.space(.s), description.y, 0.5);
    try testing.expectApproxEqAbs(tokens.space(.l), description.x, 0.5);

    var raised_fill = false;
    for (frame.commands()) |command| {
        if (command.payload == .rectangle and command.payload.rectangle.color.eql(tokens.colors.get(.idle).get(.surface_raised))) raised_fill = true;
    }
    try testing.expect(raised_fill);
    const node = try nodeOf(frame, Account.id);
    try testing.expectEqual(zui.SemanticRole.group, node.role);
    try testing.expectEqualStrings("Account", node.label);
}

// =============================================================
// Tabs
// =============================================================

const Project = struct {
    const Tab = enum { overview, activity, settings };
    const id: zui.Id = .of("project");

    tab: Tab = .overview,
    changes: u32 = 0,
    style: zui_widgets.TabsStyle = .underline,

    fn declare(app: *Project, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(500) }, .padding = .all(10) } });
        if (widgets.tabs(ui, id, &app.tab, .{ .style = app.style, .label = "Project" })) app.changes += 1;
        ui.close();
    }

    fn tabId(index: usize) zui.Id {
        return id.indexedChild("tab", index);
    }

    /// The indicator, the one rectangle in the accent's color, or the
    /// raised thumb in a groove.
    fn indicator(frame: *const Ui.Frame, color: zui.Color) ?zui.Rect {
        for (frame.commands()) |command| {
            if (command.payload == .rectangle and command.payload.rectangle.color.eql(color)) return command.bounds;
        }
        return null;
    }
};

test "tabs select by click, and the arrow keys, Home and End move the selection and the focus with it" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Project = .{};
    var frame = try driver.frame(&app, Project.declare, &.{});

    _ = try driver.click(&app, Project.declare, Project.tabId(2));
    try testing.expectEqual(.settings, app.tab);
    try testing.expectEqual(@as(u32, 1), app.changes);
    frame = try driver.frame(&app, Project.declare, &.{});
    try testing.expect(fixture.ui.focused(Project.tabId(2)));

    _ = try driver.pressKeys(&app, Project.declare, &.{.right});
    try testing.expectEqual(.overview, app.tab);
    _ = try driver.pressKeys(&app, Project.declare, &.{.left});
    try testing.expectEqual(.settings, app.tab);
    _ = try driver.pressKeys(&app, Project.declare, &.{.home});
    try testing.expectEqual(.overview, app.tab);
    _ = try driver.pressKeys(&app, Project.declare, &.{.end});
    try testing.expectEqual(.settings, app.tab);
    _ = try driver.pressKeys(&app, Project.declare, &.{.left});
    try testing.expectEqual(.activity, app.tab);
    frame = try driver.frame(&app, Project.declare, &.{});
    try testing.expect(fixture.ui.focused(Project.tabId(1)));
    try testing.expectEqual(@as(u32, 6), app.changes);

    _ = try driver.pressKeys(&app, Project.declare, &.{ .enter, .space });
    try testing.expectEqual(.activity, app.tab);
    try testing.expectEqual(@as(u32, 6), app.changes);

    _ = try driver.frame(&app, Project.declare, &.{.{ .environment = .{ .direction = .right_to_left } }});
    _ = try driver.pressKeys(&app, Project.declare, &.{.left});
    try testing.expectEqual(.settings, app.tab);
}

test "only the selected tab is in the Tab order, and each tab says whether it is selected" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Project = .{ .tab = .activity };
    var frame = try driver.frame(&app, Project.declare, &.{});
    frame = try driver.pressKeys(&app, Project.declare, &.{.tab});
    try testing.expect(fixture.ui.focused(Project.tabId(1)));
    frame = try driver.pressKeys(&app, Project.declare, &.{.tab});
    try testing.expect(!fixture.ui.focused(Project.tabId(2)));

    const bar = try nodeOf(frame, Project.id);
    try testing.expectEqual(zui.SemanticRole.group, bar.role);
    try testing.expectEqualStrings("Project", bar.label);
    const activity = try nodeOf(frame, Project.tabId(1));
    try testing.expectEqual(zui.SemanticRole.radio, activity.role);
    try testing.expectEqualStrings("Activity", activity.label);
    try testing.expect(activity.state.selected);
    try testing.expect(!(try nodeOf(frame, Project.tabId(0))).state.selected);

    _ = try driver.action(&app, Project.declare, Project.tabId(0), .invoke);
    try testing.expectEqual(.overview, app.tab);
}

test "the underline slides to the selected tab through the toggle spring, and lands at once under reduced motion" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Project = .{};
    const accent = tokens.colors.get(.idle).get(.accent);
    var frame = try driver.frame(&app, Project.declare, &.{});
    try testing.expectEqual(@as(?zui.Rect, null), Project.indicator(frame, accent));
    try testing.expect(fixture.ui.nextFrame() != .on_event);
    frame = try driver.frame(&app, Project.declare, &.{});

    const padding = tokens.space(.m);
    const first = frame.rectOf(Project.tabId(0)).?;
    const under_first = Project.indicator(frame, accent).?;
    try expectNear(.{ .x = first.x + padding, .y = first.y + first.height - 2, .width = first.width - 2 * padding, .height = 2 }, under_first);

    _ = try driver.click(&app, Project.declare, Project.tabId(2));
    frame = try driver.frame(&app, Project.declare, &.{});
    const sliding = Project.indicator(frame, accent).?;
    const third = frame.rectOf(Project.tabId(2)).?;
    try testing.expect(sliding.x > under_first.x and sliding.x < third.x + padding);
    for (0..60) |_| frame = try driver.frame(&app, Project.declare, &.{});
    try testing.expectApproxEqAbs(third.x + padding, Project.indicator(frame, accent).?.x, 0.5);

    _ = try driver.frame(&app, Project.declare, &.{.{ .environment = .{ .reduced_motion = true } }});
    _ = try driver.click(&app, Project.declare, Project.tabId(0));
    frame = try driver.frame(&app, Project.declare, &.{});
    try testing.expectEqual(under_first.x, Project.indicator(frame, accent).?.x);
}

test "pill tabs sit in a groove, the raised thumb behind the selected one" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Project = .{ .style = .pill, .tab = .activity };
    _ = try driver.frame(&app, Project.declare, &.{});
    const frame = try driver.frame(&app, Project.declare, &.{});
    const groove = frame.rectOf(Project.id).?;
    try testing.expectEqual(tokens.control_heights.get(.medium), groove.height);
    try testing.expectEqual(tokens.colors.get(.idle).get(.surface_sunken), rectangleOf(frame, Project.id).?.color);
    const thumb = Project.indicator(frame, tokens.colors.get(.idle).get(tokens.elevations.get(.raised).surface)).?;
    try expectNear(frame.rectOf(Project.tabId(1)).?, thumb);
    var drew_shadow = false;
    for (frame.commands()) |command| {
        if (command.payload == .shadow and sameShadow(tokens.elevations.get(.raised).shadow, command.payload.shadow)) drew_shadow = true;
    }
    try testing.expect(drew_shadow);
}

// =============================================================
// Navigation list
// =============================================================

const Mail = struct {
    const id: zui.Id = .of("places");
    const items = [_]zui_widgets.NavigationItem{
        .{ .label = "Mail", .heading = true },
        .{ .label = "Inbox", .count = "12" },
        .{ .label = "Drafts" },
        .{ .label = "Labels", .heading = true },
        .{ .label = "Receipts" },
    };

    place: usize = 1,
    changes: u32 = 0,

    fn declare(app: *Mail, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(240) } } });
        if (widgets.navigationList(ui, id, &items, &app.place, .{ .label = "Places" })) app.changes += 1;
        ui.close();
    }

    fn row(index: usize) zui.Id {
        return id.indexedChild("item", index);
    }
};

test "a navigation list selects by click, and Up, Down, Home and End move past its headings" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Mail = .{};
    _ = try driver.frame(&app, Mail.declare, &.{});

    _ = try driver.click(&app, Mail.declare, Mail.row(4));
    try testing.expectEqual(@as(usize, 4), app.place);
    _ = try driver.frame(&app, Mail.declare, &.{});
    try testing.expect(fixture.ui.focused(Mail.row(4)));
    _ = try driver.pressKeys(&app, Mail.declare, &.{.up});
    try testing.expectEqual(@as(usize, 2), app.place);
    _ = try driver.pressKeys(&app, Mail.declare, &.{.home});
    try testing.expectEqual(@as(usize, 1), app.place);
    _ = try driver.pressKeys(&app, Mail.declare, &.{.up});
    try testing.expectEqual(@as(usize, 1), app.place);
    _ = try driver.pressKeys(&app, Mail.declare, &.{.down});
    try testing.expectEqual(@as(usize, 2), app.place);
    _ = try driver.pressKeys(&app, Mail.declare, &.{.end});
    try testing.expectEqual(@as(usize, 4), app.place);
    _ = try driver.pressKeys(&app, Mail.declare, &.{.down});
    try testing.expectEqual(@as(usize, 4), app.place);
    try testing.expectEqual(@as(u32, 5), app.changes);
}

test "a navigation row hovers in secondary_container and is selected in accent_container, listed as an option" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Mail = .{};
    _ = try driver.frame(&app, Mail.declare, &.{});
    const frame = try driver.hover(&app, Mail.declare, Mail.row(2));
    try testing.expectEqual(tokens.colors.get(.idle).get(.accent_container), rectangleOf(frame, Mail.row(1)).?.color);
    try testing.expectEqual(tokens.colors.get(.hovered).get(.secondary_container), rectangleOf(frame, Mail.row(2)).?.color);
    try testing.expectEqual(@as(?@TypeOf(rectangleOf(frame, Mail.row(4)).?), null), rectangleOf(frame, Mail.row(4)));
    try testing.expectEqual(tokens.control_heights.get(.medium), frame.rectOf(Mail.row(1)).?.height);

    const list = try nodeOf(frame, Mail.id);
    try testing.expectEqual(zui.SemanticRole.list_box, list.role);
    const inbox = try nodeOf(frame, Mail.row(1));
    try testing.expectEqual(zui.SemanticRole.option, inbox.role);
    try testing.expect(inbox.state.selected);
    try testing.expectError(error.NotListed, nodeOf(frame, Mail.row(0)));
    _ = try driver.action(&app, Mail.declare, Mail.row(2), .invoke);
    try testing.expectEqual(@as(usize, 2), app.place);
}

// =============================================================
// Breadcrumbs
// =============================================================

const Path = struct {
    const id: zui.Id = .of("path");

    crumbs: []const []const u8 = &.{ "Home", "Projects", "Harbor" },
    chosen: ?usize = null,

    fn declare(app: *Path, ui: *Ui) void {
        if (widgets.breadcrumbs(ui, id, app.crumbs, .{ .label = "Location" })) |depth| app.chosen = depth;
    }

    fn crumb(index: usize) zui.Id {
        return id.indexedChild("crumb", index);
    }
};

test "breadcrumbs return the crumb chosen by click or by Enter, and the current page is not a link" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Path = .{};
    var frame = try driver.frame(&app, Path.declare, &.{});
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Path.crumb(2)));
    try testing.expectEqual(tokens.control_heights.get(.small), frame.rectOf(Path.crumb(0)).?.height);

    _ = try driver.click(&app, Path.declare, Path.crumb(1));
    try testing.expectEqual(@as(?usize, 1), app.chosen);
    app.chosen = null;
    _ = try driver.pressKeys(&app, Path.declare, &.{.tab});
    frame = try driver.pressKeys(&app, Path.declare, &.{.enter});
    try testing.expectEqual(@as(?usize, 0), app.chosen);

    const home = try nodeOf(frame, Path.crumb(0));
    try testing.expectEqual(zui.SemanticRole.link, home.role);
    try testing.expectEqualStrings("Home", home.label);
    var current_found = false;
    for (frame.semantics()) |node| {
        if (node.role == .label and std.mem.eql(u8, node.label, "Harbor")) current_found = node.state.selected;
    }
    try testing.expect(current_found);
    try testing.expectEqual(zui.SemanticRole.group, (try nodeOf(frame, Path.id)).role);
}

test "past four crumbs the middle ones collapse into one that shows them" {
    var fixture: Fixture(Ui) = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var app: Path = .{ .crumbs = &.{ "Home", "Projects", "Harbor", "Services", "Orders", "Settings" } };
    var frame = try driver.frame(&app, Path.declare, &.{});
    try testing.expect(frame.rectOf(Path.crumb(0)) != null);
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Path.crumb(1)));
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Path.crumb(3)));
    try testing.expect(frame.rectOf(Path.crumb(4)) != null);
    const more = frame.rectOf(Path.id.child("more")).?;
    try testing.expect(more.width >= tokens.target_floors.get(.pointer));

    _ = try driver.click(&app, Path.declare, Path.id.child("more"));
    frame = try driver.frame(&app, Path.declare, &.{});
    try testing.expectEqual(@as(?zui.Rect, null), frame.rectOf(Path.id.child("more")));
    for (0..5) |index| try testing.expect(frame.rectOf(Path.crumb(index)) != null);
    try testing.expect(fixture.ui.focused(Path.crumb(1)));
    try testing.expectEqual(@as(?usize, null), app.chosen);
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

test "every container and navigation component's glance permutations audit clean" {
    inline for (zui_widgets.previews.all) |Component| {
        const Glance = zui_design.Permutations(Component, .glance);
        for (0..Glance.count) |index| {
            const permutation = Glance.at(index);
            try auditGlance(Component, permutation, Glance.preview(permutation));
        }
    }
}

test "every container and navigation component audits clean in every scheme and density" {
    inline for (zui_widgets.previews.all) |Component| {
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

/// Declares every part of the containers and navigation a skin styles,
/// once the second frame has the rectangles their scrollbar and
/// indicators are placed from.
pub fn EveryContainer(comptime SkinnedWidgets: type) type {
    return struct {
        const Self = @This();
        pub const ids = struct {
            pub const card: zui.Id = .of("container.card");
            pub const area: zui.Id = .of("container.area");
            pub const track = area.child("vertical_track");
            pub const tabs: zui.Id = .of("container.tabs");
            pub const pills: zui.Id = .of("container.pills");
            pub const places: zui.Id = .of("container.places");
            pub const path: zui.Id = .of("container.path");
        };
        const Section = enum { one, two };

        widgets: SkinnedWidgets,
        tab: Section = .one,
        pill: Section = .two,
        place: usize = 1,

        pub fn declare(form: *Self, ui: anytype) void {
            const used = form.widgets;
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(360) }, .padding = .all(10), .child_gap = 10 } });
            _ = used.card(ui, ids.card, .{ .interactive = true, .label = "card" });
            used.cardTitle(ui, "title");
            used.cardBody(ui, "body");
            ui.close();
            used.divider(ui, .{ .label = "or" });
            const area = used.scrollArea(ui, ids.area, .{ .height = .fixed(60) });
            for (0..8) |_| used.label(ui, "row");
            area.end(ui);
            const group = used.groupBox(ui, .of("container.group"), "group", .{ .description = "described" });
            used.label(ui, "row");
            group.end(ui);
            _ = used.tabs(ui, ids.tabs, &form.tab, .{});
            _ = used.tabs(ui, ids.pills, &form.pill, .{ .style = .pill });
            _ = used.navigationList(ui, ids.places, &.{ .{ .label = "heading", .heading = true }, .{ .label = "one", .count = "1" }, .{ .label = "two", .count = "2" } }, &form.place, .{});
            _ = used.breadcrumbs(ui, ids.path, &.{ "a", "b", "c", "d", "e" }, .{});
            ui.close();
        }
    };
}

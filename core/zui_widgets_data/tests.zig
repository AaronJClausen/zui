const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_widgets = @import("zui_widgets");
const zui_widgets_data = @import("zui_widgets_data");
const zui_design = @import("zui_design");

const testing = std.testing;
const KeySet = zui_widgets_data.KeySet;
const Text = zui_testing.FixedMetricsText(u16);
const limits: zui.Limits = .{
    .max_elements = 512,
    .max_text_bytes = 8192,
    .max_depth = 24,
    .max_render_commands = 1024,
    .state_slots = 512,
    .measure_cache_entries = 1024,
};
const Ui = zui.Context(.{ .limits = limits, .Text = Text, .features = .{ .semantics = true } });

fn TokensIn(comptime preferences: zui_design.Preferences) zui.design.Tokens(Ui, void) {
    @setEvalBranchQuota(10_000_000);
    var resolved: zui.design.Tokens(Ui, void) = .{};
    _ = zui_design.resolve(zui_design.default, preferences, &resolved);
    return resolved;
}

const tokens = TokensIn(.{ .theme = .dark });
const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui));
const widgets: Widgets = .{ .skin = .{ .tokens = &tokens } };
const data = zui_widgets_data.of(widgets);

const Fixture = struct {
    text: Text = .{},
    ui: Ui = undefined,
    driver: zui_testing.Driver(Ui) = undefined,

    fn init(fixture: *Fixture) !void {
        fixture.ui = try .init(testing.allocator, testing.io, &fixture.text);
        fixture.driver = .{ .ui = &fixture.ui };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.ui.deinit(testing.allocator);
    }
};

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

fn rectangleColorAt(frame: anytype, bounds: zui.Rect) ?zui.Color {
    for (frame.commands()) |command| {
        const drawn = command.bounds;
        const covers = @abs(drawn.x - bounds.x) < 1 and @abs(drawn.y - bounds.y) < 1 and @abs(drawn.width - bounds.width) < 1 and @abs(drawn.height - bounds.height) < 1;
        if (command.payload == .rectangle and covers) return command.payload.rectangle.color;
    }
    return null;
}

fn skinColor(part: zui_widgets.Part, state: zui.WidgetState) zui.Color {
    return widgets.skin.zuiStyle(part, state, &.{}).background.?;
}

fn waitFor(driver: anytype, app: anytype, comptime declare: anytype, seconds: f64) !*const Ui.Frame {
    const interval = driver.frame_interval_ns;
    defer driver.frame_interval_ns = interval;
    driver.frame_interval_ns = @intFromFloat(seconds * std.time.ns_per_s);
    return driver.frame(app, declare, &.{});
}

// =============================================================
// KeySet
// =============================================================

test "a key set keeps its keys in order and refuses one past its storage" {
    var storage: [3]u64 = undefined;
    var set: KeySet = .init(&storage);
    try testing.expect(set.insert(30));
    try testing.expect(set.insert(10));
    try testing.expect(set.insert(20));
    try testing.expect(set.insert(20));
    try testing.expectEqualSlices(u64, &.{ 10, 20, 30 }, set.keys());
    try testing.expect(!set.insert(40));
    try testing.expectEqual(1, set.refused);
    try testing.expect(!set.contains(40));
    set.remove(20);
    try testing.expectEqualSlices(u64, &.{ 10, 30 }, set.keys());
    try testing.expect(!set.toggle(10));
    try testing.expect(set.toggle(5));
    try testing.expectEqualSlices(u64, &.{ 5, 30 }, set.keys());
    set.only(7);
    try testing.expectEqualSlices(u64, &.{7}, set.keys());
}

// =============================================================
// Table
// =============================================================

const Ship = struct {
    number: u32,

    fn name(ship: *const Ship, buffer: *[zui_widgets_data.cell_capacity]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "Ship {d}", .{ship.number}) catch "";
    }

    fn port(ship: *const Ship, _: *[zui_widgets_data.cell_capacity]u8) []const u8 {
        return if (ship.number % 2 == 0) "Lisbon" else "Oslo";
    }

    fn tonnage(ship: *const Ship, buffer: *[zui_widgets_data.cell_capacity]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{d}", .{ship.number * 10}) catch "";
    }

    fn key(ship: *const Ship) u64 {
        return 1000 + ship.number;
    }
};

const ship_columns = [_]zui_widgets_data.Column(Ship){
    .{ .title = "Name", .text = Ship.name },
    .{ .title = "Port", .text = Ship.port, .width = 120, .sortable = false },
    .{ .title = "Tonnage", .text = Ship.tonnage, .width = 100, .numeric = true },
};

/// Ships numbered by their index, made as they are asked for.
const Fleet = struct {
    ships: usize,

    pub fn count(fleet: Fleet) usize {
        return fleet.ships;
    }

    pub fn row(_: Fleet, index: usize) Ship {
        return .{ .number = @intCast(index) };
    }
};

const table_id: zui.Id = .of("ships");

const Harbor = struct {
    fleet: Fleet,
    sort: zui_widgets_data.Sort = .{},
    selected_storage: [8]u64 = undefined,
    selection: KeySet = undefined,
    widths: [3]f32 = .{ 0, 0, 0 },
    shown: zui_widgets_data.Data(Widgets).TableResult = .{},
    sorts: u32 = 0,
    activated: ?usize = null,
    keyed: bool = false,

    fn init(harbor: *Harbor, ships: usize) void {
        harbor.* = .{ .fleet = .{ .ships = ships } };
        harbor.selection = .init(&harbor.selected_storage);
    }

    fn declare(harbor: *Harbor, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(600), .height = .fixed(400) } } });
        harbor.shown = data.table(ui, table_id, Ship, harbor.fleet, .{
            .columns = &ship_columns,
            .sort = &harbor.sort,
            .selection = &harbor.selection,
            .widths = &harbor.widths,
            .key = if (harbor.keyed) Ship.key else null,
            .label = "Ships",
        });
        if (harbor.shown.sorted) harbor.sorts += 1;
        if (harbor.shown.activated) |index| harbor.activated = index;
        ui.close();
    }
};

fn rowId(index: usize) zui.Id {
    return table_id.indexedChild("row", index);
}

fn declaredOf(ships: usize) !struct { elements: usize, commands: usize } {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var harbor: Harbor = undefined;
    harbor.init(ships);
    _ = try fixture.driver.frame(&harbor, Harbor.declare, &.{});
    const frame = try fixture.driver.frame(&harbor, Harbor.declare, &.{});
    return .{ .elements = frame.elementCount(), .commands = frame.commands().len };
}

test "a table of a million rows declares as much as one of a hundred" {
    const hundred = try declaredOf(100);
    const million = try declaredOf(1_000_000);
    try testing.expectEqual(hundred.elements, million.elements);
    try testing.expectEqual(hundred.commands, million.commands);
}

test "a table declares only the rows in view, and the last at the end of a million" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var harbor: Harbor = undefined;
    harbor.init(1_000_000);
    _ = try driver.frame(&harbor, Harbor.declare, &.{});
    var frame = try driver.frame(&harbor, Harbor.declare, &.{});
    const header = frame.rectOf(table_id.child("header")).?;
    const row_height = frame.rectOf(rowId(0)).?.height;
    const in_view: usize = @intFromFloat(@ceil(frame.rectOf(table_id.child("body")).?.height / row_height));
    try testing.expect(frame.rectOf(rowId(in_view)) != null);
    try testing.expect(frame.rectOf(rowId(in_view + 2)) == null);
    try testing.expectEqual(1_000_000 * row_height, frame.rectOf(table_id.child("rows")).?.height);

    _ = try driver.focus(&harbor, Harbor.declare, table_id.child("body"));
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{.end});
    frame = try driver.frame(&harbor, Harbor.declare, &.{});
    try testing.expect(textCommand(frame, "Ship 999999") != null);
    try testing.expect(frame.rectOf(rowId(0)) == null);
    try testing.expectEqual(header.y, frame.rectOf(table_id.child("header")).?.y);
    try testing.expectEqualSlices(u64, &.{999_999}, harbor.selection.keys());
}

test "a click on a sortable column's title sorts by it, and a second reverses the order" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var harbor: Harbor = undefined;
    harbor.init(20);
    _ = try driver.frame(&harbor, Harbor.declare, &.{});
    const name_column = table_id.indexedChild("column", 0);
    var frame = try driver.click(&harbor, Harbor.declare, name_column);
    try testing.expectEqual(@as(?usize, 0), harbor.sort.column);
    try testing.expect(!harbor.sort.descending);
    frame = try driver.frame(&harbor, Harbor.declare, &.{});
    try testing.expectEqualStrings("Name, sorted ascending", (try nodeOf(frame, name_column)).label);
    try testing.expect((try nodeOf(frame, name_column)).state.selected);
    _ = try driver.click(&harbor, Harbor.declare, name_column);
    try testing.expect(harbor.sort.descending);
    _ = try driver.click(&harbor, Harbor.declare, table_id.indexedChild("column", 2));
    try testing.expectEqual(@as(?usize, 2), harbor.sort.column);
    try testing.expect(!harbor.sort.descending);
    try testing.expectEqual(3, harbor.sorts);

    _ = try driver.click(&harbor, Harbor.declare, table_id.indexedChild("column", 1));
    try testing.expectEqual(@as(?usize, 2), harbor.sort.column);
    frame = try driver.frame(&harbor, Harbor.declare, &.{});
    try testing.expectEqual(zui.SemanticRole.label, (try nodeOf(frame, table_id.indexedChild("column", 1))).role);

    _ = try driver.tabTo(&harbor, Harbor.declare, name_column);
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{.enter});
    try testing.expectEqual(@as(?usize, 0), harbor.sort.column);
}

test "a click selects one row, which draws in the selection's colors" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var harbor: Harbor = undefined;
    harbor.init(20);
    harbor.keyed = true;
    _ = try driver.frame(&harbor, Harbor.declare, &.{});
    _ = try driver.click(&harbor, Harbor.declare, rowId(3));
    try testing.expect(harbor.shown.selection_changed);
    _ = try driver.click(&harbor, Harbor.declare, rowId(5));
    try testing.expectEqualSlices(u64, &.{1005}, harbor.selection.keys());
    const frame = try driver.frame(&harbor, Harbor.declare, &.{});
    try testing.expect(fixture.ui.focused(table_id.child("body")));
    try testing.expect((try nodeOf(frame, rowId(5))).state.selected);
    try testing.expect(!(try nodeOf(frame, rowId(3))).state.selected);
    try testing.expectEqual(zui.SemanticRole.option, (try nodeOf(frame, rowId(5))).role);
    try testing.expectEqual(zui.SemanticRole.list_box, (try nodeOf(frame, table_id.child("body"))).role);
    try testing.expectEqualStrings("Ship 5", (try nodeOf(frame, rowId(5))).label);
    try testing.expectEqual(skinColor(.table_row_selected, .hovered), rectangleColorAt(frame, frame.rectOf(rowId(5)).?).?);
    try testing.expectEqual(tokens.colors.get(.idle).get(.on_selection), textCommand(frame, "Ship 5").?.payload.text.style.color);
}

test "the pointer over a row tints it at half the hover's strength" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var harbor: Harbor = undefined;
    harbor.init(20);
    _ = try driver.frame(&harbor, Harbor.declare, &.{});
    _ = try driver.hover(&harbor, Harbor.declare, rowId(2));
    const frame = try driver.frame(&harbor, Harbor.declare, &.{});
    const tint = rectangleColorAt(frame, frame.rectOf(rowId(2)).?).?;
    const hover = tokens.colors.get(.hovered).get(.secondary_container);
    try testing.expectEqual(hover.r, tint.r);
    try testing.expect(tint.a < hover.a and tint.a > 0);
}

test "the arrows move the selection, Ctrl moves only the keyboard's row, and Enter activates it" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var harbor: Harbor = undefined;
    harbor.init(200);
    _ = try driver.frame(&harbor, Harbor.declare, &.{});
    _ = try driver.tabTo(&harbor, Harbor.declare, table_id.child("body"));
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{.down});
    try testing.expectEqualSlices(u64, &.{0}, harbor.selection.keys());
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{ .down, .down });
    try testing.expectEqualSlices(u64, &.{2}, harbor.selection.keys());
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{.up});
    try testing.expectEqualSlices(u64, &.{1}, harbor.selection.keys());

    driver.modifiers = .{ .control = true };
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{ .down, .down, .space });
    driver.modifiers = .{};
    try testing.expectEqualSlices(u64, &.{ 1, 3 }, harbor.selection.keys());
    var frame = try driver.frame(&harbor, Harbor.declare, &.{});
    try testing.expect(frame.rectOf(rowId(3)) != null);
    const ring = widgets.skin.zuiStyle(.table_row_selected, .idle, &.{}).focus_ring.?;
    var rings: usize = 0;
    for (frame.commands()) |command| if (command.payload == .border and command.payload.border.color.eql(ring.color)) {
        rings += 1;
        const row = frame.rectOf(rowId(3)).?;
        try testing.expect(command.bounds.y <= row.y and command.bounds.y + command.bounds.height >= row.y + row.height);
    };
    try testing.expectEqual(1, rings);

    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{.space});
    try testing.expectEqualSlices(u64, &.{3}, harbor.selection.keys());
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{.enter});
    try testing.expectEqual(@as(?usize, 3), harbor.activated);

    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{.page_down});
    const page = harbor.selection.keys()[0];
    try testing.expect(page > 6);
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{.home});
    try testing.expectEqualSlices(u64, &.{0}, harbor.selection.keys());
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{.page_up});
    try testing.expectEqualSlices(u64, &.{0}, harbor.selection.keys());
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{.end});
    frame = try driver.frame(&harbor, Harbor.declare, &.{});
    try testing.expectEqualSlices(u64, &.{199}, harbor.selection.keys());
    try testing.expect(frame.rectOf(rowId(199)) != null);
    try testing.expect(frame.rectOf(rowId(199)).?.y + frame.rectOf(rowId(199)).?.height <= frame.rectOf(table_id.child("body")).?.y + frame.rectOf(table_id.child("body")).?.height + 0.5);
}

test "a table of rows in a slice selects through its own key" {
    const Rows = struct {
        const shown = [_]Ship{ .{ .number = 7 }, .{ .number = 3 } };
        var selected_storage: [2]u64 = undefined;
        var selection: KeySet = .init(&selected_storage);

        fn declare(_: *void, ui: *Ui) void {
            _ = data.table(ui, table_id, Ship, &shown, .{ .columns = &ship_columns, .selection = &selection, .key = Ship.key, .height = .fixed(200) });
        }
    };
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var app = {};
    _ = try fixture.driver.frame(&app, Rows.declare, &.{});
    const frame = try fixture.driver.click(&app, Rows.declare, rowId(1));
    try testing.expectEqualSlices(u64, &.{1003}, Rows.selection.keys());
    try testing.expect(textCommand(frame, "Ship 7") != null);
    try testing.expect(textCommand(frame, "70") != null);
}

test "a numeric cell sits at its column's trailing edge, and the columns line up under their titles" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var harbor: Harbor = undefined;
    harbor.init(20);
    _ = try fixture.driver.frame(&harbor, Harbor.declare, &.{});
    const frame = try fixture.driver.frame(&harbor, Harbor.declare, &.{});
    const tonnage_title = frame.rectOf(table_id.indexedChild("column", 2)).?;
    const cell = textCommand(frame, "40").?.bounds;
    try testing.expectApproxEqAbs(tonnage_title.x + tonnage_title.width, cell.x + cell.width, 1);
    const port_title = frame.rectOf(table_id.indexedChild("column", 1)).?;
    try testing.expectApproxEqAbs(port_title.x, textCommand(frame, "Oslo").?.bounds.x, 1);
    try testing.expectEqual(tokens.text_styles.get(.numeric).font, textCommand(frame, "40").?.payload.text.style.font);
}

test "dragging a column's handle resizes it, kept to its least width, and so do the arrows" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var harbor: Harbor = undefined;
    harbor.init(20);
    _ = try driver.frame(&harbor, Harbor.declare, &.{});
    _ = try driver.frame(&harbor, Harbor.declare, &.{});
    const handle = table_id.indexedChild("resize", 1);
    const handle_rect = fixture.ui.rectOf(handle).?;
    _ = try driver.drag(&harbor, Harbor.declare, handle, .{ 0.5, 0.5 }, .{ 0.5 + 40 / handle_rect.width, 0.5 });
    try testing.expectEqual(160, harbor.widths[1]);
    try testing.expect(harbor.shown.resized or harbor.widths[1] == 160);
    var frame = try driver.frame(&harbor, Harbor.declare, &.{});
    try testing.expectEqual(160, frame.rectOf(table_id.indexedChild("column", 1)).?.width);

    _ = try driver.drag(&harbor, Harbor.declare, handle, .{ 0.5, 0.5 }, .{ 0.5 - 400 / handle_rect.width, 0.5 });
    try testing.expectEqual(ship_columns[1].least_width, harbor.widths[1]);

    _ = try driver.tabTo(&harbor, Harbor.declare, handle);
    _ = try driver.pressKeys(&harbor, Harbor.declare, &.{ .right, .right });
    try testing.expectEqual(ship_columns[1].least_width + 32, harbor.widths[1]);
    frame = try driver.action(&harbor, Harbor.declare, handle, .{ .adjust = -1 });
    try testing.expectEqual(ship_columns[1].least_width + 16, harbor.widths[1]);
    frame = try driver.frame(&harbor, Harbor.declare, &.{});
    const node = try nodeOf(frame, handle);
    try testing.expectEqual(zui.SemanticRole.slider, node.role);
    try testing.expectEqualStrings("Width of Port", node.label);
}

test "a table's handle draws its line in the accent while dragged" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var harbor: Harbor = undefined;
    harbor.init(20);
    _ = try driver.frame(&harbor, Harbor.declare, &.{});
    const handle = table_id.indexedChild("resize", 0);
    const at = try driver.pointOn(handle, .{ 0.5, 0.5 });
    const pointer: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = at, .at = driver.now };
    _ = try driver.frame(&harbor, Harbor.declare, &.{ .{ .pointer_move = .{ .pointer = pointer } }, .{ .pointer_down = .{ .pointer = pointer } } });
    const frame = try driver.frame(&harbor, Harbor.declare, &.{});
    const accent = tokens.colors.get(.pressed).get(.accent);
    var lines: usize = 0;
    for (frame.commands()) |command| if (command.payload == .rectangle and command.payload.rectangle.color.eql(accent)) {
        lines += 1;
        try testing.expectEqual(1, command.bounds.width);
    };
    try testing.expectEqual(1, lines);
}

// =============================================================
// Tree
// =============================================================

const Folder = struct {
    title: []const u8,
    id: u64,
    children: []const Folder = &.{},

    fn name(folder: *const Folder) []const u8 {
        return folder.title;
    }

    fn subfolders(folder: *const Folder) []const Folder {
        return folder.children;
    }

    fn key(folder: *const Folder) u64 {
        return folder.id;
    }
};

const folders = [_]Folder{
    .{ .title = "Projects", .id = 1, .children = &.{
        .{ .title = "Harbor", .id = 2 },
        .{ .title = "Field Guide", .id = 3, .children = &.{
            .{ .title = "Drafts", .id = 4 },
        } },
    } },
    .{ .title = "Archive", .id = 5, .children = &.{.{ .title = "2025", .id = 6 }} },
    .{ .title = "Shared", .id = 7 },
};

const tree_id: zui.Id = .of("folders");

const Browser = struct {
    expanded_storage: [8]u64 = undefined,
    expanded: KeySet = undefined,
    selected_storage: [8]u64 = undefined,
    selection: KeySet = undefined,
    shown: zui_widgets_data.Data(Widgets).TreeResult = .{},
    activated: ?u64 = null,

    fn init(browser: *Browser) void {
        browser.* = .{};
        browser.expanded = .init(&browser.expanded_storage);
        browser.selection = .init(&browser.selected_storage);
    }

    fn declare(browser: *Browser, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(300) } } });
        browser.shown = data.tree(ui, tree_id, Folder, &folders, .{
            .expanded = &browser.expanded,
            .selection = &browser.selection,
            .label = Folder.name,
            .children = Folder.subfolders,
            .key = Folder.key,
            .accessible_label = "Folders",
        });
        if (browser.shown.activated) |key| browser.activated = key;
        ui.close();
    }
};

fn treeRow(key: u64) zui.Id {
    return zui_widgets_data.treeRowId(tree_id, key);
}

test "a tree shows its roots, and Right expands a row and then moves into it" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var browser: Browser = undefined;
    browser.init();
    var frame = try driver.frame(&browser, Browser.declare, &.{});
    try testing.expect(frame.rectOf(treeRow(1)) != null);
    try testing.expect(frame.rectOf(treeRow(2)) == null);
    try testing.expectEqual(@as(?bool, false), (try nodeOf(frame, treeRow(1))).state.expanded);
    try testing.expectEqual(@as(?bool, null), (try nodeOf(frame, treeRow(7))).state.expanded);

    _ = try driver.tabTo(&browser, Browser.declare, tree_id);
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.right});
    try testing.expect(browser.expanded.contains(1));
    try testing.expect(browser.shown.expansion_changed);
    frame = try driver.frame(&browser, Browser.declare, &.{});
    try testing.expect(frame.rectOf(treeRow(2)) != null);
    try testing.expectEqual(@as(?bool, true), (try nodeOf(frame, treeRow(1))).state.expanded);
    const indent = frame.rectOf(treeRow(2)).?;
    try testing.expect(textCommand(frame, "Harbor").?.bounds.x > textCommand(frame, "Projects").?.bounds.x);
    _ = indent;

    _ = try driver.pressKeys(&browser, Browser.declare, &.{.right});
    try testing.expectEqualSlices(u64, &.{2}, browser.selection.keys());
    _ = try driver.pressKeys(&browser, Browser.declare, &.{ .down, .right, .right });
    try testing.expectEqualSlices(u64, &.{4}, browser.selection.keys());
    try testing.expect(browser.expanded.contains(3));
}

test "Left collapses a row or moves to its parent, Up and Down walk the rows shown, Home and End reach the ends" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var browser: Browser = undefined;
    browser.init();
    _ = browser.expanded.insert(1);
    _ = browser.expanded.insert(3);
    _ = try driver.frame(&browser, Browser.declare, &.{});
    _ = try driver.tabTo(&browser, Browser.declare, tree_id);
    _ = try driver.pressKeys(&browser, Browser.declare, &.{ .down, .down, .down });
    try testing.expectEqualSlices(u64, &.{4}, browser.selection.keys());
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.left});
    try testing.expectEqualSlices(u64, &.{3}, browser.selection.keys());
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.left});
    try testing.expect(!browser.expanded.contains(3));
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.left});
    try testing.expectEqualSlices(u64, &.{1}, browser.selection.keys());
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.end});
    try testing.expectEqualSlices(u64, &.{7}, browser.selection.keys());
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.up});
    try testing.expectEqualSlices(u64, &.{5}, browser.selection.keys());
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.home});
    try testing.expectEqualSlices(u64, &.{1}, browser.selection.keys());
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.up});
    try testing.expectEqualSlices(u64, &.{1}, browser.selection.keys());
}

test "an asterisk expands every sibling of the keyboard's row" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var browser: Browser = undefined;
    browser.init();
    _ = try driver.frame(&browser, Browser.declare, &.{});
    _ = try driver.tabTo(&browser, Browser.declare, tree_id);
    _ = try driver.typeText(&browser, Browser.declare, "*");
    try testing.expectEqualSlices(u64, &.{ 1, 5 }, browser.expanded.keys());
}

test "a click selects a row, a click on its chevron opens it, and Ctrl moves only the keyboard's row" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var browser: Browser = undefined;
    browser.init();
    _ = try driver.frame(&browser, Browser.declare, &.{});
    _ = try driver.click(&browser, Browser.declare, treeRow(5));
    try testing.expectEqualSlices(u64, &.{5}, browser.selection.keys());
    try testing.expect(!browser.expanded.contains(5));
    _ = try driver.click(&browser, Browser.declare, treeRow(5).child("chevron"));
    try testing.expect(browser.expanded.contains(5));
    try testing.expectEqualSlices(u64, &.{5}, browser.selection.keys());
    const frame = try driver.frame(&browser, Browser.declare, &.{});
    try testing.expect(fixture.ui.focused(tree_id));
    try testing.expect((try nodeOf(frame, treeRow(5))).state.selected);
    try testing.expectEqual(skinColor(.tree_row_selected, .hovered), rectangleColorAt(frame, frame.rectOf(treeRow(5)).?).?);

    driver.modifiers = .{ .control = true };
    _ = try driver.pressKeys(&browser, Browser.declare, &.{ .down, .space });
    driver.modifiers = .{};
    try testing.expectEqualSlices(u64, &.{ 5, 6 }, browser.selection.keys());
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.enter});
    try testing.expectEqual(@as(?u64, 6), browser.activated);
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.space});
    try testing.expectEqualSlices(u64, &.{6}, browser.selection.keys());
}

test "a line marks the branch of the keyboard's row" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var browser: Browser = undefined;
    browser.init();
    _ = browser.expanded.insert(1);
    _ = browser.expanded.insert(3);
    _ = try driver.frame(&browser, Browser.declare, &.{});
    _ = try driver.tabTo(&browser, Browser.declare, tree_id);
    var frame = try driver.frame(&browser, Browser.declare, &.{});
    const guide = skinColor(.tree_guide, .idle);
    var lines: usize = 0;
    for (frame.commands()) |command| if (command.payload == .rectangle and command.payload.rectangle.color.eql(guide)) {
        lines += 1;
    };
    try testing.expectEqual(0, lines);
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.down});
    frame = try driver.frame(&browser, Browser.declare, &.{});
    for (frame.commands()) |command| if (command.payload == .rectangle and command.payload.rectangle.color.eql(guide)) {
        lines += 1;
        try testing.expectEqual(1, command.bounds.width);
    };
    try testing.expectEqual(3, lines);
}

test "in a right-to-left layout Left expands a tree's row and Right collapses it" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var browser: Browser = undefined;
    browser.init();
    _ = try driver.frame(&browser, Browser.declare, &.{.{ .environment = .{ .direction = .right_to_left } }});
    _ = try driver.tabTo(&browser, Browser.declare, tree_id);
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.left});
    try testing.expect(browser.expanded.contains(1));
    _ = try driver.pressKeys(&browser, Browser.declare, &.{.right});
    try testing.expect(!browser.expanded.contains(1));
}

// =============================================================
// Split pane
// =============================================================

const split_id: zui.Id = .of("mail");
const divider_id = split_id.child("divider");

const Mail = struct {
    list_width: f32 = 240,
    axis: zui_widgets_data.SplitAxis = .horizontal,
    resized: bool = false,

    fn declare(mail: *Mail, ui: *Ui) void {
        ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(800), .height = .fixed(500) } } });
        const panes = data.splitPane(ui, split_id, &mail.list_width, .{ .axis = mail.axis, .min = 200, .label = "List width" });
        widgets.label(ui, "Inbox");
        panes.second(ui);
        widgets.label(ui, "Message");
        panes.end(ui);
        mail.resized = panes.resized;
        ui.close();
    }
};

test "dragging the divider resizes the first pane, each kept to its least size" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var mail: Mail = .{};
    _ = try driver.frame(&mail, Mail.declare, &.{});
    var frame = try driver.frame(&mail, Mail.declare, &.{});
    try testing.expectEqual(240, frame.rectOf(split_id.child("first")).?.width);
    const hit = frame.rectOf(divider_id).?;
    _ = try driver.drag(&mail, Mail.declare, divider_id, .{ 0.5, 0.5 }, .{ 0.5 + 100 / hit.width, 0.5 });
    try testing.expectEqual(340, mail.list_width);
    frame = try driver.frame(&mail, Mail.declare, &.{});
    try testing.expectEqual(340, frame.rectOf(split_id.child("first")).?.width);
    try testing.expectApproxEqAbs(800 - 340 - 1, frame.rectOf(split_id.child("second")).?.width, 0.5);

    _ = try driver.drag(&mail, Mail.declare, divider_id, .{ 0.5, 0.5 }, .{ 0.5 + 1000 / hit.width, 0.5 });
    try testing.expectEqual(800 - 1 - 200, mail.list_width);
    _ = try driver.drag(&mail, Mail.declare, divider_id, .{ 0.5, 0.5 }, .{ 0.5 - 1000 / hit.width, 0.5 });
    try testing.expectEqual(200, mail.list_width);
}

test "the arrows move a focused divider by 16, and an assistive technology adjusts it" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var mail: Mail = .{};
    _ = try driver.frame(&mail, Mail.declare, &.{});
    _ = try driver.tabTo(&mail, Mail.declare, divider_id);
    _ = try driver.pressKeys(&mail, Mail.declare, &.{ .right, .right });
    try testing.expectEqual(272, mail.list_width);
    try testing.expect(mail.resized);
    _ = try driver.pressKeys(&mail, Mail.declare, &.{.left});
    try testing.expectEqual(256, mail.list_width);
    var frame = try driver.action(&mail, Mail.declare, divider_id, .{ .adjust = 2 });
    try testing.expectEqual(288, mail.list_width);
    frame = try driver.frame(&mail, Mail.declare, &.{});
    const node = try nodeOf(frame, divider_id);
    try testing.expectEqual(zui.SemanticRole.slider, node.role);
    try testing.expectEqualStrings("List width", node.label);
    try testing.expectEqual(288, node.value.range.value);
    try testing.expect(node.actions.contains(.adjust) or node.actions.contains(.focus));

    mail.axis = .vertical;
    mail.list_width = 240;
    _ = try driver.frame(&mail, Mail.declare, &.{});
    _ = try driver.focus(&mail, Mail.declare, divider_id);
    _ = try driver.pressKeys(&mail, Mail.declare, &.{.down});
    try testing.expectEqual(256, mail.list_width);
    frame = try driver.frame(&mail, Mail.declare, &.{});
    try testing.expectEqual(256, frame.rectOf(split_id.child("first")).?.height);
}

test "the divider thickens in the accent once hovered a moment, asking for a frame at that moment" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var mail: Mail = .{};
    _ = try driver.frame(&mail, Mail.declare, &.{});
    _ = try driver.frame(&mail, Mail.declare, &.{});
    const accent = tokens.colors.get(.hovered).get(.accent);
    var frame = try driver.hover(&mail, Mail.declare, divider_id);
    frame = try driver.frame(&mail, Mail.declare, &.{});
    try testing.expect(fixture.ui.nextFrame() == .at);
    var lines: usize = 0;
    for (frame.commands()) |command| if (command.payload == .rectangle and command.payload.rectangle.color.eql(accent)) {
        lines += 1;
    };
    try testing.expectEqual(0, lines);
    frame = try waitFor(driver, &mail, Mail.declare, 0.2);
    for (frame.commands()) |command| if (command.payload == .rectangle and command.payload.rectangle.color.eql(accent)) {
        lines += 1;
        try testing.expectEqual(3, command.bounds.width);
    };
    try testing.expectEqual(1, lines);
}

test "in a right-to-left layout dragging the divider toward the start widens the first pane" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const driver = &fixture.driver;
    var mail: Mail = .{};
    _ = try driver.frame(&mail, Mail.declare, &.{.{ .environment = .{ .direction = .right_to_left } }});
    const frame = try driver.frame(&mail, Mail.declare, &.{});
    const hit = frame.rectOf(divider_id).?;
    _ = try driver.drag(&mail, Mail.declare, divider_id, .{ 0.5, 0.5 }, .{ 0.5 - 60 / hit.width, 0.5 });
    try testing.expectEqual(300, mail.list_width);
}

// =============================================================
// Every component, under review
// =============================================================

const Recorded = struct {
    var asked: std.EnumArray(zui_widgets.Part, bool) = .initFill(false);

    pub fn zuiStyle(_: *const Recorded, part: zui_widgets.Part, _: zui.WidgetState, _: *const zui.Environment) zui_widgets.Style(Ui) {
        asked.set(part, true);
        return .{ .size = .{ 12, 24 } };
    }
};

test "every part the data components draw reaches the skin" {
    const RecordedWidgets = zui_widgets.Widgets(Ui, Recorded);
    inline for (zui_widgets_data.previews.all) |Component| {
        inline for (comptime std.meta.fieldNames(@TypeOf(Component.zuiPreviews))) |name| {
            const Shown = struct {
                fn declare(_: *void, ui: *Ui) void {
                    Component.declare(RecordedWidgets{ .skin = .{} }, ui, @field(Component.zuiPreviews, name));
                }
            };
            var fixture: Fixture = .{};
            try fixture.init();
            defer fixture.deinit();
            var app = {};
            _ = try fixture.driver.frame(&app, Shown.declare, &.{});
            _ = try fixture.driver.pressKeys(&app, Shown.declare, &.{ .tab, .down });
            _ = try fixture.driver.frame(&app, Shown.declare, &.{});
        }
    }
    for (zui_widgets.data_parts) |part| {
        if (!Recorded.asked.get(part)) {
            std.debug.print("never asked for {t}\n", .{part});
            return error.PartNeverStyled;
        }
    }
}

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
    var fixture: Fixture = .{};
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

test "every data component's glance permutations audit clean" {
    inline for (zui_widgets_data.previews.all) |Component| {
        const Glance = zui_design.Permutations(Component, .glance);
        for (0..Glance.count) |index| {
            const permutation = Glance.at(index);
            try auditGlance(Component, permutation, Glance.preview(permutation));
        }
    }
}

test "every data component audits clean in every scheme and density" {
    inline for (zui_widgets_data.previews.all) |Component| {
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

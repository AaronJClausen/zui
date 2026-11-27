const std = @import("std");
const zui = @import("zui");
const zui_widgets = @import("zui_widgets");
const zui_widgets_data = @import("zui_widgets_data");

/// As many containers as a large ship's manifest has crates, made as the
/// table asks for each.
const container_count = 1_000_000;

const ids = zui.ids(.{
    "manifest.toolbar",
    "manifest.add",
    "manifest.duplicate",
    "manifest.weigh",
    "manifest.seal",
    "manifest.export",
    "manifest.commands",
    "manifest.panes",
    "manifest.holds",
    "manifest.containers",
    "manifest.properties",
    "manifest.status",
    "manifest.palette",
});

const Hold = struct {
    name: []const u8,
    id: u64,
    holds: []const Hold = &.{},

    fn title(hold: *const Hold) []const u8 {
        return hold.name;
    }

    fn inside(hold: *const Hold) []const Hold {
        return hold.holds;
    }

    fn key(hold: *const Hold) u64 {
        return hold.id;
    }
};

const ships = [_]Hold{
    .{ .name = "Aurora", .id = 1, .holds = &.{
        .{ .name = "Forward hold", .id = 11, .holds = &.{ .{ .name = "Bay 1", .id = 111 }, .{ .name = "Bay 2", .id = 112 } } },
        .{ .name = "Aft hold", .id = 12 },
        .{ .name = "Reefer deck", .id = 13 },
    } },
    .{ .name = "Borealis", .id = 2, .holds = &.{ .{ .name = "Main hold", .id = 21 }, .{ .name = "Tank deck", .id = 22 } } },
    .{ .name = "Cassiopeia", .id = 3 },
};

const ports = [_][]const u8{ "Lisbon", "Rotterdam", "Hamburg", "Antwerp", "Oslo", "Genoa" };
const goods = [_][]const u8{ "Coffee", "Steel coils", "Textiles", "Machine parts", "Timber", "Olive oil", "Tiles" };

const Container = struct {
    number: u32,

    fn code(container: *const Container, buffer: *[zui_widgets_data.cell_capacity]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "MSKU {d:0>7}", .{container.number}) catch "";
    }

    fn cargo(container: *const Container, _: *[zui_widgets_data.cell_capacity]u8) []const u8 {
        return goods[container.number % goods.len];
    }

    fn port(container: *const Container, _: *[zui_widgets_data.cell_capacity]u8) []const u8 {
        return ports[(container.number / 7) % ports.len];
    }

    fn tonnes(container: *const Container, buffer: *[zui_widgets_data.cell_capacity]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{d}.{d}", .{ 4 + container.number % 26, container.number % 10 }) catch "";
    }

    fn key(container: *const Container) u64 {
        return container.number;
    }
};

const columns = [_]zui_widgets_data.Column(Container){
    .{ .title = "Container", .text = Container.code, .width = 160 },
    .{ .title = "Cargo", .text = Container.cargo, .sortable = false },
    .{ .title = "Port", .text = Container.port, .width = 120, .sortable = false },
    .{ .title = "Tonnes", .text = Container.tonnes, .width = 96, .numeric = true, .sortable = false },
};

/// The containers in the order the table's sort asks for: by number,
/// either way.
const ContainerOrder = struct {
    descending: bool,

    pub fn count(_: ContainerOrder) usize {
        return container_count;
    }

    pub fn row(order: ContainerOrder, index: usize) Container {
        const number: u32 = @intCast(if (order.descending) container_count - 1 - index else index);
        return .{ .number = number };
    }
};

const Command = enum { add, seal, first, last, reverse, sidebar };

const commands = [_]zui_widgets_data.Command{
    .{ .label = "Add a container", .shortcut = "Ctrl+N", .group = "Manifest" },
    .{ .label = "Seal the selected containers", .group = "Manifest" },
    .{ .label = "Go to the first container", .shortcut = "Home", .group = "Go" },
    .{ .label = "Go to the last container", .shortcut = "End", .group = "Go" },
    .{ .label = "Reverse the order", .group = "View" },
    .{ .label = "Show or hide the holds", .group = "View" },
};

/// What the property grid edits: the selected container's papers.
const Papers = struct {
    consignee: []const u8 = "Harbor Logistics",
    declared_tonnes: f32 = 12,
    temperature: i8 = 4,
    hazard: enum { none, flammable, corrosive } = .none,
    sealed: bool = false,
    customs: struct { cleared: bool = false, inspections: u8 = 0 } = .{},

    pub const zui_inspector = .{ .fields = .{
        .declared_tonnes = .{ .label = "Declared tonnes", .min = 0, .max = 30, .step = 0.5 },
        .temperature = .{ .label = "Temperature", .min = -30, .max = 30 },
    } };
};

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        /// A cargo manifest of a million containers, built from
        /// `zui_widgets_data`: a toolbar whose items spill into a menu
        /// as the window narrows, the ships' holds in a tree beside the
        /// containers in a table that declares only the rows in view, the
        /// selected container's papers in a property grid, a status bar, and
        /// Ctrl+K's command palette.
        pub const Manifest = struct {
            sidebar_width: f32 = 240,
            sidebar_shown: bool = true,
            expanded_storage: [8]u64 = undefined,
            expanded: zui_widgets_data.KeySet = .{ .storage = &.{} },
            hold_storage: [1]u64 = undefined,
            chosen_hold: zui_widgets_data.KeySet = .{ .storage = &.{} },
            selected_storage: [64]u64 = undefined,
            selected: zui_widgets_data.KeySet = .{ .storage = &.{} },
            sort: zui_widgets_data.Sort = .{ .column = 0 },
            column_widths: [columns.len]f32 = @splat(0),
            papers: Papers = .{},
            added: u32 = 0,
            sealed: u32 = 0,
            exported: u32 = 0,
            palette_open: bool = false,
            query_bytes: [48]u8 = undefined,
            query: zui_widgets.EditableText = undefined,
            started: bool = false,

            pub fn declare(self: *@This(), ui: *Ui, shell: *const Shell) void {
                const data = zui_widgets_data.of(shell.widgets);
                if (!self.started) {
                    self.started = true;
                    self.expanded = .init(&self.expanded_storage);
                    _ = self.expanded.insert(1);
                    self.chosen_hold = .init(&self.hold_storage);
                    self.chosen_hold.only(11);
                    self.selected = .init(&self.selected_storage);
                    self.query = .init(&self.query_bytes, "");
                }
                if (ui.chordPressed(.{ .key = .k, .modifiers = .{ .control = true } })) self.palette_open = true;
                shell.pageHeading(ui, "MANIFEST", "Data components", "A million containers in a table that declares only the rows in view, beside a tree of holds, with a toolbar, a property grid, a status bar and a command palette (Ctrl+K).");
                self.toolbar(ui, data);
                {
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both } });
                    defer ui.close();
                    if (self.sidebar_shown) {
                        const panes = data.splitPane(ui, ids.@"manifest.panes", &self.sidebar_width, .{ .min = 180, .label = "Holds width" });
                        _ = data.tree(ui, ids.@"manifest.holds", Hold, &ships, .{
                            .expanded = &self.expanded,
                            .selection = &self.chosen_hold,
                            .label = Hold.title,
                            .children = Hold.inside,
                            .key = Hold.key,
                            .accessible_label = "Holds",
                        });
                        panes.second(ui);
                        self.containers(ui, data);
                        panes.end(ui);
                    } else self.containers(ui, data);
                }
                self.status(ui, data);
                if (data.commandPalette(ui, ids.@"manifest.palette", &self.palette_open, &commands, .{ .query = &self.query })) |index| self.run(ui, @enumFromInt(index));
            }

            fn toolbar(self: *@This(), ui: *Ui, data: anytype) void {
                var bar = data.toolbar(ui, ids.@"manifest.toolbar", .{ .label = "Manifest" });
                if (bar.item(ui, ids.@"manifest.add", "Add", .{})) self.added += 1;
                if (bar.item(ui, ids.@"manifest.duplicate", "Duplicate", .{ .disabled = self.selected.len == 0 })) self.added += @intCast(self.selected.len);
                bar.separator(ui);
                _ = bar.item(ui, ids.@"manifest.weigh", "Weigh", .{});
                if (bar.item(ui, ids.@"manifest.seal", "Seal", .{ .disabled = self.selected.len == 0 })) self.sealed += @intCast(self.selected.len);
                bar.separator(ui);
                if (bar.item(ui, ids.@"manifest.export", "Export", .{})) self.exported += 1;
                if (bar.item(ui, ids.@"manifest.commands", "Commands", .{})) self.palette_open = true;
                bar.end(ui);
            }

            fn containers(self: *@This(), ui: *Ui, data: anytype) void {
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 8 } });
                defer ui.close();
                const shown = data.table(ui, ids.@"manifest.containers", Container, ContainerOrder{ .descending = self.sort.descending }, .{
                    .columns = &columns,
                    .sort = &self.sort,
                    .selection = &self.selected,
                    .widths = &self.column_widths,
                    .key = Container.key,
                    .label = "Containers",
                });
                if (shown.selection_changed) self.papers = .{};
                if (self.selected.len != 0) _ = data.propertyGrid(ui, ids.@"manifest.properties", &self.papers);
            }

            fn status(self: *const @This(), ui: *Ui, data: anytype) void {
                var buffer: [64]u8 = undefined;
                data.statusBar(ui, ids.@"manifest.status", .{ .label = "Manifest status" });
                data.statusText(ui, "1,000,000 containers");
                data.statusText(ui, std.fmt.bufPrint(&buffer, "{d} selected", .{self.selected.len}) catch "");
                data.statusText(ui, if (self.sort.descending) "Newest first" else "Oldest first");
                if (self.added + self.sealed + self.exported != 0) data.statusText(ui, std.fmt.bufPrint(&buffer, "{d} added, {d} sealed, {d} exported", .{ self.added, self.sealed, self.exported }) catch "");
                ui.close();
            }

            fn run(self: *@This(), ui: *Ui, command: Command) void {
                const body = ids.@"manifest.containers".child("body");
                switch (command) {
                    .add => self.added += 1,
                    .seal => self.sealed += @intCast(self.selected.len),
                    .first => ui.setScrollOffset(body, .{ 0, 0 }),
                    .last => ui.setScrollOffset(body, .{ 0, std.math.floatMax(f32) }),
                    .reverse => self.sort.descending = !self.sort.descending,
                    .sidebar => self.sidebar_shown = !self.sidebar_shown,
                }
            }
        };
    };
}

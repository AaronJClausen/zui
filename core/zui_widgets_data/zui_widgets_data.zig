//! Components for data-heavy tools, drawn through any `zui_widgets.Widgets` and
//! styled by its skin.
//!
//! ```zig
//! const data = zui_widgets_data.of(widgets);
//! const browser = data.splitPane(ui, .of("browser"), &app.sidebar_width, .{ .min = 200 });
//! _ = data.tree(ui, .of("folders"), Folder, &app.folders, .{ .expanded = &app.open_folders, .selection = &app.chosen_folder, .label = Folder.name, .children = Folder.subfolders, .key = Folder.key });
//! browser.second(ui);
//! _ = data.table(ui, .of("files"), File, app.files(), .{ .columns = &file_columns, .sort = &app.sort, .selection = &app.chosen_files });
//! browser.end(ui);
//! ```

const std = @import("std");
const zui = @import("zui");

/// Keys in storage the application owns, kept in order, such as a table's
/// selected rows or a tree's expanded nodes. A full set refuses a key and
/// counts it in `refused`.
///
/// ```zig
/// var selected_storage: [256]u64 = undefined;
/// var selected: zui_widgets_data.KeySet = .init(&selected_storage);
/// ```
pub const KeySet = struct {
    storage: []u64,
    len: usize = 0,
    refused: u32 = 0,

    pub fn init(storage: []u64) KeySet {
        return .{ .storage = storage };
    }

    /// In ascending order.
    pub fn keys(set: *const KeySet) []const u64 {
        return set.storage[0..set.len];
    }

    pub fn contains(set: *const KeySet, key: u64) bool {
        const at = set.lowerBound(key);
        return at < set.len and set.storage[at] == key;
    }

    /// False when the set is full and `key` is not in it.
    pub fn insert(set: *KeySet, key: u64) bool {
        const at = set.lowerBound(key);
        if (at < set.len and set.storage[at] == key) return true;
        if (set.len == set.storage.len) {
            set.refused +|= 1;
            return false;
        }
        std.mem.copyBackwards(u64, set.storage[at + 1 .. set.len + 1], set.storage[at..set.len]);
        set.storage[at] = key;
        set.len += 1;
        return true;
    }

    pub fn remove(set: *KeySet, key: u64) void {
        const at = set.lowerBound(key);
        if (at == set.len or set.storage[at] != key) return;
        std.mem.copyForwards(u64, set.storage[at .. set.len - 1], set.storage[at + 1 .. set.len]);
        set.len -= 1;
    }

    /// Whether `key` is in the set afterwards.
    pub fn toggle(set: *KeySet, key: u64) bool {
        if (set.contains(key)) {
            set.remove(key);
            return false;
        }
        return set.insert(key);
    }

    pub fn clear(set: *KeySet) void {
        set.len = 0;
    }

    /// Leaves `key` alone in the set.
    pub fn only(set: *KeySet, key: u64) void {
        set.clear();
        _ = set.insert(key);
    }

    fn lowerBound(set: *const KeySet, key: u64) usize {
        var low: usize = 0;
        var high = set.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (set.storage[middle] < key) low = middle + 1 else high = middle;
        }
        return low;
    }
};

/// The column a table's rows are sorted by, and in which order. The table
/// changes it as a column's title is chosen; the application sorts.
pub const Sort = struct {
    /// Null for rows in their own order.
    column: ?usize = null,
    descending: bool = false,
};

/// What a cell's text is written into, when the row does not hold it.
pub const cell_capacity = 128;

/// One column of a table of `Row`s.
///
/// ```zig
/// const file_columns = [_]zui_widgets_data.Column(File){
///     .{ .title = "Name", .text = File.name },
///     .{ .title = "Size", .text = File.formattedSize, .width = 96, .numeric = true },
/// };
/// ```
pub fn Column(comptime Row: type) type {
    return struct {
        title: []const u8,
        /// The cell's text, from the row or written into `buffer`.
        text: *const fn (row: *const Row, buffer: *[cell_capacity]u8) []const u8,
        /// Null shares the width the other columns leave with the other
        /// columns without one.
        width: ?f32 = null,
        /// In numerals, at the column's trailing edge.
        numeric: bool = false,
        sortable: bool = true,
        /// The narrowest a resize makes it.
        least_width: f32 = 48,
    };
}

/// The components of the data module, drawn through `widgets`, a
/// `zui_widgets.Widgets(Ui, Skin)`.
pub fn Data(comptime WidgetsType: type) type {
    checkWidgets(WidgetsType);
    return struct {
        const Self = @This();
        pub const Widgets = WidgetsType;
        pub const Ui = Widgets.Ui;
        const SkinStyle = Widgets.SkinStyle;

        widgets: Widgets,

        pub fn TableOptions(comptime Row: type) type {
            return struct {
                columns: []const Column(Row),
                /// Changed by a click on a sortable column's title, or Enter
                /// or Space on it; null for a table that does not sort.
                sort: ?*Sort = null,
                /// The keys of the selected rows; null for a table that does
                /// not select.
                selection: ?*KeySet = null,
                /// Each column's width, which dragging the handle at its
                /// trailing edge, or the arrows on the handle, changes; 0 for
                /// the column's own `width`. Null for columns without
                /// handles.
                widths: ?[]f32 = null,
                /// A row's key in `selection`; null keys each by its index,
                /// which a sort changes.
                key: ?*const fn (row: *const Row) u64 = null,
                /// For an assistive technology.
                label: []const u8 = "",
                width: zui.Sizing = .grow,
                height: zui.Sizing = .grow,
            };
        }

        pub const TableResult = struct {
            sorted: bool = false,
            selection_changed: bool = false,
            resized: bool = false,
            /// The index of the row Enter was pressed on.
            activated: ?usize = null,
        };

        const TableState = struct {
            /// The row the keyboard is on, plus one; 0 before it is on one.
            cursor: usize,
            /// The column being resized, plus one.
            resizing: usize,
            width_at_grab: f32,
            pointer_at_grab: f32,
        };

        /// Rows under a header that stays as they scroll, of which only
        /// those in view are declared, so a table of a million rows
        /// declares as much as one of a hundred. A click selects a row,
        /// and the arrows, Page Up and Down, Home and End move the
        /// selection while the table is focused; with Ctrl they move only
        /// the keyboard's row, and Ctrl+Space adds it to the selection or
        /// takes it away. Enter activates the row. A click on a sortable
        /// column's title sorts by it, and a second reverses the order.
        /// `rows` is a slice of `Row` or a value with `count()` and
        /// `row(index)`; the application owns them.
        ///
        /// ```zig
        /// const shown = data.table(ui, .of("files"), File, app.files, .{ .columns = &file_columns, .sort = &app.sort, .selection = &app.selected, .widths = &app.column_widths, .key = File.id });
        /// if (shown.sorted) app.sortFiles();
        /// if (shown.activated) |index| app.open(app.files[index]);
        /// ```
        pub fn table(self: Self, ui: *Ui, id: zui.Id, comptime Row: type, rows: anytype, options: TableOptions(Row)) TableResult {
            comptime checkRows(Row, @TypeOf(rows));
            var result: TableResult = .{};
            const state = ui.state(id, TableState);
            const count = rowCount(rows);
            const body_id = id.child("body");
            const rows_id = id.child("rows");
            const row_look = self.widgets.style(ui, .table_row, .idle);
            const row_height = @max(row_look.size[1], ui.measureText(line_sample, row_look.text)[1], 1);
            const view_height = if (ui.rectOf(body_id)) |rect| rect.height else ui.viewport()[1];
            if (state.cursor > count) state.cursor = count;
            if (ui.focused(body_id) and count != 0) tableKeys(ui, body_id, Row, rows, count, options, state, row_height, view_height, &result);

            const offset = ui.scrollOffset(body_id)[1];
            const last = @min(count, rowsBefore(offset + view_height, row_height, .up) + 1);
            const first = @min(last, rowsBefore(offset, row_height, .down) -| 1);
            const overflows = heightOf(count, row_height) > view_height;
            const gutter = if (overflows) self.widgets.style(ui, .scroll_track, .idle).size[0] else 0;

            ui.open(.{ .id = id, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = options.width, .height = options.height } } });
            self.tableHeader(ui, id, Row, options, state, gutter, &result);
            ui.open(.{
                .id = body_id,
                .focusable = count != 0,
                .scroll = .{ .vertical = true },
                .semantics = .{ .role = .list_box, .label = options.label },
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both },
            });
            ui.open(.{ .id = rows_id, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .{ .right = gutter } } });
            if (first != 0) spacer(ui, heightOf(first, row_height));
            const keyboard_on_rows = ui.focused(body_id) and ui.focusVisible();
            for (first..last) |index| {
                const row = rowAt(Row, rows, index);
                self.tableRow(ui, id, Row, &row, index, options, state, keyboard_on_rows, row_height, &result);
            }
            if (last != count) spacer(ui, heightOf(count - last, row_height));
            ui.close();
            self.widgets.scrollbar(ui, body_id, rows_id, .y, Widgets.inEnclosingLayer(ui, 0));
            ui.close();
            ui.close();
            return result;
        }

        fn tableKeys(ui: *Ui, body_id: zui.Id, comptime Row: type, rows: anytype, count: usize, options: TableOptions(Row), state: *TableState, row_height: f32, view_height: f32, result: *TableResult) void {
            const page = @max(rowsBefore(view_height, row_height, .down), 2) - 1;
            const offset = ui.scrollOffset(body_id)[1];
            var cursor = if (state.cursor == 0) @min(rowsBefore(offset, row_height, .up), count - 1) else state.cursor - 1;
            const had_cursor = state.cursor != 0;
            var moved = false;
            var answered = false;
            for (ui.keyEvents()) |key_event| {
                const only_cursor = key_event.modifiers.control or key_event.modifiers.super;
                const from = cursor;
                switch (key_event.key) {
                    .down => cursor = if (had_cursor or moved) @min(cursor + 1, count - 1) else cursor,
                    .up => cursor = if (had_cursor or moved) cursor -| 1 else cursor,
                    .page_down => cursor = @min(cursor + page, count - 1),
                    .page_up => cursor = cursor -| page,
                    .home => cursor = 0,
                    .end => cursor = count - 1,
                    .space => if (options.selection) |selection| {
                        const key = keyOf(Row, options, &rowAt(Row, rows, cursor), cursor);
                        if (only_cursor) _ = selection.toggle(key) else selection.only(key);
                        result.selection_changed = true;
                        answered = true;
                        continue;
                    } else continue,
                    .enter => {
                        result.activated = cursor;
                        answered = true;
                        continue;
                    },
                    else => continue,
                }
                moved = true;
                if (only_cursor) continue;
                if (options.selection) |selection| {
                    const key = keyOf(Row, options, &rowAt(Row, rows, cursor), cursor);
                    if (from != cursor or !selection.contains(key) or selection.len != 1) {
                        selection.only(key);
                        result.selection_changed = true;
                    }
                }
            }
            if (moved or answered) state.cursor = cursor + 1;
            if (!moved) return;
            const top = heightOf(cursor, row_height);
            if (top < offset) ui.setScrollOffset(body_id, .{ 0, top });
            if (top + row_height > offset + view_height) ui.setScrollOffset(body_id, .{ 0, top + row_height - view_height });
        }

        fn tableHeader(self: Self, ui: *Ui, id: zui.Id, comptime Row: type, options: TableOptions(Row), state: *TableState, gutter: f32, result: *TableResult) void {
            const header = self.widgets.style(ui, .table_header, .idle);
            const row_look = self.widgets.style(ui, .table_row, .idle);
            var padding = row_look.padding;
            padding.right += gutter;
            ui.open(.{
                .id = id.child("header"),
                .decoration = .{ .background = header.background, .border = header.border },
                .layout = .{ .sizing = .{ .width = .grow, .height = .fitBetween(header.size[1], std.math.inf(f32)) }, .padding = .{ .left = padding.left, .right = padding.right }, .child_gap = row_look.gap, .child_alignment = .{ .y = .center } },
            });
            for (options.columns, 0..) |column, column_index| {
                const cell_id = id.indexedChild("column", column_index);
                const sortable = column.sortable and options.sort != null;
                if (sortable and ui.clicked(cell_id)) {
                    const sort = options.sort.?;
                    if (sort.column == column_index) sort.descending = !sort.descending else sort.* = .{ .column = column_index };
                    result.sorted = true;
                }
                const sorted = if (options.sort) |sort| sort.column == column_index else false;
                const descending = sorted and options.sort.?.descending;
                const look = self.widgets.style(ui, .table_header_cell, if (sortable) ui.widgetState(cell_id) else .idle);
                var label_buffer: [cell_capacity]u8 = undefined;
                const label = if (!sorted) column.title else std.fmt.bufPrint(&label_buffer, "{s}, sorted {s}", .{ column.title, if (descending) "descending" else "ascending" }) catch column.title;
                ui.open(.{
                    .id = cell_id,
                    .focusable = sortable,
                    .cursor = if (sortable) .pointer else null,
                    .semantics = .{ .role = if (sortable) .button else .label, .label = label, .state = .{ .selected = sorted } },
                    .decoration = decorationOf(look, sortable and focusShown(ui, cell_id)),
                    .layout = .{
                        .sizing = .{ .width = columnSizing(ui, Row, options, column_index), .height = .grow },
                        .child_gap = look.gap,
                        .child_alignment = .{ .x = if (column.numeric) .end else .start, .y = .center },
                    },
                });
                ui.text(column.title, singleLine(look.text));
                if (sorted) self.widgets.icon(ui, if (descending) .arrow_down else .arrow_up, self.widgets.style(ui, if (descending) .table_sort_descending else .table_sort_ascending, .idle));
                if (options.widths) |widths| self.resizeHandle(ui, id, column, column_index, widths, state, row_look.gap, result);
                ui.close();
            }
            ui.close();
        }

        fn resizeHandle(self: Self, ui: *Ui, id: zui.Id, column: anytype, column_index: usize, widths: []f32, state: *TableState, gap: f32, result: *TableResult) void {
            if (column_index >= widths.len) return;
            const handle_id = id.indexedChild("resize", column_index);
            const declared = widths[column_index];
            const drawn = if (ui.rectOf(id.indexedChild("column", column_index))) |rect| rect.width else column.width orelse column.least_width;
            const current = if (declared > 0) declared else drawn;
            const toward_end: f32 = if (ui.environment().direction == .right_to_left) -1 else 1;
            if (ui.pressed(handle_id)) {
                if (ui.primaryPointer()) |pointer| {
                    if (state.resizing != column_index + 1) state.* = .{ .cursor = state.cursor, .resizing = column_index + 1, .width_at_grab = current, .pointer_at_grab = pointer.position[0] };
                    const resized = @max(column.least_width, state.width_at_grab + toward_end * (pointer.position[0] - state.pointer_at_grab));
                    if (resized != declared) {
                        widths[column_index] = resized;
                        result.resized = true;
                    }
                }
            } else if (state.resizing == column_index + 1) state.resizing = 0;
            if (ui.adjusted(handle_id)) |steps| {
                widths[column_index] = @max(column.least_width, current + toward_end * @as(f32, @floatFromInt(steps)) * keyboard_step);
                result.resized = true;
            }

            const look = self.widgets.style(ui, .table_resize_handle, ui.widgetState(handle_id));
            var label_buffer: [cell_capacity]u8 = undefined;
            ui.open(.{
                .id = handle_id,
                .focusable = true,
                .cursor = .resize_horizontal,
                .semantics = .{
                    .role = .slider,
                    .label = std.fmt.bufPrint(&label_buffer, "Width of {s}", .{column.title}) catch column.title,
                    .value = .{ .range = .{ .value = current, .min = column.least_width, .max = std.math.floatMax(f32), .step = keyboard_step } },
                },
                .floating = .{ .attach_to = .parent, .anchor = .center, .attach_point = .center_right, .offset = .{ gap / 2, 0 }, .z = Widgets.inEnclosingLayer(ui, 1) },
                .decoration = .{ .border = if (focusShown(ui, handle_id)) look.focus_ring else null, .corner_radius = look.corner_radius, .corner_shape = look.corner_shape },
                .layout = .{ .sizing = .{ .width = .fixed(look.size[0]), .height = .grow }, .child_alignment = .{ .x = .center } },
            });
            if (look.background) |line| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(look.size[1]), .height = .grow } }, .decoration = .{ .background = line } });
            ui.close();
        }

        fn tableRow(self: Self, ui: *Ui, id: zui.Id, comptime Row: type, row: *const Row, index: usize, options: TableOptions(Row), state: *TableState, keyboard_on_rows: bool, row_height: f32, result: *TableResult) void {
            const row_id = id.indexedChild("row", index);
            const key = keyOf(Row, options, row, index);
            if (ui.clicked(row_id)) {
                state.cursor = index + 1;
                if (options.selection) |selection| {
                    selection.only(key);
                    result.selection_changed = true;
                }
                ui.requestFocus(id.child("body"));
            }
            const selected = if (options.selection) |selection| selection.contains(key) else false;
            const look = self.widgets.style(ui, if (selected) .table_row_selected else .table_row, ui.widgetState(row_id));
            var numeric = self.widgets.style(ui, .table_cell_numeric, .idle).text;
            numeric.color = look.text.color;
            var label_buffer: [cell_capacity]u8 = undefined;
            ui.open(.{
                .id = row_id,
                .interactive = true,
                .semantics = .{ .role = .option, .label = if (options.columns.len != 0) options.columns[0].text(row, &label_buffer) else "", .state = .{ .selected = selected } },
                .decoration = decorationOf(look, keyboard_on_rows and state.cursor == index + 1),
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(row_height) }, .padding = .{ .left = look.padding.left, .right = look.padding.right }, .child_gap = look.gap, .child_alignment = .{ .y = .center } },
            });
            for (options.columns, 0..) |column, column_index| {
                var buffer: [cell_capacity]u8 = undefined;
                ui.open(.{
                    .clip = .horizontal,
                    .layout = .{ .sizing = .{ .width = columnSizing(ui, Row, options, column_index), .height = .grow }, .child_alignment = .{ .x = if (column.numeric) .end else .start, .y = .center } },
                });
                ui.text(column.text(row, &buffer), singleLine(if (column.numeric) numeric else look.text));
                ui.close();
            }
            ui.close();
        }

        /// A column's own widths grow with the user's text scale; one the
        /// user resized stays as they left it.
        fn columnSizing(ui: *const Ui, comptime Row: type, options: TableOptions(Row), column_index: usize) zui.Sizing {
            const column = options.columns[column_index];
            if (options.widths) |widths| if (column_index < widths.len and widths[column_index] > 0) return .fixed(widths[column_index]);
            const text_scale = ui.environment().text_scale;
            if (column.width) |width| return .fixed(width * text_scale);
            return .{ .rule = .grow_from_min, .amount = 1, .min = column.least_width * text_scale };
        }

        fn keyOf(comptime Row: type, options: TableOptions(Row), row: *const Row, index: usize) u64 {
            return if (options.key) |key| key(row) else index;
        }

        pub fn TreeOptions(comptime Node: type) type {
            return struct {
                /// The keys of the expanded nodes.
                expanded: *KeySet,
                /// The keys of the selected nodes; null for a tree that does
                /// not select.
                selection: ?*KeySet = null,
                label: *const fn (node: *const Node) []const u8,
                children: *const fn (node: *const Node) []const Node,
                /// Unique among the tree's nodes.
                key: *const fn (node: *const Node) u64,
                /// For an assistive technology.
                accessible_label: []const u8 = "",
                width: zui.Sizing = .grow,
            };
        }

        pub const TreeResult = struct {
            selection_changed: bool = false,
            expansion_changed: bool = false,
            /// The key of the node Enter was pressed on.
            activated: ?u64 = null,
        };

        const TreeState = struct {
            /// The key of the node the keyboard is on.
            cursor: u64,
            has_cursor: bool,
        };

        /// Nodes under the `roots` the application owns, each row with
        /// children opening and closing by its chevron. A click selects a
        /// row. While the tree is focused, Up and Down move the selection
        /// through the rows shown, Home and End to the first and last;
        /// Right expands a row or moves to its first child, Left collapses
        /// it or moves to its parent, and * expands every sibling. With
        /// Ctrl the arrows move only the keyboard's row, and Ctrl+Space
        /// adds it to the selection or takes it away; Enter activates it.
        /// A line marks the branch the keyboard's row is in.
        ///
        /// ```zig
        /// const folders = data.tree(ui, .of("folders"), Folder, &app.folders, .{ .expanded = &app.open_folders, .selection = &app.chosen, .label = Folder.name, .children = Folder.subfolders, .key = Folder.key });
        /// if (folders.selection_changed) app.showChosenFolder();
        /// ```
        pub fn tree(self: Self, ui: *Ui, id: zui.Id, comptime Node: type, roots: []const Node, options: TreeOptions(Node)) TreeResult {
            var result: TreeResult = .{};
            const state = ui.state(id, TreeState);
            const Walk = TreeWalk(Node);
            if (roots.len != 0 and !state.has_cursor) state.* = .{ .cursor = options.key(&roots[0]), .has_cursor = true };
            var found = Walk.locate(roots, options, state.cursor);
            if (roots.len != 0 and found.node == null) {
                state.cursor = options.key(&roots[0]);
                found = Walk.locate(roots, options, state.cursor);
            }
            if (ui.focused(id) and found.node != null) treeKeys(ui, Node, roots, options, state, &found, &result);

            ui.open(.{
                .id = id,
                .focusable = roots.len != 0,
                .semantics = .{ .role = .list_box, .label = options.accessible_label },
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = options.width } },
            });
            const branch: ?u64 = if (found.parent) |parent| options.key(parent) else null;
            self.treeRows(ui, id, Node, roots, options, state, 0, branch, null, ui.focused(id) and ui.focusVisible(), &result);
            ui.close();
            return result;
        }

        fn treeKeys(ui: *Ui, comptime Node: type, roots: []const Node, options: TreeOptions(Node), state: *TreeState, found: *TreeWalk(Node).Found, result: *TreeResult) void {
            const Walk = TreeWalk(Node);
            const mirrored = ui.environment().direction == .right_to_left;
            for (ui.keyEvents()) |key_event| {
                const node = found.node orelse return;
                const only_cursor = key_event.modifiers.control or key_event.modifiers.super;
                const has_children = options.children(node).len != 0;
                const expanded = has_children and options.expanded.contains(state.cursor);
                const key = if (mirrored) switch (key_event.key) {
                    .left => zui.Key.right,
                    .right => zui.Key.left,
                    else => key_event.key,
                } else key_event.key;
                var target: ?*const Node = null;
                switch (key) {
                    .down => target = found.next,
                    .up => target = found.previous,
                    .home => target = found.first,
                    .end => target = found.last,
                    .right => if (expanded) {
                        target = &options.children(node)[0];
                    } else if (has_children) {
                        _ = options.expanded.insert(state.cursor);
                        result.expansion_changed = true;
                    },
                    .left => if (expanded) {
                        options.expanded.remove(state.cursor);
                        result.expansion_changed = true;
                    } else {
                        target = found.parent;
                    },
                    .space => if (options.selection) |selection| {
                        if (only_cursor) _ = selection.toggle(state.cursor) else selection.only(state.cursor);
                        result.selection_changed = true;
                    },
                    .enter => result.activated = state.cursor,
                    else => {},
                }
                if (target) |moved_to| {
                    state.cursor = options.key(moved_to);
                    if (!only_cursor) if (options.selection) |selection| {
                        selection.only(state.cursor);
                        result.selection_changed = true;
                    };
                }
                found.* = Walk.locate(roots, options, state.cursor);
            }
            if (std.mem.indexOfScalar(u8, ui.typedText(), '*') != null) {
                for (found.siblings) |*sibling| {
                    if (options.children(sibling).len != 0 and !options.expanded.contains(options.key(sibling))) {
                        _ = options.expanded.insert(options.key(sibling));
                        result.expansion_changed = true;
                    }
                }
            }
        }

        fn treeRows(self: Self, ui: *Ui, id: zui.Id, comptime Node: type, nodes: []const Node, options: TreeOptions(Node), state: *TreeState, depth: usize, branch: ?u64, guide_depth: ?usize, keyboard_on_rows: bool, result: *TreeResult) void {
            for (nodes) |*node| {
                const key = options.key(node);
                const children = options.children(node);
                const row_id = treeRowId(id, key);
                const chevron_id = row_id.child("chevron");
                if (ui.clicked(row_id)) {
                    if (children.len != 0 and pointerWithin(ui, chevron_id)) {
                        _ = options.expanded.toggle(key);
                        result.expansion_changed = true;
                    } else if (options.selection) |selection| {
                        selection.only(key);
                        result.selection_changed = true;
                    }
                    state.cursor = key;
                    ui.requestFocus(id);
                }
                const expanded = children.len != 0 and options.expanded.contains(key);
                const selected = if (options.selection) |selection| selection.contains(key) else false;
                const row_state = ui.widgetState(row_id);
                const look = self.widgets.style(ui, if (selected) .tree_row_selected else .tree_row, row_state);
                const indent = look.size[0] * @as(f32, @floatFromInt(depth));
                ui.open(.{
                    .id = row_id,
                    .interactive = true,
                    .semantics = .{ .role = .option, .label = options.label(node), .state = .{ .selected = selected, .expanded = if (children.len != 0) expanded else null } },
                    .decoration = decorationOf(look, keyboard_on_rows and state.cursor == key),
                    .layout = .{
                        .sizing = .{ .width = .grow, .height = .fixed(look.size[1]) },
                        .padding = .{ .left = look.padding.left + indent, .right = look.padding.right },
                        .child_gap = look.gap,
                        .child_alignment = .{ .y = .center },
                    },
                });
                if (guide_depth) |level| self.treeGuide(ui, look, level);
                self.treeChevron(ui, chevron_id, children.len != 0, expanded, row_state, if (selected) look.text.color else null);
                ui.text(options.label(node), singleLine(look.text));
                ui.close();
                if (expanded) self.treeRows(ui, id, Node, children, options, state, depth + 1, branch, if (guide_depth == null and branch != null and branch.? == key) depth else guide_depth, keyboard_on_rows, result);
            }
        }

        /// On a selected row, the chevron takes the row's text color.
        fn treeChevron(self: Self, ui: *Ui, chevron_id: zui.Id, has_children: bool, expanded: bool, row_state: zui.WidgetState, selected_color: ?Ui.Color) void {
            var collapsed_look = self.widgets.style(ui, .tree_chevron_collapsed, row_state);
            var expanded_look = self.widgets.style(ui, .tree_chevron_expanded, row_state);
            if (selected_color) |color| {
                collapsed_look.text.color = color;
                expanded_look.text.color = color;
            }
            ui.open(.{ .id = chevron_id, .layout = .{ .sizing = .{ .width = .fixed(collapsed_look.size[0]), .height = .fixed(collapsed_look.size[0]) }, .child_alignment = .{ .x = .center, .y = .center } } });
            if (has_children) {
                if (Ui.draws_transforms) {
                    const quarter_turns = animate(ui, chevron_id.child("turn"), if (expanded) 1 else 0, collapsed_look.motion);
                    const effects: Ui.Effects = .{ .transform = .{ .rotation = quarter_turns * std.math.pi / 2.0 } };
                    ui.open(.{ .effects = if (quarter_turns != 0) &effects else null, .layout = .{ .child_alignment = .{ .x = .center, .y = .center } } });
                    self.widgets.icon(ui, .chevron_right, collapsed_look);
                    ui.close();
                } else {
                    self.widgets.icon(ui, if (expanded) .chevron_down else .chevron_right, if (expanded) expanded_look else collapsed_look);
                }
            }
            ui.close();
        }

        /// A line at the depth of the branch's parent, beside each of its rows.
        fn treeGuide(self: Self, ui: *Ui, row: SkinStyle, level: usize) void {
            const guide = self.widgets.style(ui, .tree_guide, .idle);
            const chevron = self.widgets.style(ui, .tree_chevron_collapsed, .idle);
            const at = row.padding.left + row.size[0] * @as(f32, @floatFromInt(level)) + (chevron.size[0] - guide.size[0]) / 2;
            ui.box(.{
                .floating = .{ .attach_to = .parent, .anchor = .top_left, .attach_point = .top_left, .offset = .{ at, 0 }, .z = Widgets.inEnclosingLayer(ui, 0), .capture = false },
                .decoration = .{ .background = guide.background },
                .layout = .{ .sizing = .{ .width = .fixed(guide.size[0]), .height = .grow } },
            });
        }

        pub const SplitPaneOptions = struct {
            axis: SplitAxis = .horizontal,
            /// The least size of each pane.
            min: f32 = 200,
            /// For an assistive technology.
            label: []const u8 = "",
            width: zui.Sizing = .grow,
            height: zui.Sizing = .grow,
        };

        /// What `splitPane` opened: declare the first pane's content,
        /// call `second`, declare the second's, then call `end`.
        pub const SplitPane = struct {
            data: Self,
            id: zui.Id,
            options: SplitPaneOptions,
            /// The first pane's size changed this frame.
            resized: bool,

            /// Closes the first pane, declares the divider and opens the
            /// second pane.
            pub fn second(pane: SplitPane, ui: *Ui) void {
                ui.close();
                pane.data.splitDivider(ui, pane.id, pane.options);
                const across = pane.options.axis == .horizontal;
                ui.open(.{ .id = pane.id.child("second"), .clip = .both, .layout = .{ .sizing = .{ .width = if (across) .grow_equal else .grow, .height = if (across) .grow else .grow_equal } } });
            }

            pub fn end(_: SplitPane, ui: *Ui) void {
                ui.close();
                ui.close();
            }
        };

        const DividerState = struct {
            dragging: bool,
            hovered: bool,
            hovered_since: zui.Instant,
            /// Where along the divider the pointer took hold of it.
            grab: f32,
        };

        /// Two panes parted by a divider that the pointer drags and, once
        /// focused, the arrows move by 16 units, each pane kept at least
        /// `min` long. `size` is the first pane's length along the axis,
        /// which the application keeps. The divider thickens in the accent
        /// while dragged or focused, or once hovered a moment.
        ///
        /// ```zig
        /// const panes = data.splitPane(ui, .of("mail"), &app.list_width, .{ .min = 240 });
        /// declareMessageList(ui);
        /// panes.second(ui);
        /// declareMessage(ui);
        /// panes.end(ui);
        /// ```
        pub fn splitPane(self: Self, ui: *Ui, id: zui.Id, size: *f32, options: SplitPaneOptions) SplitPane {
            const across = options.axis == .horizontal;
            const along: usize = if (across) 0 else 1;
            const hit_id = id.child("divider");
            const state = ui.state(hit_id, DividerState);
            const container = ui.rectOf(id);
            const length: ?f32 = if (container) |rect| (if (across) rect.width else rect.height) else null;
            const thickness = self.widgets.style(ui, .split_divider, .idle).size[0];
            const before = size.*;
            if (ui.pressed(hit_id)) {
                if (ui.primaryPointer()) |pointer| if (container) |rect| {
                    var reach = pointer.position[along] - (if (across) rect.x else rect.y);
                    if (across and ui.environment().direction == .right_to_left) reach = rect.width - reach;
                    if (!state.dragging) {
                        state.dragging = true;
                        state.grab = reach - size.*;
                    }
                    size.* = reach - state.grab;
                };
            } else state.dragging = false;
            if (ui.adjusted(hit_id)) |steps| {
                const toward_end: f32 = if (!across) -1 else if (ui.environment().direction == .right_to_left) -1 else 1;
                size.* += toward_end * @as(f32, @floatFromInt(steps)) * keyboard_step;
            }
            const most = if (length) |room| room - thickness - options.min else std.math.floatMax(f32);
            size.* = @max(@min(size.*, most), options.min);

            ui.open(.{
                .id = id,
                .layout = .{ .direction = if (across) .left_to_right else .top_to_bottom, .sizing = .{ .width = options.width, .height = options.height } },
            });
            ui.open(.{ .id = id.child("first"), .clip = .both, .layout = .{ .sizing = .{ .width = if (across) .fixed(size.*) else .grow, .height = if (across) .grow else .fixed(size.*) } } });
            return .{ .data = self, .id = id, .options = options, .resized = size.* != before };
        }

        fn splitDivider(self: Self, ui: *Ui, id: zui.Id, options: SplitPaneOptions) void {
            const across = options.axis == .horizontal;
            const hit_id = id.child("divider");
            const state = ui.state(hit_id, DividerState);
            const now = ui.now();
            const hovered = ui.hovered(hit_id);
            if (hovered and !state.hovered) state.hovered_since = now;
            state.hovered = hovered;
            const lingered_at = state.hovered_since.addSeconds(divider_hover_seconds);
            const lingered = hovered and !now.isBefore(lingered_at);
            if (hovered and !lingered) ui.requestFrameAt(lingered_at);
            const active = state.dragging or ui.focused(hit_id) or lingered;
            const look = self.widgets.style(ui, .split_divider, .idle);
            const line = self.widgets.style(ui, .split_divider_active, ui.widgetState(hit_id));
            const size = if (ui.rectOf(id.child("first"))) |rect| (if (across) rect.width else rect.height) else options.min;
            ui.open(.{
                .decoration = .{ .background = look.background },
                .layout = .{ .sizing = if (across) .{ .width = .fixed(look.size[0]), .height = .grow } else .{ .width = .grow, .height = .fixed(look.size[0]) } },
            });
            ui.open(.{
                .id = hit_id,
                .focusable = true,
                .cursor = if (across) .resize_horizontal else .resize_vertical,
                .semantics = .{
                    .role = .slider,
                    .label = if (options.label.len != 0) options.label else "Divider",
                    .value = .{ .range = .{ .value = size, .min = options.min, .max = std.math.floatMax(f32), .step = keyboard_step } },
                },
                .floating = .{ .attach_to = .parent, .anchor = .center, .attach_point = .center, .z = Widgets.inEnclosingLayer(ui, 1) },
                .decoration = .{ .border = if (focusShown(ui, hit_id)) line.focus_ring else null },
                .layout = .{
                    .sizing = if (across) .{ .width = .fixed(look.size[1]), .height = .grow } else .{ .width = .grow, .height = .fixed(look.size[1]) },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            });
            if (active) ui.box(.{
                .decoration = .{ .background = line.background },
                .layout = .{ .sizing = if (across) .{ .width = .fixed(line.size[0]), .height = .grow } else .{ .width = .grow, .height = .fixed(line.size[0]) } },
            });
            ui.close();
            ui.close();
        }

        pub const ToolbarItemOptions = struct {
            /// Drawn alone as an icon button, with the label as its tooltip
            /// and accessible name; null draws a text button.
            icon: ?zui.design.Icon = null,
            disabled: bool = false,
        };

        const ToolbarState = struct {
            menu_open: bool,
            /// The item chosen in the overflow menu, answered by its
            /// `item` in the next frame.
            chosen: u64,
            /// The width every item took in the last frame, shown or not.
            needed: f32,
        };

        const OverflowEntry = struct { id: zui.Id, label: []const u8, disabled: bool };

        /// What `toolbar` opened: declare its items and separators,
        /// then call `end`.
        pub const Toolbar = struct {
            data: Self,
            id: zui.Id,
            /// The room the bar had for its items in the last frame; null in
            /// its first.
            room: ?f32,
            gap: f32,
            placed: f32 = 0,
            needed: f32 = 0,
            spilling: bool = false,
            overflow: [toolbar_overflow_most]OverflowEntry = undefined,
            overflow_count: usize = 0,

            /// A tertiary button, or an icon button, in the bar, or in its
            /// overflow menu once the bar has no room for it. True in the
            /// frame it is chosen; chosen from the menu, in the next.
            pub fn item(bar: *Toolbar, ui: *Ui, id: zui.Id, label: []const u8, options: ToolbarItemOptions) bool {
                const widgets = bar.data.widgets;
                const remembered = ui.state(id.child("width"), struct { width: f32 });
                if (ui.rectOf(id)) |rect| remembered.width = rect.width;
                const width = if (remembered.width > 0) remembered.width else widgets.style(ui, .control_medium, .idle).size[1];
                const lead = if (bar.needed > 0) bar.gap else 0;
                bar.needed += lead + width;
                if (bar.room) |room| {
                    const state = ui.state(bar.id, ToolbarState);
                    const kept_room = if (state.needed > room) room - bar.overflowButtonWidth(ui) - bar.gap else room;
                    if (bar.spilling or bar.placed + lead + width > kept_room) {
                        bar.spilling = true;
                        if (bar.overflow_count < bar.overflow.len) {
                            bar.overflow[bar.overflow_count] = .{ .id = id, .label = label, .disabled = options.disabled };
                            bar.overflow_count += 1;
                        }
                        if (state.chosen != id.hash) return false;
                        state.chosen = 0;
                        return !options.disabled;
                    }
                }
                bar.placed += lead + width;
                if (options.icon) |icon| return widgets.iconButton(ui, id, icon, .{ .label = label, .disabled = options.disabled });
                return widgets.button(ui, id, label, .{ .variant = .tertiary, .disabled = options.disabled });
            }

            /// The line between two groups of items, left out once the
            /// items after it spill into the overflow menu.
            pub fn separator(bar: *Toolbar, ui: *Ui) void {
                const line = bar.data.widgets.style(ui, .toolbar_separator, .idle);
                const width = line.size[0] + line.padding.left + line.padding.right;
                bar.needed += bar.gap + width;
                if (bar.spilling) return;
                bar.placed += bar.gap + width;
                ui.open(.{ .layout = .{ .padding = .{ .left = line.padding.left, .right = line.padding.right }, .child_alignment = .{ .y = .center } } });
                ui.box(.{ .decoration = .{ .background = line.background }, .layout = .{ .sizing = .{ .width = .fixed(line.size[0]), .height = .fixed(line.size[1]) } } });
                ui.close();
            }

            fn overflowButtonWidth(bar: *const Toolbar, ui: *Ui) f32 {
                if (ui.rectOf(bar.id.child("more"))) |rect| return rect.width;
                return 2 * bar.data.widgets.style(ui, .control_medium, .idle).size[1];
            }

            /// Declares the overflow menu, when items spilled into it, and
            /// closes the bar.
            pub fn end(bar: *Toolbar, ui: *Ui) void {
                const state = ui.state(bar.id, ToolbarState);
                state.needed = bar.needed;
                if (bar.overflow_count != 0) {
                    const more_id = bar.id.child("more");
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                    _ = bar.data.widgets.button(ui, more_id, overflow_label, .{ .variant = .tertiary });
                    if (bar.data.widgets.menu(ui, bar.id.child("overflow"), more_id, &state.menu_open, .{ .label = "More" })) |menu| {
                        for (bar.overflow[0..bar.overflow_count]) |entry| {
                            if (menu.item(ui, entry.label, .{ .disabled = entry.disabled })) {
                                state.chosen = entry.id.hash;
                                ui.requestFrame();
                            }
                        }
                        menu.end(ui);
                    }
                } else state.menu_open = false;
                ui.close();
            }
        };

        /// A bar of tertiary buttons and icon buttons, in groups parted by
        /// a line; the items that do not fit move into a menu at its
        /// trailing end. Declare its items through what it returns, then
        /// call `end`:
        ///
        /// ```zig
        /// var bar = data.toolbar(ui, .of("editor.toolbar"), .{ .label = "Editor" });
        /// if (bar.item(ui, .of("editor.undo"), "Undo", .{})) app.undo();
        /// if (bar.item(ui, .of("editor.redo"), "Redo", .{ .disabled = !app.canRedo() })) app.redo();
        /// bar.separator(ui);
        /// if (bar.item(ui, .of("editor.export"), "Export", .{})) app.exportDocument();
        /// bar.end(ui);
        /// ```
        pub fn toolbar(self: Self, ui: *Ui, id: zui.Id, options: BarOptions) Toolbar {
            const look = self.widgets.style(ui, .toolbar, .idle);
            // Scrolling sideways keeps the bar as wide as its parent gives it,
            // whatever its items ask for, so it knows its room; once items
            // spill into the menu there is nothing to scroll.
            ui.open(.{
                .id = id,
                .scroll = .{ .horizontal = true, .vertical = false },
                .semantics = .{ .role = .group, .label = options.label },
                .decoration = .{ .background = look.background, .border = look.border },
                .layout = .{
                    .sizing = .{ .width = options.width, .height = .fitBetween(look.size[1], std.math.inf(f32)) },
                    .padding = .{ .left = look.padding.left, .right = look.padding.right },
                    .child_gap = look.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
            const room: ?f32 = if (ui.rectOf(id)) |rect| rect.width - look.padding.left - look.padding.right else null;
            return .{ .data = self, .id = id, .room = room, .gap = look.gap };
        }

        pub const BarOptions = struct {
            /// For an assistive technology.
            label: []const u8 = "",
            width: zui.Sizing = .grow,
        };

        /// A bar along the bottom of a window or a pane, of short texts in
        /// the caption role: declare them with `statusText` and close
        /// the bar with `ui.close()`.
        ///
        /// ```zig
        /// data.statusBar(ui, .of("status"), .{ .label = "Status" });
        /// data.statusText(ui, "12 files");
        /// data.statusText(ui, "Saved");
        /// ui.close();
        /// ```
        pub fn statusBar(self: Self, ui: *Ui, id: zui.Id, options: BarOptions) void {
            const look = self.widgets.style(ui, .status_bar, .idle);
            ui.open(.{
                .id = id,
                .semantics = .{ .role = .group, .label = options.label },
                .decoration = .{ .background = look.background, .border = look.border },
                .layout = .{
                    .sizing = .{ .width = options.width, .height = .fitBetween(look.size[1], std.math.inf(f32)) },
                    .padding = .{ .left = look.padding.left, .right = look.padding.right },
                    .child_gap = look.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
        }

        /// Text in a status bar, in its color and type.
        pub fn statusText(self: Self, ui: *Ui, content: []const u8) void {
            ui.text(content, singleLine(self.widgets.style(ui, .status_bar, .idle).text));
        }

        /// What `commandPalette` edits as the user types.
        pub const EditableTextPointer = @typeInfo(@TypeOf(Widgets.textField)).@"fn".params[3].type.?;

        pub const CommandPaletteOptions = struct {
            /// What has been typed, which the palette empties as it opens.
            query: EditableTextPointer,
            placeholder: []const u8 = "Type a command",
            /// For an assistive technology.
            label: []const u8 = "Commands",
        };

        const PaletteState = struct {
            was_open: bool,
            opener: u64,
            /// Among the commands that match.
            selected: usize,
        };

        /// A panel at a fifth of the window's height, over a scrim, at the
        /// `topmost` elevation, listing the commands whose label holds
        /// what is typed, the part that matches in the accent's strong
        /// text, under each group's heading. Up and Down move the
        /// selection, and Enter or a click chooses it, closing the palette
        /// and returning the command's index in `commands`; Escape, a click
        /// on the scrim or a `dismiss` action closes it without one. Focus
        /// goes back to what had it once it closes. Declared inside another
        /// overlay, it floats above it.
        ///
        /// ```zig
        /// if (ui.chordPressed(.{ .key = .k, .modifiers = .{ .control = true } })) app.palette_open = true;
        /// if (data.commandPalette(ui, .of("palette"), &app.palette_open, &app.commands, .{ .query = &app.palette_query })) |index| app.run(index);
        /// ```
        pub fn commandPalette(self: Self, ui: *Ui, id: zui.Id, open: *bool, commands: []const Command, options: CommandPaletteOptions) ?usize {
            const state = ui.state(id, PaletteState);
            const panel_id = id.child("panel");
            const scrim_id = id.child("scrim");
            const query_id = id.child("query");
            const dismissed = open.* and state.was_open and (ui.clicked(scrim_id) or ui.dismissed(panel_id));
            if (dismissed) open.* = false;
            if (!open.*) {
                if (state.was_open) ui.requestFocus(.{ .hash = state.opener });
                state.was_open = false;
                if (!dismissed) return null;
            }
            const opening = open.* and !state.was_open;
            if (opening) {
                state.* = .{ .was_open = true, .opener = ui.focusedId().hash, .selected = 0 };
                options.query.set("");
                ui.requestFocus(query_id);
            }

            var chosen: ?usize = null;
            const query = options.query.slice();
            const match_count = matchCount(commands, query);
            if (ui.focused(query_id) and match_count != 0) {
                for (ui.keyEvents()) |key_event| switch (key_event.key) {
                    .down => state.selected = (state.selected + 1) % match_count,
                    .up => state.selected = (state.selected + match_count - 1) % match_count,
                    else => {},
                };
            }
            state.selected = if (match_count == 0) 0 else @min(state.selected, match_count - 1);

            const viewport = ui.viewport();
            const scrim = self.widgets.style(ui, .command_palette_scrim, .idle);
            const look = self.widgets.style(ui, .command_palette, .idle);
            const scrim_layer = Widgets.overlayLayer(ui, scrim.layer);
            const panel_layer = @max(look.layer, scrim_layer +| 1);
            const scrim_shown = entrance(ui, scrim_id.child("enter"), opening, scrim.motion);
            ui.box(.{
                .id = scrim_id,
                .interactive = !dismissed,
                .floating = .{ .attach_to = .root, .z = scrim_layer },
                .decoration = .{ .background = if (scrim.background) |color| (if (scrim_shown < 1) faded(color, scrim_shown) else color) else null },
                .exit = scrim.exit,
                .layout = .{ .sizing = .{ .width = .fixed(viewport[0]), .height = .fixed(viewport[1]) } },
            });
            const entered = entrance(ui, panel_id.child("enter"), opening, look.motion);
            const margin = look.padding.left + look.padding.right;
            ui.open(.{
                .id = panel_id,
                .focus_scope = true,
                .semantics = .{ .role = .dialog, .label = options.label, .actions = .initOne(.dismiss) },
                .floating = .{ .attach_to = .root, .anchor = .top_center, .attach_point = .top_center, .offset = .{ 0, viewport[1] * palette_top_share - (1 - entered) * palette_enter_slide }, .z = panel_layer },
                .decoration = .{ .background = look.background, .border = look.border, .corner_radius = look.corner_radius, .corner_shape = look.corner_shape },
                .effects = if (look.shadow) |_| &.{ .shadow = look.shadow } else null,
                .exit = look.exit,
                .layout = .{
                    .direction = .top_to_bottom,
                    .sizing = .{ .width = .fixed(@min(look.size[0], @max(viewport[0] - 2 * margin, 0))) },
                    .padding = look.padding,
                    .child_gap = look.gap,
                },
            });
            const replaced = Widgets.enterOverlay(ui, panel_layer);
            if (self.widgets.textField(ui, query_id, options.query, .{ .placeholder = options.placeholder, .label = options.label }).submitted and match_count != 0) {
                chosen = commandAt(commands, query, state.selected);
            }
            const first = state.selected -| (palette_results_most - 1);
            ui.open(.{ .id = id.child("results"), .semantics = .{ .role = .list_box, .label = options.label }, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow } } });
            var position: usize = 0;
            var heading: []const u8 = "";
            for (commands, 0..) |command, index| {
                const span = matchOf(command.label, query) orelse continue;
                defer position += 1;
                if (position < first or position >= first + palette_results_most) continue;
                if (command.group.len != 0 and !std.mem.eql(u8, command.group, heading)) {
                    const title = self.widgets.style(ui, .command_palette_heading, .idle);
                    ui.open(.{ .layout = .{ .padding = title.padding } });
                    ui.text(command.group, singleLine(title.text));
                    ui.close();
                }
                heading = command.group;
                if (self.paletteResult(ui, id.indexedChild("result", index), command, span, position == state.selected)) chosen = index;
            }
            if (match_count == 0) {
                const title = self.widgets.style(ui, .command_palette_heading, .idle);
                ui.open(.{ .layout = .{ .padding = title.padding } });
                ui.text("No command matches", singleLine(title.text));
                ui.close();
            }
            ui.close();
            Widgets.leaveOverlay(ui, replaced);
            ui.close();
            if (chosen != null) open.* = false;
            return chosen;
        }

        fn paletteResult(self: Self, ui: *Ui, result_id: zui.Id, command: Command, span: [2]usize, selected: bool) bool {
            const clicked = ui.clicked(result_id);
            const look = self.widgets.style(ui, if (selected) .command_palette_result_selected else .command_palette_result, ui.widgetState(result_id));
            var match = self.widgets.style(ui, .command_palette_match, .idle).text;
            if (selected) match.color = look.text.color;
            ui.open(.{
                .id = result_id,
                .interactive = true,
                .cursor = .pointer,
                .semantics = .{ .role = .option, .label = command.label, .state = .{ .selected = selected } },
                .decoration = .{ .background = look.background, .corner_radius = look.corner_radius, .corner_shape = look.corner_shape },
                .layout = .{ .sizing = .{ .width = .grow, .height = .fitBetween(look.size[1], std.math.inf(f32)) }, .padding = .{ .left = look.padding.left, .right = look.padding.right }, .child_gap = look.gap, .child_alignment = .{ .y = .center } },
            });
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_alignment = .{ .y = .center } } });
            const plain = singleLine(look.text);
            if (span[0] != 0) ui.text(command.label[0..span[0]], plain);
            if (span[1] != span[0]) ui.text(command.label[span[0]..span[1]], singleLine(match));
            if (span[1] != command.label.len) ui.text(command.label[span[1]..], plain);
            ui.close();
            if (command.shortcut.len != 0) {
                const keycap = self.widgets.style(ui, .command_palette_shortcut, .idle);
                ui.open(.{
                    .decoration = .{ .background = keycap.background, .corner_radius = keycap.corner_radius, .corner_shape = keycap.corner_shape },
                    .layout = .{ .padding = .{ .left = keycap.padding.left, .right = keycap.padding.right } },
                });
                ui.text(command.shortcut, singleLine(keycap.text));
                ui.close();
            }
            ui.close();
            return clicked;
        }

        /// The fields of `value.*` in rows of a name and an editor, as
        /// `zui_reflect.inspector` lays them out: a switch for a `bool`, a
        /// slider for a number with `min` and `max` and a stepper for one
        /// without, a dropdown for an enum, a text field for the widgets'
        /// editable text, read-only text for `[]const u8`, and a group that
        /// opens and closes for a struct. A dot beside a name marks a value
        /// changed from the field's default. It honours the struct's
        /// `zui_inspector` labels, hidden fields and ranges, and returns
        /// whether any editor changed the value this frame.
        ///
        /// ```zig
        /// if (data.propertyGrid(ui, .of("layer.properties"), &app.selected_layer)) app.redraw();
        /// ```
        pub fn propertyGrid(self: Self, ui: *Ui, id: zui.Id, value: anytype) bool {
            const T = PropertiesOf(@TypeOf(value));
            ui.open(.{ .id = id, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow } } });
            const changed = self.properties(ui, id, T, value, 0);
            ui.close();
            return changed;
        }

        fn properties(self: Self, ui: *Ui, id: zui.Id, comptime T: type, value: *T, depth: usize) bool {
            var changed = false;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const options = comptime declaredOptions(T, field.name);
                if (!comptime optionOf(options, "hidden", false)) {
                    const label = comptime optionOf(options, "label", @as(?[]const u8, null)) orelse labelOf(field.name);
                    if (self.property(ui, id.child(field.name), label, field.type, &@field(value, field.name), comptime field.defaultValue(), options, depth)) changed = true;
                }
            }
            return changed;
        }

        const PropertyGroup = struct { collapsed: bool };

        fn property(self: Self, ui: *Ui, id: zui.Id, label: []const u8, comptime Field: type, field: *Field, comptime default: ?Field, comptime options: anytype, depth: usize) bool {
            const widgets = self.widgets;
            if (comptime @typeInfo(Field) == .@"struct" and Field != EditableText) {
                const group = ui.state(id, PropertyGroup);
                var expanded = !group.collapsed;
                if (widgets.disclosure(ui, id, label, &expanded)) group.collapsed = !expanded;
                if (!expanded) return false;
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .{ .left = self.widgets.style(ui, .tree_row, .idle).size[0] } } });
                defer ui.close();
                return self.properties(ui, id, Field, field, depth + 1);
            }
            propertyRow(widgets, ui, label, changedFromDefault(Field, field.*, default));
            defer ui.close();
            if (Field == EditableText) return widgets.textField(ui, id, field, .{ .label = label, .placeholder = comptime optionOf(options, "placeholder", @as([]const u8, "")) }).changed;
            switch (@typeInfo(Field)) {
                .bool => return widgets.toggle(ui, id, "", field, .{ .label = label }),
                .int, .float => {
                    const min = comptime optionOf(options, "min", @as(?f64, null));
                    const max = comptime optionOf(options, "max", @as(?f64, null));
                    const step = comptime optionOf(options, "step", @as(?f64, null));
                    if (min != null and max != null) return widgets.slider(ui, id, field, .{ .min = min.?, .max = max.?, .step = step, .label = label });
                    return widgets.numberStepper(ui, id, field, .{
                        .min = min orelse -std.math.inf(f64),
                        .max = max orelse std.math.inf(f64),
                        .step = step orelse if (@typeInfo(Field) == .float) 0.1 else 1,
                        .label = label,
                    });
                },
                .@"enum" => return widgets.dropdownEnum(ui, id, field, .{ .label = label }),
                .pointer => {
                    widgets.label(ui, field.*);
                    return false;
                },
                else => comptime unreachable,
            }
        }

        /// The widgets' editable text, which a property grid edits in a
        /// text field and a command palette takes its query in.
        pub const EditableText = @typeInfo(EditableTextPointer).pointer.child;

        fn PropertiesOf(comptime Pointer: type) type {
            const info = @typeInfo(Pointer);
            if (info == .pointer and info.pointer.size == .one and !info.pointer.is_const and @typeInfo(info.pointer.child) == .@"struct") {
                checkProperties(info.pointer.child);
                return info.pointer.child;
            }
            @compileError("zui_widgets_data: propertyGrid needs a mutable pointer to a struct, got " ++ @typeName(Pointer));
        }

        fn checkProperties(comptime T: type) void {
            for (@typeInfo(T).@"struct".fields) |field| {
                const options = declaredOptions(T, field.name);
                if (optionOf(options, "hidden", false)) continue;
                const editable = field.type == EditableText or switch (@typeInfo(field.type)) {
                    .bool, .int, .float => true,
                    .@"enum" => |enum_info| enum_info.is_exhaustive and enum_info.fields.len != 0,
                    .pointer => field.type == []const u8,
                    .@"struct" => |struct_info| struct_info.layout != .@"packed",
                    else => false,
                };
                if (!editable) @compileError("zui_widgets_data: propertyGrid cannot edit " ++ @typeName(T) ++ "." ++ field.name ++ ", a " ++ @typeName(field.type) ++ "; hide it with `.fields." ++ field.name ++ " = .{ .hidden = true }` in its zui_inspector");
            }
        }

        /// How far an overlay has entered through `motion`: 0 in the frame it
        /// opens, then toward 1.
        fn entrance(ui: *Ui, id: zui.Id, opening: bool, motion: anytype) f32 {
            if (opening) _ = switch (motion) {
                .spring => |options| zui.motion.spring(ui, id, f32, 0, options),
                .none, .tween => zui.motion.tween(ui, id, f32, 0, .{ .duration = 0 }),
            };
            return animate(ui, id, 1, motion);
        }

        fn animate(ui: *Ui, id: zui.Id, target: f32, motion: anytype) f32 {
            return switch (motion) {
                .none => target,
                .tween => |options| zui.motion.tween(ui, id, f32, target, options),
                .spring => |options| zui.motion.spring(ui, id, f32, target, options),
            };
        }

        fn decorationOf(look: SkinStyle, focused: bool) Ui.Decoration {
            return .{
                .background = look.background,
                .border = if (focused) look.focus_ring else look.border,
                .corner_radius = look.corner_radius,
                .corner_shape = look.corner_shape,
            };
        }

        fn focusShown(ui: *const Ui, id: zui.Id) bool {
            return ui.focused(id) and ui.focusVisible();
        }

        fn singleLine(text_style: Ui.TextStyle) Ui.TextStyle {
            var single_line = text_style;
            single_line.wrap = .none;
            return single_line;
        }

        fn spacer(ui: *Ui, height: f32) void {
            ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(height) } } });
        }

        /// The pointer, at its last press, inside the element as it was
        /// last laid out.
        fn pointerWithin(ui: *const Ui, id: zui.Id) bool {
            const local = ui.pointerLocal(id) orelse return false;
            const rect = ui.rectOf(id) orelse return false;
            return local[0] >= 0 and local[1] >= 0 and local[0] < rect.width and local[1] < rect.height;
        }
    };
}

/// One command of a command palette.
pub const Command = struct {
    label: []const u8,
    /// Drawn as a keycap at the end of its row; none when empty.
    shortcut: []const u8 = "",
    /// The heading it is listed under, with the commands of the same group
    /// declared before and after it; none when empty.
    group: []const u8 = "",
};

/// The row of the tree `tree_id` showing the node of `key`, whose
/// `child("chevron")` is its chevron.
///
/// ```zig
/// const archive_rect = ui.rectOf(zui_widgets_data.treeRowId(.of("folders"), archive.id));
/// ```
pub fn treeRowId(tree_id: zui.Id, key: u64) zui.Id {
    const row = tree_id.indexedChild("row", @truncate(key));
    if (@bitSizeOf(usize) >= @bitSizeOf(u64)) return row;
    return row.indexedChild("high", @truncate(key >> 32));
}

/// `widgets`' data components.
///
/// ```zig
/// const data = zui_widgets_data.of(widgets);
/// ```
pub fn of(widgets: anytype) Data(@TypeOf(widgets)) {
    return .{ .widgets = widgets };
}

pub const SplitAxis = enum {
    /// Panes side by side, the divider between them moving across.
    horizontal,
    /// Panes one above the other, the divider moving up and down.
    vertical,
};

/// Each component as review shows it: its `zuiPreviews`, the content it
/// is seen with, and `declare`, which declares it with one of them through
/// any `zui_widgets.Widgets`.
///
/// ```zig
/// const Glance = zui_design.Permutations(zui_widgets_data.previews.Table, .glance);
/// zui_widgets_data.previews.Table.declare(widgets, ui, Glance.preview(Glance.at(index)));
/// ```
pub const previews = struct {
    pub const Table = struct {
        pub const Content = struct { sorted: bool = false, selected: bool = false, resizable: bool = false };

        pub const zuiPreviews = .{
            .plain = Content{},
            .sorted = Content{ .sorted = true, .resizable = true },
            .selected = Content{ .selected = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var sort: Sort = if (content.sorted) .{ .column = 0 } else if (content.selected) .{ .column = 2, .descending = true } else .{};
            var selected_storage: [2]u64 = undefined;
            var selection: KeySet = .init(&selected_storage);
            if (content.selected) _ = selection.insert(1);
            var widths = [_]f32{ 0, 0, 0 };
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(preview_height) } } });
            _ = of(widgets).table(ui, .of("preview.table"), PreviewFile, &preview_files, .{
                .columns = &preview_file_columns,
                .sort = &sort,
                .selection = &selection,
                .widths = if (content.resizable) &widths else null,
                .label = "Files",
            });
            ui.close();
        }
    };

    pub const Tree = struct {
        pub const Content = struct { expanded: bool = true, selected: bool = false };

        pub const zuiPreviews = .{
            .expanded = Content{},
            .collapsed = Content{ .expanded = false },
            .selected = Content{ .selected = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var expanded_storage: [4]u64 = undefined;
            var expanded: KeySet = .init(&expanded_storage);
            if (content.expanded) {
                _ = expanded.insert(PreviewFolder.key(&preview_folders[0]));
                _ = expanded.insert(PreviewFolder.key(&preview_folders[0].children[1]));
            }
            var selected_storage: [2]u64 = undefined;
            var selection: KeySet = .init(&selected_storage);
            if (content.selected) _ = selection.insert(PreviewFolder.key(&preview_folders[1]));
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(preview_tree_width) } } });
            _ = of(widgets).tree(ui, .of("preview.tree"), PreviewFolder, &preview_folders, .{
                .expanded = &expanded,
                .selection = &selection,
                .label = PreviewFolder.name,
                .children = PreviewFolder.subfolders,
                .key = PreviewFolder.key,
                .accessible_label = "Folders",
            });
            ui.close();
        }
    };

    pub const SplitPane = struct {
        pub const Content = struct { axis: SplitAxis = .horizontal };

        pub const zuiPreviews = .{
            .side_by_side = Content{},
            .stacked = Content{ .axis = .vertical },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var size: f32 = preview_pane_size;
            const panes = of(widgets).splitPane(ui, .of("preview.split_pane"), &size, .{ .axis = content.axis, .min = preview_pane_size / 2, .label = "Sidebar width", .height = .fixed(preview_height) });
            widgets.label(ui, "Inbox");
            panes.second(ui);
            widgets.label(ui, "The release notes for 2.4");
            panes.end(ui);
        }
    };

    pub const Toolbar = struct {
        pub const Content = struct { width: zui.Sizing = .grow };

        pub const zuiPreviews = .{
            .roomy = Content{},
            .overflowing = Content{ .width = .fixed(preview_narrow_width) },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var bar = of(widgets).toolbar(ui, .of("preview.toolbar"), .{ .label = "Editing", .width = content.width });
            _ = bar.item(ui, .of("preview.toolbar.undo"), "Undo", .{});
            _ = bar.item(ui, .of("preview.toolbar.redo"), "Redo", .{ .disabled = true });
            bar.separator(ui);
            _ = bar.item(ui, .of("preview.toolbar.crop"), "Crop", .{});
            _ = bar.item(ui, .of("preview.toolbar.rotate"), "Rotate", .{});
            bar.separator(ui);
            _ = bar.item(ui, .of("preview.toolbar.export"), "Export", .{});
            bar.end(ui);
        }
    };

    pub const StatusBar = struct {
        pub const Content = struct { texts: []const []const u8 };

        pub const zuiPreviews = .{
            .short = Content{ .texts = &.{ "6 files", "Saved" } },
            .busy = Content{ .texts = &.{ "1,204 files", "3 selected", "Syncing", "Ln 12, Col 4" } },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            const data = of(widgets);
            data.statusBar(ui, .of("preview.status_bar"), .{ .label = "Status" });
            for (content.texts) |text| data.statusText(ui, text);
            ui.close();
        }
    };

    pub const CommandPalette = struct {
        pub const Content = struct { query: []const u8 = "" };

        pub const zuiPreviews = .{
            .every_command = Content{},
            .filtered = Content{ .query = "ex" },
            .no_match = Content{ .query = "zebra" },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            const Shown = @TypeOf(of(widgets));
            var query_bytes: [32]u8 = undefined;
            var query: Shown.EditableText = .init(&query_bytes, content.query);
            var open = true;
            _ = of(widgets).commandPalette(ui, .of("preview.command_palette"), &open, &preview_commands, .{ .query = &query });
        }
    };

    pub const PropertyGrid = struct {
        pub const Content = struct { changed: bool = false };

        pub const zuiPreviews = .{
            .defaults = Content{},
            .changed = Content{ .changed = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var photo: PreviewPhoto = .{};
            if (content.changed) {
                photo.iso = 800;
                photo.raw = true;
            }
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(preview_grid_width) } } });
            _ = of(widgets).propertyGrid(ui, .of("preview.property_grid"), &photo);
            ui.close();
        }
    };

    /// Every component above.
    pub const all = .{ Table, Tree, SplitPane, Toolbar, StatusBar, CommandPalette, PropertyGrid };

    const preview_narrow_width = 240;
    const preview_grid_width = 420;

    const preview_commands = [_]Command{
        .{ .label = "Open file", .shortcut = "Ctrl+O", .group = "File" },
        .{ .label = "Export as PNG", .shortcut = "Ctrl+E", .group = "File" },
        .{ .label = "Export as JPEG", .group = "File" },
        .{ .label = "Toggle grid", .shortcut = "Ctrl+G", .group = "View" },
        .{ .label = "Zoom to fit", .group = "View" },
    };

    const PreviewPhoto = struct {
        camera: []const u8 = "X100V",
        exposure: f32 = 0.5,
        iso: u16 = 400,
        mode: enum { auto, manual } = .auto,
        raw: bool = false,
        crop: struct { width: u16 = 6000, height: u16 = 4000 } = .{},

        pub const zui_inspector = .{ .fields = .{ .exposure = .{ .min = 0, .max = 1 }, .iso = .{ .label = "ISO" } } };
    };

    const preview_height = 200;
    const preview_tree_width = 240;
    const preview_pane_size = 120;

    const PreviewFile = struct {
        name: []const u8,
        kind: []const u8,
        kilobytes: u32,

        fn nameOf(file: *const PreviewFile, _: *[cell_capacity]u8) []const u8 {
            return file.name;
        }

        fn kindOf(file: *const PreviewFile, _: *[cell_capacity]u8) []const u8 {
            return file.kind;
        }

        fn sizeOf(file: *const PreviewFile, buffer: *[cell_capacity]u8) []const u8 {
            return std.fmt.bufPrint(buffer, "{d} KB", .{file.kilobytes}) catch "";
        }
    };

    const preview_file_columns = [_]Column(PreviewFile){
        .{ .title = "Name", .text = PreviewFile.nameOf },
        .{ .title = "Kind", .text = PreviewFile.kindOf, .width = 96 },
        .{ .title = "Size", .text = PreviewFile.sizeOf, .width = 88, .numeric = true },
    };

    const preview_files = [_]PreviewFile{
        .{ .name = "release-notes.md", .kind = "Text", .kilobytes = 12 },
        .{ .name = "harbor.png", .kind = "Image", .kilobytes = 840 },
        .{ .name = "budget.csv", .kind = "Table", .kilobytes = 96 },
        .{ .name = "intro.mp4", .kind = "Video", .kilobytes = 20480 },
        .{ .name = "notes.txt", .kind = "Text", .kilobytes = 4 },
        .{ .name = "logo.svg", .kind = "Image", .kilobytes = 18 },
    };

    const PreviewFolder = struct {
        title: []const u8,
        id: u64,
        children: []const PreviewFolder = &.{},

        fn name(folder: *const PreviewFolder) []const u8 {
            return folder.title;
        }

        fn subfolders(folder: *const PreviewFolder) []const PreviewFolder {
            return folder.children;
        }

        fn key(folder: *const PreviewFolder) u64 {
            return folder.id;
        }
    };

    const preview_folders = [_]PreviewFolder{
        .{ .title = "Projects", .id = 1, .children = &.{
            .{ .title = "Harbor", .id = 2 },
            .{ .title = "Field Guide", .id = 3, .children = &.{
                .{ .title = "Drafts", .id = 4 },
                .{ .title = "Photos", .id = 5 },
            } },
        } },
        .{ .title = "Archive", .id = 6, .children = &.{.{ .title = "2025", .id = 7 }} },
        .{ .title = "Shared", .id = 8 },
    };
};

const toolbar_overflow_most = 32;
const overflow_label = "More";
/// The share of the window's height above a command palette.
const palette_top_share = 0.2;
const palette_enter_slide = 8;
const palette_results_most = 8;
const property_label_share = 0.4;

/// A row of a property grid, or of `zui_reflect.inspector`: its label in
/// a column of 40% of the row, at least the skin's `property_row` width,
/// with a dot after it when `changed`. Declare the editor, then close the
/// row.
fn propertyRow(widgets: anytype, ui: anytype, label: []const u8, changed: bool) void {
    const row = widgets.style(ui, .property_row, .idle);
    var name = widgets.style(ui, .property_label, .idle).text;
    name.wrap = .words;
    ui.open(.{ .layout = .{
        .sizing = .{ .width = .grow, .height = .fitBetween(row.size[1], std.math.inf(f32)) },
        .padding = .{ .top = row.padding.top, .bottom = row.padding.bottom },
        .child_gap = row.gap,
        .child_alignment = .{ .y = .center },
    } });
    ui.open(.{ .layout = .{ .sizing = .{ .width = .{ .rule = .percent, .amount = property_label_share, .min = row.size[0] } }, .child_gap = row.gap / 2, .child_alignment = .{ .y = .center } } });
    ui.text(label, name);
    if (changed) {
        const dot = widgets.style(ui, .property_changed, .idle);
        ui.box(.{ .decoration = .{ .background = dot.background, .corner_radius = dot.corner_radius, .corner_shape = dot.corner_shape }, .layout = .{ .sizing = .{ .width = .fixed(dot.size[0]), .height = .fixed(dot.size[0]) } } });
    }
    ui.close();
}

fn changedFromDefault(comptime Field: type, value: Field, comptime default: ?Field) bool {
    const original = default orelse return false;
    return switch (@typeInfo(Field)) {
        .bool, .int, .float, .@"enum" => value != original,
        .pointer => if (Field == []const u8) !std.mem.eql(u8, value, original) else false,
        else => false,
    };
}

/// A field's entry in its struct's `zui_inspector`, or none.
fn declaredOptions(comptime T: type, comptime name: []const u8) DeclaredOptions(T, name) {
    if (DeclaredOptions(T, name) == NoOptions) return .{};
    return @field(T.zui_inspector.fields, name);
}

fn DeclaredOptions(comptime T: type, comptime name: []const u8) type {
    if (!@hasDecl(T, "zui_inspector")) return NoOptions;
    const Fields = @TypeOf(T.zui_inspector.fields);
    return if (@hasField(Fields, name)) @FieldType(Fields, name) else NoOptions;
}

const NoOptions = struct {};

fn optionOf(comptime options: anytype, comptime key: []const u8, comptime fallback: anytype) @TypeOf(fallback) {
    return if (@hasField(@TypeOf(options), key)) @field(options, key) else fallback;
}

/// "max_fps" is "Max fps".
fn labelOf(comptime identifier: []const u8) []const u8 {
    return comptime blk: {
        var bytes: [identifier.len]u8 = identifier[0..identifier.len].*;
        for (&bytes) |*byte| {
            if (byte.* == '_') byte.* = ' ';
        }
        if (bytes.len != 0) bytes[0] = std.ascii.toUpper(bytes[0]);
        const label = bytes;
        break :blk &label;
    };
}

/// Where `query` first falls in `label`, ignoring case; the whole of an
/// empty query matches at the start.
fn matchOf(label: []const u8, query: []const u8) ?[2]usize {
    if (query.len == 0) return .{ 0, 0 };
    const at = std.ascii.indexOfIgnoreCase(label, query) orelse return null;
    return .{ at, at + query.len };
}

fn matchCount(commands: []const Command, query: []const u8) usize {
    var count: usize = 0;
    for (commands) |command| {
        if (matchOf(command.label, query) != null) count += 1;
    }
    return count;
}

/// The index in `commands` of the match at `position` among the matches.
fn commandAt(commands: []const Command, query: []const u8, position: usize) ?usize {
    var seen: usize = 0;
    for (commands, 0..) |command, index| {
        if (matchOf(command.label, query) == null) continue;
        if (seen == position) return index;
        seen += 1;
    }
    return null;
}

/// `color` with its alpha scaled by `share`, in any context's color type.
fn faded(color: anytype, share: f32) @TypeOf(color) {
    var clear = color;
    clear.a = 0;
    return clear.mix(color, share);
}

/// How far the arrows move a split pane's divider or a column's edge.
const keyboard_step = 16;
const divider_hover_seconds = 0.15;
/// Measured for a row's height, which no text of the row may outgrow.
const line_sample = "Ag";

const Rounding = enum { up, down };

fn rowsBefore(length: f32, row_height: f32, rounding: Rounding) usize {
    const rows = @max(length, 0) / row_height;
    return @intFromFloat(switch (rounding) {
        .up => @ceil(rows),
        .down => @floor(rows),
    });
}

fn heightOf(rows: usize, row_height: f32) f32 {
    return @as(f32, @floatFromInt(rows)) * row_height;
}

fn TreeWalk(comptime Node: type) type {
    return struct {
        const Found = struct {
            node: ?*const Node = null,
            parent: ?*const Node = null,
            /// The nodes beside it, under its parent or among the roots.
            siblings: []const Node = &.{},
            previous: ?*const Node = null,
            next: ?*const Node = null,
            first: ?*const Node = null,
            last: ?*const Node = null,
        };

        /// The node of `key` among those shown, and the rows around it.
        fn locate(roots: []const Node, options: anytype, key: u64) Found {
            var found: Found = .{};
            var previous: ?*const Node = null;
            visit(roots, options, key, null, &found, &previous);
            return found;
        }

        fn visit(nodes: []const Node, options: anytype, key: u64, parent: ?*const Node, found: *Found, previous: *?*const Node) void {
            for (nodes) |*node| {
                if (found.first == null) found.first = node;
                found.last = node;
                if (found.node != null and found.next == null) found.next = node;
                const node_key = options.key(node);
                if (found.node == null and node_key == key) found.* = .{ .node = node, .parent = parent, .siblings = nodes, .previous = previous.*, .first = found.first, .last = node };
                previous.* = node;
                const children = options.children(node);
                if (children.len != 0 and options.expanded.contains(node_key)) visit(children, options, key, node, found, previous);
            }
        }
    };
}

fn rowCount(rows: anytype) usize {
    return if (comptime isListOfRows(@TypeOf(rows))) rows.len else rows.count();
}

fn rowAt(comptime Row: type, rows: anytype, index: usize) Row {
    return if (comptime isListOfRows(@TypeOf(rows))) rows[index] else rows.row(index);
}

fn isListOfRows(comptime Rows: type) bool {
    const info = @typeInfo(Rows);
    if (info != .pointer) return false;
    return info.pointer.size == .slice or (info.pointer.size == .one and @typeInfo(info.pointer.child) == .array);
}

fn checkRows(comptime Row: type, comptime Rows: type) void {
    const info = @typeInfo(Rows);
    if (info == .pointer and info.pointer.size == .slice and info.pointer.child == Row) return;
    if (info == .pointer and info.pointer.size == .one and @typeInfo(info.pointer.child) == .array and @typeInfo(info.pointer.child).array.child == Row) return;
    const Source = if (info == .pointer and info.pointer.size == .one) info.pointer.child else Rows;
    if (@typeInfo(Source) == .@"struct" and @hasDecl(Source, "count") and @hasDecl(Source, "row")) return;
    @compileError("zui_widgets_data: table needs its rows as a slice of " ++ @typeName(Row) ++ " or a value with `count()` and `row(index)`, got " ++ @typeName(Rows));
}

fn checkWidgets(comptime WidgetsType: type) void {
    const is_widgets = @typeInfo(WidgetsType) == .@"struct" and @hasDecl(WidgetsType, "Ui") and @hasDecl(WidgetsType, "SkinStyle") and
        @hasDecl(WidgetsType, "style") and @hasDecl(WidgetsType, "inEnclosingLayer");
    if (!is_widgets) @compileError("zui_widgets_data: Data needs a zui_widgets.Widgets(Ui, Skin), got " ++ @typeName(WidgetsType));
}

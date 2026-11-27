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

    /// Every component above.
    pub const all = .{ Table, Tree, SplitPane };

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

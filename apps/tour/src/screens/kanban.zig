const std = @import("std");
const zui = @import("zui");

const list_count = 4;
const list_capacity = 24;
const card_capacity = 64;
const title_capacity = 56;
const exit_seconds = 0.25;
const auto_scroll_edge = 48;
const auto_scroll_step = 10;

const list_names = [list_count][]const u8{ "Backlog", "In progress", "Review", "Done" };
/// How many cards a list should hold at most; 0 for no limit.
const work_in_progress_limits = [list_count]u32{ 0, 4, 3, 0 };

const Tag = enum(u8) {
    feature,
    bug,
    chore,
    docs,

    fn name(tag: Tag) []const u8 {
        return @tagName(tag);
    }
};

const Card = struct {
    /// Never reused, so a card keeps its element id, focus and state for
    /// as long as it lives, whichever list it is in.
    uid: u32 = 0,
    title_bytes: [title_capacity]u8 = undefined,
    title_len: u8 = 0,
    tag: Tag = .feature,
    points: u8 = 1,

    fn title(card: *const Card) []const u8 {
        return card.title_bytes[0..card.title_len];
    }

    fn id(card: *const Card) zui.Id {
        return .indexed("kanban.card", card.uid);
    }
};

const List = struct {
    /// Slots in `Board.cards`, top first.
    slots: [list_capacity]u8 = undefined,
    len: usize = 0,

    fn items(list: *const List) []const u8 {
        return list.slots[0..list.len];
    }

    fn indexOf(list: *const List, slot: u8) ?usize {
        return std.mem.indexOfScalar(u8, list.items(), slot);
    }

    fn insert(list: *List, index: usize, slot: u8) void {
        const at = @min(index, list.len);
        std.mem.copyBackwards(u8, list.slots[at + 1 .. list.len + 1], list.slots[at..list.len]);
        list.slots[at] = slot;
        list.len += 1;
    }

    fn remove(list: *List, index: usize) void {
        std.mem.copyForwards(u8, list.slots[index .. list.len - 1], list.slots[index + 1 .. list.len]);
        list.len -= 1;
    }
};

const Place = struct { list: usize, index: usize };

const seed_cards = [_]struct { usize, Tag, u8, []const u8 }{
    .{ 0, .feature, 5, "Export a board as CSV" },
    .{ 0, .bug, 2, "Avatar upload fails over 4 MB" },
    .{ 0, .feature, 3, "Due dates on cards" },
    .{ 0, .chore, 1, "Bump the CI image to the new LTS" },
    .{ 0, .docs, 2, "Write the self-hosting guide" },
    .{ 0, .bug, 3, "Search misses titles with accents" },
    .{ 1, .feature, 8, "Single sign-on with SAML" },
    .{ 1, .bug, 2, "Billing page shows last month's plan" },
    .{ 1, .chore, 3, "Move sessions to the new cache" },
    .{ 2, .feature, 3, "Keyboard shortcuts for every action" },
    .{ 2, .docs, 1, "Changelog for 2.4" },
    .{ 3, .bug, 1, "Timezone off by one in reports" },
    .{ 3, .feature, 5, "Dark theme" },
    .{ 3, .chore, 2, "Remove the legacy importer" },
};

/// The cards and the four lists they are in, all in fixed storage.
const Board = struct {
    cards: [card_capacity]Card = undefined,
    used: std.StaticBitSet(card_capacity) = .initEmpty(),
    lists: [list_count]List = @splat(.{}),
    next_uid: u32 = 1,

    fn seed(board: *Board) void {
        for (seed_cards) |seed_card| _ = board.add(seed_card[0], seed_card[1], seed_card[2], seed_card[3]);
    }

    fn add(board: *Board, list: usize, tag: Tag, points: u8, title: []const u8) ?u8 {
        if (board.lists[list].len == list_capacity) return null;
        const slot: u8 = @intCast(board.used.complement().findFirstSet() orelse return null);
        board.used.set(slot);
        var card: Card = .{ .uid = board.next_uid, .tag = tag, .points = points };
        board.next_uid += 1;
        const kept = @min(title.len, title_capacity);
        @memcpy(card.title_bytes[0..kept], title[0..kept]);
        card.title_len = @intCast(kept);
        board.cards[slot] = card;
        board.lists[list].insert(board.lists[list].len, slot);
        return slot;
    }

    fn placeOf(board: *const Board, slot: u8) ?Place {
        for (&board.lists, 0..) |*list, list_index| {
            if (list.indexOf(slot)) |index| return .{ .list = list_index, .index = index };
        }
        return null;
    }

    fn slotOfUid(board: *const Board, uid: u32) ?u8 {
        var used = board.used.iterator(.{});
        while (used.next()) |slot| if (board.cards[slot].uid == uid) return @intCast(slot);
        return null;
    }

    /// Moves the card to `to.index` in `to.list` as it reads with the
    /// card taken out. Refuses when the list is full.
    fn move(board: *Board, slot: u8, to: Place) bool {
        const from = board.placeOf(slot) orelse return false;
        if (from.list != to.list and board.lists[to.list].len == list_capacity) return false;
        board.lists[from.list].remove(from.index);
        board.lists[to.list].insert(to.index, slot);
        return true;
    }

    fn delete(board: *Board, slot: u8) void {
        const place = board.placeOf(slot) orelse return;
        board.lists[place.list].remove(place.index);
        board.used.unset(slot);
    }

    fn count(board: *const Board) usize {
        return board.used.count();
    }
};

const CardDrag = struct { uid: u32 };

const ids = zui.ids(.{
    "kanban.new_title",
    "kanban.new_list",
    "kanban.add",
    "kanban.menu",
    "kanban.menu_backdrop",
    "kanban.ghost",
});

fn listId(list: usize) zui.Id {
    return .indexed("kanban.list", list);
}

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    const EditableText = kit.zui_widgets.EditableText;
    return struct {
        pub const Kanban = struct {
            board: Board = .{},
            new_title_bytes: [title_capacity]u8 = undefined,
            new_title_len: usize = 0,
            new_list: usize = 0,
            message: []const u8 = "",
            /// The card whose actions menu is open.
            menu_uid: ?u32 = null,
            /// Where a drag over each list would land, from the last frame
            /// the pointer was over it.
            drop_index: [list_count]usize = @splat(0),
            /// The card a key moved, which keeps focus and is scrolled to.
            focus_uid: ?u32 = null,

            pub fn init(self: *Kanban) void {
                self.board.seed();
            }

            pub fn declare(self: *Kanban, ui: *Ui, shell: *const Shell) void {
                self.handleCardKeys(ui);
                self.takeDrops(ui);

                {
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 4 } });
                    defer ui.close();
                    shell.label(ui, .body, "Plan a release across four lists, with the pointer or the keyboard alone.");
                    shell.label(ui, .caption, "Drag a card to another list or place. Tab to a card: arrows move between cards, Ctrl+arrows move the card, Delete removes it, the Menu key or a right-click opens its actions.");
                }
                self.toolbar(ui, shell);
                var dragged: ?DragSeen = null;
                {
                    ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                    defer ui.close();
                    for (0..list_count) |list| {
                        if (self.declareList(ui, shell, list)) |drag| dragged = drag;
                    }
                }
                if (dragged) |drag| self.dragGhost(ui, shell, drag.slot, drag.position);
                if (self.menu_uid) |uid| self.actionsMenu(ui, shell, uid);
            }

            fn toolbar(self: *Kanban, ui: *Ui, shell: *const Shell) void {
                const widgets = shell.widgets;
                const palette = shell.palette;
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                var new_title: EditableText = .{ .buffer = &self.new_title_bytes, .len = self.new_title_len };
                const typed = widgets.textField(ui, ids.@"kanban.new_title", &new_title, .{ .placeholder = "New card title", .label = "New card title", .width = .fixed(280) });
                self.new_title_len = new_title.len;
                _ = widgets.dropdown(ui, ids.@"kanban.new_list", &self.new_list, &list_names, .{ .label = "List" });
                const can_add = std.mem.trim(u8, new_title.slice(), " ").len != 0;
                if (widgets.button(ui, ids.@"kanban.add", "Add card", .{ .disabled = !can_add }) or (typed.submitted and can_add)) {
                    if (self.board.add(self.new_list, .feature, 1, std.mem.trim(u8, new_title.slice(), " "))) |_| {
                        self.new_title_len = 0;
                        self.message = "";
                    } else self.message = "That list is full.";
                }
                if (self.message.len != 0) shell.labelColored(ui, .caption, palette.warn, self.message);
                shell.spacer(ui);
                shell.printColored(ui, .caption, palette.muted, "{d} cards, {d} points in progress", .{ self.board.count(), self.pointsIn(1) + self.pointsIn(2) });
            }

            fn pointsIn(self: *const Kanban, list: usize) u32 {
                var points: u32 = 0;
                for (self.board.lists[list].items()) |slot| points += self.board.cards[slot].points;
                return points;
            }

            /// Arrows move focus between cards; with Ctrl they move the
            /// focused card itself; Delete removes it.
            fn handleCardKeys(self: *Kanban, ui: *Ui) void {
                const slot = self.focusedSlot(ui) orelse return;
                const place = self.board.placeOf(slot) orelse return;
                for (ui.keyEvents()) |key_event| {
                    const control = key_event.modifiers.control;
                    switch (key_event.key) {
                        .up => if (control) {
                            if (place.index > 0) self.moveFocused(ui, slot, .{ .list = place.list, .index = place.index - 1 });
                        } else self.focusAt(ui, place.list, place.index -| 1),
                        .down => if (control) {
                            self.moveFocused(ui, slot, .{ .list = place.list, .index = place.index + 1 });
                        } else self.focusAt(ui, place.list, place.index + 1),
                        .left => if (place.list > 0) {
                            if (control) self.moveFocused(ui, slot, .{ .list = place.list - 1, .index = place.index }) else self.focusAt(ui, place.list - 1, place.index);
                        },
                        .right => if (place.list + 1 < list_count) {
                            if (control) self.moveFocused(ui, slot, .{ .list = place.list + 1, .index = place.index }) else self.focusAt(ui, place.list + 1, place.index);
                        },
                        .delete, .backspace => {
                            self.deleteCard(ui, slot);
                            return;
                        },
                        else => continue,
                    }
                    return;
                }
            }

            fn focusedSlot(self: *const Kanban, ui: *const Ui) ?u8 {
                var used = self.board.used.iterator(.{});
                while (used.next()) |slot| {
                    const card = &self.board.cards[slot];
                    if (ui.focused(card.id())) return @intCast(slot);
                }
                return null;
            }

            fn moveFocused(self: *Kanban, ui: *Ui, slot: u8, to: Place) void {
                if (!self.board.move(slot, to)) {
                    self.message = "That list is full.";
                    return;
                }
                self.focus_uid = self.board.cards[slot].uid;
                ui.requestFrame();
            }

            fn focusAt(self: *Kanban, ui: *Ui, list: usize, index: usize) void {
                const items = self.board.lists[list].items();
                if (items.len == 0) return;
                const card = &self.board.cards[items[@min(index, items.len - 1)]];
                self.focus_uid = card.uid;
                ui.requestFocus(card.id());
            }

            /// The card's `exit` fades it out once it is no longer declared.
            fn deleteCard(self: *Kanban, ui: *Ui, slot: u8) void {
                const place = self.board.placeOf(slot) orelse return;
                const items = self.board.lists[place.list].items();
                const neighbour: ?u8 = if (place.index + 1 < items.len) items[place.index + 1] else if (place.index > 0) items[place.index - 1] else null;
                if (neighbour) |next| ui.requestFocus(self.board.cards[next].id());
                if (self.menu_uid == self.board.cards[slot].uid) self.menu_uid = null;
                self.board.delete(slot);
            }

            const DragSeen = struct { slot: u8, position: [2]f32 };

            /// Before any list is declared, so a card moved by a drop is
            /// declared once, in its new list.
            fn takeDrops(self: *Kanban, ui: *Ui) void {
                for (0..list_count) |list| {
                    const drop = ui.dropped(listId(list), CardDrag) orelse continue;
                    const slot = self.board.slotOfUid(drop.uid) orelse continue;
                    if (self.board.move(slot, .{ .list = list, .index = self.drop_index[list] })) {
                        self.focus_uid = drop.uid;
                    } else self.message = "That list is full.";
                }
            }

            fn declareList(self: *Kanban, ui: *Ui, shell: *const Shell, list: usize) ?DragSeen {
                const palette = shell.palette;
                const scroll_id = listId(list);
                const items = self.board.lists[list].items();
                var dragged: ?DragSeen = null;

                const incoming = ui.draggedOver(scroll_id, CardDrag);
                if (incoming) |drag| self.trackDrop(ui, list, drag.uid);

                const limit = work_in_progress_limits[list];
                const over_limit = limit != 0 and items.len > limit;
                ui.open(.{
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow_equal, .height = .grow }, .padding = .all(10), .child_gap = 8 },
                    .decoration = .{
                        .background = palette.sunken,
                        .border = .{ .color = if (incoming != null) palette.accent else palette.border, .widths = .all(1) },
                        .corner_radius = .all(8),
                    },
                });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .padding = .symmetric(4, 2), .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    shell.label(ui, .heading, list_names[list]);
                    shell.spacer(ui);
                    if (limit != 0) {
                        shell.printColored(ui, .caption, if (over_limit) palette.warn else palette.muted, "{d} / {d}", .{ items.len, limit });
                    } else shell.printColored(ui, .caption, palette.muted, "{d}", .{items.len});
                }
                if (over_limit) shell.labelColored(ui, .caption, palette.warn, "Over its work-in-progress limit");

                ui.open(.{
                    .id = scroll_id,
                    .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 8 },
                    .scroll = .{},
                    .semantics = .{ .role = .list_box, .label = list_names[list] },
                });
                defer ui.close();
                var shown_index: usize = 0;
                for (items) |slot| {
                    const card = &self.board.cards[slot];
                    const is_dragged_card = if (incoming) |drag| drag.uid == card.uid else false;
                    if (incoming != null and !is_dragged_card and shown_index == self.drop_index[list]) self.dropIndicator(ui, shell);
                    if (!is_dragged_card) shown_index += 1;
                    if (self.declareCard(ui, shell, slot)) |position| dragged = .{ .slot = slot, .position = position };
                }
                if (incoming != null and shown_index <= self.drop_index[list]) self.dropIndicator(ui, shell);
                if (items.len == 0) {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .padding = .all(12), .child_alignment = .{ .x = .center } } });
                    shell.labelColored(ui, .caption, palette.faint, "Drop a card here");
                    ui.close();
                }
                return dragged;
            }

            /// Where the pointer would drop the card among the others,
            /// from the cards' rectangles in the last frame, and scrolls the
            /// list while the pointer rests near its top or bottom.
            fn trackDrop(self: *Kanban, ui: *Ui, list: usize, dragged_uid: u32) void {
                const scroll_id = listId(list);
                const pointer = ui.primaryPointer() orelse return;
                var index: usize = 0;
                for (self.board.lists[list].items()) |slot| {
                    const card = &self.board.cards[slot];
                    if (card.uid == dragged_uid) continue;
                    const rect = ui.rectOf(card.id()) orelse continue;
                    if (pointer.position[1] > rect.y + rect.height / 2) index += 1;
                }
                self.drop_index[list] = index;

                const visible = ui.rectOf(scroll_id) orelse return;
                const local_y = pointer.position[1] - visible.y;
                var offset = ui.scrollOffset(scroll_id);
                if (local_y < auto_scroll_edge and offset[1] > 0) {
                    offset[1] = @max(0, offset[1] - auto_scroll_step);
                } else if (local_y > visible.height - auto_scroll_edge) {
                    offset[1] += auto_scroll_step;
                } else return;
                ui.setScrollOffset(scroll_id, offset);
                ui.requestFrame();
            }

            fn dropIndicator(_: *Kanban, ui: *Ui, shell: *const Shell) void {
                ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(3) } }, .decoration = .{ .background = shell.palette.accent, .corner_radius = .all(1.5) } });
            }

            /// Returns where a pointer is dragging the card, if one is.
            fn declareCard(self: *Kanban, ui: *Ui, shell: *const Shell, slot: u8) ?[2]f32 {
                const palette = shell.palette;
                const card = &self.board.cards[slot];
                const id = card.id();

                if (self.focus_uid == card.uid) {
                    self.focus_uid = null;
                    if (!ui.focused(id)) ui.requestFocus(id);
                    if (ui.rectOf(id)) |rect| revealInList(ui, self.board.placeOf(slot).?.list, rect);
                }
                if (ui.contextRequested(id)) {
                    self.menu_uid = card.uid;
                    ui.requestFocus(id.child("menu_first"));
                }
                const drag = ui.dragging(id);
                if (drag != null) ui.startDrag(id, CardDrag{ .uid = card.uid });

                const focused = ui.focused(id);
                const hovered = ui.hovered(id);
                ui.open(.{
                    .id = id,
                    .focusable = true,
                    .cursor = if (drag != null) .grabbing else .grab,
                    .gestures = .{ .drag = true, .long_press = true },
                    .semantics = .{ .role = .button, .label = card.title(), .actions = .initMany(&.{ .show_menu, .focus }) },
                    .exit = .{ .seconds = exit_seconds, .fade = .ease_out },
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(12), .child_gap = 8 },
                    .decoration = .{
                        .background = if (drag != null) palette.sunken else if (hovered) palette.raised else palette.surface,
                        .border = .{ .color = if (focused) palette.focus else palette.border, .widths = .all(if (focused) 2 else 1) },
                        .corner_radius = .all(8),
                    },
                });
                defer ui.close();
                if (drag != null) {
                    shell.labelColored(ui, .body, palette.faint, card.title());
                } else shell.label(ui, .body, card.title());
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    shell.chip(ui, card.tag.name(), tagColor(shell, card.tag));
                    shell.printColored(ui, .caption, palette.muted, "{d} pt", .{card.points});
                    shell.spacer(ui);
                    shell.printColored(ui, .tiny, palette.faint, "#{d}", .{card.uid});
                }
                return if (drag) |moving| moving.position else null;
            }

            fn dragGhost(self: *Kanban, ui: *Ui, shell: *const Shell, slot: u8, position: [2]f32) void {
                const palette = shell.palette;
                const card = &self.board.cards[slot];
                ui.open(.{
                    .id = ids.@"kanban.ghost",
                    .floating = .{ .attach_to = .root, .offset = .{ position[0] + 12, position[1] + 8 }, .z = 400, .capture = false },
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(240) }, .padding = .all(12), .child_gap = 6 },
                    .decoration = .{ .background = palette.raised, .border = .{ .color = palette.accent, .widths = .all(1) }, .corner_radius = .all(8) },
                    .effects = &.{ .shadow = .{ .color = .rgba(0x00000050), .offset = .{ 0, 8 }, .blur = 20 } },
                });
                defer ui.close();
                shell.label(ui, .body, card.title());
                shell.chip(ui, card.tag.name(), tagColor(shell, card.tag));
            }

            fn actionsMenu(self: *Kanban, ui: *Ui, shell: *const Shell, uid: u32) void {
                const palette = shell.palette;
                const slot = self.board.slotOfUid(uid) orelse {
                    self.menu_uid = null;
                    return;
                };
                const card = &self.board.cards[slot];
                const place = self.board.placeOf(slot) orelse return;
                const menu_id = ids.@"kanban.menu";
                if (ui.clicked(ids.@"kanban.menu_backdrop") or ui.dismissed(menu_id)) {
                    self.menu_uid = null;
                    ui.requestFocus(card.id());
                    return;
                }
                const viewport = ui.viewport();
                ui.box(.{
                    .id = ids.@"kanban.menu_backdrop",
                    .interactive = true,
                    .floating = .{ .attach_to = .root, .z = 300 },
                    .layout = .{ .sizing = .{ .width = .fixed(viewport[0]), .height = .fixed(viewport[1]) } },
                });
                ui.open(.{
                    .id = menu_id,
                    .focus_scope = true,
                    .semantics = .{ .role = .group, .label = "Card actions", .actions = .initOne(.dismiss) },
                    .floating = .{ .attach_to = .{ .element = card.id() }, .attach_point = .bottom_left, .offset = .{ 0, 4 }, .z = 301 },
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(220) }, .padding = .all(6), .child_gap = 2 },
                    .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
                    .effects = &.{ .shadow = .{ .color = .rgba(0x00000060), .offset = .{ 0, 8 }, .blur = 24 } },
                });
                defer ui.close();
                var option_index: usize = 0;
                for (0..list_count) |list| {
                    if (list == place.list) continue;
                    var label_buffer: [32]u8 = undefined;
                    const label = std.fmt.bufPrint(&label_buffer, "Move to {s}", .{list_names[list]}) catch "Move";
                    if (menuOption(ui, shell, card.id(), option_index, label, false)) {
                        if (self.board.move(slot, .{ .list = list, .index = self.board.lists[list].len })) self.focus_uid = uid else self.message = "That list is full.";
                        self.menu_uid = null;
                    }
                    option_index += 1;
                }
                if (menuOption(ui, shell, card.id(), option_index, "Move to the top", false)) {
                    _ = self.board.move(slot, .{ .list = place.list, .index = 0 });
                    self.focus_uid = uid;
                    self.menu_uid = null;
                }
                option_index += 1;
                if (menuOption(ui, shell, card.id(), option_index, "Delete", true)) {
                    self.menu_uid = null;
                    self.deleteCard(ui, slot);
                }
            }
        };

        fn menuOption(ui: *Ui, shell: *const Shell, card_id: zui.Id, index: usize, label: []const u8, destructive: bool) bool {
            const palette = shell.palette;
            const id = if (index == 0) card_id.child("menu_first") else card_id.indexedChild("menu_option", index);
            const state = ui.widgetState(id);
            ui.open(.{
                .id = id,
                .focusable = true,
                .cursor = .pointer,
                .semantics = .{ .role = .button, .label = label },
                .layout = .{ .sizing = .{ .width = .grow }, .padding = .symmetric(10, 6) },
                .decoration = .{
                    .background = if (state == .hovered or state == .pressed or ui.focused(id)) palette.hovered else null,
                    .corner_radius = .all(4),
                },
            });
            shell.labelColored(ui, .body, if (destructive) palette.bad else palette.text, label);
            ui.close();
            return ui.clicked(id);
        }

        fn revealInList(ui: *Ui, list: usize, card: zui.Rect) void {
            const scroll_id = listId(list);
            const visible = ui.rectOf(scroll_id) orelse return;
            var offset = ui.scrollOffset(scroll_id);
            if (card.y < visible.y) offset[1] -= visible.y - card.y;
            if (card.y + card.height > visible.y + visible.height) offset[1] += card.y + card.height - visible.y - visible.height;
            ui.setScrollOffset(scroll_id, .{ offset[0], @max(0, offset[1]) });
        }

        fn tagColor(shell: *const Shell, tag: Tag) zui.Color {
            return switch (tag) {
                .feature => shell.palette.accent,
                .bug => shell.palette.bad,
                .chore => shell.palette.muted,
                .docs => shell.palette.good,
            };
        }
    };
}

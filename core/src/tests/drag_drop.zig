//! Drags are arbitrated against the previous frame's hit regions, so each
//! test declares a frame before the one whose input it checks.

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;
const Ui = support.Ui;
const Harness = support.Harness;

const Card = struct { number: u8 };
const Note = struct { number: u8 };

fn fixed(width: f32, height: f32) zui.Layout {
    return .{ .sizing = .{ .width = .fixed(width), .height = .fixed(height) } };
}

fn columnId(column: usize) zui.Id {
    return .indexed("column", column);
}

fn cardId(number: u8) zui.Id {
    return .indexed("card", number);
}

/// Two columns 200×300, 50 apart, that scroll vertically over cards 200×60
/// each: six on the left, which scrolls by up to 60, and one on the right.
const Board = struct {
    columns: [2][8]u8 = .{ .{ 1, 2, 3, 4, 5, 6, 0, 0 }, .{ 7, 0, 0, 0, 0, 0, 0, 0 } },
    counts: [2]usize = .{ 6, 1 },
    /// Cards start dragging only by `startDrag` after a long press.
    lift_on_long_press: bool = false,
    /// `startDrag` once per drag rather than every frame.
    payload_given: bool = false,
    give_payload_once: bool = false,
    /// A dragged card leaves its column until it is dropped.
    hide_dragged: bool = false,
    moved: ?struct { card: Card, to: usize } = null,

    fn declare(board: *Board, ui: *Ui) void {
        ui.open(.{ .layout = .{ .direction = .left_to_right, .child_gap = 50 } });
        for (0..2) |column| {
            ui.open(.{ .id = columnId(column), .scroll = .{}, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(200), .height = .fixed(300) } } });
            for (board.columns[column][0..board.counts[column]]) |number| {
                const card = cardId(number);
                const drag = ui.dragging(card);
                if (board.lift_on_long_press and ui.contextRequested(card)) ui.startDrag(card, Card{ .number = number });
                if (drag != null and !(board.give_payload_once and board.payload_given)) {
                    ui.startDrag(card, Card{ .number = number });
                    board.payload_given = true;
                }
                if (drag != null and board.hide_dragged) continue;
                const gestures: zui.Gestures = if (board.lift_on_long_press) .{ .long_press = true } else .{ .drag = true };
                ui.box(.{ .id = card, .gestures = gestures, .layout = fixed(200, 60) });
            }
            ui.close();
            if (ui.dropped(columnId(column), Card)) |card| board.moved = .{ .card = card, .to = column };
        }
        ui.close();
        if (board.moved) |moved| board.move(moved.card.number, moved.to);
    }

    fn move(board: *Board, number: u8, to: usize) void {
        for (0..2) |column| {
            const cards = board.columns[column][0..board.counts[column]];
            const index = std.mem.indexOfScalar(u8, cards, number) orelse continue;
            std.mem.copyForwards(u8, board.columns[column][index .. board.counts[column] - 1], board.columns[column][index + 1 .. board.counts[column]]);
            board.counts[column] -= 1;
        }
        board.columns[to][board.counts[to]] = number;
        board.counts[to] += 1;
    }

    fn cardsIn(board: *const Board, index: usize) []const u8 {
        return board.columns[index][0..board.counts[index]];
    }
};

fn frame(harness: *Harness, board: *Board, events: []const zui.Event) !*Ui {
    board.moved = null;
    const ui = harness.beginEvents(events);
    board.declare(ui);
    _ = try harness.end();
    return ui;
}

fn down(pointer: zui.Pointer) zui.Event {
    return .{ .pointer_down = .{ .pointer = pointer } };
}

fn move(pointer: zui.Pointer) zui.Event {
    return .{ .pointer_move = .{ .pointer = pointer } };
}

fn up(pointer: zui.Pointer) zui.Event {
    return .{ .pointer_up = .{ .pointer = pointer } };
}

const finger = support.touch;

test "a card dragged sideways out of a list that scrolls by touch drops on the other list" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    var board: Board = .{};

    _ = try frame(&harness, &board, &.{});
    var ui = try frame(&harness, &board, &.{ down(finger(1, .{ 100, 90 })), move(finger(1, .{ 300, 100 })) });
    try testing.expectEqual(zui.Drag{ .pointer = @enumFromInt(1), .position = .{ 300, 100 }, .translation = .{ 200, 10 } }, ui.dragging(cardId(2)).?);
    try testing.expectEqual(@as(?zui.Drag, null), ui.dragging(cardId(1)));
    try testing.expect(!ui.pressed(cardId(1)));
    try testing.expectEqual([2]f32{ 0, 0 }, ui.scrollOffset(columnId(0)));

    ui = try frame(&harness, &board, &.{move(finger(1, .{ 320, 20 }))});
    try testing.expectEqual(Card{ .number = 2 }, ui.draggedOver(columnId(1), Card).?);
    try testing.expectEqual(Card{ .number = 2 }, ui.draggedOver(cardId(7), Card).?);
    try testing.expectEqual(@as(?Card, null), ui.draggedOver(columnId(0), Card));
    try testing.expectEqual(@as(?Note, null), ui.draggedOver(columnId(1), Note));

    ui = try frame(&harness, &board, &.{up(finger(1, .{ 320, 20 }))});
    try testing.expect(!ui.clicked(cardId(2)));
    try testing.expectEqual(@as(?zui.Drag, null), ui.dragging(cardId(2)));
    try testing.expectEqualSlices(u8, &.{ 1, 3, 4, 5, 6 }, board.cardsIn(0));
    try testing.expectEqualSlices(u8, &.{ 7, 2 }, board.cardsIn(1));
}

test "a vertical drag on a card scrolls its list, and a tap on one clicks it" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    var board: Board = .{};

    _ = try frame(&harness, &board, &.{});
    var ui = try frame(&harness, &board, &.{ down(finger(1, .{ 100, 100 })), move(finger(1, .{ 100, 60 })) });
    try testing.expectEqual(@as(?zui.Drag, null), ui.dragging(cardId(2)));
    try testing.expectEqual([2]f32{ 0, 40 }, ui.scrollOffset(columnId(0)));
    _ = try frame(&harness, &board, &.{up(finger(1, .{ 100, 60 }))});

    ui = try frame(&harness, &board, &.{ down(finger(1, .{ 300, 30 })), up(finger(1, .{ 300, 30 })) });
    try testing.expect(ui.clicked(cardId(7)));
    try testing.expectEqualSlices(u8, &.{7}, board.cardsIn(1));
}

test "with the mouse, which scrolls a list by its wheel, a card drags on either axis" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    var board: Board = .{};

    _ = try frame(&harness, &board, &.{});
    var ui = try frame(&harness, &board, &.{ down(support.mouse(.{ 100, 100 })), move(support.mouse(.{ 100, 150 })) });
    try testing.expectEqual([2]f32{ 0, 50 }, ui.dragging(cardId(2)).?.translation);
    try testing.expectEqual([2]f32{ 0, 0 }, ui.scrollOffset(columnId(0)));
    _ = try frame(&harness, &board, &.{move(support.mouse(.{ 300, 30 }))});
    _ = try frame(&harness, &board, &.{up(support.mouse(.{ 300, 30 }))});
    try testing.expectEqualSlices(u8, &.{ 7, 2 }, board.cardsIn(1));
}

test "a drop yields its payload to a target that asks for its type, and null to any other" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    var board: Board = .{};

    _ = try frame(&harness, &board, &.{});
    _ = try frame(&harness, &board, &.{ down(finger(1, .{ 100, 30 })), move(finger(1, .{ 300, 40 })) });
    const ui = harness.beginEvents(&.{up(finger(1, .{ 300, 40 }))});
    try testing.expectEqual(@as(?Note, null), ui.dropped(columnId(1), Note));
    try testing.expectEqual(@as(?u8, null), ui.dropped(columnId(1), u8));
    try testing.expectEqual(@as(?Card, null), ui.dropped(columnId(0), Card));
    try testing.expectEqual(Card{ .number = 1 }, ui.dropped(cardId(7), Card).?);
    try testing.expectEqual(Card{ .number = 1 }, ui.dropped(columnId(1), Card).?);
    board.declare(ui);
    _ = try harness.end();
}

test "a drag released in the record that started it drops nothing, and neither does a cancelled one" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    var board: Board = .{};

    _ = try frame(&harness, &board, &.{});
    _ = try frame(&harness, &board, &.{ down(finger(1, .{ 100, 30 })), move(finger(1, .{ 300, 40 })), up(finger(1, .{ 300, 40 })) });
    try testing.expectEqual(@as(usize, 1), board.counts[1]);

    var ui = try frame(&harness, &board, &.{ down(finger(1, .{ 100, 30 })), move(finger(1, .{ 300, 40 })) });
    try testing.expect(ui.dragging(cardId(1)) != null);
    ui = try frame(&harness, &board, &.{.{ .pointer_cancel = @enumFromInt(1) }});
    try testing.expectEqual(@as(?zui.Drag, null), ui.dragging(cardId(1)));
    try testing.expectEqual(@as(usize, 1), board.counts[1]);
}

test "a payload given once outlives frames in which its source is not declared" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    var board: Board = .{ .give_payload_once = true, .hide_dragged = true };

    _ = try frame(&harness, &board, &.{});
    _ = try frame(&harness, &board, &.{ down(finger(1, .{ 100, 30 })), move(finger(1, .{ 300, 40 })) });
    try testing.expectEqual(@as(?zui.Rect, null), harness.ui.rectOf(cardId(1)));
    for (0..10) |_| _ = try frame(&harness, &board, &.{});
    _ = try frame(&harness, &board, &.{up(finger(1, .{ 300, 40 }))});
    try testing.expectEqualSlices(u8, &.{ 2, 3, 4, 5, 6 }, board.cardsIn(0));
    try testing.expectEqualSlices(u8, &.{ 7, 1 }, board.cardsIn(1));
}

test "after a long press, startDrag lifts a card that then drags along its list" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    var board: Board = .{ .lift_on_long_press = true };

    _ = try frame(&harness, &board, &.{});
    var ui = try frame(&harness, &board, &.{down(finger(1, .{ 100, 30 }))});
    var frames: usize = 0;
    while (ui.dragging(cardId(1)) == null) : (frames += 1) {
        try testing.expect(frames < 40);
        ui = try frame(&harness, &board, &.{});
    }
    ui = try frame(&harness, &board, &.{move(finger(1, .{ 100, 200 }))});
    try testing.expectEqual([2]f32{ 0, 170 }, ui.dragging(cardId(1)).?.translation);
    try testing.expectEqual([2]f32{ 0, 0 }, ui.scrollOffset(columnId(0)));
    _ = try frame(&harness, &board, &.{move(finger(1, .{ 300, 30 }))});
    _ = try frame(&harness, &board, &.{up(finger(1, .{ 300, 30 }))});
    try testing.expectEqualSlices(u8, &.{ 7, 1 }, board.cardsIn(1));
}

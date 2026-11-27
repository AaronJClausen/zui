const std = @import("std");
const zui = @import("zui");
const cells = @import("cells.zig");
const Cell = cells.Cell;
const CellBuffer = cells.CellBuffer;

/// A named part of the frame, in layout units, which a differing cell is
/// named by when its center lies inside it.
pub const SnapshotRegion = struct {
    name: []const u8,
    rect: zui.Rect,
};

/// Writes `buffer` as text a reviewer reads and a check compares exactly:
/// its size, its glyphs framed in `|` a row a line, then each row's
/// backgrounds and the foregrounds of its glyphs as runs of columns, both
/// ends included. A blank cell's foreground is not drawn, so a foreground
/// run spans the blanks between glyphs of its color:
///
/// ```text
/// cells 4x2
/// glyphs
/// |ok  |
/// |┌──┐|
/// backgrounds
/// 00 0-1 #24272a 2-3 #f5f8fe
/// 01 0-3 #f5f8fe
/// foregrounds
/// 00 0-1 #ffffff
/// 01 0-3 #6b7280
/// ```
pub fn writeSnapshot(buffer: *const CellBuffer, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("cells {d}x{d}\nglyphs\n", .{ buffer.columns, buffer.rows });
    for (0..buffer.rows) |row| {
        try writer.writeByte('|');
        for (rowOf(buffer, row)) |cell| {
            var bytes: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(cell.codepoint, &bytes) catch {
                try writer.writeByte('?');
                continue;
            };
            try writer.writeAll(bytes[0..length]);
        }
        try writer.writeAll("|\n");
    }
    try writer.writeAll("backgrounds\n");
    for (0..buffer.rows) |row| {
        try writer.print("{d:0>2}", .{row});
        const row_cells = rowOf(buffer, row);
        var run_start: usize = 0;
        for (1..row_cells.len + 1) |column| {
            if (column < row_cells.len and row_cells[column].background.eql(row_cells[run_start].background)) continue;
            try writeRun(writer, run_start, column - 1, row_cells[run_start].background);
            run_start = column;
        }
        try writer.writeByte('\n');
    }
    try writer.writeAll("foregrounds\n");
    for (0..buffer.rows) |row| {
        try writer.print("{d:0>2}", .{row});
        var open_run: ?struct { start: usize, last_glyph: usize, color: zui.Color } = null;
        for (rowOf(buffer, row), 0..) |cell, column| {
            if (cell.codepoint == ' ') continue;
            if (open_run) |*run| {
                if (run.color.eql(cell.foreground)) {
                    run.last_glyph = column;
                    continue;
                }
                try writeRun(writer, run.start, run.last_glyph, run.color);
            }
            open_run = .{ .start = column, .last_glyph = column, .color = cell.foreground };
        }
        if (open_run) |run| try writeRun(writer, run.start, run.last_glyph, run.color);
        try writer.writeByte('\n');
    }
}

fn rowOf(buffer: *const CellBuffer, row: usize) []const Cell {
    return buffer.cells[row * buffer.columns ..][0..buffer.columns];
}

fn writeRun(writer: *std.Io.Writer, first_column: usize, last_column: usize, color: zui.Color) !void {
    try writer.print(" {d}-{d} ", .{ first_column, last_column });
    try writeColor(writer, color);
}

fn writeColor(writer: *std.Io.Writer, color: zui.Color) !void {
    try writer.print("#{x:0>2}{x:0>2}{x:0>2}", .{ color.r, color.g, color.b });
    if (color.a != 255) try writer.print("{x:0>2}", .{color.a});
}

pub const ReadSnapshotError = error{ MalformedSnapshot, SnapshotSizeDiffers };

/// Fills `buffer`, already sized, from `writeSnapshot`'s `text`. A blank
/// cell's foreground, which the text does not hold, becomes its background.
pub fn readSnapshot(buffer: *CellBuffer, text: []const u8) ReadSnapshotError!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var size_words = std.mem.tokenizeAny(u8, lines.next() orelse return error.MalformedSnapshot, " x");
    if (!std.mem.eql(u8, size_words.next() orelse "", "cells")) return error.MalformedSnapshot;
    const columns = parseNumber(size_words.next()) orelse return error.MalformedSnapshot;
    const rows = parseNumber(size_words.next()) orelse return error.MalformedSnapshot;
    if (columns != buffer.columns or rows != buffer.rows) return error.SnapshotSizeDiffers;

    try expectLine(&lines, "glyphs");
    for (0..buffer.rows) |row| {
        const line = lines.next() orelse return error.MalformedSnapshot;
        if (line.len < 2 or line[0] != '|' or line[line.len - 1] != '|') return error.MalformedSnapshot;
        var codepoints = (std.unicode.Utf8View.init(line[1 .. line.len - 1]) catch return error.MalformedSnapshot).iterator();
        for (rowCells(buffer, row)) |*cell| cell.codepoint = codepoints.nextCodepoint() orelse return error.MalformedSnapshot;
        if (codepoints.nextCodepoint() != null) return error.MalformedSnapshot;
    }

    try expectLine(&lines, "backgrounds");
    for (0..buffer.rows) |row| {
        const row_cells = rowCells(buffer, row);
        var covered: usize = 0;
        var runs = try runsOfRow(&lines, row);
        while (try runs.next()) |run| {
            if (run.first_column != covered or run.last_column >= row_cells.len) return error.MalformedSnapshot;
            for (row_cells[run.first_column .. run.last_column + 1]) |*cell| cell.background = run.color;
            covered = run.last_column + 1;
        }
        if (covered != row_cells.len) return error.MalformedSnapshot;
        for (row_cells) |*cell| cell.foreground = cell.background;
    }

    try expectLine(&lines, "foregrounds");
    for (0..buffer.rows) |row| {
        const row_cells = rowCells(buffer, row);
        var covered: usize = 0;
        var runs = try runsOfRow(&lines, row);
        while (try runs.next()) |run| {
            if (run.first_column < covered or run.last_column < run.first_column or run.last_column >= row_cells.len) return error.MalformedSnapshot;
            for (row_cells[run.first_column .. run.last_column + 1]) |*cell| {
                if (cell.codepoint != ' ') cell.foreground = run.color;
            }
            covered = run.last_column + 1;
        }
    }
    const rest = lines.rest();
    if (rest.len != 0) return error.MalformedSnapshot;
}

fn rowCells(buffer: *CellBuffer, row: usize) []Cell {
    return buffer.cells[row * buffer.columns ..][0..buffer.columns];
}

fn expectLine(lines: *std.mem.SplitIterator(u8, .scalar), expected: []const u8) ReadSnapshotError!void {
    if (!std.mem.eql(u8, lines.next() orelse "", expected)) return error.MalformedSnapshot;
}

fn parseNumber(word: ?[]const u8) ?usize {
    return std.fmt.parseInt(usize, word orelse return null, 10) catch null;
}

const ColorRun = struct { first_column: usize, last_column: usize, color: zui.Color };

const RowRuns = struct {
    words: std.mem.TokenIterator(u8, .scalar),

    fn next(runs: *RowRuns) ReadSnapshotError!?ColorRun {
        const range = runs.words.next() orelse return null;
        const color = runs.words.next() orelse return error.MalformedSnapshot;
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse return error.MalformedSnapshot;
        return .{
            .first_column = parseNumber(range[0..dash]) orelse return error.MalformedSnapshot,
            .last_column = parseNumber(range[dash + 1 ..]) orelse return error.MalformedSnapshot,
            .color = parseColor(color) orelse return error.MalformedSnapshot,
        };
    }
};

fn runsOfRow(lines: *std.mem.SplitIterator(u8, .scalar), row: usize) ReadSnapshotError!RowRuns {
    var words = std.mem.tokenizeScalar(u8, lines.next() orelse return error.MalformedSnapshot, ' ');
    if (parseNumber(words.next()) != row) return error.MalformedSnapshot;
    return .{ .words = words };
}

fn parseColor(word: []const u8) ?zui.Color {
    if (word.len != 7 and word.len != 9 or word[0] != '#') return null;
    const hex = std.fmt.parseInt(u32, word[1..], 16) catch return null;
    return if (word.len == 7) .rgb(@intCast(hex)) else .rgba(hex);
}

/// Whether `expected` and `actual` look the same on a terminal: the same
/// glyph and background, and the same foreground unless the glyph is blank.
pub fn cellsLookAlike(expected: Cell, actual: Cell) bool {
    if (expected.codepoint != actual.codepoint or !expected.background.eql(actual.background)) return false;
    return expected.codepoint == ' ' or expected.foreground.eql(actual.foreground);
}

/// Writes each of the first `shown_limit` cells that look different in
/// `expected` and `actual`, buffers of one size, with the region of
/// `regions` that holds its center, `cell_size` units a cell, and how many
/// differ in all, which it returns. Writes nothing when none differ:
///
/// ```text
///   column 9, row 3, in `swatches`: expected 'a' #ffffff on #3b82f6, actual 'a' #ffffff on #2563eb
///   ...and 4 more
/// ```
pub fn writeSnapshotDifferences(
    writer: *std.Io.Writer,
    expected: *const CellBuffer,
    actual: *const CellBuffer,
    cell_size: [2]f32,
    regions: []const SnapshotRegion,
    shown_limit: usize,
) std.Io.Writer.Error!usize {
    std.debug.assert(expected.columns == actual.columns and expected.rows == actual.rows);
    var differing: usize = 0;
    for (expected.cells, actual.cells, 0..) |expected_cell, actual_cell, index| {
        if (cellsLookAlike(expected_cell, actual_cell)) continue;
        differing += 1;
        if (differing > shown_limit) continue;
        const column = index % expected.columns;
        const row = index / expected.columns;
        try writer.print("  column {d}, row {d}, in ", .{ column, row });
        if (regionHolding(regions, cell_size, column, row)) |region| {
            try writer.print("`{s}`", .{region.name});
        } else {
            try writer.writeAll("no region");
        }
        try writer.writeAll(": expected ");
        try writeCell(writer, expected_cell);
        try writer.writeAll(", actual ");
        try writeCell(writer, actual_cell);
        try writer.writeByte('\n');
    }
    if (differing > shown_limit) try writer.print("  ...and {d} more\n", .{differing - shown_limit});
    return differing;
}

fn regionHolding(regions: []const SnapshotRegion, cell_size: [2]f32, column: usize, row: usize) ?SnapshotRegion {
    const center_x = (@as(f32, @floatFromInt(column)) + 0.5) * cell_size[0];
    const center_y = (@as(f32, @floatFromInt(row)) + 0.5) * cell_size[1];
    for (regions) |region| {
        const rect = region.rect;
        if (center_x >= rect.x and center_x < rect.x + rect.width and center_y >= rect.y and center_y < rect.y + rect.height) return region;
    }
    return null;
}

fn writeCell(writer: *std.Io.Writer, cell: Cell) !void {
    var bytes: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(cell.codepoint, &bytes) catch 0;
    try writer.print("'{s}' ", .{if (length == 0) "?" else bytes[0..length]});
    if (cell.codepoint == ' ') {
        try writer.writeAll("on ");
    } else {
        try writeColor(writer, cell.foreground);
        try writer.writeAll(" on ");
    }
    try writeColor(writer, cell.background);
}

const testing = std.testing;

fn testBuffer(columns: u16, rows: u16) !CellBuffer {
    var buffer: CellBuffer = .{};
    try buffer.resize(testing.allocator, columns, rows);
    buffer.fill(.{ .foreground = .rgb(0x102030), .background = .rgb(0x102030) });
    return buffer;
}

fn putText(buffer: *CellBuffer, column: i32, row: i32, text: []const u8, foreground: zui.Color) void {
    var codepoints = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
    var at = column;
    while (codepoints.nextCodepoint()) |codepoint| : (at += 1) {
        buffer.at(at, row).codepoint = codepoint;
        buffer.at(at, row).foreground = foreground;
    }
}

test "a snapshot holds the glyphs, the backgrounds and the foregrounds of the glyphs" {
    var buffer = try testBuffer(6, 2);
    defer buffer.deinit(testing.allocator);
    putText(&buffer, 0, 0, "ok ok", .white);
    putText(&buffer, 0, 1, "┌──┐", .rgba(0xff000080));
    for (3..6) |column| buffer.at(@intCast(column), 1).background = .white;

    var written: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&written);
    try writeSnapshot(&buffer, &writer);
    try testing.expectEqualStrings(
        \\cells 6x2
        \\glyphs
        \\|ok ok |
        \\|┌──┐  |
        \\backgrounds
        \\00 0-5 #102030
        \\01 0-2 #102030 3-5 #ffffff
        \\foregrounds
        \\00 0-4 #ffffff
        \\01 0-3 #ff000080
        \\
    , writer.buffered());
}

test "a snapshot reads back as the cells it was written from" {
    var buffer = try testBuffer(5, 2);
    defer buffer.deinit(testing.allocator);
    putText(&buffer, 1, 0, "a|b", .white);
    buffer.at(2, 0).foreground = .rgb(0x00ff00);
    buffer.at(4, 1).background = .rgb(0xabcdef);
    var written: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&written);
    try writeSnapshot(&buffer, &writer);

    var read = try testBuffer(5, 2);
    defer read.deinit(testing.allocator);
    read.fill(.{});
    try readSnapshot(&read, writer.buffered());
    for (buffer.cells, read.cells) |expected, actual| try testing.expect(cellsLookAlike(expected, actual));

    var too_small = try testBuffer(4, 2);
    defer too_small.deinit(testing.allocator);
    try testing.expectError(error.SnapshotSizeDiffers, readSnapshot(&too_small, writer.buffered()));
    try testing.expectError(error.MalformedSnapshot, readSnapshot(&read, writer.buffered()[0 .. writer.buffered().len - 10]));
}

test "a cell that looks different is named with its region, and a blank's foreground is not compared" {
    var expected = try testBuffer(4, 2);
    defer expected.deinit(testing.allocator);
    var actual = try testBuffer(4, 2);
    defer actual.deinit(testing.allocator);
    actual.at(0, 0).foreground = .white;
    actual.at(3, 1).background = .white;
    putText(&expected, 1, 0, "x", .white);
    putText(&actual, 1, 0, "x", .black);

    const regions = [_]SnapshotRegion{
        .{ .name = "top", .rect = .{ .width = 32, .height = 16 } },
        .{ .name = "bottom_right", .rect = .{ .x = 16, .y = 16, .width = 16, .height = 16 } },
    };
    var written: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&written);
    try testing.expectEqual(@as(usize, 2), try writeSnapshotDifferences(&writer, &expected, &actual, .{ 8, 16 }, &regions, 1));
    try testing.expectEqualStrings(
        \\  column 1, row 0, in `top`: expected 'x' #ffffff on #102030, actual 'x' #000000 on #102030
        \\  ...and 1 more
        \\
    , writer.buffered());

    writer = .fixed(&written);
    _ = try writeSnapshotDifferences(&writer, &expected, &actual, .{ 8, 16 }, regions[0..0], 2);
    try testing.expect(std.mem.endsWith(u8, writer.buffered(), "  column 3, row 1, in no region: expected ' ' on #102030, actual ' ' on #ffffff\n"));
}

const std = @import("std");
const zui = @import("zui");

/// Writes one line per render command, in paint order, for golden-file
/// tests. Elements are named only when their id is a field of `names`
/// (a `zui.ids(...)` set, or any struct of `zui.Id` fields), so snapshots
/// don't change when unrelated internal ids do.
///
/// Every length is written to the nearest 1/64 unit, so the text is the
/// same in every optimize mode and on every target.
///
/// ```text
/// rectangle id=toolbar x=0 y=0 w=800 h=40 color=#202020
/// text x=12 y=12 w=32 h=16 size=16 color=#e8e8f0 "Save"
/// clip_begin x=0 y=40 w=200 h=560
/// clip_end
/// ```
pub fn snapshot(writer: *std.Io.Writer, commands: anytype, names: anytype) std.Io.Writer.Error!void {
    for (commands) |command| {
        try writer.writeAll(@tagName(command.payload));
        if (nameOf(names, command.id)) |name| try writer.print(" id={s}", .{name});
        if (command.z != 0) try writer.print(" z={d}", .{command.z});
        switch (command.payload) {
            .clip_begin => |clip| try writeRect(writer, clip),
            .clip_end => {},
            inline else => |_, kind| if (comptime !std.mem.eql(u8, @tagName(kind), "transform_end")) try writeRect(writer, command.bounds),
        }
        switch (command.payload) {
            .rectangle => |rectangle| {
                try writeColor(writer, rectangle.color);
                try writeCorners(writer, rectangle);
            },
            .border => |border| {
                try writeColor(writer, border.color);
                try writeEdges(writer, border.widths);
                try writeCorners(writer, border);
            },
            .text => |text| {
                if (text.line != 0) try writer.print(" line={d}", .{text.line});
                try writeFont(writer, text.style.font);
                try writer.print(" size={d}", .{units(text.style.size)});
                if (text.style.letter_spacing != 0) try writer.print(" spacing={d}", .{units(text.style.letter_spacing)});
                try writeColor(writer, text.style.color);
                try writer.print(" \"{s}\"", .{text.content});
            },
            inline else => |payload, kind| if (comptime std.mem.eql(u8, @tagName(kind), "image")) {
                try writeHandle(writer, payload.handle);
                if (!payload.tint.eql(.white)) try writer.print(" tint=#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ payload.tint.r, payload.tint.g, payload.tint.b, payload.tint.a });
                try writeCorners(writer, payload);
            } else if (comptime std.mem.eql(u8, @tagName(kind), "gradient")) {
                try writeNamedColor(writer, "from", payload.from);
                try writeNamedColor(writer, "to", payload.to);
                if (payload.angle != 0) try writer.print(" angle={d}", .{units(payload.angle)});
                try writeCorners(writer, payload);
            } else if (comptime std.mem.eql(u8, @tagName(kind), "shadow")) {
                try writeColor(writer, payload.color);
                if (payload.offset[0] != 0 or payload.offset[1] != 0) try writer.print(" offset={d},{d}", .{ units(payload.offset[0]), units(payload.offset[1]) });
                if (payload.blur != 0) try writer.print(" blur={d}", .{units(payload.blur)});
                if (payload.spread != 0) try writer.print(" spread={d}", .{units(payload.spread)});
                try writeCorners(writer, payload);
            } else if (comptime std.mem.eql(u8, @tagName(kind), "backdrop_blur")) {
                try writer.print(" blur={d}", .{units(payload.radius)});
                try writeNamedColor(writer, "tint", payload.tint);
                try writeCorners(writer, payload);
            } else if (comptime std.mem.eql(u8, @tagName(kind), "material")) {
                try writeHandle(writer, payload.handle);
                try writeNamedColor(writer, "fallback", payload.fallback);
                try writeCorners(writer, payload);
            } else if (comptime std.mem.eql(u8, @tagName(kind), "transform_begin")) {
                if (payload.translation[0] != 0 or payload.translation[1] != 0) try writer.print(" translate={d},{d}", .{ units(payload.translation[0]), units(payload.translation[1]) });
                if (payload.scale[0] != 1 or payload.scale[1] != 1) try writer.print(" scale={d},{d}", .{ units(payload.scale[0]), units(payload.scale[1]) });
                if (payload.rotation != 0) try writer.print(" rotate={d}", .{units(payload.rotation)});
                if (payload.origin[0] != 0.5 or payload.origin[1] != 0.5) try writer.print(" origin={d},{d}", .{ units(payload.origin[0]), units(payload.origin[1]) });
            },
        }
        try writer.writeByte('\n');
    }
}

/// Compares `snapshot(commands, names)` with `expected`, printing both on
/// a mismatch.
pub fn expectSnapshot(commands: anytype, names: anytype, expected: []const u8) !void {
    var actual: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer actual.deinit();
    try snapshot(&actual.writer, commands, names);
    try std.testing.expectEqualStrings(expected, actual.written());
}

fn nameOf(names: anytype, hash: u64) ?[]const u8 {
    inline for (@typeInfo(@TypeOf(names)).@"struct".fields) |field| {
        if (field.type != zui.Id) @compileError("zui_testing: snapshot names must be zui.Id fields; ." ++ field.name ++ " is " ++ @typeName(field.type));
        if (@field(names, field.name).hash == hash) return field.name;
    }
    return null;
}

fn writeRect(writer: *std.Io.Writer, rect: zui.Rect) !void {
    try writer.print(" x={d} y={d} w={d} h={d}", .{ units(rect.x), units(rect.y), units(rect.width), units(rect.height) });
}

fn writeColor(writer: *std.Io.Writer, color: zui.Color) !void {
    try writeNamedColor(writer, "color", color);
}

fn writeNamedColor(writer: *std.Io.Writer, name: []const u8, color: zui.Color) !void {
    try writer.print(" {s}=#{x:0>2}{x:0>2}{x:0>2}", .{ name, color.r, color.g, color.b });
    if (color.a != 255) try writer.print("{x:0>2}", .{color.a});
}

fn writeCorners(writer: *std.Io.Writer, payload: anytype) !void {
    const shape = zui.cornerShapeOf(payload);
    if (shape != .round) try writer.print(" shape={t}", .{shape});
    const corners = payload.corner_radius;
    if (std.meta.eql(corners, zui.CornerRadius.zero)) return;
    if (std.meta.eql(corners, zui.CornerRadius.all(corners.top_left))) return writer.print(" radius={d}", .{units(corners.top_left)});
    try writer.print(" radius={d},{d},{d},{d}", .{ units(corners.top_left), units(corners.top_right), units(corners.bottom_left), units(corners.bottom_right) });
}

fn writeEdges(writer: *std.Io.Writer, edges: zui.Edges) !void {
    if (std.meta.eql(edges, zui.Edges.all(edges.left))) return writer.print(" widths={d}", .{units(edges.left)});
    try writer.print(" widths={d},{d},{d},{d}", .{ units(edges.left), units(edges.right), units(edges.top), units(edges.bottom) });
}

fn writeFont(writer: *std.Io.Writer, font: anytype) !void {
    switch (@typeInfo(@TypeOf(font))) {
        .int => if (font != 0) try writer.print(" font={d}", .{font}),
        .@"enum" => if (@intFromEnum(font) != 0) try writer.print(" font={t}", .{font}),
        else => comptime unreachable,
    }
}

/// Only integer and enum handles are written; pointers would make
/// snapshots differ from run to run.
fn writeHandle(writer: *std.Io.Writer, handle: anytype) !void {
    switch (@typeInfo(@TypeOf(handle))) {
        .int => try writer.print(" handle={d}", .{handle}),
        .@"enum" => try writer.print(" handle={t}", .{handle}),
        else => {},
    }
}

/// How a frame's text was laid out, as a font system's placement has it:
/// on the grid of physical pixels, or one glyph a cell of this size.
pub const SnapshotPlacement = union(enum) {
    pixel_grid,
    cells: [2]f32,

    /// `placement` as a snapshot writes it: any union with a `pixel_grid`
    /// case and a `cells: [2]f32` case, such as `zui_glyphs.Placement`.
    ///
    /// ```zig
    /// const placement: zui_testing.SnapshotPlacement = .of(zui_glyphs.placementOf(Renderer));
    /// ```
    pub fn of(placement: anytype) SnapshotPlacement {
        const Placement = @TypeOf(placement);
        if (Placement == SnapshotPlacement) return placement;
        comptime if (!isPlacement(Placement)) @compileError("zui_testing: SnapshotPlacement.of takes a union with the cases `pixel_grid` and `cells: [2]f32`, as zui_glyphs.Placement has, got " ++ @typeName(Placement));
        return switch (placement) {
            .pixel_grid => .pixel_grid,
            .cells => |cell_size| .{ .cells = cell_size },
        };
    }

    fn isPlacement(comptime Placement: type) bool {
        const info = @typeInfo(Placement);
        if (info != .@"union" or info.@"union".tag_type == null or info.@"union".fields.len != 2) return false;
        if (!@hasField(Placement, "pixel_grid") or !@hasField(Placement, "cells")) return false;
        return @FieldType(Placement, "pixel_grid") == void and @FieldType(Placement, "cells") == [2]f32;
    }
};

/// What the glyphs a frame draws became when rasterized: how many there
/// are, and one hash of all their coverage, so a change of font or
/// rasterizer changes one line of a snapshot.
pub const GlyphCoverage = struct {
    glyph_count: u32,
    hash: u64,
};

/// What a frame snapshot says, above its commands, about what drew them.
pub const FrameSnapshotHeader = struct {
    placement: SnapshotPlacement,
    /// The font system's `zuiFingerprint`.
    fonts_fingerprint: u64,
    /// Null where glyphs are not rasterized, as in cells.
    glyph_coverage: ?GlyphCoverage,
};

/// Writes `frame` (a `Ui.Frame`) as text to compare exactly: a header of
/// its viewport, its pixels a unit, `header`'s placement, fonts'
/// fingerprint and glyph coverage, then `snapshot`'s line for each of its
/// commands, every length to the nearest 1/64 unit. Writes nothing but to
/// `writer`.
///
/// ```text
/// viewport 640x384, 1 pixels a unit
/// placement pixel_grid
/// fonts 3c9a0e1f5d7b2a64
/// glyphs 87, coverage 0d4f6a2b9c1e7385
/// rectangle id=card x=0 y=0 w=640 h=384 color=#f7f7fa
/// ```
///
/// ```zig
/// var written: std.Io.Writer.Allocating = .init(gpa);
/// defer written.deinit();
/// try zui_testing.writeFrameSnapshot(&written.writer, frame, names, .{
///     .placement = .of(zui_glyphs.placementOf(Renderer)),
///     .fonts_fingerprint = text.zuiFingerprint(),
///     .glyph_coverage = null,
/// });
/// try zui_testing.expectSnapshotMatches(@embedFile("rest.txt"), written.written(), &regions);
/// ```
pub fn writeFrameSnapshot(writer: *std.Io.Writer, frame: anytype, names: anytype, header: FrameSnapshotHeader) std.Io.Writer.Error!void {
    const params = frame.params;
    try writer.print("viewport {d}x{d}, {d} pixels a unit\n", .{ units(params.viewport[0]), units(params.viewport[1]), units(params.scale * params.zoom) });
    switch (header.placement) {
        .pixel_grid => try writer.writeAll("placement pixel_grid\n"),
        .cells => |cell_size| try writer.print("placement cells {d}x{d}\n", .{ units(cell_size[0]), units(cell_size[1]) }),
    }
    try writer.print("fonts {x:0>16}\n", .{header.fonts_fingerprint});
    if (header.glyph_coverage) |coverage| {
        try writer.print("glyphs {d}, coverage {x:0>16}\n", .{ coverage.glyph_count, coverage.hash });
    } else try writer.writeAll("glyphs not rasterized\n");
    try snapshot(writer, frame.commands(), names);
}

/// A part of a frame a snapshot's difference is named by.
pub const SnapshotRegion = struct {
    name: []const u8,
    rect: zui.Rect,
};

/// A line where two snapshots differ.
pub const SnapshotDifference = struct {
    /// From 1.
    line_number: usize,
    /// Null past the snapshot's last line.
    expected: ?[]const u8,
    actual: ?[]const u8,
    /// Where the actual line's command lies, or the expected line's when
    /// the actual line has no bounds.
    place: Place,

    pub const Place = union(enum) {
        /// The smallest region holding the command's bounds, or else the
        /// one holding their center.
        region: []const u8,
        outside_every_region,
        /// A header line, or a command without bounds such as `clip_end`.
        no_bounds,
    };

    pub fn format(difference: SnapshotDifference, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("line {d}, ", .{difference.line_number});
        switch (difference.place) {
            .region => |name| try writer.print("in the `{s}` region", .{name}),
            .outside_every_region => try writer.writeAll("outside every region"),
            .no_bounds => try writer.writeAll("without bounds"),
        }
        try writer.print(":\n  expected: {s}\n  actual:   {s}\n", .{ difference.expected orelse "(no line)", difference.actual orelse "(no line)" });
    }
};

/// The lines where two snapshots differ, line by line, from `next`.
pub const SnapshotDifferences = struct {
    expected_lines: std.mem.SplitIterator(u8, .scalar),
    actual_lines: std.mem.SplitIterator(u8, .scalar),
    regions: []const SnapshotRegion,
    line_number: usize = 0,

    pub fn next(self: *SnapshotDifferences) ?SnapshotDifference {
        while (true) {
            const expected = self.expected_lines.next();
            const actual = self.actual_lines.next();
            if (expected == null and actual == null) return null;
            self.line_number += 1;
            if (expected != null and actual != null and std.mem.eql(u8, expected.?, actual.?)) continue;
            return .{
                .line_number = self.line_number,
                .expected = expected,
                .actual = actual,
                .place = placeOf(self.regions, actual) orelse placeOf(self.regions, expected) orelse .no_bounds,
            };
        }
    }
};

/// Where `actual` differs from `expected`, each line named by the region
/// of `regions` that holds its command.
pub fn snapshotDifferences(expected: []const u8, actual: []const u8, regions: []const SnapshotRegion) SnapshotDifferences {
    return .{
        .expected_lines = std.mem.splitScalar(u8, expected, '\n'),
        .actual_lines = std.mem.splitScalar(u8, actual, '\n'),
        .regions = regions,
    };
}

/// The differences `expectSnapshotMatches` prints before it counts the rest.
pub const shown_differences = 4;

/// Fails when `actual` differs from `expected`, printing the first lines
/// that differ, each with the region of `regions` that holds it, and how
/// many differ in all.
pub fn expectSnapshotMatches(expected: []const u8, actual: []const u8, regions: []const SnapshotRegion) error{SnapshotDiffers}!void {
    var differences = snapshotDifferences(expected, actual, regions);
    const first = differences.next() orelse return;
    std.debug.print("zui_testing: the snapshot differs from {f}", .{first});
    var difference_count: usize = 1;
    while (differences.next()) |difference| : (difference_count += 1) {
        if (difference_count < shown_differences) std.debug.print("{f}", .{difference});
    }
    std.debug.print("{d} of its lines differ\n", .{difference_count});
    return error.SnapshotDiffers;
}

fn placeOf(regions: []const SnapshotRegion, line: ?[]const u8) ?SnapshotDifference.Place {
    const bounds = boundsOf(line orelse return null) orelse return null;
    var holding: ?SnapshotRegion = null;
    for (regions) |region| {
        if (!holds(region.rect, bounds)) continue;
        if (holding == null or area(region.rect) < area(holding.?.rect)) holding = region;
    }
    if (holding == null) for (regions) |region| {
        if (holdsPoint(region.rect, .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 })) {
            holding = region;
            break;
        }
    };
    return if (holding) |region| .{ .region = region.name } else .outside_every_region;
}

fn boundsOf(line: []const u8) ?zui.Rect {
    return .{
        .x = valueAfter(line, " x=") orelse return null,
        .y = valueAfter(line, " y=") orelse return null,
        .width = valueAfter(line, " w=") orelse return null,
        .height = valueAfter(line, " h=") orelse return null,
    };
}

fn valueAfter(line: []const u8, key: []const u8) ?f32 {
    const start = (std.mem.indexOf(u8, line, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, ' ') orelse line.len;
    return std.fmt.parseFloat(f32, line[start..end]) catch null;
}

fn holds(outer: zui.Rect, inner: zui.Rect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.width <= outer.x + outer.width and inner.y + inner.height <= outer.y + outer.height;
}

fn holdsPoint(rect: zui.Rect, point: [2]f32) bool {
    return point[0] >= rect.x and point[1] >= rect.y and point[0] < rect.x + rect.width and point[1] < rect.y + rect.height;
}

fn area(rect: zui.Rect) f32 {
    return rect.width * rect.height;
}

/// `value` to the nearest 1/64 unit, which every target and optimize mode
/// rounds alike, and never negative zero.
fn units(value: f32) f32 {
    return @round(value * 64) / 64 + 0.0;
}

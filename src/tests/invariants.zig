//! Randomized trees, checked against properties every layout must have.

const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const Ui = support.Ui;
const Frame = Ui.Frame;
const tolerance = 0.01;

const words = [_][]const u8{ "a", "zui", "layout", "immediate", "mode", "x", "frame", "comptime" };

const Generator = struct {
    random: std.Random,
    remaining: u32,
    /// Off, every element follows the environment's direction, so the whole
    /// tree mirrors with it.
    overrides_mirroring: bool = true,
    next_scroll_id: u32 = 0,
    text_buffer: [64]u8 = undefined,

    fn sizing(self: *Generator) zui.Sizing {
        return switch (self.random.uintLessThan(u8, 8)) {
            0, 1 => .fit,
            2 => .growWeighted(@floatFromInt(self.random.intRangeAtMost(u8, 1, 3))),
            3 => .{ .rule = .grow, .amount = 1, .max = @floatFromInt(self.random.intRangeAtMost(u16, 10, 300)) },
            4 => .fixed(@floatFromInt(self.random.intRangeAtMost(u16, 0, 250))),
            5 => .grow_equal,
            6 => .{
                .rule = .grow_from_min,
                .amount = @floatFromInt(self.random.uintAtMost(u8, 3)),
                .min = @floatFromInt(self.random.uintAtMost(u8, 40)),
                .max = if (self.random.boolean()) std.math.inf(f32) else @floatFromInt(self.random.intRangeAtMost(u16, 40, 300)),
            },
            else => .percent(@as(f32, @floatFromInt(self.random.intRangeAtMost(u8, 0, 100))) / 100),
        };
    }

    fn layout(self: *Generator) zui.Layout {
        return .{
            .direction = self.random.enumValue(zui.Direction),
            .sizing = .{ .width = self.sizing(), .height = self.sizing() },
            .padding = .all(@floatFromInt(self.random.uintLessThan(u8, 12))),
            .child_gap = @floatFromInt(self.random.uintLessThan(u8, 9)),
            .child_alignment = .{
                .x = self.random.enumValue(zui.Alignment),
                .y = self.random.enumValue(zui.Alignment),
            },
            .mirrored = if (self.overrides_mirroring and self.random.uintLessThan(u8, 8) == 0) self.random.enumValue(zui.Mirrored) else .inherit,
        };
    }

    /// Containers sometimes clip, scroll, float, or take part in interaction.
    fn container(self: *Generator) zui.Element {
        var element: zui.Element = .{
            .layout = self.layout(),
            .decoration = .{
                .background = if (self.random.boolean()) .rgb(0x202020) else null,
            },
            .interactive = self.random.uintLessThan(u8, 4) == 0,
        };
        switch (self.random.uintLessThan(u8, 10)) {
            0 => element.clip = self.random.enumValue(zui.Axes),
            1 => {
                element.id = .indexed("scroll", self.next_scroll_id);
                self.next_scroll_id += 1;
                element.scroll = .{ .horizontal = self.random.boolean(), .vertical = self.random.boolean() };
            },
            2 => element.floating = .{
                // A scroll container's id may name one declared earlier, later, inside, or none.
                .attach_to = switch (self.random.uintLessThan(u8, 3)) {
                    0 => .parent,
                    1 => .root,
                    else => .{ .element = .indexed("scroll", self.random.uintLessThan(u32, self.next_scroll_id + 4)) },
                },
                .anchor = self.random.enumValue(zui.AnchorPoint),
                .attach_point = self.random.enumValue(zui.AnchorPoint),
                .z = self.random.intRangeAtMost(i16, 1, 3),
                .capture = self.random.boolean(),
                .clip = self.random.enumValue(zui.FloatingClip),
            },
            else => {},
        }
        return element;
    }

    fn sentence(self: *Generator) []const u8 {
        var writer: std.Io.Writer = .fixed(&self.text_buffer);
        const word_count = self.random.uintLessThan(u8, 6);
        for (0..word_count) |index| {
            if (index != 0) writer.writeByte(if (self.random.uintLessThan(u8, 5) == 0) '\n' else ' ') catch break;
            writer.writeAll(words[self.random.uintLessThan(usize, words.len)]) catch break;
        }
        return writer.buffered();
    }

    fn children(self: *Generator, ui: *Ui, depth: u16) void {
        const child_count = self.random.uintLessThan(u8, 5);
        for (0..child_count) |_| {
            if (self.remaining == 0) return;
            self.remaining -= 1;
            switch (self.random.uintLessThan(u8, 4)) {
                0 => ui.text(self.sentence(), .{ .wrap = self.random.enumValue(zui.TextWrap) }),
                1 => ui.box(.{ .layout = self.layout(), .decoration = .{ .background = .rgb(0x404040) } }),
                else => if (depth + 1 < Ui.max_depth) {
                    ui.open(self.container());
                    if (self.random.uintLessThan(u8, 6) == 0) ui.wrapChildren();
                    self.children(ui, depth + 1);
                    ui.close();
                },
            }
        }
    }
};

fn checkInvariants(frame: *const Frame) !void {
    for (0..frame.element_count) |index| {
        const element: Ui.Index = @intCast(index);
        for (0..2) |a| {
            try std.testing.expect(std.math.isFinite(frame.size[element][a]));
            try std.testing.expect(std.math.isFinite(frame.position[element][a]));
            try std.testing.expect(frame.size[element][a] >= -tolerance);
        }
        try checkChildren(frame, element);
        if (frame.child_counts[element].all != 0) try checkParent(frame, element);
    }
    try checkCommands(frame);
}

/// Layers paint in nondecreasing z, and clip pairs balance within each layer.
fn checkCommands(frame: *const Frame) !void {
    var previous_z: i16 = std.math.minInt(i16);
    var clip_depth: i32 = 0;
    for (frame.commands()) |command| {
        if (command.z != previous_z) {
            try std.testing.expectEqual(@as(i32, 0), clip_depth);
            try std.testing.expect(command.z > previous_z);
            previous_z = command.z;
        }
        switch (command.payload) {
            .clip_begin => clip_depth += 1,
            .clip_end => clip_depth -= 1,
            else => {},
        }
        try std.testing.expect(clip_depth >= 0);
    }
    try std.testing.expectEqual(@as(i32, 0), clip_depth);
}

/// The child walk visits exactly the elements whose parent is `parent`, in
/// declaration order, and counts the same children declaration did.
fn checkChildren(frame: *const Frame, parent: Ui.Index) !void {
    var count: u32 = 0;
    var flow_count: u32 = 0;
    var previous: ?Ui.Index = null;
    var children = frame.children(parent);
    while (children.next()) |child| {
        try std.testing.expectEqual(parent, frame.parent[child]);
        if (previous) |earlier| try std.testing.expect(child > earlier);
        previous = child;
        count += 1;
        if (!frame.isFloating(child)) flow_count += 1;
    }
    try std.testing.expectEqual(@as(u32, frame.child_counts[parent].all), count);
    try std.testing.expectEqual(@as(u32, frame.child_counts[parent].in_flow), flow_count);
}

fn flowCount(frame: *const Frame, parent: Ui.Index) u32 {
    var count: u32 = 0;
    var children = frame.children(parent);
    while (children.next()) |child| {
        if (!frame.isFloating(child)) count += 1;
    }
    return count;
}

fn checkParent(frame: *const Frame, parent: Ui.Index) !void {
    if (frame.flags[parent].wraps) return checkWrappingRow(frame, parent);
    const parent_layout = frame.layoutOf(parent);
    const along = parent_layout.direction.axis();
    const a = @intFromEnum(along);
    const b = 1 - a;
    const content_along = @max(0, frame.size[parent][a] - parent_layout.padding.total(along));
    const content_across = @max(0, frame.size[parent][b] - parent_layout.padding.total(along.other()));
    const content_top = frame.position[parent][1] + parent_layout.padding.top;
    const content_left = frame.position[parent][0] + parent_layout.padding.left;
    const content_right = frame.position[parent][0] + frame.size[parent][0] - parent_layout.padding.left;
    const reversed = frame.flags[parent].reversed;

    const flow_count = flowCount(frame, parent);
    if (flow_count == 0) return;
    const scrolls_along = frame.flags[parent].scrolls(along);

    var used = parent_layout.child_gap * @as(f32, @floatFromInt(flow_count - 1));
    var children = frame.children(parent);
    while (children.next()) |child| {
        if (!frame.isFloating(child)) used += frame.size[child][a];
    }
    if (used <= content_along + tolerance) try checkGrowFromMinWeights(frame, parent, along);

    children = frame.children(parent);
    while (children.next()) |child| {
        if (frame.isFloating(child)) continue;
        const sizing = sizingAlong(frame, child, along);
        // Overflow is only allowed once every shrinkable child is at its
        // minimum, or along an axis that scrolls.
        if (used > content_along + tolerance and sizing.rule != .fixed and !scrolls_along) {
            try std.testing.expect(frame.size[child][a] <= frame.min_size[child][a] + tolerance);
        }
        // Free space is only left over once every growable child is at its max.
        if (used < content_along - tolerance and sizing.rule.grows() and sizing.amount > 0) {
            try std.testing.expect(frame.size[child][a] >= sizing.max - tolerance);
        }
        const across_sizing = sizingAlong(frame, child, along.other());
        if (across_sizing.rule.grows()) {
            const expected = @max(frame.min_size[child][b], std.math.clamp(content_across, across_sizing.min, across_sizing.max));
            try std.testing.expectApproxEqAbs(expected, frame.size[child][b], tolerance);
        }
        // Children start inside the parent's content box, at its right for
        // a reversed parent. These frames never scroll, so every offset is
        // zero.
        if (reversed) {
            try std.testing.expect(frame.position[child][0] + frame.size[child][0] <= content_right + tolerance);
        } else {
            try std.testing.expect(frame.position[child][0] >= content_left - tolerance);
        }
        try std.testing.expect(frame.position[child][1] >= content_top - tolerance);
    }
}

/// Each line fits the row unless it holds one child or the row scrolls,
/// leaves free space only once its growing children are at their max, and
/// lies below the line before it; every child starts inside the content box.
fn checkWrappingRow(frame: *const Frame, row: Ui.Index) !void {
    const row_layout = frame.layoutOf(row);
    const gap = row_layout.child_gap;
    const content_width = @max(0, frame.size[row][0] - row_layout.padding.total(.x));
    const content_left = frame.position[row][0] + row_layout.padding.left;
    const content_right = frame.position[row][0] + frame.size[row][0] - row_layout.padding.left;
    const content_top = frame.position[row][1] + row_layout.padding.top;
    const scrolls = frame.flags[row].scroll_x or frame.flags[row].scroll_y;

    var line_first: ?Ui.Index = null;
    var previous_line_bottom: f32 = -std.math.inf(f32);
    var children = frame.children(row);
    while (true) {
        const next = children.next();
        if (next) |child| if (frame.isFloating(child)) continue;
        if (next == null or frame.starts_line[next.?]) {
            if (line_first) |first| {
                var line_width = -gap;
                var line_count: u32 = 0;
                var line_top = std.math.inf(f32);
                var line_bottom = -std.math.inf(f32);
                var line = frame.children(row);
                line.next_child = first;
                line.end = next orelse frame.subtree_end[row];
                while (line.next()) |child| {
                    if (frame.isFloating(child)) continue;
                    line_width += frame.size[child][0] + gap;
                    line_count += 1;
                    line_top = @min(line_top, frame.position[child][1]);
                    line_bottom = @max(line_bottom, frame.position[child][1] + frame.size[child][1]);
                }
                if (line_count > 1 and !scrolls) try std.testing.expect(line_width <= content_width + tolerance);
                if (!scrolls) try std.testing.expect(line_top >= previous_line_bottom + gap - tolerance);
                line = frame.children(row);
                line.next_child = first;
                line.end = next orelse frame.subtree_end[row];
                while (line.next()) |child| {
                    if (frame.isFloating(child)) continue;
                    const sizing = frame.sizingOf(child, .x);
                    if (line_width < content_width - tolerance and sizing.rule.grows() and sizing.amount > 0) {
                        try std.testing.expect(frame.size[child][0] >= sizing.max - tolerance);
                    }
                    if (frame.flags[row].reversed) {
                        try std.testing.expect(frame.position[child][0] + frame.size[child][0] <= content_right + tolerance);
                    } else {
                        try std.testing.expect(frame.position[child][0] >= content_left - tolerance);
                    }
                    try std.testing.expect(frame.position[child][1] >= content_top - tolerance);
                }
                previous_line_bottom = line_bottom;
            }
            line_first = next;
        }
        if (next == null) break;
    }
}

/// `grow_from_min` siblings that are neither at their floor nor at their max
/// have grown from their `min` by the same share of their weights.
fn checkGrowFromMinWeights(frame: *const Frame, parent: Ui.Index, along: zui.Axis) !void {
    const a = @intFromEnum(along);
    var share: ?f32 = null;
    var children = frame.children(parent);
    while (children.next()) |child| {
        if (frame.isFloating(child)) continue;
        const sizing = sizingAlong(frame, child, along);
        if (sizing.rule != .grow_from_min or sizing.amount == 0) continue;
        const size = frame.size[child][a];
        try std.testing.expect(size >= frame.min_size[child][a] - tolerance);
        if (size <= frame.min_size[child][a] + tolerance or size >= sizing.max - tolerance) continue;
        const child_share = (size - sizing.min) / sizing.amount;
        if (share) |expected| {
            try std.testing.expectApproxEqAbs(expected, child_share, tolerance);
        } else share = child_share;
    }
}

fn buildRandomFrame(ui: *Ui, seed: u64, element_budget: u32) void {
    buildRandomFrameIn(ui, seed, element_budget, .left_to_right, true);
}

fn buildRandomFrameIn(ui: *Ui, seed: u64, element_budget: u32, direction: zui.ReadingDirection, overrides_mirroring: bool) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    var generator: Generator = .{ .random = prng.random(), .remaining = element_budget, .overrides_mirroring = overrides_mirroring };
    const environment = [_]zui.Event{.{ .environment = .{ .direction = direction } }};
    ui.beginFrame(&.{
        .params = .{ .now = .zero, .viewport = .{ @floatFromInt(generator.random.intRangeAtMost(u16, 1, 1200)), @floatFromInt(generator.random.intRangeAtMost(u16, 1, 900)) } },
        .events = &environment,
    });
    generator.children(ui, 1);
}

test "random trees satisfy the layout invariants" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    for (0..2000) |seed| {
        buildRandomFrame(&harness.ui, seed, @intCast(seed % 200 + 1));
        const frame = harness.ui.endFrame();
        checkInvariants(frame) catch |err| {
            std.debug.print("invariant violated for seed {d}\n", .{seed});
            return err;
        };
        harness.ui.release(frame);
    }
}

test "a random tree in a right-to-left environment is the left-to-right one reflected" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    var unmirrored: [Ui.max_elements]zui.Rect = undefined;
    for (0..500) |seed| {
        buildRandomFrameIn(&harness.ui, seed, @intCast(seed % 200 + 1), .left_to_right, false);
        const plain = harness.ui.endFrame();
        for (unmirrored[0..plain.element_count], 0..) |*rect, index| rect.* = rectAt(plain, index);
        const element_count = plain.element_count;
        harness.ui.release(plain);

        buildRandomFrameIn(&harness.ui, seed, @intCast(seed % 200 + 1), .right_to_left, false);
        const mirrored = harness.ui.endFrame();
        defer harness.ui.release(mirrored);
        try std.testing.expectEqual(element_count, mirrored.element_count);
        const width = mirrored.params.viewport[0];
        for (unmirrored[0..element_count], 0..) |rect, index| {
            errdefer std.debug.print("seed {d}, element {d}\n", .{ seed, index });
            const reflected = rectAt(mirrored, index);
            try std.testing.expectApproxEqAbs(width - rect.x - rect.width, reflected.x, tolerance);
            try std.testing.expectEqual(rect.y, reflected.y);
            try std.testing.expectEqual(rect.width, reflected.width);
            try std.testing.expectEqual(rect.height, reflected.height);
        }
    }
}

test "layout is deterministic" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    for (0..200) |seed| {
        var snapshots: [2][32 * 1024]u8 = undefined;
        var lengths: [2]usize = undefined;
        for (0..2) |attempt| {
            buildRandomFrame(&harness.ui, seed, 150);
            const frame = harness.ui.endFrame();
            lengths[attempt] = (try support.snapshot(frame, &snapshots[attempt])).len;
            harness.ui.release(frame);
        }
        try std.testing.expectEqualStrings(snapshots[0][0..lengths[0]], snapshots[1][0..lengths[1]]);
    }
}

fn rectAt(frame: *const Frame, index: usize) zui.Rect {
    return .{ .x = frame.position[index][0], .y = frame.position[index][1], .width = frame.size[index][0], .height = frame.size[index][1] };
}

fn sizingAlong(frame: *const Frame, child: Ui.Index, axis: zui.Axis) zui.Sizing {
    return switch (axis) {
        inline else => |comptime_axis| frame.sizingOf(child, comptime_axis),
    };
}

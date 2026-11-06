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
    next_scroll_id: u32 = 0,
    text_buffer: [64]u8 = undefined,

    fn sizing(self: *Generator) zui.Sizing {
        return switch (self.random.uintLessThan(u8, 6)) {
            0, 1 => .fit,
            2 => .growWeighted(@floatFromInt(self.random.intRangeAtMost(u8, 1, 3))),
            3 => .{ .rule = .grow, .amount = 1, .max = @floatFromInt(self.random.intRangeAtMost(u16, 10, 300)) },
            4 => .fixed(@floatFromInt(self.random.intRangeAtMost(u16, 0, 250))),
            else => .percent(@as(f32, @floatFromInt(self.random.intRangeAtMost(u8, 0, 100))) / 100),
        };
    }

    fn layout(self: *Generator) zui.Layout {
        return .{
            .direction = if (self.random.boolean()) .left_to_right else .top_to_bottom,
            .sizing = .{ .width = self.sizing(), .height = self.sizing() },
            .padding = .all(@floatFromInt(self.random.uintLessThan(u8, 12))),
            .child_gap = @floatFromInt(self.random.uintLessThan(u8, 9)),
            .child_alignment = .{
                .x = self.random.enumValue(zui.Alignment),
                .y = self.random.enumValue(zui.Alignment),
            },
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
                .attach_to = if (self.random.boolean()) .parent else .root,
                .anchor = self.random.enumValue(zui.AnchorPoint),
                .attach_point = self.random.enumValue(zui.AnchorPoint),
                .z = self.random.intRangeAtMost(i16, 1, 3),
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
        if (frame.child_count[element] != 0) try checkParent(frame, element);
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
    try std.testing.expectEqual(@as(u32, frame.child_count[parent]), count);
    try std.testing.expectEqual(@as(u32, frame.flow_child_count[parent]), flow_count);
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
    const parent_layout = frame.layoutOf(parent);
    const along = parent_layout.direction.axis();
    const a = @intFromEnum(along);
    const b = 1 - a;
    const content_along = @max(0, frame.size[parent][a] - parent_layout.padding.total(along));
    const content_across = @max(0, frame.size[parent][b] - parent_layout.padding.total(along.other()));
    const content_start = [2]f32{ frame.position[parent][0] + parent_layout.padding.left, frame.position[parent][1] + parent_layout.padding.top };

    const flow_count = flowCount(frame, parent);
    if (flow_count == 0) return;
    const scrolls_along = frame.flags[parent].scrolls(along);

    var used = parent_layout.child_gap * @as(f32, @floatFromInt(flow_count - 1));
    var children = frame.children(parent);
    while (children.next()) |child| {
        if (!frame.isFloating(child)) used += frame.size[child][a];
    }

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
        if (used < content_along - tolerance and sizing.rule == .grow and sizing.amount > 0) {
            try std.testing.expect(frame.size[child][a] >= sizing.max - tolerance);
        }
        const across_sizing = sizingAlong(frame, child, along.other());
        if (across_sizing.rule == .grow) {
            const expected = @max(frame.min_size[child][b], std.math.clamp(content_across, across_sizing.min, across_sizing.max));
            try std.testing.expectApproxEqAbs(expected, frame.size[child][b], tolerance);
        }
        // Children start inside the parent's content box. These frames never
        // scroll, so every offset is zero.
        try std.testing.expect(frame.position[child][0] >= content_start[0] - tolerance);
        try std.testing.expect(frame.position[child][1] >= content_start[1] - tolerance);
    }
}

fn buildRandomFrame(ui: *Ui, seed: u64, element_budget: u32) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    var generator: Generator = .{ .random = prng.random(), .remaining = element_budget };
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ @floatFromInt(generator.random.intRangeAtMost(u16, 1, 1200)), @floatFromInt(generator.random.intRangeAtMost(u16, 1, 900)) } } });
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

fn sizingAlong(frame: *const Frame, child: Ui.Index, axis: zui.Axis) zui.Sizing {
    return switch (axis) {
        inline else => |comptime_axis| frame.sizingOf(child, comptime_axis),
    };
}

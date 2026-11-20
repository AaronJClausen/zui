//! Randomized trees, swept for the properties every layout must have.

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

    comptime std.debug.assert(Ui.features.safety_sweeps);
    // A seed that breaks an invariant panics in `endFrame`, naming the
    // frame, whose number is the seed.
    for (0..2000) |seed| {
        buildRandomFrame(&harness.ui, seed, @intCast(seed % 200 + 1));
        harness.ui.release(harness.ui.endFrame());
    }
}

const UnsweptUi = zui.Context(.{
    .limits = .{ .max_elements = 16 },
    .Text = support.FixedMetricsText,
    .features = .{ .safety_sweeps = false },
});

fn sweepOfOneBox(box: zui.Element) ?zui.SweepFailure {
    var text_contract: support.FixedMetricsText = .{};
    var ui = UnsweptUi.init(std.testing.allocator, std.testing.io, &text_contract) catch unreachable;
    defer ui.deinit(std.testing.allocator);
    ui.beginFrame(&support.record(.zero, &.{}));
    ui.box(box);
    const frame = ui.endFrame();
    defer ui.release(frame);
    return frame.sweep();
}

test "a sweep names the invariant a frame breaks and where" {
    try std.testing.expectEqual(null, sweepOfOneBox(.{ .layout = .{ .sizing = .{ .width = .fixed(40) } } }));
    try std.testing.expectEqual(
        zui.SweepFailure{ .invariant = .negative_size, .at = .{ .element = 1 } },
        sweepOfOneBox(.{ .layout = .{ .sizing = .{ .width = .fixed(-40) } } }),
    );
    try std.testing.expectEqual(
        zui.SweepFailure{ .invariant = .non_finite_geometry, .at = .{ .element = 1 } },
        sweepOfOneBox(.{ .layout = .{ .sizing = .{ .height = .fixed(std.math.nan(f32)) } } }),
    );
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

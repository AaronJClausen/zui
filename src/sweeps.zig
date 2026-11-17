const std = @import("std");
const style = @import("style.zig");
const layout = @import("layout.zig");

const Axis = style.Axis;

/// A property every laid-out frame has, which a safety sweep checks.
pub const Invariant = enum {
    /// A size or position is NaN or infinite.
    non_finite_geometry,
    negative_size,
    /// The child walk disagrees with the parent links, declaration order or
    /// the child counts.
    inconsistent_children,
    /// The children overflow their parent while one of them could still shrink.
    overflow_while_shrinkable,
    /// Free space is left over while a growing child is below its max.
    free_space_while_growable,
    /// A growing child does not fill its parent's content box across the flow.
    growth_short_across,
    /// `grow_from_min` siblings between their floor and max grew by
    /// different shares of their weights.
    unequal_growth,
    /// A child in the flow starts outside its parent's content box, along an
    /// axis that does not scroll.
    outside_content_box,
    /// A line of a wrapping row with more than one child is wider than the row.
    line_too_wide,
    /// A line of a wrapping row starts above the bottom of the line before it.
    overlapping_lines,
    /// A command's layer is below the one before it.
    decreasing_layer,
    /// A layer's clips do not begin and end in pairs.
    unbalanced_clip,
};

/// The first invariant a frame breaks, and where.
pub const SweepFailure = struct {
    invariant: Invariant,
    at: union(enum) {
        element: u32,
        command: u32,
    },

    fn atElement(invariant: Invariant, element: anytype) SweepFailure {
        return .{ .invariant = invariant, .at = .{ .element = element } };
    }
};

/// Sums of thousands of sizes round in `f32`, so the slack grows with the
/// sizes compared.
fn slack(magnitude: f32) f32 {
    return 0.01 + @abs(magnitude) * 0x1p-12;
}

/// `Frame.sweep()`, for the context `Ui`.
pub fn run(comptime Ui: type, frame: *const Ui.Frame) ?SweepFailure {
    for (0..frame.element_count) |index| {
        const element: Ui.Index = @intCast(index);
        for (frame.size[element], frame.position[element]) |size, position| {
            if (!std.math.isFinite(size) or !std.math.isFinite(position)) return .atElement(.non_finite_geometry, element);
            if (size < -slack(0)) return .atElement(.negative_size, element);
        }
    }
    for (0..frame.element_count) |index| {
        const element: Ui.Index = @intCast(index);
        if (!childrenAreConsistent(Ui, frame, element)) return .atElement(.inconsistent_children, element);
    }
    for (0..frame.element_count) |index| {
        const parent: Ui.Index = @intCast(index);
        if (frame.child_counts[parent].in_flow == 0) continue;
        const broken = if (layout.wraps(Ui, frame, parent)) wrappingRowFailure(Ui, frame, parent) else flowFailure(Ui, frame, parent);
        if (broken) |failure| return failure;
    }
    return commandFailure(frame.commands());
}

fn childrenAreConsistent(comptime Ui: type, frame: *const Ui.Frame, parent: Ui.Index) bool {
    var count: u32 = 0;
    var in_flow: u32 = 0;
    var previous: ?Ui.Index = null;
    var children = frame.children(parent);
    while (children.next()) |child| {
        if (frame.parent[child] != parent) return false;
        if (previous) |earlier| if (child <= earlier) return false;
        previous = child;
        count += 1;
        if (!frame.isFloating(child)) in_flow += 1;
    }
    return count == frame.child_counts[parent].all and in_flow == frame.child_counts[parent].in_flow;
}

fn sizingAlong(comptime Ui: type, frame: *const Ui.Frame, element: Ui.Index, axis: Axis) style.Sizing {
    return switch (axis) {
        inline else => |comptime_axis| frame.sizingOf(element, comptime_axis),
    };
}

fn isReversed(comptime Ui: type, frame: *const Ui.Frame, parent: Ui.Index) bool {
    return frame.may_mirror and frame.flags[parent].reversed;
}

/// Whether the child starts inside the parent's content box on each axis
/// that does not scroll; a scrolled axis is offset by state the frame does
/// not keep.
fn startsInContentBox(comptime Ui: type, frame: *const Ui.Frame, parent: Ui.Index, child: Ui.Index) bool {
    const parent_layout = frame.layoutOf(parent);
    const flags = frame.flags[parent];
    const position = frame.position[parent];
    if (!flags.scroll_x) {
        if (isReversed(Ui, frame, parent)) {
            const content_right = position[0] + frame.size[parent][0] - parent_layout.padding.left;
            if (frame.position[child][0] + frame.size[child][0] > content_right + slack(content_right)) return false;
        } else {
            const content_left = position[0] + parent_layout.padding.left;
            if (frame.position[child][0] < content_left - slack(content_left)) return false;
        }
    }
    if (!flags.scroll_y) {
        const content_top = position[1] + parent_layout.padding.top;
        if (frame.position[child][1] < content_top - slack(content_top)) return false;
    }
    return true;
}

fn flowFailure(comptime Ui: type, frame: *const Ui.Frame, parent: Ui.Index) ?SweepFailure {
    const parent_layout = frame.layoutOf(parent);
    const along = parent_layout.direction.axis();
    const a = @intFromEnum(along);
    const b = 1 - a;
    const content_along = @max(0, frame.size[parent][a] - parent_layout.padding.total(along));
    const content_across = @max(0, frame.size[parent][b] - parent_layout.padding.total(along.other()));
    const scrolls_along = frame.flags[parent].scrolls(along);

    var used = parent_layout.child_gap * @as(f32, @floatFromInt(frame.child_counts[parent].in_flow - 1));
    var children = frame.children(parent);
    while (children.next()) |child| {
        if (!frame.isFloating(child)) used += frame.size[child][a];
    }
    const room = slack(content_along);
    const overflows = used > content_along + room;
    const leaves_free_space = used < content_along - room;
    if (!overflows and !growsByEqualShares(Ui, frame, parent, along)) return .atElement(.unequal_growth, parent);

    children = frame.children(parent);
    while (children.next()) |child| {
        if (frame.isFloating(child)) continue;
        const sizing = sizingAlong(Ui, frame, child, along);
        if (overflows and sizing.rule != .fixed and !scrolls_along and
            frame.size[child][a] > frame.min_size[child][a] + slack(frame.min_size[child][a])) return .atElement(.overflow_while_shrinkable, child);
        if (leaves_free_space and sizing.rule.grows() and sizing.amount > 0 and
            frame.size[child][a] < sizing.max - slack(sizing.max)) return .atElement(.free_space_while_growable, child);
        const across_sizing = sizingAlong(Ui, frame, child, along.other());
        if (across_sizing.rule.grows()) {
            const expected = @max(frame.min_size[child][b], std.math.clamp(content_across, across_sizing.min, across_sizing.max));
            if (@abs(expected - frame.size[child][b]) > slack(expected)) return .atElement(.growth_short_across, child);
        }
        if (!startsInContentBox(Ui, frame, parent, child)) return .atElement(.outside_content_box, child);
    }
    return null;
}

fn growsByEqualShares(comptime Ui: type, frame: *const Ui.Frame, parent: Ui.Index, along: Axis) bool {
    const a = @intFromEnum(along);
    var share: ?f32 = null;
    var children = frame.children(parent);
    while (children.next()) |child| {
        if (frame.isFloating(child)) continue;
        const sizing = sizingAlong(Ui, frame, child, along);
        if (sizing.rule != .grow_from_min or sizing.amount == 0) continue;
        const size = frame.size[child][a];
        const floor = frame.min_size[child][a];
        if (size < floor - slack(floor)) return false;
        if (size <= floor + slack(floor) or size >= sizing.max - slack(sizing.max)) continue;
        const child_share = (size - sizing.min) / sizing.amount;
        if (share) |expected| {
            if (@abs(expected - child_share) > slack(size)) return false;
        } else share = child_share;
    }
    return true;
}

fn wrappingRowFailure(comptime Ui: type, frame: *const Ui.Frame, row: Ui.Index) ?SweepFailure {
    const row_layout = frame.layoutOf(row);
    const gap = row_layout.child_gap;
    const content_width = @max(0, frame.size[row][0] - row_layout.padding.total(.x));
    const scrolls = frame.flags[row].scroll_x or frame.flags[row].scroll_y;

    var previous_line_bottom: f32 = -std.math.inf(f32);
    var lines = layout.Lines(Ui).init(frame, row);
    while (lines.next()) |line| {
        var line_width = -gap;
        var line_count: u32 = 0;
        var line_top = std.math.inf(f32);
        var line_bottom = -std.math.inf(f32);
        var children = line;
        while (children.next()) |child| {
            line_width += frame.size[child][0] + gap;
            line_count += 1;
            line_top = @min(line_top, frame.position[child][1]);
            line_bottom = @max(line_bottom, frame.position[child][1] + frame.size[child][1]);
        }
        const first = line.all_children.next_child;
        if (line_count > 1 and !scrolls and line_width > content_width + slack(content_width)) return .atElement(.line_too_wide, first);
        if (!scrolls and line_top < previous_line_bottom + gap - slack(line_top)) return .atElement(.overlapping_lines, first);
        children = line;
        while (children.next()) |child| {
            const sizing = frame.sizingOf(child, .x);
            if (line_width < content_width - slack(content_width) and sizing.rule.grows() and sizing.amount > 0 and
                frame.size[child][0] < sizing.max - slack(sizing.max)) return .atElement(.free_space_while_growable, child);
            if (!startsInContentBox(Ui, frame, row, child)) return .atElement(.outside_content_box, child);
        }
        previous_line_bottom = line_bottom;
    }
    return null;
}

fn commandFailure(commands: anytype) ?SweepFailure {
    var previous_z: i16 = std.math.minInt(i16);
    var clip_depth: u32 = 0;
    for (commands, 0..) |command, index| {
        const at: u32 = @intCast(index);
        if (command.z != previous_z) {
            if (clip_depth != 0) return .{ .invariant = .unbalanced_clip, .at = .{ .command = at } };
            if (command.z < previous_z) return .{ .invariant = .decreasing_layer, .at = .{ .command = at } };
            previous_z = command.z;
        }
        switch (command.payload) {
            .clip_begin => clip_depth += 1,
            .clip_end => {
                if (clip_depth == 0) return .{ .invariant = .unbalanced_clip, .at = .{ .command = at } };
                clip_depth -= 1;
            },
            else => {},
        }
    }
    if (clip_depth != 0) return .{ .invariant = .unbalanced_clip, .at = .{ .command = @intCast(commands.len) } };
    return null;
}

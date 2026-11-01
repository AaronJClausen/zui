//! The layout passes of SPEC.md §6.2. Elements are stored in declaration
//! (pre-)order, so every parent's index is lower than its children's:
//! iterating backward visits children before parents, forward the reverse.
//!
//! Floating elements take no space in their parent's flow. They are sized
//! like any element, but positioned in a second step, relative to the box
//! they attach to.

const std = @import("std");
const style = @import("style.zig");
const text = @import("text.zig");
const interaction = @import("interaction.zig");

const Axis = style.Axis;
const tolerance = text.tolerance;

pub fn run(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    measureTexts(Ui, ui, frame);
    fit(Ui, frame, .x);
    distribute(Ui, frame, .x);
    wrapTexts(Ui, ui, frame);
    fit(Ui, frame, .y);
    distribute(Ui, frame, .y);
    position(Ui, ui, frame);
}

fn measureTexts(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    for (frame.texts[0..frame.text_count]) |*record| {
        const content = frame.text_bytes[record.bytes_start..][0..record.bytes_len];
        record.metrics = text.measureMetrics(&ui.memory.cache, ui.platform, content, record.style.wrap, record.style.font, record.style.size, record.style.line_height);
    }
}

/// Iterates the children that take part in a parent's flow.
fn FlowChildren(comptime Ui: type) type {
    return struct {
        frame: *const Ui.Frame,
        next_child: Ui.Index,

        fn init(frame: *const Ui.Frame, parent: Ui.Index) @This() {
            return .{ .frame = frame, .next_child = frame.first_child[parent] };
        }

        fn next(self: *@This()) ?Ui.Index {
            while (self.next_child != Ui.none_index) {
                const child = self.next_child;
                self.next_child = self.frame.next_sibling[child];
                if (!self.frame.isFloating(child)) return child;
            }
            return null;
        }
    };
}

fn flowChildCount(comptime Ui: type, frame: *const Ui.Frame, parent: Ui.Index) u32 {
    var count: u32 = 0;
    var children = FlowChildren(Ui).init(frame, parent);
    while (children.next()) |_| count += 1;
    return count;
}

fn gapsFor(child_gap: f32, flow_count: u32) f32 {
    return if (flow_count == 0) 0 else child_gap * @as(f32, @floatFromInt(flow_count - 1));
}

const ContentSize = struct { preferred: f32, min: f32 };

/// Passes 1 and 4: each element's size from its content, children first.
fn fit(comptime Ui: type, frame: *Ui.Frame, axis: Axis) void {
    const a = @intFromEnum(axis);
    var index = frame.element_count;
    while (index > 0) {
        index -= 1;
        const element: Ui.Index = @intCast(index);
        const content = contentSize(Ui, frame, element, axis);
        const sizing = frame.sizingOf(element, axis);
        switch (sizing.rule) {
            .fit, .grow => {
                frame.size[element][a] = std.math.clamp(content.preferred, sizing.min, sizing.max);
                frame.min_size[element][a] = std.math.clamp(content.min, sizing.min, sizing.max);
            },
            .fixed => {
                frame.size[element][a] = sizing.amount;
                frame.min_size[element][a] = sizing.amount;
            },
            // Resolved against the parent in `distribute`; contributes
            // nothing to a `fit` parent, which would otherwise be circular.
            .percent => {
                frame.size[element][a] = 0;
                frame.min_size[element][a] = sizing.min;
            },
        }
        // A scrolled axis may be smaller than its content.
        if (frame.flags[element].scrolls(axis) and sizing.rule != .fixed) frame.min_size[element][a] = sizing.min;
    }
}

fn contentSize(comptime Ui: type, frame: *const Ui.Frame, element: Ui.Index, axis: Axis) ContentSize {
    const a = @intFromEnum(axis);
    if (frame.kindOf(element) == .text) {
        const record = frame.texts[frame.content_index[element]];
        if (axis == .x) return .{ .preferred = record.metrics.preferred_width, .min = record.metrics.min_width };
        const height = @as(f32, @floatFromInt(record.line_count)) * record.metrics.line_height;
        return .{ .preferred = height, .min = height };
    }

    const element_layout = frame.layoutOf(element);
    const padding = element_layout.padding.total(axis);
    const along = element_layout.direction.axis() == axis;
    var preferred: f32 = 0;
    var min: f32 = 0;
    var flow_count: u32 = 0;
    var children = FlowChildren(Ui).init(frame, element);
    while (children.next()) |child| {
        flow_count += 1;
        if (along) {
            preferred += frame.size[child][a];
            min += frame.min_size[child][a];
        } else {
            preferred = @max(preferred, frame.size[child][a]);
            min = @max(min, frame.min_size[child][a]);
        }
    }
    if (along) {
        const gaps = gapsFor(element_layout.child_gap, flow_count);
        preferred += gaps;
        min += gaps;
    }
    return .{ .preferred = preferred + padding, .min = min + padding };
}

/// Passes 2 and 5: each parent hands its content box to its children.
fn distribute(comptime Ui: type, frame: *Ui.Frame, axis: Axis) void {
    const a = @intFromEnum(axis);
    for (0..frame.element_count) |index| {
        const parent: Ui.Index = @intCast(index);
        if (frame.child_count[parent] == 0) continue;
        const parent_layout = frame.layoutOf(parent);
        const content_box = @max(0, frame.size[parent][a] - parent_layout.padding.total(axis));
        const scrolls = frame.flags[parent].scrolls(axis);

        sizeFloatingChildren(Ui, frame, parent, axis);

        if (parent_layout.direction.axis() != axis) {
            var children = FlowChildren(Ui).init(frame, parent);
            while (children.next()) |child| {
                const sizing = frame.sizingOf(child, axis);
                frame.size[child][a] = switch (sizing.rule) {
                    .fixed => frame.size[child][a],
                    .grow => @max(frame.min_size[child][a], std.math.clamp(content_box, sizing.min, sizing.max)),
                    .percent => std.math.clamp(content_box * sizing.amount, sizing.min, sizing.max),
                    .fit => if (!scrolls and frame.size[child][a] > content_box) @max(frame.min_size[child][a], content_box) else frame.size[child][a],
                };
            }
            continue;
        }

        const flow_count = flowChildCount(Ui, frame, parent);
        var used = gapsFor(parent_layout.child_gap, flow_count);
        var children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            const sizing = frame.sizingOf(child, axis);
            if (sizing.rule == .percent) frame.size[child][a] = std.math.clamp(content_box * sizing.amount, sizing.min, sizing.max);
            used += frame.size[child][a];
        }

        const remaining = content_box - used;
        if (remaining > tolerance) {
            grow(Ui, frame, parent, axis, remaining);
        } else if (remaining < -tolerance and !scrolls) {
            shrink(Ui, frame, parent, axis, -remaining);
        }
    }
}

/// `grow` and `percent` on a floating element resolve against the box it
/// attaches to: the viewport for `.root`, and otherwise the parent (an
/// `.element` target may not be sized yet when its parent is visited).
fn sizeFloatingChildren(comptime Ui: type, frame: *Ui.Frame, parent: Ui.Index, axis: Axis) void {
    const a = @intFromEnum(axis);
    var child = frame.first_child[parent];
    while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
        if (!frame.isFloating(child)) continue;
        const reference = switch (frame.floatingOf(child).attach_to) {
            .root => frame.viewport[a],
            .parent, .element => frame.size[parent][a],
        };
        const sizing = frame.sizingOf(child, axis);
        switch (sizing.rule) {
            .grow => frame.size[child][a] = @max(frame.min_size[child][a], std.math.clamp(reference, sizing.min, sizing.max)),
            .percent => frame.size[child][a] = std.math.clamp(reference * sizing.amount, sizing.min, sizing.max),
            .fit, .fixed => {},
        }
    }
}

/// Free space goes to `grow` children in proportion to their weights. A
/// child that reaches its max is clamped and the rest is redistributed;
/// each round clamps at least one child, so this ends.
fn grow(comptime Ui: type, frame: *Ui.Frame, parent: Ui.Index, axis: Axis, free_space: f32) void {
    const a = @intFromEnum(axis);
    var remaining = free_space;
    while (remaining > tolerance) {
        var total_weight: f32 = 0;
        var children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            if (canGrow(Ui, frame, child, axis)) total_weight += frame.sizingOf(child, axis).amount;
        }
        if (total_weight <= 0) return;

        var clamped_any = false;
        children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            if (!canGrow(Ui, frame, child, axis)) continue;
            const sizing = frame.sizingOf(child, axis);
            const share = remaining * sizing.amount / total_weight;
            if (frame.size[child][a] + share > sizing.max) {
                remaining -= sizing.max - frame.size[child][a];
                frame.size[child][a] = sizing.max;
                clamped_any = true;
            }
        }
        if (clamped_any) continue;

        children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            if (!canGrow(Ui, frame, child, axis)) continue;
            frame.size[child][a] += remaining * frame.sizingOf(child, axis).amount / total_weight;
        }
        return;
    }
}

fn canGrow(comptime Ui: type, frame: *const Ui.Frame, child: Ui.Index, axis: Axis) bool {
    const sizing = frame.sizingOf(child, axis);
    return sizing.rule == .grow and sizing.amount > 0 and frame.size[child][@intFromEnum(axis)] < sizing.max - tolerance;
}

/// Overflow is taken from the largest shrinkable children first, levelling
/// them down to the next largest, never below a child's minimum. Each
/// round levels a group, resolves the deficit, or retires a child at its
/// minimum, so this ends.
fn shrink(comptime Ui: type, frame: *Ui.Frame, parent: Ui.Index, axis: Axis, overflow: f32) void {
    const a = @intFromEnum(axis);
    var deficit = overflow;
    var rounds: usize = 0;
    const max_rounds = 2 * @as(usize, frame.child_count[parent]) + 2;
    while (deficit > tolerance and rounds < max_rounds) : (rounds += 1) {
        var largest: f32 = 0;
        var largest_count: f32 = 0;
        var children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            if (!canShrink(Ui, frame, child, axis)) continue;
            const size = frame.size[child][a];
            if (size > largest + tolerance) {
                largest = size;
                largest_count = 1;
            } else if (size > largest - tolerance) {
                largest_count += 1;
            }
        }
        if (largest_count == 0) return;

        var next_largest: f32 = 0;
        children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            if (!canShrink(Ui, frame, child, axis)) continue;
            const size = frame.size[child][a];
            if (size < largest - tolerance) next_largest = @max(next_largest, size);
        }

        const share = deficit / largest_count;
        var removed: f32 = 0;
        children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            if (!canShrink(Ui, frame, child, axis)) continue;
            const size = frame.size[child][a];
            if (size < largest - tolerance) continue;
            const target = @max(size - share, next_largest, frame.min_size[child][a]);
            removed += size - target;
            frame.size[child][a] = target;
        }
        if (removed <= 0) return;
        deficit -= removed;
    }
}

fn canShrink(comptime Ui: type, frame: *const Ui.Frame, child: Ui.Index, axis: Axis) bool {
    const a = @intFromEnum(axis);
    return frame.sizingOf(child, axis).rule != .fixed and frame.size[child][a] > frame.min_size[child][a] + tolerance;
}

/// Pass 3: with widths known, wrap every text element into lines.
fn wrapTexts(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    for (0..frame.element_count) |index| {
        const element: Ui.Index = @intCast(index);
        if (frame.kindOf(element) != .text) continue;
        const record = &frame.texts[frame.content_index[element]];
        const content = frame.text_bytes[record.bytes_start..][0..record.bytes_len];
        record.first_line = frame.line_count;
        const fitted = text.wrapLines(
            &ui.memory.cache,
            ui.platform,
            content,
            record.bytes_start,
            record.style.wrap,
            record.style.font,
            record.style.size,
            frame.size[element][0],
            &frame.lines,
            &frame.line_count,
        );
        record.line_count = frame.line_count - record.first_line;
        if (!fitted) {
            frame.diagnostics.exceeded.insert(.render_commands);
            if (frame.diagnostics.first_dropped_id == 0) frame.diagnostics.first_dropped_id = frame.element_id[element];
        }
    }
}

/// Pass 6. The flow is positioned first, skipping floating subtrees; then
/// each floating element in declaration order is placed against its
/// target and its own subtree positioned.
fn position(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    frame.position[Ui.root_index] = .{ 0, 0 };
    for (0..frame.element_count) |index| {
        const parent: Ui.Index = @intCast(index);
        if (frame.child_count[parent] != 0 and frame.floating_root[parent] == Ui.none_index) positionChildren(Ui, ui, frame, parent);
    }

    if (frame.floating_count == 0) return;
    for (0..frame.element_count) |index| {
        const floating: Ui.Index = @intCast(index);
        if (!frame.isFloating(floating)) continue;
        placeFloating(Ui, frame, floating);
        for (floating..frame.subtree_end[floating]) |subtree_index| {
            const parent: Ui.Index = @intCast(subtree_index);
            if (frame.child_count[parent] != 0 and frame.floating_root[parent] == floating) positionChildren(Ui, ui, frame, parent);
        }
    }
}

fn placeFloating(comptime Ui: type, frame: *Ui.Frame, floating: Ui.Index) void {
    const config = frame.floatingOf(floating);
    const parent = frame.parent[floating];
    var target_position = frame.position[parent];
    var target_size = frame.size[parent];
    switch (config.attach_to) {
        .parent => {},
        .root => {
            target_position = .{ 0, 0 };
            target_size = frame.viewport;
        },
        .element => |target_id| if (frame.lookup(target_id.hash)) |target| {
            target_position = frame.position[target];
            target_size = frame.size[target];
        },
    }
    const attach = config.attach_point.fractions();
    const anchor = config.anchor.fractions();
    for (0..2) |a| {
        frame.position[floating][a] = target_position[a] + target_size[a] * attach[a] - frame.size[floating][a] * anchor[a] + config.offset[a];
    }
}

fn positionChildren(comptime Ui: type, ui: *Ui, frame: *Ui.Frame, parent: Ui.Index) void {
    const parent_layout = frame.layoutOf(parent);
    const along = parent_layout.direction.axis();
    const across = along.other();
    const a = @intFromEnum(along);
    const b = @intFromEnum(across);

    const content_start = [2]f32{
        frame.position[parent][0] + parent_layout.padding.left,
        frame.position[parent][1] + parent_layout.padding.top,
    };
    const content_along = frame.size[parent][a] - parent_layout.padding.total(along);
    const content_across = frame.size[parent][b] - parent_layout.padding.total(across);

    const flow_count = flowChildCount(Ui, frame, parent);
    var used = gapsFor(parent_layout.child_gap, flow_count);
    var widest_across: f32 = 0;
    var children = FlowChildren(Ui).init(frame, parent);
    while (children.next()) |child| {
        used += frame.size[child][a];
        widest_across = @max(widest_across, frame.size[child][b]);
    }
    frame.content_size[parent][a] = used + parent_layout.padding.total(along);
    frame.content_size[parent][b] = widest_across + parent_layout.padding.total(across);

    const offset = scrollOffset(Ui, ui, frame, parent);

    const free_along = content_along - used;
    var cursor = content_start[a] - offset[a] + if (free_along > 0) free_along * parent_layout.child_alignment.axis(along).fraction() else 0;
    const across_fraction = parent_layout.child_alignment.axis(across).fraction();

    children = FlowChildren(Ui).init(frame, parent);
    while (children.next()) |child| {
        frame.position[child][a] = cursor;
        cursor += frame.size[child][a] + parent_layout.child_gap;
        const free_across = content_across - frame.size[child][b];
        frame.position[child][b] = content_start[b] - offset[b] + if (free_across > 0) free_across * across_fraction else 0;
    }
}

/// The element's scroll offset, clamped to its content now that the
/// content is measured, and written back so the state stays in range.
fn scrollOffset(comptime Ui: type, ui: *Ui, frame: *const Ui.Frame, parent: Ui.Index) [2]f32 {
    const flags = frame.flags[parent];
    if (!flags.scroll_x and !flags.scroll_y) return .{ 0, 0 };
    const scroll = ui.memory.states.get(frame.element_id[parent], interaction.ScrollState, ui.input_state.frame_number, .create) orelse return .{ 0, 0 };
    for (0..2) |a| {
        const scrolls = if (a == 0) flags.scroll_x else flags.scroll_y;
        const limit = @max(0, frame.content_size[parent][a] - frame.size[parent][a]);
        scroll.offset[a] = if (scrolls) std.math.clamp(scroll.offset[a], 0, limit) else 0;
    }
    return scroll.offset;
}

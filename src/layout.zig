const std = @import("std");
const style = @import("style.zig");
const text = @import("text.zig");
const interaction = @import("interaction.zig");
const parallel_measure = @import("parallel_measure.zig");
const TraceZone = @import("trace.zig").TraceZone;

const Axis = style.Axis;
const tolerance = text.tolerance;
const larger = style.larger;
const clampSize = style.clampSize;

/// Each pass stays a function of its own. Inlined into one body, they ran
/// about 3% slower on the 4,096-box benchmark, and fused into four loops
/// about 17% slower: register pressure costs more than the calls and the
/// extra loops.
pub fn run(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    runPass(Ui, .measure_text, measureTexts, .{ Ui, ui, frame });
    runPass(Ui, .fit_widths, fit, .{ Ui, frame, .x });
    runPass(Ui, .distribute_widths, distribute, .{ Ui, frame, .x });
    runPass(Ui, .wrap_text, wrapTexts, .{ Ui, ui, frame });
    runPass(Ui, .fit_heights, fit, .{ Ui, frame, .y });
    runPass(Ui, .distribute_heights, distribute, .{ Ui, frame, .y });
    runPass(Ui, .position, position, .{ Ui, ui, frame });
}

inline fn runPass(comptime Ui: type, comptime zone: TraceZone, comptime pass: anytype, arguments: anytype) void {
    const traced = Ui.Tracing.begin(zone);
    defer traced.end();
    @call(.never_inline, pass, arguments);
}

/// Measures inline until the frame has made `parallel_measure_threshold`
/// calls to the text contract. If the contract is thread-safe, the misses
/// in the rest of the frame's text are then measured in parallel first.
/// Warm frames stay on the inline path and pay nothing for the parallel one.
fn measureTexts(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    if (!Ui.has_text) return;
    const cache = &ui.memory.cache;
    const calls_before = cache.measure_calls;
    var switched_to_parallel = false;
    var run_count: u32 = 0;
    for (frame.texts[0..frame.text_count], 0..) |*record, text_index| {
        if (Ui.measures_in_parallel and !switched_to_parallel and cache.measure_calls - calls_before >= Ui.limits.parallel_measure_threshold) {
            switched_to_parallel = true;
            parallel_measure.prefetch(Ui, ui, frame.texts[text_index..frame.text_count], frame.text_bytes[0..frame.text_bytes_used], frame.zoom, Ui.limits.parallel_measure_threshold);
        }
        const content = frame.text_bytes[record.bytes_start..][0..record.bytes_len];
        record.metrics = text.measureText(ui.measurer(record.style, frame.zoom), content, record.style.wrap, record.style.line_height, &ui.memory.run_widths, &run_count);
    }
}

/// Iterates the children that take part in a parent's flow.
fn FlowChildren(comptime Ui: type) type {
    return struct {
        all_children: Ui.Frame.Children,
        has_floating: bool,

        fn init(frame: *const Ui.Frame, parent: Ui.Index) @This() {
            return .{
                .all_children = frame.children(parent),
                .has_floating = frame.flow_child_count[parent] != frame.child_count[parent],
            };
        }

        fn next(self: *@This()) ?Ui.Index {
            while (self.all_children.next()) |child| {
                if (!self.has_floating or !self.all_children.frame.isFloating(child)) return child;
            }
            return null;
        }
    };
}

fn gapsFor(child_gap: f32, flow_count: u32) f32 {
    return if (flow_count == 0) 0 else child_gap * @as(f32, @floatFromInt(flow_count - 1));
}

const ContentSize = struct { preferred: f32, min: f32 };

/// Passes 1 and 4: each element's size from its content. Running
/// backward, each element adds its size into its parent's, which
/// `size` and `min_size` hold until the parent itself is reached, so no
/// pass walks a child list. Declaration zeroes both, and nothing before
/// this pass writes this axis.
fn fit(comptime Ui: type, frame: *Ui.Frame, comptime axis: Axis) void {
    const a = @intFromEnum(axis);
    var index = frame.element_count;
    while (index > 0) {
        index -= 1;
        const element: Ui.Index = @intCast(index);
        const content = contentSize(Ui, frame, element, axis);
        const sizing = frame.sizingOf(element, axis);
        switch (sizing.rule) {
            .fit, .grow => {
                frame.size[element][a] = clampSize(content.preferred, sizing.min, sizing.max);
                frame.min_size[element][a] = clampSize(content.min, sizing.min, sizing.max);
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

        if (element == Ui.root_index or frame.isFloating(element)) continue;
        const parent = frame.parent[element];
        if (frame.flags[parent].top_to_bottom == (axis == .y)) {
            frame.size[parent][a] += frame.size[element][a];
            frame.min_size[parent][a] += frame.min_size[element][a];
        } else {
            frame.size[parent][a] = larger(frame.size[parent][a], frame.size[element][a]);
            frame.min_size[parent][a] = larger(frame.min_size[parent][a], frame.min_size[element][a]);
        }
    }
}

fn contentSize(comptime Ui: type, frame: *const Ui.Frame, element: Ui.Index, comptime axis: Axis) ContentSize {
    const a = @intFromEnum(axis);
    if (Ui.has_text and frame.kindOf(element) == .text) {
        const record = frame.texts[frame.content_index[element]];
        if (axis == .x) return .{ .preferred = record.metrics.preferred_width, .min = record.metrics.min_width };
        const height = @as(f32, @floatFromInt(record.line_count)) * record.metrics.line_height;
        return .{ .preferred = height, .min = height };
    }

    if (frame.layout_index[element] == Ui.none_index) return .{ .preferred = frame.size[element][a], .min = frame.min_size[element][a] };
    const element_layout = frame.layouts[frame.layout_index[element]];
    const padding = element_layout.padding.total(axis);
    const gaps = if (element_layout.direction.axis() == axis) gapsFor(element_layout.child_gap, frame.flow_child_count[element]) else 0;
    return .{ .preferred = frame.size[element][a] + gaps + padding, .min = frame.min_size[element][a] + gaps + padding };
}

/// Passes 2 and 5: each parent hands its content box to its children.
fn distribute(comptime Ui: type, frame: *Ui.Frame, comptime axis: Axis) void {
    const a = @intFromEnum(axis);
    for (0..frame.element_count) |index| {
        const parent: Ui.Index = @intCast(index);
        if (frame.child_count[parent] == 0) continue;
        const parent_layout = frame.layoutOf(parent);
        const padding = parent_layout.padding.total(axis);
        const content_box = larger(0, frame.size[parent][a] - padding);
        const scrolls = frame.flags[parent].scrolls(axis);

        if (frame.flow_child_count[parent] != frame.child_count[parent]) @call(.never_inline, sizeFloatingChildren, .{ Ui, frame, parent, axis });

        if (parent_layout.direction.axis() != axis) {
            var widest: f32 = 0;
            var children = FlowChildren(Ui).init(frame, parent);
            while (children.next()) |child| {
                const sizing = frame.sizingOf(child, axis);
                frame.size[child][a] = switch (sizing.rule) {
                    .fixed => frame.size[child][a],
                    .grow => larger(frame.min_size[child][a], clampSize(content_box, sizing.min, sizing.max)),
                    .percent => clampSize(content_box * sizing.amount, sizing.min, sizing.max),
                    .fit => if (!scrolls and frame.size[child][a] > content_box) larger(frame.min_size[child][a], content_box) else frame.size[child][a],
                };
                widest = larger(widest, frame.size[child][a]);
            }
            frame.content_size[parent][a] = widest + padding;
            continue;
        }

        var used = gapsFor(parent_layout.child_gap, frame.flow_child_count[parent]);
        var grow_weight: f32 = 0;
        var any_grow_max = false;
        var children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            const sizing = frame.sizingOf(child, axis);
            switch (sizing.rule) {
                .percent => frame.size[child][a] = clampSize(content_box * sizing.amount, sizing.min, sizing.max),
                .grow => if (sizing.amount > 0) {
                    grow_weight += sizing.amount;
                    any_grow_max = any_grow_max or sizing.max != std.math.inf(f32);
                },
                .fit, .fixed => {},
            }
            used += frame.size[child][a];
        }

        const remaining = content_box - used;
        if (remaining > tolerance and grow_weight > 0) {
            if (any_grow_max) {
                used += grow(Ui, frame, parent, axis, remaining);
            } else {
                // No child can reach a max, so the space divides in one go.
                children = FlowChildren(Ui).init(frame, parent);
                while (children.next()) |child| {
                    const sizing = frame.sizingOf(child, axis);
                    if (sizing.rule == .grow) frame.size[child][a] += remaining * sizing.amount / grow_weight;
                }
                used = content_box;
            }
        } else if (remaining < -tolerance and !scrolls) {
            used -= shrink(Ui, frame, parent, axis, -remaining);
        }
        frame.content_size[parent][a] = used + padding;
    }
}

/// `grow` and `percent` on a floating element resolve against the box it
/// attaches to: the viewport for `.root`, and otherwise the parent (an
/// `.element` target may not be sized yet when its parent is visited).
fn sizeFloatingChildren(comptime Ui: type, frame: *Ui.Frame, parent: Ui.Index, comptime axis: Axis) void {
    const a = @intFromEnum(axis);
    var children = frame.children(parent);
    while (children.next()) |child| {
        if (!frame.isFloating(child)) continue;
        const reference = switch (frame.floatingOf(child).attach_to) {
            .root => frame.viewport[a],
            .parent, .element => frame.size[parent][a],
        };
        const sizing = frame.sizingOf(child, axis);
        switch (sizing.rule) {
            .grow => frame.size[child][a] = larger(frame.min_size[child][a], clampSize(reference, sizing.min, sizing.max)),
            .percent => frame.size[child][a] = clampSize(reference * sizing.amount, sizing.min, sizing.max),
            .fit, .fixed => {},
        }
    }
}

/// Free space goes to `grow` children in proportion to their weights. A
/// child that reaches its max is clamped and the rest is redistributed;
/// each round clamps at least one child, so this ends. Returns the space
/// handed out.
fn grow(comptime Ui: type, frame: *Ui.Frame, parent: Ui.Index, comptime axis: Axis, free_space: f32) f32 {
    const a = @intFromEnum(axis);
    var remaining = free_space;
    while (remaining > tolerance) {
        var total_weight: f32 = 0;
        var children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            if (canGrow(Ui, frame, child, axis)) total_weight += frame.sizingOf(child, axis).amount;
        }
        if (total_weight <= 0) return free_space - remaining;

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
        return free_space;
    }
    return free_space - remaining;
}

fn canGrow(comptime Ui: type, frame: *const Ui.Frame, child: Ui.Index, comptime axis: Axis) bool {
    const sizing = frame.sizingOf(child, axis);
    return sizing.rule == .grow and sizing.amount > 0 and frame.size[child][@intFromEnum(axis)] < sizing.max - tolerance;
}

/// Overflow is taken from the largest shrinkable children first, levelling
/// them down to the next largest, never below a child's minimum. Each
/// round levels a group, resolves the deficit, or retires a child at its
/// minimum, so this ends. Returns the size taken away.
fn shrink(comptime Ui: type, frame: *Ui.Frame, parent: Ui.Index, comptime axis: Axis, overflow: f32) f32 {
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
        if (largest_count == 0) break;

        var next_largest: f32 = 0;
        children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            if (!canShrink(Ui, frame, child, axis)) continue;
            const size = frame.size[child][a];
            if (size < largest - tolerance) next_largest = larger(next_largest, size);
        }

        const share = deficit / largest_count;
        var removed: f32 = 0;
        children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            if (!canShrink(Ui, frame, child, axis)) continue;
            const size = frame.size[child][a];
            if (size < largest - tolerance) continue;
            const target = larger(larger(size - share, next_largest), frame.min_size[child][a]);
            removed += size - target;
            frame.size[child][a] = target;
        }
        if (removed <= 0) break;
        deficit -= removed;
    }
    return overflow - deficit;
}

fn canShrink(comptime Ui: type, frame: *const Ui.Frame, child: Ui.Index, comptime axis: Axis) bool {
    const a = @intFromEnum(axis);
    return frame.sizingOf(child, axis).rule != .fixed and frame.size[child][a] > frame.min_size[child][a] + tolerance;
}

/// Pass 3: with widths known, wrap every text element into lines.
fn wrapTexts(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    if (!Ui.has_text) return;
    for (frame.texts[0..frame.text_count]) |*record| {
        const element = record.element;
        const content = frame.text_bytes[record.bytes_start..][0..record.bytes_len];
        if (record.metrics.run_widths_pending and !text.fitsOneLine(record.style.wrap, record.metrics, frame.size[element][0])) {
            text.measurePendingRuns(ui.measurer(record.style, frame.zoom), content, record.style.wrap, record.metrics, &ui.memory.run_widths);
        }
        record.first_line = frame.line_count;
        const fitted = text.wrapLines(
            content,
            record.bytes_start,
            record.style.wrap,
            record.metrics,
            &ui.memory.run_widths,
            frame.size[element][0],
            &frame.lines,
            &frame.line_count,
        );
        record.line_count = frame.line_count - record.first_line;
        if (!fitted) {
            frame.diagnostics.exceeded.insert(.max_render_commands);
            if (frame.diagnostics.first_dropped_id == 0) frame.diagnostics.first_dropped_id = frame.element_id[element];
        }
    }
}

/// Where a parent's next flow child goes: prepared when the parent is
/// placed, advanced by each child.
pub const ChildPlacement = struct {
    next_along: f32,
    across_start: f32,
    across_space: f32,
    across_fraction: f32,
    gap: f32,
};

/// Pass 6, one forward pass in declaration order. Parents come before
/// their children, so each element is placed from its parent's
/// `ChildPlacement` and then prepares its own. A floating element is
/// placed against its target, which, being declared earlier, is already
/// placed; a target declared later falls back to the parent.
fn position(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    const placements = &ui.memory.child_placements;
    frame.position[Ui.root_index] = .{ 0, 0 };
    startChildren(Ui, ui, frame, Ui.root_index);
    for (1..frame.element_count) |index| {
        const element: Ui.Index = @intCast(index);
        if (frame.isFloating(element)) {
            placeFloating(Ui, frame, element);
        } else {
            const parent = frame.parent[element];
            const placement = &placements[parent];
            const along: usize = @intFromBool(frame.flags[parent].top_to_bottom);
            const across = 1 - along;
            frame.position[element][along] = placement.next_along;
            placement.next_along += frame.size[element][along] + placement.gap;
            const free_across = placement.across_space - frame.size[element][across];
            frame.position[element][across] = placement.across_start + if (free_across > 0) free_across * placement.across_fraction else 0;
        }
        if (frame.child_count[element] != 0) startChildren(Ui, ui, frame, element);
    }
}

inline fn startChildren(comptime Ui: type, ui: *Ui, frame: *Ui.Frame, parent: Ui.Index) void {
    const parent_layout = frame.layoutOf(parent);
    const top_to_bottom = frame.flags[parent].top_to_bottom;
    const along: usize = @intFromBool(top_to_bottom);
    const across = 1 - along;
    const padding_start = [2]f32{ parent_layout.padding.left, parent_layout.padding.top };
    const padding_total = [2]f32{ parent_layout.padding.total(.x), parent_layout.padding.total(.y) };
    const alignment = if (top_to_bottom)
        [2]f32{ parent_layout.child_alignment.y.fraction(), parent_layout.child_alignment.x.fraction() }
    else
        [2]f32{ parent_layout.child_alignment.x.fraction(), parent_layout.child_alignment.y.fraction() };

    const offset = scrollOffset(Ui, ui, frame, parent);
    const free_along = frame.size[parent][along] - frame.content_size[parent][along];
    ui.memory.child_placements[parent] = .{
        .next_along = frame.position[parent][along] + padding_start[along] - offset[along] + if (free_along > 0) free_along * alignment[0] else 0,
        .across_start = frame.position[parent][across] + padding_start[across] - offset[across],
        .across_space = frame.size[parent][across] - padding_total[across],
        .across_fraction = alignment[1],
        .gap = parent_layout.child_gap,
    };
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
        .element => |target_id| if (frame.lookup(target_id.hash)) |target| if (target < floating) {
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

/// The element's scroll offset, clamped to its content now that the
/// content is measured, and written back so the state stays in range.
inline fn scrollOffset(comptime Ui: type, ui: *Ui, frame: *const Ui.Frame, parent: Ui.Index) [2]f32 {
    const flags = frame.flags[parent];
    if (!flags.scroll_x and !flags.scroll_y) return .{ 0, 0 };
    return @call(.never_inline, clampedScrollOffset, .{ Ui, ui, frame, parent });
}

/// Kept out of line: few elements scroll, and inlined, the state table
/// lookup makes `startChildren` save and restore registers for every parent.
fn clampedScrollOffset(comptime Ui: type, ui: *Ui, frame: *const Ui.Frame, parent: Ui.Index) [2]f32 {
    const flags = frame.flags[parent];
    const scroll = ui.memory.states.get(frame.element_id[parent], interaction.ScrollState, ui.stateGeneration(), .create) orelse return .{ 0, 0 };
    for (0..2) |a| {
        const scrolls = if (a == 0) flags.scroll_x else flags.scroll_y;
        const limit = larger(0, frame.content_size[parent][a] - frame.size[parent][a]);
        scroll.offset[a] = if (scrolls) clampSize(scroll.offset[a], 0, limit) else 0;
    }
    return scroll.offset;
}

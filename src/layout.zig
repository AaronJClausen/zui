//! The layout passes of SPEC.md §6.2. Elements are stored in declaration
//! (pre-)order, so every parent's index is lower than its children's:
//! iterating backward visits children before parents, forward the reverse.

const std = @import("std");
const style = @import("style.zig");
const text = @import("text.zig");

const Axis = style.Axis;
const tolerance = text.tolerance;

pub fn run(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    measureTexts(Ui, ui, frame);
    fit(Ui, frame, .x);
    distribute(Ui, frame, .x);
    wrapTexts(Ui, ui, frame);
    fit(Ui, frame, .y);
    distribute(Ui, frame, .y);
    position(Ui, frame);
}

fn measureTexts(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    for (frame.texts[0..frame.text_count]) |*record| {
        const content = frame.text_bytes[record.bytes_start..][0..record.bytes_len];
        record.metrics = text.measureMetrics(&ui.memory.cache, ui.platform, content, record.style.wrap, record.style.font, record.style.size, record.style.line_height);
    }
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
    if (frame.child_count[element] == 0) return .{ .preferred = padding, .min = padding };

    const along = element_layout.direction.axis() == axis;
    var preferred: f32 = 0;
    var min: f32 = 0;
    var child = frame.first_child[element];
    while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
        if (along) {
            preferred += frame.size[child][a];
            min += frame.min_size[child][a];
        } else {
            preferred = @max(preferred, frame.size[child][a]);
            min = @max(min, frame.min_size[child][a]);
        }
    }
    if (along) {
        const gaps = element_layout.child_gap * @as(f32, @floatFromInt(frame.child_count[element] - 1));
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

        if (parent_layout.direction.axis() != axis) {
            var child = frame.first_child[parent];
            while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
                const sizing = frame.sizingOf(child, axis);
                frame.size[child][a] = switch (sizing.rule) {
                    .fixed => frame.size[child][a],
                    .grow => @max(frame.min_size[child][a], std.math.clamp(content_box, sizing.min, sizing.max)),
                    .percent => std.math.clamp(content_box * sizing.amount, sizing.min, sizing.max),
                    .fit => if (frame.size[child][a] > content_box) @max(frame.min_size[child][a], content_box) else frame.size[child][a],
                };
            }
            continue;
        }

        var used = parent_layout.child_gap * @as(f32, @floatFromInt(frame.child_count[parent] - 1));
        var child = frame.first_child[parent];
        while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
            const sizing = frame.sizingOf(child, axis);
            if (sizing.rule == .percent) frame.size[child][a] = std.math.clamp(content_box * sizing.amount, sizing.min, sizing.max);
            used += frame.size[child][a];
        }

        const remaining = content_box - used;
        if (remaining > tolerance) {
            grow(Ui, frame, parent, axis, remaining);
        } else if (remaining < -tolerance) {
            shrink(Ui, frame, parent, axis, -remaining);
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
        var child = frame.first_child[parent];
        while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
            if (canGrow(Ui, frame, child, axis)) total_weight += frame.sizingOf(child, axis).amount;
        }
        if (total_weight <= 0) return;

        var clamped_any = false;
        child = frame.first_child[parent];
        while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
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

        child = frame.first_child[parent];
        while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
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
        var child = frame.first_child[parent];
        while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
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
        child = frame.first_child[parent];
        while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
            if (!canShrink(Ui, frame, child, axis)) continue;
            const size = frame.size[child][a];
            if (size < largest - tolerance) next_largest = @max(next_largest, size);
        }

        const share = deficit / largest_count;
        var removed: f32 = 0;
        child = frame.first_child[parent];
        while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
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

/// Pass 6: positions follow from the parent's content box, alignment and gap.
fn position(comptime Ui: type, frame: *Ui.Frame) void {
    frame.position[Ui.root_index] = .{ 0, 0 };
    for (0..frame.element_count) |index| {
        const parent: Ui.Index = @intCast(index);
        if (frame.child_count[parent] == 0) continue;
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

        var used = parent_layout.child_gap * @as(f32, @floatFromInt(frame.child_count[parent] - 1));
        var child = frame.first_child[parent];
        while (child != Ui.none_index) : (child = frame.next_sibling[child]) used += frame.size[child][a];

        const free_along = content_along - used;
        var cursor = content_start[a] + if (free_along > 0) free_along * parent_layout.child_alignment.axis(along).fraction() else 0;
        const across_fraction = parent_layout.child_alignment.axis(across).fraction();

        child = frame.first_child[parent];
        while (child != Ui.none_index) : (child = frame.next_sibling[child]) {
            frame.position[child][a] = cursor;
            cursor += frame.size[child][a] + parent_layout.child_gap;
            const free_across = content_across - frame.size[child][b];
            frame.position[child][b] = content_start[b] + if (free_across > 0) free_across * across_fraction else 0;
        }
    }
}

const std = @import("std");
const style = @import("style.zig");
const text = @import("text.zig");
const interaction = @import("interaction.zig");
const parallel_measure = @import("parallel_measure.zig");
const TraceZone = @import("trace.zig").TraceZone;

const Axis = style.Axis;
const tolerance = text.tolerance;
const larger = style.larger;
const smaller = style.smaller;
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
            parallel_measure.prefetch(Ui, ui, frame.texts[text_index..frame.text_count], frame.text_bytes[0..frame.text_bytes_used], frame.params.zoom, Ui.limits.parallel_measure_threshold);
        }
        const content = frame.text_bytes[record.bytes_start..][0..record.bytes_len];
        record.metrics = text.measureText(ui.measurer(record.style, frame.params.zoom), content, record.style.wrap, record.style.line_height, &ui.memory.run_widths, &run_count);
    }
}

/// Iterates the children that take part in a parent's flow.
pub fn FlowChildren(comptime Ui: type) type {
    return struct {
        all_children: Ui.Frame.Children,
        has_floating: bool,

        fn init(frame: *const Ui.Frame, parent: Ui.Index) @This() {
            return .{
                .all_children = frame.children(parent),
                .has_floating = frame.child_counts[parent].in_flow != frame.child_counts[parent].all,
            };
        }

        /// The children from `first` up to the sibling `end`, or the end of
        /// the parent's subtree.
        fn between(frame: *const Ui.Frame, parent: Ui.Index, first: Ui.Index, end: Ui.Index) @This() {
            var children = init(frame, parent);
            children.all_children.next_child = first;
            children.all_children.end = end;
            return children;
        }

        pub fn next(self: *@This()) ?Ui.Index {
            while (self.all_children.next()) |child| {
                if (!self.has_floating or !self.all_children.frame.isFloating(child)) return child;
            }
            return null;
        }
    };
}

/// Iterates a wrapping row's lines, each as the flow children on it, from
/// the line starts that distributing its widths recorded.
pub fn Lines(comptime Ui: type) type {
    return struct {
        frame: *const Ui.Frame,
        row: Ui.Index,
        children: FlowChildren(Ui),
        next_first: ?Ui.Index,

        pub fn init(frame: *const Ui.Frame, row: Ui.Index) @This() {
            var children = FlowChildren(Ui).init(frame, row);
            const first = children.next();
            return .{ .frame = frame, .row = row, .children = children, .next_first = first };
        }

        pub fn next(self: *@This()) ?FlowChildren(Ui) {
            const first = self.next_first orelse return null;
            while (self.children.next()) |child| {
                if (self.frame.starts_line[child]) {
                    self.next_first = child;
                    return .between(self.frame, self.row, first, child);
                }
            }
            self.next_first = null;
            return .between(self.frame, self.row, first, self.frame.subtree_end[self.row]);
        }
    };
}

/// False for every element without `features.flex_wrap`, at compile time.
pub inline fn wraps(comptime Ui: type, frame: *const Ui.Frame, element: Ui.Index) bool {
    return Ui.features.flex_wrap and frame.flags[element].wraps;
}

fn gapsFor(child_gap: f32, flow_count: u32) f32 {
    return if (flow_count == 0) 0 else child_gap * @as(f32, @floatFromInt(flow_count - 1));
}

const ContentSize = struct { preferred: f32, min: f32, sizing: style.Sizing };

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
        const content = if (wraps(Ui, frame, element)) wrappedContentSize(Ui, frame, element, axis) else contentSize(Ui, frame, element, axis);
        const sizing = content.sizing;
        switch (sizing.rule) {
            // `aspect_ratio` shares the arm, and comes after `grow_from_min`
            // so the four are one range of rules: in an arm of its own, the
            // content's sum was made before the `switch`, for `fixed`
            // elements too, or the `switch` became a jump table, and the
            // box tree's `endFrame` was 5.5% slower.
            .fit, .grow, .grow_from_min, .aspect_ratio => if (axis == .y and sizing.rule == .aspect_ratio and sizing.amount > 0) {
                const height = clampSize(frame.size[element][0] / sizing.amount, sizing.min, sizing.max);
                frame.size[element][a] = height;
                frame.min_size[element][a] = height;
            } else fitContent(Ui, frame, element, axis, content),
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
        if (wraps(Ui, frame, parent)) continue;
        if (frame.flags[parent].top_to_bottom == (axis == .y)) {
            frame.size[parent][a] += frame.size[element][a];
            frame.min_size[parent][a] += frame.min_size[element][a];
        } else {
            frame.size[parent][a] = larger(frame.size[parent][a], frame.size[element][a]);
            frame.min_size[parent][a] = larger(frame.min_size[parent][a], frame.min_size[element][a]);
        }
    }
}

/// With the element's sizing, read here once: a text element's is the
/// default layout's, as it never has a layout of its own.
fn contentSize(comptime Ui: type, frame: *const Ui.Frame, element: Ui.Index, comptime axis: Axis) ContentSize {
    const a = @intFromEnum(axis);
    if (Ui.has_text and frame.kindOf(element) == .text) {
        const text_sizing = comptime (style.Layout{}).sizing.axis(axis);
        const record = frame.texts[frame.content_index[element]];
        if (axis == .x) return .{ .preferred = record.metrics.preferred_width, .min = record.metrics.min_width, .sizing = text_sizing };
        const height = @as(f32, @floatFromInt(record.line_count)) * record.metrics.line_height;
        return .{ .preferred = height, .min = height, .sizing = text_sizing };
    }

    const element_layout = frame.layoutOf(element);
    const padding = element_layout.padding.total(axis);
    const gaps = if (element_layout.direction.axis() == axis) gapsFor(element_layout.child_gap, frame.child_counts[element].in_flow) else 0;
    return .{ .preferred = frame.size[element][a] + gaps + padding, .min = frame.min_size[element][a] + gaps + padding, .sizing = element_layout.sizing.axis(axis) };
}

/// A wrapping row is as wide as its children on one line, but no narrower
/// than its widest child, since each may take a line of its own; it is as
/// tall as its lines, each as tall as its tallest child.
fn wrappedContentSize(comptime Ui: type, frame: *const Ui.Frame, row: Ui.Index, comptime axis: Axis) ContentSize {
    const a = @intFromEnum(axis);
    const row_layout = frame.layoutOf(row);
    var preferred: f32 = 0;
    var min: f32 = 0;
    if (axis == .x) {
        var children = FlowChildren(Ui).init(frame, row);
        while (children.next()) |child| {
            preferred += frame.size[child][a];
            min = larger(min, frame.min_size[child][a]);
        }
        preferred += gapsFor(row_layout.child_gap, frame.child_counts[row].in_flow);
    } else {
        var line_count: u32 = 0;
        var lines = Lines(Ui).init(frame, row);
        while (lines.next()) |line| {
            var children = line;
            var line_preferred: f32 = 0;
            var line_min: f32 = 0;
            while (children.next()) |child| {
                line_preferred = larger(line_preferred, frame.size[child][a]);
                line_min = larger(line_min, frame.min_size[child][a]);
            }
            preferred += line_preferred;
            min += line_min;
            line_count += 1;
        }
        const line_gaps = gapsFor(row_layout.child_gap, line_count);
        preferred += line_gaps;
        min += line_gaps;
    }
    const padding = row_layout.padding.total(axis);
    return .{ .preferred = preferred + padding, .min = min + padding, .sizing = row_layout.sizing.axis(axis) };
}

inline fn fitContent(comptime Ui: type, frame: *Ui.Frame, element: Ui.Index, comptime axis: Axis, content: ContentSize) void {
    const a = @intFromEnum(axis);
    const sizing = content.sizing;
    const basis = if (Ui.has_image) naturalImageSize(Ui, frame, element, axis) orelse content else content;
    frame.size[element][a] = clampSize(basis.preferred, sizing.min, sizing.max);
    frame.min_size[element][a] = clampSize(basis.min, sizing.min, sizing.max);
}

/// An image's width may shrink below its natural one, as a column narrower
/// than the image squeezes it; its height then keeps the natural
/// proportions.
fn naturalImageSize(comptime Ui: type, frame: *const Ui.Frame, element: Ui.Index, comptime axis: Axis) ?ContentSize {
    if (frame.kindOf(element) != .image) return null;
    const natural = frame.imageOf(element).natural_size orelse return null;
    const element_layout = frame.layoutOf(element);
    const sizing = element_layout.sizing.axis(axis);
    const padding = element_layout.padding.total(axis);
    if (axis == .x) return .{ .preferred = natural[0] + padding, .min = padding, .sizing = sizing };
    const height = if (natural[0] > 0)
        larger(0, frame.size[element][0] - element_layout.padding.total(.x)) * natural[1] / natural[0]
    else
        natural[1];
    return .{ .preferred = height + padding, .min = height + padding, .sizing = sizing };
}

/// Passes 2 and 5: each parent hands its content box to its children.
fn distribute(comptime Ui: type, frame: *Ui.Frame, comptime axis: Axis) void {
    const a = @intFromEnum(axis);
    for (0..frame.element_count) |index| {
        const parent: Ui.Index = @intCast(index);
        if (frame.child_counts[parent].all == 0) continue;
        const parent_layout = frame.layoutOf(parent);
        const padding = parent_layout.padding.total(axis);
        const content_box = larger(0, frame.size[parent][a] - padding);
        const scrolls = frame.flags[parent].scrolls(axis);

        if (frame.child_counts[parent].in_flow != frame.child_counts[parent].all) @call(.never_inline, sizeFloatingChildren, .{ Ui, frame, parent, axis });

        if (wraps(Ui, frame, parent)) {
            if (axis == .x) @call(.never_inline, breakLines, .{ Ui, frame, parent }) else @call(.never_inline, stretchLines, .{ Ui, frame, parent });
            continue;
        }

        if (parent_layout.direction.axis() != axis) {
            var widest: f32 = 0;
            var children = FlowChildren(Ui).init(frame, parent);
            while (children.next()) |child| {
                const sizing = frame.sizingOf(child, axis);
                frame.size[child][a] = switch (sizing.rule) {
                    .fixed, .aspect_ratio => frame.size[child][a],
                    .grow, .grow_from_min => larger(frame.min_size[child][a], clampSize(content_box, sizing.min, sizing.max)),
                    .percent => clampSize(content_box * sizing.amount, sizing.min, sizing.max),
                    .fit => if (!scrolls and frame.size[child][a] > content_box) larger(frame.min_size[child][a], content_box) else frame.size[child][a],
                };
                widest = larger(widest, frame.size[child][a]);
            }
            frame.content_size[parent][a] = widest + padding;
            continue;
        }

        var used = gapsFor(parent_layout.child_gap, frame.child_counts[parent].in_flow);
        var grow_weight: f32 = 0;
        var any_grow_max = false;
        var any_grow_from_min = false;
        var children = FlowChildren(Ui).init(frame, parent);
        while (children.next()) |child| {
            const sizing = frame.sizingOf(child, axis);
            switch (sizing.rule) {
                .percent => frame.size[child][a] = clampSize(content_box * sizing.amount, sizing.min, sizing.max),
                .grow => if (sizing.amount > 0) {
                    grow_weight += sizing.amount;
                    any_grow_max = any_grow_max or sizing.max != std.math.inf(f32);
                },
                // Held at its minimum, the floor it grows past from `min`.
                .grow_from_min => {
                    grow_weight += sizing.amount;
                    any_grow_from_min = true;
                    frame.size[child][a] = frame.min_size[child][a];
                },
                .fit, .fixed, .aspect_ratio => {},
            }
            used += frame.size[child][a];
        }

        const remaining = content_box - used;
        if (remaining > tolerance and grow_weight > 0) {
            if (any_grow_from_min) {
                used += @call(.never_inline, growFromMin, .{ Ui, frame, FlowChildren(Ui).init(frame, parent), frame.child_counts[parent].in_flow, axis, remaining });
            } else if (any_grow_max) {
                used += grow(Ui, frame, .init(frame, parent), axis, remaining);
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
            used -= shrink(Ui, frame, .init(frame, parent), frame.child_counts[parent].all, axis, -remaining);
        }
        frame.content_size[parent][a] = used + padding;
    }
}

/// What a line's children ask of its axis before free space is handed out.
/// `distribute` keeps its own copy of these steps for a row that does not
/// wrap: sharing them made the box tree's `endFrame` 1.5% more instructions.
const FlowTotals = struct {
    used: f32 = 0,
    grow_weight: f32 = 0,
    any_grow_max: bool = false,
    any_grow_from_min: bool = false,

    fn join(self: *FlowTotals, other: FlowTotals, gap: f32) void {
        self.used += gap + other.used;
        self.grow_weight += other.grow_weight;
        self.any_grow_max = self.any_grow_max or other.any_grow_max;
        self.any_grow_from_min = self.any_grow_from_min or other.any_grow_from_min;
    }
};

/// Sizes a `percent` child from the content box and holds a
/// `grow_from_min` child at its minimum, the floor it grows past from
/// `min`, then adds the child to the totals.
inline fn resolveFlowChild(comptime Ui: type, frame: *Ui.Frame, child: Ui.Index, comptime axis: Axis, content_box: f32, totals: *FlowTotals) void {
    const a = @intFromEnum(axis);
    const sizing = frame.sizingOf(child, axis);
    switch (sizing.rule) {
        .percent => frame.size[child][a] = clampSize(content_box * sizing.amount, sizing.min, sizing.max),
        .grow => if (sizing.amount > 0) {
            totals.grow_weight += sizing.amount;
            totals.any_grow_max = totals.any_grow_max or sizing.max != std.math.inf(f32);
        },
        .grow_from_min => {
            totals.grow_weight += sizing.amount;
            totals.any_grow_from_min = true;
            frame.size[child][a] = frame.min_size[child][a];
        },
        .fit, .fixed, .aspect_ratio => {},
    }
    totals.used += frame.size[child][a];
}

/// Hands the free space to the growing children, or takes the overflow
/// from the shrinkable ones. Returns the size the flow ends up using.
inline fn settleFlow(comptime Ui: type, frame: *Ui.Frame, children: FlowChildren(Ui), flow_count: usize, comptime axis: Axis, content_box: f32, totals: FlowTotals, scrolls: bool) f32 {
    const a = @intFromEnum(axis);
    var used = totals.used;
    const remaining = content_box - used;
    if (remaining > tolerance and totals.grow_weight > 0) {
        if (totals.any_grow_from_min) {
            used += @call(.never_inline, growFromMin, .{ Ui, frame, children, flow_count, axis, remaining });
        } else if (totals.any_grow_max) {
            used += grow(Ui, frame, children, axis, remaining);
        } else {
            // No child can reach a max, so the space divides in one go.
            var growing = children;
            while (growing.next()) |child| {
                const sizing = frame.sizingOf(child, axis);
                if (sizing.rule == .grow) frame.size[child][a] += remaining * sizing.amount / totals.grow_weight;
            }
            used = content_box;
        }
    } else if (remaining < -tolerance and !scrolls) {
        used -= shrink(Ui, frame, children, flow_count, axis, -remaining);
    }
    return used;
}

/// Pass 2 for a wrapping row: each child goes on the current line if it
/// fits there at the size its rule asks for before free space is handed
/// out, and otherwise starts a new line, as a first child always does.
/// Each line then shares its free space or overflow as a row would.
fn breakLines(comptime Ui: type, frame: *Ui.Frame, row: Ui.Index) void {
    const row_layout = frame.layoutOf(row);
    const padding = row_layout.padding.total(.x);
    const content_box = larger(0, frame.size[row][0] - padding);
    const gap = row_layout.child_gap;
    const scrolls = frame.flags[row].scroll_x;
    var widest_line: f32 = 0;
    var line: FlowTotals = .{};
    var line_first: Ui.Index = undefined;
    var line_count: u32 = 0;
    var children = FlowChildren(Ui).init(frame, row);
    while (children.next()) |child| {
        var child_totals: FlowTotals = .{};
        resolveFlowChild(Ui, frame, child, .x, content_box, &child_totals);
        const starts_line = line_count == 0 or line.used + gap + child_totals.used > content_box + tolerance;
        frame.starts_line[child] = starts_line;
        if (!starts_line) {
            line.join(child_totals, gap);
            line_count += 1;
            continue;
        }
        if (line_count > 0) widest_line = larger(widest_line, settleFlow(Ui, frame, .between(frame, row, line_first, child), line_count, .x, content_box, line, scrolls));
        line = child_totals;
        line_first = child;
        line_count = 1;
    }
    if (line_count > 0) widest_line = larger(widest_line, settleFlow(Ui, frame, .between(frame, row, line_first, frame.subtree_end[row]), line_count, .x, content_box, line, scrolls));
    frame.content_size[row][0] = widest_line + padding;
}

/// Pass 5 for a wrapping row: a line is as tall as its tallest child, and
/// a growing child stretches to its line's height, not the row's.
fn stretchLines(comptime Ui: type, frame: *Ui.Frame, row: Ui.Index) void {
    const row_layout = frame.layoutOf(row);
    const padding = row_layout.padding.total(.y);
    const content_box = larger(0, frame.size[row][1] - padding);
    var lines_height: f32 = 0;
    var line_count: u32 = 0;
    var lines = Lines(Ui).init(frame, row);
    while (lines.next()) |line| {
        var line_height: f32 = 0;
        var children = line;
        while (children.next()) |child| {
            const sizing = frame.sizingOf(child, .y);
            if (sizing.rule == .percent) frame.size[child][1] = clampSize(content_box * sizing.amount, sizing.min, sizing.max);
            line_height = larger(line_height, frame.size[child][1]);
        }
        var stretched_height = line_height;
        children = line;
        while (children.next()) |child| {
            const sizing = frame.sizingOf(child, .y);
            if (!sizing.rule.grows()) continue;
            frame.size[child][1] = larger(frame.min_size[child][1], clampSize(line_height, sizing.min, sizing.max));
            stretched_height = larger(stretched_height, frame.size[child][1]);
        }
        lines_height += stretched_height;
        line_count += 1;
    }
    frame.content_size[row][1] = lines_height + gapsFor(row_layout.child_gap, line_count) + padding;
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
            .root => frame.params.viewport[a],
            .parent, .element => frame.size[parent][a],
        };
        const sizing = frame.sizingOf(child, axis);
        switch (sizing.rule) {
            .grow, .grow_from_min => frame.size[child][a] = larger(frame.min_size[child][a], clampSize(reference, sizing.min, sizing.max)),
            .percent => frame.size[child][a] = clampSize(reference * sizing.amount, sizing.min, sizing.max),
            .fit, .fixed, .aspect_ratio => {},
        }
    }
}

/// Free space goes to `grow` children in proportion to their weights. A
/// child that reaches its max is clamped and the rest is redistributed;
/// each round clamps at least one child, so this ends. Returns the space
/// handed out.
fn grow(comptime Ui: type, frame: *Ui.Frame, flow: FlowChildren(Ui), comptime axis: Axis, free_space: f32) f32 {
    const a = @intFromEnum(axis);
    var remaining = free_space;
    while (remaining > tolerance) {
        var total_weight: f32 = 0;
        var children = flow;
        while (children.next()) |child| {
            if (canGrow(Ui, frame, child, axis)) total_weight += frame.sizingOf(child, axis).amount;
        }
        if (total_weight <= 0) return free_space - remaining;

        var clamped_any = false;
        children = flow;
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

        children = flow;
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

/// With a `.grow_from_min` child among them, free space goes to growing
/// children by weight, one `share` for all: each ends at
/// `clamp(start + share × weight, floor, max)`. A `.grow` child
/// starts at its content's size, which is also its floor; a
/// `.grow_from_min` child starts at its `min` and is held at its floor, the
/// content's minimum, until the share passes it. `share` rises from 0
/// through each point where a child leaves its floor or reaches its max,
/// until the free space is filled, so each child bends at most twice and
/// this ends. Returns the space handed out.
fn growFromMin(comptime Ui: type, frame: *Ui.Frame, flow: FlowChildren(Ui), flow_count: usize, comptime axis: Axis, free_space: f32) f32 {
    const a = @intFromEnum(axis);
    var share: f32 = 0;
    var bends_left = 2 * flow_count + 1;
    while (bends_left > 0) : (bends_left -= 1) {
        var handed_out: f32 = 0;
        var growing_weight: f32 = 0;
        var next_bend = std.math.inf(f32);
        var children = flow;
        while (children.next()) |child| {
            const sizing = frame.sizingOf(child, axis);
            if (!sizing.rule.grows() or sizing.amount <= 0) continue;
            const floor = frame.size[child][a];
            const start = growStart(sizing, floor);
            const unclamped = start + share * sizing.amount;
            if (unclamped < floor - tolerance) {
                next_bend = smaller(next_bend, (floor - start) / sizing.amount);
            } else if (unclamped >= sizing.max - tolerance) {
                handed_out += sizing.max - floor;
            } else {
                handed_out += unclamped - floor;
                growing_weight += sizing.amount;
                next_bend = smaller(next_bend, (sizing.max - start) / sizing.amount);
            }
        }
        const missing = free_space - handed_out;
        if (missing <= tolerance) break;
        if (growing_weight > 0 and share + missing / growing_weight <= next_bend) {
            share += missing / growing_weight;
            break;
        }
        if (next_bend == std.math.inf(f32)) break;
        share = next_bend;
    }

    var handed_out: f32 = 0;
    var children = flow;
    while (children.next()) |child| {
        const sizing = frame.sizingOf(child, axis);
        if (!sizing.rule.grows() or sizing.amount <= 0) continue;
        const floor = frame.size[child][a];
        const grown = clampSize(growStart(sizing, floor) + share * sizing.amount, floor, sizing.max);
        handed_out += grown - floor;
        frame.size[child][a] = grown;
    }
    return handed_out;
}

inline fn growStart(sizing: style.Sizing, floor: f32) f32 {
    return if (sizing.rule == .grow_from_min) sizing.min else floor;
}

/// Overflow is taken from the largest shrinkable children first, levelling
/// them down to the next largest, never below a child's minimum. Each
/// round levels a group, resolves the deficit, or retires a child at its
/// minimum, so this ends. Returns the size taken away.
fn shrink(comptime Ui: type, frame: *Ui.Frame, flow: FlowChildren(Ui), flow_count: usize, comptime axis: Axis, overflow: f32) f32 {
    const a = @intFromEnum(axis);
    var deficit = overflow;
    var rounds: usize = 0;
    const max_rounds = 2 * flow_count + 2;
    while (deficit > tolerance and rounds < max_rounds) : (rounds += 1) {
        var largest: f32 = 0;
        var largest_count: f32 = 0;
        var children = flow;
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
        children = flow;
        while (children.next()) |child| {
            if (!canShrink(Ui, frame, child, axis)) continue;
            const size = frame.size[child][a];
            if (size < largest - tolerance) next_largest = larger(next_largest, size);
        }

        const share = deficit / largest_count;
        var removed: f32 = 0;
        children = flow;
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
            text.measurePendingRuns(ui.measurer(record.style, frame.params.zoom), content, record.style.wrap, record.metrics, &ui.memory.run_widths);
        }
        record.first_line = frame.line_count;
        const fitted = if (Ui.segments_text)
            text.wrapSegmentedLines(ui.segmenter(), content, record.bytes_start, record.style.wrap, record.metrics, &ui.memory.run_widths, frame.size[element][0], &frame.lines, &frame.line_count)
        else
            text.wrapLines(content, record.bytes_start, record.style.wrap, record.metrics, &ui.memory.run_widths, frame.size[element][0], &frame.lines, &frame.line_count);
        record.line_count = frame.line_count - record.first_line;
        if (!fitted) {
            frame.diagnostics.exceeded.insert(.max_render_commands);
            if (frame.diagnostics.first_dropped_id == 0) frame.diagnostics.first_dropped_id = frame.element_id[element];
        }
    }
}

/// Pass 6, one forward pass in declaration order. Parents come before
/// their children, so an element's position is final when it is reached,
/// and it places its flow children then. A floating element is placed when
/// it is reached, against its target, which is already placed if declared
/// earlier; one whose target comes later is placed against its parent
/// first, and again with its subtree once the pass has placed the target.
///
/// Until it meets a parent that mirrors its children, the pass runs
/// without working out which elements are mirrored, so a frame without
/// one pays only for looking. When it meets one, it starts again,
/// mirroring. Only a parent's mirroring moves anything: a leaf's places
/// nothing, and a floating element's anchors follow its parent's.
fn position(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    if (!frame.may_mirror and positionUnlessMirrored(Ui, ui, frame, false)) return;
    frame.may_mirror = true;
    @call(.never_inline, positionMirrored, .{ Ui, ui, frame });
}

fn positionMirrored(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    _ = positionUnlessMirrored(Ui, ui, frame, true);
}

/// Returns false, having placed only some elements, when `may_mirror` is
/// false and a parent mirrors its children.
inline fn positionUnlessMirrored(comptime Ui: type, ui: *Ui, frame: *Ui.Frame, comptime may_mirror: bool) bool {
    frame.position[Ui.root_index] = .{ 0, 0 };
    var first_with_later_target: ?Ui.Index = null;
    for (0..frame.element_count) |index| {
        const element: Ui.Index = @intCast(index);
        if (may_mirror) resolveMirroring(Ui, ui, frame, element);
        if (frame.isFloating(element)) @call(.never_inline, placeFloatingInPass, .{ Ui, frame, element, &first_with_later_target, may_mirror });
        if (frame.child_counts[element].all == 0) continue;
        if (!may_mirror and mirrorsChildren(frame.layoutOf(element))) return false;
        placeChildrenOf(Ui, ui, frame, element, may_mirror);
    }
    if (first_with_later_target) |first| @call(.never_inline, placeAfterLaterTargets, .{ Ui, ui, frame, first, may_mirror });
    return true;
}

inline fn mirrorsChildren(element_layout: *const style.Layout) bool {
    return element_layout.direction == .right_to_left or element_layout.mirrored != .inherit;
}

/// Parents come first, so the parent's mirroring is already known. A
/// reversed text's lines are aligned by swapping its alignment's start and
/// end.
fn resolveMirroring(comptime Ui: type, ui: *const Ui, frame: *Ui.Frame, element: Ui.Index) void {
    const element_layout = frame.layoutOf(element);
    const flags = &frame.flags[element];
    flags.mirrored = switch (element_layout.mirrored) {
        .yes => true,
        .no => false,
        .inherit => if (element == Ui.root_index)
            ui.environment().direction == .right_to_left
        else
            frame.flags[frame.parent[element]].mirrored,
    };
    flags.reversed = flags.mirrored != (element_layout.direction == .right_to_left);
    if (Ui.has_text and flags.reversed and frame.kindOf(element) == .text) {
        const alignment = &frame.texts[frame.content_index[element]].style.alignment;
        alignment.* = switch (alignment.*) {
            .start => .end,
            .center => .center,
            .end => .start,
        };
    }
}

fn placeFloatingInPass(comptime Ui: type, frame: *Ui.Frame, floating: Ui.Index, first_with_later_target: *?Ui.Index, comptime may_mirror: bool) void {
    if (!placeFloating(Ui, frame, floating, .earlier_targets, may_mirror) and first_with_later_target.* == null) first_with_later_target.* = floating;
}

inline fn placeChildrenOf(comptime Ui: type, ui: *Ui, frame: *Ui.Frame, parent: Ui.Index, comptime may_mirror: bool) void {
    if (wraps(Ui, frame, parent)) return @call(.never_inline, placeLines, .{ Ui, ui, frame, parent, may_mirror });
    switch (frame.flags[parent].top_to_bottom) {
        inline else => |top_to_bottom| placeChildren(Ui, ui, frame, parent, if (top_to_bottom) .y else .x, may_mirror),
    }
}

/// A wrapping row's lines go down from the top of its content box. The
/// alignment's `y` places them as a group and each child within its line,
/// and its `x` places each line along the row. A reversed row reflects its
/// children across its box, as `placeChildren` does.
fn placeLines(comptime Ui: type, ui: *Ui, frame: *Ui.Frame, row: Ui.Index, comptime may_mirror: bool) void {
    const row_layout = frame.layoutOf(row);
    const padding = row_layout.padding;
    const gap = row_layout.child_gap;
    const along_fraction = row_layout.child_alignment.x.fraction();
    const across_fraction = row_layout.child_alignment.y.fraction();
    const offset = scrollOffset(Ui, ui, frame, row);
    const content_width = frame.size[row][0] - padding.total(.x);
    const line_start = frame.position[row][0] + padding.left - offset[0];
    const free_height = frame.size[row][1] - frame.content_size[row][1];
    var line_top = frame.position[row][1] + padding.top - offset[1] + if (free_height > 0) free_height * across_fraction else 0;
    const reversed = may_mirror and frame.flags[row].reversed;
    const reflected_sum = 2 * frame.position[row][0] + frame.size[row][0];

    var lines = Lines(Ui).init(frame, row);
    while (lines.next()) |line| {
        var line_width = -gap;
        var line_height: f32 = 0;
        var children = line;
        while (children.next()) |child| {
            line_width += frame.size[child][0] + gap;
            line_height = larger(line_height, frame.size[child][1]);
        }
        const free_width = content_width - line_width;
        var next_x = line_start + if (free_width > 0) free_width * along_fraction else 0;
        children = line;
        while (children.next()) |child| {
            const size = frame.size[child];
            const free_across = line_height - size[1];
            var placed: [2]f32 = .{ next_x, line_top + if (free_across > 0) free_across * across_fraction else 0 };
            if (reversed) placed[0] = reflected_sum - placed[0] - size[0];
            frame.position[child] = placed;
            next_x += size[0] + gap;
        }
        line_top += line_height + gap;
    }
}

/// Places each floating subtree whose target was declared after it, in
/// declaration order, so a subtree nested in another is placed after the
/// one it moves with. A target inside a floating subtree that is itself
/// placed here later is taken where that subtree was first placed.
fn placeAfterLaterTargets(comptime Ui: type, ui: *Ui, frame: *Ui.Frame, first: Ui.Index, comptime may_mirror: bool) void {
    for (first..frame.element_count) |index| {
        const floating: Ui.Index = @intCast(index);
        if (!frame.isFloating(floating)) continue;
        const target = targetOf(Ui, frame, floating) orelse continue;
        if (target < floating) continue;
        _ = placeFloating(Ui, frame, floating, .all_targets, may_mirror);
        for (floating..frame.subtree_end[floating]) |subtree_index| {
            const element: Ui.Index = @intCast(subtree_index);
            if (element != floating and frame.isFloating(element)) _ = placeFloating(Ui, frame, element, .all_targets, may_mirror);
            if (frame.child_counts[element].all != 0) placeChildrenOf(Ui, ui, frame, element, may_mirror);
        }
    }
}

/// Specialized by the flow's axis, so no coordinate is indexed at run time.
/// A reversed parent places its children as if it were not, then reflects
/// them across its box, which carries its padding, alignment and scroll
/// offset over with them.
inline fn placeChildren(comptime Ui: type, ui: *Ui, frame: *Ui.Frame, parent: Ui.Index, comptime flow_axis: Axis, comptime may_mirror: bool) void {
    const along = @intFromEnum(flow_axis);
    const across = 1 - along;
    const parent_layout = frame.layoutOf(parent);
    const padding_start = [2]f32{ parent_layout.padding.left, parent_layout.padding.top };
    const across_axis: Axis = if (flow_axis == .x) .y else .x;
    const along_fraction = parent_layout.child_alignment.axis(flow_axis).fraction();
    const across_fraction = parent_layout.child_alignment.axis(across_axis).fraction();
    const gap = parent_layout.child_gap;

    const offset = scrollOffset(Ui, ui, frame, parent);
    const free_along = frame.size[parent][along] - frame.content_size[parent][along];
    var next_along = frame.position[parent][along] + padding_start[along] - offset[along] + if (free_along > 0) free_along * along_fraction else 0;
    const across_start = frame.position[parent][across] + padding_start[across] - offset[across];
    const across_space = frame.size[parent][across] - parent_layout.padding.total(across_axis);
    const reversed = may_mirror and frame.flags[parent].reversed;
    const reflected_sum = 2 * frame.position[parent][0] + frame.size[parent][0];

    var children = FlowChildren(Ui).init(frame, parent);
    while (children.next()) |child| {
        const size = frame.size[child];
        const free_across = across_space - size[across];
        var placed: [2]f32 = undefined;
        placed[along] = next_along;
        placed[across] = across_start + if (free_across > 0) free_across * across_fraction else 0;
        if (reversed) placed[0] = reflected_sum - placed[0] - size[0];
        frame.position[child] = placed;
        next_along += size[along] + gap;
    }
}

/// The element a floating element attaches to, or null for the viewport.
/// A target that does not exist, or lies inside the floating element's own
/// subtree, falls back to the parent: the subtree's position would depend
/// on itself.
pub fn targetOf(comptime Ui: type, frame: *const Ui.Frame, floating: Ui.Index) ?Ui.Index {
    const parent = frame.parent[floating];
    return switch (frame.floatingOf(floating).attach_to) {
        .parent => parent,
        .root => null,
        .element => |target_id| if (frame.lookup(target_id.hash)) |target|
            (if (target < floating or target >= frame.subtree_end[floating]) target else parent)
        else
            parent,
    };
}

const PlacedTargets = enum { earlier_targets, all_targets };

/// Returns false when the target comes later and is not placed yet, in
/// which case the element is placed against its parent for now.
/// A reversed parent reflects its floating children's anchors, attach
/// points and offsets across the box they attach to.
fn placeFloating(comptime Ui: type, frame: *Ui.Frame, floating: Ui.Index, comptime placed: PlacedTargets, comptime may_mirror: bool) bool {
    const config = frame.floatingOf(floating);
    const parent = frame.parent[floating];
    var placed_against_target = true;
    var target_position: [2]f32 = .{ 0, 0 };
    var target_size = frame.params.viewport;
    if (targetOf(Ui, frame, floating)) |found| {
        var target = found;
        if (placed == .earlier_targets and target > floating) {
            placed_against_target = false;
            target = parent;
        }
        target_position = frame.position[target];
        target_size = frame.size[target];
    }
    const attach = config.attach_point.fractions();
    const anchor = config.anchor.fractions();
    for (0..2) |a| {
        frame.position[floating][a] = target_position[a] + target_size[a] * attach[a] - frame.size[floating][a] * anchor[a] + config.offset[a];
    }
    if (may_mirror and frame.flags[parent].reversed) {
        frame.position[floating][0] = 2 * target_position[0] + target_size[0] - frame.position[floating][0] - frame.size[floating][0];
    }
    return placed_against_target;
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

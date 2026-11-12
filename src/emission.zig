const std = @import("std");
const style = @import("style.zig");
const interaction = @import("interaction.zig");
const layout = @import("layout.zig");

/// An open element whose subtree is drawn differently from its parent's:
/// it clips, has a border to draw after its children, floats, is a hit
/// region, or is a focus scope. Other elements open no level.
pub fn EmitLevel(comptime Index: type) type {
    return struct {
        element: Index,
        /// One past the last element of the subtree.
        subtree_end: Index,
        /// Clip in effect for this element's own commands and its children.
        clip: style.Rect,
        /// Clip in effect before this element's own clip, which culls the
        /// element and its border.
        outer_clip: style.Rect,
        /// The subtree ends a clip after its border.
        pushed_clip: bool,
        z: i16,
        region: u32,
        focus_scope: u64,
    };
}

/// Pass 7: render commands in paint order, plus the hit regions, the
/// id → rect results and the focus order that the next frame's
/// interaction queries read. Elements are visited in declaration order,
/// which is depth-first order. A background and content are emitted when
/// an element is entered, its dividers and border when its subtree ends, so
/// they paint over the element's children. Elements entirely outside the clip
/// are not drawn.
pub fn run(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    const emitting = Ui.Tracing.begin(.emit);
    const results = &ui.memory.results;
    results.clear();
    var emitter: Emitter(Ui) = .{ .frame = frame, .results = results, .pixels_per_unit = frame.pixels_per_unit, .units_per_pixel = 1 / frame.pixels_per_unit };

    const viewport: style.Rect = .{ .width = frame.params.viewport[0], .height = frame.params.viewport[1] };
    const levels = &ui.emit_levels;
    levels[0] = .{
        .element = Ui.root_index,
        .subtree_end = @intCast(frame.element_count),
        .clip = viewport,
        .outer_clip = viewport,
        .pushed_clip = false,
        .z = 0,
        .region = interaction.no_region,
        .focus_scope = 0,
    };
    results.insert(frame.element_id[Ui.root_index], emitter.rectOf(Ui.root_index), interaction.no_region);

    var depth: usize = 0;
    for (1..frame.element_count) |index| {
        const element: Ui.Index = @intCast(index);
        while (levels[depth].subtree_end <= element) : (depth -= 1) emitter.leave(&levels[depth], levels[depth - 1].z);
        if (!frame.flags[element].emits() and frame.decorationOf(element) == null and frame.kindOf(element) == .none) continue;
        if (emitter.enter(element, levels[depth], viewport)) |level| {
            depth += 1;
            levels[depth] = level;
        }
    }
    while (true) : (depth -= 1) {
        emitter.leave(&levels[depth], if (depth == 0) 0 else levels[depth - 1].z);
        if (depth == 0) break;
    }
    frame.diagnostics.needed.set(.max_render_commands, emitter.attempted_commands);
    emitting.end();

    if (emitter.layered_run_count != 0 or emitter.layered_runs_overflowed) {
        const sorting = Ui.Tracing.begin(.sort_layers);
        defer sorting.end();
        emitter.sortLayers();
    }
}

fn lowerLayer(comptime Ui: type) fn (void, Ui.RenderCommand, Ui.RenderCommand) bool {
    return struct {
        fn lessThan(_: void, a: Ui.RenderCommand, b: Ui.RenderCommand) bool {
            return a.z < b.z;
        }
    }.lessThan;
}

fn Emitter(comptime Ui: type) type {
    return struct {
        const Self = @This();
        const Level = EmitLevel(Ui.Index);

        frame: *Ui.Frame,
        results: *Ui.Results,
        pixels_per_unit: f32,
        /// Multiplied rather than dividing by `pixels_per_unit`: snapping
        /// runs for every command, and a division costs several multiplies.
        units_per_pixel: f32,
        /// Reported as `needed.render_commands` once emission ends.
        attempted_commands: u32 = 0,
        /// Each run of commands in one layer other than 0, in the order
        /// emitted, so sorting moves only what is out of place. Past
        /// `max_layered_runs`, the whole frame is sorted instead.
        layered_runs: [max_layered_runs]LayeredRun = undefined,
        layered_run_count: u32 = 0,
        current_z: i16 = 0,
        layered_out_of_order: bool = false,
        layered_runs_overflowed: bool = false,

        const max_layered_runs = 64;
        const LayeredRun = struct { start: u32, end: u32, z: i16 };

        fn rectOf(self: *const Self, element: Ui.Index) style.Rect {
            return .{
                .x = self.frame.position[element][0],
                .y = self.frame.position[element][1],
                .width = self.frame.size[element][0],
                .height = self.frame.size[element][1],
            };
        }

        /// To whole physical pixels.
        fn snap(self: *const Self, rect: style.Rect) style.Rect {
            const scale = self.pixels_per_unit;
            const inverse = self.units_per_pixel;
            const left = @round(rect.x * scale) * inverse;
            const top = @round(rect.y * scale) * inverse;
            const right = @round((rect.x + rect.width) * scale) * inverse;
            const bottom = @round((rect.y + rect.height) * scale) * inverse;
            return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
        }

        fn push(self: *Self, command: Ui.RenderCommand) void {
            const frame = self.frame;
            self.attempted_commands += 1;
            if (frame.command_count >= frame.render_commands.len) {
                frame.diagnostics.exceeded.insert(.max_render_commands);
                if (frame.diagnostics.first_dropped_id == 0) frame.diagnostics.first_dropped_id = command.id;
                return;
            }
            frame.render_commands[frame.command_count] = command;
            frame.command_count += 1;
        }

        /// Called where the layer can change: entering a floating element,
        /// and leaving one for its parent's layer.
        fn switchLayer(self: *Self, z: i16) void {
            if (z == self.current_z) return;
            const here = self.frame.command_count;
            if (self.current_z != 0) self.endLayeredRun(here);
            self.current_z = z;
            if (z == 0) return;
            if (self.layered_run_count != 0) {
                const previous = &self.layered_runs[self.layered_run_count - 1];
                if (previous.end == here and previous.z == z) {
                    previous.end = std.math.maxInt(u32);
                    return;
                }
                self.layered_out_of_order = self.layered_out_of_order or z < previous.z;
            }
            if (self.layered_run_count == max_layered_runs) {
                self.layered_runs_overflowed = true;
                return;
            }
            self.layered_runs[self.layered_run_count] = .{ .start = here, .end = std.math.maxInt(u32), .z = z };
            self.layered_run_count += 1;
        }

        fn endLayeredRun(self: *Self, here: u32) void {
            if (self.layered_run_count == 0) return;
            const layered_run = &self.layered_runs[self.layered_run_count - 1];
            if (layered_run.end != std.math.maxInt(u32)) return;
            layered_run.end = here;
            if (layered_run.start == here) self.layered_run_count -= 1;
        }

        /// Reorders the commands as a stable sort by layer would. The
        /// layered runs are gathered in the unused end of the commands, so
        /// layer 0's commands each move at most once, and not at all when
        /// they all come before every layered run.
        fn sortLayers(self: *Self) void {
            const frame = self.frame;
            const commands = frame.render_commands[0..frame.command_count];
            const runs = self.layered_runs[0..self.layered_run_count];
            var layered_count: usize = 0;
            for (runs) |layered_run| layered_count += layered_run.end - layered_run.start;
            const fits = !self.layered_runs_overflowed and frame.render_commands.len - commands.len >= layered_count;
            if (!fits) return std.sort.block(Ui.RenderCommand, commands, {}, lowerLayer(Ui));
            if (layered_count == 0) return;

            const gathered = frame.render_commands[frame.render_commands.len - layered_count ..];
            var gathered_count: usize = 0;
            var layer_zero_count: usize = runs[0].start;
            for (runs, 0..) |layered_run, index| {
                @memcpy(gathered[gathered_count..][0 .. layered_run.end - layered_run.start], commands[layered_run.start..layered_run.end]);
                gathered_count += layered_run.end - layered_run.start;
                const layer_zero_end = if (index + 1 < runs.len) runs[index + 1].start else commands.len;
                std.mem.copyForwards(Ui.RenderCommand, frame.render_commands[layer_zero_count..], commands[layered_run.end..layer_zero_end]);
                layer_zero_count += layer_zero_end - layered_run.end;
            }
            if (self.layered_out_of_order) std.sort.block(Ui.RenderCommand, gathered, {}, lowerLayer(Ui));
            const below_count = for (gathered, 0..) |command, index| {
                if (command.z > 0) break index;
            } else gathered.len;

            std.mem.copyForwards(Ui.RenderCommand, frame.render_commands[layer_zero_count..], gathered);
            if (below_count != 0) std.mem.rotate(Ui.RenderCommand, frame.render_commands[0 .. layer_zero_count + below_count], layer_zero_count);
        }

        /// Returns the level the element's subtree is drawn in, or null if
        /// that is the parent's level unchanged.
        fn enter(self: *Self, element: Ui.Index, parent: Level, viewport: style.Rect) ?Level {
            const frame = self.frame;
            const flags = frame.flags[element];
            const floating = flags.floating;
            const element_id = frame.element_id[element];
            const bounds = self.rectOf(element);
            var layer: Layer = .{ .clip = parent.clip, .z = parent.z };
            if (floating) layer = self.floatingLayer(element, parent.clip, viewport);
            const outer_clip = layer.clip;
            var level: Level = .{
                .element = element,
                .subtree_end = frame.subtree_end[element],
                .clip = outer_clip,
                .outer_clip = outer_clip,
                .pushed_clip = false,
                .z = layer.z,
                .region = parent.region,
                .focus_scope = if (flags.focus_scope) element_id else parent.focus_scope,
            };
            const visible = bounds.intersect(outer_clip);
            const drawn = !visible.isEmpty();

            if (drawn) if (frame.decorationOf(element)) |decoration| if (decoration.background) |color| {
                self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = level.z, .payload = .{ .rectangle = .{ .color = color, .corner_radius = decoration.corner_radius } } });
            };

            switch (frame.kindOf(element)) {
                .none => {},
                .image => if (Ui.RenderCommand.has_image and drawn) {
                    const image = frame.imageOf(element);
                    self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = level.z, .payload = .{ .image = .{ .handle = image.handle, .tint = image.tint, .corner_radius = image.corner_radius } } });
                },
                .custom => if (Ui.RenderCommand.has_custom and drawn) self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = level.z, .payload = .{ .custom = frame.customs[frame.content_index[element]] } }),
                .text => if (Ui.has_text) self.emitText(element, element_id, level),
            }

            if (flags.interactive or flags.scroll_x or flags.scroll_y or flags.disabled or flags.captures_pointer) {
                level.region = self.addRegion(element, visible, level.z, parent.region);
            }
            if (flags.explicit_id) self.results.insert(element_id, bounds, if (level.region != parent.region) level.region else interaction.no_region);
            if (flags.focusable and !flags.disabled) {
                self.results.focusables[self.results.focusable_count] = .{ .hash = element_id, .scope = parent.focus_scope };
                self.results.focusable_count += 1;
            }

            if (flags.clipsOrClipsToTarget()) {
                level.pushed_clip = true;
                if (!flags.clips_to_target) {
                    level.clip = outer_clip.intersect(clipBox(flags, bounds, outer_clip));
                    self.push(.{ .bounds = self.snap(level.clip), .id = element_id, .z = level.z, .payload = .{ .clip_begin = self.snap(level.clip) } });
                }
            }
            const has_border = if (frame.decorationOf(element)) |decoration| decoration.border != null else false;
            if (!level.pushed_clip and !has_border and !floating and level.region == parent.region and !flags.focus_scope) return null;
            return level;
        }

        const Layer = struct { clip: style.Rect, z: i16 };

        /// A floating element's layer and clip. Cut off by its target's
        /// clip, it pushes that clip merged with its own before it draws:
        /// its own box holds everything it draws itself.
        fn floatingLayer(self: *Self, floating: Ui.Index, parent_clip: style.Rect, viewport: style.Rect) Layer {
            const frame = self.frame;
            const config = frame.floatingOf(floating);
            self.switchLayer(config.z);
            if (config.clip == .none) return .{ .clip = viewport, .z = config.z };
            const target_clip = self.floatingTargetClip(floating, parent_clip, viewport);
            const clip = target_clip.intersect(clipBox(frame.flags[floating], self.rectOf(floating), target_clip));
            self.push(.{ .bounds = self.snap(clip), .id = frame.element_id[floating], .z = config.z, .payload = .{ .clip_begin = self.snap(clip) } });
            return .{ .clip = clip, .z = config.z };
        }

        /// A floating element that captures gets a region even when it is
        /// not interactive: on a higher layer, it wins the hit test over
        /// whatever it covers.
        fn addRegion(self: *Self, element: Ui.Index, visible: style.Rect, z: i16, parent_region: u32) u32 {
            const frame = self.frame;
            const flags = frame.flags[element];
            const index = self.results.region_count;
            self.results.regions[index] = .{
                .hash = frame.element_id[element],
                .bounds = visible,
                .z = z,
                .parent = parent_region,
                .flags = .{
                    .interactive = flags.interactive or flags.disabled,
                    .focusable = flags.focusable,
                    .disabled = flags.disabled,
                    .scroll_x = flags.scroll_x,
                    .scroll_y = flags.scroll_y,
                    .scroll_x_reversed = flags.scroll_x and flags.reversed,
                },
                .gestures = if (!Ui.features.gestures) {} else if (flags.interactive or flags.scroll_x or flags.scroll_y) frame.gestures[element] else .{},
                // `content_size` is only computed for elements with children.
                .max_scroll = if (frame.child_counts[element].all == 0) .{ 0, 0 } else .{
                    style.larger(0, frame.content_size[element][0] - frame.size[element][0]),
                    style.larger(0, frame.content_size[element][1] - frame.size[element][1]),
                },
            };
            self.results.region_count += 1;
            return index;
        }

        fn emitText(self: *Self, element: Ui.Index, element_id: u64, level: Level) void {
            const frame = self.frame;
            const record = frame.texts[frame.content_index[element]];
            const line_height = record.metrics.line_height;
            const alignment = record.style.alignment.fraction();
            for (frame.lines[record.first_line..][0..record.line_count], 0..) |line, line_number| {
                const free = frame.size[element][0] - line.width;
                const line_bounds: style.Rect = .{
                    .x = frame.position[element][0] + if (free > 0) free * alignment else 0,
                    .y = frame.position[element][1] + @as(f32, @floatFromInt(line_number)) * line_height,
                    .width = line.width,
                    .height = line_height,
                };
                if (line_bounds.intersect(level.clip).isEmpty()) continue;
                self.push(.{ .bounds = self.snap(line_bounds), .id = element_id, .z = level.z, .payload = .{ .text = .{
                    .content = frame.text_bytes[line.start..line.end],
                    .style = record.style,
                    .line = @intCast(line_number),
                } } });
            }
        }

        fn leave(self: *Self, level: *const Level, outer_z: i16) void {
            self.closeSubtree(level);
            if (level.pushed_clip) self.push(.{ .bounds = self.snap(level.clip), .id = self.frame.element_id[level.element], .z = level.z, .payload = .clip_end });
            if (level.z != outer_z) self.switchLayer(outer_z);
        }

        /// Dividers and the border. Both lie inside the element's box, so
        /// its own clip leaves them whole, and a floating element's
        /// target's clip cuts them off with the rest of it.
        inline fn closeSubtree(self: *Self, level: *const Level) void {
            const frame = self.frame;
            const element = level.element;
            const found = frame.decorationOf(element) orelse return;
            const border = if (found.border) |*border| border else return;
            if (border.between_children > 0) @call(.never_inline, emitDividers, .{ self, element, border, level });
            const widths = border.widths;
            if (widths.left == 0 and widths.right == 0 and widths.top == 0 and widths.bottom == 0) return;
            const bounds = self.rectOf(element);
            if (bounds.intersect(level.outer_clip).isEmpty()) return;
            self.push(.{ .bounds = self.snap(bounds), .id = frame.element_id[element], .z = level.z, .payload = .{ .border = .{
                .color = border.color,
                .widths = widths,
                .corner_radius = found.corner_radius,
            } } });
        }

        /// What cuts off the children of a floating element's target. An
        /// element target need not be on the stack of open levels, so its
        /// clip is found by walking up from it; the walk is bounded, since
        /// floating elements clipped to each other's subtrees form a cycle.
        fn floatingTargetClip(self: *const Self, floating: Ui.Index, parent_clip: style.Rect, viewport: style.Rect) style.Rect {
            const frame = self.frame;
            switch (frame.floatingOf(floating).attach_to) {
                .parent => return parent_clip,
                .root => return viewport,
                .element => {},
            }
            var clip = viewport;
            var current = layout.targetOf(Ui, frame, floating) orelse return viewport;
            for (0..frame.element_count) |_| {
                const flags = frame.flags[current];
                if (flags.clips()) clip = clip.intersect(clipBox(flags, self.rectOf(current), clip));
                if (current == Ui.root_index) break;
                if (!frame.isFloating(current)) {
                    current = frame.parent[current];
                } else if (flags.clips_to_target) {
                    current = layout.targetOf(Ui, frame, current) orelse break;
                } else break;
            }
            return clip;
        }

        /// Inside the element's own clip, so dividers scroll and are cut off
        /// with the children they separate. The gap between two children is
        /// from the later start to the earlier end, so a reversed row's
        /// dividers sit in its gaps too.
        fn emitDividers(self: *Self, element: Ui.Index, border: *const style.Border, level: *const Level) void {
            if (layout.wraps(Ui, self.frame, element)) return self.emitLineDividers(element, border, level);
            const frame = self.frame;
            const along: usize = @intFromEnum(frame.layoutOf(element).direction.axis());
            const across = 1 - along;
            const bounds = self.rectOf(element);
            const widths = border.widths;
            const across_start = if (across == 0) bounds.x + widths.left else bounds.y + widths.top;
            const across_length = if (across == 0) bounds.width - widths.left - widths.right else bounds.height - widths.top - widths.bottom;

            var previous: ?[2]f32 = null;
            var child = element + 1;
            while (child < frame.subtree_end[element]) : (child = frame.subtree_end[child]) {
                if (frame.isFloating(child)) continue;
                const extent: [2]f32 = .{ frame.position[child][along], frame.position[child][along] + frame.size[child][along] };
                if (previous) |previous_extent| {
                    var origin: [2]f32 = undefined;
                    var size: [2]f32 = undefined;
                    origin[along] = dividerStart(previous_extent, extent, border.between_children);
                    size[along] = border.between_children;
                    origin[across] = across_start;
                    size[across] = across_length;
                    self.pushDivider(element, border, level, .{ .x = origin[0], .y = origin[1], .width = size[0], .height = size[1] });
                }
                previous = extent;
            }
        }

        /// In a wrapping row, a divider between two children of a line is
        /// as tall as the line, and one between two lines spans the row.
        fn emitLineDividers(self: *Self, element: Ui.Index, border: *const style.Border, level: *const Level) void {
            const frame = self.frame;
            const bounds = self.rectOf(element);
            const widths = border.widths;
            const thickness = border.between_children;
            var previous_line: ?[2]f32 = null;
            var lines = layout.Lines(Ui).init(frame, element);
            while (lines.next()) |line| {
                var line_extent: [2]f32 = .{ std.math.inf(f32), -std.math.inf(f32) };
                var children = line;
                while (children.next()) |child| {
                    line_extent[0] = style.smaller(line_extent[0], frame.position[child][1]);
                    line_extent[1] = style.larger(line_extent[1], frame.position[child][1] + frame.size[child][1]);
                }
                if (previous_line) |previous_extent| self.pushDivider(element, border, level, .{
                    .x = bounds.x + widths.left,
                    .y = dividerStart(previous_extent, line_extent, thickness),
                    .width = bounds.width - widths.left - widths.right,
                    .height = thickness,
                });
                var previous_child: ?[2]f32 = null;
                children = line;
                while (children.next()) |child| {
                    const extent: [2]f32 = .{ frame.position[child][0], frame.position[child][0] + frame.size[child][0] };
                    if (previous_child) |previous_extent| self.pushDivider(element, border, level, .{
                        .x = dividerStart(previous_extent, extent, thickness),
                        .y = line_extent[0],
                        .width = thickness,
                        .height = line_extent[1] - line_extent[0],
                    });
                    previous_child = extent;
                }
                previous_line = line_extent;
            }
        }

        /// Centered in the gap between two extents, in either order.
        fn dividerStart(previous: [2]f32, next: [2]f32, thickness: f32) f32 {
            const gap_start = style.smaller(previous[1], next[1]);
            const gap_end = style.larger(previous[0], next[0]);
            return (gap_start + gap_end - thickness) / 2;
        }

        fn pushDivider(self: *Self, element: Ui.Index, border: *const style.Border, level: *const Level, divider: style.Rect) void {
            if (divider.intersect(level.clip).isEmpty()) return;
            self.push(.{ .bounds = self.snap(divider), .id = self.frame.element_id[element], .z = level.z, .payload = .{ .rectangle = .{ .color = border.color, .corner_radius = .zero } } });
        }
    };
}

/// An element's own clip: its box on the axes it clips, and `outer`'s
/// extent on the others.
fn clipBox(flags: anytype, bounds: style.Rect, outer: style.Rect) style.Rect {
    return .{
        .x = if (flags.clip_x) bounds.x else outer.x,
        .y = if (flags.clip_y) bounds.y else outer.y,
        .width = if (flags.clip_x) bounds.width else outer.width,
        .height = if (flags.clip_y) bounds.height else outer.height,
    };
}

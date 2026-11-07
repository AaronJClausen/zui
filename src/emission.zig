const std = @import("std");
const style = @import("style.zig");
const interaction = @import("interaction.zig");

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
        /// Clip in effect before this element's own clip, for its border.
        outer_clip: style.Rect,
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
/// an element is entered, its border when its subtree ends, so the border
/// paints over the element's children. Elements entirely outside the clip
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
        while (levels[depth].subtree_end <= element) : (depth -= 1) emitter.leave(&levels[depth]);
        if (emitter.enter(element, levels[depth], viewport)) |level| {
            depth += 1;
            levels[depth] = level;
        }
    }
    while (true) : (depth -= 1) {
        emitter.leave(&levels[depth]);
        if (depth == 0) break;
    }
    frame.diagnostics.needed.set(.max_render_commands, emitter.attempted_commands);
    emitting.end();

    if (frame.floating_count != 0) {
        const sorting = Ui.Tracing.begin(.sort_layers);
        defer sorting.end();
        std.sort.block(Ui.RenderCommand, frame.render_commands[0..frame.command_count], {}, lowerLayer(Ui));
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

        /// Returns the level the element's subtree is drawn in, or null if
        /// that is the parent's level unchanged.
        fn enter(self: *Self, element: Ui.Index, parent: Level, viewport: style.Rect) ?Level {
            const frame = self.frame;
            const flags = frame.flags[element];
            const floating = frame.isFloating(element);
            if (!floating and !flags.emits() and frame.decorationOf(element) == null and frame.kindOf(element) == .none) return null;
            const element_id = frame.element_id[element];
            const bounds = self.rectOf(element);
            const outer_clip = if (floating) viewport else parent.clip;
            var level: Level = .{
                .element = element,
                .subtree_end = frame.subtree_end[element],
                .clip = outer_clip,
                .outer_clip = outer_clip,
                .pushed_clip = false,
                .z = if (floating) frame.floatingOf(element).z else parent.z,
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
                .image => if (Ui.RenderCommand.has_image and drawn) self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = level.z, .payload = .{ .image = frame.images[frame.content_index[element]] } }),
                .custom => if (Ui.RenderCommand.has_custom and drawn) self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = level.z, .payload = .{ .custom = frame.customs[frame.content_index[element]] } }),
                .text => if (Ui.has_text) self.emitText(element, element_id, level),
            }

            if (flags.interactive or flags.scroll_x or flags.scroll_y or flags.disabled or floating) {
                level.region = self.addRegion(element, visible, level.z, parent.region);
            }
            if (flags.explicit_id) self.results.insert(element_id, bounds, if (level.region != parent.region) level.region else interaction.no_region);
            if (flags.focusable and !flags.disabled) {
                self.results.focusables[self.results.focusable_count] = .{ .hash = element_id, .scope = parent.focus_scope };
                self.results.focusable_count += 1;
            }

            if (flags.clips()) {
                const clip_box: style.Rect = .{
                    .x = if (flags.clip_x) bounds.x else outer_clip.x,
                    .y = if (flags.clip_y) bounds.y else outer_clip.y,
                    .width = if (flags.clip_x) bounds.width else outer_clip.width,
                    .height = if (flags.clip_y) bounds.height else outer_clip.height,
                };
                level.clip = outer_clip.intersect(clip_box);
                level.pushed_clip = true;
                self.push(.{ .bounds = self.snap(level.clip), .id = element_id, .z = level.z, .payload = .{ .clip_begin = self.snap(level.clip) } });
            }
            const has_border = if (frame.decorationOf(element)) |decoration| decoration.border != null else false;
            if (!level.pushed_clip and !has_border and !floating and level.region == parent.region and !flags.focus_scope) return null;
            return level;
        }

        /// Floating roots get a region even when not interactive: being on a
        /// higher layer, they win the hit test over whatever they cover.
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
                },
                // `content_size` is only computed for elements with children.
                .max_scroll = if (frame.child_count[element] == 0) .{ 0, 0 } else .{
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

        fn leave(self: *Self, level: *const Level) void {
            const frame = self.frame;
            const element = level.element;
            if (level.pushed_clip) self.push(.{ .bounds = self.snap(level.clip), .id = frame.element_id[element], .z = level.z, .payload = .clip_end });
            const decoration = frame.decorationOf(element) orelse return;
            const border = decoration.border orelse return;
            const bounds = self.rectOf(element);
            if (bounds.intersect(level.outer_clip).isEmpty()) return;
            self.push(.{ .bounds = self.snap(bounds), .id = frame.element_id[element], .z = level.z, .payload = .{ .border = .{
                .color = border.color,
                .widths = border.widths,
                .corner_radius = decoration.corner_radius,
            } } });
        }
    };
}

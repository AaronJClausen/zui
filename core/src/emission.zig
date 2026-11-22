const std = @import("std");
const style = @import("style.zig");
const interaction = @import("interaction.zig");
const layout = @import("layout.zig");
const exit_module = @import("exit.zig");
const Instant = @import("record.zig").Instant;

/// An open element whose subtree is drawn differently from its parent's:
/// it clips, has a border to draw after its children, floats, is a hit
/// region, is a focus scope, transforms, or keeps its commands for an exit
/// animation. Other elements open no level.
pub fn EmitLevel(comptime Index: type, comptime draws_transforms: bool, comptime keeps_exit_ghosts: bool) type {
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
        /// The space its subtree is hit-tested in.
        space: if (draws_transforms) u32 else void,
        transform_ends: if (draws_transforms) TransformEnds else void,
        exit: if (keeps_exit_ghosts) ExitTrack else void,
    };
}

/// What a level needs to keep its element's commands as a snapshot when its
/// subtree ends.
pub const ExitTrack = struct {
    /// Into the frame's exit list, or `no_candidate`.
    candidate: u32,
    /// The nearest element at or above this level that declares `exit`,
    /// for its children's `enclosing_id`; 0 for none.
    nearest_id: u64,
    enclosing_id: u64,
    first_command: u32,
    /// Commands pushed before the element's own, counting those dropped
    /// past `max_render_commands`.
    attempted_before: u32,
    /// The clip around the element, in which its ghost is drawn; none for a
    /// floating element, whose own commands hold its clip.
    outer_clip: ?style.Rect,
    /// The innermost space around the element whose transforms its ghost
    /// begins again, or `interaction.no_space`.
    outer_space: u32,

    pub const no_candidate = std.math.maxInt(u32);
    pub const none: ExitTrack = .{ .candidate = no_candidate, .nearest_id = 0, .enclosing_id = 0, .first_command = 0, .attempted_before = 0, .outer_clip = null, .outer_space = interaction.no_space };
};

/// The `transform_end`s a level pushes when its subtree ends.
pub const TransformEnds = struct {
    own: OwnTransform = .none,
    /// Its ancestors' transforms, begun again on a floating element's layer.
    reopened: u16 = 0,

    pub const OwnTransform = enum(u8) {
        none,
        /// Begun after the element's clip, as a floating element's is: its
        /// clip, holding its target's, is not transformed.
        inside_clip,
        around_clip,
    };
};

/// Pass 7: render commands in paint order, plus the hit regions, the
/// id → rect results and the focus order that the next frame's
/// interaction queries read. Elements are visited in declaration order,
/// which is depth-first order. A background and content are emitted when
/// an element is entered, its dividers and border when its subtree ends, so
/// they paint over the element's children. Elements entirely outside the clip
/// are not drawn.
pub fn run(comptime Ui: type, ui: *Ui, frame: *Ui.Frame) void {
    if (frame.effect_count == 0) emit(Ui, ui, frame, .without_effects) else @call(.never_inline, emit, .{ Ui, ui, frame, .with_effects });
}

/// A frame with effects is emitted by its own copy of the walk, so that
/// one without them runs code that never looks for any: any change to
/// the walk moves how the compiler allocates its registers, by up to 5% of
/// `endFrame`. The helpers both copies call are `inline` because with two
/// callers the compiler stopped inlining them, which cost the walk 4%.
const Walk = enum { without_effects, with_effects };

fn emit(comptime Ui: type, ui: *Ui, frame: *Ui.Frame, comptime walk: Walk) void {
    const emitting = Ui.Tracing.begin(.emit);
    const results = &ui.memory.results;
    results.clear();
    var emitter: Emitter(Ui) = .{
        .frame = frame,
        .results = results,
        .space_effects = &ui.emit_space_effects,
        .pixels_per_unit = frame.pixels_per_unit,
        .units_per_pixel = 1 / frame.pixels_per_unit,
        .ghosts = if (Ui.keeps_exit_ghosts) &ui.memory.exit_ghosts else {},
        .now = if (Ui.keeps_exit_ghosts) ui.now() else {},
    };

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
        .space = if (Ui.draws_transforms) interaction.no_space else {},
        .transform_ends = if (Ui.draws_transforms) .{} else {},
        .exit = if (Ui.keeps_exit_ghosts) .none else {},
    };
    results.insert(frame.element_id[Ui.root_index], emitter.rectOf(Ui.root_index), interaction.no_region);

    var depth: usize = 0;
    var next_effect: u32 = 0;
    var next_effect_element: Ui.Index = if (walk == .with_effects) frame.effect_elements[0] else Ui.none_index;
    const exit_list = if (Ui.keeps_exit_ghosts) Ui.exitListOf(frame) else {};
    var next_exit: u32 = 0;
    var next_exit_element: Ui.Index = Ui.none_index;
    if (Ui.keeps_exit_ghosts) {
        ui.memory.exit_ghosts.next().reset();
        if (!ui.current_environment.reduced_motion and exit_list.count != 0) next_exit_element = exit_list.elements[0];
    }
    for (1..frame.element_count) |index| {
        const element: Ui.Index = @intCast(index);
        while (levels[depth].subtree_end <= element) : (depth -= 1) emitter.leave(&levels[depth], levels[depth - 1].z);
        const effect_index = next_effect;
        const effects: ?*const Ui.Effects = if (walk == .with_effects and element == next_effect_element) taken: {
            const effects = &frame.effects[next_effect];
            next_effect += 1;
            next_effect_element = if (next_effect < frame.effect_count) frame.effect_elements[next_effect] else Ui.none_index;
            break :taken effects;
        } else null;
        const exit_candidate: ?u32 = if (Ui.keeps_exit_ghosts and element == next_exit_element) taken: {
            const candidate = next_exit;
            next_exit += 1;
            next_exit_element = if (next_exit < exit_list.count) exit_list.elements[next_exit] else Ui.none_index;
            break :taken candidate;
        } else null;
        if (!frame.flags[element].emits() and frame.decorationOf(element) == null and frame.kindOf(element) == .none and effects == null and exit_candidate == null) continue;
        if (emitter.enter(element, levels[depth], viewport, effects, effect_index, exit_candidate)) |level| {
            depth += 1;
            levels[depth] = level;
        }
    }
    while (true) : (depth -= 1) {
        emitter.leave(&levels[depth], if (depth == 0) 0 else levels[depth - 1].z);
        if (depth == 0) break;
    }
    if (Ui.keeps_exit_ghosts) emitGhosts(Ui, ui, &emitter);
    frame.diagnostics.needed.set(.max_render_commands, emitter.attempted_commands);
    emitting.end();

    if (emitter.layered_run_count != 0 or emitter.layered_runs_overflowed) {
        const sorting = Ui.Tracing.begin(.sort_layers);
        defer sorting.end();
        emitter.sortLayers();
    }
}

/// Draws each ghost still leaving at the end of its layer, older ghosts
/// first, and keeps it for the next frame. A snapshot of the last frame
/// becomes a ghost when its element is no longer declared, unless the
/// element around it that also declares `exit` left with it, since that
/// one's ghost holds its commands. A ghost is dropped once its seconds are
/// up or its element is declared again.
fn emitGhosts(comptime Ui: type, ui: *Ui, emitter: *Emitter(Ui)) void {
    const ghosts = &ui.memory.exit_ghosts;
    defer ghosts.advance();
    const frame = emitter.frame;
    defer frame.diagnostics.needed.set(.exit_ghost_commands, emitter.ghost_commands_needed);
    if (ui.current_environment.reduced_motion) return;
    const previous = ghosts.previous();
    const next = ghosts.next();
    const now = emitter.now;
    var fading = false;
    inline for (.{ true, false }) |exited| {
        for (previous.keptGhosts()) |*ghost| {
            if (ghost.exited != exited) continue;
            if (frame.lookup(ghost.id) != null) continue;
            if (!exited and ghost.enclosing_id != 0 and frame.lookup(ghost.enclosing_id) == null) continue;
            const progress = ghost.progressAt(now);
            if (!(progress < 1)) continue;
            const commands = previous.commandsOf(ghost);
            emitter.ghost_commands_needed += @intCast(commands.len);
            next.begin();
            for (commands) |command| next.append(command);
            var kept = ghost.*;
            kept.exited = true;
            if (!next.finish(kept)) {
                emitter.reportGhostOverflow(ghost.id);
                continue;
            }
            const copied = next.commandsOf(&next.keptGhosts()[next.ghost_count - 1]);
            switch (ghost.exit.fade) {
                .none => {
                    emitter.pushGhost(copied, false, 1);
                    ui.requestFrameAt(ghost.since.addSeconds(ghost.exit.seconds));
                },
                else => |curve| {
                    emitter.pushGhost(copied, true, curve.opacityAt(progress));
                    fading = true;
                },
            }
        }
    }
    emitter.switchLayer(0);
    if (fading) ui.requestFrame();
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
        const Level = EmitLevel(Ui.Index, Ui.draws_transforms, Ui.keeps_exit_ghosts);
        const no_space = interaction.no_space;

        frame: *Ui.Frame,
        results: *Ui.Results,
        space_effects: *[Ui.max_spaces]u32,
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
        ghosts: if (Ui.keeps_exit_ghosts) *Ui.ExitGhosts else void,
        now: if (Ui.keeps_exit_ghosts) Instant else void,
        /// Reported as `needed.exit_ghost_commands` once emission ends.
        ghost_commands_needed: if (Ui.keeps_exit_ghosts) u32 else void = if (Ui.keeps_exit_ghosts) 0 else {},

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

        /// `color` itself, unless the renderer draws only `Color`, when an
        /// `ExtendedColor` is clamped and the frame told if that changed it.
        inline fn commandColor(self: *Self, color: Ui.Color) Ui.CommandColor {
            if (comptime !Ui.clamps_colors) return color;
            if (!color.isStandard()) self.frame.diagnostics.clamped_colors = true;
            return color.toColor();
        }

        inline fn commandTextStyle(self: *Self, text_style: Ui.TextStyle) @FieldType(Ui.RenderCommand.Text, "style") {
            if (comptime !Ui.clamps_colors) return text_style;
            return .{
                .font = text_style.font,
                .size = text_style.size,
                .letter_spacing = text_style.letter_spacing,
                .line_height = text_style.line_height,
                .color = self.commandColor(text_style.color),
                .wrap = text_style.wrap,
                .alignment = text_style.alignment,
            };
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
        inline fn sortLayers(self: *Self) void {
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
        inline fn enter(self: *Self, element: Ui.Index, parent: Level, viewport: style.Rect, effects: ?*const Ui.Effects, effect_index: u32, exit_candidate: ?u32) ?Level {
            const frame = self.frame;
            const flags = frame.flags[element];
            const floating = flags.floating;
            const element_id = frame.element_id[element];
            const bounds = self.rectOf(element);
            const first_command = if (Ui.keeps_exit_ghosts) frame.command_count else {};
            const attempted_before = if (Ui.keeps_exit_ghosts) self.attempted_commands else {};
            var layer: Layer = .{ .clip = parent.clip, .z = parent.z };
            if (floating) layer = self.floatingLayer(element, parent, viewport);
            var outer_clip = layer.clip;
            var space = if (Ui.draws_transforms) parent.space else {};
            var transform_ends: if (Ui.draws_transforms) TransformEnds else void = if (Ui.draws_transforms) .{ .reopened = layer.reopened } else {};
            if (effects) |declared| if (declared.transform) |*transform| {
                if (comptime Ui.draws_transforms) {
                    const begun = self.beginTransform(element, bounds, transform, effect_index, parent.space, layer.z, outer_clip);
                    outer_clip = begun.clip;
                    space = begun.space;
                    transform_ends.own = if (flags.clips_to_target) .inside_clip else .around_clip;
                } else frame.diagnostics.lowered.insert(.transform);
            };
            var level: Level = .{
                .element = element,
                .subtree_end = frame.subtree_end[element],
                .clip = outer_clip,
                .outer_clip = outer_clip,
                .pushed_clip = false,
                .z = layer.z,
                .region = parent.region,
                .focus_scope = if (flags.focus_scope) element_id else parent.focus_scope,
                .space = space,
                .transform_ends = transform_ends,
                .exit = if (Ui.keeps_exit_ghosts) exitTrack(parent, element_id, exit_candidate, first_command, attempted_before, floating, layer) else {},
            };
            const visible = bounds.intersect(outer_clip);
            const drawn = !visible.isEmpty();

            if (effects) |declared| if (declared.shadow) |*shadow| self.emitShadow(element, bounds, outer_clip, level.z, shadow);
            if (drawn) if (effects) |declared| if (declared.backdrop_blur) |*blur| self.emitBackdropBlur(element, bounds, level.z, blur);
            if (drawn) if (frame.decorationOf(element)) |decoration| self.emitBackground(element_id, bounds, level.z, decoration);
            if (drawn) if (effects) |declared| if (declared.gradient) |*gradient| self.emitGradient(element, bounds, level.z, gradient);

            switch (frame.kindOf(element)) {
                .none => {},
                .image => if (Ui.RenderCommand.has_image and drawn) {
                    const image = frame.imageOf(element);
                    self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = level.z, .payload = .{ .image = .{ .handle = image.handle, .tint = self.commandColor(image.tint), .corner_radius = image.corner_radius } } });
                },
                .custom => if (Ui.RenderCommand.has_custom and drawn) self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = level.z, .payload = .{ .custom = frame.customs[frame.content_index[element]] } }),
                .text => if (Ui.has_text) self.emitText(element, element_id, level),
            }

            if (flags.interactive or flags.scroll_x or flags.scroll_y or flags.disabled or flags.captures_pointer) {
                level.region = self.addRegion(element, visible, &level, parent.region);
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
            const transforms = if (comptime Ui.draws_transforms) transform_ends.own != .none else false;
            if (!level.pushed_clip and !has_border and !floating and level.region == parent.region and !flags.focus_scope and !transforms and exit_candidate == null) return null;
            return level;
        }

        fn exitTrack(parent: Level, element_id: u64, exit_candidate: ?u32, first_command: u32, attempted_before: u32, floating: bool, layer: Layer) ExitTrack {
            const reopened = if (Ui.draws_transforms) layer.reopened != 0 else false;
            return .{
                .candidate = exit_candidate orelse ExitTrack.no_candidate,
                .nearest_id = if (exit_candidate != null) element_id else parent.exit.nearest_id,
                .enclosing_id = parent.exit.nearest_id,
                .first_command = first_command,
                .attempted_before = attempted_before,
                .outer_clip = if (floating) null else parent.clip,
                .outer_space = if (Ui.draws_transforms and !reopened) parent.space else no_space,
            };
        }

        /// Copies the commands the level's subtree pushed, inside the clip
        /// and transforms around it, into the store being written. A subtree
        /// that lost commands to `max_render_commands` is not kept, since
        /// its clips might not end.
        fn keepSnapshot(self: *Self, level: *const Level) void {
            const frame = self.frame;
            const track = &level.exit;
            const pushed = frame.command_count - track.first_command;
            if (pushed == 0 or self.attempted_commands - track.attempted_before != pushed) return;
            const element_id = frame.element_id[level.element];
            const store = self.ghosts.next();
            store.begin();
            const transforms = if (Ui.draws_transforms) self.keepTransformBegins(store, track.outer_space, level.z) else 0;
            if (track.outer_clip) |clip| store.append(.{ .bounds = self.snap(clip), .id = element_id, .z = level.z, .payload = .{ .clip_begin = self.snap(clip) } });
            for (frame.render_commands[track.first_command..frame.command_count]) |command| store.append(command);
            if (track.outer_clip) |clip| store.append(.{ .bounds = self.snap(clip), .id = element_id, .z = level.z, .payload = .clip_end });
            if (Ui.draws_transforms) for (0..transforms) |_| store.append(.{ .bounds = self.snap(self.rectOf(level.element)), .id = element_id, .z = level.z, .payload = .transform_end });
            self.ghost_commands_needed += pushed + 2 * (transforms + @as(u32, @intFromBool(track.outer_clip != null)));
            const kept = store.finish(.{
                .id = element_id,
                .enclosing_id = track.enclosing_id,
                .exit = Ui.exitListOf(frame).exits[track.candidate],
                .since = self.now,
                .first_command = 0,
                .command_count = 0,
                .exited = false,
            });
            if (!kept) self.reportGhostOverflow(element_id);
        }

        /// Begins the transforms of `innermost` and every space around it
        /// in `store`, the outermost first, as `reopenTransforms` does in
        /// the frame.
        fn keepTransformBegins(self: *Self, store: *Ui.ExitGhosts.Store, innermost: u32, z: i16) u32 {
            const spaces = &self.results.spaces;
            var count: u32 = 0;
            var space = innermost;
            while (space != no_space) : (space = spaces[space].parent) count += 1;
            var still_to_begin = count;
            while (still_to_begin != 0) : (still_to_begin -= 1) {
                var outermost_left = innermost;
                for (1..still_to_begin) |_| outermost_left = spaces[outermost_left].parent;
                const effect_index = self.space_effects[outermost_left];
                const element = self.frame.effect_elements[effect_index];
                store.append(.{ .bounds = self.snap(self.rectOf(element)), .id = self.frame.element_id[element], .z = z, .payload = .{ .transform_begin = self.frame.effects[effect_index].transform.? } });
            }
            return count;
        }

        /// A ghost's text is copied into the frame, which a renderer may
        /// hold after the store it came from is written again.
        fn pushGhost(self: *Self, commands: []const Ui.RenderCommand, comptime fades: bool, opacity: f32) void {
            const frame = self.frame;
            for (commands) |command| {
                var drawn = command;
                if (fades) exit_module.fadeCommand(Ui.RenderCommand, &drawn, opacity);
                if (Ui.has_text and drawn.payload == .text) {
                    const content = drawn.payload.text.content;
                    const needed = &frame.diagnostics.needed;
                    needed.set(.max_text_bytes, needed.get(.max_text_bytes) + @as(u32, @intCast(content.len)));
                    if (frame.text_bytes.len - frame.text_bytes_used < content.len) {
                        frame.diagnostics.exceeded.insert(.max_text_bytes);
                        if (frame.diagnostics.first_dropped_id == 0) frame.diagnostics.first_dropped_id = drawn.id;
                        continue;
                    }
                    const copy = frame.text_bytes[frame.text_bytes_used..][0..content.len];
                    @memcpy(copy, content);
                    frame.text_bytes_used += @intCast(content.len);
                    drawn.payload.text.content = copy;
                }
                self.switchLayer(drawn.z);
                self.push(drawn);
            }
        }

        fn reportGhostOverflow(self: *Self, element_id: u64) void {
            const diagnostics = &self.frame.diagnostics;
            diagnostics.exceeded.insert(.exit_ghost_commands);
            if (diagnostics.first_dropped_id == 0) diagnostics.first_dropped_id = element_id;
        }

        const TransformBegun = struct { clip: style.Rect, space: u32 };

        /// Begins the element's transform and enters its space, whose clip,
        /// for culling, is the box around `clip` in the space's own units.
        fn beginTransform(self: *Self, element: Ui.Index, bounds: style.Rect, transform: *const style.Transform, effect_index: u32, parent_space: u32, z: i16, clip: style.Rect) TransformBegun {
            self.push(.{ .bounds = self.snap(bounds), .id = self.frame.element_id[element], .z = z, .payload = .{ .transform_begin = transform.* } });
            const results = self.results;
            const space = results.space_count;
            results.space_count += 1;
            self.space_effects[space] = effect_index;
            const parent_from_window: style.Affine = if (parent_space == no_space) .identity else results.spaces[parent_space].from_window;
            const to_local = transform.affine(bounds).inverse() orelse {
                results.spaces[space] = .{ .from_window = .identity, .clip = .{}, .parent = parent_space };
                return .{ .clip = .{}, .space = space };
            };
            results.spaces[space] = .{ .from_window = to_local.after(parent_from_window), .clip = clip, .parent = parent_space };
            return .{ .clip = to_local.boundsOf(clip), .space = space };
        }

        /// A floating element on another layer than its parent's is sorted
        /// away from the transforms around it, so it begins each again, the
        /// outermost first.
        fn reopenTransforms(self: *Self, innermost: u32, z: i16) u16 {
            const spaces = &self.results.spaces;
            var count: u16 = 0;
            var space = innermost;
            while (space != no_space) : (space = spaces[space].parent) count += 1;
            var still_to_begin = count;
            while (still_to_begin != 0) : (still_to_begin -= 1) {
                var outermost_left = innermost;
                for (1..still_to_begin) |_| outermost_left = spaces[outermost_left].parent;
                const effect_index = self.space_effects[outermost_left];
                const element = self.frame.effect_elements[effect_index];
                self.push(.{ .bounds = self.snap(self.rectOf(element)), .id = self.frame.element_id[element], .z = z, .payload = .{ .transform_begin = self.frame.effects[effect_index].transform.? } });
            }
            return count;
        }

        fn cornerRadiusOf(self: *const Self, element: Ui.Index) style.CornerRadius {
            const decoration = self.frame.decorationOf(element) orelse return .zero;
            return decoration.corner_radius;
        }

        /// Culled by what it paints rather than by the element's box, so the
        /// shadow of an element just outside the clip still shows inside it.
        fn emitShadow(self: *Self, element: Ui.Index, bounds: style.Rect, clip: style.Rect, z: i16, shadow: *const Ui.Shadow) void {
            if (comptime !Ui.RenderCommand.commands.contains(.shadow)) {
                self.frame.diagnostics.lowered.insert(.shadow);
                return;
            }
            if (shadow.paintedBounds(bounds).intersect(clip).isEmpty()) return;
            self.push(.{ .bounds = self.snap(bounds), .id = self.frame.element_id[element], .z = z, .payload = .{ .shadow = .{
                .color = self.commandColor(shadow.color),
                .offset = shadow.offset,
                .blur = shadow.blur,
                .spread = shadow.spread,
                .corner_radius = self.cornerRadiusOf(element),
            } } });
        }

        fn emitGradient(self: *Self, element: Ui.Index, bounds: style.Rect, z: i16, gradient: *const Ui.Gradient) void {
            const element_id = self.frame.element_id[element];
            const corner_radius = self.cornerRadiusOf(element);
            if (comptime !Ui.RenderCommand.commands.contains(.gradient)) {
                self.frame.diagnostics.lowered.insert(.gradient);
                self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = z, .payload = .{ .rectangle = .{ .color = self.commandColor(gradient.meanColor()), .corner_radius = corner_radius } } });
                return;
            }
            self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = z, .payload = .{ .gradient = .{
                .from = self.commandColor(gradient.from),
                .to = self.commandColor(gradient.to),
                .angle = gradient.angle,
                .corner_radius = corner_radius,
            } } });
        }

        inline fn emitBackground(self: *Self, element_id: u64, bounds: style.Rect, z: i16, decoration: *const Ui.Decoration) void {
            if (decoration.materialOf()) |material| {
                if (comptime Ui.RenderCommand.commands.contains(.material)) {
                    self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = z, .payload = .{ .material = .{
                        .handle = material,
                        .fallback = self.commandColor(decoration.background orelse .transparent),
                        .corner_radius = decoration.corner_radius,
                    } } });
                    return;
                }
                self.frame.diagnostics.lowered.insert(.material);
            }
            if (decoration.background) |color| {
                self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = z, .payload = .{ .rectangle = .{ .color = self.commandColor(color), .corner_radius = decoration.corner_radius } } });
            }
        }

        fn emitBackdropBlur(self: *Self, element: Ui.Index, bounds: style.Rect, z: i16, blur: *const Ui.BackdropBlur) void {
            const element_id = self.frame.element_id[element];
            const corner_radius = self.cornerRadiusOf(element);
            if (comptime !Ui.RenderCommand.commands.contains(.backdrop_blur)) {
                self.frame.diagnostics.lowered.insert(.backdrop_blur);
                self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = z, .payload = .{ .rectangle = .{ .color = self.commandColor(blur.tint), .corner_radius = corner_radius } } });
                return;
            }
            self.push(.{ .bounds = self.snap(bounds), .id = element_id, .z = z, .payload = .{ .backdrop_blur = .{
                .radius = blur.radius,
                .tint = self.commandColor(blur.tint),
                .corner_radius = corner_radius,
            } } });
        }

        const Layer = struct {
            clip: style.Rect,
            z: i16,
            reopened: if (Ui.draws_transforms) u16 else void = if (Ui.draws_transforms) 0 else {},
        };

        /// A floating element's layer and clip. Cut off by its target's
        /// clip, it pushes that clip merged with its own before it draws:
        /// its own box holds everything it draws itself.
        inline fn floatingLayer(self: *Self, floating: Ui.Index, parent: Level, window: style.Rect) Layer {
            const frame = self.frame;
            const config = frame.floatingOf(floating);
            self.switchLayer(config.z);
            var layer: Layer = .{ .clip = window, .z = config.z };
            var viewport = window;
            if (comptime Ui.draws_transforms) if (parent.space != no_space) {
                if (config.z != parent.z) layer.reopened = self.reopenTransforms(parent.space, config.z);
                viewport = self.results.spaces[parent.space].from_window.boundsOf(window);
                layer.clip = viewport;
            };
            if (config.clip == .none) return layer;
            const target_clip = self.floatingTargetClip(floating, parent.clip, viewport);
            layer.clip = target_clip.intersect(clipBox(frame.flags[floating], self.rectOf(floating), target_clip));
            self.push(.{ .bounds = self.snap(layer.clip), .id = frame.element_id[floating], .z = config.z, .payload = .{ .clip_begin = self.snap(layer.clip) } });
            return layer;
        }

        /// A floating element that captures gets a region even when it is
        /// not interactive: on a higher layer, it wins the hit test over
        /// whatever it covers.
        fn addRegion(self: *Self, element: Ui.Index, visible: style.Rect, level: *const Level, parent_region: u32) u32 {
            const frame = self.frame;
            const flags = frame.flags[element];
            const index = self.results.region_count;
            self.results.regions[index] = .{
                .hash = frame.element_id[element],
                .bounds = visible,
                .space = level.space,
                .z = level.z,
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

        inline fn emitText(self: *Self, element: Ui.Index, element_id: u64, level: Level) void {
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
                    .style = self.commandTextStyle(record.style),
                    .line = @intCast(line_number),
                } } });
            }
        }

        fn leave(self: *Self, level: *const Level, outer_z: i16) void {
            self.closeSubtree(level);
            if (comptime Ui.draws_transforms) if (level.transform_ends.own == .inside_clip) self.pushTransformEnd(level);
            if (level.pushed_clip) self.push(.{ .bounds = self.snap(level.clip), .id = self.frame.element_id[level.element], .z = level.z, .payload = .clip_end });
            if (comptime Ui.draws_transforms) {
                if (level.transform_ends.own == .around_clip) self.pushTransformEnd(level);
                for (0..level.transform_ends.reopened) |_| self.pushTransformEnd(level);
            }
            if (comptime Ui.keeps_exit_ghosts) if (level.exit.candidate != ExitTrack.no_candidate) self.keepSnapshot(level);
            if (level.z != outer_z) self.switchLayer(outer_z);
        }

        fn pushTransformEnd(self: *Self, level: *const Level) void {
            self.push(.{ .bounds = self.snap(self.rectOf(level.element)), .id = self.frame.element_id[level.element], .z = level.z, .payload = .transform_end });
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
                .color = self.commandColor(border.color),
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
        fn emitDividers(self: *Self, element: Ui.Index, border: *const Ui.Border, level: *const Level) void {
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
        fn emitLineDividers(self: *Self, element: Ui.Index, border: *const Ui.Border, level: *const Level) void {
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

        fn pushDivider(self: *Self, element: Ui.Index, border: *const Ui.Border, level: *const Level, divider: style.Rect) void {
            if (divider.intersect(level.clip).isEmpty()) return;
            self.push(.{ .bounds = self.snap(divider), .id = self.frame.element_id[element], .z = level.z, .payload = .{ .rectangle = .{ .color = self.commandColor(border.color), .corner_radius = .zero } } });
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

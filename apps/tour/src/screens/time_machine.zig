const std = @import("std");
const zui = @import("zui");

const world_size: [2]f32 = .{ 640, 360 };
const steps_per_second = 60;
const max_steps = 60 * steps_per_second;
/// A frame that comes late runs at most this many steps, so a long sleep
/// is not caught up all at once.
const max_steps_per_frame = 4;
const max_bodies = 24;
const log_capacity = 256;
const fling_strength = 3;

/// One input the world took, at the step it applies before.
const Input = struct {
    step: u32,
    action: Action,

    const Action = union(enum) {
        fling: struct { position: [2]f32, velocity: [2]f32 },
        toggle_gravity,
    };
};

const Body = struct {
    position: [2]f32,
    velocity: [2]f32,
    radius: f32,
    hue_index: u8,
};

/// Bouncing bodies, a pure function of the steps run and the inputs
/// applied before each.
const World = struct {
    bodies: [max_bodies]Body = undefined,
    count: u8 = 0,
    flung_total: u32 = 0,
    gravity: bool = true,
    step: u32 = 0,

    fn apply(world: *World, action: Input.Action) void {
        switch (action) {
            .fling => |fling| {
                const slot: u8 = if (world.count < max_bodies) world.count else @intCast(world.flung_total % max_bodies);
                world.bodies[slot] = .{
                    .position = fling.position,
                    .velocity = fling.velocity,
                    .radius = 10 + @as(f32, @floatFromInt(world.flung_total % 4)) * 3,
                    .hue_index = @intCast(world.flung_total % 4),
                };
                world.count = @max(world.count, slot + 1);
                world.flung_total += 1;
            },
            .toggle_gravity => world.gravity = !world.gravity,
        }
    }

    fn advance(world: *World) void {
        const seconds: f32 = 1.0 / @as(f32, steps_per_second);
        const gravity: f32 = if (world.gravity) 900 else 0;
        const bodies = world.bodies[0..world.count];
        for (bodies) |*body| {
            body.velocity[1] += gravity * seconds;
            body.velocity[0] *= 0.999;
            body.velocity[1] *= 0.999;
            for (0..2) |axis| {
                body.position[axis] += body.velocity[axis] * seconds;
                if (body.position[axis] < body.radius) {
                    body.position[axis] = body.radius;
                    body.velocity[axis] = @abs(body.velocity[axis]) * 0.85;
                } else if (body.position[axis] > world_size[axis] - body.radius) {
                    body.position[axis] = world_size[axis] - body.radius;
                    body.velocity[axis] = -@abs(body.velocity[axis]) * 0.85;
                }
            }
        }
        for (bodies, 0..) |*first, first_index| {
            for (bodies[first_index + 1 ..]) |*second| collide(first, second);
        }
        world.step += 1;
    }

    /// Equal masses exchange the part of their velocities along the line
    /// between their centers.
    fn collide(first: *Body, second: *Body) void {
        const offset: [2]f32 = .{ second.position[0] - first.position[0], second.position[1] - first.position[1] };
        const distance_squared = offset[0] * offset[0] + offset[1] * offset[1];
        const touching = first.radius + second.radius;
        if (distance_squared >= touching * touching or distance_squared == 0) return;
        const distance = @sqrt(distance_squared);
        const normal: [2]f32 = .{ offset[0] / distance, offset[1] / distance };
        const overlap = (touching - distance) / 2;
        for (0..2) |axis| {
            first.position[axis] -= normal[axis] * overlap;
            second.position[axis] += normal[axis] * overlap;
        }
        const closing = (second.velocity[0] - first.velocity[0]) * normal[0] + (second.velocity[1] - first.velocity[1]) * normal[1];
        if (closing >= 0) return;
        for (0..2) |axis| {
            first.velocity[axis] += closing * normal[axis] * 0.9;
            second.velocity[axis] -= closing * normal[axis] * 0.9;
        }
    }

    /// Nothing moves enough to see: the timeline need not grow.
    fn settled(world: *const World) bool {
        for (world.bodies[0..world.count]) |body| {
            const resting_on_floor = !world.gravity or body.position[1] >= world_size[1] - body.radius - 0.5;
            if (@abs(body.velocity[0]) > 4 or @abs(body.velocity[1]) > 20 or !resting_on_floor) return false;
        }
        return true;
    }

    fn checksum(world: *const World) u32 {
        var hasher = std.hash.Fnv1a_32.init();
        hasher.update(std.mem.asBytes(&world.count));
        hasher.update(std.mem.asBytes(&world.gravity));
        hasher.update(std.mem.asBytes(&world.step));
        for (world.bodies[0..world.count]) |body| {
            hasher.update(std.mem.asBytes(&body.position));
            hasher.update(std.mem.asBytes(&body.velocity));
        }
        return hasher.final();
    }
};

/// Every input in the order taken, each with its step.
const InputLog = struct {
    inputs: [log_capacity]Input = undefined,
    count: u16 = 0,

    fn record(log: *InputLog, input: Input) bool {
        if (log.count == log_capacity) return false;
        log.inputs[log.count] = input;
        log.count += 1;
        return true;
    }

    /// Forgets every input after `step`: the future that was, before a branch.
    fn truncateAfter(log: *InputLog, step: u32) u16 {
        var kept: u16 = 0;
        while (kept < log.count and log.inputs[kept].step <= step) kept += 1;
        const forgotten = log.count - kept;
        log.count = kept;
        return forgotten;
    }

    /// The world at `target_step`, from nothing: every step run and every
    /// input applied at its step, as the run did.
    fn rebuild(log: *const InputLog, target_step: u32) World {
        var world: World = .{};
        log.applyInputsAt(&world);
        while (world.step < target_step) log.stepForward(&world);
        return world;
    }

    fn stepForward(log: *const InputLog, world: *World) void {
        world.advance();
        log.applyInputsAt(world);
    }

    fn applyInputsAt(log: *const InputLog, world: *World) void {
        for (log.inputs[0..log.count]) |input| {
            if (input.step == world.step) world.apply(input.action);
        }
    }

    fn countThrough(log: *const InputLog, step: u32) u16 {
        var count: u16 = 0;
        for (log.inputs[0..log.count]) |input| {
            if (input.step <= step) count += 1;
        }
        return count;
    }
};

const opening_flings = [_]Input.Action{
    .{ .fling = .{ .position = .{ 120, 90 }, .velocity = .{ 260, -120 } } },
    .{ .fling = .{ .position = .{ 320, 60 }, .velocity = .{ -180, 40 } } },
    .{ .fling = .{ .position = .{ 520, 120 }, .velocity = .{ -320, -260 } } },
    .{ .fling = .{ .position = .{ 240, 200 }, .velocity = .{ 120, -380 } } },
};

/// The screen, declared through `kit`, the tour's `Kit`.
pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        const ids = struct {
            const canvas: zui.Id = .of("time_machine.canvas");
            const play: zui.Id = .of("time_machine.play");
            const present: zui.Id = .of("time_machine.present");
            const gravity: zui.Id = .of("time_machine.gravity");
            const reset: zui.Id = .of("time_machine.reset");
            const timeline: zui.Id = .of("time_machine.timeline");
            const proof: zui.Id = .of("time_machine.proof");
        };

        const Aim = struct {
            from: [2]f32 = .{ 0, 0 },
            to: [2]f32 = .{ 0, 0 },
            active: bool = false,
        };

        const LastReplay = struct {
            steps: u32 = 0,
            inputs_applied: u16 = 0,
            microseconds: f32 = 0,
        };

        /// A world of bouncing balls rebuilt at any step by replaying its input log, checked against the live run.
        pub const TimeMachine = struct {
            started: bool = false,
            log: InputLog = .{},
            /// The world at `view_step`, which the page shows.
            world: World = .{},
            /// The furthest step the run has reached, the present.
            head_step: u32 = 0,
            /// Each step's checksum as the run first reached it.
            live_checksums: [max_steps + 1]u32 = undefined,
            playing: bool = true,
            step_time_debt: f32 = 0,
            aim: Aim = .{},
            last_replay: LastReplay = .{},
            rebuilds: u32 = 0,
            branches: u32 = 0,
            inputs_forgotten: u32 = 0,
            log_full: bool = false,

            fn start(self: *TimeMachine) void {
                self.* = .{ .started = true };
                for (opening_flings) |action| _ = self.log.record(.{ .step = 0, .action = action });
                self.world = self.log.rebuild(0);
                self.live_checksums[0] = self.world.checksum();
            }

            /// Declares the page into the tour's stage.
            pub fn declare(self: *TimeMachine, ui: *Ui, shell: *const Shell) void {
                if (!self.started) self.start();
                self.handleCanvasInput(ui);
                self.advanceClock(ui);

                {
                    ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 12 } });
                    defer ui.close();
                    self.canvasCard(ui, shell);
                    self.proofCard(ui, shell);
                }
                self.timelineCard(ui, shell);
            }

            fn atPresent(self: *const TimeMachine) bool {
                return self.world.step == self.head_step;
            }

            fn advanceClock(self: *TimeMachine, ui: *Ui) void {
                if (!self.playing) return;
                if (self.atPresent() and (self.world.settled() or self.head_step == max_steps)) {
                    self.step_time_debt = 0;
                    if (self.head_step == max_steps) self.playing = false;
                    return;
                }
                self.step_time_debt += ui.dt() * steps_per_second;
                const steps: u32 = @intFromFloat(@min(@floor(self.step_time_debt), max_steps_per_frame));
                self.step_time_debt = @min(self.step_time_debt - @as(f32, @floatFromInt(steps)), 1);
                for (0..steps) |_| self.stepOnce();
                ui.requestFrame();
            }

            fn stepOnce(self: *TimeMachine) void {
                if (self.world.step == max_steps) return;
                self.log.stepForward(&self.world);
                if (self.world.step > self.head_step) {
                    self.head_step = self.world.step;
                    self.live_checksums[self.head_step] = self.world.checksum();
                }
            }

            /// Rebuilds the world at `step` from nothing, as zui's replay does.
            fn scrubTo(self: *TimeMachine, ui: *Ui, step: u32, shell: *const Shell) void {
                const started_at: zui.Instant = .fromTimestamp(std.Io.Timestamp.now(shell.io, .awake));
                self.world = self.log.rebuild(step);
                const finished_at: zui.Instant = .fromTimestamp(std.Io.Timestamp.now(shell.io, .awake));
                self.rebuilds += 1;
                self.last_replay = .{ .steps = step, .inputs_applied = self.log.countThrough(step), .microseconds = finished_at.secondsSince(started_at) * std.time.us_per_s };
                ui.requestFrame();
            }

            /// Taking input in the past forgets the future it had, as a branch.
            fn take(self: *TimeMachine, action: Input.Action) void {
                if (!self.atPresent()) {
                    self.inputs_forgotten += self.log.truncateAfter(self.world.step);
                    self.head_step = self.world.step;
                    self.branches += 1;
                }
                if (!self.log.record(.{ .step = self.world.step, .action = action })) {
                    self.log_full = true;
                    return;
                }
                self.world.apply(action);
                self.live_checksums[self.head_step] = self.world.checksum();
                self.playing = true;
            }

            fn handleCanvasInput(self: *TimeMachine, ui: *Ui) void {
                const placement: WorldPlacement = .of(ui.rectOf(ids.canvas) orelse return);
                if (ui.pressed(ids.canvas)) {
                    const local = ui.pointerLocal(ids.canvas) orelse return;
                    const at_world = placement.toWorld(local);
                    if (!self.aim.active) self.aim = .{ .from = at_world, .to = at_world, .active = true };
                    self.aim.to = at_world;
                } else if (self.aim.active) {
                    self.aim.active = false;
                    self.take(.{ .fling = .{
                        .position = self.aim.from,
                        .velocity = .{ (self.aim.to[0] - self.aim.from[0]) * fling_strength, (self.aim.to[1] - self.aim.from[1]) * fling_strength },
                    } });
                }
            }

            /// The world drawn as large as fits the canvas, centered in it.
            const WorldPlacement = struct {
                scale: f32,
                origin: [2]f32,

                fn of(canvas: zui.Rect) WorldPlacement {
                    const scale = @max(0.05, @min(canvas.width / world_size[0], canvas.height / world_size[1]));
                    return .{ .scale = scale, .origin = .{ @round((canvas.width - world_size[0] * scale) / 2), @round((canvas.height - world_size[1] * scale) / 2) } };
                }

                fn toWorld(placement: WorldPlacement, local: [2]f32) [2]f32 {
                    return .{
                        std.math.clamp((local[0] - placement.origin[0]) / placement.scale, 0, world_size[0]),
                        std.math.clamp((local[1] - placement.origin[1]) / placement.scale, 0, world_size[1]),
                    };
                }

                fn toCanvas(placement: WorldPlacement, point: [2]f32) [2]f32 {
                    return .{ placement.origin[0] + point[0] * placement.scale, placement.origin[1] + point[1] * placement.scale };
                }
            };

            fn bodyColor(colors: kit.Colors, hue_index: u8) zui.Color {
                return switch (hue_index % 4) {
                    0 => colors.get(.danger),
                    1 => colors.get(.accent),
                    2 => colors.get(.success),
                    else => colors.get(.warning),
                };
            }

            fn canvasCard(self: *TimeMachine, ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                shell.openCard(ui, "", .{ .width = .grow, .height = .grow });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                    defer ui.close();
                    shell.label(ui, .heading, "Drag on the field to fling a ball");
                    shell.spacer(ui);
                    if (!self.atPresent()) shell.chip(ui, "in the past: input here starts a branch", .warning);
                }
                const placement: WorldPlacement = .of(ui.rectOf(ids.canvas) orelse .{ .width = world_size[0], .height = world_size[1] });
                const scale = placement.scale;
                ui.open(.{
                    .id = ids.canvas,
                    .interactive = true,
                    .cursor = .crosshair,
                    .layout = .{ .sizing = .{ .width = .grow, .height = .grow } },
                    .clip = .both,
                });
                defer ui.close();
                ui.box(.{
                    .floating = .{ .offset = placement.origin, .capture = false, .clip = .target },
                    .layout = .{ .sizing = .{ .width = .fixed(world_size[0] * scale), .height = .fixed(world_size[1] * scale) } },
                    .decoration = .{ .background = colors.get(.surface_sunken), .border = .{ .color = colors.get(.outline_muted), .widths = .all(1) }, .corner_radius = .all(6) },
                });
                for (self.world.bodies[0..self.world.count]) |body| {
                    const diameter = body.radius * 2 * scale;
                    const top_left = placement.toCanvas(.{ body.position[0] - body.radius, body.position[1] - body.radius });
                    ui.box(.{
                        .floating = .{ .offset = top_left, .capture = false, .clip = .target },
                        .layout = .{ .sizing = .{ .width = .fixed(diameter), .height = .fixed(diameter) } },
                        .decoration = .{ .background = bodyColor(colors, body.hue_index), .corner_radius = .all(diameter / 2) },
                    });
                }
                if (self.aim.active) {
                    const dots = 8;
                    for (0..dots + 1) |index| {
                        const along = @as(f32, @floatFromInt(index)) / dots;
                        const point = placement.toCanvas(.{ self.aim.from[0] + (self.aim.to[0] - self.aim.from[0]) * along, self.aim.from[1] + (self.aim.to[1] - self.aim.from[1]) * along });
                        ui.box(.{
                            .floating = .{ .offset = .{ point[0] - 3, point[1] - 3 }, .capture = false, .clip = .target },
                            .layout = .{ .sizing = .{ .width = .fixed(6), .height = .fixed(6) } },
                            .decoration = .{ .background = colors.get(.on_surface), .corner_radius = .all(3) },
                        });
                    }
                }
            }

            fn proofCard(self: *TimeMachine, ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                shell.openScrollingCard(ui, ids.proof, "", .{ .width = .fixed(330), .height = .grow });
                defer ui.close();
                shell.labelColored(ui, .caption, colors.get(.on_surface_accent), "THE STATE IS A FUNCTION OF THE LOG");
                const checksum = self.world.checksum();
                const live_checksum = self.live_checksums[self.world.step];
                const identical = checksum == live_checksum;
                if (self.rebuilds == 0) {
                    shell.labelColored(ui, .title, colors.get(.on_surface_muted), "Scrub back");
                    shell.labelColored(ui, .caption, colors.get(.on_surface_muted), "Drag the timeline: each position is rebuilt from nothing by replaying the log, and checked against the live run.");
                } else {
                    shell.labelColored(ui, .title, if (identical) colors.get(.on_surface_accent) else colors.get(.on_danger_container), if (identical) "Identical" else "Different");
                }
                shell.print(ui, .caption, "step {d}, rebuilt   {x:0>8}", .{ self.world.step, checksum });
                shell.print(ui, .caption, "step {d}, live run  {x:0>8}", .{ self.world.step, live_checksum });
                shell.divider(ui);
                stat(ui, shell, "inputs recorded", "{d} of {d}", .{ self.log.count, log_capacity });
                stat(ui, shell, "last rebuild replayed", "{d} steps", .{self.last_replay.steps});
                stat(ui, shell, "inputs applied", "{d}", .{self.last_replay.inputs_applied});
                stat(ui, shell, "rebuild took", "{d:.0} us", .{self.last_replay.microseconds});
                stat(ui, shell, "branches", "{d}, {d} inputs forgotten", .{ self.branches, self.inputs_forgotten });
                if (self.log_full) shell.labelColored(ui, .caption, colors.get(.on_warning_container), "The log is full: further input is refused, not half kept. Reset to start over.");
                shell.divider(ui);
                shell.labelColored(ui, .caption, colors.get(.on_surface_muted), "zui records a whole UI the same way: ui.relayTo(listener) hands over each frame record, its time, events and source deliveries, and feeding them back declares the identical commands.");
                shell.label(ui, .tiny, "INPUT LOG, NEWEST LAST");
                const shown = @min(self.log.count, 6);
                for (self.log.inputs[self.log.count - shown .. self.log.count]) |input| {
                    const line_style: Ui.TextStyle = .{ .size = 12 * shell.text_scale, .font = shell.fonts.mono, .color = if (input.step <= self.world.step) colors.get(.on_surface) else colors.get(.on_surface_muted) };
                    var line: [64]u8 = undefined;
                    ui.text(switch (input.action) {
                        .fling => |fling| std.fmt.bufPrint(&line, "#{d:0>4} fling {d:.0},{d:.0}", .{ input.step, fling.velocity[0], fling.velocity[1] }) catch "fling",
                        .toggle_gravity => std.fmt.bufPrint(&line, "#{d:0>4} gravity", .{input.step}) catch "gravity",
                    }, line_style);
                }
            }

            fn stat(ui: *Ui, shell: *const Shell, name: []const u8, comptime format: []const u8, arguments: anytype) void {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
                defer ui.close();
                shell.label(ui, .caption, name);
                shell.spacer(ui);
                shell.print(ui, .caption, format, arguments);
            }

            fn timelineCard(self: *TimeMachine, ui: *Ui, shell: *const Shell) void {
                const colors = shell.colors;
                shell.openCard(ui, "", .{ .width = .grow });
                defer ui.close();
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 10, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                if (shell.widgets.button(ui, ids.play, if (self.playing) "Pause" else "Play", .{ .width = .fixed(72) })) {
                    self.playing = !self.playing;
                    self.step_time_debt = 0;
                    ui.requestFrame();
                }
                if (shell.widgets.button(ui, ids.present, "Now", .{ .disabled = self.atPresent() })) {
                    self.scrubTo(ui, self.head_step, shell);
                }
                var view_step: u32 = self.world.step;
                if (shell.widgets.slider(ui, ids.timeline, &view_step, .{ .min = 0, .max = @floatFromInt(@max(1, self.head_step)), .label = "timeline" })) {
                    self.playing = false;
                    self.scrubTo(ui, @min(view_step, self.head_step), shell);
                }
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(150) }, .child_alignment = .{ .x = .end } } });
                shell.printColored(ui, .caption, if (self.atPresent()) colors.get(.on_surface) else colors.get(.on_warning_container), "{d:.1} / {d:.1} s", .{ secondsAt(self.world.step), secondsAt(self.head_step) });
                ui.close();
                if (shell.widgets.button(ui, ids.gravity, if (self.world.gravity) "Gravity off" else "Gravity on", .{})) self.take(.toggle_gravity);
                if (shell.widgets.button(ui, ids.reset, "Reset", .{})) {
                    self.start();
                    ui.requestFrame();
                }
            }

            fn secondsAt(step: u32) f32 {
                return @as(f32, @floatFromInt(step)) / steps_per_second;
            }
        };
    };
}

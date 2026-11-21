//! Tweens and springs over `ui.state`, which ask for frames only while they
//! move and land at once when the user asks for reduced motion.
//!
//! ```zig
//! const opacity = zui_motion.tween(ui, .of("toast"), f32, if (app.importing) 1 else 0, .{ .duration = 0.25 });
//! const background = zui_motion.tween(ui, .of("save"), zui.Color, if (ui.hovered(.of("save"))) hover_color else rest_color, .{});
//! const drawer_x = zui_motion.spring(ui, .of("drawer"), f32, if (app.drawer_open) 0 else -280, .{});
//! ```

const std = @import("std");
const zui = @import("zui");

/// How a tween's progress, from 0 to 1, becomes the share of the way it has
/// moved. Every easing maps 0 to 0 and 1 to 1 exactly.
pub const Easing = enum {
    linear,
    /// Starts slowly and ends at full speed: cubic.
    ease_in,
    /// Starts at full speed and slows to a stop: cubic.
    ease_out,
    /// Slow at both ends: cubic.
    ease_in_out,

    pub fn apply(easing: Easing, progress: f32) f32 {
        const clamped = std.math.clamp(progress, 0, 1);
        return switch (easing) {
            .linear => clamped,
            .ease_in => clamped * clamped * clamped,
            .ease_out => 1 - cube(1 - clamped),
            .ease_in_out => if (clamped < 0.5) 4 * cube(clamped) else 1 - cube(2 - 2 * clamped) / 2,
        };
    }

    fn cube(value: f32) f32 {
        return value * value * value;
    }
};

pub const TweenOptions = struct {
    /// Seconds from the old value to the new one; 0 or less lands at once.
    duration: f32 = 0.2,
    easing: Easing = .ease_out,
    /// Seconds to hold the old value before moving, during which the tween
    /// asks for a frame at the instant it starts rather than for every frame.
    delay: f32 = 0,
};

/// Eases the value for `element_id` toward `target` over
/// `options.duration`, returning this frame's value. The first target a
/// tween sees is where it starts, without moving; a later one starts a new
/// tween from the current value, so changing the target mid-flight keeps
/// the value continuous. While it moves it asks for the next frame, and at
/// rest it asks for none, so an application that uses it still idles.
/// Under `reduced_motion` it lands on the target in the frame it changes.
///
/// `T` is `f32`, `[N]f32`, `zui.Color`, `zui.ExtendedColor`, or a struct of
/// them. A `zui.Color` is interpolated per sRGB channel, as `Color.mix`
/// and CSS transitions do; a `zui.ExtendedColor`, per linear channel.
/// Its state takes one of `limits.state_slots`; when the table is full the
/// tween reports `.state_slots` and returns `target`.
///
/// ```zig
/// const card_offset = zui_motion.tween(ui, card_id, [2]f32, if (app.expanded) .{ 0, 0 } else .{ 0, 40 }, .{ .duration = 0.3, .easing = .ease_in_out });
/// ```
pub fn tween(ui: anytype, element_id: zui.Id, comptime T: type, target: T, options: TweenOptions) T {
    comptime checkAnimatable(T);
    const motion = ui.state(element_id, TweenState(T));
    const now = ui.now();
    if (motion.phase == .unset or ui.environment().reduced_motion) {
        motion.* = .{ .from = target, .to = target, .starts_at = now, .phase = .at_rest };
        return target;
    }
    if (!std.meta.eql(motion.to, target)) {
        motion.from = motion.valueAt(now, options);
        motion.to = target;
        motion.starts_at = now.addSeconds(options.delay);
        motion.phase = .moving;
    }
    if (motion.phase == .at_rest) return motion.to;
    if (now.isBefore(motion.starts_at)) {
        ui.requestFrameAt(motion.starts_at);
        return motion.from;
    }
    const progress = motion.progressAt(now, options);
    if (progress >= 1) {
        motion.phase = .at_rest;
        return motion.to;
    }
    ui.requestFrame();
    return interpolate(T, motion.from, motion.to, options.easing.apply(progress));
}

pub const SpringOptions = struct {
    /// How quickly the value follows, in radians per second: it covers
    /// about 99% of the way in `6.6 / angular_frequency` seconds.
    angular_frequency: f32 = 20,
    /// Within this distance of the target, and moving slower than this
    /// distance per `1 / angular_frequency` seconds, the value lands on it.
    rest_distance: f32 = 0.001,
};

/// Follows `target` with a critically damped spring, which never
/// overshoots a target it starts toward at rest, and keeps its velocity
/// when the target moves, so a value chasing a pointer or a drag stays
/// smooth. It returns this frame's value, asks for the next frame while it
/// moves and for none at rest. The first target it sees is where it starts.
/// Under `reduced_motion` it lands on the target in the frame it changes.
///
/// `T` is as `tween` takes, though its state holds a position and a
/// velocity for each number in `T`, so fewer of them fit a state slot.
///
/// ```zig
/// const thumb_x = zui_motion.spring(ui, thumb_id, f32, app.volume * track_width, .{ .angular_frequency = 30 });
/// ```
pub fn spring(ui: anytype, element_id: zui.Id, comptime T: type, target: T, options: SpringOptions) T {
    comptime checkAnimatable(T);
    const motion = ui.state(element_id, SpringState(T));
    if (motion.phase == .unset or ui.environment().reduced_motion) {
        motion.settle(target);
        return target;
    }
    if (!std.meta.eql(motion.target, target)) {
        motion.target = target;
        if (motion.phase == .at_rest) {
            // The time since the previous frame was spent at rest, not moving.
            motion.phase = .moving;
            ui.requestFrame();
            return fromComponents(T, &motion.position);
        }
    }
    if (motion.phase == .at_rest) return target;
    if (motion.advance(ui.dt(), options)) {
        motion.settle(target);
        return target;
    }
    ui.requestFrame();
    return fromComponents(T, &motion.position);
}

const Phase = enum(u8) { unset, moving, at_rest };

fn TweenState(comptime T: type) type {
    return struct {
        const Self = @This();

        from: T,
        to: T,
        starts_at: zui.Instant,
        phase: Phase,

        fn progressAt(self: *const Self, now: zui.Instant, options: TweenOptions) f32 {
            if (options.duration <= 0) return 1;
            return now.secondsSince(self.starts_at) / options.duration;
        }

        fn valueAt(self: *const Self, now: zui.Instant, options: TweenOptions) T {
            if (self.phase == .at_rest) return self.to;
            if (now.isBefore(self.starts_at)) return self.from;
            const progress = self.progressAt(now, options);
            if (progress >= 1) return self.to;
            return interpolate(T, self.from, self.to, options.easing.apply(progress));
        }
    };
}

fn SpringState(comptime T: type) type {
    const count = componentCount(T);
    return struct {
        const Self = @This();

        position: [count]f32,
        velocity: [count]f32,
        target: T,
        phase: Phase,

        fn settle(self: *Self, target: T) void {
            self.* = .{ .position = undefined, .velocity = @splat(0), .target = target, .phase = .at_rest };
            writeComponents(T, target, &self.position);
        }

        /// Steps the spring exactly by `dt`, and reports whether it came to rest.
        fn advance(self: *Self, dt: f32, options: SpringOptions) bool {
            const omega = options.angular_frequency;
            const decay = @exp(-omega * dt);
            var target: [count]f32 = undefined;
            writeComponents(T, self.target, &target);
            var at_rest = true;
            for (&self.position, &self.velocity, target) |*position, *velocity, goal| {
                const offset = position.* - goal;
                const momentum = velocity.* + omega * offset;
                position.* = goal + (offset + momentum * dt) * decay;
                velocity.* = (velocity.* - omega * momentum * dt) * decay;
                if (@abs(position.* - goal) > options.rest_distance or @abs(velocity.*) > options.rest_distance * omega) at_rest = false;
            }
            return at_rest;
        }
    };
}

fn checkAnimatable(comptime T: type) void {
    _ = componentCount(T);
}

fn componentCount(comptime T: type) usize {
    if (T == f32) return 1;
    if (T == zui.Color or T == zui.ExtendedColor) return 4;
    switch (@typeInfo(T)) {
        .array => |array| if (array.child == f32) return array.len,
        .@"struct" => |structure| if (structure.fields.len > 0) {
            var count: usize = 0;
            for (structure.fields) |field| count += componentCount(field.type);
            return count;
        },
        else => {},
    }
    @compileError("zui_motion: cannot animate " ++ @typeName(T) ++ "; animate f32, [N]f32, zui.Color, zui.ExtendedColor or a struct of them");
}

fn interpolate(comptime T: type, from: T, to: T, amount: f32) T {
    const count = comptime componentCount(T);
    var from_components: [count]f32 = undefined;
    var to_components: [count]f32 = undefined;
    writeComponents(T, from, &from_components);
    writeComponents(T, to, &to_components);
    for (&from_components, to_components) |*component, to_component| component.* += (to_component - component.*) * amount;
    return fromComponents(T, &from_components);
}

fn writeComponents(comptime T: type, value: T, components: *[componentCount(T)]f32) void {
    if (T == f32) {
        components[0] = value;
    } else if (T == zui.Color) {
        components.* = .{ channelOf(value.r), channelOf(value.g), channelOf(value.b), channelOf(value.a) };
    } else if (T == zui.ExtendedColor) {
        components.* = .{ value.r, value.g, value.b, value.a };
    } else switch (@typeInfo(T)) {
        .array => components.* = value,
        .@"struct" => |structure| {
            comptime var offset: usize = 0;
            inline for (structure.fields) |field| {
                const field_count = comptime componentCount(field.type);
                writeComponents(field.type, @field(value, field.name), components[offset..][0..field_count]);
                offset += field_count;
            }
        },
        else => comptime unreachable,
    }
}

fn fromComponents(comptime T: type, components: *const [componentCount(T)]f32) T {
    if (T == f32) return components[0];
    if (T == zui.Color) return .{ .r = byteOf(components[0]), .g = byteOf(components[1]), .b = byteOf(components[2]), .a = byteOf(components[3]) };
    if (T == zui.ExtendedColor) return .{ .r = @floatCast(components[0]), .g = @floatCast(components[1]), .b = @floatCast(components[2]), .a = @floatCast(components[3]) };
    switch (@typeInfo(T)) {
        .array => return components.*,
        .@"struct" => |structure| {
            var value: T = undefined;
            comptime var offset: usize = 0;
            inline for (structure.fields) |field| {
                const field_count = comptime componentCount(field.type);
                @field(value, field.name) = fromComponents(field.type, components[offset..][0..field_count]);
                offset += field_count;
            }
            return value;
        },
        else => comptime unreachable,
    }
}

fn channelOf(byte: u8) f32 {
    return @as(f32, @floatFromInt(byte)) / 255;
}

fn byteOf(channel: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(channel, 0, 1) * 255));
}

test {
    _ = @import("tests.zig");
}

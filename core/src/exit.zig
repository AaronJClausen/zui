const std = @import("std");
const style = @import("style.zig");
const Instant = @import("record.zig").Instant;

/// How an element leaves once it is no longer declared: its last commands
/// keep drawing for `seconds`, taking no space and no hits, as its fade
/// says. Needs an id, and `Config.limits.exit_ghost_commands` above 0;
/// without that limit it is ignored, so a widget can declare it for every
/// context.
///
/// ```zig
/// if (app.toast) |message| {
///     ui.open(.{ .id = .of("toast"), .floating = toast_place, .exit = .{ .seconds = 0.25, .fade = .ease_out } });
///     defer ui.close();
///     ui.text(message, styles.toast);
/// }
/// ```
pub const Exit = struct {
    seconds: f32,
    fade: ExitFade = .linear,
};

/// The opacity of a ghost over its seconds. Every color its commands draw
/// is multiplied in alpha by `opacityAt`.
pub const ExitFade = enum(u8) {
    /// Held unchanged, then gone: no alpha is touched.
    none,
    linear,
    /// Fades slowly at first: cubic.
    ease_in,
    /// Fades quickly at first: cubic.
    ease_out,
    /// Slow at both ends: cubic.
    ease_in_out,

    /// 1 at `progress` 0 and 0 at `progress` 1, exactly. `.none` holds 1.
    pub fn opacityAt(fade: ExitFade, progress: f32) f32 {
        const clamped = std.math.clamp(progress, 0, 1);
        return 1 - switch (fade) {
            .none => 0,
            .linear => clamped,
            .ease_in => cube(clamped),
            .ease_out => 1 - cube(1 - clamped),
            .ease_in_out => if (clamped < 0.5) 4 * cube(clamped) else 1 - cube(2 - 2 * clamped) / 2,
        };
    }

    fn cube(value: f32) f32 {
        return value * value * value;
    }
};

/// One element's commands in a `GhostStore`: the snapshot of a candidate
/// declared in the frame the store was written for, or a ghost that has
/// exited.
pub const Ghost = struct {
    id: u64,
    /// The nearest enclosing element that also declares `exit`, whose own
    /// ghost holds this one's commands; 0 for none.
    enclosing_id: u64,
    exit: Exit,
    /// The `now` of the last frame its element was declared.
    since: Instant,
    first_command: u32,
    command_count: u32,
    exited: bool,

    pub fn progressAt(self: *const Ghost, now: Instant) f32 {
        return now.secondsSince(self.since) / self.exit.seconds;
    }
};

/// The commands kept for exit animations in one frame, with the bytes of
/// the text they draw. A ghost is written whole or not at all, so a ghost's
/// clips always end.
pub fn GhostStore(comptime RenderCommand: type, comptime command_capacity: u32, comptime text_capacity: u32) type {
    return struct {
        const Self = @This();

        commands: [command_capacity]RenderCommand,
        command_count: u32,
        text: [text_capacity]u8,
        text_count: u32,
        /// Each holds at least one command.
        ghosts: [command_capacity]Ghost,
        ghost_count: u32,
        pending_first_command: u32,
        pending_text_start: u32,
        /// Set once a command or its text did not fit; the pending ghost is
        /// then abandoned.
        pending_overflowed: bool,

        pub fn reset(self: *Self) void {
            self.command_count = 0;
            self.text_count = 0;
            self.ghost_count = 0;
        }

        pub fn begin(self: *Self) void {
            self.pending_first_command = self.command_count;
            self.pending_text_start = self.text_count;
            self.pending_overflowed = false;
        }

        /// Copies `command` and the text it draws.
        pub fn append(self: *Self, command: RenderCommand) void {
            if (self.pending_overflowed) return;
            if (self.command_count == command_capacity) {
                self.pending_overflowed = true;
                return;
            }
            var kept = command;
            if (kept.payload == .text) {
                const content = kept.payload.text.content;
                if (text_capacity - self.text_count < content.len) {
                    self.pending_overflowed = true;
                    return;
                }
                const copy = self.text[self.text_count..][0..content.len];
                @memcpy(copy, content);
                self.text_count += @intCast(content.len);
                kept.payload.text.content = copy;
            }
            self.commands[self.command_count] = kept;
            self.command_count += 1;
        }

        /// Keeps what was appended since `begin` as one ghost, or drops it
        /// all and returns false if any of it did not fit.
        pub fn finish(self: *Self, ghost: Ghost) bool {
            if (self.pending_overflowed) {
                self.command_count = self.pending_first_command;
                self.text_count = self.pending_text_start;
                return false;
            }
            const count = self.command_count - self.pending_first_command;
            if (count == 0) return true;
            var kept = ghost;
            kept.first_command = self.pending_first_command;
            kept.command_count = count;
            self.ghosts[self.ghost_count] = kept;
            self.ghost_count += 1;
            return true;
        }

        pub fn commandsOf(self: *const Self, ghost: *const Ghost) []const RenderCommand {
            return self.commands[ghost.first_command..][0..ghost.command_count];
        }

        pub fn keptGhosts(self: *const Self) []const Ghost {
            return self.ghosts[0..self.ghost_count];
        }
    };
}

/// Two stores, one written each frame while the other holds the last
/// frame's snapshots and ghosts.
pub fn Ghosts(comptime RenderCommand: type, comptime command_capacity: u32, comptime text_capacity: u32) type {
    return struct {
        const Self = @This();
        pub const Store = GhostStore(RenderCommand, command_capacity, text_capacity);

        stores: [2]Store,
        latest: u1,

        pub fn reset(self: *Self) void {
            for (&self.stores) |*store| store.reset();
            self.latest = 0;
        }

        pub fn previous(self: *Self) *Store {
            return &self.stores[self.latest];
        }

        pub fn next(self: *Self) *Store {
            return &self.stores[1 - self.latest];
        }

        /// Makes the store just written the previous one for the next frame.
        pub fn advance(self: *Self) void {
            self.latest = 1 - self.latest;
        }
    };
}

/// `color` with its alpha multiplied by `opacity`, for `Color` or
/// `ExtendedColor`.
pub inline fn faded(color: anytype, opacity: f32) @TypeOf(color) {
    var result = color;
    if (@TypeOf(color) == style.Color) {
        result.a = @intFromFloat(@round(@as(f32, @floatFromInt(color.a)) * opacity));
    } else {
        result.a = @floatCast(@as(f32, color.a) * opacity);
    }
    return result;
}

/// Multiplies the alpha of every color `command` draws by `opacity`.
pub fn fadeCommand(comptime RenderCommand: type, command: *RenderCommand, opacity: f32) void {
    switch (command.payload) {
        .rectangle => |*rectangle| rectangle.color = faded(rectangle.color, opacity),
        .border => |*border| border.color = faded(border.color, opacity),
        .text => |*text| text.style.color = faded(text.style.color, opacity),
        inline else => |*payload, tag| {
            const name = @tagName(tag);
            if (comptime std.mem.eql(u8, name, "image")) {
                payload.tint = faded(payload.tint, opacity);
            } else if (comptime std.mem.eql(u8, name, "gradient")) {
                payload.from = faded(payload.from, opacity);
                payload.to = faded(payload.to, opacity);
            } else if (comptime std.mem.eql(u8, name, "shadow")) {
                payload.color = faded(payload.color, opacity);
            } else if (comptime std.mem.eql(u8, name, "backdrop_blur")) {
                payload.tint = faded(payload.tint, opacity);
            } else if (comptime std.mem.eql(u8, name, "material")) {
                payload.fallback = faded(payload.fallback, opacity);
            }
        },
    }
}

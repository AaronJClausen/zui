const std = @import("std");
const style = @import("style.zig");

pub const Button = enum { primary, secondary, middle };

/// Navigation and editing keys. Mapping platform key codes onto these is
/// the backend's job.
pub const Key = enum { tab, enter, escape, space, backspace, delete, left, right, up, down, home, end, page_up, page_down };

/// Held modifier keys, as state rather than events.
pub const Modifiers = packed struct(u4) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const WidgetState = enum { idle, hovered, pressed, focused, disabled };

/// Per frame, zui keeps at most this many key events and bytes of typed
/// text; the rest of a frame's events are dropped.
pub const max_keys_per_frame = 32;
pub const max_text_input_bytes = 128;

/// Scroll position of a scroll container, kept in the state table under
/// the container's id.
pub const ScrollState = struct {
    offset: [2]f32 = .{ 0, 0 },
};

pub const RegionFlags = packed struct(u8) {
    interactive: bool = false,
    focusable: bool = false,
    disabled: bool = false,
    scroll_x: bool = false,
    scroll_y: bool = false,
    _: u3 = 0,

    pub fn scrolls(self: RegionFlags, axis: usize) bool {
        return if (axis == 0) self.scroll_x else self.scroll_y;
    }
};

pub const no_region = std.math.maxInt(u32);

/// A part of the last frame the pointer can hit, in paint order.
pub const Region = struct {
    hash: u64,
    /// The element's rectangle, clipped by its ancestors.
    bounds: style.Rect,
    z: i16,
    /// The nearest enclosing region in the tree, or `no_region`.
    parent: u32,
    flags: RegionFlags,
    /// For scroll containers: the largest offset per axis.
    max_scroll: [2]f32,
};

pub const Focusable = struct {
    hash: u64,
    /// The innermost `focus_scope` element containing this one, or 0.
    scope: u64,
};

/// What zui keeps of the previous frame for interaction queries. It lives in
/// the Context, not in a frame, because with `frames_in_flight = 1` the
/// previous frame's memory is reused before the queries run.
pub fn Results(comptime max_regions: u32, comptime table_slots: u32) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            hash: u64,
            rect: style.Rect,
            region: u32,
        };

        has_frame: bool,
        entries: [table_slots]Entry,
        /// The slots of `entries` in use, so `clear` touches only those
        /// rather than the whole table.
        used_slots: [max_regions]u32,
        used_slot_count: u32,
        regions: [max_regions]Region,
        region_count: u32,
        focusables: [max_regions]Focusable,
        focusable_count: u32,

        pub fn reset(self: *Self) void {
            for (&self.entries) |*entry| entry.hash = 0;
            self.used_slot_count = 0;
            self.region_count = 0;
            self.focusable_count = 0;
            self.has_frame = false;
        }

        pub fn clear(self: *Self) void {
            for (self.used_slots[0..self.used_slot_count]) |slot| self.entries[slot].hash = 0;
            self.used_slot_count = 0;
            self.region_count = 0;
            self.focusable_count = 0;
        }

        /// At most one insert per element, so `used_slots` cannot overflow.
        pub fn insert(self: *Self, hash: u64, rect: style.Rect, region: u32) void {
            var slot: usize = @as(usize, @truncate(hash)) & (table_slots - 1);
            while (self.entries[slot].hash != 0 and self.entries[slot].hash != hash) slot = (slot + 1) & (table_slots - 1);
            if (self.entries[slot].hash == 0) {
                self.used_slots[self.used_slot_count] = @intCast(slot);
                self.used_slot_count += 1;
            }
            self.entries[slot] = .{ .hash = hash, .rect = rect, .region = region };
        }

        pub fn find(self: *const Self, hash: u64) ?*const Entry {
            if (!self.has_frame or hash == 0) return null;
            var slot: usize = @as(usize, @truncate(hash)) & (table_slots - 1);
            while (self.entries[slot].hash != 0) : (slot = (slot + 1) & (table_slots - 1)) {
                if (self.entries[slot].hash == hash) return &self.entries[slot];
            }
            return null;
        }

        pub fn regionFlags(self: *const Self, hash: u64) RegionFlags {
            const entry = self.find(hash) orelse return .{};
            if (entry.region == no_region) return .{};
            return self.regions[entry.region].flags;
        }

        /// The region the pointer hits: the highest z, and within a layer
        /// the last painted.
        pub fn topmostAt(self: *const Self, point: [2]f32) ?u32 {
            var top: ?u32 = null;
            for (self.regions[0..self.region_count], 0..) |region, index| {
                if (!region.bounds.contains(point)) continue;
                if (top == null or region.z >= self.regions[top.?].z) top = @intCast(index);
            }
            return top;
        }

        /// The next focusable element after `current` in `direction`,
        /// staying inside `current`'s focus scope.
        pub fn nextFocus(self: *const Self, current: u64, forward: bool) u64 {
            const count = self.focusable_count;
            if (count == 0) return 0;
            const current_index = for (self.focusables[0..count], 0..) |focusable, index| {
                if (focusable.hash == current) break index;
            } else return if (forward) self.focusables[0].hash else self.focusables[count - 1].hash;

            const scope = self.focusables[current_index].scope;
            for (1..count) |step| {
                const index = if (forward) (current_index + step) % count else (current_index + count - step) % count;
                if (self.focusables[index].scope == scope) return self.focusables[index].hash;
            }
            return current;
        }

        pub fn isFocusable(self: *const Self, hash: u64) bool {
            for (self.focusables[0..self.focusable_count]) |focusable| {
                if (focusable.hash == hash) return true;
            }
            return false;
        }
    };
}

/// Input copied out of `Input` plus what is derived from it each frame.
pub fn State(comptime max_chain: usize) type {
    return struct {
        const Self = @This();

        pointer: ?[2]f32 = null,
        buttons: std.EnumSet(Button) = .initEmpty(),
        modifiers: Modifiers = .{},
        keys: [max_keys_per_frame]Key = undefined,
        key_count: u8 = 0,
        text: [max_text_input_bytes]u8 = undefined,
        text_len: u8 = 0,

        /// Interactive elements under the pointer, innermost first.
        hover_chain: [max_chain]u64 = undefined,
        hover_count: u16 = 0,
        press_target: u64 = 0,
        clicked: u64 = 0,
        focus: u64 = 0,
        pending_focus: ?u64 = null,
        frame_number: u32 = 0,

        pub fn isHovered(self: *const Self, hash: u64) bool {
            for (self.hover_chain[0..self.hover_count]) |hovered| {
                if (hovered == hash) return true;
            }
            return false;
        }

        pub fn keyPressed(self: *const Self, key: Key) bool {
            return std.mem.indexOfScalar(Key, self.keys[0..self.key_count], key) != null;
        }
    };
}

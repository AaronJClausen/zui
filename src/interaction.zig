const std = @import("std");
const style = @import("style.zig");
const input = @import("input.zig");

pub const WidgetState = enum { idle, hovered, pressed, focused, disabled };

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

/// One slot of the pointer table: a contact touching or hovering over the
/// surface.
pub fn Contact(comptime max_chain: usize) type {
    return struct {
        const Self = @This();

        pointer: input.Pointer,
        buttons: std.EnumSet(input.Button),
        /// The element the primary button's press began on, or 0.
        press_target: u64,
        /// When its primary press began, counted across contacts, so the
        /// first touch still down can be found.
        press_order: u64,
        /// Moved since its hover was last hit-tested. Moves coalesce: only
        /// the last one before another event of this pointer is tested.
        hover_stale: bool,
        /// Interactive elements under the pointer, innermost first. Empty
        /// for touch, which never hovers.
        hover_chain: [max_chain]u64,
        hover_count: u16,
        /// A touch that lifted this frame. It stays until the next frame
        /// begins, so the frame that sees a tap can still ask where it was.
        lifted: bool,

        pub fn init(pointer: input.Pointer) Self {
            return .{ .pointer = pointer, .buttons = .initEmpty(), .press_target = 0, .press_order = 0, .hover_stale = false, .hover_chain = undefined, .hover_count = 0, .lifted = false };
        }

        pub fn hovers(self: *const Self) bool {
            return self.pointer.kind != .touch;
        }

        pub fn isHovering(self: *const Self, hash: u64) bool {
            return std.mem.indexOfScalar(u64, self.hover_chain[0..self.hover_count], hash) != null;
        }
    };
}

/// The pointer table plus what this frame's events delivered, which the
/// interaction queries read until the next `beginFrame`.
pub fn State(comptime max_contacts: u8, comptime max_chain: usize, comptime max_events: u16, comptime max_text_bytes: u16, comptime max_path_bytes: u32) type {
    return struct {
        const Self = @This();
        pub const Slot = Contact(max_chain);

        contacts: [max_contacts]?Slot,
        presses_begun: u64,

        key_events: [max_events]input.KeyEvent,
        key_event_count: u16,
        text: [max_text_bytes]u8,
        text_len: u16,
        clicked: [max_events]u64,
        clicked_count: u16,
        dropped_paths: [max_path_bytes]u8,
        dropped_path_len: u32,
        drops: [if (max_path_bytes == 0) 0 else max_events]input.FilesDropped,
        drop_count: u16,
        lifecycle: input.LifecycleSet,

        focus: u64,
        pending_focus: ?u64,

        pub fn reset(self: *Self) void {
            self.contacts = @splat(null);
            self.presses_begun = 0;
            self.focus = 0;
            self.pending_focus = null;
            self.clearFrameEvents();
        }

        pub fn clearFrameEvents(self: *Self) void {
            for (&self.contacts) |*slot| {
                if (slot.*) |*contact| if (contact.lifted) {
                    slot.* = null;
                };
            }
            self.key_event_count = 0;
            self.text_len = 0;
            self.clicked_count = 0;
            self.dropped_path_len = 0;
            self.drop_count = 0;
            self.lifecycle = .initEmpty();
        }

        pub fn find(self: *Self, id: input.PointerId) ?*Slot {
            for (&self.contacts) |*slot| {
                if (slot.*) |*contact| if (contact.pointer.id == id) return contact;
            }
            return null;
        }

        /// The contact for `pointer`, taking a free slot for a new one.
        /// Null when the table is full: like a digitizer, the extra contact
        /// is ignored until a slot frees.
        pub fn findOrAdd(self: *Self, pointer: input.Pointer) ?*Slot {
            if (self.find(pointer.id)) |contact| {
                contact.lifted = false;
                return contact;
            }
            for (&self.contacts) |*slot| {
                if (slot.* == null) {
                    slot.* = .init(pointer);
                    return &slot.*.?;
                }
            }
            return null;
        }

        pub fn remove(self: *Self, contact: *Slot) void {
            for (&self.contacts) |*slot| {
                if (slot.*) |*occupied| if (occupied == contact) {
                    slot.* = null;
                    return;
                };
            }
        }

        pub fn isHovered(self: *const Self, hash: u64) bool {
            for (&self.contacts) |*slot| {
                if (slot.*) |*contact| if (contact.isHovering(hash)) return true;
            }
            return false;
        }

        pub fn isPressed(self: *const Self, hash: u64) bool {
            for (&self.contacts) |*slot| {
                if (slot.*) |*contact| if (contact.press_target == hash and contact.buttons.contains(.primary)) return true;
            }
            return false;
        }

        pub fn isClicked(self: *const Self, hash: u64) bool {
            return std.mem.indexOfScalar(u64, self.clicked[0..self.clicked_count], hash) != null;
        }

        /// Each click takes at least one event, so `clicked` cannot overflow.
        pub fn addClick(self: *Self, hash: u64) void {
            if (self.isClicked(hash)) return;
            self.clicked[self.clicked_count] = hash;
            self.clicked_count += 1;
        }

        /// The mouse or a pen over the surface, whose hover the cursor follows.
        pub fn hoveringContact(self: *const Self) ?*const Slot {
            for (&self.contacts) |*slot| {
                if (slot.*) |*contact| if (contact.hovers()) return contact;
            }
            return null;
        }

        /// The mouse or a pen while over the surface, or else the first
        /// touch still down.
        pub fn primaryPointer(self: *const Self) ?input.Pointer {
            var first_touch: ?*const Slot = null;
            for (&self.contacts) |*slot| {
                if (slot.*) |*contact| {
                    if (contact.hovers()) return contact.pointer;
                    if (first_touch == null or contact.press_order < first_touch.?.press_order) first_touch = contact;
                }
            }
            return if (first_touch) |touch| touch.pointer else null;
        }

        pub fn keyPressed(self: *const Self, key: input.Key) bool {
            for (self.key_events[0..self.key_event_count]) |event| {
                if (event.key == key) return true;
            }
            return false;
        }

        pub fn chordPressed(self: *const Self, chord: input.Chord) bool {
            for (self.key_events[0..self.key_event_count]) |event| {
                if (event.key == chord.key and event.modifiers == chord.modifiers) return true;
            }
            return false;
        }
    };
}

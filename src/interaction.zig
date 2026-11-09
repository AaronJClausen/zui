const std = @import("std");
const style = @import("style.zig");
const input = @import("input.zig");
const Instant = @import("record.zig").Instant;

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
    /// Its horizontal offset grows to the left, as a mirrored row's does.
    scroll_x_reversed: bool = false,
    _: u2 = 0,

    pub fn scrolls(self: RegionFlags, axis: usize) bool {
        return if (axis == 0) self.scroll_x else self.scroll_y;
    }
};

pub const no_region = std.math.maxInt(u32);

/// What an element accepts from pointers. When elements are nested, a
/// pointer goes to the innermost one that accepts what it does:
///
/// ```zig
/// ui.open(.{ .id = .of("carousel"), .scroll = .{ .horizontal = true, .vertical = false }, .gestures = .{ .pan = .horizontal } });
/// ```
pub const Gestures = packed struct(u8) {
    /// The axes it pans or scrolls on, with any pointer. A scroll container
    /// pans on its scrolled axes with touch and pen without it, and the
    /// mouse scrolls it with the wheel.
    pan: Pan = .none,
    /// Scale and rotation by two pointers, and the pan of their centroid.
    zoom: bool = false,
    /// A press held still for `long_press_seconds` asks for its context
    /// menu, `contextRequested`, instead of tapping.
    long_press: bool = false,
    /// A second tap within `double_tap_seconds` is `doubleTapped`; a single
    /// tap is `clicked` only once that window has passed.
    double_tap: bool = false,
    _: u3 = 0,

    /// The axes an element pans on.
    pub const Pan = enum(u2) {
        none,
        horizontal,
        vertical,
        both,

        pub fn includes(self: Pan, axis: usize) bool {
            return self == .both or self == if (axis == 0) Pan.horizontal else Pan.vertical;
        }
    };

    /// How far, in layout units, a pointer moves from where it pressed
    /// before it pans: a shorter move is still a tap.
    pub const touch_slop: f32 = 8;
    pub const long_press_seconds: f64 = 0.5;
    /// From the first tap's release to the second's.
    pub const double_tap_seconds: f64 = 0.3;
    /// A pan released faster than this, in layout units per second, coasts.
    pub const fling_speed: f32 = 50;
    /// Coasting slows by a factor of e in this time, so it travels about
    /// the release speed times this far.
    pub const momentum_seconds: f32 = 0.325;
    /// Coasting stops below this speed, in layout units per second.
    pub const momentum_stop_speed: f32 = 10;
    /// How far before the release the motion that sets its speed began.
    pub const velocity_window_seconds: f64 = 0.1;
    /// The deadline a coasting element sets for the next frame, after this
    /// one's `now`.
    pub const momentum_frame_seconds: f64 = 1.0 / 120.0;

    pub fn any(self: Gestures) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};

/// A part of the last frame the pointer can hit, in paint order.
pub fn RegionOf(comptime has_gestures: bool) type {
    return struct {
        hash: u64,
        /// The element's rectangle, clipped by its ancestors.
        bounds: style.Rect,
        z: i16,
        /// The nearest enclosing region in the tree, or `no_region`.
        parent: u32,
        flags: RegionFlags,
        gestures: if (has_gestures) Gestures else void,
        /// For scroll containers: the largest offset per axis.
        max_scroll: [2]f32,

        pub fn zooms(self: *const @This()) bool {
            return has_gestures and self.gestures.zoom and !self.flags.disabled;
        }

        /// The axes a pointer of `kind` can pan it on.
        pub fn panAxes(self: *const @This(), kind: input.PointerKind) Gestures.Pan {
            const horizontal = self.pans(0, kind);
            const vertical = self.pans(1, kind);
            return if (horizontal and vertical) .both else if (horizontal) .horizontal else if (vertical) .vertical else .none;
        }

        /// Whether a pointer of `kind` moving along `axis` can pan it.
        pub fn pans(self: *const @This(), axis: usize, kind: input.PointerKind) bool {
            if (self.flags.disabled) return false;
            if (has_gestures and self.gestures.pan.includes(axis)) return true;
            return kind != .mouse and self.flags.scrolls(axis);
        }
    };
}

pub const Focusable = struct {
    hash: u64,
    /// The innermost `focus_scope` element containing this one, or 0.
    scope: u64,
};

/// What zui keeps of the previous frame for interaction queries. It lives in
/// the Context, not in a frame, because with `frames_in_flight = 1` the
/// previous frame's memory is reused before the queries run.
pub fn Results(comptime max_regions: u32, comptime table_slots: u32, comptime has_gestures: bool) type {
    return struct {
        const Self = @This();
        pub const Region = RegionOf(has_gestures);

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

        /// The innermost focus scope holding the focusable element, or 0.
        pub fn focusScopeOf(self: *const Self, hash: u64) u64 {
            for (self.focusables[0..self.focusable_count]) |focusable| {
                if (focusable.hash == hash) return focusable.scope;
            }
            return 0;
        }

        pub fn isFocusable(self: *const Self, hash: u64) bool {
            for (self.focusables[0..self.focusable_count]) |focusable| {
                if (focusable.hash == hash) return true;
            }
            return false;
        }
    };
}

/// What keeps an element moving after a fling, in the state table under
/// its id.
pub const Momentum = struct {
    /// Layout units per second, as the content moves.
    velocity: [2]f32,
    last_moved: Instant,

    /// Moves on to `now`, slowing exponentially, and returns how far.
    pub fn advance(self: *Momentum, now: Instant) [2]f32 {
        const elapsed = now.secondsSince(self.last_moved);
        self.last_moved = now;
        const kept = @exp(-elapsed / Gestures.momentum_seconds);
        const travel = Gestures.momentum_seconds * (1 - kept);
        const moved: [2]f32 = .{ self.velocity[0] * travel, self.velocity[1] * travel };
        self.velocity = .{ self.velocity[0] * kept, self.velocity[1] * kept };
        return moved;
    }

    pub fn stopped(self: *const Momentum) bool {
        return self.velocity[0] * self.velocity[0] + self.velocity[1] * self.velocity[1] < Gestures.momentum_stop_speed * Gestures.momentum_stop_speed;
    }
};

/// Where a pointer was, and when, for its speed at release.
pub const MotionSample = struct {
    position: [2]f32,
    at: Instant,
};

/// What a pressed pointer is doing to the elements under it.
pub const PointerGesture = struct {
    press_position: [2]f32,
    /// Where the pan last moved its owner to.
    panned_to: [2]f32,
    /// The element the pointer pans, or 0.
    pan_owner: u64,
    /// The axes the owner takes: the one the pointer locked to, or both
    /// when the owner pans on both.
    pan_axes: Gestures.Pan,
    /// Past the touch slop, so the pan has been arbitrated, whether or not
    /// an element took it.
    past_slop: bool,
    /// One of two pointers zooming `pan_owner`.
    zooming: bool,
    pressed_at: Instant,
    /// The element that asks for its context menu if the press is held
    /// still, or 0.
    long_press_owner: u64,
    /// The press was held long enough, so its release is not a tap.
    long_pressed: bool,
    /// The latest positions, oldest first.
    recent: [4]MotionSample,
    recent_count: u8,

    pub fn pressedAt(pointer: input.Pointer) PointerGesture {
        var gesture: PointerGesture = .{ .press_position = pointer.position, .panned_to = pointer.position, .pan_owner = 0, .pan_axes = .none, .past_slop = false, .zooming = false, .pressed_at = pointer.at, .long_press_owner = 0, .long_pressed = false, .recent = undefined, .recent_count = 0 };
        gesture.sample(pointer);
        return gesture;
    }

    pub fn sample(self: *PointerGesture, pointer: input.Pointer) void {
        if (self.recent_count == self.recent.len) {
            std.mem.copyForwards(MotionSample, self.recent[0 .. self.recent.len - 1], self.recent[1..]);
            self.recent_count -= 1;
        }
        self.recent[self.recent_count] = .{ .position = pointer.position, .at = pointer.at };
        self.recent_count += 1;
    }

    /// Over the samples within the velocity window before the latest, in
    /// layout units per second; zero without time between them.
    pub fn velocity(self: *const PointerGesture) [2]f32 {
        const latest = self.recent[self.recent_count - 1];
        const earliest = for (self.recent[0..self.recent_count]) |recent| {
            if (latest.at.secondsSince(recent.at) <= Gestures.velocity_window_seconds) break recent;
        } else latest;
        const elapsed = latest.at.secondsSince(earliest.at);
        if (elapsed <= 0) return .{ 0, 0 };
        return .{ (latest.position[0] - earliest.position[0]) / elapsed, (latest.position[1] - earliest.position[1]) / elapsed };
    }

    pub fn longPressDue(self: *const PointerGesture) Instant {
        return self.pressed_at.addSeconds(Gestures.long_press_seconds);
    }

    /// Whether this pointer has done anything but tap.
    pub fn claimed(self: *const PointerGesture) bool {
        return self.pan_owner != 0 or self.long_pressed;
    }
};

/// One slot of the pointer table: a contact touching or hovering over the
/// surface.
pub fn Contact(comptime max_chain: usize, comptime has_gestures: bool) type {
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
        /// The element the secondary button's press began on, or 0.
        secondary_target: u64,
        gesture: if (has_gestures) PointerGesture else void,

        pub fn init(pointer: input.Pointer) Self {
            return .{ .pointer = pointer, .buttons = .initEmpty(), .press_target = 0, .press_order = 0, .hover_stale = false, .hover_chain = undefined, .hover_count = 0, .lifted = false, .secondary_target = 0, .gesture = if (has_gestures) .pressedAt(pointer) else {} };
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
pub fn State(comptime max_contacts: u8, comptime max_chain: usize, comptime max_events: u16, comptime max_text_bytes: u16, comptime max_path_bytes: u32, comptime has_gestures: bool) type {
    return struct {
        const Self = @This();
        pub const Slot = Contact(max_chain, has_gestures);
        /// Each takes an event or a coasting element.
        const max_manipulations = if (has_gestures) @as(u32, max_events) + max_coasting else 0;
        pub const max_coasting = if (has_gestures) max_contacts else 0;
        /// Each takes an event or a long press, one per contact.
        const max_context_requests = @as(u32, max_events) + max_contacts;
        const max_double_taps = if (has_gestures) max_events else 0;
        const max_pending_taps = if (has_gestures) max_contacts else 0;

        /// A tap on an element that accepts double taps, waiting to see
        /// whether a second one follows.
        pub const PendingTap = struct {
            hash: u64,
            released_at: Instant,

            pub fn due(self: PendingTap) Instant {
                return self.released_at.addSeconds(Gestures.double_tap_seconds);
            }
        };

        pub const ManipulatedElement = struct {
            hash: u64,
            manipulation: input.Manipulation,
        };

        contacts: [max_contacts]?Slot,
        presses_begun: u64,

        key_events: [max_events]input.KeyEvent,
        key_event_count: u16,
        text: [max_text_bytes]u8,
        text_len: u16,
        clicked: [@as(u32, max_events) + max_pending_taps]u64,
        clicked_count: u32,
        dropped_paths: [max_path_bytes]u8,
        dropped_path_len: u32,
        drops: [if (max_path_bytes == 0) 0 else max_events]input.FilesDropped,
        drop_count: u16,
        lifecycle: input.LifecycleSet,
        manipulated: [max_manipulations]ManipulatedElement,
        manipulated_count: u32,
        /// Elements moving on after a fling, each with `Momentum` in the
        /// state table.
        coasting: [max_coasting]u64,
        coasting_count: u8,
        context_requested: [max_context_requests]u64,
        context_request_count: u32,
        double_tapped: [max_double_taps]u64,
        double_tap_count: u16,
        /// Kept across frames until each is clicked or tapped again.
        pending_taps: [max_pending_taps]?PendingTap,
        /// A long press or a delayed tap may be waiting, so `beginFrame`
        /// looks for those that are due; otherwise it looks at nothing.
        timers_armed: bool,

        focus: u64,
        pending_focus: ?u64,

        pub fn reset(self: *Self) void {
            self.contacts = @splat(null);
            self.presses_begun = 0;
            self.pending_taps = @splat(null);
            self.timers_armed = false;
            self.coasting_count = 0;
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
            self.manipulated_count = 0;
            self.context_request_count = 0;
            self.double_tap_count = 0;
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

        /// Each click takes an event or a tap that waited, one per
        /// pending slot, so `clicked` cannot overflow.
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

        pub fn isContextRequested(self: *const Self, hash: u64) bool {
            return std.mem.indexOfScalar(u64, self.context_requested[0..self.context_request_count], hash) != null;
        }

        pub fn addContextRequest(self: *Self, hash: u64) void {
            if (self.isContextRequested(hash)) return;
            self.context_requested[self.context_request_count] = hash;
            self.context_request_count += 1;
        }

        pub fn isDoubleTapped(self: *const Self, hash: u64) bool {
            return std.mem.indexOfScalar(u64, self.double_tapped[0..self.double_tap_count], hash) != null;
        }

        /// A tap on an element that accepts double taps: the second within
        /// the window is a double tap, and a first waits to become a click.
        /// With every slot waiting, the one that has waited longest clicks
        /// now to make room.
        pub fn tapDelayed(self: *Self, hash: u64, released_at: Instant) void {
            for (&self.pending_taps) |*slot| {
                const pending = slot.* orelse continue;
                if (pending.hash != hash) continue;
                slot.* = null;
                if (!pending.due().isBefore(released_at)) {
                    if (!self.isDoubleTapped(hash)) {
                        self.double_tapped[self.double_tap_count] = hash;
                        self.double_tap_count += 1;
                    }
                    return;
                }
                self.addClick(hash);
                break;
            }
            var free: *?PendingTap = &self.pending_taps[0];
            for (&self.pending_taps) |*slot| {
                const pending = slot.* orelse {
                    free = slot;
                    break;
                };
                if (pending.released_at.isBefore(free.*.?.released_at)) free = slot;
            } else self.addClick(free.*.?.hash);
            free.* = .{ .hash = hash, .released_at = released_at };
            self.timers_armed = true;
        }

        pub fn manipulationOf(self: *const Self, hash: u64) ?input.Manipulation {
            for (self.manipulated[0..self.manipulated_count]) |*entry| {
                if (entry.hash == hash) return entry.manipulation;
            }
            return null;
        }

        /// The element's manipulation this frame, started as the identity.
        pub fn manipulate(self: *Self, hash: u64) *input.Manipulation {
            for (self.manipulated[0..self.manipulated_count]) |*entry| {
                if (entry.hash == hash) return &entry.manipulation;
            }
            const entry = &self.manipulated[self.manipulated_count];
            entry.* = .{ .hash = hash, .manipulation = .{} };
            self.manipulated_count += 1;
            return &entry.manipulation;
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

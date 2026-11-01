const std = @import("std");
const id = @import("id.zig");

pub const max_state_bytes = 64;
pub const max_state_alignment = 16;

pub fn typeHash(comptime T: type) u64 {
    return comptime id.fnv1a(@typeName(T));
}

/// Checks the limits a state type must meet to fit a slot.
pub fn checkStateType(comptime T: type) void {
    if (@sizeOf(T) > max_state_bytes) {
        @compileError(std.fmt.comptimePrint("zui: state type {s} is {d} bytes, but a state slot holds at most {d}; store an index into your own storage instead", .{ @typeName(T), @sizeOf(T), max_state_bytes }));
    }
    if (@alignOf(T) > max_state_alignment) {
        @compileError(std.fmt.comptimePrint("zui: state type {s} needs {d}-byte alignment, but state slots are aligned to {d}", .{ @typeName(T), @alignOf(T), max_state_alignment }));
    }
}

/// Per-id memory that survives across frames, keyed by (id, type). Open
/// addressing with linear probing; eviction uses backward-shift deletion,
/// so the table never accumulates tombstones.
pub fn StateTable(comptime slot_count: u32) type {
    return struct {
        const Self = @This();
        const mask = slot_count - 1;

        const Slot = struct {
            key: u64,
            element_id: u64,
            type_hash: u64,
            last_touched: u32,
            bytes: [max_state_bytes]u8 align(max_state_alignment),
        };

        slots: [slot_count]Slot,
        /// Handed out when the table is full, so callers always get valid memory.
        overflow_scratch: [max_state_bytes]u8 align(max_state_alignment),
        used: u32,

        pub fn reset(self: *Self) void {
            for (&self.slots) |*slot| slot.key = 0;
            self.used = 0;
        }

        pub const Lookup = enum { create, existing_only };

        /// The slot for (`element_id`, `T`), touched for `frame_number`.
        /// Returns null if the slot does not exist and `mode` is
        /// `.existing_only`, or if the table is full.
        pub fn get(self: *Self, element_id: u64, comptime T: type, frame_number: u32, mode: Lookup) ?*T {
            checkStateType(T);
            const type_hash = typeHash(T);
            const key = keyFor(element_id, type_hash);
            var index: usize = @as(usize, @truncate(key)) & mask;
            for (0..slot_count) |_| {
                const slot = &self.slots[index];
                if (slot.key == 0) {
                    if (mode == .existing_only or self.used == slot_count) return null;
                    slot.* = .{ .key = key, .element_id = element_id, .type_hash = type_hash, .last_touched = frame_number, .bytes = @splat(0) };
                    self.used += 1;
                    return @ptrCast(@alignCast(&slot.bytes));
                }
                if (slot.key == key and slot.element_id == element_id and slot.type_hash == type_hash) {
                    slot.last_touched = frame_number;
                    return @ptrCast(@alignCast(&slot.bytes));
                }
                index = (index + 1) & mask;
            }
            return null;
        }

        pub fn scratch(self: *Self, comptime T: type) *T {
            checkStateType(T);
            self.overflow_scratch = @splat(0);
            return @ptrCast(@alignCast(&self.overflow_scratch));
        }

        /// Frees every slot not touched in the last `ttl_frames` frames.
        pub fn evict(self: *Self, frame_number: u32, ttl_frames: u32) void {
            var index: usize = 0;
            while (index < slot_count) {
                const slot = &self.slots[index];
                if (slot.key != 0 and frame_number -% slot.last_touched > ttl_frames) {
                    self.removeAt(index);
                    continue;
                }
                index += 1;
            }
        }

        fn removeAt(self: *Self, removed_index: usize) void {
            var hole = removed_index;
            var probe = removed_index;
            // Bounded, because a full table has no empty slot to stop at.
            for (0..slot_count - 1) |_| {
                probe = (probe + 1) & mask;
                const candidate = self.slots[probe];
                if (candidate.key == 0) break;
                const home: usize = @as(usize, @truncate(candidate.key)) & mask;
                const stays_put = if (probe > hole) (home > hole and home <= probe) else (home > hole or home <= probe);
                if (!stays_put) {
                    self.slots[hole] = candidate;
                    hole = probe;
                }
            }
            self.slots[hole].key = 0;
            self.used -= 1;
        }

        fn keyFor(element_id: u64, type_hash: u64) u64 {
            const key = id.mix(element_id, type_hash);
            return if (key == 0) 1 else key;
        }
    };
}

const Expanded = struct { open: bool };
const Counter = struct { count: u32 };

test "state persists, is keyed by type, and starts zeroed" {
    var table: StateTable(16) = undefined;
    table.reset();
    const expanded = table.get(7, Expanded, 1, .create).?;
    try std.testing.expectEqual(false, expanded.open);
    expanded.open = true;
    table.get(7, Counter, 1, .create).?.count = 3;

    try std.testing.expectEqual(true, table.get(7, Expanded, 2, .existing_only).?.open);
    try std.testing.expectEqual(@as(u32, 3), table.get(7, Counter, 2, .existing_only).?.count);
    try std.testing.expectEqual(@as(?*Expanded, null), table.get(8, Expanded, 2, .existing_only));
}

test "untouched slots are evicted, and the rest stay reachable" {
    var table: StateTable(8) = undefined;
    table.reset();
    for (0..8) |element| table.get(element, Counter, 1, .create).?.count = @intCast(element);
    try std.testing.expectEqual(@as(?*Counter, null), table.get(100, Counter, 1, .create));

    for (0..8) |element| {
        if (element % 2 == 0) _ = table.get(element, Counter, 5, .existing_only);
    }
    table.evict(5, 2);
    try std.testing.expectEqual(@as(u32, 4), table.used);
    for (0..8) |element| {
        const found = table.get(element, Counter, 5, .existing_only);
        if (element % 2 == 0) {
            try std.testing.expectEqual(@as(u32, @intCast(element)), found.?.count);
        } else {
            try std.testing.expectEqual(@as(?*Counter, null), found);
        }
    }
}

test "backward-shift deletion keeps every survivor reachable under heavy churn" {
    var table: StateTable(64) = undefined;
    table.reset();
    var prng: std.Random.DefaultPrng = .init(42);
    const random = prng.random();
    var alive: [256]bool = @splat(false);
    var frame: u32 = 1;
    while (frame < 400) : (frame += 1) {
        for (0..8) |_| {
            const element = random.uintLessThan(usize, alive.len);
            if (table.get(element, Counter, frame, .create)) |counter| {
                counter.count = @intCast(element);
                alive[element] = true;
            }
        }
        for (0..alive.len) |element| {
            if (alive[element] and random.uintLessThan(u8, 3) != 0) _ = table.get(element, Counter, frame, .existing_only);
        }
        table.evict(frame, 1);
        var expected_used: u32 = 0;
        for (0..alive.len) |element| {
            if (!alive[element]) continue;
            if (table.get(element, Counter, frame, .existing_only)) |counter| {
                try std.testing.expectEqual(@as(u32, @intCast(element)), counter.count);
                expected_used += 1;
            } else alive[element] = false;
        }
        try std.testing.expectEqual(expected_used, table.used);
    }
}

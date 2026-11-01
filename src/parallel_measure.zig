const std = @import("std");
const text = @import("text.zig");

/// Measures a frame's cache misses on several threads before layout, for
/// platforms that declare `pub const thread_safe_measure = true` (SPEC.md
/// §10.5). Layout then finds every measurement in the cache.
pub fn MeasureBatch(comptime FontId: type, comptime Platform: type, comptime capacity: u32) type {
    return struct {
        const Self = @This();
        const seen_slots = std.math.ceilPowerOfTwoAssert(u32, capacity * 2);
        /// Keys per task: large enough that spawning a task costs less
        /// than the measurements it runs.
        pub const chunk_size = 64;

        pub const Pending = struct {
            key: u64,
            text: []const u8,
            font: FontId,
            size: f32,
            measured: [2]f32,
            done: bool,
            seen_slot: u32,
        };

        pending: [capacity]Pending,
        pending_count: u32,
        /// Indexes into `pending` plus one, by key, so a word that repeats
        /// in the frame is measured once. Zero is empty.
        seen: [seen_slots]u32,

        pub fn clearAll(self: *Self) void {
            @memset(&self.seen, 0);
            self.pending_count = 0;
        }

        /// Clears only the slots the last batch used.
        pub fn reset(self: *Self) void {
            for (self.pending[0..self.pending_count]) |entry| self.seen[entry.seen_slot] = 0;
            self.pending_count = 0;
        }

        /// Adds a run the cache does not have. Returns false once the
        /// batch is full; the rest are measured inline during layout.
        pub fn add(self: *Self, key: u64, run: []const u8, font: FontId, size: f32) bool {
            var slot: usize = @as(usize, @truncate(key)) & (seen_slots - 1);
            while (self.seen[slot] != 0) : (slot = (slot + 1) & (seen_slots - 1)) {
                if (self.pending[self.seen[slot] - 1].key == key) return true;
            }
            if (self.pending_count == capacity) return false;
            self.pending[self.pending_count] = .{ .key = key, .text = run, .font = font, .size = size, .measured = undefined, .done = false, .seen_slot = @intCast(slot) };
            self.pending_count += 1;
            self.seen[slot] = self.pending_count;
            return true;
        }

        /// Measures everything pending across `io`, `chunk_size` keys per
        /// task, and waits for the tasks. If the calling task is canceled,
        /// the measurements already made are kept and the rest are left to
        /// layout.
        pub fn measureAll(self: *Self, io: std.Io, platform: *Platform) void {
            var group: std.Io.Group = .init;
            var start: u32 = 0;
            while (start < self.pending_count) : (start += chunk_size) {
                const end = @min(start + chunk_size, self.pending_count);
                group.async(io, measureChunk, .{ platform, self.pending[start..end] });
            }
            group.await(io) catch |err| switch (err) {
                error.Canceled => {
                    group.cancel(io);
                    io.recancel();
                },
            };
        }

        fn measureChunk(platform: *Platform, chunk: []Pending) void {
            for (chunk) |*entry| {
                entry.measured = platform.measureText(entry.text, entry.font, entry.size);
                entry.done = true;
            }
        }
    };
}

/// Collects the distinct cache misses of `texts` and, if there are at
/// least `threshold`, measures them in parallel and stores them in the
/// cache. Below the threshold, spawning tasks would cost more than it
/// saves, and layout measures the misses itself.
pub fn prefetch(comptime Ui: type, ui: *Ui, texts: []const Ui.TextRecord, text_bytes: []const u8, threshold: u32) void {
    const cache = &ui.memory.cache;
    const batch = &ui.memory.measure_batch;
    batch.reset();
    collect: for (texts) |record| {
        const content = text_bytes[record.bytes_start..][0..record.bytes_len];
        const font = record.style.font;
        const size = record.style.size;
        if (!addIfMissing(Ui, cache, batch, " ", font, size)) break :collect;
        var runs: text.RunIterator = .init(content, record.style.wrap);
        while (runs.next()) |run| {
            if (!addIfMissing(Ui, cache, batch, run, font, size)) break :collect;
        }
    }
    if (batch.pending_count < threshold) return;

    batch.measureAll(ui.io, ui.platform);
    for (batch.pending[0..batch.pending_count]) |entry| {
        if (!entry.done) continue;
        cache.insert(entry.key, entry.measured);
        cache.platform_calls += 1;
    }
}

fn addIfMissing(comptime Ui: type, cache: *Ui.Cache, batch: anytype, run: []const u8, font: Ui.FontId, size: f32) bool {
    const key = Ui.Cache.keyOf(run, font, size);
    if (cache.lookup(key) != null) return true;
    return batch.add(key, run, font, size);
}

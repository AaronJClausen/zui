const std = @import("std");
const text = @import("text.zig");

/// Measures a frame's cache misses on several threads before layout, for
/// text contracts that declare `pub const zui_thread_safe = true`. Layout
/// then finds every measurement in the cache.
pub fn MeasureBatch(comptime Key: type, comptime Text: type, comptime capacity: u32) type {
    return struct {
        const Self = @This();
        const seen_slots = std.math.ceilPowerOfTwoAssert(u32, capacity * 2);
        /// Keys per task: large enough that spawning a task costs less
        /// than the measurements it runs.
        pub const chunk_size = 64;

        pub const Pending = struct {
            hash: u64,
            text: []const u8,
            key: Key,
            measured: [2]f32,
            done: bool,
            seen_slot: u32,
        };

        pending: [capacity]Pending,
        pending_count: u32,
        /// Indexes into `pending` plus one, by hash, so a word that repeats
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
        pub fn add(self: *Self, hash: u64, run: []const u8, key: Key) bool {
            var slot: usize = @as(usize, @truncate(hash)) & (seen_slots - 1);
            while (self.seen[slot] != 0) : (slot = (slot + 1) & (seen_slots - 1)) {
                if (self.pending[self.seen[slot] - 1].hash == hash) return true;
            }
            if (self.pending_count == capacity) return false;
            self.pending[self.pending_count] = .{ .hash = hash, .text = run, .key = key, .measured = undefined, .done = false, .seen_slot = @intCast(slot) };
            self.pending_count += 1;
            self.seen[slot] = self.pending_count;
            return true;
        }

        /// Measures everything pending across `io`, `chunk_size` keys per
        /// task, and waits for the tasks. If the calling task is canceled,
        /// the measurements already made are kept and the rest are left to
        /// layout.
        pub fn measureAll(self: *Self, io: std.Io, text_contract: *Text) void {
            var group: std.Io.Group = .init;
            var start: u32 = 0;
            while (start < self.pending_count) : (start += chunk_size) {
                const end = @min(start + chunk_size, self.pending_count);
                group.async(io, measureChunk, .{ text_contract, self.pending[start..end] });
            }
            group.await(io) catch |err| switch (err) {
                error.Canceled => {
                    group.cancel(io);
                    io.recancel();
                },
            };
        }

        fn measureChunk(text_contract: *Text, chunk: []Pending) void {
            for (chunk) |*entry| {
                entry.measured = text_contract.zuiMeasure(entry.text, entry.key);
                entry.done = true;
            }
        }
    };
}

/// Collects the distinct cache misses of `texts` and, if there are at
/// least `threshold`, measures them in parallel and stores them in the
/// cache. Below the threshold, spawning tasks would cost more than it
/// saves, and layout measures the misses itself.
pub fn prefetch(comptime Ui: type, ui: *Ui, texts: []const Ui.TextRecord, text_bytes: []const u8, zoom: f32, threshold: u32) void {
    const cache = &ui.memory.cache;
    const batch = &ui.memory.measure_batch;
    batch.reset();
    collect: for (texts) |record| {
        const content = text_bytes[record.bytes_start..][0..record.bytes_len];
        const key = Ui.measureKeyOf(record.style, zoom);
        if (!addIfMissing(Ui, cache, batch, " ", key)) break :collect;
        var runs: text.RunIterator(Ui.Segmenter) = .init(content, record.style.wrap, ui.segmenter());
        while (runs.next()) |run| {
            if (!addIfMissing(Ui, cache, batch, run, key)) break :collect;
        }
    }
    if (batch.pending_count < threshold) return;

    batch.measureAll(ui.io, ui.text_contract);
    for (batch.pending[0..batch.pending_count]) |entry| {
        if (!entry.done) continue;
        cache.insert(entry.hash, entry.measured);
        cache.measure_calls += 1;
    }
}

fn addIfMissing(comptime Ui: type, cache: *Ui.Cache, batch: anytype, run: []const u8, key: Ui.MeasureKey) bool {
    const hash = Ui.Cache.hashOf(run, key);
    if (cache.lookup(hash) != null) return true;
    return batch.add(hash, run, key);
}

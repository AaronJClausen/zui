const std = @import("std");
const style = @import("style.zig");

/// A byte range of the frame's text buffer that renders as one line.
pub const Line = struct {
    start: u32,
    end: u32,
    width: f32,
};

pub const Word = struct {
    start: u32,
    end: u32,
    ends_paragraph: bool,
};

/// Splits at every ASCII space and newline. Consecutive spaces produce
/// empty words, so their widths survive in the layout.
pub const WordIterator = struct {
    text: []const u8,
    position: u32 = 0,
    finished: bool = false,

    pub fn next(self: *WordIterator) ?Word {
        if (self.finished) return null;
        const start = self.position;
        const separator = findSeparator(self.text, start) orelse {
            self.finished = true;
            return .{ .start = start, .end = @intCast(self.text.len), .ends_paragraph = false };
        };
        self.position = separator + 1;
        return .{ .start = start, .end = separator, .ends_paragraph = self.text[separator] == '\n' };
    }

    /// The first space or newline at or after `from`, 16 bytes at a time.
    fn findSeparator(text: []const u8, from: u32) ?u32 {
        const Chunk = @Vector(16, u8);
        var cursor: usize = from;
        while (cursor + 16 <= text.len) : (cursor += 16) {
            const chunk: Chunk = text[cursor..][0..16].*;
            const separators = (chunk == @as(Chunk, @splat(' '))) | (chunk == @as(Chunk, @splat('\n')));
            const mask: u16 = @bitCast(separators);
            if (mask != 0) return @intCast(cursor + @ctz(mask));
        }
        while (cursor < text.len) : (cursor += 1) {
            if (text[cursor] == ' ' or text[cursor] == '\n') return @intCast(cursor);
        }
        return null;
    }
};

pub fn fontBits(font: anytype) u64 {
    return switch (@typeInfo(@TypeOf(font))) {
        .int => @intCast(font),
        .@"enum" => @intCast(@intFromEnum(font)),
        else => @compileError("zui: Config.FontId must be an integer or enum type, got " ++ @typeName(@TypeOf(font))),
    };
}

/// Persistent, open-addressed cache of text measurements, keyed by the
/// bytes, the font and the size. It outlives frames, which is why
/// steady-state frames make almost no platform calls.
pub fn MeasureCache(comptime FontId: type, comptime entry_count: u32, comptime Platform: type) type {
    return struct {
        const Self = @This();
        const probe_window = 8;

        /// The key hashes the bytes with the font and size as the seed;
        /// two different texts share one with probability 2^-64.
        const Entry = struct {
            key: u64,
            measured: [2]f32,
            last_used: u32,
        };

        entries: [entry_count]Entry,
        generation: u32,
        platform_calls: u64,

        pub fn reset(self: *Self) void {
            for (&self.entries) |*entry| entry.key = 0;
            self.generation = 1;
            self.platform_calls = 0;
        }

        pub fn measure(self: *Self, platform: *Platform, text: []const u8, font: FontId, size: f32) [2]f32 {
            const key = keyOf(text, font, size);
            if (self.lookup(key)) |measured| return measured;
            const measured = platform.measureText(text, font, size);
            self.platform_calls += 1;
            self.insert(key, measured);
            return measured;
        }

        pub fn keyOf(text: []const u8, font: FontId, size: f32) u64 {
            const size_bits: u32 = @bitCast(size);
            return nonZero(std.hash.Wyhash.hash(fontBits(font) << 32 | size_bits, text));
        }

        /// Marks a hit as used this generation, so it is evicted last.
        pub fn lookup(self: *Self, key: u64) ?[2]f32 {
            for (0..probe_window) |step| {
                const entry = &self.entries[(@as(usize, @truncate(key)) +% step) & (entry_count - 1)];
                if (entry.key == 0) return null;
                if (entry.key == key) {
                    entry.last_used = self.generation;
                    return entry.measured;
                }
            }
            return null;
        }

        /// For a key `lookup` just missed: takes the first empty slot in the
        /// probe window, or else the least recently used one.
        pub fn insert(self: *Self, key: u64, measured: [2]f32) void {
            var replace_index: usize = @as(usize, @truncate(key)) & (entry_count - 1);
            var replace_age: u32 = 0;
            for (0..probe_window) |step| {
                const index = (@as(usize, @truncate(key)) +% step) & (entry_count - 1);
                const entry = &self.entries[index];
                if (entry.key == 0) {
                    replace_index = index;
                    break;
                }
                const age = self.generation -% entry.last_used;
                if (age >= replace_age) {
                    replace_age = age;
                    replace_index = index;
                }
            }
            self.entries[replace_index] = .{ .key = key, .measured = measured, .last_used = self.generation };
        }

        fn nonZero(key: u64) u64 {
            return if (key == 0) 1 else key;
        }
    };
}

pub const Metrics = struct {
    /// The width with no wrapping except at newlines.
    preferred_width: f32,
    /// The narrowest the text can be without breaking inside a word.
    min_width: f32,
    line_height: f32,
    space_width: f32,
    /// Where this text's run widths start in the run width buffer.
    first_run: u32,
};

/// Run widths a frame can need: a text has at most one run more than it
/// has bytes (consecutive spaces make empty words).
pub fn maxRuns(max_text_bytes: u32, max_texts: u32) u32 {
    return max_text_bytes + max_texts;
}

/// Measures `text` and appends the width of each of its runs to
/// `run_widths`: each word for `.words`, each paragraph for `.newlines`,
/// the whole text for `.none`. Wrapping reads them back, so each run is
/// looked up in the cache once per frame, not twice.
pub fn measureMetrics(
    cache: anytype,
    platform: anytype,
    text: []const u8,
    wrap: style.TextWrap,
    font: anytype,
    size: f32,
    line_height_override: f32,
    run_widths: []f32,
    run_count: *u32,
) Metrics {
    const space = cache.measure(platform, " ", font, size);
    var metrics: Metrics = .{
        .preferred_width = 0,
        .min_width = 0,
        .line_height = if (line_height_override > 0) line_height_override else space[1],
        .space_width = space[0],
        .first_run = run_count.*,
    };
    if (text.len == 0) return metrics;
    var runs: RunWriter = .{ .widths = run_widths, .count = run_count };

    switch (wrap) {
        .none => {
            const width = runs.append(cache.measure(platform, text, font, size)[0]);
            metrics.preferred_width = width;
            metrics.min_width = width;
        },
        .newlines => {
            var widest: f32 = 0;
            var paragraphs = std.mem.splitScalar(u8, text, '\n');
            while (paragraphs.next()) |paragraph| widest = @max(widest, runs.append(measureRun(cache, platform, paragraph, font, size)));
            metrics.preferred_width = widest;
            metrics.min_width = widest;
        },
        .words => {
            var widest_paragraph: f32 = 0;
            var widest_word: f32 = 0;
            var paragraph_width: f32 = 0;
            var paragraph_has_word = false;
            var words: WordIterator = .{ .text = text };
            while (words.next()) |word| {
                const word_width = runs.append(measureRun(cache, platform, text[word.start..word.end], font, size));
                widest_word = @max(widest_word, word_width);
                paragraph_width += word_width + if (paragraph_has_word) space[0] else 0;
                paragraph_has_word = true;
                if (word.ends_paragraph) {
                    widest_paragraph = @max(widest_paragraph, paragraph_width);
                    paragraph_width = 0;
                    paragraph_has_word = false;
                }
            }
            metrics.preferred_width = @max(widest_paragraph, paragraph_width);
            metrics.min_width = widest_word;
        },
    }
    return metrics;
}

/// The runs `measureMetrics` measures, other than the space: each
/// non-empty word for `.words`, each non-empty paragraph for `.newlines`,
/// the whole text for `.none`.
pub const RunIterator = struct {
    text: []const u8,
    wrap: style.TextWrap,
    words: WordIterator,
    paragraphs: std.mem.SplitIterator(u8, .scalar),
    whole_text_done: bool = false,

    pub fn init(text: []const u8, wrap: style.TextWrap) RunIterator {
        return .{ .text = text, .wrap = wrap, .words = .{ .text = text }, .paragraphs = std.mem.splitScalar(u8, text, '\n') };
    }

    pub fn next(self: *RunIterator) ?[]const u8 {
        if (self.text.len == 0) return null;
        switch (self.wrap) {
            .none => {
                if (self.whole_text_done) return null;
                self.whole_text_done = true;
                return self.text;
            },
            .newlines => while (self.paragraphs.next()) |paragraph| {
                if (paragraph.len != 0) return paragraph;
            },
            .words => while (self.words.next()) |word| {
                if (word.end != word.start) return self.text[word.start..word.end];
            },
        }
        return null;
    }
};

const RunWriter = struct {
    widths: []f32,
    count: *u32,

    fn append(self: RunWriter, width: f32) f32 {
        self.widths[self.count.*] = width;
        self.count.* += 1;
        return width;
    }
};

fn measureRun(cache: anytype, platform: anytype, run: []const u8, font: anytype, size: f32) f32 {
    if (run.len == 0) return 0;
    return cache.measure(platform, run, font, size)[0];
}

/// Appends the lines of `text` laid out within `max_width`, from the run
/// widths `measureMetrics` recorded. `base` is the offset of `text` in the
/// frame's text buffer, so lines index that buffer.
/// Words are never broken: layout never makes a text element narrower than
/// its longest word, so a word wider than a line can only come from a
/// parent too small for it, and it overflows, as in CSS by default.
/// Returns false if `lines` ran out of room; the lines that fit are kept.
pub fn wrapLines(
    text: []const u8,
    base: u32,
    wrap: style.TextWrap,
    metrics: Metrics,
    run_widths: []const f32,
    max_width: f32,
    lines: []Line,
    line_count: *u32,
) bool {
    if (text.len == 0) return true;
    var output: LineOutput = .{ .lines = lines, .count = line_count };
    var next_run = metrics.first_run;

    switch (wrap) {
        .none => return output.emit(base, base + @as(u32, @intCast(text.len)), run_widths[next_run]),
        .newlines => {
            var start: u32 = 0;
            var paragraphs = std.mem.splitScalar(u8, text, '\n');
            while (paragraphs.next()) |paragraph| {
                const end = start + @as(u32, @intCast(paragraph.len));
                if (!output.emit(base + start, base + end, run_widths[next_run])) return false;
                next_run += 1;
                start = end + 1;
            }
            return true;
        },
        .words => {
            const space_width = metrics.space_width;
            var line_start: u32 = 0;
            var line_end: u32 = 0;
            var line_width: f32 = 0;
            var line_open = false;

            var words: WordIterator = .{ .text = text };
            while (words.next()) |word| {
                const word_width = run_widths[next_run];
                next_run += 1;

                if (line_open and line_width + space_width + word_width > max_width + tolerance) {
                    if (!output.emit(base + line_start, base + line_end, line_width)) return false;
                    line_open = false;
                }
                if (!line_open) {
                    line_start = word.start;
                    line_width = word_width;
                    line_open = true;
                } else {
                    line_width += space_width + word_width;
                }
                line_end = word.end;

                if (word.ends_paragraph) {
                    if (!output.emit(base + line_start, base + line_end, line_width)) return false;
                    line_open = false;
                    line_start = word.end + 1;
                    line_end = line_start;
                    line_width = 0;
                    line_open = true;
                }
            }
            if (line_open) return output.emit(base + line_start, base + line_end, line_width);
            return true;
        },
    }
}

/// Layout tolerance for comparisons between sums of measured widths.
pub const tolerance: f32 = 0.001;

const LineOutput = struct {
    lines: []Line,
    count: *u32,

    fn emit(self: LineOutput, start: u32, end: u32, width: f32) bool {
        if (self.count.* >= self.lines.len) return false;
        self.lines[self.count.*] = .{ .start = start, .end = end, .width = width };
        self.count.* += 1;
        return true;
    }
};

const TestPlatform = struct {
    pub fn measureText(_: *TestPlatform, text: []const u8, _: u16, size: f32) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * size / 2, size };
    }
};

fn testCache() MeasureCache(u16, 64, TestPlatform) {
    var cache: MeasureCache(u16, 64, TestPlatform) = undefined;
    cache.reset();
    return cache;
}

test "words split at spaces and newlines" {
    var words: WordIterator = .{ .text = "ab cd\nef" };
    try std.testing.expectEqual(Word{ .start = 0, .end = 2, .ends_paragraph = false }, words.next().?);
    try std.testing.expectEqual(Word{ .start = 3, .end = 5, .ends_paragraph = true }, words.next().?);
    try std.testing.expectEqual(Word{ .start = 6, .end = 8, .ends_paragraph = false }, words.next().?);
    try std.testing.expectEqual(@as(?Word, null), words.next());
}

test "the cache answers repeats without calling the platform" {
    var cache = testCache();
    var platform: TestPlatform = .{};
    try std.testing.expectEqual([2]f32{ 40, 16 }, cache.measure(&platform, "hello", 0, 16));
    try std.testing.expectEqual([2]f32{ 40, 16 }, cache.measure(&platform, "hello", 0, 16));
    try std.testing.expectEqual(@as(u64, 1), cache.platform_calls);
    _ = cache.measure(&platform, "hello", 0, 20);
    try std.testing.expectEqual(@as(u64, 2), cache.platform_calls);
}

test "metrics: preferred and minimum widths" {
    var cache = testCache();
    var platform: TestPlatform = .{};
    var run_widths: [16]f32 = undefined;
    var run_count: u32 = 0;
    const metrics = measureMetrics(&cache, &platform, "aa bbbb\nc", .words, @as(u16, 0), 16, 0, &run_widths, &run_count);
    try std.testing.expectEqual(@as(u32, 3), run_count);
    try std.testing.expectEqual(@as(f32, 7 * 8), metrics.preferred_width);
    try std.testing.expectEqual(@as(f32, 4 * 8), metrics.min_width);
    try std.testing.expectEqual(@as(f32, 16), metrics.line_height);
}

test "wrapping: greedy, paragraphs, and whole words" {
    var cache = testCache();
    var platform: TestPlatform = .{};
    var lines: [16]Line = undefined;
    var count: u32 = 0;
    var run_widths: [16]f32 = undefined;
    var run_count: u32 = 0;
    const text = "one two three\nfour abcdefghij";
    const metrics = measureMetrics(&cache, &platform, text, .words, @as(u16, 0), 16, 0, &run_widths, &run_count);
    try std.testing.expect(wrapLines(text, 100, .words, metrics, &run_widths, 64, &lines, &count));
    const expected = [_][]const u8{ "one two", "three", "four", "abcdefghij" };
    try std.testing.expectEqual(expected.len, count);
    for (expected, lines[0..count]) |expected_line, line| {
        try std.testing.expectEqualStrings(expected_line, text[line.start - 100 .. line.end - 100]);
    }
    try std.testing.expectEqual(@as(f32, 7 * 8), lines[0].width);
}

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

/// Where a line may break inside one paragraph of a text, as a text
/// contract's `zuiSegment` reports it. Without `zuiSegment`, a text breaks
/// at ASCII spaces.
///
/// ```zig
/// pub fn zuiSegment(self: *Fonts, paragraph: []const u8, breaks: *zui.BreakSink) void {
///     var opportunities = self.line_breaker.iterate(paragraph);
///     while (opportunities.next()) |offset| breaks.add(offset);
/// }
/// ```
pub const BreakSink = struct {
    offsets: []u32,
    count: u32 = 0,
    paragraph_len: u32,

    /// A line may break before byte `offset` of the paragraph. A space
    /// before the break stays with the text before it, and hangs past the
    /// end of a line that breaks there. Offsets come in increasing order;
    /// one that does not, or that is not inside the paragraph, is ignored.
    pub fn add(self: *BreakSink, offset: usize) void {
        if (offset == 0 or offset >= self.paragraph_len or self.count == self.offsets.len) return;
        if (self.count > 0 and offset <= self.offsets[self.count - 1]) return;
        self.offsets[self.count] = @intCast(offset);
        self.count += 1;
    }
};

/// Whether `Text` reports its own break opportunities.
pub fn segments(comptime Text: type) bool {
    return Text != void and @hasDecl(Text, "zuiSegment");
}

/// Splits a text that wraps at words into its words: at ASCII spaces and
/// newlines, or, when the text contract has `zuiSegment`, at newlines and
/// where it reports, through `breaks`, which holds one paragraph's breaks.
pub fn Segmenter(comptime Text: type) type {
    if (!segments(Text)) return struct {
        pub const Words = WordIterator;

        pub fn words(_: @This(), text: []const u8) Words {
            return .{ .text = text };
        }
    };
    return struct {
        pub const Words = SegmentIterator(Text);

        text_contract: *Text,
        breaks: []u32,

        pub fn words(self: @This(), text: []const u8) Words {
            return .{ .text = text, .text_contract = self.text_contract, .breaks = self.breaks };
        }
    };
}

/// A word between a segmenting text contract's break opportunities.
pub const Segment = struct {
    start: u32,
    /// Before the spaces that end the segment.
    end: u32,
    ends_paragraph: bool,
    /// A line that breaks after the segment leaves them hanging past its end.
    trailing_spaces: u32,
};

/// The segments between a text contract's break opportunities, one
/// paragraph at a time.
pub fn SegmentIterator(comptime Text: type) type {
    return struct {
        const Self = @This();

        text: []const u8,
        text_contract: *Text,
        breaks: []u32,
        paragraph_start: u32 = 0,
        paragraph_end: u32 = 0,
        break_count: u32 = 0,
        next_break: u32 = 0,
        position: u32 = 0,
        paragraph_segmented: bool = false,
        finished: bool = false,

        pub fn next(self: *Self) ?Segment {
            if (self.finished) return null;
            if (!self.paragraph_segmented) self.segmentParagraph();
            const start = self.position;
            const last_in_paragraph = self.next_break == self.break_count;
            const end = if (last_in_paragraph) self.paragraph_end else self.paragraph_start + self.breaks[self.next_break];
            var word_end = end;
            while (word_end > start and self.text[word_end - 1] == ' ') word_end -= 1;
            const ends_paragraph = last_in_paragraph and self.paragraph_end < self.text.len;
            if (!last_in_paragraph) {
                self.next_break += 1;
                self.position = end;
            } else if (ends_paragraph) {
                self.paragraph_start = end + 1;
                self.position = self.paragraph_start;
                self.paragraph_segmented = false;
            } else {
                self.finished = true;
            }
            return .{ .start = start, .end = word_end, .ends_paragraph = ends_paragraph, .trailing_spaces = end - word_end };
        }

        fn segmentParagraph(self: *Self) void {
            const rest = self.text[self.paragraph_start..];
            const paragraph = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
            self.paragraph_end = self.paragraph_start + @as(u32, @intCast(paragraph.len));
            var sink: BreakSink = .{ .offsets = self.breaks, .paragraph_len = @intCast(paragraph.len) };
            if (paragraph.len > 1) self.text_contract.zuiSegment(paragraph, &sink);
            self.break_count = sink.count;
            self.next_break = 0;
            self.paragraph_segmented = true;
        }
    };
}

fn spacesWidth(count: u32, space_width: f32) f32 {
    return @as(f32, @floatFromInt(count)) * space_width;
}

pub fn fontBits(font: anytype) u64 {
    return switch (@typeInfo(@TypeOf(font))) {
        .int => @intCast(font),
        .@"enum" => @intCast(@intFromEnum(font)),
        else => @compileError("zui: Config.FontId must be an integer or enum type, got " ++ @typeName(@TypeOf(font))),
    };
}

/// An open-addressed table keyed by 64-bit hashes, 0 marking an empty
/// entry. It outlives frames; a full probe window gives up its least
/// recently used entry.
fn LruTable(comptime Value: type, comptime entry_count: u32) type {
    return struct {
        const Self = @This();
        const probe_window = 8;

        const Entry = struct {
            key: u64,
            last_used: u32,
            value: Value,
        };

        entries: [entry_count]Entry,

        fn clear(self: *Self) void {
            for (&self.entries) |*entry| entry.key = 0;
        }

        /// Marks a hit as used in `generation`, so it is evicted last.
        fn lookup(self: *Self, key: u64, generation: u32) ?*Value {
            for (0..probe_window) |step| {
                const entry = &self.entries[(@as(usize, @truncate(key)) +% step) & (entry_count - 1)];
                if (entry.key == 0) return null;
                if (entry.key == key) {
                    entry.last_used = generation;
                    return &entry.value;
                }
            }
            return null;
        }

        const Found = struct { value: *Value, was_present: bool };

        /// `lookup` and, on a miss, `claim`, in one walk of the probe window.
        fn lookupOrClaim(self: *Self, key: u64, generation: u32) Found {
            const home: usize = @truncate(key);
            var replace_index: usize = home & (entry_count - 1);
            var replace_age: u32 = 0;
            for (0..probe_window) |step| {
                const index = (home +% step) & (entry_count - 1);
                const entry = &self.entries[index];
                if (entry.key == key) {
                    entry.last_used = generation;
                    return .{ .value = &entry.value, .was_present = true };
                }
                if (entry.key == 0) {
                    replace_index = index;
                    break;
                }
                const age = generation -% entry.last_used;
                if (age >= replace_age) {
                    replace_age = age;
                    replace_index = index;
                }
            }
            const entry = &self.entries[replace_index];
            entry.key = key;
            entry.last_used = generation;
            return .{ .value = &entry.value, .was_present = false };
        }

        /// For a key `lookup` just missed: the first empty entry in the
        /// probe window, or else the least recently used one, for the
        /// caller to fill.
        fn claim(self: *Self, key: u64, generation: u32) *Value {
            var replace_index: usize = @as(usize, @truncate(key)) & (entry_count - 1);
            var replace_age: u32 = 0;
            for (0..probe_window) |step| {
                const index = (@as(usize, @truncate(key)) +% step) & (entry_count - 1);
                const entry = &self.entries[index];
                if (entry.key == 0) {
                    replace_index = index;
                    break;
                }
                const age = generation -% entry.last_used;
                if (age >= replace_age) {
                    replace_age = age;
                    replace_index = index;
                }
            }
            const entry = &self.entries[replace_index];
            entry.key = key;
            entry.last_used = generation;
            return &entry.value;
        }
    };
}

/// Runs whose widths a string cache entry keeps. A text with more is
/// cached by its metrics alone, and measures its runs only to wrap.
pub const max_cached_runs = 16;

/// A whole text's measurement, in layout units.
pub const CachedString = struct {
    /// `first_run` is meaningless here, and `line_height` is the font's.
    metrics: Metrics,
    run_count: u32,
    /// The first `run_count` are valid when it is at most `max_cached_runs`.
    run_widths: [max_cached_runs]f32,
};

/// The persistent measurement caches, keyed by hashes of the bytes seeded
/// with the `MeasureKey`; two different texts share one with probability
/// 2^-64. They outlive frames, which is why steady-state frames make
/// almost no calls to the text contract:
/// - segments: what the text contract measured for one word or paragraph;
/// - strings: a whole text's metrics and run widths, so a warm text costs
///   one probe instead of one per word.
pub fn MeasureCache(comptime FontId: type, comptime segment_entries: u32, comptime string_entries: u32, comptime Text: type) type {
    return struct {
        const Self = @This();
        pub const Key = style.MeasureKey(FontId);

        segments: LruTable([2]f32, segment_entries),
        strings: LruTable(CachedString, string_entries),
        generation: u32,
        measure_calls: u64,

        pub fn reset(self: *Self) void {
            self.segments.clear();
            self.strings.clear();
            self.generation = 1;
            self.measure_calls = 0;
        }

        pub fn measure(self: *Self, text_contract: *Text, text: []const u8, key: Key) [2]f32 {
            const hash = hashOf(text, key);
            if (self.lookup(hash)) |measured| return measured;
            const measured = text_contract.zuiMeasure(text, key);
            self.measure_calls += 1;
            self.insert(hash, measured);
            return measured;
        }

        pub fn hashOf(text: []const u8, key: Key) u64 {
            return nonZero(std.hash.Wyhash.hash(seedOf(key), text));
        }

        /// A string's metrics are in layout units and depend on how it
        /// wraps, so its hash is seeded with the zoom and the wrap mode too.
        pub fn stringHashOf(text: []const u8, key: Key, wrap: style.TextWrap, inverse_zoom: f32) u64 {
            const zoom_bits: u32 = @bitCast(inverse_zoom);
            const layout_bits = @as(u64, zoom_bits) << 2 | @intFromEnum(wrap);
            return nonZero(std.hash.Wyhash.hash(seedOf(key) ^ (layout_bits *% 0xc2b2ae3d27d4eb4f), text));
        }

        fn seedOf(key: Key) u64 {
            const size_bits: u32 = @bitCast(key.size);
            const spacing_bits: u32 = @bitCast(key.letter_spacing);
            return (fontBits(key.font) << 32 | size_bits) ^ (@as(u64, spacing_bits) *% 0x9e3779b97f4a7c15);
        }

        pub fn lookup(self: *Self, key: u64) ?[2]f32 {
            const measured = self.segments.lookup(key, self.generation) orelse return null;
            return measured.*;
        }

        /// For a key `lookup` just missed.
        pub fn insert(self: *Self, key: u64, measured: [2]f32) void {
            self.segments.claim(key, self.generation).* = measured;
        }

        /// The string's entry, or one claimed for it, which the caller fills.
        pub fn findString(self: *Self, key: u64) LruTable(CachedString, string_entries).Found {
            return self.strings.lookupOrClaim(key, self.generation);
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
    /// A newline divides the text, so it never takes the single-line path.
    has_paragraph_break: bool,
    /// The run widths were not cached with the string: `measurePendingRuns`
    /// measures them if the text has to wrap.
    run_widths_pending: bool = false,
    /// Where this text's run widths start in the run width buffer.
    first_run: u32,
};

/// Run widths a frame can need: a text has at most one run more than it
/// has bytes (consecutive spaces make empty words), and a cached string's
/// widths are copied whole, even past its last run.
pub fn maxRuns(max_text_bytes: u32, max_texts: u32) u32 {
    return max_text_bytes + max_texts + max_cached_runs;
}

/// Measures through the cache with one text's key, which carries the
/// zoomed size, and returns layout units.
pub fn Measurer(comptime Cache: type, comptime Text: type) type {
    return struct {
        const Self = @This();

        cache: *Cache,
        text_contract: *Text,
        key: Cache.Key,
        inverse_zoom: f32,
        segmenter: Segmenter(Text),

        pub fn measure(self: Self, run: []const u8) [2]f32 {
            const measured = self.cache.measure(self.text_contract, run, self.key);
            return .{ measured[0] * self.inverse_zoom, measured[1] * self.inverse_zoom };
        }

        fn width(self: Self, run: []const u8) f32 {
            if (run.len == 0) return 0;
            return self.measure(run)[0];
        }
    };
}

/// Measures `text` through the string cache, then appends its run widths
/// to `run_widths` as `measureMetrics` does. A hit walks no words; for a
/// text of more than `max_cached_runs` runs it reserves their places and
/// leaves them pending.
pub fn measureText(
    measurer: anytype,
    text: []const u8,
    wrap: style.TextWrap,
    line_height_override: f32,
    run_widths: []f32,
    run_count: *u32,
) Metrics {
    const cache = measurer.cache;
    const hash = @TypeOf(cache.*).stringHashOf(text, measurer.key, wrap, measurer.inverse_zoom);
    const first_run = run_count.*;
    const cached_widths = run_widths[first_run..][0..max_cached_runs];
    var metrics: Metrics = undefined;
    const found = cache.findString(hash);
    const cached = found.value;
    if (found.was_present) {
        metrics = cached.metrics;
        metrics.first_run = first_run;
        metrics.run_widths_pending = cached.run_count > max_cached_runs;
        cached_widths.* = cached.run_widths;
        run_count.* += cached.run_count;
    } else {
        metrics = measureMetrics(measurer, text, wrap, 0, run_widths, run_count);
        cached.* = .{ .metrics = metrics, .run_count = run_count.* - first_run, .run_widths = cached_widths.* };
    }
    if (line_height_override > 0) metrics.line_height = line_height_override;
    return metrics;
}

/// Writes the run widths `measureText` left pending, from `metrics.first_run`.
pub fn measurePendingRuns(measurer: anytype, text: []const u8, wrap: style.TextWrap, metrics: Metrics, run_widths: []f32) void {
    var count = metrics.first_run;
    const runs: RunWriter = .{ .widths = run_widths, .count = &count };
    switch (wrap) {
        .none => _ = runs.append(measurer.measure(text)[0]),
        .newlines => {
            var paragraphs = std.mem.splitScalar(u8, text, '\n');
            while (paragraphs.next()) |paragraph| _ = runs.append(measurer.width(paragraph));
        },
        .words => {
            var words = measurer.segmenter.words(text);
            while (words.next()) |word| _ = runs.append(measurer.width(text[word.start..word.end]));
        },
    }
}

/// Measures `text` and appends the width of each of its runs to
/// `run_widths`: each word for `.words`, each paragraph for `.newlines`,
/// the whole text for `.none`. Wrapping reads them back, so each run is
/// looked up in the cache once per frame, not twice.
pub fn measureMetrics(
    measurer: anytype,
    text: []const u8,
    wrap: style.TextWrap,
    line_height_override: f32,
    run_widths: []f32,
    run_count: *u32,
) Metrics {
    const space = measurer.measure(" ");
    var metrics: Metrics = .{
        .preferred_width = 0,
        .min_width = 0,
        .line_height = if (line_height_override > 0) line_height_override else space[1],
        .space_width = space[0],
        .has_paragraph_break = false,
        .first_run = run_count.*,
    };
    if (text.len == 0) return metrics;
    var runs: RunWriter = .{ .widths = run_widths, .count = run_count };

    switch (wrap) {
        .none => {
            const width = runs.append(measurer.measure(text)[0]);
            metrics.preferred_width = width;
            metrics.min_width = width;
        },
        .newlines => {
            var widest: f32 = 0;
            var paragraphs = std.mem.splitScalar(u8, text, '\n');
            while (paragraphs.next()) |paragraph| widest = @max(widest, runs.append(measurer.width(paragraph)));
            metrics.preferred_width = widest;
            metrics.min_width = widest;
            metrics.has_paragraph_break = run_count.* - metrics.first_run > 1;
        },
        .words => if (comptime segments(@TypeOf(measurer.text_contract.*))) {
            measureSegments(measurer, text, space[0], runs, &metrics);
        } else {
            // Negative until a paragraph ends, so the loop carries no flag for it.
            var widest_ended_paragraph: f32 = -1;
            var widest_word: f32 = 0;
            var paragraph_width: f32 = 0;
            var paragraph_has_word = false;
            var words: WordIterator = .{ .text = text };
            while (words.next()) |word| {
                const word_width = runs.append(measurer.width(text[word.start..word.end]));
                widest_word = @max(widest_word, word_width);
                paragraph_width += word_width + if (paragraph_has_word) space[0] else 0;
                paragraph_has_word = true;
                if (word.ends_paragraph) {
                    widest_ended_paragraph = @max(widest_ended_paragraph, paragraph_width);
                    paragraph_width = 0;
                    paragraph_has_word = false;
                }
            }
            metrics.preferred_width = @max(widest_ended_paragraph, paragraph_width);
            metrics.min_width = widest_word;
            metrics.has_paragraph_break = widest_ended_paragraph >= 0;
        },
    }
    return metrics;
}

/// `measureMetrics` for `.words` with a segmenting text contract. The
/// spaces that end a paragraph count toward its width.
fn measureSegments(measurer: anytype, text: []const u8, space_width: f32, runs: RunWriter, metrics: *Metrics) void {
    var widest_ended_paragraph: f32 = -1;
    var widest_word: f32 = 0;
    var paragraph_width: f32 = 0;
    var trailing_width: f32 = 0;
    var segments_of_text = measurer.segmenter.words(text);
    while (segments_of_text.next()) |segment| {
        const word_width = runs.append(measurer.width(text[segment.start..segment.end]));
        widest_word = @max(widest_word, word_width);
        paragraph_width += word_width + trailing_width;
        trailing_width = spacesWidth(segment.trailing_spaces, space_width);
        if (segment.ends_paragraph) {
            widest_ended_paragraph = @max(widest_ended_paragraph, paragraph_width + trailing_width);
            paragraph_width = 0;
            trailing_width = 0;
        }
    }
    metrics.preferred_width = @max(widest_ended_paragraph, paragraph_width + trailing_width);
    metrics.min_width = widest_word;
    metrics.has_paragraph_break = widest_ended_paragraph >= 0;
}

/// The runs `measureMetrics` measures, other than the space: each
/// non-empty word for `.words`, each non-empty paragraph for `.newlines`,
/// the whole text for `.none`.
pub fn RunIterator(comptime TextSegmenter: type) type {
    return struct {
        const Self = @This();

        text: []const u8,
        wrap: style.TextWrap,
        words: TextSegmenter.Words,
        paragraphs: std.mem.SplitIterator(u8, .scalar),
        whole_text_done: bool = false,

        pub fn init(text: []const u8, wrap: style.TextWrap, segmenter: TextSegmenter) Self {
            return .{ .text = text, .wrap = wrap, .words = segmenter.words(text), .paragraphs = std.mem.splitScalar(u8, text, '\n') };
        }

        pub fn next(self: *Self) ?[]const u8 {
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
}

const RunWriter = struct {
    widths: []f32,
    count: *u32,

    fn append(self: RunWriter, width: f32) f32 {
        self.widths[self.count.*] = width;
        self.count.* += 1;
        return width;
    }
};

/// Appends the lines of `text` laid out within `max_width`, from the run
/// widths `measureMetrics` recorded. `base` is the offset of `text` in the
/// frame's text buffer, so lines index that buffer.
/// A text without a paragraph break that fits is one line, emitted without
/// walking its words: the line greedy wrapping would produce.
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
    const output: LineOutput = .{ .lines = lines, .count = line_count };
    if (fitsOneLine(wrap, metrics, max_width)) return output.emit(base, base + @as(u32, @intCast(text.len)), metrics.preferred_width);

    switch (wrap) {
        .none => unreachable,
        .newlines => {
            var next_run = metrics.first_run;
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
        .words => return wrapWords(text, base, metrics, run_widths, max_width, output),
    }
}

/// `wrapLines` for a segmenting text contract, whose `.words` break where
/// it reports.
pub fn wrapSegmentedLines(
    segmenter: anytype,
    text: []const u8,
    base: u32,
    wrap: style.TextWrap,
    metrics: Metrics,
    run_widths: []const f32,
    max_width: f32,
    lines: []Line,
    line_count: *u32,
) bool {
    if (wrap != .words or text.len == 0 or fitsOneLine(wrap, metrics, max_width)) return wrapLines(text, base, wrap, metrics, run_widths, max_width, lines, line_count);
    return wrapSegments(segmenter.words(text), base, metrics, run_widths, max_width, .{ .lines = lines, .count = line_count });
}

/// Whether `wrapLines` emits the text as one line without reading its run widths.
pub fn fitsOneLine(wrap: style.TextWrap, metrics: Metrics, max_width: f32) bool {
    return switch (wrap) {
        .none => true,
        .newlines => !metrics.has_paragraph_break,
        .words => !metrics.has_paragraph_break and metrics.preferred_width <= max_width + tolerance,
    };
}

/// Greedy wrapping at spaces, with a line of its own after each newline.
/// Words are never broken: layout never makes a text element narrower than
/// its longest word, so a word wider than a line can only come from a
/// parent too small for it, and it overflows, as in CSS by default. Every
/// paragraph has a word, if an empty one, so a newline closes the line.
fn wrapWords(text: []const u8, base: u32, metrics: Metrics, run_widths: []const f32, max_width: f32, output: LineOutput) bool {
    const space_width = metrics.space_width;
    var next_run = metrics.first_run;
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
        }
    }
    if (line_open) return output.emit(base + line_start, base + line_end, line_width);
    return true;
}

/// Greedy wrapping between a segmenting contract's segments, as
/// `wrapWords` wraps between words. The spaces after a line's last segment
/// hang past its end, but for the last line of a paragraph, which keeps
/// them.
fn wrapSegments(text_segments: anytype, base: u32, metrics: Metrics, run_widths: []const f32, max_width: f32, output: LineOutput) bool {
    var segments_of_text = text_segments;
    const space_width = metrics.space_width;
    var next_run = metrics.first_run;
    var line_start: u32 = 0;
    var line_end: u32 = 0;
    var line_width: f32 = 0;
    var line_open = false;
    var trailing_spaces: u32 = 0;
    var trailing_width: f32 = 0;

    while (segments_of_text.next()) |segment| {
        const word_width = run_widths[next_run];
        next_run += 1;

        if (line_open and line_width + trailing_width + word_width > max_width + tolerance) {
            if (!output.emit(base + line_start, base + line_end, line_width)) return false;
            line_open = false;
        }
        if (!line_open) {
            line_start = segment.start;
            line_width = word_width;
            line_open = true;
        } else {
            line_width += trailing_width + word_width;
        }
        line_end = segment.end;
        trailing_spaces = segment.trailing_spaces;
        trailing_width = spacesWidth(trailing_spaces, space_width);

        if (segment.ends_paragraph) {
            if (!output.emit(base + line_start, base + line_end + trailing_spaces, line_width + trailing_width)) return false;
            line_open = false;
        }
    }
    if (!line_open) return true;
    return output.emit(base + line_start, base + line_end + trailing_spaces, line_width + trailing_width);
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

const FixedMetricsText = struct {
    pub fn zuiMeasure(_: *FixedMetricsText, text: []const u8, key: style.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * (key.size / 2 + key.letter_spacing), key.size };
    }
};

const TestCache = MeasureCache(u16, 64, 16, FixedMetricsText);

fn testCache() TestCache {
    var cache: TestCache = undefined;
    cache.reset();
    return cache;
}

fn testMeasurer(cache: *TestCache, text_contract: *FixedMetricsText, zoom: f32) Measurer(TestCache, FixedMetricsText) {
    return .{ .cache = cache, .text_contract = text_contract, .key = .{ .font = 0, .size = 16 * zoom, .letter_spacing = 0 }, .inverse_zoom = 1 / zoom, .segmenter = .{} };
}

test "words split at spaces and newlines" {
    var words: WordIterator = .{ .text = "ab cd\nef" };
    try std.testing.expectEqual(Word{ .start = 0, .end = 2, .ends_paragraph = false }, words.next().?);
    try std.testing.expectEqual(Word{ .start = 3, .end = 5, .ends_paragraph = true }, words.next().?);
    try std.testing.expectEqual(Word{ .start = 6, .end = 8, .ends_paragraph = false }, words.next().?);
    try std.testing.expectEqual(@as(?Word, null), words.next());
}

test "the cache answers repeats without calling the text contract" {
    var cache = testCache();
    var text_contract: FixedMetricsText = .{};
    try std.testing.expectEqual([2]f32{ 40, 16 }, cache.measure(&text_contract, "hello", .{ .font = 0, .size = 16, .letter_spacing = 0 }));
    try std.testing.expectEqual([2]f32{ 40, 16 }, cache.measure(&text_contract, "hello", .{ .font = 0, .size = 16, .letter_spacing = 0 }));
    try std.testing.expectEqual(@as(u64, 1), cache.measure_calls);
    _ = cache.measure(&text_contract, "hello", .{ .font = 0, .size = 20, .letter_spacing = 0 });
    _ = cache.measure(&text_contract, "hello", .{ .font = 0, .size = 16, .letter_spacing = 1 });
    try std.testing.expectEqual(@as(u64, 3), cache.measure_calls);
}

test "zoomed text is measured at the zoomed size and returned in layout units" {
    var cache = testCache();
    var text_contract: FixedMetricsText = .{};
    try std.testing.expectEqual([2]f32{ 40, 16 }, testMeasurer(&cache, &text_contract, 2).measure("hello"));
    try std.testing.expectEqual([2]f32{ 80, 32 }, cache.measure(&text_contract, "hello", .{ .font = 0, .size = 32, .letter_spacing = 0 }));
    try std.testing.expectEqual(@as(u64, 1), cache.measure_calls);
}

test "metrics: preferred and minimum widths" {
    var cache = testCache();
    var text_contract: FixedMetricsText = .{};
    var run_widths: [16]f32 = undefined;
    var run_count: u32 = 0;
    const metrics = measureMetrics(testMeasurer(&cache, &text_contract, 1), "aa bbbb\nc", .words, 0, &run_widths, &run_count);
    try std.testing.expectEqual(@as(u32, 3), run_count);
    try std.testing.expectEqual(@as(f32, 7 * 8), metrics.preferred_width);
    try std.testing.expectEqual(@as(f32, 4 * 8), metrics.min_width);
    try std.testing.expectEqual(@as(f32, 16), metrics.line_height);
}

test "wrapping: greedy, paragraphs, and whole words" {
    var cache = testCache();
    var text_contract: FixedMetricsText = .{};
    var lines: [16]Line = undefined;
    var count: u32 = 0;
    var run_widths: [16]f32 = undefined;
    var run_count: u32 = 0;
    const text = "one two three\nfour abcdefghij";
    const metrics = measureMetrics(testMeasurer(&cache, &text_contract, 1), text, .words, 0, &run_widths, &run_count);
    try std.testing.expect(wrapLines(text, 100, .words, metrics, &run_widths, 64, &lines, &count));
    const expected = [_][]const u8{ "one two", "three", "four", "abcdefghij" };
    try std.testing.expectEqual(expected.len, count);
    for (expected, lines[0..count]) |expected_line, line| {
        try std.testing.expectEqualStrings(expected_line, text[line.start - 100 .. line.end - 100]);
    }
    try std.testing.expectEqual(@as(f32, 7 * 8), lines[0].width);
}

test "a text that fits is one line; one with a newline is not" {
    var cache = testCache();
    var text_contract: FixedMetricsText = .{};
    var lines: [16]Line = undefined;
    var count: u32 = 0;
    var run_widths: [16]f32 = undefined;
    var run_count: u32 = 0;
    const fitting = measureMetrics(testMeasurer(&cache, &text_contract, 1), "one two", .words, 0, &run_widths, &run_count);
    try std.testing.expect(!fitting.has_paragraph_break);
    try std.testing.expect(wrapLines("one two", 0, .words, fitting, &run_widths, 56, &lines, &count));
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(Line{ .start = 0, .end = 7, .width = 56 }, lines[0]);

    count = 0;
    const broken = measureMetrics(testMeasurer(&cache, &text_contract, 1), "one\ntwo", .words, 0, &run_widths, &run_count);
    try std.testing.expect(broken.has_paragraph_break);
    try std.testing.expect(wrapLines("one\ntwo", 0, .words, broken, &run_widths, 1000, &lines, &count));
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "the single-line path emits the line greedy wrapping would" {
    var prng: std.Random.DefaultPrng = .init(0x7e47);
    const random = prng.random();
    var cache = testCache();
    var text_contract: FixedMetricsText = .{};
    const alphabet = "ab  \n";
    for (0..2000) |_| {
        var bytes: [24]u8 = undefined;
        const text = bytes[0..random.intRangeAtMost(usize, 1, bytes.len)];
        for (text) |*byte| byte.* = alphabet[random.uintLessThan(usize, if (random.boolean()) 3 else alphabet.len)];
        const max_width: f32 = @floatFromInt(random.uintLessThan(u32, 24 * 8));

        var run_widths: [32]f32 = undefined;
        var run_count: u32 = 0;
        const metrics = measureMetrics(testMeasurer(&cache, &text_contract, 1), text, .words, 0, &run_widths, &run_count);
        var fast: [32]Line = undefined;
        var fast_count: u32 = 0;
        var greedy: [32]Line = undefined;
        var greedy_count: u32 = 0;
        try std.testing.expect(wrapLines(text, 0, .words, metrics, &run_widths, max_width, &fast, &fast_count));
        try std.testing.expect(wrapWords(text, 0, metrics, &run_widths, max_width, .{ .lines = &greedy, .count = &greedy_count }));
        try std.testing.expectEqualSlices(Line, greedy[0..greedy_count], fast[0..fast_count]);
    }
}

/// Breaks after every space, as the spaces alone would.
const SpaceBreakingText = struct {
    pub fn zuiMeasure(_: *SpaceBreakingText, text: []const u8, key: style.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * key.size / 2, key.size };
    }

    pub fn zuiSegment(_: *SpaceBreakingText, paragraph: []const u8, breaks: *BreakSink) void {
        for (paragraph, 0..) |byte, index| if (byte == ' ') breaks.add(index + 1);
    }
};

test "a contract breaking after every space wraps as the spaces alone do" {
    var prng: std.Random.DefaultPrng = .init(0x5e9);
    const random = prng.random();
    var cache = testCache();
    var spaces_cache: MeasureCache(u16, 64, 16, SpaceBreakingText) = undefined;
    spaces_cache.reset();
    var text_contract: FixedMetricsText = .{};
    var segmenting_contract: SpaceBreakingText = .{};
    var breaks: [32]u32 = undefined;
    const segmenter: Segmenter(SpaceBreakingText) = .{ .text_contract = &segmenting_contract, .breaks = &breaks };
    const segmenting: Measurer(@TypeOf(spaces_cache), SpaceBreakingText) = .{ .cache = &spaces_cache, .text_contract = &segmenting_contract, .key = .{ .font = 0, .size = 16, .letter_spacing = 0 }, .inverse_zoom = 1, .segmenter = segmenter };
    const alphabet = "ab  \n";
    var compared: u32 = 0;
    for (0..2000) |_| {
        var bytes: [24]u8 = undefined;
        const text = bytes[0..random.intRangeAtMost(usize, 1, bytes.len)];
        for (text) |*byte| byte.* = alphabet[random.uintLessThan(usize, if (random.boolean()) 3 else alphabet.len)];
        // A space that ends a paragraph hangs for a segmenting contract,
        // where the default wraps an empty word after it.
        if (std.mem.indexOf(u8, text, " \n") != null or text[text.len - 1] == ' ') continue;
        compared += 1;
        const max_width: f32 = @floatFromInt(random.uintLessThan(u32, 24 * 8));

        var run_widths: [32]f32 = undefined;
        var run_count: u32 = 0;
        const metrics = measureMetrics(testMeasurer(&cache, &text_contract, 1), text, .words, 0, &run_widths, &run_count);
        var segmented_widths: [32]f32 = undefined;
        var segmented_count: u32 = 0;
        const segmented_metrics = measureMetrics(segmenting, text, .words, 0, &segmented_widths, &segmented_count);
        try std.testing.expectEqual(metrics.preferred_width, segmented_metrics.preferred_width);
        try std.testing.expectEqual(metrics.min_width, segmented_metrics.min_width);
        try std.testing.expectEqual(metrics.has_paragraph_break, segmented_metrics.has_paragraph_break);

        var lines: [32]Line = undefined;
        var line_count: u32 = 0;
        var segmented_lines: [32]Line = undefined;
        var segmented_line_count: u32 = 0;
        try std.testing.expect(wrapLines(text, 0, .words, metrics, &run_widths, max_width, &lines, &line_count));
        try std.testing.expect(wrapSegmentedLines(segmenter, text, 0, .words, segmented_metrics, &segmented_widths, max_width, &segmented_lines, &segmented_line_count));
        try std.testing.expectEqualSlices(Line, lines[0..line_count], segmented_lines[0..segmented_line_count]);
    }
    try std.testing.expect(compared > 500);
}

test "a break sink keeps increasing offsets inside the paragraph" {
    var offsets: [4]u32 = undefined;
    var sink: BreakSink = .{ .offsets = &offsets, .paragraph_len = 10 };
    for ([_]usize{ 0, 3, 3, 2, 7, 10, 12, 9 }) |offset| sink.add(offset);
    try std.testing.expectEqualSlices(u32, &.{ 3, 7, 9 }, offsets[0..sink.count]);
}

test "a paragraph's first word adds no space before it" {
    var cache = testCache();
    var text_contract: FixedMetricsText = .{};
    var lines: [16]Line = undefined;
    var count: u32 = 0;
    var run_widths: [16]f32 = undefined;
    var run_count: u32 = 0;
    const text = "one\nfour abcdefghij";
    const metrics = measureMetrics(testMeasurer(&cache, &text_contract, 1), text, .words, 0, &run_widths, &run_count);
    try std.testing.expect(wrapLines(text, 0, .words, metrics, &run_widths, 80, &lines, &count));
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual(Line{ .start = 4, .end = 8, .width = 32 }, lines[1]);
}

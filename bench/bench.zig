//! `zig build bench` runs these in ReleaseFast and prints one row per
//! scenario (SPEC.md §14.3).
//!
//! ```sh
//! zig build bench                                  # print the tables
//! zig build bench -- --check-targets               # fail if a §6.5 target is missed
//! zig build bench -- --json results.json           # save each scenario's fastest frame
//! zig build bench -- --compare baseline.json       # fail on a >10% regression
//! ```

const std = @import("std");
const zui = @import("zui");
const Io = std.Io;

/// Text measurement with the cost profile of a bitmap font: one table
/// lookup per byte.
const GlyphTablePlatform = struct {
    advances: [256]f32 = blk: {
        var table: [256]f32 = undefined;
        for (&table, 0..) |*advance, byte| advance.* = 6 + @as(f32, @floatFromInt(byte % 5));
        break :blk table;
    },

    pub fn measureText(self: *GlyphTablePlatform, text: []const u8, _: u16, size: f32) [2]f32 {
        var width: f32 = 0;
        for (text) |byte| width += self.advances[byte];
        return .{ width * size / 16, size };
    }
};

/// Text measurement with the cost profile of a shaping engine: about a
/// microsecond for a short word.
fn ShapingPlatform(comptime thread_safe: bool) type {
    return struct {
        const Self = @This();
        pub const thread_safe_measure = thread_safe;
        const rounds_per_byte = 160;

        pub fn measureText(_: *Self, text: []const u8, _: u16, size: f32) [2]f32 {
            var state: u64 = 0x9e3779b97f4a7c15;
            for (text) |byte| {
                for (0..rounds_per_byte) |_| state = (state ^ byte) *% 0x100000001b3;
            }
            std.mem.doNotOptimizeAway(state);
            return .{ @as(f32, @floatFromInt(text.len)) * size / 2, size };
        }
    };
}

const Measurement = struct {
    name: []const u8,
    elements: u32,
    /// Layout and emission: the time `endFrame` takes.
    layout_min_ns: u64,
    layout_median_ns: u64,
    /// Declaration, layout and emission together.
    frame_median_ns: u64,
    target_ns: ?u64 = null,
    platform_calls_per_frame: f64,
};

const max_timed_frames = 400;

fn Scenario(comptime config: zui.Config, comptime Platform: type, comptime Scene: type) type {
    return struct {
        const Ui = zui.Context(config, Platform);

        /// Times `frame_count` frames after `warmup_frames`, in a fresh
        /// Context whose allocator counts every call after `init`.
        fn run(io: Io, gpa: std.mem.Allocator, warmup_frames: usize, frame_count: usize) !Measurement {
            var platform: Platform = .{};
            var counting: CountingAllocator = .{ .backing = gpa };
            var ui = try Ui.init(counting.allocator(), io, &platform);
            defer ui.deinit(counting.allocator());
            const allocations_after_init = counting.allocations;

            var scene: Scene = .{};
            for (0..warmup_frames) |index| {
                ui.beginFrame(.{ .viewport = .{ 1600, 1200 } });
                scene.declare(&ui, index);
                ui.release(try ui.endFrame());
            }

            var layout_times: [max_timed_frames]u64 = undefined;
            var frame_times: [max_timed_frames]u64 = undefined;
            const calls_before = ui.measureCalls();
            for (0..frame_count) |index| {
                const frame_start = Io.Timestamp.now(io, .awake);
                ui.beginFrame(.{ .viewport = .{ 1600, 1200 } });
                scene.declare(&ui, warmup_frames + index);
                const layout_start = Io.Timestamp.now(io, .awake);
                const frame = try ui.endFrame();
                const end = Io.Timestamp.now(io, .awake);
                ui.release(frame);
                layout_times[index] = @intCast(layout_start.durationTo(end).nanoseconds);
                frame_times[index] = @intCast(frame_start.durationTo(end).nanoseconds);
            }
            const calls = ui.measureCalls() - calls_before;
            if (counting.allocations != allocations_after_init) return error.FramesAllocated;

            std.mem.sortUnstable(u64, layout_times[0..frame_count], {}, std.sort.asc(u64));
            std.mem.sortUnstable(u64, frame_times[0..frame_count], {}, std.sort.asc(u64));
            return .{
                .name = Scene.name,
                .elements = ui.lastFrame().element_count,
                .layout_min_ns = layout_times[0],
                .layout_median_ns = layout_times[frame_count / 2],
                .frame_median_ns = frame_times[frame_count / 2],
                .target_ns = Scene.target_ns,
                .platform_calls_per_frame = @as(f64, @floatFromInt(calls)) / @as(f64, @floatFromInt(frame_count)),
            };
        }
    };
}

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocations: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.allocations += 1;
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

/// SPEC.md §6.5: 4,096 boxes, depth 8, no text. 512 rows, each a chain of
/// 8 nested boxes with a mix of sizing rules, so nearly every element is a
/// parent: the most per-element work a tree of this size can ask for.
const BoxTree = struct {
    const name = "4096 boxes, depth 8";
    const target_ns: ?u64 = 100 * std.time.ns_per_us;
    const config: zui.Config = .{ .max_elements = 4200, .max_render_commands = 8192 };

    fn declare(_: *BoxTree, ui: anytype, _: usize) void {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 1 } });
        for (0..512) |row| {
            for (0..8) |depth| {
                const sizing: zui.Sizing2 = switch ((row + depth) % 4) {
                    0 => .{ .width = .grow, .height = .fit },
                    1 => .{ .width = .fit, .height = .fixed(2) },
                    2 => .{ .width = .percent(0.9), .height = .fit },
                    else => .{ .width = .growBetween(4, 400), .height = .fit },
                };
                ui.open(.{
                    .layout = .{ .sizing = sizing, .padding = .all(1), .child_gap = 1, .direction = if (depth % 2 == 0) .left_to_right else .top_to_bottom },
                    .background = if (depth % 3 == 0) zui.Color.rgb(0x202030) else null,
                });
            }
            for (0..8) |_| ui.close();
        }
        ui.close();
    }
};

const vocabulary = [_][]const u8{
    "layout", "frame",  "render", "measure", "text",   "zig",      "comptime", "element", "panel",  "button",
    "slider", "scroll", "focus",  "hover",   "click",  "window",   "widget",   "cache",   "word",   "line",
    "the",    "a",      "of",     "and",     "to",     "in",       "is",       "for",     "with",   "on",
    "every",  "nested", "fast",   "small",   "simple", "explicit", "memory",   "arena",   "thread", "task",
};

/// 1,000 sentences of about 40 characters, from `vocabulary` or, with
/// `made_up_words`, from random words that rarely repeat.
fn Sentences(comptime made_up_words: bool) type {
    return struct {
        const Self = @This();

        sentences: [1000][]const u8 = undefined,
        storage: [1000][64]u8 = undefined,
        prepared: bool = false,

        fn get(self: *Self) *const [1000][]const u8 {
            if (self.prepared) return &self.sentences;
            var prng: std.Random.DefaultPrng = .init(0x5eed);
            const random = prng.random();
            for (&self.sentences, &self.storage) |*sentence, *bytes| {
                var length: usize = 0;
                const target_length = 40 + random.uintLessThan(usize, 8);
                while (true) {
                    var made_up: [9]u8 = undefined;
                    const word = if (made_up_words) blk: {
                        const word_length = 3 + random.uintLessThan(usize, 7);
                        for (made_up[0..word_length]) |*byte| byte.* = 'a' + random.uintLessThan(u8, 26);
                        break :blk made_up[0..word_length];
                    } else vocabulary[random.uintLessThan(usize, vocabulary.len)];
                    if (length + word.len + 1 > target_length) break;
                    if (length != 0) {
                        bytes[length] = ' ';
                        length += 1;
                    }
                    @memcpy(bytes[length..][0..word.len], word);
                    length += word.len;
                }
                sentence.* = bytes[0..length];
            }
            self.prepared = true;
            return &self.sentences;
        }
    };
}

/// 1,000 texts in 100 panels 160 units wide, so most wrap.
fn declareTextWall(ui: anytype, sentences: *const [1000][]const u8, size: f32) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both } });
    for (0..100) |panel| {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(160) }, .padding = .all(4), .child_gap = 2 } });
        for (sentences[panel * 10 ..][0..10]) |sentence| ui.text(sentence, .{ .size = size });
        ui.close();
    }
    ui.close();
}

/// A different font size every frame, so every measurement misses the cache.
fn coldSize(frame_index: usize) f32 {
    return 14 + @as(f32, @floatFromInt(frame_index % 1024)) / 128;
}

const text_config: zui.Config = .{ .max_elements = 1200, .max_render_commands = 8192, .max_text_bytes = 64 * 1024 };

/// SPEC.md §6.5: 1,000 text elements averaging 40 characters, all
/// measurements cached.
const TextWall = struct {
    const name = "1000 texts, warm cache";
    const target_ns: ?u64 = 250 * std.time.ns_per_us;
    sentences: Sentences(false) = .{},

    fn declare(self: *TextWall, ui: anytype, _: usize) void {
        declareTextWall(ui, self.sentences.get(), 16);
    }
};

const TextWallCold = struct {
    const name = "1000 texts, cold cache";
    const target_ns: ?u64 = null;
    sentences: Sentences(false) = .{},

    fn declare(self: *TextWallCold, ui: anytype, frame_index: usize) void {
        declareTextWall(ui, self.sentences.get(), coldSize(frame_index));
    }
};

const DeepTree = struct {
    const name = "depth 64";
    const target_ns: ?u64 = null;
    const config: zui.Config = .{ .max_elements = 128, .max_depth = 80 };

    fn declare(_: *DeepTree, ui: anytype, _: usize) void {
        for (0..64) |depth| ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fit }, .padding = .all(1), .direction = if (depth % 2 == 0) .left_to_right else .top_to_bottom } });
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } } });
        for (0..64) |_| ui.close();
    }
};

const WideTree = struct {
    const name = "4000 children of one parent";
    const target_ns: ?u64 = null;
    const config: zui.Config = .{ .max_elements = 4100, .max_render_commands = 8192 };

    fn declare(_: *WideTree, ui: anytype, _: usize) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 1 } });
        for (0..4000) |index| ui.box(.{
            .layout = .{ .sizing = .{ .width = if (index % 2 == 0) .grow else .fixed(1), .height = .fixed(8) } },
            .background = .rgb(0x303040),
        });
        ui.close();
    }
};

const shaping_config: zui.Config = .{
    .max_elements = 1200,
    .max_render_commands = 8192,
    .max_text_bytes = 64 * 1024,
    .measure_cache_entries = 16384,
    .parallel_measure_capacity = 8192,
};

/// SPEC.md §10.5: cold frames whose measurements cost about a microsecond
/// each, as with a shaping engine, measured on one thread and then across
/// the `Io`'s threads.
fn ShapedTextWall(comptime parallel: bool) type {
    return struct {
        const Self = @This();
        const name = if (parallel) "shaped text, parallel" else "shaped text, one thread";
        const target_ns: ?u64 = null;
        sentences: Sentences(true) = .{},

        fn declare(self: *Self, ui: anytype, frame_index: usize) void {
            declareTextWall(ui, self.sentences.get(), coldSize(frame_index));
        }
    };
}

/// SPEC.md §10.2: frames rendered on a second thread while the next one is
/// declared and laid out, against the same work on one thread.
fn framesPerSecond(io: Io, gpa: std.mem.Allocator, render_thread: bool) !f64 {
    const Ui = zui.Context(text_config, GlyphTablePlatform);
    var platform: GlyphTablePlatform = .{};
    var ui = try Ui.init(gpa, io, &platform);
    defer ui.deinit(gpa);
    var sentences: Sentences(false) = .{};

    const frame_count = 300;
    var queue_buffer: [2]*const Ui.Frame = undefined;
    var queue: Io.Queue(*const Ui.Frame) = .init(&queue_buffer);
    var renderer: ?Io.Future(void) = if (render_thread) try io.concurrent(renderFrames(Ui), .{ io, &ui, &queue }) else null;

    const start = Io.Timestamp.now(io, .awake);
    for (0..frame_count) |_| {
        ui.beginFrame(.{ .viewport = .{ 1600, 1200 } });
        declareTextWall(&ui, sentences.get(), 16);
        const frame = try ui.endFrame();
        if (renderer != null) {
            queue.putOneUncancelable(io, frame) catch unreachable;
        } else {
            simulateRender(Ui, io, frame);
            ui.release(frame);
        }
    }
    if (renderer) |*running| {
        queue.close(io);
        running.await(io);
    }
    const elapsed_ns: f64 = @floatFromInt(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
    return frame_count * std.time.ns_per_s / elapsed_ns;
}

fn renderFrames(comptime Ui: type) fn (Io, *Ui, *Io.Queue(*const Ui.Frame)) void {
    return struct {
        fn render(io: Io, ui: *Ui, queue: *Io.Queue(*const Ui.Frame)) void {
            while (queue.getOneUncancelable(io)) |frame| {
                simulateRender(Ui, io, frame);
                ui.release(frame);
            } else |_| {}
        }
    }.render;
}

/// A renderer that reads every command and then takes 200 µs, about as
/// long as declaring and laying out the frame. A clock-bounded wait rather
/// than arithmetic, which the optimizer is free to shorten.
fn simulateRender(comptime Ui: type, io: Io, frame: *const Ui.Frame) void {
    var checksum: f32 = 0;
    for (frame.commands()) |command| checksum += command.bounds.x;
    std.mem.doNotOptimizeAway(checksum);
    const start = Io.Timestamp.now(io, .awake);
    while (start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds < 200 * std.time.ns_per_us) {}
}

const Options = struct {
    json_path: ?[]const u8 = null,
    compare_path: ?[]const u8 = null,
    check_targets: bool = false,
};

fn parseOptions(arguments: []const [:0]const u8) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--json") and index + 1 < arguments.len) {
            index += 1;
            options.json_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--compare") and index + 1 < arguments.len) {
            index += 1;
            options.compare_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--check-targets")) {
            options.check_targets = true;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --json <path>, --compare <path> or --check-targets\n", .{argument});
            return error.UnknownArgument;
        }
    }
    return options;
}

fn microseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_us;
}

/// The scenarios a regression check compares: the single-threaded ones,
/// whose times don't depend on what the machine's other cores are doing.
const compared_count = 5;
const regression_tolerance = 1.10;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const options = try parseOptions(try init.minimal.args.toSlice(arena));

    const measurements = [_]Measurement{
        try Scenario(BoxTree.config, GlyphTablePlatform, BoxTree).run(io, gpa, 20, 400),
        try Scenario(text_config, GlyphTablePlatform, TextWall).run(io, gpa, 20, 400),
        try Scenario(text_config, GlyphTablePlatform, TextWallCold).run(io, gpa, 20, 400),
        try Scenario(DeepTree.config, GlyphTablePlatform, DeepTree).run(io, gpa, 20, 400),
        try Scenario(WideTree.config, GlyphTablePlatform, WideTree).run(io, gpa, 20, 400),
        try Scenario(shaping_config, ShapingPlatform(false), ShapedTextWall(false)).run(io, gpa, 2, 20),
        try Scenario(shaping_config, ShapingPlatform(true), ShapedTextWall(true)).run(io, gpa, 2, 20),
    };
    const one_thread_rate = try framesPerSecond(io, gpa, false);
    const render_thread_rate = try framesPerSecond(io, gpa, true);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("{s:<28} {s:>8} {s:>11} {s:>11} {s:>11} {s:>8} {s:>12} {s:>9}\n", .{ "scenario", "elements", "layout min", "layout med", "frame med", "ns/elem", "target", "measures" });
    var missed_target = false;
    for (measurements) |measurement| {
        const per_element = @as(f64, @floatFromInt(measurement.layout_min_ns)) / @as(f64, @floatFromInt(measurement.elements));
        var target_buffer: [32]u8 = undefined;
        const target_text = if (measurement.target_ns) |target| blk: {
            const met = measurement.layout_min_ns <= target;
            if (!met) missed_target = true;
            break :blk std.fmt.bufPrint(&target_buffer, "{s} {d:.0}us", .{ if (met) "ok" else "MISS", microseconds(target) }) catch unreachable;
        } else "";
        try out.print("{s:<28} {d:>8} {d:>9.1}us {d:>9.1}us {d:>9.1}us {d:>8.1} {s:>12} {d:>9.0}\n", .{
            measurement.name,
            measurement.elements,
            microseconds(measurement.layout_min_ns),
            microseconds(measurement.layout_median_ns),
            microseconds(measurement.frame_median_ns),
            per_element,
            target_text,
            measurement.platform_calls_per_frame,
        });
    }
    const shaped_one_thread: f64 = @floatFromInt(measurements[5].layout_median_ns);
    const shaped_parallel: f64 = @floatFromInt(measurements[6].layout_median_ns);
    try out.print("\nparallel measurement: {d:.2}x as fast as one thread\n", .{shaped_one_thread / shaped_parallel});
    try out.print("render thread: {d:.0} frames/s against {d:.0} on one thread ({d:.2}x)\n", .{ render_thread_rate, one_thread_rate, render_thread_rate / one_thread_rate });
    try out.writeAll("allocations after init: 0 in every scenario\n");
    try out.flush();

    if (options.json_path) |path| try writeJson(io, path, measurements[0..compared_count]);
    const regressed = if (options.compare_path) |path| try compare(io, arena, out, path, measurements[0..compared_count]) else false;
    try out.flush();
    if (regressed) return error.Regression;
    if (options.check_targets and missed_target) return error.TargetMissed;
}

fn writeJson(io: Io, path: []const u8, measurements: []const Measurement) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll("{\n");
    for (measurements, 0..) |measurement, index| {
        try writer.print("  \"{s}\": {d}{s}\n", .{ measurement.name, measurement.layout_min_ns, if (index + 1 < measurements.len) "," else "" });
    }
    try writer.writeAll("}\n");
    try writer.flush();
}

/// Prints each scenario's change against the baseline and returns whether
/// any is more than 10% slower. A scenario missing from the baseline is new
/// and only printed.
fn compare(io: Io, arena: std.mem.Allocator, out: *Io.Writer, path: []const u8, measurements: []const Measurement) !bool {
    const contents = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024));
    const baseline = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap(u64), arena, contents, .{});
    try out.writeAll("\nagainst the baseline (fastest frames):\n");
    var regressed = false;
    for (measurements) |measurement| {
        const before = baseline.map.get(measurement.name) orelse {
            try out.print("  {s:<28} new\n", .{measurement.name});
            continue;
        };
        const ratio = @as(f64, @floatFromInt(measurement.layout_min_ns)) / @as(f64, @floatFromInt(before));
        const slower = ratio > regression_tolerance;
        if (slower) regressed = true;
        try out.print("  {s:<28} {d:>9.1}us -> {d:>9.1}us  {s}{d:.1}%{s}\n", .{
            measurement.name,
            microseconds(before),
            microseconds(measurement.layout_min_ns),
            if (ratio >= 1) "+" else "",
            (ratio - 1) * 100,
            if (slower) "  REGRESSION" else "",
        });
    }
    return regressed;
}

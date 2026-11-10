//! ```sh
//! zig build bench                                  # print the tables
//! zig build bench -- --check-targets               # fail if a SPEC.md §20.2 budget is missed
//! zig build bench -- --json results.json           # save each scenario's fastest declaration and layout
//! zig build bench -- --core 3 --machine-json m.json # pin to core 3, raise priority, record the machine
//! ZUI_BENCH_LAYOUT_SEED=7 zig build bench          # move the stack and each Context's memory
//! zig build bench -Dbench-layout-seed=7            # move the code
//! zig build bench -- --counters                    # also count cycles, instructions and misses (Linux)
//! ```
//!
//! Two commits are compared with `zig build bench-compare`, never by two
//! runs of this.

const std = @import("std");
const zui = @import("zui");
const Io = std.Io;

const bench_options = @import("bench_options");
const counters = @import("counters.zig");
const machine = @import("machine.zig");
const statistics = @import("statistics.zig");
const scenes = @import("scenes.zig");
const GlyphTableText = scenes.GlyphTableText;
const Sentences = scenes.Sentences;
const declareTextWall = scenes.declareTextWall;
const coldSize = scenes.coldSize;
const text_limits = scenes.text_limits;
const BoxTree = scenes.BoxTree;
const StaticBoxTree = scenes.StaticBoxTree;
const TextWall = scenes.TextWall;
const TextWallCold = scenes.TextWallCold;
const SingleLineTexts = scenes.SingleLineTexts;
const ChangingTexts = scenes.ChangingTexts;
const DeepTree = scenes.DeepTree;
const WideTree = scenes.WideTree;
const DocumentsView = scenes.DocumentsView;
const GridWithTooltip = scenes.GridWithTooltip;
const InteractiveBoxTree = scenes.InteractiveBoxTree;
const PressedInteractiveBoxTree = scenes.PressedInteractiveBoxTree;
const eventsOf = scenes.eventsOf;

/// Text measurement with the cost profile of a shaping engine: about a
/// microsecond for a short word.
fn ShapingText(comptime thread_safe: bool) type {
    return struct {
        const Self = @This();
        pub const zui_thread_safe = thread_safe;
        const rounds_per_byte = 160;

        pub fn zuiMeasure(_: *Self, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
            var state: u64 = 0x9e3779b97f4a7c15;
            for (text) |byte| {
                for (0..rounds_per_byte) |_| state = (state ^ byte) *% 0x100000001b3;
            }
            std.mem.doNotOptimizeAway(state);
            return .{ @as(f32, @floatFromInt(text.len)) * key.size / 2, key.size };
        }
    };
}

/// One phase's times over a scenario's timed frames.
const Spread = struct {
    min_ns: u64,
    median_ns: u64,
    p95_ns: u64,
    clusters: ?statistics.Clusters,

    fn of(sorted: []const u64) Spread {
        return .{
            .min_ns = sorted[0],
            .median_ns = sorted[sorted.len / 2],
            .p95_ns = statistics.percentile(sorted, 0.95),
            .clusters = statistics.twoClusters(sorted),
        };
    }
};

const Measurement = struct {
    name: []const u8,
    elements: u32,
    /// `beginFrame` and the scene's `open`/`close` calls: everything before `endFrame`.
    declare: Spread,
    /// Layout and emission: the time `endFrame` takes.
    layout: Spread,
    /// Declaration, layout and emission together.
    frame_median_ns: u64,
    /// Each event's fewest per frame, with `--counters`.
    declare_counts: ?counters.Counts = null,
    layout_counts: ?counters.Counts = null,
    layout_target_ns: ?u64 = null,
    declare_target_ns: ?u64 = null,
    measure_calls_per_frame: f64,
};

const max_timed_frames = 400;

/// Bytes of padding at the start of the code, so every function after it
/// lands somewhere else: 0 to 4080, in steps of the 16 bytes functions are
/// aligned to. LLVM emits module assembly before any function.
const code_shift = if (bench_options.layout_seed == 0) 0 else (bench_options.layout_seed *% 0x9e3779b97f4a7c15 >> 56) * 16;

comptime {
    if (code_shift > 0) asm (std.fmt.comptimePrint(".text\n.skip {d}\n", .{code_shift}));
}

/// Where a run puts its stack and each scenario's `Context` memory, chosen
/// by `ZUI_BENCH_LAYOUT_SEED`. Moving them shows how much of a time comes
/// from where things happen to land: a cache set, a 4 KiB alias, a split
/// line. Without a seed, both shifts are zero.
const Layout = struct {
    /// The stack moves down by this many 64-byte steps, up to 4 KiB.
    stack_steps: u6 = 0,
    /// Each `Context` starts this many bytes into a larger allocation, a
    /// multiple of `heap_step` under 4 KiB.
    heap_offset: usize = 0,
    /// Counts each phase of the compared scenarios, with `--counters`.
    counter_group: ?*counters.Group = null,

    const environment_variable = "ZUI_BENCH_LAYOUT_SEED";
    const heap_span = 4096;
    /// Every `Context`'s buffer alignment, the cache line, divides this.
    const heap_step = @max(128, std.atomic.cache_line);

    fn fromSeed(seed: u64) Layout {
        var prng: std.Random.DefaultPrng = .init(seed);
        const random = prng.random();
        return .{
            .stack_steps = random.int(u6),
            .heap_offset = random.uintLessThan(usize, heap_span / heap_step) * heap_step,
        };
    }

    fn read(environ: *const std.process.Environ.Map) !Layout {
        const text = environ.get(environment_variable) orelse return .{};
        const seed = std.fmt.parseInt(u64, text, 10) catch {
            std.debug.print("{s} needs a whole number, got \"{s}\"\n", .{ environment_variable, text });
            return error.InvalidArgument;
        };
        return fromSeed(seed);
    }

    /// Runs `entry` with the stack moved down by `stack_steps`.
    fn runShifted(layout: Layout, entry: Entry, io: Io, gpa: std.mem.Allocator) anyerror!Run {
        switch (layout.stack_steps) {
            inline else => |steps| return StackShift(steps).run(entry, layout, io, gpa),
        }
    }

    fn StackShift(comptime steps: u6) type {
        return struct {
            noinline fn run(entry: Entry, layout: Layout, io: Io, gpa: std.mem.Allocator) anyerror!Run {
                var padding: [@as(usize, steps) * 64]u8 = undefined;
                std.mem.doNotOptimizeAway(&padding);
                return @call(.never_inline, entry.run, .{ io, gpa, layout });
            }
        };
    }
};

fn Scenario(comptime limits: zui.Limits, comptime Text: type, comptime Scene: type) type {
    return struct {
        const Ui = zui.Context(.{ .limits = limits, .Text = Text });

        /// Times `frame_count` frames after `warmup_frames`, in a fresh
        /// Context whose allocator counts every call after `init`.
        fn run(io: Io, gpa: std.mem.Allocator, layout: Layout, warmup_frames: usize, frame_count: usize) !Measurement {
            comptime std.debug.assert(Layout.heap_step % Ui.buffer_alignment == 0);
            var text: Text = .{};
            var counting: CountingAllocator = .{ .backing = gpa };
            const memory = try counting.allocator().alignedAlloc(u8, .fromByteUnits(Ui.buffer_alignment), Ui.required_bytes + Layout.heap_span);
            defer counting.allocator().free(memory);
            var ui = try Ui.initBuffer(@alignCast(memory[layout.heap_offset..]), io, &text);
            defer ui.deinit(undefined);
            const allocations_after_init = counting.allocations;

            var scene: Scene = .{};
            for (0..warmup_frames) |index| {
                ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1600, 1200 } }, .events = eventsOf(&scene, index) });
                scene.declare(&ui, index);
                ui.release(ui.endFrame());
            }

            var element_count: u32 = 0;
            var declare_times: [max_timed_frames]u64 = undefined;
            var layout_times: [max_timed_frames]u64 = undefined;
            var frame_times: [max_timed_frames]u64 = undefined;
            const group = layout.counter_group;
            var declare_counts: counters.Counts = @splat(std.math.maxInt(u64));
            var layout_counts: counters.Counts = @splat(std.math.maxInt(u64));
            const calls_before = ui.measureCalls();
            for (0..frame_count) |index| {
                if (group) |counting_group| counting_group.start();
                const frame_start = Io.Timestamp.now(io, .awake);
                ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1600, 1200 } }, .events = eventsOf(&scene, warmup_frames + index) });
                scene.declare(&ui, warmup_frames + index);
                const declare_end = Io.Timestamp.now(io, .awake);
                // Reading the counters between the phases stays out of
                // both phases' times.
                const layout_start = if (group) |counting_group| started: {
                    counting_group.stop();
                    fewest(&declare_counts, try counting_group.read());
                    counting_group.start();
                    break :started Io.Timestamp.now(io, .awake);
                } else declare_end;
                const frame = ui.endFrame();
                const end = Io.Timestamp.now(io, .awake);
                if (group) |counting_group| {
                    counting_group.stop();
                    fewest(&layout_counts, try counting_group.read());
                }
                element_count = frame.elementCount();
                ui.release(frame);
                declare_times[index] = @intCast(frame_start.durationTo(declare_end).nanoseconds);
                layout_times[index] = @intCast(layout_start.durationTo(end).nanoseconds);
                frame_times[index] = declare_times[index] + layout_times[index];
            }
            const calls = ui.measureCalls() - calls_before;
            if (counting.allocations != allocations_after_init) return error.FramesAllocated;

            std.mem.sortUnstable(u64, declare_times[0..frame_count], {}, std.sort.asc(u64));
            std.mem.sortUnstable(u64, layout_times[0..frame_count], {}, std.sort.asc(u64));
            std.mem.sortUnstable(u64, frame_times[0..frame_count], {}, std.sort.asc(u64));
            return .{
                .name = Scene.name,
                .elements = element_count,
                .declare = .of(declare_times[0..frame_count]),
                .layout = .of(layout_times[0..frame_count]),
                .frame_median_ns = frame_times[frame_count / 2],
                .layout_target_ns = Scene.layout_target_ns,
                .declare_target_ns = if (@hasDecl(Scene, "declare_target_ns")) Scene.declare_target_ns else null,
                .measure_calls_per_frame = @as(f64, @floatFromInt(calls)) / @as(f64, @floatFromInt(frame_count)),
                .declare_counts = if (group != null) declare_counts else null,
                .layout_counts = if (group != null) layout_counts else null,
            };
        }
    };
}

fn fewest(least: *counters.Counts, counts: counters.Counts) void {
    for (least, counts) |*kept, count| kept.* = @min(kept.*, count);
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

const shaping_limits: zui.Limits = .{
    .max_elements = 1200,
    .max_render_commands = 8192,
    .max_text_bytes = 64 * 1024,
    .measure_cache_entries = 16384,
    .parallel_measure_capacity = 8192,
};

/// Cold frames whose measurements cost about a microsecond
/// each, as with a shaping engine, measured on one thread and then across
/// the `Io`'s threads.
fn ShapedTextWall(comptime parallel: bool) type {
    return struct {
        const Self = @This();
        const name = if (parallel) "shaped text, parallel" else "shaped text, one thread";
        const layout_target_ns: ?u64 = null;
        sentences: Sentences(true) = .{},

        fn declare(self: *Self, ui: anytype, frame_index: usize) void {
            declareTextWall(ui, self.sentences.get(), coldSize(frame_index));
        }
    };
}

/// Frames rendered on a second thread while the next one is
/// declared and laid out, against the same work on one thread.
fn framesPerSecond(io: Io, gpa: std.mem.Allocator, render_thread: bool) !f64 {
    const Ui = zui.Context(.{ .limits = text_limits, .Text = GlyphTableText });
    var text: GlyphTableText = .{};
    var ui = try Ui.init(gpa, io, &text);
    defer ui.deinit(gpa);
    var sentences: Sentences(false) = .{};

    const frame_count = 300;
    var queue_buffer: [2]*const Ui.Frame = undefined;
    var queue: Io.Queue(*const Ui.Frame) = .init(&queue_buffer);
    var renderer: ?Io.Future(void) = if (render_thread) try io.concurrent(renderFrames(Ui), .{ io, &ui, &queue }) else null;

    const start = Io.Timestamp.now(io, .awake);
    for (0..frame_count) |_| {
        ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1600, 1200 } } });
        declareTextWall(&ui, sentences.get(), 16);
        const frame = ui.endFrame();
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

const StartupMeasurement = struct {
    name: []const u8,
    spread: Spread,
};

const startup_samples = 50;

fn startupMeasurement(name: []const u8, times: *[startup_samples]u64) StartupMeasurement {
    std.mem.sortUnstable(u64, times, {}, std.sort.asc(u64));
    return .{ .name = name, .spread = .of(times) };
}

const DefaultUi = zui.Context(.{ .Text = GlyphTableText });

/// Each sample gets memory the process has never touched, so its page
/// faults are timed, as they are when an application starts.
fn timeInit(io: Io, gpa: std.mem.Allocator) !StartupMeasurement {
    var text: GlyphTableText = .{};
    var times: [startup_samples]u64 = undefined;
    for (&times) |*time| {
        const start = Io.Timestamp.now(io, .awake);
        var ui = try DefaultUi.init(gpa, io, &text);
        time.* = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        ui.deinit(gpa);
    }
    return startupMeasurement("init, default config", &times);
}

var init_buffer: [DefaultUi.required_bytes]u8 align(DefaultUi.buffer_alignment) = undefined;

/// Only the first sample touches `init_buffer` for the first time, so this
/// is the time zui itself spends preparing memory.
fn timeInitBuffer(io: Io, _: std.mem.Allocator) !StartupMeasurement {
    var text: GlyphTableText = .{};
    var times: [startup_samples]u64 = undefined;
    for (&times) |*time| {
        const start = Io.Timestamp.now(io, .awake);
        var ui = try DefaultUi.initBuffer(&init_buffer, io, &text);
        // Nothing else reads `init_buffer`, so without this LLVM deletes
        // every write `initBuffer` makes to it, and the sample times nothing.
        std.mem.doNotOptimizeAway(&ui);
        time.* = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        ui.deinit(undefined);
    }
    return startupMeasurement("initBuffer, default config", &times);
}

/// The first frame of each new `Context`: every measurement misses the
/// cache, and the frame's memory is touched for the first time.
fn FirstFrame(comptime name: []const u8, comptime limits: zui.Limits, comptime Scene: type) type {
    return struct {
        const Ui = zui.Context(.{ .limits = limits, .Text = GlyphTableText });

        fn run(io: Io, gpa: std.mem.Allocator) !StartupMeasurement {
            var text: GlyphTableText = .{};
            var scene: Scene = .{};
            if (@hasField(Scene, "sentences")) _ = scene.sentences.get();
            var times: [startup_samples]u64 = undefined;
            for (&times) |*time| {
                var counting: CountingAllocator = .{ .backing = gpa };
                var ui = try Ui.init(counting.allocator(), io, &text);
                defer ui.deinit(counting.allocator());
                const allocations_after_init = counting.allocations;

                const start = Io.Timestamp.now(io, .awake);
                ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1600, 1200 } } });
                scene.declare(&ui, 0);
                const frame = ui.endFrame();
                time.* = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
                ui.release(frame);
                if (counting.allocations != allocations_after_init) return error.FramesAllocated;
            }
            return startupMeasurement("first frame, " ++ name, &times);
        }
    };
}

const RenderThreadRates = struct {
    one_thread: f64,
    render_thread: f64,
};

const Run = union(enum) {
    frames: Measurement,
    startup: StartupMeasurement,
    render_thread: RenderThreadRates,
};

const Kind = enum {
    /// Single-threaded frames, whose times don't depend on what the
    /// machine's other cores are doing: the ones `bench-compare` compares.
    compared_frames,
    reported_frames,
    /// Runs after every other scenario, because its page faults are part
    /// of what it times, and they depend on memory no scenario touched yet.
    startup,
    render_thread,

    /// The second column of `--list-scenarios`, which `bench-compare` reads.
    fn listedAs(kind: Kind) []const u8 {
        return switch (kind) {
            .compared_frames => "compared",
            .reported_frames, .render_thread => "reported",
            .startup => "startup",
        };
    }
};

const Entry = struct {
    name: []const u8,
    kind: Kind,
    run: *const fn (Io, std.mem.Allocator, Layout) anyerror!Run,
};

fn frames(comptime kind: Kind, comptime limits: zui.Limits, comptime Text: type, comptime Scene: type) Entry {
    const warmup_frames, const timed_frames = if (kind == .compared_frames) .{ 20, 400 } else .{ 2, 20 };
    return .{ .name = Scene.name, .kind = kind, .run = struct {
        fn run(io: Io, gpa: std.mem.Allocator, layout: Layout) anyerror!Run {
            return .{ .frames = try Scenario(limits, Text, Scene).run(io, gpa, layout, warmup_frames, timed_frames) };
        }
    }.run };
}

fn startup(comptime name: []const u8, comptime timeStartup: anytype) Entry {
    return .{ .name = name, .kind = .startup, .run = struct {
        fn run(io: Io, gpa: std.mem.Allocator, _: Layout) anyerror!Run {
            return .{ .startup = try timeStartup(io, gpa) };
        }
    }.run };
}

fn timeRenderThread(io: Io, gpa: std.mem.Allocator, _: Layout) anyerror!Run {
    return .{ .render_thread = .{
        .one_thread = try framesPerSecond(io, gpa, false),
        .render_thread = try framesPerSecond(io, gpa, true),
    } };
}

const shaped_one_thread = "shaped text, one thread";
const shaped_parallel = "shaped text, parallel";

/// Every scenario, in the order the tables print them.
const entries = [_]Entry{
    frames(.compared_frames, BoxTree.limits, GlyphTableText, BoxTree),
    frames(.compared_frames, StaticBoxTree.limits, GlyphTableText, StaticBoxTree),
    frames(.compared_frames, text_limits, GlyphTableText, TextWall),
    frames(.compared_frames, text_limits, GlyphTableText, TextWallCold),
    frames(.compared_frames, SingleLineTexts.limits, GlyphTableText, SingleLineTexts),
    frames(.compared_frames, ChangingTexts.limits, GlyphTableText, ChangingTexts),
    frames(.compared_frames, DeepTree.limits, GlyphTableText, DeepTree),
    frames(.compared_frames, WideTree.limits, GlyphTableText, WideTree),
    frames(.compared_frames, DocumentsView.limits, GlyphTableText, DocumentsView),
    frames(.compared_frames, GridWithTooltip(.first).limits, GlyphTableText, GridWithTooltip(.first)),
    frames(.compared_frames, GridWithTooltip(.last).limits, GlyphTableText, GridWithTooltip(.last)),
    frames(.compared_frames, InteractiveBoxTree.limits, GlyphTableText, InteractiveBoxTree),
    frames(.compared_frames, PressedInteractiveBoxTree.limits, GlyphTableText, PressedInteractiveBoxTree),
    frames(.reported_frames, shaping_limits, ShapingText(false), ShapedTextWall(false)),
    frames(.reported_frames, shaping_limits, ShapingText(true), ShapedTextWall(true)),
    .{ .name = "render thread", .kind = .render_thread, .run = timeRenderThread },
    startup("init, default config", timeInit),
    startup("initBuffer, default config", timeInitBuffer),
    startup("first frame, documents view", FirstFrame("documents view", DocumentsView.limits, DocumentsView).run),
    startup("first frame, 1000 texts", FirstFrame("1000 texts", text_limits, TextWall).run),
};

comptime {
    for (entries, 0..) |entry, index| {
        for (entries[0..index]) |earlier| {
            if (std.mem.eql(u8, entry.name, earlier.name)) @compileError("two scenarios are named \"" ++ entry.name ++ "\"");
        }
    }
}

fn entryIndex(name: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) return index;
    }
    return null;
}

const Options = struct {
    json_path: ?[]const u8 = null,
    check_targets: bool = false,
    core: ?u32 = null,
    machine_json_path: ?[]const u8 = null,
    print_capabilities: bool = false,
    list_scenarios: bool = false,
    /// Indices into `entries`; empty runs every scenario.
    selected: std.ArrayList(usize) = .empty,
    order_seed: ?u64 = null,
    counters: bool = false,
};

/// What `--capabilities` prints, so `bench-compare` can tell which options
/// a commit's benchmark understands. A benchmark from before this option
/// fails on it with `UnknownArgument`. `bench-install` names the build
/// step that installs this executable, so it can be run without the build
/// runner. `layout-seed` reads `ZUI_BENCH_LAYOUT_SEED`; `code-layout` is
/// the `-Dbench-layout-seed` build option.
const capabilities = "core machine-json scenarios bench-install layout-seed code-layout counters";

fn parseOptions(arena: std.mem.Allocator, arguments: []const [:0]const u8) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        const has_value = index + 1 < arguments.len;
        if (std.mem.eql(u8, argument, "--json") and has_value) {
            index += 1;
            options.json_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--check-targets")) {
            options.check_targets = true;
        } else if (std.mem.eql(u8, argument, "--core") and has_value) {
            index += 1;
            options.core = std.fmt.parseInt(u32, arguments[index], 10) catch {
                std.debug.print("--core needs a core number, got \"{s}\"\n", .{arguments[index]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, argument, "--machine-json") and has_value) {
            index += 1;
            options.machine_json_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--capabilities")) {
            options.print_capabilities = true;
        } else if (std.mem.eql(u8, argument, "--list-scenarios")) {
            options.list_scenarios = true;
        } else if (std.mem.eql(u8, argument, "--scenario") and has_value) {
            index += 1;
            const entry_index = entryIndex(arguments[index]) orelse {
                std.debug.print("unknown scenario \"{s}\"; `--list-scenarios` lists them\n", .{arguments[index]});
                return error.UnknownScenario;
            };
            if (std.mem.indexOfScalar(usize, options.selected.items, entry_index) == null) try options.selected.append(arena, entry_index);
        } else if (std.mem.eql(u8, argument, "--order-seed") and has_value) {
            index += 1;
            options.order_seed = std.fmt.parseInt(u64, arguments[index], 10) catch {
                std.debug.print("--order-seed needs a whole number, got \"{s}\"\n", .{arguments[index]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, argument, "--counters")) {
            options.counters = true;
        } else if (std.mem.eql(u8, argument, "--compare")) {
            std.debug.print("--compare was removed: compare two commits with `zig build bench-compare -- <base> [<head>]`\n", .{});
            return error.UnknownArgument;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --json <path>, --check-targets, --core <n>, --machine-json <path>,\n" ++
                "--scenario <name>, --order-seed <n>, --counters, --list-scenarios or --capabilities\n", .{argument});
            return error.UnknownArgument;
        }
    }
    if (options.selected.items.len == 0) {
        for (0..entries.len) |entry_index| try options.selected.append(arena, entry_index);
    }
    return options;
}

/// The selected scenarios in the order they run: shuffled by the seed, if
/// one is given, with startup scenarios last.
fn runOrder(arena: std.mem.Allocator, selected: []const usize, order_seed: ?u64) ![]const usize {
    var order: std.ArrayList(usize) = .empty;
    for (selected) |entry_index| {
        if (entries[entry_index].kind != .startup) try order.append(arena, entry_index);
    }
    if (order_seed) |seed| {
        var random: std.Random.DefaultPrng = .init(seed);
        random.random().shuffle(usize, order.items);
    }
    for (selected) |entry_index| {
        if (entries[entry_index].kind == .startup) try order.append(arena, entry_index);
    }
    return order.items;
}

fn budgetText(buffer: []u8, fastest_ns: u64, budget_ns: ?u64, missed_any: *bool) []const u8 {
    const budget = budget_ns orelse return "";
    const met = fastest_ns <= budget;
    if (!met) missed_any.* = true;
    return std.fmt.bufPrint(buffer, "{s} {d:.0}us", .{ if (met) "ok" else "MISS", microseconds(budget) }) catch unreachable;
}

fn microseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_us;
}

fn openCounters() !counters.Group {
    return counters.Group.open() catch |err| {
        switch (err) {
            error.Unsupported => std.debug.print("--counters needs Linux; {s}\n", .{counters.alternatives}),
            error.CountersNotPermitted => std.debug.print("--counters was refused: /proc/sys/kernel/perf_event_paranoid must be 2 or lower\n", .{}),
            error.CounterUnavailable => std.debug.print("--counters: this machine does not expose its hardware counters; {s}\n", .{counters.alternatives}),
        }
        return err;
    };
}

fn printCounters(out: *Io.Writer, runs: []const ?Run) !void {
    var printed_header = false;
    for (runs) |maybe_run| {
        const measurement = if (maybe_run) |run| switch (run) {
            .frames => |frames_run| frames_run,
            else => continue,
        } else continue;
        const phases = [_]struct { []const u8, ?counters.Counts }{ .{ "declare", measurement.declare_counts }, .{ "layout", measurement.layout_counts } };
        for (phases) |phase| {
            const counts = phase[1] orelse continue;
            if (!printed_header) {
                try out.print("\n{s:<38}", .{"fewest per frame"});
                for (std.enums.values(counters.Event)) |event| try out.print(" {s:>15}", .{event.label()});
                try out.print(" {s:>6}\n", .{"IPC"});
                printed_header = true;
            }
            var label_buffer: [64]u8 = undefined;
            try out.print("{s:<38}", .{std.fmt.bufPrint(&label_buffer, "{s}, {s}", .{ measurement.name, phase[0] }) catch measurement.name});
            for (counts) |count| try out.print(" {d:>15}", .{count});
            const cycles: f64 = @floatFromInt(counts[@intFromEnum(counters.Event.cycles)]);
            const instructions: f64 = @floatFromInt(counts[@intFromEnum(counters.Event.instructions)]);
            try out.print(" {d:>6.2}\n", .{instructions / cycles});
        }
    }
}

/// One fastest time `bench-compare` compares. The layout time keeps the
/// scenario's bare name, so it still matches results from before the
/// declaration time was recorded.
const ComparedTime = struct {
    key_buffer: [96]u8,
    key_len: usize,
    nanoseconds: u64,

    fn key(self: *const ComparedTime) []const u8 {
        return self.key_buffer[0..self.key_len];
    }

    fn init(comptime key_format: []const u8, name: []const u8, nanoseconds: u64) ComparedTime {
        var time: ComparedTime = .{ .key_buffer = undefined, .key_len = undefined, .nanoseconds = nanoseconds };
        time.key_len = (std.fmt.bufPrint(&time.key_buffer, key_format, .{name}) catch unreachable).len;
        return time;
    }

    /// A counter rides in the same map as the times, its key ending in
    /// the event's label; `nanoseconds` then holds the count.
    fn initCounter(name: []const u8, phase: []const u8, event: []const u8, count: u64) ComparedTime {
        var time: ComparedTime = .{ .key_buffer = undefined, .key_len = undefined, .nanoseconds = count };
        time.key_len = (std.fmt.bufPrint(&time.key_buffer, "{s}{s}, {s}", .{ name, phase, event }) catch unreachable).len;
        return time;
    }
};

const max_compared_values = (2 + 2 * counters.event_count) * entries.len;

fn comparedTimes(runs: []const ?Run, times: *[max_compared_values]ComparedTime) []const ComparedTime {
    var count: usize = 0;
    for (runs, entries) |maybe_run, entry| {
        const run = maybe_run orelse continue;
        switch (run) {
            .frames => |measurement| if (entry.kind == .compared_frames) {
                times[count] = .init("{s}", measurement.name, measurement.layout.min_ns);
                times[count + 1] = .init("{s}, declare", measurement.name, measurement.declare.min_ns);
                count += 2;
                // A base without counters shows these as only in head.
                const phases = [_]struct { []const u8, ?counters.Counts }{ .{ "", measurement.layout_counts }, .{ ", declare", measurement.declare_counts } };
                for (phases) |phase| {
                    const counts = phase[1] orelse continue;
                    for (std.enums.values(counters.Event), counts) |event, value| {
                        times[count] = .initCounter(measurement.name, phase[0], event.label(), value);
                        count += 1;
                    }
                }
            },
            .startup => |measurement| {
                times[count] = .init("{s}", measurement.name, measurement.spread.min_ns);
                count += 1;
            },
            .render_thread => {},
        }
    }
    return times[0..count];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const options = try parseOptions(arena, try init.minimal.args.toSlice(arena));
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    if (options.print_capabilities) {
        try out.writeAll(capabilities ++ "\n");
        return out.flush();
    }
    if (options.list_scenarios) {
        for (entries) |entry| try out.print("{s}\t{s}\n", .{ entry.name, entry.kind.listedAs() });
        return out.flush();
    }
    var layout = try Layout.read(init.environ_map);
    var counter_group: ?counters.Group = if (options.counters) try openCounters() else null;
    defer if (counter_group) |*group| group.close();
    if (counter_group) |*group| layout.counter_group = group;
    if (options.core) |core| try pinAndRaisePriority(core);
    if (options.machine_json_path) |path| try writeMachineJson(io, arena, path, options.core);

    var runs: [entries.len]?Run = @splat(null);
    for (try runOrder(arena, options.selected.items, options.order_seed)) |entry_index| {
        runs[entry_index] = try layout.runShifted(entries[entry_index], io, gpa);
    }

    const missed_target = try printFrames(out, &runs);
    try printRates(out, &runs);
    try printStartup(out, &runs);
    try printCounters(out, &runs);
    try printClusterWarnings(out, &runs);
    try out.flush();

    var compared_time_buffer: [max_compared_values]ComparedTime = undefined;
    if (options.json_path) |path| try writeJson(io, path, comparedTimes(&runs, &compared_time_buffer));
    if (options.check_targets and missed_target) return error.TargetMissed;
}

/// Prints the scenario table and returns whether any budget was missed.
fn printFrames(out: *Io.Writer, runs: []const ?Run) !bool {
    var missed_target = false;
    var printed_header = false;
    for (runs) |maybe_run| {
        const measurement = if (maybe_run) |run| switch (run) {
            .frames => |frames_run| frames_run,
            else => continue,
        } else continue;
        if (!printed_header) {
            try out.print("{s:<28} {s:>8} {s:>11} {s:>11} {s:>11} {s:>11} {s:>11} {s:>11} {s:>11} {s:>8} {s:>14} {s:>14} {s:>9}\n", .{ "scenario", "elements", "declare min", "declare med", "declare p95", "layout min", "layout med", "layout p95", "frame med", "ns/elem", "declare budget", "layout budget", "measures" });
            printed_header = true;
        }
        const per_element = @as(f64, @floatFromInt(measurement.layout.min_ns)) / @as(f64, @floatFromInt(measurement.elements));
        var declare_budget_buffer: [32]u8 = undefined;
        var layout_budget_buffer: [32]u8 = undefined;
        const declare_budget = budgetText(&declare_budget_buffer, measurement.declare.min_ns, measurement.declare_target_ns, &missed_target);
        const layout_budget = budgetText(&layout_budget_buffer, measurement.layout.min_ns, measurement.layout_target_ns, &missed_target);
        try out.print("{s:<28} {d:>8} {d:>9.1}us {d:>9.1}us {d:>9.1}us {d:>9.1}us {d:>9.1}us {d:>9.1}us {d:>9.1}us {d:>8.1} {s:>14} {s:>14} {d:>9.0}\n", .{
            measurement.name,
            measurement.elements,
            microseconds(measurement.declare.min_ns),
            microseconds(measurement.declare.median_ns),
            microseconds(measurement.declare.p95_ns),
            microseconds(measurement.layout.min_ns),
            microseconds(measurement.layout.median_ns),
            microseconds(measurement.layout.p95_ns),
            microseconds(measurement.frame_median_ns),
            per_element,
            declare_budget,
            layout_budget,
            measurement.measure_calls_per_frame,
        });
    }
    if (printed_header) try out.writeAll("allocations after init: 0 in every scenario\n");
    return missed_target;
}

fn printRates(out: *Io.Writer, runs: []const ?Run) !void {
    const one_thread = runs[entryIndex(shaped_one_thread).?];
    const parallel = runs[entryIndex(shaped_parallel).?];
    if (one_thread != null and parallel != null) {
        const one_thread_ns: f64 = @floatFromInt(one_thread.?.frames.layout.median_ns);
        const parallel_ns: f64 = @floatFromInt(parallel.?.frames.layout.median_ns);
        try out.print("\nparallel measurement: {d:.2}x as fast as one thread\n", .{one_thread_ns / parallel_ns});
    }
    for (runs) |maybe_run| {
        const rates = if (maybe_run) |run| switch (run) {
            .render_thread => |render_thread_rates| render_thread_rates,
            else => continue,
        } else continue;
        try out.print("render thread: {d:.0} frames/s against {d:.0} on one thread ({d:.2}x)\n", .{ rates.render_thread, rates.one_thread, rates.render_thread / rates.one_thread });
    }
}

fn printStartup(out: *Io.Writer, runs: []const ?Run) !void {
    var printed_header = false;
    for (runs) |maybe_run| {
        const measurement = if (maybe_run) |run| switch (run) {
            .startup => |startup_run| startup_run,
            else => continue,
        } else continue;
        if (!printed_header) {
            try out.print("\n{s:<28} {s:>11} {s:>11} {s:>11}\n", .{ "startup", "min", "median", "p95" });
            printed_header = true;
        }
        try out.print("{s:<28} {d:>9.1}us {d:>9.1}us {d:>9.1}us\n", .{
            measurement.name,
            microseconds(measurement.spread.min_ns),
            microseconds(measurement.spread.median_ns),
            microseconds(measurement.spread.p95_ns),
        });
    }
    if (printed_header) try out.print("init allocates {d:.2} MiB at the default config\n", .{@as(f64, @floatFromInt(DefaultUi.required_bytes)) / (1024 * 1024)});
}

/// A scenario whose frames fell into two clusters measured two things, and
/// its fastest frame says only which one was faster.
fn printClusterWarnings(out: *Io.Writer, runs: []const ?Run) !void {
    for (runs) |maybe_run| {
        switch (maybe_run orelse continue) {
            .frames => |measurement| {
                try printClusterWarning(out, measurement.name, ", declare", measurement.declare);
                try printClusterWarning(out, measurement.name, ", layout", measurement.layout);
            },
            .startup => |measurement| try printClusterWarning(out, measurement.name, "", measurement.spread),
            .render_thread => {},
        }
    }
}

fn printClusterWarning(out: *Io.Writer, name: []const u8, phase: []const u8, spread: Spread) !void {
    const clusters = spread.clusters orelse return;
    try out.print("warning: {s}{s} times fell in two clusters, around {d:.1}us and {d:.1}us ({d:.0}% in the slower)\n", .{
        name,
        phase,
        microseconds(clusters.lower_median),
        microseconds(clusters.upper_median),
        clusters.upper_share * 100,
    });
}

/// Pins only this thread: on Windows the threads the parallel scenarios
/// start still run on every core, while on Linux they inherit the pin.
fn pinAndRaisePriority(core: u32) !void {
    machine.pinToCore(core, .thread) catch |err| {
        std.debug.print("could not pin to core {d}: {t}\n", .{ core, err });
        return err;
    };
    machine.raisePriority() catch |err| std.debug.print("pinned to core {d}, but could not raise the priority: {t}\n", .{ core, err });
}

fn writeMachineJson(io: Io, arena: std.mem.Allocator, path: []const u8, core: ?u32) !void {
    const state = try machine.read(io, arena, core);
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try state.writeJson(&file_writer.interface);
    try file_writer.interface.flush();
}

fn writeJson(io: Io, path: []const u8, times: []const ComparedTime) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll("{\n");
    for (times, 0..) |*time, index| {
        try writer.print("  \"{s}\": {d}{s}\n", .{ time.key(), time.nanoseconds, if (index + 1 < times.len) "," else "" });
    }
    try writer.writeAll("}\n");
    try writer.flush();
}

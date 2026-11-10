//! ```sh
//! zig build bench                                  # print the tables
//! zig build bench -- --check-targets               # fail if a SPEC.md §20.2 budget is missed
//! zig build bench -- --json results.json           # save each scenario's fastest declaration and layout
//! zig build bench -- --core 3 --machine-json m.json # pin to core 3, raise priority, record the machine
//! ```
//!
//! Two commits are compared with `zig build bench-compare`, never by two
//! runs of this.

const std = @import("std");
const zui = @import("zui");
const Io = std.Io;

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
    layout_target_ns: ?u64 = null,
    declare_target_ns: ?u64 = null,
    measure_calls_per_frame: f64,
};

const max_timed_frames = 400;

fn Scenario(comptime limits: zui.Limits, comptime Text: type, comptime Scene: type) type {
    return struct {
        const Ui = zui.Context(.{ .limits = limits, .Text = Text });

        /// Times `frame_count` frames after `warmup_frames`, in a fresh
        /// Context whose allocator counts every call after `init`.
        fn run(io: Io, gpa: std.mem.Allocator, warmup_frames: usize, frame_count: usize) !Measurement {
            var text: Text = .{};
            var counting: CountingAllocator = .{ .backing = gpa };
            var ui = try Ui.init(counting.allocator(), io, &text);
            defer ui.deinit(counting.allocator());
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
            const calls_before = ui.measureCalls();
            for (0..frame_count) |index| {
                const frame_start = Io.Timestamp.now(io, .awake);
                ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1600, 1200 } }, .events = eventsOf(&scene, warmup_frames + index) });
                scene.declare(&ui, warmup_frames + index);
                const layout_start = Io.Timestamp.now(io, .awake);
                const frame = ui.endFrame();
                const end = Io.Timestamp.now(io, .awake);
                element_count = frame.elementCount();
                ui.release(frame);
                declare_times[index] = @intCast(frame_start.durationTo(layout_start).nanoseconds);
                layout_times[index] = @intCast(layout_start.durationTo(end).nanoseconds);
                frame_times[index] = @intCast(frame_start.durationTo(end).nanoseconds);
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
fn timeInitBuffer(io: Io) !StartupMeasurement {
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

const Options = struct {
    json_path: ?[]const u8 = null,
    check_targets: bool = false,
    core: ?u32 = null,
    machine_json_path: ?[]const u8 = null,
    print_capabilities: bool = false,
};

/// What `--capabilities` prints, so `bench-compare` can tell which options
/// a commit's benchmark understands. A benchmark from before this option
/// fails on it with `UnknownArgument`.
const capabilities = "core machine-json";

fn parseOptions(arguments: []const [:0]const u8) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--json") and index + 1 < arguments.len) {
            index += 1;
            options.json_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--check-targets")) {
            options.check_targets = true;
        } else if (std.mem.eql(u8, argument, "--core") and index + 1 < arguments.len) {
            index += 1;
            options.core = std.fmt.parseInt(u32, arguments[index], 10) catch {
                std.debug.print("--core needs a core number, got \"{s}\"\n", .{arguments[index]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, argument, "--machine-json") and index + 1 < arguments.len) {
            index += 1;
            options.machine_json_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--capabilities")) {
            options.print_capabilities = true;
        } else if (std.mem.eql(u8, argument, "--compare")) {
            std.debug.print("--compare was removed: compare two commits with `zig build bench-compare -- <base> [<head>]`\n", .{});
            return error.UnknownArgument;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --json <path>, --check-targets, --core <n>, --machine-json <path> or --capabilities\n", .{argument});
            return error.UnknownArgument;
        }
    }
    return options;
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

/// The scenarios `bench-compare` compares: the single-threaded ones,
/// whose times don't depend on what the machine's other cores are doing.
const compared_count = 13;

/// One fastest time `bench-compare` compares. The layout time keeps the
/// scenario's bare name, so it still matches results from before the
/// declaration time was recorded.
const ComparedTime = struct {
    key_buffer: [64]u8,
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
};

fn comparedTimes(measurements: []const Measurement, startup_measurements: []const StartupMeasurement, times: []ComparedTime) []const ComparedTime {
    var count: usize = 0;
    for (measurements) |measurement| {
        times[count] = .init("{s}", measurement.name, measurement.layout.min_ns);
        times[count + 1] = .init("{s}, declare", measurement.name, measurement.declare.min_ns);
        count += 2;
    }
    for (startup_measurements) |measurement| {
        times[count] = .init("{s}", measurement.name, measurement.spread.min_ns);
        count += 1;
    }
    return times[0..count];
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const options = try parseOptions(try init.minimal.args.toSlice(arena));
    if (options.print_capabilities) {
        var capabilities_writer = Io.File.stdout().writer(io, &.{});
        return capabilities_writer.interface.writeAll(capabilities ++ "\n");
    }
    if (options.core) |core| try pinAndRaisePriority(core);
    if (options.machine_json_path) |path| try writeMachineJson(io, arena, path, options.core);

    const measurements = [_]Measurement{
        try Scenario(BoxTree.limits, GlyphTableText, BoxTree).run(io, gpa, 20, 400),
        try Scenario(StaticBoxTree.limits, GlyphTableText, StaticBoxTree).run(io, gpa, 20, 400),
        try Scenario(text_limits, GlyphTableText, TextWall).run(io, gpa, 20, 400),
        try Scenario(text_limits, GlyphTableText, TextWallCold).run(io, gpa, 20, 400),
        try Scenario(SingleLineTexts.limits, GlyphTableText, SingleLineTexts).run(io, gpa, 20, 400),
        try Scenario(ChangingTexts.limits, GlyphTableText, ChangingTexts).run(io, gpa, 20, 400),
        try Scenario(DeepTree.limits, GlyphTableText, DeepTree).run(io, gpa, 20, 400),
        try Scenario(WideTree.limits, GlyphTableText, WideTree).run(io, gpa, 20, 400),
        try Scenario(DocumentsView.limits, GlyphTableText, DocumentsView).run(io, gpa, 20, 400),
        try Scenario(GridWithTooltip(.first).limits, GlyphTableText, GridWithTooltip(.first)).run(io, gpa, 20, 400),
        try Scenario(GridWithTooltip(.last).limits, GlyphTableText, GridWithTooltip(.last)).run(io, gpa, 20, 400),
        try Scenario(InteractiveBoxTree.limits, GlyphTableText, InteractiveBoxTree).run(io, gpa, 20, 400),
        try Scenario(PressedInteractiveBoxTree.limits, GlyphTableText, PressedInteractiveBoxTree).run(io, gpa, 20, 400),
        try Scenario(shaping_limits, ShapingText(false), ShapedTextWall(false)).run(io, gpa, 2, 20),
        try Scenario(shaping_limits, ShapingText(true), ShapedTextWall(true)).run(io, gpa, 2, 20),
    };
    const startup_measurements = [_]StartupMeasurement{
        try timeInit(io, gpa),
        try timeInitBuffer(io),
        try FirstFrame("documents view", DocumentsView.limits, DocumentsView).run(io, gpa),
        try FirstFrame("1000 texts", text_limits, TextWall).run(io, gpa),
    };
    const one_thread_rate = try framesPerSecond(io, gpa, false);
    const render_thread_rate = try framesPerSecond(io, gpa, true);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    const missed_target = try printMeasurements(out, &measurements);
    if (measurements.len > compared_count) {
        const shaped_one_thread: f64 = @floatFromInt(measurements[compared_count].layout.median_ns);
        const shaped_parallel: f64 = @floatFromInt(measurements[compared_count + 1].layout.median_ns);
        try out.print("\nparallel measurement: {d:.2}x as fast as one thread\n", .{shaped_one_thread / shaped_parallel});
    }
    try out.print("render thread: {d:.0} frames/s against {d:.0} on one thread ({d:.2}x)\n", .{ render_thread_rate, one_thread_rate, render_thread_rate / one_thread_rate });
    try out.writeAll("allocations after init: 0 in every scenario\n");
    try printStartupMeasurements(out, &startup_measurements);
    try printClusterWarnings(out, &measurements, &startup_measurements);
    try out.flush();

    var compared_time_buffer: [2 * compared_count + startup_measurements.len]ComparedTime = undefined;
    const compared_times = comparedTimes(measurements[0..compared_count], &startup_measurements, &compared_time_buffer);
    if (options.json_path) |path| try writeJson(io, path, compared_times);
    if (options.check_targets and missed_target) return error.TargetMissed;
}

/// Prints the scenario table and returns whether any budget was missed.
fn printMeasurements(out: *Io.Writer, measurements: []const Measurement) !bool {
    try out.print("{s:<28} {s:>8} {s:>11} {s:>11} {s:>11} {s:>11} {s:>11} {s:>11} {s:>11} {s:>8} {s:>14} {s:>14} {s:>9}\n", .{ "scenario", "elements", "declare min", "declare med", "declare p95", "layout min", "layout med", "layout p95", "frame med", "ns/elem", "declare budget", "layout budget", "measures" });
    var missed_target = false;
    for (measurements) |measurement| {
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
    return missed_target;
}

fn printStartupMeasurements(out: *Io.Writer, startup_measurements: []const StartupMeasurement) !void {
    try out.print("\n{s:<28} {s:>11} {s:>11} {s:>11}\n", .{ "startup", "min", "median", "p95" });
    for (startup_measurements) |measurement| {
        try out.print("{s:<28} {d:>9.1}us {d:>9.1}us {d:>9.1}us\n", .{
            measurement.name,
            microseconds(measurement.spread.min_ns),
            microseconds(measurement.spread.median_ns),
            microseconds(measurement.spread.p95_ns),
        });
    }
    try out.print("init allocates {d:.2} MiB at the default config\n", .{@as(f64, @floatFromInt(DefaultUi.required_bytes)) / (1024 * 1024)});
}

/// A scenario whose frames fell into two clusters measured two things, and
/// its fastest frame says only which one was faster.
fn printClusterWarnings(out: *Io.Writer, measurements: []const Measurement, startup_measurements: []const StartupMeasurement) !void {
    for (measurements) |measurement| {
        try printClusterWarning(out, measurement.name, "declare", measurement.declare);
        try printClusterWarning(out, measurement.name, "layout", measurement.layout);
    }
    for (startup_measurements) |measurement| try printClusterWarning(out, measurement.name, "", measurement.spread);
}

fn printClusterWarning(out: *Io.Writer, name: []const u8, phase: []const u8, spread: Spread) !void {
    const clusters = spread.clusters orelse return;
    try out.print("warning: {s}{s}{s} times fell in two clusters, around {d:.1}us and {d:.1}us ({d:.0}% in the slower)\n", .{
        name,
        if (phase.len == 0) "" else ", ",
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

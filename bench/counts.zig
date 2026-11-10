//! ```sh
//! zig build counts                             # each scenario's instructions per frame, under Callgrind
//! zig build counts -- --json counts.json       # also save them
//! zig build counts -- --compare parent.json    # fail on more than 2% growth over a saved run
//! ```
//!
//! Needs x86_64 Linux with Valgrind. The executable is always built for one
//! CPU model, so the counts are the same on every machine that runs it.
//! Callgrind also simulates caches of a fixed geometry and a branch
//! predictor; their misses are printed and saved beside the instructions,
//! but only the instructions can fail `--compare`.

const std = @import("std");
const zui = @import("zui");
const callgrind = std.valgrind.callgrind;
const Io = std.Io;
const scenes = @import("scenes.zig");

const warmup_frames = 4;
const counted_frames = 10;
const growth_tolerance = 1.02;

const Scenarios = .{ scenes.BoxTree, scenes.StaticBoxTree, scenes.TextWall, scenes.TextWallCold, scenes.SingleLineTexts, scenes.ChangingTexts, scenes.DeepTree, scenes.WideTree, scenes.DocumentsView, scenes.GridWithTooltip(.first), scenes.GridWithTooltip(.last), scenes.InteractiveBoxTree, scenes.PressedInteractiveBoxTree, scenes.DeepTreeWithIdleSources, scenes.DeepTreeWithIdleAsyncSources };

const Phase = enum {
    /// `beginFrame` and the scene's declaration.
    declare,
    /// Layout and emission.
    endFrame,
};

/// Runs one scenario in a fresh `Context`, with Callgrind collecting only
/// while `phase` runs in the counted frames.
fn runCounted(comptime Scene: type, io: Io, gpa: std.mem.Allocator, phase: Phase) !void {
    const Ui = zui.Context(.{ .limits = Scene.limits, .Text = scenes.GlyphTableText, .Sources = if (@hasDecl(Scene, "Sources")) Scene.Sources else void });
    var text: scenes.GlyphTableText = .{};
    var ui = try Ui.init(gpa, io, &text);
    defer ui.deinit(gpa);

    var scene: Scene = .{};
    var sources: Ui.Sources = if (Ui.has_sources) .{} else {};
    if (@hasField(Scene, "sentences")) _ = scene.sentences.get();
    for (0..warmup_frames + counted_frames) |frame_index| {
        const counted = frame_index >= warmup_frames;
        const counting_declare = counted and phase == .declare;
        const counting_end_frame = counted and phase == .endFrame;

        if (counting_declare) callgrind.toggleCollect();
        const record: Ui.FrameRecord = .{ .params = .{ .now = .zero, .viewport = .{ 1600, 1200 } }, .events = scenes.eventsOf(&scene, frame_index) };
        if (Ui.has_sources) ui.beginFrame(&record, &sources) else ui.beginFrame(&record);
        scene.declare(&ui, frame_index);
        if (counting_declare) callgrind.toggleCollect();

        if (counting_end_frame) callgrind.toggleCollect();
        const frame = ui.endFrame();
        if (counting_end_frame) callgrind.toggleCollect();
        ui.release(frame);
    }
}

fn runScenario(name: []const u8, phase: Phase, io: Io, gpa: std.mem.Allocator) !void {
    inline for (Scenarios) |Scene| {
        if (std.mem.eql(u8, name, Scene.name)) return runCounted(Scene, io, gpa, phase);
    }
    std.debug.print("unknown scenario \"{s}\"\n", .{name});
    return error.UnknownScenario;
}

const Count = struct {
    key: []const u8,
    per_frame: u64,
    /// Instructions are gated on; the simulated misses come from a model
    /// too simple to price them, so they only show direction.
    gated: bool,
};

/// Each counted event, per frame.
const Events = struct {
    instructions: u64,
    i1_misses: u64,
    d1_misses: u64,
    last_level_misses: u64,
    branch_misses: u64,
};

/// A fixed cache geometry, since without one Valgrind simulates the host's
/// caches and the miss counts would differ from runner to runner.
const cache_geometry = [_][]const u8{ "--I1=32768,8,64", "--D1=32768,8,64", "--LL=8388608,16,64" };

/// Runs this executable under Callgrind for one scenario and phase, and
/// reads what Callgrind collected from its summary.
fn countUnderCallgrind(io: Io, arena: std.mem.Allocator, self_path: []const u8, name: []const u8, phase: Phase) !Events {
    // The environment and the executable's path are copied onto the initial
    // stack, so their lengths move every stack address and with them the
    // simulated D1 misses. An empty environment and a path relative to the
    // executable's own directory keep the stack where it is on every runner.
    const self_name = try std.fmt.allocPrint(arena, "./{s}", .{std.fs.path.basename(self_path)});
    var empty_environment: std.process.Environ.Map = .init(arena);
    const argv: []const []const u8 = &(.{
        "valgrind",        "--tool=callgrind", "--collect-atstart=no", "--callgrind-out-file=/dev/null",
        "--cache-sim=yes", "--branch-sim=yes",
    } ++ cache_geometry ++ .{ self_name, "--run", name, @tagName(phase) });
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .cwd = .{ .path = std.fs.path.dirname(self_path) orelse "." },
        .environ_map = &empty_environment,
    }) catch |err| {
        if (err == error.FileNotFound) std.debug.print("valgrind was not found; counts need x86_64 Linux with Valgrind installed\n", .{});
        return err;
    };
    if (!(result.term == .exited and result.term.exited == 0)) {
        std.debug.print("counting \"{s}\" ({s}) failed with {any}:\n{s}{s}", .{ name, @tagName(phase), result.term, result.stdout, result.stderr });
        return error.CountFailed;
    }
    const names = summaryLine(result.stderr, "Events    : ") orelse {
        std.debug.print("Callgrind printed no event names:\n{s}", .{result.stderr});
        return error.CountMissing;
    };
    const values = summaryLine(result.stderr, "Collected : ") orelse {
        std.debug.print("Callgrind printed no count:\n{s}", .{result.stderr});
        return error.CountMissing;
    };
    var collected: std.StringHashMapUnmanaged(u64) = .empty;
    var name_tokens = std.mem.tokenizeScalar(u8, names, ' ');
    var value_tokens = std.mem.tokenizeScalar(u8, values, ' ');
    // Callgrind leaves trailing zeros off the collected values.
    while (name_tokens.next()) |event_name| {
        const value = if (value_tokens.next()) |token| try std.fmt.parseInt(u64, token, 10) else 0;
        try collected.put(arena, event_name, value);
    }
    const event = struct {
        fn sum(events: *const std.StringHashMapUnmanaged(u64), event_names: []const []const u8) !u64 {
            var total: u64 = 0;
            for (event_names) |event_name| total += events.get(event_name) orelse return error.CountMissing;
            return total / counted_frames;
        }
    };
    return .{
        .instructions = try event.sum(&collected, &.{"Ir"}),
        .i1_misses = try event.sum(&collected, &.{"I1mr"}),
        .d1_misses = try event.sum(&collected, &.{ "D1mr", "D1mw" }),
        .last_level_misses = try event.sum(&collected, &.{ "ILmr", "DLmr", "DLmw" }),
        .branch_misses = try event.sum(&collected, &.{ "Bcm", "Bim" }),
    };
}

/// The rest of the summary line that starts with `marker`, after
/// Valgrind's `==pid==` prefix.
fn summaryLine(stderr: []const u8, marker: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, stderr, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, stderr, start, '\n') orelse stderr.len;
    return std.mem.trim(u8, stderr[start..end], " \r");
}

const Options = struct {
    run_scenario: ?struct { name: []const u8, phase: Phase } = null,
    json_path: ?[]const u8 = null,
    compare_path: ?[]const u8 = null,
};

fn parseOptions(arguments: []const [:0]const u8) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--run") and index + 2 < arguments.len) {
            const phase = std.meta.stringToEnum(Phase, arguments[index + 2]) orelse return error.UnknownPhase;
            options.run_scenario = .{ .name = arguments[index + 1], .phase = phase };
            index += 2;
        } else if (std.mem.eql(u8, argument, "--json") and index + 1 < arguments.len) {
            index += 1;
            options.json_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--compare") and index + 1 < arguments.len) {
            index += 1;
            options.compare_path = arguments[index];
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --json <path> or --compare <path>\n", .{argument});
            return error.UnknownArgument;
        }
    }
    return options;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    const options = try parseOptions(arguments);
    if (options.run_scenario) |run| return runScenario(run.name, run.phase, io, init.gpa);

    var counts: std.ArrayList(Count) = .empty;
    inline for (Scenarios) |Scene| {
        for (std.enums.values(Phase)) |phase| {
            const key = try std.fmt.allocPrint(arena, "{s}, {s}", .{ Scene.name, @tagName(phase) });
            const events = try countUnderCallgrind(io, arena, arguments[0], Scene.name, phase);
            // The instruction key keeps its old name, so a parent from
            // before the simulated misses still gates on it.
            try counts.append(arena, .{ .key = key, .per_frame = events.instructions, .gated = true });
            const misses = [_]struct { []const u8, u64 }{
                .{ "I1 misses", events.i1_misses },
                .{ "D1 misses", events.d1_misses },
                .{ "LL misses", events.last_level_misses },
                .{ "branch misses", events.branch_misses },
            };
            for (misses) |miss| {
                try counts.append(arena, .{ .key = try std.fmt.allocPrint(arena, "{s}, {s}", .{ key, miss[0] }), .per_frame = miss[1], .gated = false });
            }
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("{s:<62} {s:>14}\n", .{ "scenario, phase, event", "per frame" });
    for (counts.items) |count| try out.print("{s:<62} {d:>14}\n", .{ count.key, count.per_frame });
    try out.flush();

    if (options.json_path) |path| try writeJson(io, path, counts.items);
    const grew = if (options.compare_path) |path| try compare(io, arena, out, path, counts.items) else false;
    try out.flush();
    if (grew) return error.InstructionsGrew;
}

fn writeJson(io: Io, path: []const u8, counts: []const Count) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll("{\n");
    for (counts, 0..) |count, index| {
        try writer.print("  \"{s}\": {d}{s}\n", .{ count.key, count.per_frame, if (index + 1 < counts.len) "," else "" });
    }
    try writer.writeAll("}\n");
    try writer.flush();
}

/// Prints each count's change against the baseline and returns whether any
/// instruction count grew by more than `growth_tolerance`. A count missing
/// from the baseline is new and only printed.
fn compare(io: Io, arena: std.mem.Allocator, out: *Io.Writer, path: []const u8, counts: []const Count) !bool {
    const contents = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024));
    const baseline = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap(u64), arena, contents, .{});
    try out.writeAll("\nagainst the baseline (only instructions can fail the check):\n");
    var grew = false;
    for (counts) |count| {
        const before = baseline.map.get(count.key) orelse {
            try out.print("  {s:<62} {d:>14}  new\n", .{ count.key, count.per_frame });
            continue;
        };
        const ratio = if (before == 0)
            (if (count.per_frame == 0) @as(f64, 1) else std.math.inf(f64))
        else
            @as(f64, @floatFromInt(count.per_frame)) / @as(f64, @floatFromInt(before));
        const too_much = count.gated and ratio > growth_tolerance;
        if (too_much) grew = true;
        try out.print("  {s:<62} {d:>14} -> {d:>14}  {s}{d:.2}%{s}\n", .{
            count.key,
            before,
            count.per_frame,
            if (ratio >= 1) "+" else "",
            (ratio - 1) * 100,
            if (too_much) "  GREW" else "",
        });
    }
    return grew;
}

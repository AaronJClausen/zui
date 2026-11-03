//! ```sh
//! zig build bench-compare -- main               # the working tree against main
//! zig build bench-compare -- 946405e~1 946405e  # two commits
//! zig build bench-compare -- HEAD HEAD          # a commit against itself: the noise floor
//! zig build bench-compare -- main --rounds 20
//! ```

const std = @import("std");
const Io = std.Io;

const default_rounds = 10;

const Options = struct {
    zig_exe: []const u8,
    repository: []const u8,
    base_ref: []const u8,
    head_ref: ?[]const u8,
    rounds: usize,
};

fn parseOptions(arguments: []const [:0]const u8) !Options {
    var zig_exe: ?[]const u8 = null;
    var repository: ?[]const u8 = null;
    var refs: [2][]const u8 = undefined;
    var ref_count: usize = 0;
    var rounds: usize = default_rounds;
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        const has_value = index + 1 < arguments.len;
        if (std.mem.eql(u8, argument, "--zig") and has_value) {
            index += 1;
            zig_exe = arguments[index];
        } else if (std.mem.eql(u8, argument, "--repository") and has_value) {
            index += 1;
            repository = arguments[index];
        } else if (std.mem.eql(u8, argument, "--rounds") and has_value) {
            index += 1;
            rounds = std.fmt.parseInt(usize, arguments[index], 10) catch 0;
            if (rounds < 2) {
                std.debug.print("--rounds needs a whole number of at least 2, got \"{s}\"\n", .{arguments[index]});
                return error.InvalidArgument;
            }
        } else if (!std.mem.startsWith(u8, argument, "--") and ref_count < refs.len) {
            refs[ref_count] = argument;
            ref_count += 1;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected <base> [<head>] [--rounds <count>]\n", .{argument});
            return error.InvalidArgument;
        }
    }
    if (ref_count == 0) {
        std.debug.print("usage: zig build bench-compare -- <base> [<head>] [--rounds <count>]\n" ++
            "<head> defaults to the working tree, uncommitted changes included\n", .{});
        return error.InvalidArgument;
    }
    return .{
        .zig_exe = zig_exe orelse return error.MissingZigExe,
        .repository = repository orelse return error.MissingRepository,
        .base_ref = refs[0],
        .head_ref = if (ref_count == 2) refs[1] else null,
        .rounds = rounds,
    };
}

/// One build of the benchmarks: a commit checked out in its own worktree,
/// or the working tree itself.
const Side = struct {
    label: []const u8,
    /// Abbreviated; null for the working tree.
    commit: ?[]const u8,
    directory: []const u8,
    results_path: []const u8,
    /// One entry per run, from the benchmark's `--json`: the fastest frame
    /// of each scenario's declaration and `endFrame`, in nanoseconds.
    runs: std.ArrayList(std.json.ArrayHashMap(u64)) = .empty,
};

const Tool = struct {
    io: Io,
    arena: std.mem.Allocator,
    options: Options,
    scratch_directory: []const u8,

    fn runCommand(tool: *const Tool, argv: []const []const u8, cwd: []const u8) ![]const u8 {
        const result = try std.process.run(tool.arena, tool.io, .{ .argv = argv, .cwd = .{ .path = cwd } });
        if (result.term == .exited and result.term.exited == 0) return result.stdout;
        std.debug.print("in {s}, this failed with {any}:\n ", .{ cwd, result.term });
        for (argv) |argument| std.debug.print(" {s}", .{argument});
        std.debug.print("\n{s}{s}", .{ result.stdout, result.stderr });
        return error.CommandFailed;
    }

    fn git(tool: *const Tool, arguments: []const []const u8) ![]const u8 {
        const argv = try std.mem.concat(tool.arena, []const u8, &.{ &.{"git"}, arguments });
        const output = try tool.runCommand(argv, tool.options.repository);
        return std.mem.trimEnd(u8, output, "\r\n");
    }

    /// `role` keeps the two worktrees apart when both sides name one commit.
    fn checkOut(tool: *const Tool, ref: []const u8, role: []const u8) !Side {
        const commit = tool.git(&.{ "rev-parse", "--verify", "--quiet", "--short", try std.fmt.allocPrint(tool.arena, "{s}^{{commit}}", .{ref}) }) catch {
            std.debug.print("\"{s}\" does not name a commit\n", .{ref});
            return error.UnknownRef;
        };
        const directory = try std.fs.path.join(tool.arena, &.{ tool.scratch_directory, try std.fmt.allocPrint(tool.arena, "{s}-{s}", .{ role, commit }) });
        // A worktree left by an interrupted comparison is reused rather than
        // failing `worktree add`.
        if (Io.Dir.cwd().access(tool.io, directory, .{})) |_| {} else |_| {
            _ = try tool.git(&.{ "worktree", "add", "--detach", "--quiet", directory, commit });
        }
        return .{
            .label = ref,
            .commit = commit,
            .directory = directory,
            .results_path = try tool.resultsPath(role),
        };
    }

    fn workingTree(tool: *const Tool) !Side {
        return .{
            .label = "working tree",
            .commit = null,
            .directory = tool.options.repository,
            .results_path = try tool.resultsPath("head"),
        };
    }

    fn resultsPath(tool: *const Tool, role: []const u8) ![]const u8 {
        return std.fs.path.join(tool.arena, &.{ tool.scratch_directory, try std.fmt.allocPrint(tool.arena, "{s}.json", .{role}) });
    }

    fn remove(tool: *const Tool, side: *const Side) void {
        if (side.commit == null) return;
        _ = tool.git(&.{ "worktree", "remove", "--force", side.directory }) catch
            std.debug.print("could not remove the worktree at {s}; `git worktree remove --force` it by hand\n", .{side.directory});
    }

    /// Runs that side's own `zig build bench`, so each commit is measured by
    /// the scenarios it shipped with.
    fn runBenchmarks(tool: *const Tool, side: *Side) !void {
        _ = try tool.runCommand(&.{ tool.options.zig_exe, "build", "bench", "--", "--json", side.results_path }, side.directory);
        const contents = try Io.Dir.cwd().readFileAlloc(tool.io, side.results_path, tool.arena, .limited(64 * 1024));
        try side.runs.append(tool.arena, try std.json.parseFromSliceLeaky(std.json.ArrayHashMap(u64), tool.arena, contents, .{}));
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const options = try parseOptions(try init.minimal.args.toSlice(arena));

    const tool: Tool = .{
        .io = io,
        .arena = arena,
        .options = options,
        .scratch_directory = try std.fs.path.join(arena, &.{ options.repository, ".zig-cache", "bench-compare" }),
    };
    try Io.Dir.cwd().createDirPath(io, tool.scratch_directory);

    var base = try tool.checkOut(options.base_ref, "base");
    defer tool.remove(&base);
    var head = if (options.head_ref) |ref| try tool.checkOut(ref, "head") else try tool.workingTree();
    defer tool.remove(&head);

    // The first run of each side builds it and warms the machine; its times
    // are thrown away.
    std.debug.print("building {s} and {s}\n", .{ base.label, head.label });
    try tool.runBenchmarks(&base);
    try tool.runBenchmarks(&head);
    base.runs.clearRetainingCapacity();
    head.runs.clearRetainingCapacity();

    // Alternating which side goes first cancels a drift in the machine's
    // speed over the comparison, such as a CPU warming up.
    for (0..options.rounds) |round| {
        std.debug.print("round {d}/{d}\n", .{ round + 1, options.rounds });
        const first, const second = if (round % 2 == 0) .{ &base, &head } else .{ &head, &base };
        try tool.runBenchmarks(first);
        try tool.runBenchmarks(second);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    try report(arena, &stdout_writer.interface, &base, &head);
    try stdout_writer.interface.flush();
}

const Quartiles = struct {
    lower: f64,
    median: f64,
    upper: f64,

    fn of(sorted: []const f64) Quartiles {
        const middle = sorted.len / 2;
        return .{
            .lower = sorted[sorted.len / 4],
            .median = if (sorted.len % 2 == 1) sorted[middle] else (sorted[middle - 1] + sorted[middle]) / 2,
            .upper = sorted[sorted.len - 1 - sorted.len / 4],
        };
    }
};

fn sortedTimes(arena: std.mem.Allocator, side: *const Side, key: []const u8) !?[]f64 {
    const times = try arena.alloc(f64, side.runs.items.len);
    for (side.runs.items, times) |run, *time| {
        time.* = @floatFromInt(run.map.get(key) orelse return null);
    }
    std.mem.sortUnstable(f64, times, {}, std.sort.asc(f64));
    return times;
}

/// Changes whose whole middle half is within this of no change are not
/// called faster or slower: comparing a commit against itself on the
/// reference machine gives middle halves within 2% that all contain zero.
const verdict_threshold = 0.02;

fn report(arena: std.mem.Allocator, out: *Io.Writer, base: *const Side, head: *const Side) !void {
    const rounds = base.runs.items.len;
    try printSide(out, "base", base);
    try printSide(out, "head", head);
    try out.print("{d} rounds, alternating which goes first. Each time is a run's fastest frame;\n" ++
        "the change is the median of the rounds' head/base ratios, and the middle half\n" ++
        "is where half of those ratios fell.\n\n", .{rounds});
    try out.print("{s:<37} {s:>10} {s:>10} {s:>8}   middle half\n", .{ "", "base", "head", "change" });

    const ratios = try arena.alloc(f64, rounds);
    for (head.runs.items[0].map.keys()) |key| {
        const base_times = try sortedTimes(arena, base, key) orelse {
            try out.print("{s:<37} only in head\n", .{key});
            continue;
        };
        const head_times = (try sortedTimes(arena, head, key)).?;
        for (ratios, base.runs.items, head.runs.items) |*ratio, base_run, head_run| {
            ratio.* = @as(f64, @floatFromInt(head_run.map.get(key).?)) / @as(f64, @floatFromInt(base_run.map.get(key).?));
        }
        std.mem.sortUnstable(f64, ratios, {}, std.sort.asc(f64));
        const change = Quartiles.of(ratios);
        var median_buffer: [16]u8 = undefined;
        var lower_buffer: [16]u8 = undefined;
        var upper_buffer: [16]u8 = undefined;
        var spread_buffer: [40]u8 = undefined;
        const spread = try std.fmt.bufPrint(&spread_buffer, "{s:>7} to {s}", .{ percentChange(&lower_buffer, change.lower), percentChange(&upper_buffer, change.upper) });
        try out.print("{s:<37} {d:>8.1}us {d:>8.1}us {s:>8}   ", .{
            key,
            Quartiles.of(base_times).median / std.time.ns_per_us,
            Quartiles.of(head_times).median / std.time.ns_per_us,
            percentChange(&median_buffer, change.median),
        });
        if (change.lower > 1 + verdict_threshold) {
            try out.print("{s:<19} slower\n", .{spread});
        } else if (change.upper < 1 - verdict_threshold) {
            try out.print("{s:<19} faster\n", .{spread});
        } else {
            try out.print("{s}\n", .{spread});
        }
    }
    for (base.runs.items[0].map.keys()) |key| {
        if (!head.runs.items[0].map.contains(key)) try out.print("{s:<37} only in base\n", .{key});
    }
}

fn printSide(out: *Io.Writer, role: []const u8, side: *const Side) !void {
    if (side.commit) |commit| {
        try out.print("{s}  {s} ({s})\n", .{ role, side.label, commit });
    } else {
        try out.print("{s}  {s}\n", .{ role, side.label });
    }
}

fn percentChange(buffer: *[16]u8, ratio: f64) []const u8 {
    const rounded_change = @round((ratio - 1) * 1000) / 10;
    // Without `@abs`, a small speedup prints as -0.0%.
    const change = if (rounded_change == 0) @abs(rounded_change) else rounded_change;
    return std.fmt.bufPrint(buffer, "{s}{d:.1}%", .{ if (change >= 0) "+" else "", change }) catch unreachable;
}

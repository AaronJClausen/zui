//! ```sh
//! zig build bench-compare -- main               # the working tree against main
//! zig build bench-compare -- 946405e~1 946405e  # two commits
//! zig build bench-compare -- --calibrate        # HEAD against itself: save this machine's noise bands
//! zig build bench-compare -- main --rounds 20   # a fixed number of rounds
//! zig build bench-compare -- main --core 7 --require-quiet
//! zig build bench-compare -- main --layouts 1   # one memory layout, as before B5
//! zig build bench-compare -- main --metric cycles # core cycles, through hardware counters (Linux)
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const machine = @import("machine.zig");
const Machine = machine.Machine;
const statistics = @import("statistics.zig");

/// Rounds keep coming until every interval is narrower than its target or
/// the time budget is spent, but never fewer than this.
const min_sequential_rounds = 6;
const max_sequential_rounds = 100;
const default_target_width = 0.01;
const default_time_budget_seconds = 420;
/// Layouts the rounds take turns with, each a seed for where the
/// benchmark's code, stack and `Context` memory land and, on Linux, a
/// length of padding in its environment.
const default_layouts = 3;
const layout_seed_variable = "ZUI_BENCH_LAYOUT_SEED";
const environment_padding_variable = "ZUI_BENCH_PADDING";
const max_environment_padding = 4096;

/// What a comparison compares. The counters ride in the benchmark's JSON
/// beside the times, under keys ending in their name.
const Metric = enum {
    ns,
    cycles,
    instructions,

    const counter_suffixes = [_][]const u8{ ", cycles", ", instructions", ", branch misses", ", L1D read misses", ", LL misses" };

    fn suffix(metric: Metric) ?[]const u8 {
        return switch (metric) {
            .ns => null,
            .cycles => ", cycles",
            .instructions => ", instructions",
        };
    }

    /// Whether `key` holds this metric.
    fn selects(metric: Metric, key: []const u8) bool {
        if (metric.suffix()) |wanted| return std.mem.endsWith(u8, key, wanted);
        for (counter_suffixes) |counter| {
            if (std.mem.endsWith(u8, key, counter)) return false;
        }
        return true;
    }
};

/// The noise band when this machine has not been calibrated.
const default_noise_band = 0.02;
/// The narrowest band calibration saves: a commit compared with itself
/// over few rounds can give an interval of exactly no change.
const min_noise_band = 0.005;

const Options = struct {
    zig_exe: []const u8,
    repository: []const u8,
    base_ref: []const u8,
    head_ref: ?[]const u8,
    /// Null runs rounds until the intervals are narrow enough.
    rounds: ?usize,
    target_width: f64,
    time_budget_seconds: u64,
    calibrate: bool,
    /// Null pins to the highest-numbered logical CPU.
    core: ?u32,
    pin: bool,
    require_quiet: bool,
    layouts: usize,
    metric: Metric,
};

const usage = "usage: zig build bench-compare -- <base> [<head>] [--rounds <count> | --target-width <percent>] [--time-budget <seconds>]\n" ++
    "                                    [--core <n> | --no-pin] [--require-quiet] [--layouts <count>] [--metric ns|cycles|instructions]\n" ++
    "       zig build bench-compare -- --calibrate [<commit>]\n" ++
    "<head> defaults to the working tree, uncommitted changes included; <commit> to HEAD\n";

fn parseOptions(arguments: []const [:0]const u8) !Options {
    var zig_exe: ?[]const u8 = null;
    var repository: ?[]const u8 = null;
    var refs: [2][]const u8 = undefined;
    var ref_count: usize = 0;
    var rounds: ?usize = null;
    var target_width: f64 = default_target_width;
    var time_budget_seconds: u64 = default_time_budget_seconds;
    var calibrate = false;
    var core: ?u32 = null;
    var pin = true;
    var require_quiet = false;
    var layouts: usize = default_layouts;
    var metric: Metric = .ns;
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
            const count = std.fmt.parseInt(usize, arguments[index], 10) catch 0;
            if (count < 2) {
                std.debug.print("--rounds needs a whole number of at least 2, got \"{s}\"\n", .{arguments[index]});
                return error.InvalidArgument;
            }
            rounds = count;
        } else if (std.mem.eql(u8, argument, "--target-width") and has_value) {
            index += 1;
            const percent = std.fmt.parseFloat(f64, arguments[index]) catch 0;
            if (!(percent > 0)) {
                std.debug.print("--target-width needs a percentage above 0, got \"{s}\"\n", .{arguments[index]});
                return error.InvalidArgument;
            }
            target_width = percent / 100;
        } else if (std.mem.eql(u8, argument, "--time-budget") and has_value) {
            index += 1;
            time_budget_seconds = std.fmt.parseInt(u64, arguments[index], 10) catch {
                std.debug.print("--time-budget needs a whole number of seconds, got \"{s}\"\n", .{arguments[index]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, argument, "--calibrate")) {
            calibrate = true;
        } else if (std.mem.eql(u8, argument, "--core") and has_value) {
            index += 1;
            core = std.fmt.parseInt(u32, arguments[index], 10) catch {
                std.debug.print("--core needs a core number, got \"{s}\"\n", .{arguments[index]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, argument, "--no-pin")) {
            pin = false;
        } else if (std.mem.eql(u8, argument, "--require-quiet")) {
            require_quiet = true;
        } else if (std.mem.eql(u8, argument, "--layouts") and has_value) {
            index += 1;
            layouts = std.fmt.parseInt(usize, arguments[index], 10) catch 0;
            if (layouts == 0) {
                std.debug.print("--layouts needs a whole number of at least 1, got \"{s}\"\n", .{arguments[index]});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, argument, "--metric") and has_value) {
            index += 1;
            metric = std.meta.stringToEnum(Metric, arguments[index]) orelse {
                std.debug.print("--metric needs ns, cycles or instructions, got \"{s}\"\n", .{arguments[index]});
                return error.InvalidArgument;
            };
        } else if (!std.mem.startsWith(u8, argument, "--") and ref_count < refs.len) {
            refs[ref_count] = argument;
            ref_count += 1;
        } else {
            std.debug.print("unknown argument \"{s}\"\n" ++ usage, .{argument});
            return error.InvalidArgument;
        }
    }
    if (calibrate and ref_count > 1) {
        std.debug.print("--calibrate compares one commit with itself\n" ++ usage, .{});
        return error.InvalidArgument;
    }
    if (ref_count == 0 and !calibrate) {
        std.debug.print(usage, .{});
        return error.InvalidArgument;
    }
    const base_ref = if (ref_count == 0) "HEAD" else refs[0];
    return .{
        .zig_exe = zig_exe orelse return error.MissingZigExe,
        .repository = repository orelse return error.MissingRepository,
        .base_ref = base_ref,
        .head_ref = if (calibrate) base_ref else if (ref_count == 2) refs[1] else null,
        .rounds = rounds,
        .target_width = target_width,
        .time_budget_seconds = time_budget_seconds,
        .calibrate = calibrate,
        .core = core,
        .pin = pin,
        .require_quiet = require_quiet,
        .layouts = layouts,
        .metric = metric,
    };
}

const Scenario = struct {
    name: []const u8,
    startup: bool,
};

/// The scenarios both sides know, in head's order.
fn sharedScenarios(arena: std.mem.Allocator, base: []const Scenario, head: []const Scenario) ![]const Scenario {
    var shared: std.ArrayList(Scenario) = .empty;
    for (head) |scenario| {
        for (base) |base_scenario| {
            if (std.mem.eql(u8, scenario.name, base_scenario.name)) {
                try shared.append(arena, scenario);
                break;
            }
        }
    }
    return shared.items;
}

/// One build of the benchmarks: a commit checked out in its own worktree,
/// or the working tree itself.
const Side = struct {
    label: []const u8,
    /// Abbreviated; null for the working tree.
    commit: ?[]const u8,
    directory: []const u8,
    results_path: []const u8,
    /// What the side's `bench --capabilities` printed: empty for commits
    /// from before the option.
    capabilities: []const u8 = "",
    /// One entry per run, from the benchmark's `--json`: the fastest frame
    /// of each scenario's declaration and `endFrame`, in nanoseconds.
    runs: std.ArrayList(std.json.ArrayHashMap(u64)) = .empty,
    /// The machine's state just before each run.
    machines: std.ArrayList(Machine) = .empty,
    /// The installed benchmark, run without the build runner, when both
    /// sides can run one scenario at a time: one build per layout when the
    /// layouts move the code, otherwise one for all.
    executables: []const []const u8 = &.{},

    fn supports(side: *const Side, capability: []const u8) bool {
        var words = std.mem.tokenizeAny(u8, side.capabilities, " \r\n");
        while (words.next()) |word| {
            if (std.mem.eql(u8, word, capability)) return true;
        }
        return false;
    }
};

/// One layout the benchmarks run under.
const Layout = struct {
    /// Which of the comparison's layouts this is, and so which of a side's
    /// builds runs under it.
    index: usize,
    /// Null when a side cannot move its own memory, so neither side does.
    seed: ?u64,
    /// Whether each side was built with `-Dbench-layout-seed=<seed>`, which
    /// moves its code.
    moves_code: bool,
    /// Bytes of padding in the environment, which shifts the initial stack
    /// of a benchmark from any commit. Zero where the environment is not on
    /// the stack.
    environment_padding: usize,

    fn choose(random: std.Random, index: usize, moves_memory: bool, moves_code: bool) Layout {
        return .{
            .index = index,
            // Zero would mean no code shift.
            .seed = if (moves_memory) random.intRangeAtMost(u32, 1, std.math.maxInt(u32)) else null,
            .moves_code = moves_memory and moves_code,
            .environment_padding = if (builtin.os.tag == .linux) random.uintLessThan(usize, max_environment_padding) else 0,
        };
    }
};

const Tool = struct {
    io: Io,
    arena: std.mem.Allocator,
    options: Options,
    scratch_directory: []const u8,
    environ: *const std.process.Environ.Map,
    pinned_core: ?u32 = null,
    layouts: []const Layout = &.{.{ .index = 0, .seed = null, .moves_code = false, .environment_padding = 0 }},

    fn runCommand(tool: *const Tool, argv: []const []const u8, cwd: []const u8) ![]const u8 {
        return tool.runCommandIn(argv, cwd, null);
    }

    fn runCommandIn(tool: *const Tool, argv: []const []const u8, cwd: []const u8, environ: ?*const std.process.Environ.Map) ![]const u8 {
        const result = try std.process.run(tool.arena, tool.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = environ });
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

    /// A command run beside others by `runInParallel`.
    const Job = struct {
        argv: []const []const u8,
        cwd: []const u8,
        /// Where its output goes; printed if it fails.
        log_path: []const u8,
        /// Where its standard output goes, if not to the log.
        stdout_path: ?[]const u8 = null,
    };

    /// Runs every job at once and waits for them all; returns whether each
    /// succeeded. A build of the benchmarks spends most of its time in LLVM on
    /// one thread, so several builds take about as long as one.
    fn runInParallel(tool: *const Tool, jobs: []const Job) ![]const bool {
        const io = tool.io;
        const children = try tool.arena.alloc(?std.process.Child, jobs.len);
        @memset(children, null);
        defer for (children) |*maybe_child| {
            if (maybe_child.*) |*child| child.kill(io);
        };
        for (jobs, children) |job, *child| {
            const log = try Io.Dir.cwd().createFile(io, job.log_path, .{});
            defer log.close(io);
            const stdout_file = if (job.stdout_path) |path| try Io.Dir.cwd().createFile(io, path, .{}) else null;
            defer if (stdout_file) |file| file.close(io);
            child.* = try std.process.spawn(io, .{
                .argv = job.argv,
                .cwd = .{ .path = job.cwd },
                .stdin = .ignore,
                .stdout = .{ .file = stdout_file orelse log },
                .stderr = .{ .file = log },
            });
        }
        const succeeded = try tool.arena.alloc(bool, jobs.len);
        for (jobs, children, succeeded) |job, *maybe_child, *job_succeeded| {
            const term = try maybe_child.*.?.wait(io);
            maybe_child.* = null;
            job_succeeded.* = term == .exited and term.exited == 0;
            if (job_succeeded.* or job.stdout_path != null) continue;
            std.debug.print("in {s}, this failed with {any}:\n ", .{ job.cwd, term });
            for (job.argv) |argument| std.debug.print(" {s}", .{argument});
            const output = Io.Dir.cwd().readFileAlloc(io, job.log_path, tool.arena, .limited(64 * 1024)) catch "";
            std.debug.print("\n{s}", .{output});
        }
        return succeeded;
    }

    /// Builds each side's benchmark and asks it which options it supports.
    /// A failure is taken as a benchmark too old to know the question; a
    /// build that is really broken fails loudly on its first run.
    fn probeCapabilities(tool: *const Tool, sides: []const *Side) !void {
        const jobs = try tool.arena.alloc(Job, sides.len);
        for (jobs, sides, 0..) |*job, side, index| job.* = .{
            .argv = &.{ tool.options.zig_exe, "build", "bench", "--", "--capabilities" },
            .cwd = side.directory,
            .log_path = try tool.scratchPath("probe-{d}.log", .{index}),
            .stdout_path = try tool.scratchPath("probe-{d}.txt", .{index}),
        };
        for (jobs, sides, try tool.runInParallel(jobs)) |job, side, succeeded| {
            if (succeeded) side.capabilities = try Io.Dir.cwd().readFileAlloc(tool.io, job.stdout_path.?, tool.arena, .limited(4096));
        }
    }

    /// Installs each side's benchmark, built unpinned like every build, so
    /// each scenario can run in its own process without the build runner:
    /// once for each layout when the layouts move the code.
    fn install(tool: *const Tool, sides: []const *Side, roles: []const []const u8) !void {
        const builds = if (tool.layouts[0].moves_code) tool.layouts.len else 1;
        var jobs: std.ArrayList(Job) = .empty;
        for (sides, roles) |side, role| {
            const executables = try tool.arena.alloc([]const u8, builds);
            for (executables, 0..) |*executable, index| {
                const prefix = try tool.scratchPath("{s}-bin-{d}", .{ role, index });
                var argv: std.ArrayList([]const u8) = .empty;
                try argv.appendSlice(tool.arena, &.{ tool.options.zig_exe, "build", "bench-install", "--prefix", prefix });
                if (tool.layouts[0].moves_code) try argv.append(tool.arena, try std.fmt.allocPrint(tool.arena, "-Dbench-layout-seed={d}", .{tool.layouts[index].seed.?}));
                try jobs.append(tool.arena, .{ .argv = argv.items, .cwd = side.directory, .log_path = try tool.scratchPath("{s}-build-{d}.log", .{ role, index }) });
                executable.* = try std.fs.path.join(tool.arena, &.{ prefix, "bin", if (builtin.os.tag == .windows) "zui-bench.exe" else "zui-bench" });
            }
            side.executables = executables;
        }
        for (try tool.runInParallel(jobs.items)) |succeeded| {
            if (!succeeded) return error.CommandFailed;
        }
    }

    fn scratchPath(tool: *const Tool, comptime format: []const u8, arguments: anytype) ![]const u8 {
        return std.fs.path.join(tool.arena, &.{ tool.scratch_directory, try std.fmt.allocPrint(tool.arena, format, arguments) });
    }

    /// The compared and startup scenarios, with startup scenarios marked,
    /// as `bench --list-scenarios` prints them.
    fn listScenarios(tool: *const Tool, side: *const Side) ![]const Scenario {
        const output = try tool.runCommand(&.{ side.executables[0], "--list-scenarios" }, side.directory);
        var scenarios: std.ArrayList(Scenario) = .empty;
        var lines = std.mem.tokenizeAny(u8, output, "\r\n");
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const kind = line[tab + 1 ..];
            const is_startup = std.mem.eql(u8, kind, "startup");
            if (!is_startup and !std.mem.eql(u8, kind, "compared")) continue;
            try scenarios.append(tool.arena, .{ .name = line[0..tab], .startup = is_startup });
        }
        return scenarios.items;
    }

    /// The command that runs the side's benchmark: its installed executable,
    /// or its own `zig build bench`, so each commit is measured by the
    /// scenarios it shipped with.
    fn benchmarkArgv(tool: *const Tool, side: *const Side, arguments: []const []const u8, layout: Layout) ![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        if (side.executables.len > 0) {
            try argv.append(tool.arena, side.executables[if (side.executables.len > 1) layout.index else 0]);
        } else {
            try argv.appendSlice(tool.arena, &.{ tool.options.zig_exe, "build", "bench", "--" });
        }
        try argv.appendSlice(tool.arena, &.{ "--json", side.results_path });
        if (tool.options.metric != .ns) try argv.append(tool.arena, "--counters");
        // The pin is inherited already; this adds the raised priority, which
        // on Windows is not.
        if (tool.pinned_core) |core| {
            if (side.supports("core")) try argv.appendSlice(tool.arena, &.{ "--core", try std.fmt.allocPrint(tool.arena, "{d}", .{core}) });
        }
        try argv.appendSlice(tool.arena, arguments);
        return argv.items;
    }

    /// This process's environment with the layout's seed and padding.
    fn layoutEnvironment(tool: *const Tool, layout: Layout) !std.process.Environ.Map {
        var environ = try tool.environ.clone(tool.arena);
        _ = environ.swapRemove(layout_seed_variable);
        _ = environ.swapRemove(environment_padding_variable);
        if (layout.seed) |seed| try environ.put(layout_seed_variable, try std.fmt.allocPrint(tool.arena, "{d}", .{seed}));
        if (layout.environment_padding > 0) {
            const padding = try tool.arena.alloc(u8, layout.environment_padding);
            @memset(padding, 'x');
            try environ.put(environment_padding_variable, padding);
        }
        return environ;
    }

    fn measure(tool: *const Tool, side: *Side, arguments: []const []const u8, layout: Layout) !std.json.ArrayHashMap(u64) {
        try side.machines.append(tool.arena, try machine.read(tool.io, tool.arena, tool.pinned_core));
        const environ = try tool.layoutEnvironment(layout);
        _ = try tool.runCommandIn(try tool.benchmarkArgv(side, arguments, layout), side.directory, &environ);
        const contents = try Io.Dir.cwd().readFileAlloc(tool.io, side.results_path, tool.arena, .limited(64 * 1024));
        return std.json.parseFromSliceLeaky(std.json.ArrayHashMap(u64), tool.arena, contents, .{});
    }

    /// One round of every scenario at once, for sides that cannot run one
    /// scenario at a time.
    fn runBenchmarks(tool: *const Tool, side: *Side, layout: Layout) !void {
        try side.runs.append(tool.arena, try tool.measure(side, &.{}, layout));
    }

    /// One round of one scenario at a time, in an order shuffled by the
    /// round, alternating which side goes first from one scenario to the
    /// next. Startup scenarios stay last, as they do in `bench`.
    fn runScenarioRound(tool: *const Tool, base: *Side, head: *Side, scenarios: []const Scenario, round: usize, layout: Layout) !void {
        const order = try tool.arena.dupe(Scenario, scenarios);
        var frames_count: usize = 0;
        for (scenarios) |scenario| {
            if (!scenario.startup) {
                order[frames_count] = scenario;
                frames_count += 1;
            }
        }
        var startup_count: usize = frames_count;
        for (scenarios) |scenario| {
            if (scenario.startup) {
                order[startup_count] = scenario;
                startup_count += 1;
            }
        }
        var random: std.Random.DefaultPrng = .init(round);
        random.random().shuffle(Scenario, order[0..frames_count]);

        var base_times: std.json.ArrayHashMap(u64) = .{};
        var head_times: std.json.ArrayHashMap(u64) = .{};
        for (order, 0..) |scenario, position| {
            const base_first = (round + position) % 2 == 0;
            for ([_]bool{ base_first, !base_first }) |is_base| {
                const side, const times = if (is_base) .{ base, &base_times } else .{ head, &head_times };
                const measured = try tool.measure(side, &.{ "--scenario", scenario.name }, layout);
                for (measured.map.keys(), measured.map.values()) |key, nanoseconds| try times.map.put(tool.arena, key, nanoseconds);
            }
        }
        try base.runs.append(tool.arena, base_times);
        try head.runs.append(tool.arena, head_times);
    }

    fn pin(tool: *Tool) !void {
        if (!tool.options.pin) return;
        const core = tool.options.core orelse machine.logicalCpuCount() - 1;
        machine.pinToCore(core, .process) catch |err| {
            if (tool.options.core != null) {
                std.debug.print("could not pin to core {d}: {t}\n", .{ core, err });
                return err;
            }
            std.debug.print("warning: could not pin to core {d} ({t}); measuring unpinned\n", .{ core, err });
            return;
        };
        tool.pinned_core = core;
        machine.raisePriority() catch |err| std.debug.print("warning: pinned to core {d}, but could not raise the priority: {t}\n", .{ core, err });
    }

    fn noiseFloorPath(tool: *const Tool) ![]const u8 {
        return std.fs.path.join(tool.arena, &.{ tool.scratch_directory, "noise-floor.json" });
    }
};

/// Each machine setup's noise bands, as `--calibrate` measured them, keyed
/// by the setup's fingerprint in hexadecimal.
const NoiseFloors = std.json.ArrayHashMap(NoiseFloor);

const NoiseFloor = struct {
    machine: Machine,
    commit: []const u8,
    /// How far from no change a commit compared with itself reached, per
    /// time: the change a comparison must clear to be called.
    bands: std.json.ArrayHashMap(f64),
};

fn readNoiseFloors(tool: *const Tool) !NoiseFloors {
    const contents = Io.Dir.cwd().readFileAlloc(tool.io, try tool.noiseFloorPath(), tool.arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(NoiseFloors, tool.arena, contents, .{ .ignore_unknown_fields = true }) catch {
        std.debug.print("warning: {s} could not be read; calibrate again\n", .{try tool.noiseFloorPath()});
        return .{};
    };
}

fn writeNoiseFloors(tool: *const Tool, floors: *const NoiseFloors) !void {
    const file = try Io.Dir.cwd().createFile(tool.io, try tool.noiseFloorPath(), .{});
    defer file.close(tool.io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(tool.io, &buffer);
    try std.json.Stringify.value(floors.*, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
}

fn fingerprintText(arena: std.mem.Allocator, state: *const Machine) ![]const u8 {
    return std.fmt.allocPrint(arena, "{x:0>16}", .{state.fingerprint()});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const options = try parseOptions(try init.minimal.args.toSlice(arena));
    const started = Io.Timestamp.now(io, .awake);

    var tool: Tool = .{
        .io = io,
        .arena = arena,
        .options = options,
        .scratch_directory = try std.fs.path.join(arena, &.{ options.repository, ".zig-cache", "bench-compare" }),
        .environ = init.environ_map,
    };
    try Io.Dir.cwd().createDirPath(io, tool.scratch_directory);

    var base = try tool.checkOut(options.base_ref, "base");
    defer tool.remove(&base);
    var head = if (options.head_ref) |ref| try tool.checkOut(ref, "head") else try tool.workingTree();
    defer tool.remove(&head);

    // Building, and a first run of each side that warms the machine and is
    // thrown away, happen unpinned: the compiler uses every core.
    std.debug.print("building {s} and {s}\n", .{ base.label, head.label });
    try tool.probeCapabilities(&.{ &base, &head });
    if (options.metric != .ns) {
        for ([_]*const Side{ &base, &head }) |side| {
            if (!side.supports("counters")) {
                std.debug.print("--metric {t}: {s}'s benchmark cannot read hardware counters\n", .{ options.metric, side.label });
                return error.CountersUnsupported;
            }
        }
    }
    var scenarios: []const Scenario = &.{};
    const one_scenario_at_a_time = for ([_]*const Side{ &base, &head }) |side| {
        if (!side.supports("scenarios") or !side.supports("bench-install")) break false;
    } else true;

    // Fresh layouts for every comparison, so repeated comparisons sample
    // new ones rather than repeating the same few.
    const moves_memory = base.supports("layout-seed") and head.supports("layout-seed");
    const moves_code = one_scenario_at_a_time and options.layouts > 1 and base.supports("code-layout") and head.supports("code-layout");
    var layout_random: std.Random.DefaultPrng = .init(@bitCast(@as(i64, @truncate(Io.Timestamp.now(io, .real).nanoseconds))));
    const layouts = try arena.alloc(Layout, options.layouts);
    for (layouts, 0..) |*layout, index| layout.* = .choose(layout_random.random(), index, moves_memory, moves_code);
    tool.layouts = layouts;
    if (moves_code) std.debug.print("building each side {d} times, once per code layout\n", .{layouts.len});

    if (one_scenario_at_a_time) {
        try tool.install(&.{ &base, &head }, &.{ "base", "head" });
        scenarios = try sharedScenarios(arena, try tool.listScenarios(&base), try tool.listScenarios(&head));
    } else {
        std.debug.print("{s} cannot run one scenario at a time, so each round runs every scenario at once, in one order\n", .{if (!base.supports("scenarios")) base.label else head.label});
    }
    try tool.runBenchmarks(&base, tool.layouts[0]);
    try tool.runBenchmarks(&head, tool.layouts[0]);
    base.runs.clearRetainingCapacity();
    head.runs.clearRetainingCapacity();
    base.machines.clearRetainingCapacity();
    head.machines.clearRetainingCapacity();

    try tool.pin();
    const setup = try machine.read(io, arena, tool.pinned_core);
    if (options.require_quiet) {
        if (setup.noisyReason()) |reason| {
            std.debug.print("--require-quiet: {s}. README.md, \"Quieting the machine\", says how to set it up.\n", .{reason});
            return error.NoisyMachine;
        }
    }
    var floors = try readNoiseFloors(&tool);
    const fingerprint = try fingerprintText(arena, &setup);
    const bands: ?std.json.ArrayHashMap(f64) = if (options.calibrate) null else if (floors.map.get(fingerprint)) |floor| floor.bands else null;
    const verdicts: Verdicts = .{ .bands = bands, .target_width = options.target_width, .layouts = layouts.len, .metric = options.metric };

    const budget_ns = options.time_budget_seconds * std.time.ns_per_s;
    var round_ns: u64 = 0;
    var round: usize = 0;
    while (true) : (round += 1) {
        if (options.rounds) |rounds| {
            if (round == rounds) break;
        } else {
            if (round >= min_sequential_rounds and try verdicts.allNarrowEnough(arena, &base, &head)) break;
            if (round == max_sequential_rounds) break;
        }
        const elapsed_ns: u64 = @intCast(started.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        if (round >= 2 and elapsed_ns + round_ns > budget_ns) {
            std.debug.print("stopping after {d} rounds: another would pass the {d} s time budget\n", .{ round, options.time_budget_seconds });
            break;
        }
        if (options.rounds) |rounds| {
            std.debug.print("round {d}/{d}\n", .{ round + 1, rounds });
        } else {
            std.debug.print("round {d}, until every interval is narrow enough or {d} s pass\n", .{ round + 1, options.time_budget_seconds });
        }
        const round_started = Io.Timestamp.now(io, .awake);
        const layout = layouts[round % layouts.len];
        if (one_scenario_at_a_time) {
            try tool.runScenarioRound(&base, &head, scenarios, round, layout);
        } else {
            // Alternating which side goes first cancels a drift in the
            // machine's speed over the comparison, such as a CPU warming up.
            const first, const second = if (round % 2 == 0) .{ &base, &head } else .{ &head, &base };
            try tool.runBenchmarks(first, layout);
            try tool.runBenchmarks(second, layout);
        }
        round_ns = @intCast(round_started.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    const changes = try report(arena, out, &base, &head, &verdicts, one_scenario_at_a_time, layouts);
    if (!options.calibrate and bands == null) {
        try out.print("\nThis machine setup has no noise bands, so each was taken as {d:.0}%. `zig build bench-compare -- --calibrate` measures them.\n", .{default_noise_band * 100});
    }
    if (options.calibrate) {
        // Calibrating one metric keeps the bands of the others.
        var calibrated: std.json.ArrayHashMap(f64) = if (floors.map.get(fingerprint)) |floor| floor.bands else .{};
        for (changes) |change| try calibrated.map.put(arena, change.key, @max(change.interval.reach(), min_noise_band));
        try floors.map.put(arena, fingerprint, .{ .machine = setup, .commit = base.commit.?, .bands = calibrated });
        try writeNoiseFloors(&tool, &floors);
        try out.print("\nsaved each time's noise band for this machine setup ({s}) to {s}\n", .{ fingerprint, try tool.noiseFloorPath() });
    }
    try out.flush();
}

const Change = struct {
    key: []const u8,
    interval: statistics.Interval,
};

/// Decides when a change is called, and when the rounds can stop.
const Verdicts = struct {
    /// Null before calibration, when every time gets the default band.
    bands: ?std.json.ArrayHashMap(f64),
    target_width: f64,
    /// Round `r` ran under layout `r % layouts`.
    layouts: usize,
    metric: Metric,

    fn band(verdicts: *const Verdicts, key: []const u8) f64 {
        const bands = verdicts.bands orelse return default_noise_band;
        return bands.map.get(key) orelse default_noise_band;
    }

    /// An interval need not be narrower than its band: any interval that
    /// narrow already decides the verdict.
    fn narrowEnough(verdicts: *const Verdicts, key: []const u8, interval: statistics.Interval) bool {
        return interval.width() <= @max(verdicts.target_width, verdicts.band(key));
    }

    fn allNarrowEnough(verdicts: *const Verdicts, arena: std.mem.Allocator, base: *const Side, head: *const Side) !bool {
        if (base.runs.items.len == 0) return false;
        for (head.runs.items[0].map.keys()) |key| {
            if (!verdicts.metric.selects(key)) continue;
            const groups = try ratiosByLayout(arena, base, head, key, verdicts.layouts) orelse continue;
            if (!verdicts.narrowEnough(key, try statistics.bootstrapMedian(arena, groups))) return false;
        }
        return true;
    }
};

/// Each round's head/base ratio for `key`, one group per layout, so the
/// bootstrap resamples layouts before the rounds within them. Null when
/// the base never measured `key`.
fn ratiosByLayout(arena: std.mem.Allocator, base: *const Side, head: *const Side, key: []const u8, layouts: usize) !?[]const []const f64 {
    const rounds = base.runs.items.len;
    const group_count = @min(layouts, rounds);
    const groups = try arena.alloc([]f64, group_count);
    for (groups, 0..) |*group, layout| group.* = try arena.alloc(f64, (rounds - layout + group_count - 1) / group_count);
    for (base.runs.items, head.runs.items, 0..) |base_run, head_run, round| {
        const base_time = base_run.map.get(key) orelse return null;
        groups[round % group_count][round / group_count] = @as(f64, @floatFromInt(head_run.map.get(key).?)) / @as(f64, @floatFromInt(base_time));
    }
    return groups;
}

fn medianTime(arena: std.mem.Allocator, side: *const Side, key: []const u8) !f64 {
    const times = try arena.alloc(f64, side.runs.items.len);
    for (side.runs.items, times) |run, *time| time.* = @floatFromInt(run.map.get(key).?);
    return statistics.median(times);
}

fn report(arena: std.mem.Allocator, out: *Io.Writer, base: *const Side, head: *const Side, verdicts: *const Verdicts, one_scenario_at_a_time: bool, layouts: []const Layout) ![]const Change {
    const rounds = base.runs.items.len;
    try printSide(out, "base", base);
    try printSide(out, "head", head);
    try warnOfChangedSetup(out, base, head);
    if (one_scenario_at_a_time) {
        try out.print("{d} rounds, each running one scenario at a time in a new random order,\n" ++
            "alternating which side goes first. ", .{rounds});
    } else {
        try out.print("{d} rounds of every scenario at once, alternating which side goes first. ", .{rounds});
    }
    try printLayouts(out, layouts, @min(layouts.len, rounds));
    try out.writeAll("Each time is a run's fastest frame;\n" ++
        "the change is the median of the rounds' head/base ratios, with its bootstrap 95%\n" ++
        "interval, resampling layouts and then the rounds within them. A change is called\n" ++
        "only when its whole interval lies beyond the noise band: how far a commit\n" ++
        "compared with itself strayed on this machine.\n\n");
    try out.print("{s:<37} {s:>10} {s:>10} {s:>8}   {s:<19} {s:>6}\n", .{ "", "base", "head", "change", "95% interval", "band" });

    var changes: std.ArrayList(Change) = .empty;
    for (head.runs.items[0].map.keys()) |key| {
        if (!verdicts.metric.selects(key)) continue;
        const groups = try ratiosByLayout(arena, base, head, key, verdicts.layouts) orelse {
            try out.print("{s:<37} only in head\n", .{key});
            continue;
        };
        const interval = try statistics.bootstrapMedian(arena, groups);
        try changes.append(arena, .{ .key = key, .interval = interval });
        const band = verdicts.band(key);
        var estimate_buffer: [16]u8 = undefined;
        var lower_buffer: [16]u8 = undefined;
        var upper_buffer: [16]u8 = undefined;
        var interval_buffer: [40]u8 = undefined;
        const interval_text = try std.fmt.bufPrint(&interval_buffer, "{s:>7} to {s}", .{ percentChange(&lower_buffer, interval.lower), percentChange(&upper_buffer, interval.upper) });
        var base_buffer: [24]u8 = undefined;
        var head_buffer: [24]u8 = undefined;
        try out.print("{s:<37} {s:>10} {s:>10} {s:>8}   {s:<19} {d:>5.1}%", .{
            if (verdicts.metric.suffix()) |suffix| key[0 .. key.len - suffix.len] else key,
            try formatValue(&base_buffer, verdicts.metric, try medianTime(arena, base, key)),
            try formatValue(&head_buffer, verdicts.metric, try medianTime(arena, head, key)),
            percentChange(&estimate_buffer, interval.estimate),
            interval_text,
            band * 100,
        });
        if (interval.lower > 1 + band) {
            try out.writeAll("  slower\n");
        } else if (interval.upper < 1 - band) {
            try out.writeAll("  faster\n");
        } else {
            try out.writeByte('\n');
        }
    }
    for (base.runs.items[0].map.keys()) |key| {
        if (verdicts.metric.selects(key) and !head.runs.items[0].map.contains(key)) try out.print("{s:<37} only in base\n", .{key});
    }
    return changes.items;
}

fn formatValue(buffer: *[24]u8, metric: Metric, value: f64) ![]const u8 {
    return switch (metric) {
        .ns => std.fmt.bufPrint(buffer, "{d:.1}us", .{value / std.time.ns_per_us}),
        .cycles, .instructions => std.fmt.bufPrint(buffer, "{d:.0}", .{value}),
    };
}

/// The layouts the rounds used, so a comparison can be repeated under them.
fn printLayouts(out: *Io.Writer, layouts: []const Layout, used: usize) !void {
    if (used <= 1 and layouts[0].seed == null and layouts[0].environment_padding == 0) return;
    try out.print("Rounds took turns with {d} layout{s} of {s}:", .{
        used,
        if (used == 1) "" else "s",
        if (layouts[0].moves_code) "code and memory, each side built once per layout" else "memory",
    });
    for (layouts[0..used], 0..) |layout, index| {
        try out.writeAll(if (index == 0) " " else ", ");
        if (layout.seed) |seed| try out.print("{s}={d}", .{ layout_seed_variable, seed }) else try out.writeAll("no seed");
        if (layout.environment_padding > 0) try out.print(" with {d} bytes of environment", .{layout.environment_padding});
    }
    try out.writeAll(".\n");
}

fn printSide(out: *Io.Writer, role: []const u8, side: *const Side) !void {
    if (side.commit) |commit| {
        try out.print("{s}  {s} ({s})\n", .{ role, side.label, commit });
    } else {
        try out.print("{s}  {s}\n", .{ role, side.label });
    }
    try out.writeAll("      ");
    try side.machines.items[0].print(out);
    var lowest_mhz: u32 = std.math.maxInt(u32);
    var highest_mhz: u32 = 0;
    for (side.machines.items) |state| {
        const mhz = state.clock_mhz orelse continue;
        lowest_mhz = @min(lowest_mhz, mhz);
        highest_mhz = @max(highest_mhz, mhz);
    }
    if (lowest_mhz < highest_mhz) try out.print("; the clock read {d} to {d} MHz over its runs", .{ lowest_mhz, highest_mhz });
    try out.writeByte('\n');
}

/// Both sides run on one machine, so a difference means its setup changed
/// while the comparison ran, and the two sides were not measured alike.
fn warnOfChangedSetup(out: *Io.Writer, base: *const Side, head: *const Side) !void {
    const fields = @typeInfo(Machine).@"struct".fields;
    const reference = &base.machines.items[0];
    var changed: [fields.len]bool = @splat(false);
    var names: [fields.len][]const u8 = undefined;
    for ([_]*const Side{ base, head }) |side| {
        for (side.machines.items) |*state| {
            for (reference.differingSettings(state, &names)) |name| {
                inline for (fields, 0..) |field, index| {
                    if (std.mem.eql(u8, field.name, name)) changed[index] = true;
                }
            }
        }
    }
    var any = false;
    inline for (fields, 0..) |field, index| {
        if (changed[index]) {
            try out.print("{s}{s}", .{ if (any) ", " else "warning: the machine's setup changed during the comparison: ", field.name });
            any = true;
        }
    }
    if (any) try out.writeByte('\n');
}

fn percentChange(buffer: *[16]u8, ratio: f64) []const u8 {
    const rounded_change = @round((ratio - 1) * 1000) / 10;
    // Without `@abs`, a small speedup prints as -0.0%.
    const change = if (rounded_change == 0) @abs(rounded_change) else rounded_change;
    return std.fmt.bufPrint(buffer, "{s}{d:.1}%", .{ if (change >= 0) "+" else "", change }) catch unreachable;
}

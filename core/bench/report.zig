//! ```sh
//! zig build bench-report -- ~/zui-results           # the commit measured on the most machines
//! zig build bench-report -- ~/zui-results 45f48f4   # one commit
//! ```
//!
//! Sets side by side the results `zig build bench -- --results-dir <dir>`
//! kept on each machine. Each machine's times are divided by its own box
//! tree's, phase by phase, so the table compares what each scenario costs
//! relative to the others there, not which machine is faster; the
//! scenarios whose relative cost differs most between machines are the
//! ones a platform treats differently.

const std = @import("std");
const Io = std.Io;
const machine = @import("machine.zig");

/// The scenario every other is measured against, on each machine.
const reference = "4096 boxes, depth 8";
const flagged_count = 5;

const counter_suffixes = [_][]const u8{ ", cycles", ", instructions", ", branch misses", ", L1D read misses", ", LL misses" };

const Results = struct {
    machine: machine.Machine,
    times: std.json.ArrayHashMap(u64),
};

const Entry = struct {
    fingerprint: []const u8,
    results: Results,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len < 2 or arguments.len > 3) {
        std.debug.print("usage: zig build bench-report -- <results dir> [<commit>]\n", .{});
        return error.InvalidArgument;
    }
    const directory_path = arguments[1];
    var directory = Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch |err| {
        std.debug.print("could not open {s}: {t}\n", .{ directory_path, err });
        return err;
    };
    defer directory.close(io);

    // Every machine's commits, to choose one when none is named.
    var machines: std.ArrayList([]const u8) = .empty;
    var commits: std.StringArrayHashMapUnmanaged(usize) = .empty;
    var machine_iterator = directory.iterate();
    while (try machine_iterator.next(io)) |machine_entry| {
        if (machine_entry.kind != .directory) continue;
        const fingerprint = try arena.dupe(u8, machine_entry.name);
        try machines.append(arena, fingerprint);
        var machine_directory = try directory.openDir(io, fingerprint, .{ .iterate = true });
        defer machine_directory.close(io);
        var file_iterator = machine_directory.iterate();
        while (try file_iterator.next(io)) |file_entry| {
            if (file_entry.kind != .file or !std.mem.endsWith(u8, file_entry.name, ".json")) continue;
            const commit = try arena.dupe(u8, file_entry.name[0 .. file_entry.name.len - ".json".len]);
            const count = try commits.getOrPutValue(arena, commit, 0);
            count.value_ptr.* += 1;
        }
    }
    const commit = if (arguments.len == 3) arguments[2] else mostMeasured(&commits) orelse {
        std.debug.print("{s} holds no results; write some with `zig build bench -- --results-dir {s}`\n", .{ directory_path, directory_path });
        return error.NoResults;
    };

    var entries: std.ArrayList(Entry) = .empty;
    std.mem.sortUnstable([]const u8, machines.items, {}, lessThan);
    for (machines.items) |fingerprint| {
        const path = try std.fs.path.join(arena, &.{ fingerprint, try std.fmt.allocPrint(arena, "{s}.json", .{commit}) });
        const contents = directory.readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const results = std.json.parseFromSliceLeaky(Results, arena, contents, .{ .ignore_unknown_fields = true }) catch |err| {
            std.debug.print("could not read {s}/{s}: {t}\n", .{ directory_path, path, err });
            return err;
        };
        try entries.append(arena, .{ .fingerprint = fingerprint, .results = results });
    }
    if (entries.items.len == 0) {
        std.debug.print("no machine in {s} measured {s}\n", .{ directory_path, commit });
        return error.NoResults;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try report(arena, out, commit, entries.items);
    try out.flush();
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn mostMeasured(commits: *const std.StringArrayHashMapUnmanaged(usize)) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_count: usize = 0;
    for (commits.keys(), commits.values()) |commit, count| {
        if (count > best_count) {
            best = commit;
            best_count = count;
        }
    }
    return best;
}

fn isCounter(key: []const u8) bool {
    for (counter_suffixes) |suffix| {
        if (std.mem.endsWith(u8, key, suffix)) return true;
    }
    return false;
}

/// The reference time for `key`'s phase on one machine.
fn referenceFor(times: *const std.json.ArrayHashMap(u64), key: []const u8) ?u64 {
    return times.map.get(if (std.mem.endsWith(u8, key, ", declare")) reference ++ ", declare" else reference);
}

const Row = struct {
    key: []const u8,
    /// Each machine's time over its box tree's, or null where it was not
    /// measured.
    relative: []?f64,
    /// The largest relative cost over the smallest.
    spread: f64,
};

fn report(arena: std.mem.Allocator, out: *Io.Writer, commit: []const u8, entries: []const Entry) !void {
    try out.print("{s}, on {d} machine{s}:\n", .{ commit, entries.len, if (entries.len == 1) "" else "s" });
    for (entries, 1..) |entry, number| {
        const state = &entry.results.machine;
        try out.print("  #{d}  ", .{number});
        try state.print(out);
        try out.print("\n      {d} cores", .{state.physical_cores orelse 0});
        if (state.l1d_kib) |kib| try out.print(", L1d {d} KiB", .{kib});
        if (state.l2_kib) |kib| try out.print(", L2 {d} KiB", .{kib});
        if (state.l3_kib) |kib| try out.print(", L3 {d} KiB", .{kib});
        try out.print("; {s} built for {s} ({s})\n", .{ state.target, state.built_for_cpu, entry.fingerprint });
    }
    try out.print("\nEach time over that machine's own {s} in the same phase:\n\n", .{reference});

    var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (entries) |entry| {
        for (entry.results.times.map.keys()) |key| {
            if (!isCounter(key)) try keys.put(arena, key, {});
        }
    }
    var rows: std.ArrayList(Row) = .empty;
    for (keys.keys()) |key| {
        const relative = try arena.alloc(?f64, entries.len);
        var smallest: f64 = std.math.inf(f64);
        var largest: f64 = 0;
        for (entries, relative) |entry, *value| {
            const time = entry.results.times.map.get(key) orelse {
                value.* = null;
                continue;
            };
            const base = referenceFor(&entry.results.times, key) orelse {
                value.* = null;
                continue;
            };
            value.* = @as(f64, @floatFromInt(time)) / @as(f64, @floatFromInt(base));
            smallest = @min(smallest, value.*.?);
            largest = @max(largest, value.*.?);
        }
        try rows.append(arena, .{ .key = key, .relative = relative, .spread = if (largest > 0) largest / smallest else 1 });
    }

    try out.print("{s:<40}", .{""});
    for (1..entries.len + 1) |number| try out.print(" {s:>8}{d:<1}", .{ "#", number });
    if (entries.len > 1) try out.print(" {s:>8}", .{"spread"});
    try out.writeByte('\n');
    try out.print("{s:<40}", .{reference ++ " (us)"});
    for (entries) |entry| {
        const base = entry.results.times.map.get(reference) orelse 0;
        try out.print(" {d:>9.1}", .{@as(f64, @floatFromInt(base)) / std.time.ns_per_us});
    }
    try out.writeByte('\n');
    for (rows.items) |row| {
        try out.print("{s:<40}", .{row.key});
        for (row.relative) |value| {
            if (value) |ratio| try out.print(" {d:>8.2}x", .{ratio}) else try out.print(" {s:>9}", .{"-"});
        }
        if (entries.len > 1) try out.print(" {d:>7.2}x", .{row.spread});
        try out.writeByte('\n');
    }

    if (entries.len < 2) {
        try out.writeAll("\nOne machine only: run the benchmark on another with the same --results-dir to compare.\n");
        return;
    }
    std.mem.sortUnstable(Row, rows.items, {}, struct {
        fn wider(_: void, a: Row, b: Row) bool {
            return a.spread > b.spread;
        }
    }.wider);
    try out.writeAll("\nRelative costs that differ most between machines:\n");
    for (rows.items[0..@min(flagged_count, rows.items.len)]) |row| {
        if (row.spread <= 1) break;
        try out.print("  {s}: {d:.2}x from one machine to another\n", .{ row.key, row.spread });
    }
}

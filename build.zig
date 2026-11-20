const std = @import("std");

/// Every package directory: `test-all` and `check-all` run in each, and
/// `fmt` formats each.
const packages = [_][]const u8{
    "core",
    "text/glyphs",
    "text/fonts",
    "text/truetype",
    "themes",
    "examples",
    "renderers/terminal",
    "renderers/raylib",
    "renderers/sokol",
    "renderers/webgl",
    "hosts/native",
    "hosts/web",
};

/// Checked in as sokol-shdc writes them, so formatting leaves them alone.
const generated_sources = [_][]const u8{
    "renderers/sokol/src/material.glsl.zig",
    "renderers/sokol/src/linear_light.glsl.zig",
    "renderers/sokol/src/present_scrgb.glsl.zig",
};

const core_modules = [_][]const u8{ "zui", "zui_testing", "zui_widgets", "zui_async", "zui_tracy", "zui_reflect", "zui_app", "zui_wire", "zui_debug" };

/// Packages with no third-party library, whose module of the same name the
/// aggregator re-exports. One that links a C library is reached through
/// `zui.builder.dependency`, so a user fetches only the libraries they use.
const pure_zig_packages = [_][]const u8{ "zui_glyphs", "zui_fonts" };

/// A dependency's build does not see the arguments after `--`, and installs
/// into a prefix of its own in the cache, so the aggregator runs and installs
/// core's executables itself.
const core_steps_taking_arguments = [_]struct { step: []const u8, executable: []const u8 }{
    .{ .step = "bench", .executable = "zui-bench" },
    .{ .step = "counts", .executable = "zui-counts" },
    .{ .step = "bench-compare", .executable = "zui-bench-compare" },
    .{ .step = "bench-report", .executable = "zui-bench-report" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("zui_core", .{
        .target = target,
        .optimize = optimize,
        .@"zui-sanitize-thread" = b.option(bool, "zui-sanitize-thread", "Build zui and its modules with ThreadSanitizer, through LLVM (Linux)"),
        .@"zui-debug" = b.option(bool, "zui-debug", "Keep id names for diagnostics"),
        .@"zui-tracy" = b.option(bool, "zui-tracy", "Link Tracy's client, so zui_tracy.Tracer traces into the Tracy profiler"),
        .@"bench-layout-seed" = b.option(u64, "bench-layout-seed", "Move every function of the benchmark by a seed-chosen offset, as bench-compare's layouts do"),
    });
    for (core_modules) |name| b.modules.put(b.graph.arena, name, core.module(name)) catch @panic("OOM");
    for (pure_zig_packages) |name| {
        b.modules.put(b.graph.arena, name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name)) catch @panic("OOM");
    }

    for ([_][]const u8{ "test", "check" }) |name| forwardStep(b, core, name).dependOn(&core.builder.top_level_steps.get(name).?.step);
    forwardStep(b, core, "docs").dependOn(&b.addInstallDirectory(.{
        .source_dir = core.namedLazyPath("docs"),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
    const bench_file_name = b.fmt("zui-bench{s}", .{target.result.exeFileExt()});
    forwardStep(b, core, "bench-install").dependOn(&b.addInstallBinFile(core.namedLazyPath("zui-bench"), bench_file_name).step);
    for (core_steps_taking_arguments) |forwarded| {
        const run = std.Build.Step.Run.create(b, b.fmt("run {s}", .{forwarded.executable}));
        run.addFileArg(core.namedLazyPath(forwarded.executable));
        if (std.mem.eql(u8, forwarded.step, "bench-compare")) {
            run.addArgs(&.{ "--zig", b.graph.zig_exe, "--repository", b.pathFromRoot(".") });
        }
        if (b.args) |arguments| run.addArgs(arguments);
        forwardStep(b, core, forwarded.step).dependOn(&run.step);
    }

    addStepInEveryPackage(b, "test-all", "test", "Run every package's tests, each in its own directory");
    addStepInEveryPackage(b, "check-all", "check", "Type-check every package for the selected target, each in its own directory");

    const formatted_paths = [_][]const u8{ "build.zig", "build.zig.zon" } ++ packages;
    var excluded_paths: [2 * packages.len + generated_sources.len][]const u8 = undefined;
    for (packages, 0..) |package, index| {
        excluded_paths[2 * index] = b.pathJoin(&.{ package, "zig-out" });
        excluded_paths[2 * index + 1] = b.pathJoin(&.{ package, "zig-pkg" });
    }
    @memcpy(excluded_paths[2 * packages.len ..], &generated_sources);
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = &formatted_paths, .exclude_paths = &excluded_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = &formatted_paths, .exclude_paths = &excluded_paths, .check = true }).step);
}

fn forwardStep(b: *std.Build, core: *std.Build.Dependency, name: []const u8) *std.Build.Step {
    return b.step(name, core.builder.top_level_steps.get(name).?.description);
}

/// Runs `zig build <package_step>` in each package's directory as a process
/// of its own, so no package is fetched or configured until the step runs.
fn addStepInEveryPackage(b: *std.Build, name: []const u8, package_step: []const u8, description: []const u8) void {
    const step = b.step(name, description);
    for (packages) |package| {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", package_step });
        for ([_][]const u8{ "target", "cpu", "optimize" }) |option| {
            const given = b.user_input_options.get(option) orelse continue;
            if (given.value == .scalar) run.addArg(b.fmt("-D{s}={s}", .{ option, given.value.scalar }));
        }
        run.setCwd(b.path(package));
        run.setName(b.fmt("zig build {s} in {s}", .{ package_step, package }));
        step.dependOn(&run.step);
    }
}

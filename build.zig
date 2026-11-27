const std = @import("std");

/// Every package directory: `test-all` and `check-all` run in each, and
/// `fmt` formats each.
const packages = [_][]const u8{
    "core",
    "text/glyphs",
    "text/fonts",
    "text/truetype",
    "apps/tour",
    "apps/test_card",
    "themes",
    "examples",
    "examples/template",
    "renderers/terminal",
    "renderers/raylib",
    "renderers/sokol",
    "renderers/webgl",
    "hosts/native",
    "hosts/web",
};

/// Packages that do not build on core, and so take none of its options.
const packages_without_core = [_][]const u8{ "text/glyphs", "text/fonts" };

/// Core's options that every package on core declares and passes on.
const core_options = [_][]const u8{ "zui-debug", "zui-sanitize-thread", "zui-tracy" };

/// Checked in as sokol-shdc writes them, so formatting leaves them alone.
const generated_sources = [_][]const u8{
    "renderers/sokol/src/material.glsl.zig",
    "renderers/sokol/src/linear_light.glsl.zig",
    "renderers/sokol/src/present_scrgb.glsl.zig",
};

const core_modules = [_][]const u8{ "zui", "zui_testing", "zui_widgets", "zui_widgets_data", "zui_async", "zui_tracy", "zui_reflect", "zui_app", "zui_wire", "zui_debug", "zui_motion", "zui_color", "zui_design", "zui_icons" };

/// Packages with no third-party library, whose module of the same name the
/// aggregator re-exports. One that links a C library is reached through
/// `zui.builder.dependency`, so a user fetches only the libraries they use.
const pure_zig_packages = [_][]const u8{ "zui_glyphs", "zui_fonts" };

/// Pure-Zig packages built on core, re-exported with the options core is
/// given, so that their `zui` is the one the aggregator re-exports.
const pure_zig_packages_on_core = [_][]const u8{ "zui_tour", "zui_test_card" };

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
    // Passed on only when given: core instantiated with different options is a second `zui` module, whose types match no one else's.
    const sanitize_thread = b.option(bool, "zui-sanitize-thread", "Build zui and its modules with ThreadSanitizer, through LLVM (Linux)");
    const debug = b.option(bool, "zui-debug", "Keep id names for diagnostics");
    const tracy = b.option(bool, "zui-tracy", "Link Tracy's client, so zui_tracy.Tracer traces into the Tracy profiler");
    const core = b.dependency("zui_core", .{
        .target = target,
        .optimize = optimize,
        .@"zui-sanitize-thread" = sanitize_thread,
        .@"zui-debug" = debug,
        .@"zui-tracy" = tracy,
        .@"bench-layout-seed" = b.option(u64, "bench-layout-seed", "Move every function of the benchmark by a seed-chosen offset, as bench-compare's layouts do"),
    });
    for (core_modules) |name| b.modules.put(b.graph.arena, name, core.module(name)) catch @panic("OOM");
    for (pure_zig_packages) |name| {
        b.modules.put(b.graph.arena, name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name)) catch @panic("OOM");
    }
    for (pure_zig_packages_on_core) |name| {
        b.modules.put(b.graph.arena, name, b.dependency(name, .{ .target = target, .optimize = optimize, .@"zui-sanitize-thread" = sanitize_thread, .@"zui-debug" = debug, .@"zui-tracy" = tracy }).module(name)) catch @panic("OOM");
    }

    for ([_][]const u8{ "test", "test-unit", "test-unit-1", "test-unit-2", "test-compile-errors", "check-bench-tools", "check" }) |name| forwardStep(b, core, name).dependOn(&core.builder.top_level_steps.get(name).?.step);
    b.top_level_steps.get("check").?.step.dependOn(&reexportsCheck(b, target, optimize).step);
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

    const hooks = b.step("hooks", "Have git run the hooks in .githooks: format and syntax checks before a commit, CI's jobs before a push; and blame skip the commits in .git-blame-ignore-revs");
    for ([_][2][]const u8{ .{ "core.hooksPath", ".githooks" }, .{ "blame.ignoreRevsFile", ".git-blame-ignore-revs" } }) |setting| {
        const set_git_config = b.addSystemCommand(&.{ "git", "config", setting[0], setting[1] });
        set_git_config.setCwd(b.path("."));
        hooks.dependOn(&set_git_config.step);
    }

    const local_ci = b.addSystemCommand(&.{ "uv", "run", "--quiet", "--script" });
    local_ci.addFileArg(b.path("tools/ci/local_ci.py"));
    if (b.args) |arguments| local_ci.addArgs(arguments);
    local_ci.setCwd(b.path("."));
    local_ci.has_side_effects = true;
    b.step("ci", "Run CI's jobs for what HEAD changes since its upstream, here: Linux's in a container, Windows' and macOS' as cross-checks (`-- --help`)").dependOn(&local_ci.step);

    const formatted_paths = [_][]const u8{ "build.zig", "build.zig.zon", "tests" } ++ packages;
    var excluded_paths: [2 * packages.len + generated_sources.len][]const u8 = undefined;
    for (packages, 0..) |package, index| {
        excluded_paths[2 * index] = b.pathJoin(&.{ package, "zig-out" });
        excluded_paths[2 * index + 1] = b.pathJoin(&.{ package, "zig-pkg" });
    }
    @memcpy(excluded_paths[2 * packages.len ..], &generated_sources);
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = &formatted_paths, .exclude_paths = &excluded_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = &formatted_paths, .exclude_paths = &excluded_paths, .check = true }).step);
    b.step("fmt-md", "Format every Markdown file with mdformat, through uv").dependOn(&markdownFormatter(b, .format).step);
    b.step("fmt-md-check", "Fail if any Markdown file is not formatted").dependOn(&markdownFormatter(b, .check).step);
}

/// Runs mdformat with the plugin and pinned versions in `tools/mdformat/`,
/// over every Markdown file `.mdformat.toml` does not exclude.
fn markdownFormatter(b: *std.Build, mode: enum { format, check }) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "uvx", "--quiet", "--from" });
    run.addDirectoryArg(b.path("tools/mdformat"));
    run.addArg("mdformat-zui");
    if (mode == .check) run.addArg("--check");
    run.addArg(".");
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

/// Compiles one module that imports core's `zui` and the apps through the
/// aggregator, so `check` fails when an app is built on a second `zui`.
fn reexportsCheck(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .root_source_file = b.path("tests/reexports.zig"), .target = target, .optimize = optimize });
    for ([_][]const u8{ "zui", "zui_app" } ++ pure_zig_packages_on_core) |name| module.addImport(name, b.modules.get(name).?);
    return b.addObject(.{ .name = "zui-reexports", .root_module = module });
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
        const builds_on_core = for (packages_without_core) |without| {
            if (std.mem.eql(u8, package, without)) break false;
        } else true;
        for ([_][]const u8{ "target", "cpu", "optimize" } ++ core_options) |option| {
            if (!builds_on_core and std.mem.startsWith(u8, option, "zui-")) continue;
            const given = b.user_input_options.get(option) orelse continue;
            if (given.value == .scalar) run.addArg(b.fmt("-D{s}={s}", .{ option, given.value.scalar }));
        }
        run.setCwd(b.path(package));
        run.setName(b.fmt("zig build {s} in {s}", .{ package_step, package }));
        step.dependOn(&run.step);
    }
}

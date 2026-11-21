const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);

    const core = b.dependency("zui_core", core_options.on(target, optimize));
    const zui_module = core.module("zui");
    const zui_testing_module = core.module("zui_testing");
    const zui_glyphs_module = b.dependency("zui_glyphs", .{ .target = target, .optimize = optimize }).module("zui_glyphs");
    const zui_app_module = core.module("zui_app");

    const backend_module = b.addModule("zui_terminal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_glyphs", .module = zui_glyphs_module },
        },
    });

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_glyphs", .module = zui_glyphs_module },
            .{ .name = "zui_testing", .module = zui_testing_module },
        },
    });
    const unit_tests = b.addTest(.{ .root_module = test_module });
    const test_step = b.step("test", "Run the backend's unit tests and zui's renderer suite");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const conformance_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui_terminal", .module = backend_module },
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_testing", .module = zui_testing_module },
            .{ .name = "zui_app", .module = zui_app_module },
        },
    }) });
    const run_conformance = b.addRunArtifact(conformance_tests);
    b.step("conformance", "Run zui's renderer suite against the renderer").dependOn(&run_conformance.step);
    test_step.dependOn(&run_conformance.step);

    const check_step = b.step("check", "Compile the backend and the targets without producing output");
    check_step.dependOn(&unit_tests.step);
    const tour_step = b.step("tour", "Run zui's tour in this terminal (Ctrl+C or Ctrl+Q quits); --dump --screen <name> prints a screen's glyphs");
    const showcase_step = b.step("showcase", "Run zui's showcase in this terminal (Ctrl+C or Ctrl+Q quits); --dump prints its glyphs");
    // Until stb is fetched, the font system the targets name declares no
    // module.
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;
    const target_imports: []const std.Build.Module.Import = &.{
        .{ .name = "zui_terminal", .module = backend_module },
        .{ .name = "zui", .module = zui_module },
        .{ .name = "zui_app", .module = zui_app_module },
        .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
        .{ .name = "zui_tour", .module = b.dependency("zui_tour", core_options.on(target, optimize)).module("zui_tour") },
        .{ .name = "zui_showcase", .module = b.dependency("zui_showcase", core_options.on(target, optimize)).module("zui_showcase") },
    };
    for ([_]struct { name: []const u8, step: *std.Build.Step }{ .{ .name = "tour", .step = tour_step }, .{ .name = "showcase", .step = showcase_step } }) |app| {
        const executable = b.addExecutable(.{
            .name = b.fmt("zui-terminal-{s}", .{app.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{app.name})),
                .target = target,
                .optimize = optimize,
                .imports = target_imports,
            }),
        });
        b.installArtifact(executable);
        check_step.dependOn(&executable.step);
        const run = b.addRunArtifact(executable);
        run.stdio = .inherit;
        if (b.args) |arguments| run.addArgs(arguments);
        app.step.dependOn(&run.step);
    }
}

/// The font system the targets name, once it has declared its module:
/// until stb is fetched it returns from `build()` before declaring it.
fn truetypeDeclaring(b: *std.Build, args: anytype) ?*std.Build.Dependency {
    const dependency = b.dependency("zui_truetype", args);
    return if (dependency.builder.modules.contains("zui_truetype")) dependency else null;
}

/// Core's options as the package depending on this one gave them, each
/// passed on only when given: core instantiated with other options is a
/// second `zui` module, whose types match no one else's.
const CoreOptions = struct {
    debug: ?bool,
    sanitize_thread: ?bool,
    tracy: ?bool,

    fn declare(b: *std.Build) CoreOptions {
        return .{
            .debug = b.option(bool, "zui-debug", "Keep id names for diagnostics, as core does"),
            .sanitize_thread = b.option(bool, "zui-sanitize-thread", "Build zui and its modules with ThreadSanitizer, through LLVM (Linux)"),
            .tracy = b.option(bool, "zui-tracy", "Link Tracy's client into zui, so zui_tracy.Tracer traces into the Tracy profiler"),
        };
    }

    /// `b.dependency`'s arguments for a package on core.
    fn on(options: CoreOptions, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) DependencyArguments {
        return .{ .target = target, .optimize = optimize, .@"zui-debug" = options.debug, .@"zui-sanitize-thread" = options.sanitize_thread, .@"zui-tracy" = options.tracy };
    }

    const DependencyArguments = struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        @"zui-debug": ?bool,
        @"zui-sanitize-thread": ?bool,
        @"zui-tracy": ?bool,
    };
};

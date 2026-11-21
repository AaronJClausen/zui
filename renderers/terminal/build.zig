const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);

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

    const demo = b.addExecutable(.{
        .name = "zui-terminal-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_terminal", .module = backend_module },
                .{ .name = "zui", .module = zui_module },
                .{ .name = "zui_app", .module = zui_app_module },
                .{ .name = "zui_widgets", .module = core.module("zui_widgets") },
                .{ .name = "zui_showcase", .module = b.dependency("zui_showcase", core_options.on(target, optimize)).module("zui_showcase") },
            },
        }),
    });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    run_demo.stdio = .inherit;
    if (b.args) |arguments| run_demo.addArgs(arguments);
    b.step("demo", "Run the demo in this terminal (Ctrl+C or Ctrl+Q quits)").dependOn(&run_demo.step);

    b.step("check", "Compile the backend and the demo without producing output").dependOn(&demo.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
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

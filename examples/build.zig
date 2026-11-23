const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);

    const core = b.dependency("zui_core", core_options.on(target, optimize));

    const test_step = b.step("test", "Run the samples' tests");
    const check_step = b.step("check", "Compile the samples' tests without running them");
    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "samples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);

    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;
    const sample_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("samples/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = core.module("zui") },
            .{ .name = "zui_icons", .module = core.module("zui_icons") },
            .{ .name = "zui_fonts", .module = b.dependency("zui_fonts", .{ .target = target, .optimize = optimize }).module("zui_fonts") },
            .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(sample_tests).step);
    check_step.dependOn(&sample_tests.step);
}

/// The font system the samples draw with, once it has declared its
/// module: until stb is fetched it returns from `build()` before
/// declaring it.
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

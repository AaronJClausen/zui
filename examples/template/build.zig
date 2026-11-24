const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zui_arguments = CoreOptions.declare(b).on(target, optimize);

    const run_step = b.step("run", "Open the app's window (`-- --frames 120` closes it after 120 frames)");
    const test_step = b.step("test", "Run the app's tests, headless");
    const check_step = b.step("check", "Compile the app and its tests without running them");
    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);

    const zui = b.dependency("zui", zui_arguments);
    const zui_truetype = declaring(zui.builder.dependency("zui_truetype", zui_arguments), "zui_truetype") orelse return;

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui.module("zui") },
            .{ .name = "zui_testing", .module = zui.module("zui_testing") },
            .{ .name = "zui_design", .module = zui.module("zui_design") },
            .{ .name = "zui_widgets", .module = zui.module("zui_widgets") },
            .{ .name = "zui_fonts", .module = zui.module("zui_fonts") },
            .{ .name = "zui_truetype", .module = zui_truetype.module("zui_truetype") },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check_step.dependOn(&tests.step);

    switch (target.result.os.tag) {
        .windows, .linux => {},
        else => {
            run_step.dependOn(&b.addFail("zui_host opens windows on Windows and Linux only").step);
            return;
        },
    }
    const zui_sokol = declaring(zui.builder.dependency("zui_sokol", zui_arguments), "zui_sokol") orelse return;
    const zui_host = zui.builder.dependency("zui_host", zui_arguments);

    const app = b.addExecutable(.{
        .name = "zui-template",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui", .module = zui.module("zui") },
                .{ .name = "zui_app", .module = zui.module("zui_app") },
                .{ .name = "zui_design", .module = zui.module("zui_design") },
                .{ .name = "zui_widgets", .module = zui.module("zui_widgets") },
                .{ .name = "zui_fonts", .module = zui.module("zui_fonts") },
                .{ .name = "zui_truetype", .module = zui_truetype.module("zui_truetype") },
                .{ .name = "zui_sokol", .module = zui_sokol.module("zui_sokol") },
                .{ .name = "zui_host", .module = zui_host.module("zui_host") },
            },
        }),
    });
    linkThroughLlvmOnLinux(app);
    b.installArtifact(app);
    const run_app = b.addRunArtifact(app);
    if (b.args) |arguments| run_app.addArgs(arguments);
    run_step.dependOn(&run_app.step);
    check_step.dependOn(&app.step);
}

/// A package whose own libraries are lazy declares its module only once
/// they are fetched, and asking for a module it lacks panics.
fn declaring(dependency: *std.Build.Dependency, module_name: []const u8) ?*std.Build.Dependency {
    return if (dependency.builder.modules.contains(module_name)) dependency else null;
}

/// Zig 0.16's own ELF linker rejects the R_X86_64_PC64 relocations in the
/// `.sframe` section that GCC 16's crt1.o carries, and LLD crashes the
/// compiler unless the LLVM backend produced the objects.
fn linkThroughLlvmOnLinux(compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().os.tag == .linux) {
        compile.use_llvm = true;
        compile.use_lld = true;
    }
}

/// zui's options, each passed on only when given: zui built with other
/// options is a second `zui` module, whose types match no one else's.
const CoreOptions = struct {
    debug: ?bool,
    sanitize_thread: ?bool,
    tracy: ?bool,

    fn declare(b: *std.Build) CoreOptions {
        return .{
            .debug = b.option(bool, "zui-debug", "Keep id names for diagnostics"),
            .sanitize_thread = b.option(bool, "zui-sanitize-thread", "Build zui and its modules with ThreadSanitizer, through LLVM (Linux)"),
            .tracy = b.option(bool, "zui-tracy", "Link Tracy's client into zui, so zui_tracy.Tracer traces into the Tracy profiler"),
        };
    }

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

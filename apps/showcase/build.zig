const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);

    const showcase_module = b.addModule("zui_showcase", showcaseModuleOptions(b, target, optimize, core_options));
    const unit_tests = b.addTest(.{ .root_module = showcase_module });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const browser_tests = b.addTest(.{
        .name = "zui-showcase-freestanding",
        .root_module = b.createModule(showcaseModuleOptions(b, browser_target, optimize, core_options)),
        .test_runner = .{ .path = b.path("freestanding_test_runner.zig"), .mode = .simple },
    });
    browser_tests.entry = .disabled;
    browser_tests.rdynamic = true;
    const check_step = b.step("check", "Compile the unit tests, natively and for wasm32-freestanding, without running them");
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&browser_tests.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "zui_showcase.zig", "freestanding_test_runner.zig" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

fn showcaseModuleOptions(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions) std.Build.Module.CreateOptions {
    const core = b.dependency("zui_core", core_options.on(target, optimize));
    const imports = b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "zui", .module = core.module("zui") },
        .{ .name = "zui_widgets", .module = core.module("zui_widgets") },
    }) catch @panic("out of memory");
    return .{ .root_source_file = b.path("zui_showcase.zig"), .target = target, .optimize = optimize, .imports = imports };
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

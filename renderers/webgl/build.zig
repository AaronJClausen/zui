const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);

    const webgl_module = b.addModule("zui_webgl", webglModuleOptions(b, target, optimize));
    const unit_tests = b.addTest(.{ .root_module = webgl_module });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const browser_tests = b.addTest(.{
        .name = "zui-webgl-browser",
        .root_module = b.createModule(webglModuleOptions(b, browser_target, optimize)),
        .test_runner = .{ .path = b.path("src/freestanding_test_runner.zig"), .mode = .simple },
    });
    browser_tests.entry = .disabled;
    browser_tests.rdynamic = true;
    const check_step = b.step("check", "Compile the unit tests, natively and for wasm32-freestanding, without running them");
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&browser_tests.step);
}

fn webglModuleOptions(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) std.Build.Module.CreateOptions {
    const imports = b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "zui", .module = b.dependency("zui_core", .{ .target = target, .optimize = optimize }).module("zui") },
        .{ .name = "zui_glyphs", .module = b.dependency("zui_glyphs", .{ .target = target, .optimize = optimize }).module("zui_glyphs") },
    }) catch @panic("out of memory");
    return .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .imports = imports };
}

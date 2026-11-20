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

/// Until stb is fetched, the module is declared without it, so that a
/// package depending on this one still configures, and asks for stb too.
fn webglModuleOptions(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) std.Build.Module.CreateOptions {
    const zui_core = b.dependency("zui_core", .{ .target = target, .optimize = optimize });
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    imports.append(b.allocator, .{ .name = "zui", .module = zui_core.module("zui") }) catch @panic("out of memory");
    if (b.lazyDependency("stb", .{})) |stb_dependency| {
        imports.append(b.allocator, .{ .name = "stb_truetype", .module = stbTruetypeModule(b, stb_dependency, target, optimize) }) catch @panic("out of memory");
    }
    return .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .imports = imports.items };
}

/// stb_truetype's declarations, translated to Zig, with its implementation
/// compiled in without a C library, at the commit the sokol renderer
/// rasterizes with.
fn stbTruetypeModule(b: *std.Build, stb_dependency: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const translated = b.addTranslateC(.{
        .root_source_file = stb_dependency.path("stb_truetype.h"),
        .target = target,
        .optimize = optimize,
    });
    const module = translated.createModule();
    module.link_libc = false;
    module.addCSourceFile(.{ .file = b.path("src/stb_truetype.c"), .flags = &.{"-fvisibility=hidden"} });
    module.addIncludePath(stb_dependency.path(""));
    return module;
}

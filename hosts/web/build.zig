const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const web_module = webModule(b, "src/root.zig", target, optimize);
    const unit_tests = b.addTest(.{ .root_module = web_module });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const browser_check = b.addObject(.{
        .name = "browser_check",
        .root_module = webModule(b, "src/browser_check.zig", browser_target, optimize),
    });
    const check_step = b.step("check", "Compile the unit tests, and zui for the browser, without running them");
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&browser_check.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

fn webModule(b: *std.Build, root_source_file: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize });
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui_dependency.module("zui") }},
    });
}

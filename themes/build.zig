const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize });

    const themes_module = b.addModule("zui_themes", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui_dependency.module("zui") }},
    });

    const unit_tests = b.addTest(.{ .root_module = themes_module });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(unit_tests).step);
    b.step("check", "Compile the unit tests without running them").dependOn(&unit_tests.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

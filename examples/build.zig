const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize });

    const sample_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("samples/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui_dependency.module("zui") }},
    }) });
    b.step("test", "Run the samples' tests").dependOn(&b.addRunArtifact(sample_tests).step);
    b.step("check", "Compile the samples' tests without running them").dependOn(&sample_tests.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "samples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

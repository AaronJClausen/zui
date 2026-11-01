const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zui_module = b.addModule("zui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{ .root_module = zui_module });
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // A static library is only built so its documentation can be emitted;
    // consumers import the module above, not this artifact.
    const docs_library = b.addLibrary(.{ .name = "zui", .root_module = zui_module, .linkage = .static });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation into zig-out/docs").dependOn(&install_docs.step);

    // Nothing requests this artifact's outputs, so compiling it emits no
    // files: a fast feedback loop for editors (ZLS build-on-save) and for
    // cross-target CI.
    const check_library = b.addLibrary(.{ .name = "zui", .root_module = zui_module, .linkage = .static });
    b.step("check", "Type-check the library for the selected target").dependOn(&check_library.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fonts_module = b.addModule("zui_fonts", .{ .root_source_file = b.path("zui_fonts.zig"), .target = target, .optimize = optimize });
    const unit_tests = b.addTest(.{ .root_module = fonts_module });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const browser_tests = b.addTest(.{
        .name = "zui-fonts-freestanding",
        .root_module = b.createModule(.{ .root_source_file = b.path("zui_fonts.zig"), .target = browser_target, .optimize = optimize }),
        .test_runner = .{ .path = b.path("freestanding_test_runner.zig"), .mode = .simple },
    });
    browser_tests.entry = .disabled;
    browser_tests.rdynamic = true;
    const check_step = b.step("check", "Compile the unit tests, natively and for wasm32-freestanding, without running them");
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&browser_tests.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "zui_fonts.zig", "freestanding_test_runner.zig" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

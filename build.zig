const std = @import("std");

/// Misuse that must fail to compile with zui's own message. The build
/// system matches the *end* of an error line, so each `expected_error` is a
/// complete message.
const compile_error_cases = [_]struct { name: []const u8, expected_error: []const u8 }{
    .{ .name = "state_slots_not_power_of_two", .expected_error = "zui: state_slots must be a power of two, got 1000" },
    .{ .name = "font_id_not_integer", .expected_error = "zui: FontId must be an integer or enum type, got f32" },
    .{ .name = "platform_missing_measure_text", .expected_error = "platform_missing_measure_text.Platform does not implement zui.Platform: missing `measureText`" },
    .{ .name = "platform_measure_text_wrong_signature", .expected_error = "platform_measure_text_wrong_signature.Platform.measureText must be fn (*platform_measure_text_wrong_signature.Platform, []const u8, u16, f32) [2]f32, found fn (*platform_measure_text_wrong_signature.Platform, []const u8, f32) [2]f32" },
    .{ .name = "platform_misspelled_hook", .expected_error = "platform_misspelled_hook.Platform declares `zuiWake`, which zui does not read; the optional hooks are `wake` and `scale`" },
    .{ .name = "ids_repeated_name", .expected_error = "zui.ids: \"save\" appears more than once" },
    .{ .name = "custom_without_custom_data", .expected_error = "zui: custom() needs Config.CustomData set to your payload type" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_options = b.addOptions();
    build_options.addOption(bool, "debug", b.option(bool, "zui-debug", "Keep id names for diagnostics") orelse false);

    const zui_module = b.addModule("zui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zui_module.addOptions("zui_options", build_options);

    const unit_tests = b.addTest(.{ .root_module = zui_module });
    const test_step = b.step("test", "Run the unit tests and the compile-error tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    for (compile_error_cases) |case| {
        const failing_object = b.addObject(.{
            .name = case.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/compile_errors/{s}.zig", .{case.name})),
                .target = target,
                .imports = &.{.{ .name = "zui", .module = zui_module }},
            }),
        });
        failing_object.expect_errors = .{ .contains = case.expected_error };
        test_step.dependOn(&failing_object.step);
    }

    // A static library is only built so its documentation can be emitted;
    // consumers import the module above, not this artifact.
    const docs_library = b.addLibrary(.{ .name = "zui", .root_module = zui_module, .linkage = .static });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation into zig-out/docs").dependOn(&install_docs.step);

    // Nothing requests this object's outputs, so compiling it emits no files:
    // a fast feedback loop for editors (ZLS build-on-save) and for
    // cross-target CI. It instantiates zui, because generic code is only
    // type-checked once instantiated.
    const check_object = b.addObject(.{
        .name = "zui_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/instantiate.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zui", .module = zui_module }},
        }),
    });
    b.step("check", "Type-check zui for the selected target").dependOn(&check_object.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

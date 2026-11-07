const std = @import("std");

/// Misuse that must fail to compile with zui's own message. The build
/// system matches the *end* of an error line, so each `expected_error` is a
/// complete message.
const compile_error_cases = [_]struct { name: []const u8, expected_error: []const u8 }{
    .{ .name = "state_slots_not_power_of_two", .expected_error = "zui: limits.state_slots must be a power of two, got 1000" },
    .{ .name = "font_id_not_integer", .expected_error = "zui: FontId must be an integer or enum type, got f32" },
    .{ .name = "text_missing_measure", .expected_error = "zui: text_missing_measure.Text does not implement zui.Text: missing `zuiMeasure`" },
    .{ .name = "text_measure_wrong_signature", .expected_error = "zui: text_measure_wrong_signature.Text.zuiMeasure must be fn (*text_measure_wrong_signature.Text, []const u8, style.MeasureKey(u16)) [2]f32, found fn (*text_measure_wrong_signature.Text, []const u8, u16, f32) [2]f32" },
    .{ .name = "text_unknown_declaration", .expected_error = "zui: text_unknown_declaration.Text declares unknown `zui_threadsafe`" },
    .{ .name = "text_thread_safe_not_bool", .expected_error = "zui: text_thread_safe_not_bool.Text.zui_thread_safe must be a bool, found comptime_int" },
    .{ .name = "text_without_text_contract", .expected_error = "zui: text() needs Config.Text set to a text contract" },
    .{ .name = "image_without_image_handle", .expected_error = "zui: image() needs Config.ImageHandle set to your image type" },
    .{ .name = "ids_repeated_name", .expected_error = "zui.ids: \"save\" appears more than once" },
    .{ .name = "custom_without_custom_data", .expected_error = "zui: custom() needs Config.CustomData set to your payload type" },
    .{ .name = "state_type_too_large", .expected_error = "zui: state type state_type_too_large.History is 80 bytes, but a state slot holds at most 64; store an index into your own storage instead" },
    .{ .name = "tracer_not_struct", .expected_error = "zui: Tracer must be a struct type, got u32" },
    .{ .name = "tracer_missing_end", .expected_error = "zui: tracer_missing_end.Tracer does not implement zui.Tracer: missing `zuiEnd`" },
    .{ .name = "tracer_begin_not_comptime", .expected_error = "zui: tracer_begin_not_comptime.Tracer.zuiBegin must be fn (comptime zone: zui.TraceZone) Span, found fn (trace.TraceZone) u32" },
    .{ .name = "tracer_end_wrong_signature", .expected_error = "zui: tracer_end_wrong_signature.Tracer.zuiEnd must be fn (u32) void, the span zuiBegin returns, found fn (u64) void" },
    .{ .name = "tracer_unknown_declaration", .expected_error = "zui: tracer_unknown_declaration.Tracer declares unknown `zuiFrameMark`" },
    .{ .name = "sources_not_struct", .expected_error = "zui: Sources must be a struct type, got u32" },
    .{ .name = "sources_field_not_source", .expected_error = "zui: sources_field_not_source.AppSources.count must be a struct type implementing zui.Source, got u32" },
    .{ .name = "sources_missing_swap", .expected_error = "zui: sources_missing_swap.AppSources.quotes does not implement zui.Source: missing `zuiSwap`" },
    .{ .name = "sources_missing_delivery", .expected_error = "zui: sources_missing_delivery.AppSources.quotes does not implement zui.Source: missing `Delivery`" },
    .{ .name = "sources_swap_wrong_signature", .expected_error = "zui: sources_swap_wrong_signature.AppSources.quotes.zuiSwap must be fn (*sources_swap_wrong_signature.Quotes) void, found fn (*const sources_swap_wrong_signature.Quotes) void" },
    .{ .name = "sources_pending_wrong_signature", .expected_error = "zui: sources_pending_wrong_signature.AppSources.quotes.zuiPending must be fn (*const sources_pending_wrong_signature.Quotes) bool, found fn (*sources_pending_wrong_signature.Quotes) bool" },
    .{ .name = "sources_unknown_declaration", .expected_error = "zui: sources_unknown_declaration.AppSources.quotes declares unknown `zuiPendng`" },
    .{ .name = "source_without_sources", .expected_error = "zui: source() needs Config.Sources set to a struct of sources" },
    .{ .name = "source_not_in_sources", .expected_error = "enum 'meta.FieldEnum(source_not_in_sources.AppSources)' has no member named 'quotez'" },
    .{ .name = "status_failed_on_infallible", .expected_error = "enum '@typeInfo(sources.StatusWithProgress(u32,void)).@\"union\".tag_type.?' has no member named 'failed'" },
    .{ .name = "status_missing_prong", .expected_error = "switch must handle all possibilities" },
    .{ .name = "widgets_slider_on_bool", .expected_error = "zui_widgets: slider needs a pointer to an integer or float, got *bool" },
    .{ .name = "reflect_misspelled_option", .expected_error = "no field named 'volum' in struct 'zui_reflect.FieldOptionsOf(reflect_misspelled_option.Settings)'" },
    .{ .name = "reflect_untyped_options", .expected_error = "; declare it as `pub const zui_inspector: zui_reflect.Options(@This())` so misspelled options fail to compile" },
    .{ .name = "reflect_unsupported_field", .expected_error = "zui_reflect: reflect_unsupported_field.Settings.on_change is *const fn () void, which the inspector cannot edit; hide it with `.fields.on_change = .{ .hidden = true }`" },
    .{ .name = "reflect_range_on_bool", .expected_error = "zui_reflect: reflect_range_on_bool.Settings.fullscreen is bool; min, max and step only apply to numbers" },
    .{ .name = "reflect_min_above_max", .expected_error = "zui_reflect: reflect_min_above_max.Settings.max_fps has min 240 above max 30" },
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

    // Each optional module sits in its own directory and can only reach
    // zui through @import("zui"), so the compiler holds them to the public API.
    const testing_module = b.addModule("zui_testing", .{
        .root_source_file = b.path("zui_testing/zui_testing.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });
    const widgets_module = b.addModule("zui_widgets", .{
        .root_source_file = b.path("zui_widgets/zui_widgets.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });
    const tracy_enabled = b.option(bool, "zui-tracy", "Link Tracy's client, so zui_tracy.Tracer traces into the Tracy profiler") orelse false;
    const tracy_options = b.addOptions();
    tracy_options.addOption(bool, "enabled", tracy_enabled);
    const tracy_module = b.addModule("zui_tracy", .{
        .root_source_file = b.path("zui_tracy/zui_tracy.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_tracy_options", .module = tracy_options.createModule() },
        },
    });
    if (tracy_enabled) linkTracy(b, tracy_module);
    const reflect_module = b.addModule("zui_reflect", .{
        .root_source_file = b.path("zui_reflect/zui_reflect.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_widgets", .module = widgets_module },
        },
    });

    const test_step = b.step("test", "Run the unit tests and the compile-error tests");
    const tested_modules = [_]*std.Build.Module{ zui_module, testing_module, widgets_module, reflect_module, tracy_module };
    for (tested_modules) |tested_module| {
        const module_tests = b.addTest(.{ .root_module = tested_module });
        test_step.dependOn(&b.addRunArtifact(module_tests).step);
    }
    for ([_]*std.Build.Module{ widgets_module, reflect_module, tracy_module }) |module_with_driven_tests| {
        module_with_driven_tests.addImport("zui_testing", testing_module);
    }

    for (compile_error_cases) |case| {
        const failing_object = b.addObject(.{
            .name = case.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/compile_errors/{s}.zig", .{case.name})),
                .target = target,
                .imports = &.{
                    .{ .name = "zui", .module = zui_module },
                    .{ .name = "zui_widgets", .module = widgets_module },
                    .{ .name = "zui_reflect", .module = reflect_module },
                },
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
            .imports = &.{
                .{ .name = "zui", .module = zui_module },
                .{ .name = "zui_testing", .module = testing_module },
                .{ .name = "zui_widgets", .module = widgets_module },
                .{ .name = "zui_reflect", .module = reflect_module },
                .{ .name = "zui_tracy", .module = tracy_module },
            },
        }),
    });
    b.step("check", "Type-check zui for the selected target").dependOn(&check_object.step);

    const bench_executable = b.addExecutable(.{
        .name = "zui-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zui", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "zui_options", .module = build_options.createModule() }},
            }) }},
        }),
    });
    const run_bench = b.addRunArtifact(bench_executable);
    if (b.args) |arguments| run_bench.addArgs(arguments);
    b.step("bench", "Run the benchmarks in ReleaseFast").dependOn(&run_bench.step);

    // A fixed CPU model and no libc, so every runner executes the same
    // instructions; Valgrind supports every extension of x86-64-v3.
    const counts_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
    });
    const counts_executable = b.addExecutable(.{
        .name = "zui-counts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/counts.zig"),
            .target = counts_target,
            .optimize = .ReleaseFast,
            .valgrind = true,
            .imports = &.{.{ .name = "zui", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = counts_target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "zui_options", .module = build_options.createModule() }},
            }) }},
        }),
    });
    const run_counts = b.addRunArtifact(counts_executable);
    if (b.args) |arguments| run_counts.addArgs(arguments);
    b.step("counts", "Count each scenario's instructions per frame under Callgrind (x86_64 Linux with Valgrind)").dependOn(&run_counts.step);
    test_step.dependOn(&counts_executable.step);

    const bench_compare_executable = b.addExecutable(.{
        .name = "zui-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/compare.zig"),
            .target = b.graph.host,
        }),
    });
    const run_bench_compare = b.addRunArtifact(bench_compare_executable);
    run_bench_compare.addArgs(&.{ "--zig", b.graph.zig_exe, "--repository", b.pathFromRoot(".") });
    if (b.args) |arguments| run_bench_compare.addArgs(arguments);
    b.step("bench-compare", "Alternate the benchmarks of two commits: -- <base> [<head>] [--rounds <count>]").dependOn(&run_bench_compare.step);
    test_step.dependOn(&bench_compare_executable.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "tests", "bench", "zui_testing", "zui_widgets", "zui_reflect", "zui_tracy" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

/// Tracy is a lazy dependency, fetched only by a build that asks for it.
fn linkTracy(b: *std.Build, tracy_module: *std.Build.Module) void {
    const tracy = b.lazyDependency("tracy", .{}) orelse return;
    const windows = tracy_module.resolved_target.?.result.os.tag == .windows;
    // With callstacks, a MinGW build's process exits with code 9 after
    // Tracy shuts down. zui's zones collect no callstacks.
    const flags: []const []const u8 = if (windows)
        &.{ "-DTRACY_ENABLE", "-DTRACY_NO_CALLSTACK" }
    else
        &.{"-DTRACY_ENABLE"};
    tracy_module.addCSourceFile(.{ .file = tracy.path("public/TracyClient.cpp"), .flags = flags });
    tracy_module.link_libcpp = true;
    if (windows) {
        for ([_][]const u8{ "ws2_32", "dbghelp", "advapi32", "user32", "secur32" }) |library| tracy_module.linkSystemLibrary(library, .{});
    }
}

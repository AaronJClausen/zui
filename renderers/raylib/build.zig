const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Passed on only when given: core instantiated with different options is a second `zui` module, whose types match no one else's.
    const tracy = b.option(bool, "zui-tracy", "Link Tracy's client, so the demo traces zui's zones into the Tracy profiler");

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);

    const core = b.dependency("zui_core", .{ .target = target, .optimize = optimize, .@"zui-tracy" = tracy });
    const raylib_dependency = b.lazyDependency("raylib", .{ .target = target, .optimize = optimize }) orelse return;
    const truetype_dependency = truetypeDeclaring(b, .{ .target = target, .optimize = optimize, .@"zui-tracy" = tracy }) orelse return;
    const zui_module = core.module("zui");
    const zui_app_module = core.module("zui_app");
    const zui_glyphs_module = b.dependency("zui_glyphs", .{ .target = target, .optimize = optimize }).module("zui_glyphs");
    const zui_truetype_module = truetype_dependency.module("zui_truetype");

    const backend_module = b.addModule("zui_raylib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_app", .module = zui_app_module },
            .{ .name = "zui_glyphs", .module = zui_glyphs_module },
            .{ .name = "raylib", .module = raylib_dependency.module("raylib") },
            .{ .name = "rlgl", .module = raylib_dependency.module("rlgl") },
        },
    });

    moveSystemLibrariesOntoModule(raylib_dependency.artifact("raylib"), backend_module);

    const backend_tests = b.addTest(.{ .root_module = backend_module });
    linkThroughLlvmOnLinux(backend_tests);
    b.step("test", "Run the backend's unit tests").dependOn(&b.addRunArtifact(backend_tests).step);

    // Needs a display, which `test` does not: on Linux CI it runs under Xvfb.
    const conformance_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui_raylib", .module = backend_module },
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_app", .module = zui_app_module },
            .{ .name = "zui_testing", .module = core.module("zui_testing") },
            .{ .name = "zui_truetype", .module = zui_truetype_module },
        },
    }) });
    linkThroughLlvmOnLinux(conformance_tests);
    b.step("conformance", "Run zui's renderer and host suites against the renderer and the host, in hidden windows").dependOn(&b.addRunArtifact(conformance_tests).step);

    const demo_imports: []const std.Build.Module.Import = &.{
        .{ .name = "zui_raylib", .module = backend_module },
        .{ .name = "zui", .module = zui_module },
        .{ .name = "zui_app", .module = zui_app_module },
        .{ .name = "zui_widgets", .module = core.module("zui_widgets") },
        .{ .name = "zui_reflect", .module = core.module("zui_reflect") },
        .{ .name = "zui_async", .module = core.module("zui_async") },
        .{ .name = "zui_tracy", .module = core.module("zui_tracy") },
        .{ .name = "zui_debug", .module = core.module("zui_debug") },
        .{ .name = "zui_glyphs", .module = zui_glyphs_module },
        .{ .name = "zui_truetype", .module = zui_truetype_module },
        .{ .name = "zui_fonts", .module = b.dependency("zui_fonts", .{ .target = target, .optimize = optimize }).module("zui_fonts") },
    };
    const demo = b.addExecutable(.{
        .name = "zui-demo",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/demo.zig"), .target = target, .optimize = optimize, .imports = demo_imports }),
    });
    if (target.result.os.tag == .windows) demo.subsystem = .windows;
    linkThroughLlvmOnLinux(demo);
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |arguments| run_demo.addArgs(arguments);
    b.step("demo", "Run the tour (`-- --frames 900 --cycle 40` visits every screen and quits)").dependOn(&run_demo.step);

    const tour_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("examples/tour_test.zig"), .target = target, .optimize = optimize, .imports = demo_imports }) });
    linkThroughLlvmOnLinux(tour_tests);
    b.step("test-tour", "Declare every screen of the tour headlessly; fail if one exceeds its limits or does not fit the default window").dependOn(&b.addRunArtifact(tour_tests).step);

    const check_step = b.step("check", "Compile the backend, the tour, its tests and the renderer suite without producing output");
    check_step.dependOn(&demo.step);
    check_step.dependOn(&tour_tests.step);
    check_step.dependOn(&conformance_tests.step);
}

/// The font system the tour and the renderer suite measure with, once it
/// has declared its module: until stb is fetched it returns from `build()`
/// before declaring it.
fn truetypeDeclaring(b: *std.Build, args: anytype) ?*std.Build.Dependency {
    const dependency = b.dependency("zui_truetype", args);
    return if (dependency.builder.modules.contains("zui_truetype")) dependency else null;
}

/// Zig 0.16's own ELF linker rejects the R_X86_64_PC64 relocations in the
/// `.sframe` section that GCC 16's crt1.o carries, and LLD crashes the
/// compiler unless the LLVM backend produced the objects.
fn linkThroughLlvmOnLinux(compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().os.tag == .linux) {
        compile.use_llvm = true;
        compile.use_lld = true;
    }
}

/// Zig archives the shared libraries a static library links (raylib's GL
/// and X11) into it, and LLD's warning about those members fails the
/// link. Linked from `module` instead, they reach every artifact that
/// imports it and stay out of the archive.
fn moveSystemLibrariesOntoModule(library: *std.Build.Step.Compile, module: *std.Build.Module) void {
    const link_objects = &library.root_module.link_objects;
    var index: usize = 0;
    while (index < link_objects.items.len) {
        switch (link_objects.items[index]) {
            .system_lib => |system_library| {
                module.linkSystemLibrary(system_library.name, .{});
                _ = link_objects.orderedRemove(index);
            },
            else => index += 1,
        }
    }
}

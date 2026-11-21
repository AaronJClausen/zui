const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);

    const core = b.dependency("zui_core", core_options.on(target, optimize));
    const raylib_dependency = b.lazyDependency("raylib", .{ .target = target, .optimize = optimize }) orelse return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;
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

    const check_step = b.step("check", "Compile the backend, the targets and the renderer suite without producing output");
    check_step.dependOn(&backend_tests.step);
    check_step.dependOn(&conformance_tests.step);
    const target_imports: []const std.Build.Module.Import = &.{
        .{ .name = "zui_raylib", .module = backend_module },
        .{ .name = "zui", .module = zui_module },
        .{ .name = "zui_app", .module = zui_app_module },
        .{ .name = "zui_truetype", .module = zui_truetype_module },
        .{ .name = "zui_tour", .module = b.dependency("zui_tour", core_options.on(target, optimize)).module("zui_tour") },
        .{ .name = "zui_showcase", .module = b.dependency("zui_showcase", core_options.on(target, optimize)).module("zui_showcase") },
    };
    const apps = [_]struct { name: []const u8, description: []const u8 }{
        .{ .name = "tour", .description = "Run zui's tour (`-- --hidden --frames 600 --cycle 50` visits every screen and quits)" },
        .{ .name = "showcase", .description = "Run zui's showcase (`-- --hidden --frames 60` draws 60 frames and quits)" },
    };
    for (apps) |app| {
        const executable = b.addExecutable(.{
            .name = b.fmt("zui-raylib-{s}", .{app.name}),
            .root_module = b.createModule(.{ .root_source_file = b.path(b.fmt("examples/{s}.zig", .{app.name})), .target = target, .optimize = optimize, .imports = target_imports }),
        });
        if (target.result.os.tag == .windows) executable.subsystem = .windows;
        linkThroughLlvmOnLinux(executable);
        b.installArtifact(executable);
        check_step.dependOn(&executable.step);
        const run = b.addRunArtifact(executable);
        if (b.args) |arguments| run.addArgs(arguments);
        b.step(app.name, app.description).dependOn(&run.step);
    }
}

/// The font system the targets and the renderer suite measure with, once
/// it has declared its module: until stb is fetched it returns from `build()`
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

/// Core's options as the package depending on this one gave them, each
/// passed on only when given: core instantiated with other options is a
/// second `zui` module, whose types match no one else's.
const CoreOptions = struct {
    debug: ?bool,
    sanitize_thread: ?bool,
    tracy: ?bool,

    fn declare(b: *std.Build) CoreOptions {
        return .{
            .debug = b.option(bool, "zui-debug", "Keep id names for diagnostics, as core does"),
            .sanitize_thread = b.option(bool, "zui-sanitize-thread", "Build zui and its modules with ThreadSanitizer, through LLVM (Linux)"),
            .tracy = b.option(bool, "zui-tracy", "Link Tracy's client into zui, so zui_tracy.Tracer traces into the Tracy profiler"),
        };
    }

    /// `b.dependency`'s arguments for a package on core.
    fn on(options: CoreOptions, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) DependencyArguments {
        return .{ .target = target, .optimize = optimize, .@"zui-debug" = options.debug, .@"zui-sanitize-thread" = options.sanitize_thread, .@"zui-tracy" = options.tracy };
    }

    const DependencyArguments = struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        @"zui-debug": ?bool,
        @"zui-sanitize-thread": ?bool,
        @"zui-tracy": ?bool,
    };
};

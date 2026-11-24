const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);

    const core = b.dependency("zui_core", core_options.on(target, optimize));
    // The renderer presents and the host polls input, so raylib's
    // `EndDrawing` must do neither.
    const raylib_dependency = b.lazyDependency("raylib", .{ .target = target, .optimize = optimize, .config = "-DSUPPORT_CUSTOM_FRAME_CONTROL=1" }) orelse return;
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
    shareFrameworkPaths(raylib_dependency.artifact("raylib"), backend_module);

    const check: Check = .{ .step = b.step("check", "Compile the backend, the targets and the renderer suite without producing output"), .links = target.query.isNative() };

    b.step("test", "Run the backend's unit tests").dependOn(&b.addRunArtifact(addTest(b, backend_module)).step);
    check.compile(addTest(b, backend_module));

    // Needs a display, which `test` does not: on Linux CI it runs under Xvfb.
    const conformance_module = b.createModule(.{
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
    });
    b.step("conformance", "Run zui's renderer and host suites against the renderer and the host, in hidden windows").dependOn(&b.addRunArtifact(addTest(b, conformance_module)).step);
    check.compile(addTest(b, conformance_module));

    const tour_module = b.createModule(.{
        .root_source_file = b.path("examples/tour.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui_raylib", .module = backend_module },
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_app", .module = zui_app_module },
            .{ .name = "zui_truetype", .module = zui_truetype_module },
            .{ .name = "zui_tour", .module = b.dependency("zui_tour", core_options.on(target, optimize)).module("zui_tour") },
        },
    });
    const tour = addAppExecutable(b, "tour", tour_module);
    b.installArtifact(tour);
    check.compile(addAppExecutable(b, "tour", tour_module));
    const run_tour = b.addRunArtifact(tour);
    if (b.args) |arguments| run_tour.addArgs(arguments);
    b.step("tour", "Run zui's tour (`-- --hidden --frames 600 --cycle 50` visits every screen and quits)").dependOn(&run_tour.step);

    const test_card_module = b.createModule(.{
        .root_source_file = b.path("examples/test_card.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui_raylib", .module = backend_module },
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_app", .module = zui_app_module },
            .{ .name = "zui_truetype", .module = zui_truetype_module },
            .{ .name = "zui_test_card", .module = b.dependency("zui_test_card", core_options.on(target, optimize)).module("zui_test_card") },
        },
    });
    const test_card = addAppExecutable(b, "test-card", test_card_module);
    b.installArtifact(test_card);
    check.compile(addAppExecutable(b, "test-card", test_card_module));
    const run_test_card = b.addRunArtifact(test_card);
    if (b.args) |arguments| run_test_card.addArgs(arguments);
    b.step("test-card", "Run zui's test card (`-- --hidden --frames 6` draws every scene once and quits; `-- --screenshot <path> --scene <name>` saves one)").dependOn(&run_test_card.step);
}

/// `check` compiles its own copy of each artifact, which nothing else runs
/// or installs. For another target it asks for no binary, so the build only
/// analyses the code: linking would need that target's SDK, such as macOS's
/// frameworks.
const Check = struct {
    step: *std.Build.Step,
    links: bool,

    fn compile(check: Check, artifact: *std.Build.Step.Compile) void {
        if (check.links) _ = artifact.getEmittedBin();
        check.step.dependOn(&artifact.step);
    }
};

fn addTest(b: *std.Build, module: *std.Build.Module) *std.Build.Step.Compile {
    const tests = b.addTest(.{ .root_module = module });
    linkThroughLlvmOnLinux(tests);
    return tests;
}

fn addAppExecutable(b: *std.Build, app_name: []const u8, module: *std.Build.Module) *std.Build.Step.Compile {
    const executable = b.addExecutable(.{ .name = b.fmt("zui-raylib-{s}", .{app_name}), .root_module = module });
    if (module.resolved_target.?.result.os.tag == .windows) executable.subsystem = .windows;
    linkThroughLlvmOnLinux(executable);
    return executable;
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

/// raylib finds macOS's frameworks through `-iframework` paths of its own
/// when cross-compiling, which do not reach the artifacts that link it.
fn shareFrameworkPaths(library: *std.Build.Step.Compile, module: *std.Build.Module) void {
    for (library.root_module.include_dirs.items) |include_directory| switch (include_directory) {
        .framework_path, .framework_path_system => |directory| module.addSystemFrameworkPath(directory),
        else => {},
    };
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

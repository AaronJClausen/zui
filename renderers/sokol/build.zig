const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const force_opengl = b.option(bool, "gl", "Render with OpenGL instead of D3D11 or Metal") orelse false;

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths, .exclude_paths = &generated_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .exclude_paths = &generated_paths, .check = true }).step);

    const check = b.step("check", "Compile the backend and the demo, and link the tour for wasm32-freestanding, without installing them");
    const truetype_dependency = truetypeDeclaring(b, .{ .target = target, .optimize = optimize }) orelse return;
    const tour_modules = addTourModules(b, truetype_dependency, target, optimize, .exported);
    if (target.result.os.tag == .freestanding) return;

    const core = b.dependency("zui_core", .{ .target = target, .optimize = optimize });
    const sokol_dependency = b.lazyDependency("sokol", .{ .target = target, .optimize = optimize, .gl = force_opengl }) orelse return;
    const zui_module = core.module("zui");
    const glyphs_module = b.dependency("zui_glyphs", .{ .target = target, .optimize = optimize }).module("zui_glyphs");

    const backend_module = b.addModule("zui_sokol", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_glyphs", .module = glyphs_module },
            .{ .name = "zui_sokol_ui", .module = tour_modules.ui },
            .{ .name = "sokol", .module = sokol_dependency.module("sokol") },
        },
    });
    addRendererOptions(b, backend_module, force_opengl);

    const unit_tests = b.addTest(.{ .root_module = backend_module });
    linkThroughLlvmOnLinux(unit_tests);
    const ui_unit_tests = b.addTest(.{ .root_module = tour_modules.ui });
    linkThroughLlvmOnLinux(ui_unit_tests);
    const test_step = b.step("test", "Run the backend's unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(ui_unit_tests).step);

    const demo_imports = std.mem.concat(b.allocator, std.Build.Module.Import, &.{ tour_modules.imports, &.{.{ .name = "zui_sokol", .module = backend_module }} }) catch @panic("out of memory");
    const demo = b.addExecutable(.{
        .name = "zui-sokol-demo",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/demo.zig"), .target = target, .optimize = optimize, .imports = demo_imports }),
    });
    if (target.result.os.tag == .windows) demo.subsystem = .windows;
    linkThroughLlvmOnLinux(demo);

    const tour_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/tour_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = tour_modules.imports,
    }) });
    linkThroughLlvmOnLinux(tour_tests);
    b.step("test-tour", "Declare every screen of the demo headlessly; fail if one exceeds its limits or does not fit the default window").dependOn(&b.addRunArtifact(tour_tests).step);
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |arguments| run_demo.addArgs(arguments);
    b.step("demo", "Run the demo (`-- --frames 120` quits after 120 frames)").dependOn(&run_demo.step);

    check.dependOn(&demo.step);
    const freestanding_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const freestanding_truetype_dependency = truetypeDeclaring(b, .{ .target = freestanding_target, .optimize = optimize }) orelse return;
    const freestanding_tour_modules = addTourModules(b, freestanding_truetype_dependency, freestanding_target, optimize, .private);
    const freestanding_tour = b.addExecutable(.{
        .name = "zui-sokol-tour-freestanding",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tour_freestanding.zig"),
            .target = freestanding_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_sokol_ui", .module = freestanding_tour_modules.ui },
                .{ .name = "zui_sokol_tour", .module = freestanding_tour_modules.tour },
            },
        }),
    });
    freestanding_tour.entry = .disabled;
    freestanding_tour.rdynamic = true;
    _ = freestanding_tour.getEmittedBin();
    check.dependOn(&freestanding_tour.step);

    // The renderer suite reads frames back with glReadPixels, so it always
    // renders with OpenGL, and needs a window: on Linux CI, under Xvfb.
    const gl_sokol_dependency = b.lazyDependency("sokol", .{ .target = target, .optimize = optimize, .gl = true }) orelse return;
    const gl_backend_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_glyphs", .module = glyphs_module },
            .{ .name = "zui_sokol_ui", .module = tour_modules.ui },
            .{ .name = "sokol", .module = gl_sokol_dependency.module("sokol") },
        },
    });
    addRendererOptions(b, gl_backend_module, true);
    const conformance = b.addExecutable(.{
        .name = "zui-sokol-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_sokol", .module = gl_backend_module },
                .{ .name = "zui", .module = zui_module },
                .{ .name = "zui_testing", .module = core.module("zui_testing") },
            },
        }),
    });
    linkThroughLlvmOnLinux(conformance);
    b.step("conformance", "Run zui's renderer suite against the renderer, in a window, with OpenGL").dependOn(&b.addRunArtifact(conformance).step);

    const regenerate_shaders = b.step("shaders", "Regenerate each src/*.glsl.zig from its GLSL with sokol-shdc");
    if (b.lazyImport(@This(), "sokol")) |sokol| {
        inline for (shaders) |shader| {
            regenerate_shaders.dependOn(sokol.shdc.createSourceFile(b, .{
                .shdc_dep = sokol_dependency.builder.dependency("shdc", .{}),
                .input = shader ++ ".glsl",
                .output = shader ++ ".glsl.zig",
                .slang = .{ .glsl410 = true, .hlsl5 = true, .metal_macos = true },
            }) catch |err| std.debug.panic("sokol-shdc cannot run here: {t}", .{err}));
        }
    }
}

/// Checked in as `.glsl.zig`, so that building zui_sokol never runs sokol-shdc.
const shaders = [_][]const u8{ "src/material", "src/linear_light", "src/present_scrgb" };

const generated_paths = generated: {
    var paths: [shaders.len][]const u8 = undefined;
    for (shaders, &paths) |shader, *path| path.* = shader ++ ".glsl.zig";
    break :generated paths;
};
/// Zig 0.16's own ELF linker rejects the R_X86_64_PC64 relocations in the
/// `.sframe` section that GCC 16's crt1.o carries, and LLD crashes the
/// compiler unless the LLVM backend produced the objects.
fn linkThroughLlvmOnLinux(compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().os.tag == .linux) {
        compile.use_llvm = true;
        compile.use_lld = true;
    }
}

/// On Windows the renderer draws into a native host's window with a
/// context of its own: OpenGL through opengl32 and gdi32, or Direct3D 11
/// composed into the window through DirectComposition. On Linux it draws
/// into a native host's Wayland surface with OpenGL through EGL.
fn addRendererOptions(b: *std.Build, module: *std.Build.Module, opengl: bool) void {
    const options = b.addOptions();
    options.addOption(bool, "opengl", opengl);
    module.addOptions("zui_sokol_options", options);
    const os = module.resolved_target.?.result.os.tag;
    if (os == .linux) {
        module.linkSystemLibrary("EGL", .{});
        module.linkSystemLibrary("wayland-egl", .{});
        return;
    }
    if (os != .windows) return;
    if (opengl) {
        module.linkSystemLibrary("opengl32", .{});
        module.linkSystemLibrary("gdi32", .{});
    } else {
        module.addCSourceFile(.{ .file = b.path("src/composition.c") });
        module.linkSystemLibrary("d3d11", .{});
        module.linkSystemLibrary("dxgi", .{});
        module.linkSystemLibrary("user32", .{});
    }
}

const TourModules = struct {
    /// `zui_sokol_ui`: the types a context drawn by `zui_sokol` declares.
    ui: *std.Build.Module,
    /// `zui_sokol_tour`: the tour's application, which declares its frames
    /// through `zui_sokol_ui` alone, so it builds where sokol does not.
    tour: *std.Build.Module,
    /// What the tour's modules import.
    imports: []const std.Build.Module.Import,
};

/// `.exported` adds the modules for dependents to import; `.private`
/// makes them for this build alone, as for a second target.
fn addTourModules(b: *std.Build, truetype_dependency: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, visibility: enum { exported, private }) TourModules {
    const core = b.dependency("zui_core", .{ .target = target, .optimize = optimize });
    const fonts_module = b.dependency("zui_fonts", .{ .target = target, .optimize = optimize }).module("zui_fonts");
    const ui_options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = b.allocator.dupe(std.Build.Module.Import, &.{
            .{ .name = "zui", .module = core.module("zui") },
            .{ .name = "zui_glyphs", .module = b.dependency("zui_glyphs", .{ .target = target, .optimize = optimize }).module("zui_glyphs") },
            .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
            .{ .name = "zui_fonts", .module = fonts_module },
        }) catch @panic("out of memory"),
    };
    const ui = if (visibility == .exported) b.addModule("zui_sokol_ui", ui_options) else b.createModule(ui_options);
    const imports = b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "zui_sokol_ui", .module = ui },
        .{ .name = "zui", .module = core.module("zui") },
        .{ .name = "zui_widgets", .module = core.module("zui_widgets") },
        .{ .name = "zui_reflect", .module = core.module("zui_reflect") },
        .{ .name = "zui_async", .module = core.module("zui_async") },
        .{ .name = "zui_fonts", .module = fonts_module },
    }) catch @panic("out of memory");
    const tour_options: std.Build.Module.CreateOptions = .{ .root_source_file = b.path("examples/tour_app.zig"), .target = target, .optimize = optimize, .imports = imports };
    const tour = if (visibility == .exported) b.addModule("zui_sokol_tour", tour_options) else b.createModule(tour_options);
    return .{ .ui = ui, .tour = tour, .imports = imports };
}

/// The font system the tour's text delegates its TrueType fonts to, once
/// it has declared its module: until stb is fetched it returns from
/// `build()` before declaring it.
fn truetypeDeclaring(b: *std.Build, args: anytype) ?*std.Build.Dependency {
    const dependency = b.dependency("zui_truetype", args);
    return if (dependency.builder.modules.contains("zui_truetype")) dependency else null;
}

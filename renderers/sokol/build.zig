const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);
    const force_opengl = b.option(bool, "gl", "Render with OpenGL instead of D3D11 or Metal") orelse false;

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths, .exclude_paths = &generated_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .exclude_paths = &generated_paths, .check = true }).step);

    const check = b.step("check", "Compile the backend, its tests and the renderer suite without running them");
    if (target.result.os.tag == .freestanding) return;

    const core = b.dependency("zui_core", core_options.on(target, optimize));
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
            .{ .name = "sokol", .module = sokol_dependency.module("sokol") },
        },
    });
    addRendererOptions(b, backend_module, force_opengl);

    const unit_tests = b.addTest(.{ .root_module = backend_module });
    linkThroughLlvmOnLinux(unit_tests);
    b.step("test", "Run the backend's unit tests").dependOn(&b.addRunArtifact(unit_tests).step);
    check.dependOn(&unit_tests.step);

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
            .{ .name = "sokol", .module = gl_sokol_dependency.module("sokol") },
        },
    });
    addRendererOptions(b, gl_backend_module, true);
    // Until stb is fetched, the font system the suite measures with declares
    // no module.
    if (truetypeDeclaring(b, core_options.on(target, optimize))) |truetype_dependency| {
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
                    .{ .name = "zui_app", .module = core.module("zui_app") },
                    .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
                },
            }),
        });
        linkThroughLlvmOnLinux(conformance);
        check.dependOn(&conformance.step);
        b.step("conformance", "Run zui's renderer suite against the renderer, in a window, with OpenGL").dependOn(&b.addRunArtifact(conformance).step);
    }

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

/// The font system the renderer suite measures with, once it has declared
/// its module: until stb is fetched it returns from `build()` before
/// declaring it.
fn truetypeDeclaring(b: *std.Build, args: anytype) ?*std.Build.Dependency {
    const dependency = b.dependency("zui_truetype", args);
    return if (dependency.builder.modules.contains("zui_truetype")) dependency else null;
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

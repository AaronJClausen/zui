const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);
    const windows = target.result.os.tag == .windows;
    const linux = target.result.os.tag == .linux;
    const has_host = windows or linux;

    const core = b.dependency("zui_core", core_options.on(target, optimize));
    const zui_module = core.module("zui");

    const host_module = b.addModule("zui_host", .{
        .root_source_file = b.path("zui_host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });
    if (windows) {
        for ([_][]const u8{ "user32", "gdi32", "shell32", "imm32", "dwmapi", "advapi32", "dxgi", "ole32", "oleaut32", "uiautomationcore" }) |library| host_module.linkSystemLibrary(library, .{});
    }
    if (linux) {
        host_module.link_libc = true;
        for ([_][]const u8{ "wayland-client", "xkbcommon", "X11", "X11-xcb", "xcb", "xcb-xkb", "xcb-cursor", "xkbcommon-x11" }) |library| host_module.linkSystemLibrary(library, .{});
    }

    const unit_tests = b.addTest(.{ .root_module = host_module });
    linkThroughLlvmOnLinux(unit_tests);
    const test_step = b.step("test", "Run the host's unit tests, and zui's host suite against a window the user never sees");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const conformance_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(if (linux) "linux/conformance.zig" else "windows/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui_host", .module = host_module },
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_testing", .module = core.module("zui_testing") },
            .{ .name = "zui_async", .module = core.module("zui_async") },
            .{ .name = "zui_widgets", .module = core.module("zui_widgets") },
            .{ .name = "zui_design", .module = core.module("zui_design") },
        },
    }) });
    linkThroughLlvmOnLinux(conformance_tests);
    const conformance_step = b.step("conformance", "Run zui's host suite and the host's own tests against a window the user never sees (Linux: Wayland, or X11 with ZUI_HOST_BACKEND=x11; skipped without the display server)");
    conformance_step.dependOn(&b.addRunArtifact(conformance_tests).step);
    if (has_host) test_step.dependOn(conformance_step);

    const check_step = b.step("check", "Compile the host and its tests without producing output");
    check_step.dependOn(&unit_tests.step);
    if (has_host) check_step.dependOn(&conformance_tests.step);

    if (has_host) addTour(b, target, optimize, host_module, core, check_step, core_options);
    if (has_host) addTestCard(b, target, optimize, host_module, core, check_step, core_options);
    if (has_host) addTheme(b, target, optimize, host_module, core, check_step, core_options);
    if (has_host) addServicesExample(b, target, optimize, host_module, core, check_step, core_options);
    if (has_host) addTitleBarExample(b, target, optimize, host_module, core, check_step, core_options);
    if (has_host) addManyWindowsExample(b, target, optimize, host_module, core, check_step, core_options);
    if (has_host) addMaterialExample(b, target, optimize, host_module, core, check_step, core_options);
    if (windows) addWindowsExamples(b, target, optimize, host_module, core, check_step, core_options);
    if (linux) addTerminateCheck(b, target, optimize, host_module, core, test_step, check_step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "zui_host.zig", "windows", "linux", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
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

/// zui's tour on this host, drawn by the sokol renderer: on
/// Windows through a Direct3D 11 swapchain that DirectComposition composes
/// over the window's backdrop, on Linux with OpenGL through EGL.
fn addTour(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, core: *std.Build.Dependency, check_step: *std.Build.Step, core_options: CoreOptions) void {
    const zui_sokol_dependency = sokolDeclaring(b, core_options.on(target, optimize), "zui_sokol") orelse return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;
    const tour = b.addExecutable(.{
        .name = "zui-host-tour",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tour.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_app", .module = core.module("zui_app") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
                .{ .name = "zui_tour", .module = b.dependency("zui_tour", core_options.on(target, optimize)).module("zui_tour") },
            },
        }),
    });
    linkThroughLlvmOnLinux(tour);
    b.installArtifact(tour);
    const run_tour = b.addRunArtifact(tour);
    if (b.args) |arguments| run_tour.addArgs(arguments);
    b.step("tour", "Run zui's tour on this host (`-- --frames 300 --cycle 30` visits every screen and quits; `-- --measure-idle` reports its idle CPU time)").dependOn(&run_tour.step);
    check_step.dependOn(&tour.step);
}

/// zui's test card on this host, drawn by the sokol renderer as the tour is.
fn addTestCard(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, core: *std.Build.Dependency, check_step: *std.Build.Step, core_options: CoreOptions) void {
    const zui_sokol_dependency = sokolDeclaring(b, core_options.on(target, optimize), "zui_sokol") orelse return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;
    const test_card = b.addExecutable(.{
        .name = "zui-host-test-card",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/test_card.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_app", .module = core.module("zui_app") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
                .{ .name = "zui_test_card", .module = b.dependency("zui_test_card", core_options.on(target, optimize)).module("zui_test_card") },
            },
        }),
    });
    linkThroughLlvmOnLinux(test_card);
    b.installArtifact(test_card);
    const run_test_card = b.addRunArtifact(test_card);
    if (b.args) |arguments| run_test_card.addArgs(arguments);
    b.step("test-card", "Run zui's test card on this host (`-- --frames 6` draws every scene once and quits)").dependOn(&run_test_card.step);
    check_step.dependOn(&test_card.step);
}

/// A window styled by a ZON file that the host's file watch reloads, on
/// either host.
fn addTheme(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, core: *std.Build.Dependency, check_step: *std.Build.Step, core_options: CoreOptions) void {
    const zui_sokol_dependency = sokolDeclaring(b, core_options.on(target, optimize), "zui_sokol") orelse return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;
    const theme = b.addExecutable(.{
        .name = "zui-host-theme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/theme.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_async", .module = core.module("zui_async") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_app", .module = core.module("zui_app") },
                .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
            },
        }),
    });
    linkThroughLlvmOnLinux(theme);
    b.installArtifact(theme);
    const run_theme = b.addRunArtifact(theme);
    if (b.args) |arguments| run_theme.addArgs(arguments);
    b.step("theme", "Show a window styled by examples/theme.zon, restyled when the file changes (`-- --check` scripts it)").dependOn(&run_theme.step);
    check_step.dependOn(&theme.step);
}

/// Every host service from buttons, on Windows and on Linux.
fn addServicesExample(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, core: *std.Build.Dependency, check_step: *std.Build.Step, core_options: CoreOptions) void {
    const zui_sokol_dependency = sokolDeclaring(b, core_options.on(target, optimize), "zui_sokol") orelse return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;
    const services = b.addExecutable(.{
        .name = "zui-host-services",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/services.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_app", .module = core.module("zui_app") },
                .{ .name = "zui_async", .module = core.module("zui_async") },
                .{ .name = "zui_widgets", .module = core.module("zui_widgets") },
                .{ .name = "zui_design", .module = core.module("zui_design") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
            },
        }),
    });
    linkThroughLlvmOnLinux(services);
    b.installArtifact(services);
    const run_services = b.addRunArtifact(services);
    if (b.args) |arguments| run_services.addArgs(arguments);
    b.step("services", "Call every host service from buttons, each answer shown (`-- --check` answers them through the host's fake and quits)").dependOn(&run_services.step);
    check_step.dependOn(&services.step);
}

/// A title bar the application draws, which the OS still drags, maximizes
/// and resizes the window by, on Windows and on Linux.
fn addTitleBarExample(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, core: *std.Build.Dependency, check_step: *std.Build.Step, core_options: CoreOptions) void {
    const zui_sokol_dependency = sokolDeclaring(b, core_options.on(target, optimize), "zui_sokol") orelse return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;
    const title_bar = b.addExecutable(.{
        .name = "zui-host-title-bar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/title_bar.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_app", .module = core.module("zui_app") },
                .{ .name = "zui_widgets", .module = core.module("zui_widgets") },
                .{ .name = "zui_design", .module = core.module("zui_design") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
            },
        }),
    });
    linkThroughLlvmOnLinux(title_bar);
    b.installArtifact(title_bar);
    const run_title_bar = b.addRunArtifact(title_bar);
    if (b.args) |arguments| run_title_bar.addArgs(arguments);
    b.step("title-bar", "Draw the title bar in the window, which the OS still drags, maximizes and resizes (`-- --check` hit-tests it hidden and quits)").dependOn(&run_title_bar.step);
    check_step.dependOn(&title_bar.step);
}

/// One application in many windows, on Windows and on Linux.
fn addManyWindowsExample(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, core: *std.Build.Dependency, check_step: *std.Build.Step, core_options: CoreOptions) void {
    const zui_sokol_dependency = sokolDeclaring(b, core_options.on(target, optimize), "zui_sokol") orelse return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;
    const many_windows = b.addExecutable(.{
        .name = "zui-host-many-windows",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/many_windows.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_app", .module = core.module("zui_app") },
                .{ .name = "zui_async", .module = core.module("zui_async") },
                .{ .name = "zui_widgets", .module = core.module("zui_widgets") },
                .{ .name = "zui_design", .module = core.module("zui_design") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
            },
        }),
    });
    linkThroughLlvmOnLinux(many_windows);
    b.installArtifact(many_windows);
    const run_many_windows = b.addRunArtifact(many_windows);
    if (b.args) |arguments| run_many_windows.addArgs(arguments);
    b.step("many-windows", "Run one application in two windows, each with its own UI (`-- --check` clicks and closes them and quits, hidden on Windows; `--measure-idle`, `--measure-animation`)").dependOn(&run_many_windows.step);
    check_step.dependOn(&many_windows.step);
}

/// An application whose window is never shown, sent SIGTERM and SIGINT in
/// a process of its own, must end within a second of each; `test` runs it.
fn addTerminateCheck(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, core: *std.Build.Dependency, test_step: *std.Build.Step, check_step: *std.Build.Step) void {
    const terminate_check = b.addExecutable(.{
        .name = "zui-host-terminate-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("linux/terminate_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_app", .module = core.module("zui_app") },
            },
        }),
    });
    linkThroughLlvmOnLinux(terminate_check);
    const run_terminate_check = b.addRunArtifact(terminate_check);
    const terminate_check_step = b.step("terminate-check", "End an application whose window is never shown by SIGTERM and by SIGINT, each within a second (skipped without a display server)");
    terminate_check_step.dependOn(&run_terminate_check.step);
    test_step.dependOn(terminate_check_step);
    check_step.dependOn(&terminate_check.step);
}

/// The desktop through a window, where the system has a material, on
/// Windows and on Linux.
fn addMaterialExample(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, core: *std.Build.Dependency, check_step: *std.Build.Step, core_options: CoreOptions) void {
    const zui_sokol_dependency = sokolDeclaring(b, core_options.on(target, optimize), "zui_sokol") orelse return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;
    const material = b.addExecutable(.{
        .name = "zui-host-material",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/material.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_app", .module = core.module("zui_app") },
                .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
            },
        }),
    });
    linkThroughLlvmOnLinux(material);
    b.installArtifact(material);
    const run_material = b.addRunArtifact(material);
    if (b.args) |arguments| run_material.addArgs(arguments);
    b.step("material", "Show the desktop through a window, or the solid fallback (`-- --no-system-material`; `-- --check` reports a hidden window's material and quits)").dependOn(&run_material.step);
    check_step.dependOn(&material.step);
}

/// The remote, HDR and accessibility examples, which run only on the
/// Windows host so far.
fn addWindowsExamples(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, core: *std.Build.Dependency, check_step: *std.Build.Step, core_options: CoreOptions) void {
    const app_module = core.module("zui_app");
    const zui_sokol_dependency = sokolDeclaring(b, core_options.on(target, optimize), "zui_sokol") orelse return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;

    const remote = b.addExecutable(.{
        .name = "zui-host-remote",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/remote.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_app", .module = app_module },
                .{ .name = "zui_wire", .module = core.module("zui_wire") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
                .{ .name = "zui_tour", .module = b.dependency("zui_tour", core_options.on(target, optimize)).module("zui_tour") },
            },
        }),
    });
    b.installArtifact(remote);
    const run_remote = b.addRunArtifact(remote);
    if (b.args) |arguments| run_remote.addArgs(arguments);
    b.step("remote", "Run the tour in one process and draw it in this one, over zui_wire (`-- --check tour.bmp` scripts it)").dependOn(&run_remote.step);
    check_step.dependOn(&remote.step);

    const hdr = b.addExecutable(.{
        .name = "zui-host-hdr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hdr.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_app", .module = app_module },
                .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
            },
        }),
    });
    b.installArtifact(hdr);
    const run_hdr = b.addRunArtifact(hdr);
    if (b.args) |arguments| run_hdr.addArgs(arguments);
    b.step("hdr", "Show HDR white beside SDR white (`-- --measure` reads them back off the desktop in scRGB)").dependOn(&run_hdr.step);
    check_step.dependOn(&hdr.step);

    const accessible = b.addExecutable(.{
        .name = "zui-host-accessible",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/accessible.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui", .module = core.module("zui") },
                .{ .name = "zui_app", .module = app_module },
                .{ .name = "zui_widgets", .module = core.module("zui_widgets") },
                .{ .name = "zui_design", .module = core.module("zui_design") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
            },
        }),
    });
    b.installArtifact(accessible);
    const run_accessible = b.addRunArtifact(accessible);
    if (b.args) |arguments| run_accessible.addArgs(arguments);
    b.step("accessible", "Show zui_widgets controls to UI Automation, for Narrator and Accessibility Insights (`-- --frames 30` quits)").dependOn(&run_accessible.step);
    check_step.dependOn(&accessible.step);
}

/// The sokol renderer's package, once it has declared `module_name`: until its
/// own lazy libraries are fetched it returns from `build()` before declaring
/// any, and asking for a module it lacks panics.
fn sokolDeclaring(b: *std.Build, args: anytype, module_name: []const u8) ?*std.Build.Dependency {
    const dependency = b.lazyDependency("zui_sokol", args) orelse return null;
    return if (dependency.builder.modules.contains(module_name)) dependency else null;
}

/// The font system the examples measure with, once it has declared its
/// module: until stb is fetched it returns from `build()` before declaring
/// it.
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

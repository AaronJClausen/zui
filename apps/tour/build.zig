const std = @import("std");

/// Misuse that must fail to compile with the tour's own message. The build
/// system matches the *end* of an error line, so each `expected_error` is a
/// complete message.
const compile_error_cases = [_]struct { name: []const u8, expected_error: []const u8 }{
    .{ .name = "text_without_add_font", .expected_error = "zui_tour: text_without_add_font.MeasuringOnly has no `addFont`; the tour's Text is a font system that adds font files and measures with them, such as zui_truetype.Text" },
    .{ .name = "text_without_fingerprint", .expected_error = "zui_tour: text_without_fingerprint.Unfingerprinted has no `zuiFingerprint`; the tour's Text is a font system that adds font files and measures with them, such as zui_truetype.Text" },
    .{ .name = "text_not_a_struct", .expected_error = "zui_tour: the Text must be a font system's struct, such as zui_truetype.Text, got u16" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);

    const tour_module = b.addModule("zui_tour", tourModuleOptions(b, target, optimize, core_options));

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "tests" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);

    const test_step = b.step("test", "Declare every screen headlessly on renderers that draw every command and none, in pixels and in cells, and check the compile errors");
    const check_step = b.step("check", "Compile the tests natively, and the tour for wasm32-freestanding, without running them");
    // The tests measure with zui_truetype, whose stb a package depending
    // on the tour must not be made to fetch.
    if (b.pkg_hash.len != 0) return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui_tour", .module = tour_module },
            .{ .name = "zui", .module = coreModule(b, target, optimize, core_options, "zui") },
            .{ .name = "zui_app", .module = coreModule(b, target, optimize, core_options, "zui_app") },
            .{ .name = "zui_design", .module = coreModule(b, target, optimize, core_options, "zui_design") },
            .{ .name = "zui_testing", .module = coreModule(b, target, optimize, core_options, "zui_testing") },
            .{ .name = "zui_glyphs", .module = b.dependency("zui_glyphs", .{ .target = target, .optimize = optimize }).module("zui_glyphs") },
            .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    check_step.dependOn(&tests.step);

    for (compile_error_cases) |case| {
        const failing_object = b.addObject(.{
            .name = case.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/compile_errors/{s}.zig", .{case.name})),
                .target = target,
                .imports = &.{
                    .{ .name = "zui", .module = coreModule(b, target, optimize, core_options, "zui") },
                    .{ .name = "zui_tour", .module = tour_module },
                },
            }),
        });
        failing_object.expect_errors = .{ .contains = case.expected_error };
        test_step.dependOn(&failing_object.step);
    }

    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const browser_truetype_dependency = truetypeDeclaring(b, core_options.on(browser_target, optimize)) orelse return;
    const freestanding_tour = b.addExecutable(.{
        .name = "zui-tour-freestanding",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/freestanding.zig"),
            .target = browser_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_tour", .module = b.createModule(tourModuleOptions(b, browser_target, optimize, core_options)) },
                .{ .name = "zui", .module = coreModule(b, browser_target, optimize, core_options, "zui") },
                .{ .name = "zui_truetype", .module = browser_truetype_dependency.module("zui_truetype") },
            },
        }),
    });
    freestanding_tour.entry = .disabled;
    freestanding_tour.rdynamic = true;
    _ = freestanding_tour.getEmittedBin();
    check_step.dependOn(&freestanding_tour.step);
}

fn coreModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions, name: []const u8) *std.Build.Module {
    return b.dependency("zui_core", core_options.on(target, optimize)).module(name);
}

fn tourModuleOptions(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions) std.Build.Module.CreateOptions {
    const imports = b.allocator.alloc(std.Build.Module.Import, 12) catch @panic("out of memory");
    for (imports[0..10], [_][]const u8{ "zui", "zui_app", "zui_widgets", "zui_widgets_data", "zui_reflect", "zui_async", "zui_debug", "zui_tracy", "zui_motion", "zui_design" }) |*import, name| {
        import.* = .{ .name = name, .module = coreModule(b, target, optimize, core_options, name) };
    }
    imports[10] = .{ .name = "zui_glyphs", .module = b.dependency("zui_glyphs", .{ .target = target, .optimize = optimize }).module("zui_glyphs") };
    imports[11] = .{ .name = "zui_fonts", .module = b.dependency("zui_fonts", .{ .target = target, .optimize = optimize }).module("zui_fonts") };
    return .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .imports = imports };
}

/// The font system the tests measure with, once it has declared its
/// module: until stb is fetched it returns from `build()` before
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

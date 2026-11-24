const std = @import("std");

/// Misuse that must fail to compile with the test card's own message. The
/// build system matches the *end* of an error line, so each
/// `expected_error` is a complete message.
const compile_error_cases = [_]struct { name: []const u8, expected_error: []const u8 }{
    .{ .name = "text_without_add_font", .expected_error = "zui_test_card: text_without_add_font.MeasuringOnly has no `addFont`; the test card's Text is a font system that adds font files and measures with them, such as zui_truetype.Text" },
    .{ .name = "text_without_fingerprint", .expected_error = "zui_test_card: text_without_fingerprint.Unfingerprinted has no `zuiFingerprint`; the test card's Text is a font system that adds font files and measures with them, such as zui_truetype.Text" },
    .{ .name = "text_not_a_struct", .expected_error = "zui_test_card: the Text must be a font system's struct, such as zui_truetype.Text, got u16" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);

    const test_card_module = b.addModule("zui_test_card", testCardModuleOptions(b, target, optimize, core_options));

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "tests" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);

    const test_step = b.step("test", "Declare every scene headlessly on renderers that draw every command and none, in pixels and in cells, and check the compile errors");
    const check_step = b.step("check", "Compile the tests, natively and for wasm32-freestanding, without running them");
    // The tests measure with zui_truetype, whose stb a package depending
    // on the test card must not be made to fetch.
    if (b.pkg_hash.len != 0) return;
    const truetype_dependency = truetypeDeclaring(b, core_options.on(target, optimize)) orelse return;

    const tests = b.addTest(.{ .root_module = testsModule(b, target, optimize, core_options, test_card_module, truetype_dependency) });
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
                    .{ .name = "zui_test_card", .module = test_card_module },
                },
            }),
        });
        failing_object.expect_errors = .{ .contains = case.expected_error };
        test_step.dependOn(&failing_object.step);
    }

    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const browser_truetype_dependency = truetypeDeclaring(b, core_options.on(browser_target, optimize)) orelse return;
    const browser_test_card_module = b.createModule(testCardModuleOptions(b, browser_target, optimize, core_options));
    const browser_tests = b.addTest(.{
        .name = "zui-test-card-freestanding",
        .root_module = testsModule(b, browser_target, optimize, core_options, browser_test_card_module, browser_truetype_dependency),
        .test_runner = .{ .path = b.path("src/freestanding_test_runner.zig"), .mode = .simple },
    });
    browser_tests.entry = .disabled;
    browser_tests.rdynamic = true;
    check_step.dependOn(&browser_tests.step);
}

fn testsModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions, test_card_module: *std.Build.Module, truetype_dependency: *std.Build.Dependency) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui_test_card", .module = test_card_module },
            .{ .name = "zui", .module = coreModule(b, target, optimize, core_options, "zui") },
            .{ .name = "zui_app", .module = coreModule(b, target, optimize, core_options, "zui_app") },
            .{ .name = "zui_design", .module = coreModule(b, target, optimize, core_options, "zui_design") },
            .{ .name = "zui_glyphs", .module = b.dependency("zui_glyphs", .{ .target = target, .optimize = optimize }).module("zui_glyphs") },
            .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
        },
    });
}

fn coreModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions, name: []const u8) *std.Build.Module {
    return b.dependency("zui_core", core_options.on(target, optimize)).module(name);
}

fn testCardModuleOptions(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions) std.Build.Module.CreateOptions {
    const imports = b.allocator.alloc(std.Build.Module.Import, 6) catch @panic("out of memory");
    for (imports[0..4], [_][]const u8{ "zui", "zui_app", "zui_widgets", "zui_design" }) |*import, name| {
        import.* = .{ .name = name, .module = coreModule(b, target, optimize, core_options, name) };
    }
    imports[4] = .{ .name = "zui_glyphs", .module = b.dependency("zui_glyphs", .{ .target = target, .optimize = optimize }).module("zui_glyphs") };
    imports[5] = .{ .name = "zui_fonts", .module = b.dependency("zui_fonts", .{ .target = target, .optimize = optimize }).module("zui_fonts") };
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

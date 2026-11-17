const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const web_module = webModule(b, "src/root.zig", target, optimize);
    const unit_tests = b.addTest(.{ .root_module = web_module });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const client = browserModule(b, "zui-web", "src/browser.zig", browser_target, optimize);
    b.getInstallStep().dependOn(&b.addInstallArtifact(client, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    const check_step = b.step("check", "Compile the unit tests, and the client for the browser, without running them");
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&client.step);

    const test_demo = b.step("test-demo", "Stream zui-sokol's tour, headless, to the browser's client under Node, and check every frame decodes to what was drawn");
    const test_draw = b.step("test-draw", "Draw frames of zui-sokol's tour in headless Chromium and check each against zui-sokol's renderer drawing it; needs a display");
    const test_input = b.step("test-input", "Give the client input in headless Chromium, run zui-sokol's tour on the records it writes, and check the tour took them and the page shows its cursor");
    const browser = b.option([]const u8, "browser", "The Chromium that `test-draw` runs headless (default: chromium)") orelse "chromium";
    if (b.lazyDependency("zui_sokol", .{ .target = target, .optimize = optimize })) |zui_sokol_dependency| {
        const tour_imports: []const std.Build.Module.Import = &.{
            .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
            .{ .name = "zui_sokol_tour", .module = zui_sokol_dependency.module("zui_sokol_tour") },
            .{ .name = "zui_wire", .module = b.dependency("zui", .{ .target = target, .optimize = optimize }).module("zui_wire") },
        };
        const demo_stream = tourTool(b, "demo-stream", "tools/demo_stream.zig", tour_imports, target, optimize);
        const write_stream = b.addRunArtifact(demo_stream);
        const stream = write_stream.addOutputFileArg("tour.zuiw");
        const expected = write_stream.addOutputFileArg("tour.expected");

        const wire_check = browserModule(b, "zui-web-wire-check", "src/browser_wire_check.zig", browser_target, optimize);
        const decode_in_client = b.addSystemCommand(&.{"node"});
        decode_in_client.addFileArg(b.path("web/check_stream.mjs"));
        decode_in_client.addArtifactArg(wire_check);
        decode_in_client.addFileArg(stream);
        decode_in_client.addFileArg(expected);
        decode_in_client.expectExitCode(0);
        test_demo.dependOn(&decode_in_client.step);

        const draw_reference = tourTool(b, "draw-reference", "tools/draw_reference.zig", tour_imports, target, optimize);
        const write_reference = b.addRunArtifact(draw_reference);
        write_reference.addFileArg(stream);
        const reference = write_reference.addOutputFileArg("tour.reference");
        for (compared_frames) |frame_number| write_reference.addArg(b.fmt("{d}", .{frame_number}));

        const bitmap_fonts = tourTool(b, "bitmap-fonts", "tools/bitmap_fonts.zig", tour_imports, target, optimize);
        const write_bitmap_fonts = b.addRunArtifact(bitmap_fonts);
        const bitmap_font_rows = write_bitmap_fonts.addOutputFileArg("bitmap.fonts");

        const draw_in_browser = b.addSystemCommand(&.{"node"});
        draw_in_browser.addFileArg(b.path("web/check_draw.mjs"));
        draw_in_browser.addArg(browser);
        draw_in_browser.addArtifactArg(client);
        draw_in_browser.addFileArg(stream);
        draw_in_browser.addFileArg(reference);
        draw_in_browser.addFileArg(bitmap_font_rows);
        for (tour_truetype_fonts) |font| draw_in_browser.addFileArg(zui_sokol_dependency.path(font));
        for ([_][]const u8{ "web/check_draw.html", "web/frame_drawer.mjs", "web/headless_page.mjs" }) |page_file| draw_in_browser.addFileInput(b.path(page_file));
        draw_in_browser.expectExitCode(0);
        test_draw.dependOn(&draw_in_browser.step);

        const replay_input = tourTool(b, "replay-input", "tools/replay_input.zig", tour_imports, target, optimize);
        const input_in_browser = b.addSystemCommand(&.{"node"});
        input_in_browser.addFileArg(b.path("web/check_input.mjs"));
        input_in_browser.addArg(browser);
        input_in_browser.addArtifactArg(client);
        input_in_browser.addArtifactArg(replay_input);
        for ([_][]const u8{ "web/check_input.html", "web/input_recorder.mjs", "web/headless_page.mjs" }) |page_file| input_in_browser.addFileInput(b.path(page_file));
        input_in_browser.expectExitCode(0);
        test_input.dependOn(&input_in_browser.step);
    }

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "tools" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

fn webModule(b: *std.Build, root_source_file: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize });
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_dependency.module("zui") },
            .{ .name = "zui_wire", .module = zui_dependency.module("zui_wire") },
            .{ .name = "stb_truetype", .module = stbTruetypeModule(b, target, optimize) },
        },
    });
}

/// stb_truetype's declarations, translated to Zig, with its implementation
/// compiled in without a C library, at the commit zui-sokol rasterizes with.
fn stbTruetypeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const stb_dependency = b.dependency("stb", .{});
    const translated = b.addTranslateC(.{
        .root_source_file = stb_dependency.path("stb_truetype.h"),
        .target = target,
        .optimize = optimize,
    });
    const module = translated.createModule();
    module.link_libc = false;
    module.addCSourceFile(.{ .file = b.path("src/stb_truetype.c"), .flags = &.{"-fvisibility=hidden"} });
    module.addIncludePath(stb_dependency.path(""));
    return module;
}

/// The frame of each of the tour's thirteen screens that `test-draw`
/// compares: the middle one of the 24 that `tools/demo_stream.zig` streams.
const compared_frames = compared: {
    var numbers: [13]u64 = undefined;
    for (&numbers, 0..) |*number, screen| number.* = 24 * screen + 12;
    break :compared numbers;
};

/// The TrueType fonts zui-sokol's tour adds, in the order `kit.addFonts`
/// adds them, so each takes the `FontId` the tour's text names.
const tour_truetype_fonts = [_][]const u8{
    "examples/fonts/AtkinsonHyperlegible-Regular.ttf",
    "examples/fonts/AtkinsonHyperlegible-Bold.ttf",
};

/// A native program that runs zui-sokol's tour.
fn tourTool(b: *std.Build, name: []const u8, root_source_file: []const u8, imports: []const std.Build.Module.Import, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const tool = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{ .root_source_file = b.path(root_source_file), .target = target, .optimize = optimize, .imports = imports }),
    });
    linkThroughLlvmOnLinux(tool);
    return tool;
}

/// A WebAssembly module with no entry point, whose exports the page calls.
fn browserModule(b: *std.Build, name: []const u8, root_source_file: []const u8, browser_target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.addExecutable(.{ .name = name, .root_module = webModule(b, root_source_file, browser_target, optimize) });
    module.entry = .disabled;
    module.rdynamic = true;
    return module;
}

/// As zui-sokol links: Zig 0.16's ELF linker rejects the R_X86_64_PC64
/// relocations that GCC 16's crt1.o carries, and LLD crashes the compiler
/// unless the LLVM backend produced the objects.
fn linkThroughLlvmOnLinux(compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().os.tag == .linux) {
        compile.use_llvm = true;
        compile.use_lld = true;
    }
}

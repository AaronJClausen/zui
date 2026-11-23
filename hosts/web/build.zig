const std = @import("std");

const compile_error_cases = [_]struct { name: []const u8, expected_error: []const u8 }{
    .{ .name = "platform_without_run", .expected_error = "zui_web: platform_without_run.PlatformWithoutRun is not a web host's platform: missing `run`, which must be fn (*platform_without_run.PlatformWithoutRun, zui_web.Turns) !void, or noreturn" },
    .{ .name = "platform_clock_in_milliseconds", .expected_error = "zui_web: platform_clock_in_milliseconds.PlatformClockInMilliseconds.now must be fn (*platform_clock_in_milliseconds.PlatformClockInMilliseconds) zui.Instant, found fn (*platform_clock_in_milliseconds.PlatformClockInMilliseconds) f64" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_options: CoreOptions = .declare(b);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "tests", "tools", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);

    // Until stb is fetched, the font system declares no module, and every
    // step here needs it.
    if (truetypeDeclaring(b, core_options.on(target, optimize)) == null) return;
    const web_module = webModule(b, "src/root.zig", target, optimize, core_options);
    web_module.addImport("zui_testing", b.dependency("zui_core", core_options.on(target, optimize)).module("zui_testing"));
    web_module.sanitize_thread = core_options.sanitize_thread;
    const unit_tests = b.addTest(.{ .root_module = web_module });
    const test_step = b.step("test", "Run the unit tests, the web host's conformance on a scripted page, and the compile errors");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    for (compile_error_cases) |case| {
        const failing_object = b.addObject(.{
            .name = case.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/compile_errors/{s}.zig", .{case.name})),
                .target = target,
                .imports = &.{
                    .{ .name = "zui", .module = b.dependency("zui_core", core_options.on(target, optimize)).module("zui") },
                    .{ .name = "zui_web", .module = web_module },
                },
            }),
        });
        failing_object.expect_errors = .{ .contains = case.expected_error };
        test_step.dependOn(&failing_object.step);
    }

    const browser_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const client = browserModule(b, "zui-web", "src/browser.zig", browser_target, optimize, core_options);
    b.getInstallStep().dependOn(&b.addInstallArtifact(client, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    const check_step = b.step("check", "Compile the unit tests, the client, the tour on the web host and the tour's worker for the browser, and the native tools that run the tour, without running them");
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&client.step);

    const test_demo = b.step("test-demo", "Stream the tour, headless, to the browser's client under Node, and check every frame decodes to what was drawn; run the tour in a worker under Node, and check every frame is the one it draws natively");
    const test_draw = b.step("test-draw", "Draw frames of the tour in headless Chromium, with one sample per pixel and with four, and check each against the sokol renderer drawing it alike; needs a display");
    const test_input = b.step("test-input", "Give the client input in headless Chromium, run the tour on the records it writes, and check the tour took them and the page shows its cursor");
    const site_step = b.step("site", "Write the published page, the client, the tour's worker and the tour's fonts to zig-out/site");
    const tour_step = b.step("tour", "Write the tour on the web host, its page, its worker's scripts and its module, to zig-out/tour");
    const test_host = b.step("test-host", "Open the tour on the web host in headless Chromium, and check it draws the tour, sleeps while idle, its input reaches the tour, it shows the cursor the tour asks for, a lost WebGL context comes back with the tour's screen kept, the page's settings restyle it, and a hidden page draws nothing");
    const test_site = b.step("test-site", "Serve the published page without isolation headers, open it in headless Chromium, and check its service worker isolates it, it draws the tour's frames, sleeps while idle, and its input wakes it and reaches the tour");
    const browser = b.option([]const u8, "browser", "The Chromium that `test-draw` runs headless (default: chromium)") orelse "chromium";
    const worker_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory }),
    });
    const worker_truetype_dependency = truetypeDeclaring(b, core_options.on(worker_target, optimize)) orelse return;
    const tour_worker = tourWorker(b, worker_truetype_dependency, worker_target, optimize, core_options);
    b.getInstallStep().dependOn(&b.addInstallArtifact(tour_worker, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    check_step.dependOn(&tour_worker.step);

    const tour_on_host = tourOnHost(b, worker_truetype_dependency, worker_target, optimize, core_options);
    check_step.dependOn(&tour_on_host.step);
    const tour_page = tourPageFiles(b, tour_on_host, webglDependency(b, worker_target, optimize, core_options));
    tour_step.dependOn(&b.addInstallDirectory(.{ .source_dir = tour_page.getDirectory(), .install_dir = .prefix, .install_subdir = "tour" }).step);
    const open_tour = b.addSystemCommand(&.{"node"});
    open_tour.addFileArg(b.path("web/check_host.mjs"));
    open_tour.addArg(browser);
    open_tour.addDirectoryArg(tour_page.getDirectory());
    open_tour.addFileInput(b.path("web/headless_page.mjs"));
    open_tour.expectExitCode(0);
    test_host.dependOn(&open_tour.step);

    const core_dependency = b.dependency("zui_core", core_options.on(target, optimize));
    const tour_session = b.createModule(.{ .root_source_file = b.path("src/tour_session.zig"), .target = target, .optimize = optimize, .imports = tourSessionImports(b, truetypeDeclaring(b, core_options.on(target, optimize)).?, target, optimize, core_options) });
    const tour_imports: []const std.Build.Module.Import = &.{
        .{ .name = "zui", .module = core_dependency.module("zui") },
        .{ .name = "zui_wire", .module = core_dependency.module("zui_wire") },
        .{ .name = "tour_session", .module = tour_session },
    };
    const demo_stream = tourTool(b, "demo-stream", "tools/demo_stream.zig", tour_imports, target, optimize);
    check_step.dependOn(&demo_stream.step);
    const write_stream = b.addRunArtifact(demo_stream);
    const stream = write_stream.addOutputFileArg("tour.zuiw");
    const expected = write_stream.addOutputFileArg("tour.expected");

    const wire_check = browserModule(b, "zui-web-wire-check", "src/browser_wire_check.zig", browser_target, optimize, core_options);
    const decode_in_client = b.addSystemCommand(&.{"node"});
    decode_in_client.addFileArg(b.path("web/check_stream.mjs"));
    decode_in_client.addArtifactArg(wire_check);
    decode_in_client.addFileArg(stream);
    decode_in_client.addFileArg(expected);
    for (tour_fonts) |font| decode_in_client.addFileArg(fontsDependency(b).path(font));
    decode_in_client.expectExitCode(0);
    test_demo.dependOn(&decode_in_client.step);

    const tour_frames = tourTool(b, "tour-frames", "tools/tour_frames.zig", &.{.{ .name = "tour_session", .module = tour_session }}, target, optimize);
    check_step.dependOn(&tour_frames.step);
    const run_in_worker = b.addSystemCommand(&.{"node"});
    run_in_worker.addFileArg(b.path("web/check_worker.mjs"));
    run_in_worker.addArtifactArg(client);
    run_in_worker.addArtifactArg(tour_worker);
    run_in_worker.addArtifactArg(tour_frames);
    for ([_][]const u8{ "web/tour_worker.mjs", "web/tour_thread.mjs", "web/worker_port.mjs", "web/shared_module.mjs" }) |worker_file| run_in_worker.addFileInput(b.path(worker_file));
    run_in_worker.expectExitCode(0);
    test_demo.dependOn(&run_in_worker.step);

    const replay_input = tourTool(b, "replay-input", "tools/replay_input.zig", tour_imports, target, optimize);
    check_step.dependOn(&replay_input.step);
    const input_in_browser = b.addSystemCommand(&.{"node"});
    input_in_browser.addFileArg(b.path("web/check_input.mjs"));
    input_in_browser.addArg(browser);
    input_in_browser.addArtifactArg(client);
    input_in_browser.addArtifactArg(replay_input);
    for ([_][]const u8{ "web/check_input.html", "web/input_recorder.mjs", "web/headless_page.mjs" }) |page_file| input_in_browser.addFileInput(b.path(page_file));
    input_in_browser.expectExitCode(0);
    test_input.dependOn(&input_in_browser.step);

    const site = siteFiles(b, client, tour_worker, webglDependency(b, target, optimize, core_options));
    site_step.dependOn(&b.addInstallDirectory(.{ .source_dir = site.getDirectory(), .install_dir = .prefix, .install_subdir = "site" }).step);
    const open_site = b.addSystemCommand(&.{"node"});
    open_site.addFileArg(b.path("web/check_site.mjs"));
    open_site.addArg(browser);
    open_site.addDirectoryArg(site.getDirectory());
    open_site.addFileInput(b.path("web/headless_page.mjs"));
    open_site.expectExitCode(0);
    test_site.dependOn(&open_site.step);

    // Only the reference `test-draw` compares with needs the sokol renderer.
    const zui_sokol_dependency = sokolDeclaring(b, core_options.on(target, optimize), "zui_sokol") orelse return;
    const draw_reference = tourTool(b, "draw-reference", "tools/draw_reference.zig", &.{
        .{ .name = "zui", .module = core_dependency.module("zui") },
        .{ .name = "zui_wire", .module = core_dependency.module("zui_wire") },
        .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
        .{ .name = "zui_truetype", .module = truetypeDeclaring(b, core_options.on(target, optimize)).?.module("zui_truetype") },
        .{ .name = "zui_tour", .module = b.dependency("zui_tour", core_options.on(target, optimize)).module("zui_tour") },
    }, target, optimize);
    const one_sample_reference = drawReference(b, draw_reference, stream, "1", "with-text");
    const four_sample_reference = drawReference(b, draw_reference, stream, "4", "without-text");

    const draw_in_browser = b.addSystemCommand(&.{"node"});
    draw_in_browser.addFileArg(b.path("web/check_draw.mjs"));
    draw_in_browser.addArg(browser);
    draw_in_browser.addArtifactArg(client);
    draw_in_browser.addFileArg(webglDependency(b, target, optimize, core_options).path("web/frame_drawer.mjs"));
    draw_in_browser.addFileArg(stream);
    draw_in_browser.addFileArg(one_sample_reference);
    draw_in_browser.addFileArg(four_sample_reference);
    for (tour_fonts) |font| draw_in_browser.addFileArg(fontsDependency(b).path(font));
    for ([_][]const u8{ "web/check_draw.html", "web/client.mjs", "web/headless_page.mjs" }) |page_file| draw_in_browser.addFileInput(b.path(page_file));
    draw_in_browser.expectExitCode(0);
    test_draw.dependOn(&draw_in_browser.step);
}

fn webModule(b: *std.Build, root_source_file: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions) *std.Build.Module {
    const core_dependency = b.dependency("zui_core", core_options.on(target, optimize));
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .imports = b.allocator.dupe(std.Build.Module.Import, &.{
            .{ .name = "zui", .module = core_dependency.module("zui") },
            .{ .name = "zui_app", .module = core_dependency.module("zui_app") },
            .{ .name = "zui_wire", .module = core_dependency.module("zui_wire") },
            .{ .name = "zui_webgl", .module = webglDependency(b, target, optimize, core_options).module("zui_webgl") },
            .{ .name = "zui_glyphs", .module = b.dependency("zui_glyphs", .{ .target = target, .optimize = optimize }).module("zui_glyphs") },
            .{ .name = "zui_truetype", .module = truetypeDeclaring(b, core_options.on(target, optimize)).?.module("zui_truetype") },
            .{ .name = "zui_fonts", .module = b.dependency("zui_fonts", .{ .target = target, .optimize = optimize }).module("zui_fonts") },
        }) catch @panic("out of memory"),
    });
}

fn fontsDependency(b: *std.Build) *std.Build.Dependency {
    return b.dependency("zui_fonts", .{});
}

/// The font system the client's text adds the page's fonts to, once it has
/// declared its module: until stb is fetched it returns from `build()`
/// before declaring it.
fn truetypeDeclaring(b: *std.Build, args: anytype) ?*std.Build.Dependency {
    const dependency = b.dependency("zui_truetype", args);
    return if (dependency.builder.modules.contains("zui_truetype")) dependency else null;
}

fn webglDependency(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions) *std.Build.Dependency {
    return b.dependency("zui_webgl", core_options.on(target, optimize));
}

/// The sokol renderer drawing `compared_frames` of `stream` with
/// `samples_per_pixel`, and its text only `"with-text"`.
fn drawReference(b: *std.Build, draw_reference: *std.Build.Step.Compile, stream: std.Build.LazyPath, samples_per_pixel: []const u8, text_choice: []const u8) std.Build.LazyPath {
    const write_reference = b.addRunArtifact(draw_reference);
    write_reference.addFileArg(stream);
    const reference = write_reference.addOutputFileArg(b.fmt("tour-{s}-{s}.reference", .{ samples_per_pixel, text_choice }));
    write_reference.addArgs(&.{ samples_per_pixel, text_choice });
    for (compared_frames) |frame_number| write_reference.addArg(b.fmt("{d}", .{frame_number}));
    return reference;
}

/// The frame of each of the tour's thirteen screens that `test-draw`
/// compares: the middle one of the 24 that `tools/demo_stream.zig` streams.
const compared_frames = compared: {
    var numbers: [13]u64 = undefined;
    for (&numbers, 0..) |*number, screen| number.* = 24 * screen + 12;
    break :compared numbers;
};

/// The fonts of `zui_fonts` that the tour adds, in the order it adds them,
/// so each takes the `FontId` the tour's text names.
const tour_fonts = [_][]const u8{
    "AtkinsonHyperlegible-Regular.ttf",
    "AtkinsonHyperlegible-Bold.ttf",
    "LiberationMono-Regular.ttf",
};

/// The licences of `tour_fonts`, published beside them.
const tour_font_licences = [_][]const u8{ "OFL.txt", "LiberationMono-LICENSE.txt" };

/// What the published page loads from `web/`, besides the client, the frame
/// drawer, the tour's worker and the fonts.
const site_scripts = [_][]const u8{
    "index.html",
    "cross_origin_isolation.mjs",
    "isolation_service_worker.js",
    "tour_page.mjs",
    "client.mjs",
    "input_recorder.mjs",
    "worker_port.mjs",
    "tour_worker.mjs",
    "tour_thread.mjs",
    "shared_module.mjs",
};

/// The published site: the page, the client, the frame drawer, the tour's
/// worker, and the tour's fonts with their licences.
fn siteFiles(b: *std.Build, client: *std.Build.Step.Compile, worker: *std.Build.Step.Compile, webgl_dependency: *std.Build.Dependency) *std.Build.Step.WriteFile {
    const site = b.addWriteFiles();
    for (site_scripts) |script| _ = site.addCopyFile(b.path(b.fmt("web/{s}", .{script})), script);
    _ = site.addCopyFile(webgl_dependency.path("web/frame_drawer.mjs"), "frame_drawer.mjs");
    _ = site.addCopyFile(client.getEmittedBin(), "zui-web.wasm");
    _ = site.addCopyFile(worker.getEmittedBin(), "zui-web-tour.wasm");
    var font_urls: std.ArrayList(u8) = .empty;
    font_urls.append(b.allocator, '[') catch @panic("out of memory");
    for (tour_fonts, 0..) |font, index| {
        const url = b.fmt("fonts/{s}", .{font});
        _ = site.addCopyFile(fontsDependency(b).path(font), url);
        font_urls.print(b.allocator, "{s}\"{s}\"", .{ if (index == 0) "" else ",", url }) catch @panic("out of memory");
    }
    font_urls.append(b.allocator, ']') catch @panic("out of memory");
    _ = site.add("truetype-fonts.json", font_urls.items);
    for (tour_font_licences) |licence| _ = site.addCopyFile(fontsDependency(b).path(licence), b.fmt("fonts/{s}", .{licence}));
    return site;
}

fn tourSessionImports(b: *std.Build, truetype_dependency: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions) []const std.Build.Module.Import {
    const core_dependency = b.dependency("zui_core", core_options.on(target, optimize));
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "zui", .module = core_dependency.module("zui") },
        .{ .name = "zui_app", .module = core_dependency.module("zui_app") },
        .{ .name = "zui_wire", .module = core_dependency.module("zui_wire") },
        .{ .name = "zui_tour", .module = b.dependency("zui_tour", core_options.on(target, optimize)).module("zui_tour") },
        .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
        .{ .name = "zui_webgl", .module = webglDependency(b, target, optimize, core_options).module("zui_webgl") },
    }) catch @panic("out of memory");
}

/// The tour for a Web Worker, stepped by the page.
fn tourWorker(b: *std.Build, truetype_dependency: *std.Build.Dependency, worker_target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions) *std.Build.Step.Compile {
    return workerModule(b, "zui-web-tour", "src/tour_worker.zig", tourSessionImports(b, truetype_dependency, worker_target, optimize, core_options), worker_target, optimize);
}

/// The tour target: `zui_tour.App` on `zui_web.Host`, `zui_webgl.Renderer`
/// and `zui_truetype.Text`, in the worker the page starts.
fn tourOnHost(b: *std.Build, truetype_dependency: *std.Build.Dependency, worker_target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions) *std.Build.Step.Compile {
    const core_dependency = b.dependency("zui_core", core_options.on(worker_target, optimize));
    const imports = b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "zui_app", .module = core_dependency.module("zui_app") },
        .{ .name = "zui_web", .module = webModule(b, "src/root.zig", worker_target, optimize, core_options) },
        .{ .name = "zui_webgl", .module = webglDependency(b, worker_target, optimize, core_options).module("zui_webgl") },
        .{ .name = "zui_truetype", .module = truetype_dependency.module("zui_truetype") },
        .{ .name = "zui_tour", .module = b.dependency("zui_tour", core_options.on(worker_target, optimize)).module("zui_tour") },
    }) catch @panic("out of memory");
    return workerModule(b, "zui-tour", "examples/tour.zig", imports, worker_target, optimize);
}

/// What the tour target's page loads from `web/`, besides its page,
/// `tour.html`, the frame drawer and the module.
const tour_page_scripts = [_][]const u8{
    "cross_origin_isolation.mjs",
    "isolation_service_worker.js",
    "host_page.mjs",
    "host_worker.mjs",
    "input_recorder.mjs",
    "page_environment.mjs",
    "worker_port.mjs",
    "shared_module.mjs",
    "tour_thread.mjs",
};

/// What `zig build tour` writes: the tour target's page, the scripts its
/// page and worker load, its module, and its fonts' licences.
fn tourPageFiles(b: *std.Build, tour_on_host: *std.Build.Step.Compile, webgl_dependency: *std.Build.Dependency) *std.Build.Step.WriteFile {
    const page = b.addWriteFiles();
    _ = page.addCopyFile(b.path("web/tour.html"), "index.html");
    for (tour_page_scripts) |script| _ = page.addCopyFile(b.path(b.fmt("web/{s}", .{script})), script);
    _ = page.addCopyFile(webgl_dependency.path("web/frame_drawer.mjs"), "frame_drawer.mjs");
    _ = page.addCopyFile(tour_on_host.getEmittedBin(), "zui-tour.wasm");
    for (tour_font_licences) |licence| _ = page.addCopyFile(fontsDependency(b).path(licence), b.fmt("fonts/{s}", .{licence}));
    return page;
}

/// A module for a Web Worker: WebAssembly on memory the worker shares
/// with the workers its tasks run on, each of which sets its own stack
/// pointer and thread-local storage.
fn workerModule(b: *std.Build, name: []const u8, root_source_file: []const u8, imports: []const std.Build.Module.Import, worker_target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = worker_target,
        .optimize = optimize,
        .single_threaded = false,
        .imports = imports,
    });
    module.export_symbol_names = &.{ "__stack_pointer", "__wasm_init_tls" };
    const worker = b.addExecutable(.{ .name = name, .root_module = module });
    worker.entry = .disabled;
    worker.rdynamic = true;
    worker.import_memory = true;
    worker.shared_memory = true;
    worker.stack_size = 4 << 20;
    worker.max_memory = 1 << 30;
    return worker;
}

/// A native program that runs the tour, or draws it.
fn tourTool(b: *std.Build, name: []const u8, root_source_file: []const u8, imports: []const std.Build.Module.Import, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const tool = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{ .root_source_file = b.path(root_source_file), .target = target, .optimize = optimize, .imports = imports }),
    });
    linkThroughLlvmOnLinux(tool);
    return tool;
}

/// A WebAssembly module with no entry point, whose exports the page calls.
fn browserModule(b: *std.Build, name: []const u8, root_source_file: []const u8, browser_target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core_options: CoreOptions) *std.Build.Step.Compile {
    const module = b.addExecutable(.{ .name = name, .root_module = webModule(b, root_source_file, browser_target, optimize, core_options) });
    module.entry = .disabled;
    module.rdynamic = true;
    return module;
}

/// Zig 0.16's ELF linker rejects the
/// R_X86_64_PC64 relocations that GCC 16's crt1.o carries, and LLD crashes
/// the compiler unless the LLVM backend produced the objects.
fn linkThroughLlvmOnLinux(compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().os.tag == .linux) {
        compile.use_llvm = true;
        compile.use_lld = true;
    }
}

/// The sokol renderer's package, once it has declared `module_name`: until its
/// own lazy libraries are fetched it returns from `build()` before declaring
/// any, and asking for a module it lacks panics.
fn sokolDeclaring(b: *std.Build, args: anytype, module_name: []const u8) ?*std.Build.Dependency {
    const dependency = b.lazyDependency("zui_sokol", args) orelse return null;
    return if (dependency.builder.modules.contains(module_name)) dependency else null;
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

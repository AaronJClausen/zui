<h1><img src="assets/zui-social.svg" alt="zui"></h1>

An immediate-mode UI layout library for Zig, in the spirit of
[Clay](https://github.com/nicbarker/clay). Each frame, the application
declares its UI as nested function calls. zui computes the layout and
returns a flat list of render commands for the application's own
renderer to draw.

**Status:** pre-alpha. The design is specified in [SPEC.md](SPEC.md).
Implemented so far:

- **0.1–0.4:** the `Context`, the layout passes, text wrapping, render
  commands, input, focus, clipping, scrolling, floating elements, idling
  at 0% CPU, and the `zui_widgets`, `zui_reflect` and `zui_testing`
  modules.
- **0.5–0.6 and stage 1:** performance, `zig build bench` and
  `bench-compare`, instruction counts under Callgrind that CI checks,
  and tracing into [Tracy](https://github.com/wolfpld/tracy) through
  `zui_tracy`.
- **Stage 2:** `Context(config)` with the text contract and limits,
  frame records, the environment, and sources, with `zui_async`'s
  defaults.
- **Stage 3:** the renderer and host contracts, checked at compile time
  and by conformance suites, `Config.features`, and `zui_app`.
- **Stage 4:** the first native host, for Windows.
- **Stage 5:** relaying and replaying sessions, `zui_wire` for an
  application in another process, and file watches.
- **Stage 6:** faster text, static styles, `grow` and `grow_equal`,
  aspect ratios, dividers, right-to-left layout and flex wrap.
- **Stage 7:** gestures, and drag and drop.
- **After stage 7:** benchmarks that can be trusted, and the speedups
  they found.
- **Stage 8:** effects: gradients, shadows, backdrop blur, transforms,
  materials, and HDR and wide-gamut color.
- **Stage 9:** `zui_debug`'s inspector, semantics and accessibility,
  safety sweeps, and the tour in a browser.
- **Stage 10, begun:** the Linux host on Wayland, host services, custom
  title bars, many windows, and who owns the loop.

[docs/feature-tour.html](docs/feature-tour.html) walks through every
shipped feature in the code a consumer writes, with semantic
highlighting; open it in a browser, or read
[docs/feature-tour.md](docs/feature-tour.md).

Next, in the order of SPEC.md §21: the rest of the effects and of the
inspector, more hosts, motion and text editing. [ROADMAP.md](ROADMAP.md)
keeps the queue of work in order, with each item's plan in
[`roadmap/`](roadmap/), and [ARCHITECTURE.md](ARCHITECTURE.md) shows how
the pieces connect.

The loop by hand, which `zui_app.run` runs for you (SPEC.md §6.1):

```zig
const Ui = zui.Context(.{ .Text = MyFonts }); // MyFonts declares zuiMeasure
var ui = try Ui.init(gpa, io, &fonts);
defer ui.deinit(gpa);

comptime zui.checkHostAndRenderer(MyHost, MyRenderer);
var events: [256]zui.Event = undefined;
var text: [256]u8 = undefined;
var builder: zui.RecordBuilder = .init(&events, &text);
while (host.zuiPoll(.main, &builder)) { // the host sets the time, viewport and scale, and appends events
    ui.beginFrame(&builder.record());
    ui.open(.{ .id = .of("toolbar"), .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(40) }, .padding = .all(4) }, .decoration = .{ .background = .rgb(0x202020) } });
    ui.text("Hello, zui", .{ .color = .white });
    ui.close();
    const frame = ui.endFrame();
    try renderer.zuiSubmit(host.zuiSurface(.main), frame);
    host.zuiApply(.main, frame.requests()); // the cursor, the IME window
    ui.release(frame);
    host.zuiWait(ui.nextFrame());
}
```

Between the two, an application that owns its loop keeps `zui_app`'s
turn: which windows are due, the render thread, host requests and
notices. It steps a `zui_app.Session(App)` from its own frame, on a host
that declares neither `zuiWait` nor `zuiRun` (a window it already has).
A host whose platform owns the loop declares `zuiRun`, and `zui_app.run`
hands it a `zui.Driver` to call from the platform's callbacks (SPEC.md
§16.3, §19.5); no shipped host declares it yet:

```zig
var session: zui_app.Session(App) = undefined;
try session.start(.{ .gpa = gpa, .io = io }, .{ .title = "panel" });
defer session.stop();
while (editor.running()) {
    if (try session.step()) |next| editor.redrawAt(next) else break; // never blocks
}
```

With `.Sources = AppSources` in the `Config`, a struct whose fields are
sources (SPEC.md §14), `beginFrame` and `nextFrame` also take
`&app.sources`, the record is `builder.recordWith(Ui.Deliveries)`, and
declaration reads them with `ui.source(.quotes)`:

```zig
const AppSources = struct {
    battery: zui_async.Latest(f32) = .{},
    thumbnails: zui_async.KeyedLoads(u64, LoadError!Texture, .{ .capacity = 128, .owns_resources = true }) = .{},
};

// Any thread:
waker.wakeIf(app.sources.battery.publish(0.8));

// Declaration asks; it starts nothing:
const thumbnail = ui.source(.thumbnails).get(path_hash);

// The loader, after endFrame, starts what was asked for and frees what went unread:
var to_start = app.sources.thumbnails.toStart(waker);
while (to_start.next()) |load| group.async(io, loadThumbnail, .{load});
var to_release = app.sources.thumbnails.toRelease();
while (to_release.next()) |released| if (released) |texture| unload(texture) else |_| {};
```

## Requirements

- Zig **0.16.0**

## Using zui in your project

```sh
zig fetch --save git+https://github.com/AaronJClausen/zui
```

```zig
// build.zig
const zui = b.dependency("zui", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui", zui.module("zui"));
// Optional:
exe.root_module.addImport("zui_async", zui.module("zui_async"));
exe.root_module.addImport("zui_widgets", zui.module("zui_widgets"));
exe.root_module.addImport("zui_reflect", zui.module("zui_reflect"));
exe.root_module.addImport("zui_app", zui.module("zui_app"));
exe.root_module.addImport("zui_wire", zui.module("zui_wire"));
exe.root_module.addImport("zui_debug", zui.module("zui_debug"));
exe.root_module.addImport("zui_motion", zui.module("zui_motion"));
exe.root_module.addImport("zui_color", zui.module("zui_color"));
exe.root_module.addImport("zui_design", zui.module("zui_design"));
tests.root_module.addImport("zui_testing", zui.module("zui_testing"));
// Tracing into Tracy; `.@"zui-tracy" = true` in the options above links it.
exe.root_module.addImport("zui_tracy", zui.module("zui_tracy"));
// Text: what font systems and renderers share, and the bundled typefaces.
exe.root_module.addImport("zui_glyphs", zui.module("zui_glyphs"));
exe.root_module.addImport("zui_fonts", zui.module("zui_fonts"));
// The tour and the showcase, which a renderer's or a host's targets run.
exe.root_module.addImport("zui_tour", zui.module("zui_tour"));
exe.root_module.addImport("zui_showcase", zui.module("zui_showcase"));
// The default font system, which builds stb_truetype, so it is a package of its own.
const zui_truetype = zui.builder.dependency("zui_truetype", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui_truetype", zui_truetype.module("zui_truetype"));
```

```zig
var tokens: zui.design.Tokens(Ui, void) = .{};
_ = zui_design.resolve(zui_design.default, .from(ui.environment(), .{}), &tokens);
const widgets: zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui)) = .{ .skin = .{ .tokens = &tokens } };

if (widgets.button(ui, .of("save"), "Save", .{})) save();
_ = widgets.slider(ui, .of("volume"), &settings.volume, .{ .max = 100 });
_ = zui_reflect.inspector(widgets, ui, .of("settings"), &settings);
```

SPEC.md §19.2 lists the widgets, §16.7 the skin that styles them, and
§19.3 covers the inspector's typed options. [text/](text/README.md)
covers fonts.

## Packages

Renderers and hosts are packages of their own, reached through the `zui`
dependency's builder as `zui.builder.dependency("<name>", …)`, so an
application fetches only the libraries of the renderers it uses. Give
each the same `.@"zui-tracy"` you give `zui`, if any, so they build one
`zui` module and their types match. Each package's README covers its
API, what it draws or reports, its limits, and its build steps.

| Package | Directory | What it is |
|---|---|---|
| `zui` and its modules | `core/`, re-exported by the root | the engine, `zui_async`, `zui_widgets`, `zui_reflect`, `zui_app`, `zui_wire`, `zui_debug`, `zui_motion`, `zui_color`, `zui_design`, `zui_testing` and `zui_tracy` |
| `zui_glyphs`, `zui_truetype`, `zui_fonts` | [text/](text/README.md) | the layout that font systems and renderers share, the default font system on stb_truetype, and the bundled typefaces |
| `zui_raylib` | [renderers/raylib/](renderers/raylib/README.md) | a raylib renderer and adapter host, the reference backend |
| `zui_sokol` | [renderers/sokol/](renderers/sokol/README.md) | a sokol renderer on D3D11, Metal or OpenGL, drawing every optional command and extended colors |
| `zui_terminal` | [renderers/terminal/](renderers/terminal/README.md) | a renderer and host on the terminal, in 24-bit-color cells |
| `zui_webgl` | [renderers/webgl/](renderers/webgl/README.md) | the browser's drawing of a frame through WebGL 2 |
| `zui_host` | [hosts/native/](hosts/native/README.md) | the native hosts, for Windows and for Linux on Wayland or X11 |
| `zui_web` | [hosts/web/](hosts/web/README.md) | the web host, the tour on it as the published page, and the thin client over `zui_wire` the checks compare it with |
| `zui_tour` | [apps/tour/](apps/tour/README.md) | zui shown four ways: an operations console, the same console with its features pointed out, field cases and spectacles, for any host and renderer |
| `zui_showcase` | [apps/showcase/](apps/showcase/) | one small application every renderer draws, so their frames can be compared |
| `zui_themes` | [themes/](themes/) | skins in the design languages of Windows, macOS, GNOME and KDE; a skeleton today |
| — | [examples/](examples/) | a template project and samples; a skeleton today |

## Development

Run from the root:

| Command | What it does |
|---|---|
| `zig build test` | run core's tests (add `-Doptimize=ReleaseSafe` or `ReleaseFast` to test other modes) |
| `zig build check` | compile core without producing output; add `-Dtarget=wasm32-freestanding` to check another target |
| `zig build test-all` | run `zig build test` in every package's directory |
| `zig build check-all` | run `zig build check` in every package's directory |
| `zig build bench` | run the benchmarks |
| `zig build fmt` | format every Zig source file |
| `zig build fmt-md` | format every Markdown file with mdformat; needs [uv](https://docs.astral.sh/uv/) |
| `zig build ci` | run CI's jobs for what `HEAD` changes, on this machine: Linux's in a container, Windows' and macOS' as cross-checks |
| `zig build hooks` | turn on the checked-in git hooks: format and syntax checks before a commit, CI's jobs before a push |

[docs/development.md](docs/development.md) lists every step and what CI
runs, and how a backend runs the conformance suites;
[docs/benchmarking.md](docs/benchmarking.md) covers profiling and
measuring on a quiet machine. Each package's own steps are in its
README.

## License

MIT; see [LICENSE](LICENSE).

The zui logo is adapted from the
[Zig logo](https://codeberg.org/ziglang/logo) and, like it, is licensed
under CC BY-SA 4.0; see [assets/LICENSE.md](assets/LICENSE.md). zui is
not affiliated with or endorsed by the Zig Software Foundation.

The fonts `zui_fonts` bundles, which `zui_truetype` draws in by default
and the tours use, are under the SIL Open Font License 1.1: Atkinson
Hyperlegible, copyright 2020 Braille Institute of America, Inc. (see
[text/fonts/OFL.txt](text/fonts/OFL.txt)), and Liberation Mono,
copyright 2010 Google Corporation and 2012 Red Hat, Inc. (see
[text/fonts/LiberationMono-LICENSE.txt](text/fonts/LiberationMono-LICENSE.txt)).

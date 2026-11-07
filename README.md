<h1><img src="assets/zui-social.svg" alt="zui"></h1>

An immediate-mode UI layout library for Zig, in the spirit of
[Clay](https://github.com/nicbarker/clay). Each frame, the application
declares its UI as nested function calls. zui computes the layout and
returns a flat list of render commands for the application's own renderer
to draw.

**Status:** pre-alpha. The design is specified in [SPEC.md](SPEC.md).
Implemented so far:
- **0.1:** the `Context` and its memory, element declaration, the layout
  passes, text wrapping with a measurement cache, and render commands.
- **0.2:** input; hover, press, click and focus (including tab order and
  focus scopes); clipping with culling; scroll containers driven by the
  wheel; floating elements in their own paint layers; and per-element
  state that persists across frames.
- **0.3:** `beginFrame` waiting for a render thread to release a frame,
  and a way for an idle application to sleep at 0% CPU. Its task pools
  were deleted in stage 2, to be replaced by sources.
- **0.4:** three optional modules built only on the public API:
  - `zui_widgets`: button, checkbox, slider, text field, dropdown and
    disclosure;
  - `zui_reflect`: an editor generated from any struct, with typed
    options;
  - `zui_testing`: font-independent metrics, a driver that clicks, drags
    and types by element id, golden snapshots, and command checks.
- **0.5:** performance. Layout and emission of 4,096 boxes went from
  216 µs to 97 µs on a 2020 desktop core, and 1,000 cached texts from
  346 µs to about 170 µs.
  Text contracts with thread-safe measurement get parallel measurement for
  cold frames (4.3× as fast on 10 cores), and `zig build bench` measures
  all of it.
- **0.6, in part:** `zig build bench-compare`, which runs two commits'
  benchmarks alternately and reports each change with its spread;
  startup benchmarks for `init`, `initBuffer` and first frames; and the
  design of sources, demand and the loader that replace task pools.
- **Stage 1:** instruction counts of every single-threaded benchmark
  under Callgrind, identical on every machine, with CI failing on more
  than 2% growth over the parent commit; and a tracer contract that sees
  every step of a frame as a zone, with `zui_tracy` sending them to the
  [Tracy](https://github.com/wolfpld/tracy) profiler. Without a tracer,
  tracing compiles to nothing.
- **Stage 2:** `Context(config)` with the text contract and
  `Config.limits`; a frame record with time, scale, zoom and input as an
  ordered event log over a pointer table; `endFrame` that always returns
  a frame; `nextFrame()`; letter spacing, measured through the text
  contract's key; and the environment (theme, contrast, reduced motion,
  locale and more) with the cursor and text-input requests a frame makes
  of its host; and sources: application memory that producers publish
  into from any thread, swapped into each frame at `beginFrame`, read
  with `ui.source(.field)`, and reporting what the frame read so the
  application's loader knows what to start or release; and `zui_async`,
  the default sources: `Latest` for the newest value, `Stream` for every
  item in order, `Task` for one piece of work with its status, and
  `KeyedLoads` for many loads driven by what the UI asks for, each
  checked by `zui_testing.expectSourceConforms` under ThreadSanitizer and
  on a single-threaded `Io`. The backends are on this API, and the
  demo's thumbnail grid loads through `KeyedLoads` without the UI thread
  ever waiting, and idles at 0% CPU.
- **Stage 5, begun:** `ui.relayTo(listener)` hands a listener each
  record as applied, with what each source delivered, during
  `beginFrame`; fed back with its deliveries, a relayed session replays
  to the same commands. `zui_wire` writes those records and the frames
  that come out as bytes, each frame as the changes from the one before,
  and reads them back in another process: zui-sokol's tour averages 240
  bytes a frame instead of 24 KB on all but its stress screen, and a
  stream carries its fonts' fingerprint so a reader with other fonts
  refuses it.
- **Stage 6, early:** a text that fits is laid out as one line without
  walking its words, and a whole-string cache makes a warm text one probe
  instead of one per word: 1,000 warm texts lay out in about 100 µs. The
  box tree of 4,096 boxes lays out and emits its commands in about 94 µs.
- **Stage 3:** the renderer contract (`zuiSubmit`, the surfaces
  it draws into, the optional commands it draws), checked at compile time
  by `zui.checkRenderer`, and a `RenderCommand` union generated with
  exactly the variants a renderer draws, so its exhaustive `switch` names
  nothing else. zui-raylib, zui-sokol and zui-terminal are renderers.
  The host contract (`zuiPoll`, `zuiWaker`, `zuiWait`, `zuiSurface`,
  `zuiApply`), checked by `zui.checkHost`, with `zui.RecordBuilder` for
  the record a host fills and `zui.checkHostAndRenderer` failing to
  compile when a host and a renderer share no kind of surface. And the
  conformance suites every implementation runs in its own CI:
  `zui_testing.expectRendererConforms` draws a reference scene, deep
  clips and out-of-bounds commands and reads the pixels back, and
  `zui_testing.expectHostConforms` checks a host's event order, sticky
  and cross-thread wakes, and waits. All three backends pass the renderer
  suite in CI. `Config.features` turns semantics, gestures, wrapping and
  safety sweeps on or off; calling an API whose feature is off fails to
  compile, naming the field to set. And `zui_app`, which runs the whole
  loop from one call, `zui_app.run(App, init, .{ .title = "demo" })`,
  submitting on a render thread when the renderer allows and reporting
  its capabilities, fallbacks and every exceeded limit once. zui-raylib is
  the first host: the demo runs through `zui_app` on it, and presents its
  first frame about 290 ms after the process starts, all but 5 ms of it
  raylib opening its window.

- **Stage 4:** the first native host, for Windows, in
  [zui-host](https://github.com/AaronJClausen/zui-host): its own message
  loop on a thread of its own, per-monitor scale, the environment
  (dark mode, high contrast, animations, power), lifecycle events
  (Ctrl+C and the session ending as a terminate request, sleep, low
  memory), dropped files, the cursor, the IME window and the clipboard,
  passing zui's host suite; and the system's material (Mica) behind the
  window where nothing is drawn, reported as
  `Environment.system_material`, so the same code draws its own
  background where there is none. zui-sokol's tour runs on it unchanged,
  through `zui_app.run`, drawn by zui-sokol's renderer into the native
  window, and idles at 0% CPU. `zui_app` makes an application's own text
  contract when the renderer does not measure (`pub const Text`), and
  lets it set its zoom and add events to each record (`zuiRecord`).
  The record carries the new events: `ui.filesDropped()` and
  `ui.lifecycle()`.

The reference backend, its adapter host and the demo application live in
[zui-raylib](https://github.com/AaronJClausen/zui-raylib); the other
backends are [zui-sokol](https://github.com/AaronJClausen/zui-sokol) and
[zui-terminal](https://github.com/AaronJClausen/zui-terminal); native
hosts live in [zui-host](https://github.com/AaronJClausen/zui-host).

Next, in the order of SPEC.md §21: the wire format, and from there text,
layout, gestures, effects, an inspector and accessibility, more hosts,
motion and text editing. The box tree's layout budget (P4) comes early,
as the text fast path and string cache did.
[ROADMAP.md](ROADMAP.md) keeps the queue of work in order, and
[ARCHITECTURE.md](ARCHITECTURE.md) shows how the pieces connect.

The loop by hand, which `zui_app.run` runs for
you (SPEC.md §6.1):

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

With `.Sources = AppSources` in the `Config`, a struct whose fields are
sources (SPEC.md §14), `beginFrame` and `nextFrame` also take
`&app.sources`, the record is `builder.recordWith(Ui.Deliveries)`, and declaration reads them with `ui.source(.quotes)`:

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

## Development

| Command | What it does |
|---|---|
| `zig build test` | run the unit, golden, randomized-invariant, widget and compile-error tests (add `-Doptimize=ReleaseSafe` or `ReleaseFast` to test other modes) |
| `zig build check` | compile one full frame, every widget, the default sources and the test driver without producing output; add `-Dtarget=wasm32-freestanding` to check another target |
| `zig build test -Dzui-debug=true` | keep id names, so duplicate-id and unbalanced-tree panics name the element |
| `zig build test -Dzui-tracy=true` | fetch Tracy and test `zui_tracy` with its client linked |
| `zig build test -Dzui-sanitize-thread=true` | run the tests under ThreadSanitizer, through LLVM, on Linux; ThreadSanitizer needs ASLR entropy of at most 28 bits (`sysctl vm.mmap_rnd_bits=28`), or a container started with `--security-opt seccomp=unconfined` |
| `zig build bench` | run the benchmarks in ReleaseFast; add `-- --check-targets` to fail on a missed performance target, or `-- --compare old.json` after `-- --json old.json` to check for regressions |
| `zig build counts` | count each benchmark's instructions per frame under Callgrind, on x86_64 Linux with Valgrind (on Windows, in a Linux container); add `-- --json counts.json` to save them and `-- --compare counts.json` to fail on more than 2% growth |
| `zig build bench-compare -- main` | run the benchmarks of `main` and of the working tree alternately, and report each time's median change and its spread; `-- <base> <head>` compares two commits (SPEC.md §20.3) |
| `zig build docs` | generate API documentation into `zig-out/docs` |
| `zig build fmt` | format every Zig source file |
| `zig build fmt-check` | fail if any file is not formatted, as CI does |

CI runs:
- the format check;
- the tests in three optimize modes on Linux, Windows and macOS, plus as
  a 32-bit x86 Linux program;
- `check` for six targets: 32- and 64-bit, big-endian, freestanding and
  WebAssembly;
- the benchmarks, failing on any allocation after `init`. Times and the
  SPEC.md §20.2 budgets are reported in the job summary but not compared:
  runners vary too much. Check for slowdowns on your own machine with
  `zig build bench-compare`;
- instruction counts of this commit and its parent, failing on more than
  2% growth;
- the tests under ThreadSanitizer, which stress every `zui_async` source
  with producers on other threads;
- `zui_tracy` with Tracy's client, on Linux, Windows and macOS.

Those targets exist to catch assumptions about the host machine early:
the first 32-bit build found two places that used a 64-bit hash as an
index.

### Profiling

Set `.features = .{ .Tracer = zui_tracy.Tracer }` in the `Config`, call
`zui_tracy.frameMark()` after each presented frame, build with
`-Dzui-tracy=true`, and connect Tracy's profiler of the same version
(0.14.1). Every step of `beginFrame` and `endFrame` is a zone.
zui-raylib's demo does all of this with `zig build demo
-Dzui-tracy=true`. Without the profiler's window, Tracy's
`tracy-capture -o demo.tracy` saves a trace (run the demo with
`TRACY_NO_EXIT=1` so it waits for the capture to finish) and
`tracy-csvexport demo.tracy` lists its zones.

To keep noise out of a profile or a timing:
- pin the process to one core (`taskset -c 2` on Linux, `start /affinity 4`
  on Windows) and keep other work off it;
- fix the CPU frequency: turn off turbo and use a performance power plan,
  or `cpupower frequency-set -g performance`;
- compare two builds by alternating them, never one after the other, as
  `zig build bench-compare` does; and prefer `zig build counts`, which no
  machine's noise can move.

### Conformance suites

A renderer or host proves its contract by running zui's suite in its own
CI. Each suite takes a harness: a value that gives the suite what only
the implementation knows how to do, such as making a drawing target and
reading its pixels back, or making the OS report an event.

```zig
// src/conformance.zig, a test root importing the backend and zui_testing
test "the renderer passes zui's renderer suite" {
    var harness: MyHarness = undefined; // declares config, renderer, beginDraw, and pixel when it can read back
    harness.init();
    defer harness.deinit();
    try zui_testing.expectRendererConforms(MyRenderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io });
}
```

The recipe the backends follow:
- `src/conformance.zig` holds the harness and the test, built by a
  `conformance` step in `build.zig`;
- CI runs `zig build conformance`, under `xvfb-run --auto-servernum` on
  Linux when the backend needs a window for its graphics context;
- a backend whose test step needs no display adds `conformance` to
  `test` too, as zui-terminal does.

`zui_testing.findRendererViolation` and `findHostViolation` return the
first violation instead of failing, and the doc comments of
`expectRendererConforms` and `expectHostConforms` list what a harness
declares. zui-raylib, zui-sokol and zui-terminal each have a
`src/conformance.zig` to copy.

The repository uses LF line endings everywhere (see `.gitattributes`),
whatever your `core.autocrlf` setting.

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
tests.root_module.addImport("zui_testing", zui.module("zui_testing"));
// Tracing into Tracy; `.@"zui-tracy" = true` in the options above links it.
exe.root_module.addImport("zui_tracy", zui.module("zui_tracy"));
```

```zig
const widgets: zui_widgets.Widgets(Ui) = .{};

if (widgets.button(ui, .of("save"), "Save", .{})) save();
_ = widgets.slider(ui, .of("volume"), &settings.volume, .{ .max = 100 });
_ = zui_reflect.inspector(widgets, ui, .of("settings"), &settings);
```

SPEC.md §19.2 lists the widgets, and §19.3 covers the inspector's typed
options.

## License

MIT; see [LICENSE](LICENSE).

The zui logo is adapted from the [Zig logo](https://codeberg.org/ziglang/logo)
and, like it, is licensed under CC BY-SA 4.0; see
[assets/LICENSE.md](assets/LICENSE.md). zui is not affiliated with or endorsed
by the Zig Software Foundation.

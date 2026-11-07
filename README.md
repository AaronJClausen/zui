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
- **Stage 1, in part:** instruction counts of every single-threaded
  benchmark under Callgrind, identical on every machine, with CI failing
  on more than 2% growth over the parent commit.
- **Stage 2, in part:** `Context(config)` with the text contract and
  `Config.limits`; a frame record with time, scale, zoom and input as an
  ordered event log over a pointer table; `endFrame` that always returns
  a frame; and `nextFrame()`.

The reference backend and demo application live in
[zui-raylib](https://github.com/AaronJClausen/zui-raylib). It and the
other backends still use the API from before stage 2.

Next, in the order of SPEC.md §21: a tracer contract (stage 1); then the rest of stage 2: the environment, sources
with `zui_async`, and the backends moved to the new API. After that come
the renderer and host contracts with `zui_app`, a native Windows host, the
wire format, and from there text, layout, gestures, effects, an
inspector and accessibility, more hosts, motion and text editing.
[ROADMAP.md](ROADMAP.md) keeps the queue of work in order, and
[ARCHITECTURE.md](ARCHITECTURE.md) shows how the pieces connect.

Today's API, until stage 3 adds the host and renderer contracts of
SPEC.md §6.1:

```zig
const Ui = zui.Context(.{ .Text = MyFonts }); // MyFonts declares zuiMeasure
var ui = try Ui.init(gpa, io, &fonts);
defer ui.deinit(gpa);

ui.beginFrame(&.{ .params = .{ .now = now, .viewport = .{ 800, 600 } }, .events = events });
ui.open(.{ .id = .of("toolbar"), .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(40) }, .padding = .all(4) }, .decoration = .{ .background = .rgb(0x202020) } });
ui.text("Hello, zui", .{ .color = .white });
ui.close();
const frame = ui.endFrame();
for (frame.commands()) |command| renderer.draw(command);
ui.release(frame);
waitFor(ui.nextFrame());
```

## Requirements

- Zig **0.16.0**

## Development

| Command | What it does |
|---|---|
| `zig build test` | run the unit, golden, randomized-invariant, widget and compile-error tests (add `-Doptimize=ReleaseSafe` or `ReleaseFast` to test other modes) |
| `zig build check` | compile one full frame, every widget and the test driver without producing output; add `-Dtarget=wasm32-freestanding` to check another target |
| `zig build test -Dzui-debug=true` | keep id names, so duplicate-id and unbalanced-tree panics name the element |
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
  2% growth.

Those targets exist to catch assumptions about the host machine early:
the first 32-bit build found two places that used a 64-bit hash as an
index.

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
exe.root_module.addImport("zui_widgets", zui.module("zui_widgets"));
exe.root_module.addImport("zui_reflect", zui.module("zui_reflect"));
tests.root_module.addImport("zui_testing", zui.module("zui_testing"));
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

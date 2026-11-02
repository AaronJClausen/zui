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
- **0.3:** `TaskPool`s of background work that is canceled when its
  element stops being declared; `needsFrame`, so an idle application can
  sleep at 0% CPU; and `beginFrame` waiting for a render thread to
  release a frame.
- **0.4:** three optional modules built only on the public API:
  - `zui_widgets`: button, checkbox, slider, text field, dropdown and
    disclosure;
  - `zui_reflect`: an editor generated from any struct, with typed
    options;
  - `zui_testing`: font-independent metrics, a driver that clicks, drags
    and types by element id, golden snapshots, and command checks.
- **0.5:** performance. Layout and emission of 4,096 boxes went from
  216 µs to 97 µs on a 2020 desktop core, and 1,000 cached texts from
  346 µs to about 170 µs, which meets both of SPEC.md §6.5's targets.
  Platforms with thread-safe text measurement get parallel measurement for
  cold frames (4.3× as fast on 10 cores), and `zig build bench` measures
  all of it.

The reference backend and demo application live in
[zui-raylib](https://github.com/AaronJClausen/zui-raylib). Later work
(layout islands, flex wrap, static subtrees) ships only if the benchmarks
show a win; see SPEC.md §16.

```zig
const Ui = zui.Context(.{}, MyPlatform);
var ui = try Ui.init(gpa, io, &platform);
defer ui.deinit(gpa);

ui.beginFrame(.{ .viewport = .{ 800, 600 } });
ui.open(.{ .id = .of("toolbar"), .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(40) }, .padding = .all(4) }, .background = .rgb(0x202020) });
ui.text("Hello, zui", .{ .color = .white });
ui.close();
const frame = ui.endFrame() catch ui.lastFrame();
for (frame.commands()) |command| renderer.draw(command);
ui.release(frame);
```

## Requirements

- Zig **0.16.0**

## Development

| Command | What it does |
|---|---|
| `zig build test` | run the unit, golden, randomized-invariant, widget and compile-error tests (add `-Doptimize=ReleaseSafe` or `ReleaseFast` to test other modes) |
| `zig build check` | compile one full frame, every widget and the test driver without producing output; add `-Dtarget=wasm32-freestanding` to check another target |
| `zig build test -Dzui-debug=true` | keep id names, so duplicate-id and unbalanced-tree panics name the element |
| `zig build bench` | run the benchmarks in ReleaseFast; add `-- --check-targets` to fail on a missed §6.5 target, or `-- --compare old.json` after `-- --json old.json` to check for regressions |
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
  SPEC.md §6.5 targets are reported in the job summary but not compared:
  runners vary too much. Check for slowdowns on your own machine with
  `--json` and `--compare`.

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

SPEC.md §15.1 lists the widgets, and §15.2 covers what the inspector
generates for each field type.

## License

MIT; see [LICENSE](LICENSE).

The zui logo is adapted from the [Zig logo](https://codeberg.org/ziglang/logo)
and, like it, is licensed under CC BY-SA 4.0; see
[assets/LICENSE.md](assets/LICENSE.md). zui is not affiliated with or endorsed
by the Zig Software Foundation.

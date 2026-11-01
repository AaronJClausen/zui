# zui

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

Still missing from 0.2 is its reference raylib backend. Async tasks (0.3)
come next; see the roadmap in SPEC.md §16.

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
| `zig build test` | run the unit, golden, randomized-invariant and compile-error tests (add `-Doptimize=ReleaseSafe` or `ReleaseFast` to test other modes) |
| `zig build check` | compile one full frame without producing output; add `-Dtarget=wasm32-freestanding` to check another target |
| `zig build test -Dzui-debug=true` | keep id names, so duplicate-id and unbalanced-tree panics name the element |
| `zig build docs` | generate API documentation into `zig-out/docs` |
| `zig build fmt` | format every Zig source file |
| `zig build fmt-check` | fail if any file is not formatted, as CI does |

CI runs:
- the format check;
- the tests in three optimize modes on Linux, Windows and macOS, plus as
  a 32-bit x86 Linux program;
- `check` for six targets: 32- and 64-bit, big-endian, freestanding and
  WebAssembly.

Those targets exist to catch assumptions about the host machine early:
the first 32-bit build found two places that used a 64-bit hash as an
index.

The repository uses LF line endings everywhere (see `.gitattributes`),
whatever your `core.autocrlf` setting.

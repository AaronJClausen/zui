# The template project

A small zui app to copy out as the start of your own: a window with a
title, a count, and two buttons that change it, styled by zui's default
design in the system's light or dark theme. It runs on
[`zui_app`](../../core/zui_app/zui_app.zig) over the native host
(`zui_host`, Windows and Linux), drawn by the sokol renderer
(`zui_sokol`), in the bundled Atkinson Hyperlegible fonts through
`zui_truetype`.

| File | What it holds |
|---|---|
| `src/counter.zig` | the app: its state, kept across frames, and the UI it declares each frame |
| `src/main.zig` | the window: `zui_app` running the app on a host and a renderer, and the `--frames` flag |
| `src/tests.zig` | a headless test that clicks the buttons and checks the count |
| `build.zig` | the steps below |
| `build.zig.zon` | the one dependency, `zui` |

## Copy it out

1. Copy this directory, from a clone of zui or its downloaded archive,
   wherever your app will live:

   ```sh
   git clone https://github.com/AaronJClausen/zui
   cp -r zui/examples/template ~/my-app && cd ~/my-app
   ```

2. Point `zui` at the published package instead of this repository.
   `zig fetch` replaces the `.zui = .{ .path = "../.." }` entry in
   `build.zig.zon` with a URL and a hash:

   ```sh
   zig fetch --save git+https://github.com/AaronJClausen/zui
   ```

3. Give the package its own name: in `build.zig.zon`, change
   `.name = .zui_template` to your app's (`.my_app`) and the
   `.fingerprint` to `0x0`. The next `zig build` fails with the
   fingerprint to use (`use this value: 0x…`); paste it in. Rename the
   executable from `zui-template` in `build.zig` too.

Nothing else names this repository: `build.zig` reaches every package
through the `zui` dependency, the renderer and the host as
`zui.builder.dependency("zui_sokol", …)` and
`zui.builder.dependency("zui_host", …)`.

## Build and run

Zig 0.16.0. The first build fetches sokol and stb_truetype and compiles
them, which takes a minute or two. On Linux the host needs
`libwayland-dev libxkbcommon-dev libegl-dev` and
`libx11-dev libx11-xcb-dev libxcb1-dev libxcb-xkb-dev libxcb-cursor-dev libxkbcommon-x11-dev`,
and the sokol renderer
`libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev` (the
names are Debian's and Ubuntu's).

| Command | What it does |
|---|---|
| `zig build run` | open the window; it stays open until you close it |
| `zig build run -- --frames 120` | draw 120 frames, then close the window: for scripts and CI |
| `zig build test` | run the headless tests (add `-Doptimize=ReleaseSafe` or `ReleaseFast` to test other modes) |
| `zig build check` | compile the app and its tests without running them; add `-Dtarget=x86_64-windows` to cross-compile |
| `zig build` | install the app into `zig-out/bin` |
| `zig build fmt` | format the Zig sources; `fmt-check` fails if one is not formatted |

`-Dzui-debug=true` keeps element ids' names, so a duplicate id or an
unbalanced `open`/`close` panics with the element's name.

## How it is put together

`Counter` in `src/counter.zig` is the whole app. It is generic over the
context, `Ui`, so the window and the test declare the same UI: the
window's `Ui` is built for the sokol renderer, the test's for no
renderer at all. Each frame, `declare` opens the window's column, writes
the title and the count, and declares the two buttons, which return true
in the frame they are clicked. The count is a field, so it lasts across
frames; zui keeps nothing of the app's. The design's tokens are resolved
again only when the system's theme, contrast or text size changes.

`src/main.zig` names the host, the renderer and the font system once, in
`App`, which `zui_app.run` opens a window for and runs until the window
closes. `SokolRenderer` opens the sokol renderer on the host's window,
as `zui_app` opens a renderer.

The test runs whole frames with `zui_testing.Driver`: `click` presses
and releases the mouse on a button's center, using the layout of the
frame before, so each click follows a frame that declared the button.

[SPEC.md](../../SPEC.md) §19.2 lists the widgets, and the
[main README](../../README.md#using-zui-in-your-project) every module
`zui` offers.

## Another renderer

To draw with raylib on its own window instead (Windows, Linux and macOS;
on Linux it needs
`libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl1-mesa-dev`):

- in `build.zig`, replace the `zui_sokol` and `zui_host` dependencies
  and imports with one:

  ```zig
  const zui_raylib = declaring(zui.builder.dependency("zui_raylib", zui_arguments), "zui_raylib") orelse return;
  // in the app's imports:
  .{ .name = "zui_raylib", .module = zui_raylib.module("zui_raylib") },
  ```

  and drop the `switch` on the OS before it, since raylib opens windows
  on macOS too;

- in `src/main.zig`, import `zui_raylib` in place of `zui_host` and
  `zui_sokol`, delete `SokolRenderer`, and name raylib's host and
  renderer:

  ```zig
  const Ui = zui.Context(zui_app.contextConfig(zui_raylib.Renderer, .{ .Text = zui_truetype.Text }));
  // in App:
  pub const Host = zui_raylib.Host;
  pub const Renderer = zui_raylib.Renderer;
  ```

`src/counter.zig` and the test do not change.
[renderers/](../../renderers/) holds the others: a terminal renderer and
host, and WebGL for the browser.

## Limits

- The native host opens windows on Windows and Linux (Wayland or X11)
  only; on macOS `zig build run` fails with that message, and `test` and
  `check` still build. Use raylib there.
- On Linux the link prints `warning(link): unexpected LLD stderr` and a
  `failed command:` line for sokol's library and still succeeds.
- The template has one window and no data from outside it; a source
  (`zui_async`) brings in data that arrives between frames, and
  `zui_app`'s `zuiLoader` starts the work that produces it.

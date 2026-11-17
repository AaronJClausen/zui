# zui-web

[zui](https://github.com/AaronJClausen/zui) in the browser: first a thin client that draws a zui app streamed over zui_wire, later a web host with a canvas surface.

Built by roadmap items V4 (the demo in a browser, a thin client over zui_wire) and H5 (the web host).

## Status

V4 has begun. The client's decoder runs in WebAssembly: `zig build`
writes `zig-out/web/zui-web.wasm` (66 KB in ReleaseSmall, 35 MiB of memory
once `zuiWebInit` reserves it), which takes a `zui_wire` stream in pieces of any size, as a socket
delivers it, and decodes each frame once all of it has arrived.
`zig build test-demo` declares every screen of zui-sokol's tour
headlessly, streams its frames to that client under Node in pieces of 1 to
16,384 bytes, and checks that each of the 312 frames decodes to what the
tour drew.

The client then lays each frame out as triangles, as zui-sokol's
renderer does, and `web/frame_drawer.mjs` draws them on a canvas through
WebGL 2: rectangles, borders, clips, gradients, shadows and transforms,
and text, once the page hands the client the stream's fonts. TrueType
glyphs are rasterized by stb_truetype, compiled into the client without a
C library, into an atlas packed as zui-sokol packs its own; bitmap text
uses sokol_debugtext's six fonts. A backdrop blur copies what was drawn
beneath it and blurs it as zui-sokol does, along x and then y into two
half-float targets, before the pane is drawn from them; a material is drawn
by zui-sokol's material shader, ported to GLSL ES. Without
`EXT_color_buffer_float`, blurs are drawn as their tint alone. Images are
not drawn yet, and there is no page. `zig build test-draw` draws a frame of
each of the tour's screens with zui-sokol's renderer and with the client in
headless Chromium, and checks that every pixel matches, within 2 of each
color or a pixel's neighbor: shapes, text, blurs and materials alike. A
frame may have one
pixel that matches nothing nearby: a glyph's partial coverage at its edge
is a color no neighbor has, and the two rasterizers decide a pixel that
close to a turned glyph's edge differently. Of the 13 frames, only the
Transforms screen's has such a pixel.
See [zui's ROADMAP.md](https://github.com/AaronJClausen/zui/blob/main/ROADMAP.md).

## Requirements

- Zig **0.16.0**
- zui, fetched automatically (pinned by commit in `build.zig.zon`)
- for `zig build test-demo`: Node on the `PATH`, and on Linux sokol's X11,
  OpenGL and PulseAudio headers, since the tour links them; zui-sokol,
  which holds the tour, is fetched automatically, pinned as zui is
- for `zig build test-draw`, also Chromium or Google Chrome (`chromium`
  on the `PATH`, or `-Dbrowser=<path>`), and a display for zui-sokol's
  OpenGL window: on Linux CI, Xvfb

## Development

| Command | Does |
|---|---|
| `zig build test` | run the tests; CI also runs `-Doptimize=ReleaseSafe` and `-Doptimize=ReleaseFast` |
| `zig build` | write the client, `zig-out/web/zui-web.wasm` |
| `zig build check` | compile without running, and compile the client for `wasm32-freestanding` |
| `zig build test-demo` | stream zui-sokol's tour to the client under Node, and check every frame decodes to what was drawn |
| `zig build test-draw` | draw a frame of each of the tour's screens in headless Chromium, and check each against zui-sokol's renderer drawing it |
| `zig build fmt` | format the Zig sources |
| `zig build fmt-check` | fail if a Zig source is not formatted (CI) |
| `zig build test --fork=../zui` | build against a local zui checkout instead of the pin |

When `test-draw` fails, it prints each failing frame's numbers and writes
the frame drawn and its reference as PPM images to a new temporary
directory, or to the one `ZUI_WEB_DRAW_FAILURES` names; CI uploads them as
the `draw-failures` artifact.

To move the pin, push the zui change and run
`zig fetch --save=zui git+https://github.com/AaronJClausen/zui#<commit>`.
Keep zui's pin the one zui-sokol's pin names, and move the two together,
and likewise stb's, so the client rasterizes glyphs as zui-sokol does:
the tour and the client then share zui's types, and `--fork=../zui`, which
cannot fork two zui packages into one checkout, matches only one.

## License

MIT, as zui.

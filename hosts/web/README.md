# zui-web

[zui](https://github.com/AaronJClausen/zui) in the browser: first a thin client that draws a zui app streamed over zui_wire, later a web host with a canvas surface.

Built by roadmap items V4 (the demo in a browser, a thin client over zui_wire) and H5 (the web host).

## Status

V4 has begun. The client's decoder runs in WebAssembly: `zig build`
writes `zig-out/web/zui-web.wasm` (75 KB in ReleaseSmall, 35 MiB of memory
once `zuiWebInit` reserves it), which takes a `zui_wire` stream in pieces of any size, as a socket
delivers it, and decodes each frame once all of it has arrived.
`zig build test-demo` declares every screen of zui-sokol's tour
headlessly, streams its frames to that client under Node in pieces of 1 to
16,384 bytes, and checks that each of the 312 frames decodes to what the
tour drew.

The client then lays each frame out as triangles, as zui-sokol's
renderer does, and `web/frame_drawer.mjs` draws them on a canvas through
WebGL 2, with four samples per pixel resolved to one, which smooth every
edge as zui-sokol's demo window does with its `sample_count = 4`:
rectangles, borders, clips, gradients, shadows and transforms,
and text, once the page hands the client the stream's fonts. TrueType
glyphs are rasterized by stb_truetype, compiled into the client without a
C library, into an atlas packed as zui-sokol packs its own; bitmap text
uses sokol_debugtext's six fonts. A backdrop blur copies what was drawn
beneath it and blurs it as zui-sokol does, along x and then y into two
float targets, before the pane is drawn from them; a material is drawn
by zui-sokol's material shader, ported to GLSL ES. The blur is summed in
RGBA32F where WebGL can render, blend and filter it
(`EXT_color_buffer_float`, `EXT_float_blend`, `OES_texture_float_linear`),
as zui-sokol sums it where its GPU can, and otherwise in RGBA16F, whose
rounding differs between drivers by several color steps; without
`EXT_color_buffer_float`, blurs are drawn as their tint alone. Images are
not drawn yet. `zig build test-draw` draws a frame of
each of the tour's screens with zui-sokol's renderer and with the client in
headless Chromium, twice. With one sample per pixel, it checks that every
pixel matches, within 2 of each color or a pixel's neighbor: shapes, text,
blurs and materials alike. A frame may have one pixel that matches nothing
nearby: a glyph's partial coverage at its edge is a color no neighbor has,
and the two rasterizers decide a pixel that close to a turned glyph's edge
differently. Of the 13 frames, only the Transforms screen's has such a
pixel. With four samples per pixel and without text, it checks that every
pixel of each image also matches the other's, so an edge smoothed in one
alone fails, allowing one sample's share of the colors around a pixel,
since SwiftShader snaps vertices to a sixteenth of a pixel, and four
pixels a frame where a line thinner than a pixel has two samples decided
differently; a frame drawn unsmoothed has hundreds that match nothing.
Text is left out there, since where a glyph's quad covers part of a pixel
a GPU may sample the glyph anywhere in the pixel. It fails, rather than
compare them, if either side cannot sum blurs in RGBA32F.

Input goes back the other way. `web/input_recorder.mjs` turns a canvas's
pointer, wheel, key and text events, its size and `devicePixelRatio` into
calls the client makes records of, as `zui_wire.Client` does: a record is
written only when it holds events or the canvas's size or scale changed,
the stream's header before the first, and the application's host counts
the time between them. A key is the one its `key` names, or for a digit
or a mark, the one its `code` places, so Ctrl+2 is Ctrl+2 on any layout;
a key that types a character also sends it as text. The cursor each frame
asks for is set on the canvas. `zig build test-input` gives the page a
mouse, keys, the wheel, a touch and a resize through headless Chromium,
runs zui-sokol's tour on the records the client wrote, checks that each
holds what the page was given and that the tour moved between screens on
the click and the shortcuts, and sends the tour's frames back to the page,
which must show the pointer cursor over the rail.

The tour itself runs in the browser too, in a Web Worker behind the page:
`zig build` also writes `zig-out/web/zui-web-tour.wasm`, zui-sokol's tour
built for `wasm32-freestanding` with shared memory (793 KB in
ReleaseSmall, about 49 MiB of memory once `zuiTourInit` reserves it).
`web/tour_worker.mjs` takes the page's clock and records each frame and
posts back the frame's wire bytes. The tour's strip and frame inspector
time each frame's beginFrame, declaration and layout on the worker's
`performance.now()`, and show the page's time to draw the frame before as
its submit time. The tour's loaders, the Gallery's
tiles and Mission Control's producers, run on an `Io` of the worker's own,
`SteppedIo`: its clocks read the page's instant, and its tasks take turns
on 16 threads, each a worker of its own on the same memory
(`web/tour_thread.mjs`), one at a time and only while the frame waits for
them, so the tour draws the same frames for the same clock and input
wherever it runs. A worker can share its memory only on a page that is
cross-origin isolated, served with `Cross-Origin-Opener-Policy:
same-origin` and `Cross-Origin-Embedder-Policy: require-corp`.
`zig build test-demo` also runs the tour in that worker under Node, on the
records the client wrote of the mouse crossing each screen and
Ctrl+PageDown between them, and checks that each of the 312 frames is,
byte for byte, the frame the tour draws natively on the same ticks
(`tools/tour_frames.zig`), that its tasks ran alike, and that the client
decodes every frame. Real timings differ from run to run, so there both
time frames on a steady stopwatch, 1 µs a reading.

The published page puts it all together: `web/index.html` starts the
tour's worker, draws each frame it sends on the canvas, and sends it the
canvas's input as records. It sleeps between frames as a native host
does: each answer from the worker carries when to step the tour again,
which is the tour's `ui.nextFrame()`, at once, at a deadline or on input,
or sooner, when one of its tasks' sleeps ends, since under `SteppedIo`
tasks run only while a frame waits for them. The page then asks for an
animation frame at once, sets a timer for the deadline, or waits for the
canvas's input, a resize or a change of `devicePixelRatio`, and a step
that finds no frame due declares none. Idle, the tour draws only its
heartbeat, once a second; the Box Storm, Typography, Light and Depth,
Transforms and Materials screens animate, and ask for every frame, as
they do natively. GitHub
Pages cannot send the headers that make a page cross-origin isolated, so
the page registers a service worker of its own,
`web/isolation_service_worker.js`, which serves the page and everything
it loads again with them, and reloads once. `zig build site` writes the
page, the client, the tour's worker and the tour's fonts to
`zig-out/site`, and CI's Pages workflow (`.github/workflows/pages.yml`)
builds it in ReleaseSmall and publishes it from `main`, to
<https://aaronjclausen.github.io/zui-web/> once the repository's Pages
source is GitHub Actions.
`zig build test-site` serves that site without the isolation headers,
as GitHub Pages does, opens it in headless Chromium, and checks that the
service worker isolated it after one reload, that the page draws the
worker's frames, timed above 0 µs, that it sleeps while idle, drawing
1 frame a second on Welcome while the display runs at 60, and that input
wakes it and reaches the tour: the mouse over the
rail shows the pointer cursor the tour asks for, Ctrl+PageDown draws the
next screen, and a click on Mission Control starts its producers' tasks,
whose frames keep coming without input. Then, on the Gallery, every
tile's load must finish without input, and the page sleep again.
See [zui's ROADMAP.md](https://github.com/AaronJClausen/zui/blob/main/ROADMAP.md).

## Requirements

- Zig **0.16.0**
- zui, fetched automatically (pinned by commit in `build.zig.zon`)
- for `zig build test-demo`: Node on the `PATH`, with `worker_threads`, and on Linux sokol's X11,
  OpenGL and PulseAudio headers, since the tour links them; zui-sokol,
  which holds the tour, is fetched automatically, pinned as zui is
- for `zig build test-input`, also Chromium or Google Chrome (`chromium`
  on the `PATH`, or `-Dbrowser=<path>`), run headless
- for `zig build site`, sokol's X11, OpenGL and PulseAudio headers on
  Linux, since the tool that writes sokol_debugtext's fonts links them;
  for `zig build test-site`, also Node and Chromium, run headless
- for `zig build test-draw`, also Chromium or Google Chrome, and a display
  for zui-sokol's OpenGL window: on Linux CI, Xvfb

## Development

| Command | Does |
|---|---|
| `zig build test` | run the tests; CI also runs `-Doptimize=ReleaseSafe` and `-Doptimize=ReleaseFast` |
| `zig build` | write the client, `zig-out/web/zui-web.wasm`, and the tour for a worker, `zig-out/web/zui-web-tour.wasm` |
| `zig build check` | compile without running, and compile the client and the tour's worker for `wasm32-freestanding` |
| `zig build test-demo` | stream zui-sokol's tour to the client under Node, and check every frame decodes to what was drawn; run the tour in a worker under Node, and check every frame is the one the tour draws natively |
| `zig build test-draw` | draw a frame of each of the tour's screens in headless Chromium, with one sample per pixel and with four, and check each against zui-sokol's renderer drawing it alike |
| `zig build test-input` | give the page input in headless Chromium, run the tour on the records the client wrote of it, and check the tour took them and the page shows the cursor it asks for |
| `zig build site` | write the published page, the client, the tour's worker and its fonts to `zig-out/site`; serve that directory over HTTP (or HTTPS, off `localhost`) to run the tour in a browser |
| `zig build test-site` | serve the site without isolation headers, open it in headless Chromium, and check its service worker isolates it, it draws the tour's frames, sleeps while idle, and its input wakes it and reaches the tour |
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

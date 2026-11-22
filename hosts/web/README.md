# The web host

`zui_web` is zui in the browser: today a thin client that draws an
application streamed over `zui_wire` (`09-seeing-the-ui:04-demo-in-browser`),
the [tour](../../apps/tour/README.md) in a Web Worker, and the page that
puts them together, published to GitHub Pages by the Pages workflow;
later a web host with a canvas surface (`10-reach:02-web-host`). It
exports no module yet: its steps run from `hosts/web/` (see
*Development*). Everything under its `src/` that the browser runs
compiles for `wasm32-freestanding`.

## Development

Run from `hosts/web/`. The first build fetches stb, and sokol-zig, which only `test-draw` compiles, for the sokol
renderer that draws its reference; on Linux `test-draw` needs sokol's
`libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev`;
`test-demo` needs Node on the `PATH`, with `worker_threads`; `test-draw`, `test-input` and
`test-site` also need Chromium or Google Chrome (`chromium` on the
`PATH`, or `-Dbrowser=<path>`), run headless; and `test-draw` needs a
display for the sokol renderer's OpenGL window (CI runs it under
`xvfb-run`):

| Command | What it does |
|---|---|
| `zig build test` | run the client's and the stepped `Io`'s unit tests |
| `zig build` | write the client, `zig-out/web/zui-web.wasm`, and the tour for a worker, `zig-out/web/zui-web-tour.wasm` |
| `zig build check` | compile without running: the client and the tour's worker for `wasm32-freestanding`, and the native tools that run the tour |
| `zig build test-demo` | stream the tour to the client under Node, and check every frame decodes to what was drawn; run the tour in a worker under Node, and check every frame is the one the tour draws natively |
| `zig build test-draw` | draw a frame of each of the tour's screens in headless Chromium, with one sample per pixel and with four, and check each against the sokol renderer drawing it alike |
| `zig build test-input` | give the page input in headless Chromium, run the tour on the records the client wrote of it, and check the tour took them and the page shows the cursor it asks for |
| `zig build site` | write the published page, the client, the frame drawer, the tour's worker and its fonts to `zig-out/site`; serve that directory over HTTP (or HTTPS, off `localhost`) to run the tour in a browser |
| `zig build test-site` | serve the site without isolation headers, open it in headless Chromium, and check its service worker isolates it, it draws the tour's frames, sleeps while idle, and its input wakes it and reaches the tour |

When `test-draw` fails, it prints each failing frame's numbers and writes
the frame drawn and its reference as PPM images to a new temporary
directory, or to the one `ZUI_WEB_DRAW_FAILURES` names; CI uploads them as
the `draw-failures` artifact.

## How it works

**The client.** `zig build` writes `zig-out/web/zui-web.wasm` (35 MiB of
memory once `zuiWebInit` reserves it), which takes
a `zui_wire` stream in pieces of any size, as a socket delivers it,
decodes each frame once all of it has arrived, and draws it through
`zui_webgl.Renderer`, which lays it out in the client's memory and hands
it to the page's `FrameDrawer` (`frame_drawer.mjs`) for canvas 0:
`web/client.mjs` instantiates the client with `frameDrawerImports`. Its text is the TrueType
fonts the page hands over, in the order the tour added them, laid out
through a `zui_truetype.Text` with no default font, so the client embeds
none; once the page hands fonts over, a stream whose header
carries another fingerprint, measured with other fonts or the same fonts
in another order, is refused with `FontsDiffer` rather than drawn.
`zig build test-demo` declares every screen of the tour, as the browser
draws it, headlessly, streams its frames to that client, handed the tour's fonts,
under Node in pieces of 1 to 16,384 bytes, checks that each of the 312
frames decodes to what the tour drew, and that a client handed the fonts
in the other order refuses the stream.
`zig build test-draw` draws a frame of each of the tour's screens with the
sokol renderer and with the client in headless Chromium, twice. With one
sample per pixel, it checks that every pixel matches, within 2 of each
color or a pixel's neighbor: shapes, text, blurs and materials alike. A
frame may have one pixel that matches nothing nearby, where the two
rasterizers decide a pixel on an edge differently. A glyph's quad reaches
half a texel past its coverage, into the blank texels the atlas keeps
between glyphs, so a pixel on a turned glyph's edge is blank either way. With four samples
per pixel and without text, it checks that every pixel of each image also
matches the other's, so an edge smoothed in one alone fails, allowing one
sample's share of the colors around a pixel, since SwiftShader snaps
vertices to a sixteenth of a pixel, and four pixels a frame where a line
thinner than a pixel has two samples decided differently; a frame drawn
unsmoothed has hundreds that match nothing. Text is left out there, since
where a glyph's quad covers part of a pixel a GPU may sample the glyph
anywhere in the pixel. It fails, rather than compare them, if either side
cannot sum blurs in RGBA32F.

**Input** goes back the other way. `web/input_recorder.mjs` turns a
canvas's pointer, wheel, key and text events, its size and
`devicePixelRatio` into calls the client makes records of, as
`zui_wire.Client` does: a record is written only when it holds events or
the canvas's size or scale changed, the stream's header before the first,
and the application's host counts the time between them. A key is the one
its `key` names, or for a digit or a mark, the one its `code` places, so
Ctrl+2 is Ctrl+2 on any layout; a key that types a character also sends
it as text. The cursor each frame asks for is set on the canvas.
`zig build test-input` gives the page a mouse, keys, the wheel, a touch
and a resize through headless Chromium, runs the tour on the records the
client wrote, checks that each holds what the page was given and that the
tour moved between screens on the click and the shortcuts, and sends the
tour's frames back to the page, which must show the pointer cursor over
the rail.

**The tour in a worker.** `zig build` also writes
`zig-out/web/zui-web-tour.wasm`, the tour built for
`wasm32-freestanding` with shared memory, declared for
`zui_webgl.Renderer` (about 49 MiB of memory once
`zuiTourInit` reserves it). It is the tour's `zui_tour.App` stepped as a
`zui_app.Session`, as any application whose loop is another's: its host
hands the session the page's records and declares no loop of its own, and
its renderer writes each frame as wire bytes. `web/tour_worker.mjs` takes
the page's clock and records each frame, steps the session, which
declares a frame only when one is due, and posts back the frame's wire
bytes, or none, and when to step it next. The tour's
strip and frame inspector time each frame's beginFrame, declaration and
layout on the worker's `performance.now()`, and show the page's time to
draw the frame before as its submit time. The tour's loaders, the
Gallery's tiles and Mission Control's producers, run on an `Io` of the
worker's own, `SteppedIo`: its clocks read the page's instant, and its
tasks take turns on 16 threads, each a worker of its own on the same
memory (`web/tour_thread.mjs`), one at a time and only while the frame
waits for them, so the tour draws the same frames for the same clock and
input wherever it runs. A worker can share its memory only on a page that
is cross-origin isolated, served with `Cross-Origin-Opener-Policy:
same-origin` and `Cross-Origin-Embedder-Policy: require-corp`.
`zig build test-demo` also runs the tour in that worker under Node, on
the records the client wrote of the mouse crossing each screen and
Ctrl+PageDown between them, and checks that each of the 312 frames is,
byte for byte, the frame the tour draws natively on the same ticks
(`tools/tour_frames.zig`), that its tasks ran alike, and that the client
decodes every frame. Real timings differ from run to run, so there both
time frames on a steady stopwatch, 1 µs a reading.

**The published page** puts it all together: `web/index.html` starts the
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
they do natively. GitHub Pages cannot send the headers that make a page
cross-origin isolated, so the page registers a service worker of its own,
`web/isolation_service_worker.js`, which serves the page and everything
it loads again with them, and reloads once. `zig build site` writes the
page, the client, the frame drawer, the tour's worker and the tour's fonts
to `zig-out/site` (in ReleaseSmall, `zui-web.wasm` is 80 KB and
`zui-web-tour.wasm` 845 KB), and the Pages workflow
(`.github/workflows/pages.yml`) builds it in ReleaseSmall, checks it, and
publishes it from `main`. `zig build test-site` serves that site without
the isolation headers, as GitHub Pages does, opens it in headless
Chromium, and checks that the service worker isolated it after one
reload, that the page draws the worker's frames, timed above 0 µs, that
it sleeps while idle, drawing 1 frame a second on Welcome while the
display runs at 60, and that input wakes it and reaches the tour: the
mouse over the rail shows the pointer cursor the tour asks for,
Ctrl+PageDown draws the next screen, and a click on Mission Control starts
its producers' tasks, whose frames keep coming without input. Then, on
the Gallery, every tile's load must finish without input, and the page
sleep again.

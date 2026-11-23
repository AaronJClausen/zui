# The web host

`zui_web` is zui in the browser: the web host, `Host`, which runs an
application in a dedicated worker drawing on the canvas its page
transferred (`10-reach:02-web-host`), and the
[tour](../../apps/tour/README.md) on it, the page GitHub Pages publishes
by the Pages workflow; and a thin client that draws an application
streamed over `zui_wire` (`09-seeing-the-ui:04-demo-in-browser`), with
the tour in a Web Worker writing its frames to it, which the checks use
to compare the browser's frames and drawing with the native ones. It
exports no module yet: its steps run from `hosts/web/` (see
*Development*). Everything under its `src/` that the browser runs
compiles for `wasm32-freestanding`.

## Development

Run from `hosts/web/`. The first build fetches stb, and sokol-zig, which
only `test-draw` compiles, for the sokol renderer that draws its
reference; on Linux `test-draw` needs sokol's
`libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev`;
`test-demo` needs Node on the `PATH`, with `worker_threads`;
`test-draw`, `test-input`, `test-site` and `test-host` also need
Chromium or Google Chrome (`chromium` on the `PATH`, or
`-Dbrowser=<path>`), run headless; and `test-draw` needs a display for
the sokol renderer's OpenGL window (CI runs it under `xvfb-run`):

| Command | What it does |
|---|---|
| `zig build test` | run the client's, the stepped `Io`'s and the web host's unit tests, the web host's conformance on a scripted page, and its compile errors |
| `zig build` | write the client, `zig-out/web/zui-web.wasm`, and the tour for a worker, `zig-out/web/zui-web-tour.wasm` |
| `zig build check` | compile without running: the client, the tour on the web host and the tour's worker for `wasm32-freestanding`, and the native tools that run the tour |
| `zig build test-demo` | stream the tour to the client under Node, and check every frame decodes to what was drawn; run the tour in a worker under Node, and check every frame is the one the tour draws natively |
| `zig build test-draw` | draw a frame of each of the tour's screens in headless Chromium, with one sample per pixel and with four, and check each against the sokol renderer drawing it alike |
| `zig build test-input` | give the page input in headless Chromium, also through the hidden text field an IME composes in, run the tour on the records the client wrote of it, and check the tour took them and the page shows the cursor it asks for |
| `zig build site` | write the published page, the tour on the web host, to `zig-out/site`: its page, the scripts of its page and worker, the frame drawer, `zui-tour.wasm` and its fonts' licences; serve that directory over HTTP (or HTTPS, off `localhost`) to run the tour in a browser |
| `zig build test-site` | serve the site without isolation headers, open it in headless Chromium, and check its service worker isolates it, the tour draws and times its frames, sleeps while idle, and its input wakes it and reaches the tour, whose tasks run without input |
| `zig build tour` | write the same page to `zig-out/tour`; serve that directory cross-origin isolated (`Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`), or over HTTPS, where its service worker isolates it, to run the tour |
| `zig build test-host` | serve the tour on the web host cross-origin isolated, open it in headless Chromium without a display, and check its worker draws the tour, sleeps while idle, takes the page's input, shows the cursor the tour asks for on the page's canvas, draws the same screen again after its WebGL context is lost and restored, hears the page's settings, the tour restyled as the emulated media queries and the document's direction change, draws nothing while another tab hides the page, takes typed and composed text once through the hidden text field at the Port field's caret, and copies to and reads from the page's clipboard |

When `test-draw` fails, it prints each failing frame's numbers and
writes the frame drawn and its reference as PPM images to a new
temporary directory, or to the one `ZUI_WEB_DRAW_FAILURES` names; CI
uploads them as the `draw-failures` artifact.

## How it works

**The client.** `zig build` writes `zig-out/web/zui-web.wasm` (35 MiB of
memory once `zuiWebInit` reserves it), which takes a `zui_wire` stream
in pieces of any size, as a socket delivers it, decodes each frame once
all of it has arrived, and draws it through `zui_webgl.Renderer`, which
lays it out in the client's memory and hands it to the page's
`FrameDrawer` (`frame_drawer.mjs`) for canvas 0: `web/client.mjs`
instantiates the client with `frameDrawerImports`. Its text is the
TrueType fonts the page hands over, in the order the tour added them,
laid out through a `zui_truetype.Text` with no default font, so the
client embeds none; once the page hands fonts over, a stream whose
header carries another fingerprint, measured with other fonts or the
same fonts in another order, is refused with `FontsDiffer` rather than
drawn. `zig build test-demo` declares every screen of the tour, as the
browser draws it, headlessly, streams its frames to that client, handed
the tour's fonts, under Node in pieces of 1 to 16,384 bytes, checks that
each of the 312 frames decodes to what the tour drew, and that a client
handed the fonts in the other order refuses the stream.
`zig build test-draw` draws a frame of each of the tour's screens with
the sokol renderer and with the client in headless Chromium, twice. With
one sample per pixel, it checks that every pixel matches, within 2 of
each color or a pixel's neighbor: shapes, text, blurs and materials
alike. A frame may have one pixel that matches nothing nearby, where the
two rasterizers decide a pixel on an edge differently. A glyph's quad
reaches half a texel past its coverage, into the blank texels the atlas
keeps between glyphs, so a pixel on a turned glyph's edge is blank
either way. With four samples per pixel and without text, it checks that
every pixel of each image also matches the other's, so an edge smoothed
in one alone fails, allowing one sample's share of the colors around a
pixel, since SwiftShader snaps vertices to a sixteenth of a pixel, and
four pixels a frame where a line thinner than a pixel has two samples
decided differently; a frame drawn unsmoothed has hundreds that match
nothing. Text is left out there, since where a glyph's quad covers part
of a pixel a GPU may sample the glyph anywhere in the pixel. It fails,
rather than compare them, if either side cannot sum blurs in RGBA32F.
The reference names the OpenGL renderer that drew it. Where there is no
GPU, as in CI, that is Mesa's llvmpipe, which rounds both halves of each
8-bit blend: a translucent layer can leave a color a step below a GPU's.
Against llvmpipe a color may differ by 5 instead of 2, which covers the
tour's labels under a fade at alpha 1/255 (3 steps) and its text stacked
dozens of lines deep (5).

**Input** goes back the other way. `web/input_recorder.mjs` turns a
canvas's pointer, wheel, key and text events, its size and
`devicePixelRatio` into calls the client makes records of, as
`zui_wire.Client` does: a record is written only when it holds events or
the canvas's size or scale changed, the stream's header before the
first, and the application's host counts the time between them. A key is
the one its `key` names, or for a digit or a mark, the one its `code`
places, so Ctrl+2 is Ctrl+2 on any layout; a key that types a character
also sends it as text. The cursor each frame asks for is set on the
canvas. `zig build test-input` gives the page a mouse, keys, the wheel,
a touch and a resize through headless Chromium, runs the tour on the
records the client wrote, checks that each holds what the page was given
and that the tour moved between screens on the click and the shortcuts,
and sends the tour's frames back to the page, which must show the
pointer cursor over the rail.

**The tour in a worker.** `zig build` also writes
`zig-out/web/zui-web-tour.wasm`, the tour built for
`wasm32-freestanding` with shared memory, declared for
`zui_webgl.Renderer` (about 49 MiB of memory once `zuiTourInit` reserves
it). It is the tour's `zui_tour.App` stepped as a `zui_app.Session`, as
any application whose loop is another's: its host hands the session the
page's records and declares no loop of its own, and its renderer writes
each frame as wire bytes. `web/tour_worker.mjs` takes the page's clock
and records each frame, steps the session, which declares a frame only
when one is due, and posts back the frame's wire bytes, or none, and
when to step it next. The tour's strip and frame inspector time each
frame's beginFrame, declaration and layout on the worker's
`performance.now()`, and show the page's time to draw the frame before
as its submit time. The tour's loaders, Photo Culling's loads and Log
Tail's producers, run on an `Io` of the worker's own, `SteppedIo`: its
clocks read the page's instant, and its tasks take turns on 16 threads,
each a worker of its own on the same memory (`web/tour_thread.mjs`), one
at a time and only while the frame waits for them, so the tour draws the
same frames for the same clock and input wherever it runs. A worker can
share its memory only on a page that is cross-origin isolated, served
with `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`. `zig build test-demo` also
runs the tour in that worker under Node, on the records the client wrote
of the mouse crossing each screen and Ctrl+PageDown between them, and
checks that each of the 312 frames is, byte for byte, the frame the tour
draws natively on the same ticks (`tools/tour_frames.zig`), that its
tasks ran alike, and that the client decodes every frame. Real timings
differ from run to run, so there both time frames on a steady stopwatch,
1 µs a reading.

**The web host** is `HostOn(Platform)` (`src/host.zig`), a pushed host
whose loop is the page's event loop, with its logic apart from the
browser: `Platform` gives it the page's clock (`now`), takes the next
turn as the host schedules it (`schedule`: an animation frame, a timer
at an instant, nothing until input, or the run's end), wakes it from any
thread (`wake`), shows the canvas's cursor (`showCursor`), and runs the
event loop (`run(Turns)`, which returns, or is `noreturn` where the loop
is the browser's); a platform missing one, or of another type, is a
compile error naming it. From the page the platform hands the host the
canvas, by the id the page gave it, with its size in CSS pixels and
`devicePixelRatio` (`attachCanvas`, `resize`), its pointers, wheel, keys
and text, read as `browser_input` maps the browser's events, and a lost
or restored WebGL context (`loseContext`, `restoreContext`). Each turn
steps the `Io` to the page's clock when it is a `SteppedIo`, polls and
steps the application, and schedules the next as the step's `NextFrame`
asks, folded with the `SteppedIo`'s next wake: an animation frame at
once, a timer at an instant, or nothing until input; a wake from a task
during the step, or input, makes it due at once. The driver starts on
the first turn after the canvas arrives, its surface is `.web` with that
id, a lost context suspends the surfaces on the next turn and its return
resumes them, and the cursor goes to the platform only when it changes.
The page's settings arrive as text, `changeSetting(name, value)`, each
named as the field of `PageEnvironment` (theme, contrast, reduced motion
and transparency, locale, direction, window focus and accent, a color as
`#rrggbb` or `"none"`) and the `zui.EnvironmentChange` it becomes; until
the page says otherwise each is `zui.Environment`'s default, the first
record reports them all, and a record after reports only those that
changed. A locale longer than `zui.Locale` holds keeps the whole subtags
that fit. `showPage(false)`, the page hidden, is `suspend` in the next
record, after which the surfaces are suspended and nothing is drawn;
`showPage(true)` is `resume`, and the surfaces resume unless the context
is lost. Input waits in an inbox of 256 events and 1,024 bytes of text,
in CSS pixels until a poll converts them to layout units over the
application's zoom; what does not fit is dropped and counted in the
record. `zig build test` runs `zui_testing.expectPushedHostConforms` on
it over a scripted platform whose loop waits on the real clock, and
`check` compiles it for the browser as the tour target's host.

**The browser's host** is `Host` (`src/browser_host.zig`), `HostOn` the
imports of the dedicated worker it runs in, `web/host_worker.mjs`. The
page, through `web/host_page.mjs`'s
`runOnHost(canvas, moduleUrl, stopped)`, starts that worker and
transfers the canvas to it as an `OffscreenCanvas`; `input_recorder.mjs`
reads the canvas's events into `messageSink`, which posts the calls each
event made as one message, and the page measures the canvas's CSS size
and `devicePixelRatio` on the animation frame after a resize or a change
of scale, and sets the cursor the worker posts back.
`web/page_environment.mjs`'s `followPageEnvironment` reads the page's
settings into the same sink, once at the start and again on each change:
`prefers-color-scheme`, `prefers-contrast: more` or
`forced-colors: active` as high contrast, `prefers-reduced-motion`,
`prefers-reduced-transparency`, `navigator.language` and
`languagechange`, the document's computed `direction`, watched for
changes of the root's `dir` and `lang`, `focus` and `blur`, the
`AccentColor` system color, read from a hidden element's computed
`color` ("none" where `CSS.supports` does not know it), and
`visibilitychange`. No event tells of a new accent alone, so the page
reads it again when the color scheme or forced colors change. The worker
delivers the first settings before it attaches the canvas, so the first
record carries them. The worker instantiates the module on shared memory
and calls its `zuiWebRun`, which runs the application through
`zui_app.runWith`; the host's `zuiRun` keeps its turns and calls
`zuiWebHostYield`, which throws, unwinding to the worker's event loop
without running the epilogues of the frames below, as Emscripten's main
loop does. The worker then starts the task threads, each a worker on the
same memory (`web/tour_thread.mjs`), attaches the canvas, drawn by a
`FrameDrawer`, and from then on takes each turn, `zuiWebHostTurn`, from
`requestAnimationFrame` or a timer as the host schedules it
(`zuiWebHostSchedule`), and hands the page's events to the module's
`zuiWeb*` exports, which take them as the client's do, with their times
moved onto the worker's clock. A wake from a task's thread is posted to
the host's worker, which asks for a turn unless one is due. A lost WebGL
context, whose default the worker prevents, suspends the surfaces; when
the browser restores it, the worker makes the canvas's `FrameDrawer`
again, and the renderer hands it the whole glyph atlas with the next
frame. An application's root names `zui_web.worker.std_options` and
`zui_web.worker.os`, whose `heap.page_allocator` is the allocator
`zui_web.worker.setup` hands the application, and exports `zuiWebRun`:

```zig
const Tour = zui_tour.App(.{ .Host = zui_web.Host, .Renderer = zui_webgl.Renderer, .Text = zui_truetype.Text, .renderer_name = "WebGL 2" });

pub const std_options = zui_web.worker.std_options;
pub const os = zui_web.worker.os;

export fn zuiWebRun() void {
    const setup = zui_web.worker.setup(.{ .task_threads = 16 }) catch |err| return zui_web.worker.fail(err);
    zui_app.runWith(Tour, setup, .{ .title = "zui tour" }) catch |err| zui_web.worker.fail(err);
}
```

The tour target, `examples/tour.zig`, does this around the tour, whose
frames it times on the worker's clock. `zig build tour` writes its page,
`web/index.html`, the published page, with its scripts and
`zui-tour.wasm` (2.7 MB in ReleaseSmall, the fonts embedded), to
`zig-out/tour`. `zig build test-host` serves it cross-origin isolated to
headless Chromium, which needs no display, and reads the worker through
the DevTools protocol: the tour must draw at least 64 colors at the
canvas's size after a resize to 1280×800 CSS pixels at a ratio of 1.25;
take at most 3 turns in 2 s idle on the Overview and on Settings, the
heartbeat alone, while the page sees at least 30 animation frames; show
the pointer cursor on the page's canvas with the mouse over the rail,
and change the canvas on Ctrl+PageDown; and, after `WEBGL_lose_context`
loses and restores its context on Settings, draw Settings again, at most
2% of its pixels changed. Then, through `Emulation.setEmulatedMedia`,
the worker must hear the page's first settings; an emulated dark scheme
must darken the canvas's mean luminance and a light one lighten it, each
by at least 20 of 255; more contrast must change at least 0.5% of
Settings and a right-to-left document at least 5%, each back within 2%
when undone; reduced transparency and a changed `navigator.language`,
which the tour does not show, must reach the worker; another tab in
front must hide the page and take its focus, and the worker draw no
frame in 1.5 s, and the page brought to the front again draw Settings as
before; and on Clickable Chaos, whose wall moves, reduced motion must
leave the worker at most 3 turns in 2 s. The tour target times the
tour's frames on the worker's `performance.now()`
(`zui_web.worker.millisecondsNow`), since the `SteppedIo`'s clock stands
still for all of a turn, and exports what its strip shows
(`zuiTourNewestFrameMicroseconds`); `zui_web.worker` exports the tasks
started and finished (`zuiWebTasksStarted`, `zuiWebTasksFinished`), for
the checks.

**Text input and services.** While a frame asks for text input, the host
posts the caret, in CSS pixels, to the page, which places a hidden text
field there (`web/page_text_field.mjs`, `HiddenTextField`), transparent
rather than hidden from layout, so it keeps the focus and the browser's
IME composes in it; a frame that stops asking takes it away and gives
the canvas the focus back. While the field has the focus the canvas
hears no keys: the field sends each key as the canvas would, but a key's
text comes only from what the field took, its `input` or, for an IME,
`compositionend`, so a printable key's text reaches the record once. The
record has no place for a composition in progress, so only committed
text is sent. `zuiClipboard` copies through the page's
`navigator.clipboard.writeText`, refusing more than 64 KiB or text that
is not UTF-8, and reads through `readText`, one read at a time (another
is `Busy`): the page answers with a sink call, the text or the failure
(`denied` when the browser refuses, `unavailable` otherwise), and the
host publishes it into the read's sink, with what did not fit its 64 KiB
counted as left out. `zuiOpenUrl` refuses what `zui.isOpenableUrl`
refuses and hands the rest to the page, which opens it in a new tab
(`window.open(url, "_blank", "noopener")`). `test-input` places the
field and checks that a key typed into it and an IME's composition
(`Input.imeSetComposition`, `Input.insertText`) each reach the records
once; `test-host` clicks Settings' Port field, checks the field is
placed at its caret, that a typed key's and a composition's text reach
the tour once each, and, with the clipboard's permission granted
(`Browser.grantPermissions`), that what the module copies reaches the
page's clipboard and what the page copies answers the module's read. The
tour does not use the clipboard, so the tour target exports calls for
the check alone (`zuiTourCopyForCheck`, `zuiTourPasteForCheck`). Limits:
`navigator.language` is read but not mapped to a direction when the
document gives none; the browser may block a new tab opened without the
user's gesture, and allows clipboard reads only with the user's
permission.

**The published page** is the tour target's, `web/index.html`, the tour
on the web host. GitHub Pages cannot send the headers that make a page
cross-origin isolated, so the page registers a service worker of its
own, `web/isolation_service_worker.js`, which serves the page and
everything it loads again with them, and reloads once; it caches
nothing, so a returning visitor gets what the site serves now.
`zig build site` writes it to `zig-out/site`: the page, the scripts its
page and worker load, the frame drawer, `zui-tour.wasm`, which embeds
the tour's fonts (2.7 MB in ReleaseSmall, 513 KB gzipped), and the
fonts' licences. The Pages workflow (`.github/workflows/pages.yml`)
builds it in ReleaseSmall, checks it, and publishes it from `main`.
`zig build test-site` serves that site without the isolation headers, as
GitHub Pages does, opens it in headless Chromium, and reads the worker
through the DevTools protocol: the service worker must isolate it after
one reload; the tour must draw at least 64 colors at the canvas's size,
its frames timed above 0 µs; idle, it must draw at most 3 frames and
take at most 3 turns in 2 s on the Overview, the heartbeat alone, while
the display runs on; the mouse over the rail must show the pointer
cursor the tour asks for, and Ctrl+PageDown draw the next screen; a
click on Log Tail must start its producers' tasks, whose frames keep
coming without input, the host never scheduling a turn later than their
next publication; and on Photo Culling every photo's load must finish
without input, the host never waiting for input while a task is left,
and the worker sleep again.

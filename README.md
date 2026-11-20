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
- **Stage 3:** the renderer contract (`zuiSubmit`, the surfaces
  it draws into, the optional commands it draws), checked at compile time
  by `zui.checkRenderer`, and a `RenderCommand` union generated with
  exactly the variants a renderer draws, so its exhaustive `switch` names
  nothing else. `zui_raylib`, `zui_sokol` and `zui_terminal` are renderers.
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
  its capabilities, fallbacks and every exceeded limit once. `zui_raylib` is
  the first host: the demo runs through `zui_app` on it, and presents its
  first frame about 290 ms after the process starts, all but 5 ms of it
  raylib opening its window.
- **Stage 4:** the first native host, for Windows, in
  [hosts/native/](hosts/native/): its own message
  loop on a thread of its own, per-monitor scale, the environment
  (dark mode, high contrast, animations, power), lifecycle events
  (Ctrl+C and the session ending as a terminate request, sleep, low
  memory), dropped files, the cursor, the IME window and the clipboard,
  passing zui's host suite; and the system's material (Mica) behind the
  window where nothing is drawn, reported as
  `Environment.system_material`, so the same code draws its own
  background where there is none. The sokol renderer's tour runs on it unchanged,
  through `zui_app.run`, drawn by the sokol renderer into the native
  window, and idles at 0% CPU. `zui_app` makes an application's own text
  contract when the renderer does not measure (`pub const Text`), and
  lets it set its zoom and add events to each record (`zuiRecord`).
  The record carries the new events: `ui.filesDropped()` and
  `ui.lifecycle()`.
- **Stage 5:** `ui.relayTo(listener)` hands a listener each
  record as applied, with what each source delivered, during
  `beginFrame`; fed back with its deliveries, a relayed session replays
  to the same commands. `zui_wire` writes those records and the frames
  that come out as bytes, each frame as the changes from the one before,
  and reads them back in another process: the sokol renderer's tour averages 240
  bytes a frame instead of 24 KB on all but its stress screen, and a
  stream carries its fonts' fingerprint so a reader with other fonts
  refuses it. `zui_wire.Host` and `zui_wire.Renderer` run an application
  whose window is elsewhere, and `zui_wire.Client` joins any host and
  renderer to it over a socket, sending input and drawing the frames
  that come back: `zui_host`'s `zig build remote` runs the sokol renderer's tour in
  one process and draws it in another, keys going one way and frames the
  other. In tests, `zui_testing.Recording` keeps a session's records
  and `driver.replay` runs them again, with no loader: a recorded session
  of the tour replays to identical commands without starting any work,
  but for the counts its gallery keeps outside its sources. And a host
  can watch directories (`zuiFileWatch`), publishing each
  `zui.FileChange` into a source: `zui_host`'s `zig build theme` restyles
  its window a few milliseconds after its theme file is saved.
- **Stage 6:** a text that fits is laid out as one line without
  walking its words, and a whole-string cache makes a warm text one probe
  instead of one per word: 1,000 warm texts now lay out in about 67 µs. The
  box tree of 4,096 boxes declares in about 57 µs and lays out and emits
  its commands in about 109 µs, both within their budgets (on a 2020
  desktop core at its 3.7 GHz base clock, Turbo Boost off). Static styles:
  `zui.static(zui.Style{ ... })` makes a style at comptime, and
  `.style = toolbar_style` on an element references it instead of
  copying it, so 4,096 styled boxes declare in about 28 µs. A text
  contract with `zuiSegment` reports where a paragraph may break into a
  `zui.BreakSink`, so CJK and Thai wrap between characters; without it,
  text breaks after spaces as before. `.width = .grow` starts from the
  content and adds a share of the free space, as CSS `flex: auto`;
  `.width = .grow_equal` shares the whole width, as `flex: 1`, so columns
  come out equal whatever they hold. `.height = .aspectRatio(16.0 / 9.0)`
  derives a height from the width, and an image declared with
  `.natural_size` takes that size and keeps its proportions as its width
  grows or shrinks. A border's `.between_children = 1` draws a divider
  between each two children, centered in the gap, and an image's `tint`
  is multiplied into its pixels and its `corner_radius` rounds it, as
  `zui_raylib` and `zui_sokol` draw it and the renderer suite checks. A
  floating element may attach to an element declared after it; with
  `.capture = false` it lets the pointer through to what it covers, as a
  tooltip should, and with `.clip = .target` it is cut off where its
  target's children are, so a badge on a row scrolls away with the row.
  When the environment reads right to left, the layout mirrors: rows
  flow from the right, `.start` and a padding's `left` are on the right,
  floating anchors flip and text lines align right; `.mirrored = .no`
  keeps a subtree left to right, and `.direction = .right_to_left`
  reverses one row. With `.features = .{ .flex_wrap = true }`,
  `ui.wrapChildren()` after a row's `open` moves each child that would
  overflow it onto a new line, as CSS `flex-wrap`: each line grows and
  shrinks its children on its own, and is as tall as its tallest child.
- **Stage 7:** gestures, and drag and drop. An element declares what it
  accepts, `.gestures = .{ .pan = .horizontal }`, and once a pointer
  moves past the touch slop it goes to the innermost element that pans
  on that axis and can still move that way: a vertical drag on a
  carousel scrolls the list around it, and a drag that scrolls a list
  takes the press from the button it started on. Scroll containers pan
  with touch and pen. Two fingers zoom the innermost element that
  accepts `.zoom`, even when the pinch starts on a list inside it.
  `ui.manipulation(id)` reports what pans, pinches and the wheel did to
  an element, such as a map: translation, scale, rotation and pivot.
  `.long_press` turns a held press into `ui.contextRequested(id)`, as a
  right click and the menu key do, and `.double_tap` gives
  `ui.doubleTapped(id)`, delaying only that element's single tap;
  `ui.dismissed`, `ui.adjusted` and `ui.navigated` read Escape and the
  arrows. A flick coasts on and slows down, frame by frame, as
  `nextFrame` asks. An element with `.custom` runs the application's own
  recognizer: `ui.pointerEvents(id)` gives it the pointers pressed on it,
  and every other gesture waits until it calls `ui.claim` or
  `ui.decline`; `zui_widgets`' `lasso` draws with a pen over a map that
  fingers still pan. A card that declares `.drag` drags on the axes no
  element around it pans on, so it leaves a vertically scrolling list
  sideways: `ui.dragging(id)` says where its pointer is,
  `ui.startDrag(id, payload)` gives it a typed payload, and a target
  reads it with `ui.dropped(id, Payload)`, or `ui.draggedOver` before
  the release, never as another type.
- **After stage 7, the foundation:** benchmarks that can be trusted.
  `bench-compare` pins itself to one core, records the machine's state,
  runs each scenario on its own in a shuffled order over three code and
  memory layouts, and calls a change only when its 95% interval lies
  beyond the noise band calibrated for that machine, so a change that
  only moves code is not called. `bench --counters` counts cycles and
  cache misses on Linux, `zig build counts` reports Callgrind's simulated
  misses beside its instructions, and `bench-report` sets machines side
  by side. Judged by them, the core got faster where no benchmark had
  looked: a tooltip declared before a 3,000-cell grid no longer sorts
  every command (671 µs to 79 µs), warm texts that wrap reuse their lines
  (43% faster), `init` takes 92 µs instead of 138 µs, and the id-to-rect
  table is 96 KiB smaller.
- **Stage 8:** effects. `.effects = &.{ .gradient = ..., .shadow
  = ... }` gives an element a linear gradient, interpolated in OKLab,
  and a shadow, which with no offset is a glow, both in the shape of its
  rounded box. A renderer that declares `.gradient` and `.shadow` gets
  those commands; for any other, the core lowers a gradient to its
  middle color and a shadow to nothing, and `frame.diagnostics.lowered`
  says so. The sokol renderer draws both, on its tour's Light & Depth screen.
  `.backdrop_blur = .{ .radius = ..., .tint = ... }` is frosted glass
  over what zui drew beneath the element; the sokol renderer blurs it, and the
  other backends draw the tint it is lowered to.
  `.transform = .{ .translation, .scale, .rotation, .origin }` moves an
  element and its subtree as painted, leaving layout alone, and a
  pointer hits it where it is drawn; the sokol renderer draws it, on its tour's
  Transforms screen, and the other backends draw and hit-test the
  element as laid out.
  A renderer with a `MaterialHandle` gives the decoration a `material`,
  its own shader drawn in place of the background, which is the
  fallback a renderer without `.material` draws; the sokol renderer draws its
  own (`zui_sokol.Material`), on its tour's Materials screen, and the
  other backends draw the fallback.
  `Config.Color = zui.ExtendedColor` declares HDR and wide-gamut colors
  in linear scRGB; for a renderer without `zui_extended_color` they are
  clamped to `zui.Color` as they are emitted, and
  `frame.diagnostics.clamped_colors` says when that changed one;
  `zui_wire` carries them as declared when its context's commands do,
  and the sokol renderer takes them as declared and encodes them into its 8-bit
  sRGB target. A host and a renderer that both declare `.scrgb_fp16`
  in `zui_output_formats` open the window in it, and its surface says
  which format the host chose. The renderer suite reads an FP16 target
  back and checks HDR white there; the sokol renderer draws an `.offscreen`
  surface in `.scrgb_fp16` in linear light and passes it. On a monitor
  in HDR, `zui_host`'s Windows host opens the window in `.scrgb_fp16` and
  reports `hdr_headroom`, and the sokol renderer draws it into a half-float scRGB
  swapchain, where twice SDR white shows twice as bright.
  An element or frame without effects pays nothing for them.
- **Stage 9:** seeing the UI. `frame.inspect(index)` reports
  everything a frame kept of one element, and `zui_debug.Inspector(Ui)`
  is a panel over it: the frame's diagnostics, the fallbacks in effect
  (commands lowered, colors clamped, and a run's report handed to
  `reportRun`), the element tree, and the element under the pointer
  with every field of its layout, decoration, effects, floating and
  text style that differs from the default. `observe(frame, pointer)`
  after `endFrame` copies what it shows, and `declare(ui)` draws it in
  the next frame; `zui_app` hands an application each frame, before it
  is submitted, through its `zuiObserve` hook, and the raylib renderer's tour
  opens the panel with F12. With `zui_debug.ZoneTimer(Inner)` as the
  tracer, the panel also shows each zone's time in the last frame and its mean and
  peak over the last 60, while passing the zones on to `Inner`, such as
  `zui_tracy.Tracer`.
  `declareWithThemeFrom` draws the panel in a theme read from a ZON
  file: the host's file watch publishes the file's changes into a
  source, and the loader's `loadTheme(io)` reads it again into another,
  so a replay restyles as the live run did.
  With `features.semantics`, an element's `.semantics = .{ .role =
  .button, .label = "Save" }` puts it in `frame.semantics()`, with its
  value, bounds, state and actions, in tree order, and an `action` event
  naming it is answered by the queries of the input it stands in for:
  `invoke` by `clicked`, `adjust` by `adjusted`, `dismiss` by
  `dismissed`. Every `zui_widgets` control declares its own. A host that
  declares `zuiSemantics` is handed the list with each frame; `zui_host`'s
  Windows host bridges it to UI Automation, so Narrator reads each
  control's name, role, bounds, state and heading level, and a client's
  Invoke, Toggle, Expand, Collapse, Select, a range's SetValue, a scroll,
  ShowContextMenu, a dialog's Close and SetFocus arrive as `action`
  events.
  `frame.sweep()` checks the invariants every laid-out frame keeps
  (finite sizes, consistent child lists, free space and overflow shared
  as the sizing rules say, commands in nondecreasing layers with
  balanced clips) and names the first one broken; with
  `features.safety_sweeps`, on by default in safe builds, `endFrame`
  panics on it.
  The sokol renderer's tour runs in a browser, at
  <https://aaronjclausen.github.io/zui-web/>: zui-web builds it for
  `wasm32-freestanding` and runs it in a Web Worker, and its page draws
  the tour's frames over `zui_wire` through WebGL 2, with four samples
  per pixel as a native window with `sample_count = 4` has, and sends
  the canvas's input back as records.
- **Stage 10, begun:** `zui_host`'s Linux host opens a Wayland window
  through libwayland-client and xdg-shell, with the compositor's buffer
  scale, the pointer, the wheel, keys through the compositor's keymap,
  typed text, focus and cursor shapes, passing zui's host suite; the sokol renderer
  draws into it through EGL, and its tour runs on it unchanged and idles
  at 0% CPU. Held keys repeat at the compositor's rate; SIGINT, SIGTERM
  and SIGHUP are terminate requests, and sleeping and waking suspend and
  resume; the theme, contrast and reduced motion come from the XDG
  desktop portal and power from UPower, over a D-Bus client of the
  host's own. It scales by fractions through `wp_fractional_scale_v1`,
  reads and writes the clipboard, takes dropped files, watches files
  through inotify, shows notifications, the desktop portal's file
  dialogs and opens URLs, and `zig build theme` and `zig build services`
  run on it. The IME, a custom title bar, many windows, a system material
  and X11 come next. Host services have one checked shape each,
  reached through `zui_app.ServicesOf(Host)`'s compile-time `has_*`
  guards, with every answer published into a source the application
  chooses (`zui.ServiceReply`), so it relays and replays; the Windows
  host reads and writes the clipboard, opens URLs, and shows
  notifications, file dialogs, context menus and a menu bar through
  them, all five from one window in `zui_host`'s `zig build services`.
  With `features.chrome_regions`, an element's `.chrome = .title_bar`
  (or a caption button or a resize edge) lists it in
  `frame.chromeRegions()` for a window opened with `title_bar = .custom`,
  and `zui_app` hands the list to the host's `zuiChromeRegions`. The
  Windows host then drops its caption and answers `WM_NCHITTEST` from
  them, so Windows still drags, snaps, maximizes and resizes a window
  whose title bar the application draws, and shows snap layouts over its
  maximize button: `zui_host`'s `zig build title-bar`.
  Many windows: an application whose `zuiDeclare(app, ui, window)` takes
  the window declares each one in a context of its own, opening and
  closing them between frames through `Start(App).windows`, with each
  window's sources its own and one wait for all. `zui_host`'s Windows host
  opens up to four windows, and the sokol renderer draws each through its own
  swapchain on one device. In `zui_host`'s `zig build many-windows`, two
  windows animating at once each hold the display's rate, and two idle
  windows use no CPU.

The reference backend, its adapter host and the demo application live in
[renderers/raylib/](renderers/raylib/); the other backends are
the sokol renderer in [renderers/sokol/](renderers/sokol/) and the
terminal renderer in [renderers/terminal/](renderers/terminal/); native
hosts live in [hosts/native/](hosts/native/).

[docs/feature-tour.html](docs/feature-tour.html) walks through every
shipped feature in the code a consumer writes, with semantic highlighting;
open it in a browser, or read [docs/feature-tour.md](docs/feature-tour.md).

Next, in the order of SPEC.md §21: the rest of the effects and of the
inspector, more hosts, motion and
text editing.
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

The engine and its modules are the package in `core/`; the repository's
root is the package `zui` that users fetch, which re-exports core's
modules and runs core's steps under the same names. Beside core:

- `themes/`, the package `zui_themes`: skins in the design languages of
  Windows, macOS, GNOME and KDE, as data applied through `zui_widgets`'
  skin contract (K4, after the skin contract, K5); a skeleton today.
- `examples/`: a template project (D1) and samples (D2); a skeleton today.
- `renderers/raylib/`, the package `zui_raylib`: the raylib renderer and
  adapter host, and the tour (see *The raylib renderer* below).
- `renderers/sokol/`, the package `zui_sokol`: the sokol renderer, and
  the tour on it (see *The sokol renderer* below).
- `renderers/terminal/`, the package `zui_terminal`: the terminal
  renderer (see *The terminal renderer* below).
- `hosts/native/`, the package `zui_host`: the native hosts, for Windows
  and for Linux on Wayland, and their examples (see *The native hosts*
  below).

Each has its own `test` and `check`, run from its directory, and
`test-all` and `check-all` run them. The raylib renderer has these too,
run from `renderers/raylib/`; the first build fetches raylib and compiles
it:

| Command | What it does |
|---|---|
| `zig build test` | run the renderer's and host's unit tests |
| `zig build conformance` | run zui's renderer and host suites against them, in hidden windows; needs a display |
| `zig build test-tour` | declare every screen of the tour headlessly, and fail if one exceeds its limits or does not fit the default window |
| `zig build check` | compile the renderer, the tour, its tests and the conformance suites without producing output |
| `zig build demo` | run the tour |
| `zig build demo -- --screen gallery` | start on one screen |
| `zig build demo -- --frames 900 --cycle 40` | visit every screen, 40 frames each, then quit; add `--hidden` to do it in a hidden window |
| `zig build demo -- --screenshot <absolute path> --screen typography` | render offscreen in live mode, save a PNG, quit |
| `zig build demo -- --measure-idle` | report the CPU used over 10 idle seconds |
| `zig build demo -- --measure-startup` | report the time from process start to the first presented frame (Windows) |
| `zig build demo -- --zui-debug` | open `zui_debug`'s inspector, which F12 toggles |
| `zig build demo -Dzui-tracy=true` | trace zui's zones into Tracy 0.14.1 |

The sokol renderer has them too, run from `renderers/sokol/`; the first
build fetches sokol-zig and stb, and on Linux needs
`libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev libegl-dev libwayland-dev`:

| Command | What it does |
|---|---|
| `zig build test` | run the renderer's and `zui_sokol_ui`'s unit tests |
| `zig build conformance` | run zui's renderer suite against it in a window, always with OpenGL; needs a display |
| `zig build test-tour` | declare every screen of the tour headlessly, and fail if one exceeds its limits or does not fit the default window |
| `zig build check` | compile the renderer and the demo, and link the tour for `wasm32-freestanding`, without producing output |
| `zig build demo` | run the tour |
| `zig build demo -- --screen gallery` | start on one screen |
| `zig build demo -- --frames 900 --cycle 40` | visit every screen, 40 zui frames each, then quit |
| `zig build demo -Dgl=true` | render with OpenGL instead of D3D11 or Metal |
| `zig build shaders` | regenerate each `src/*.glsl.zig` from its GLSL with sokol-shdc, after the GLSL changes |

The terminal renderer has them too, run from `renderers/terminal/`:

| Command | What it does |
|---|---|
| `zig build test` | run its unit tests and zui's renderer suite against it |
| `zig build conformance` | run zui's renderer suite alone |
| `zig build check` | compile the renderer and the demo without producing output |
| `zig build demo` | run the demo in this terminal; Ctrl+C or Ctrl+Q quits |
| `zig build demo -- --dump` | render the demo offscreen at 100×30 and print its glyphs |

The native hosts have them too, run from `hosts/native/`; the examples
fetch sokol-zig and stb for the sokol renderer that draws them, and on
Linux the build needs `libwayland-dev libxkbcommon-dev libegl-dev`, and
for the examples sokol's
`libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev`:

| Command | What it does |
|---|---|
| `zig build test` | the unit tests, and zui's host suite and the host's own tests against a window the user never sees (on Linux, skipped without a Wayland compositor) |
| `zig build conformance` | only the host suite and the host's own tests |
| `zig build check` | compile the host, its tests and the examples; add `-Dtarget=x86_64-windows` or `aarch64-windows` to cross-compile |
| `zig build tour` | run the tour (Windows, Direct3D 11; Linux, OpenGL through EGL on Wayland) |
| `zig build material` | show the system material, or its fallback (Windows) |
| `zig build hdr` | show HDR white beside SDR white (Windows) |
| `zig build remote` | run the tour in another process and draw it here, over `zui_wire` (Windows) |
| `zig build theme` | a window styled by a theme file, restyled when it changes; `-- --check` scripts it |
| `zig build accessible` | `zui_widgets` controls for Narrator and Accessibility Insights (Windows) |
| `zig build services` | every host service from buttons, each answer shown; `-- --check` runs it against the fake |
| `zig build title-bar` | a title bar the application draws, which Windows still drags, snaps and resizes; `-- --check` hit-tests it hidden (Windows) |
| `zig build many-windows` | one application in two windows, each with its own UI; `-- --check` clicks and closes them hidden (Windows) |

Run these from the root:

| Command | What it does |
|---|---|
| `zig build test` | run the unit, golden, randomized-invariant, widget and compile-error tests (add `-Doptimize=ReleaseSafe` or `ReleaseFast` to test other modes) |
| `zig build check` | compile one full frame, every widget, the default sources and the test driver without producing output; add `-Dtarget=wasm32-freestanding` to check another target |
| `zig build test -Dzui-debug=true` | keep id names, so duplicate-id and unbalanced-tree panics name the element |
| `zig build test -Dzui-tracy=true` | fetch Tracy and test `zui_tracy` with its client linked |
| `zig build test -Dzui-sanitize-thread=true` | run the tests under ThreadSanitizer, through LLVM, on Linux; ThreadSanitizer needs ASLR entropy of at most 28 bits (`sysctl vm.mmap_rnd_bits=28`), or a container started with `--security-opt seccomp=unconfined` |
| `zig build bench` | run the benchmarks in ReleaseFast and print each phase's fastest, median and 95th-percentile frame; add `-- --check-targets` to fail on a missed performance target, `-- --core <n>` to pin to one core at a raised priority, `-- --machine-json <path>` to record the machine's state, `-- --scenario <name>` (see `-- --list-scenarios`) to run only some scenarios, or `-- --counters` to count each phase's cycles, instructions and cache and branch misses (Linux on bare metal); `ZUI_BENCH_LAYOUT_SEED=<n>` moves the stack and each `Context`'s memory, and `-Dbench-layout-seed=<n>` moves the code; `-- --results-dir <dir>` keeps the times and the machine they came from for `bench-report` |
| `zig build bench-report -- <dir> [<commit>]` | set side by side each machine's results for one commit, each normalized to its own box tree, and name the scenarios whose relative cost differs most between machines (see *Comparing machines*) |
| `zig build counts` | count each benchmark's instructions per frame under Callgrind, on x86_64 Linux with Valgrind (on Windows, in a Linux container), with simulated cache and branch misses beside them; add `-- --json counts.json` to save them and `-- --compare counts.json` to fail on more than 2% growth in instructions (misses are informational) |
| `zig build bench-compare -- main` | run the benchmarks of `main` and of the working tree alternately, pinned to one core, until each time's change is known closely enough; report each change with its 95% interval, calling it only beyond this machine's noise band; the rounds take turns with 3 layouts of code and memory (`-- --layouts <k>`), so a change that only moves code is not called; `-- --metric cycles` or `instructions` compares hardware counts instead of times; `-- <base> <head>` compares two commits (SPEC.md §20.3) |
| `zig build bench-install` | install the benchmark executable into `zig-out/bin`, as `bench-compare` does to run one scenario at a time; a base from before this step is compared one whole run at a time instead, which a scenario's position in the run can bias |
| `zig build bench-compare -- --calibrate` | compare `HEAD` with itself and save each time's noise band for this machine's setup; run it once per machine, and again after changing the setup |
| `zig build docs` | generate API documentation into `zig-out/docs` |
| `zig build test-all` | run `zig build test` in every package's directory, each as a process of its own |
| `zig build check-all` | run `zig build check` in every package's directory; `-Dtarget` and `-Doptimize` are passed on |
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
  2% growth, with simulated cache and branch misses reported beside them;
- the tests under ThreadSanitizer, which stress every `zui_async` source
  with producers on other threads;
- `zui_tracy` with Tracy's client, on Linux, Windows and macOS;
- the tests of `themes/` and `examples/` in three optimize modes, and
  their `check`, on Linux, Windows and macOS, each run from its directory;
- the raylib renderer's tests, `test-tour` and `check` on Windows, `check`
  on macOS, and on Linux, under `xvfb-run`, its conformance, a visit of
  every screen of the tour, five screenshots, kept as the run's
  artifacts, and the CPU the tour uses while idle, in the job summary,
  from `renderers/raylib/`;
- the sokol renderer's tests, `check` and `test-tour` on Linux, Windows
  and macOS, its `check -Dgl=true` on Windows, and its conformance on
  Linux under `xvfb-run`, from `renderers/sokol/`;
- the terminal renderer's tests, its conformance, its `check` and its
  demo's `--dump`, on Linux, Windows and macOS, from `renderers/terminal/`;
- the native hosts' tests in Debug and ReleaseSafe and their `check`, on
  Windows, and on Linux under a headless Weston with a D-Bus daemon of
  its own, and `check` for x86-64 and ARM64 Windows from Linux, from
  `hosts/native/`. The examples are compiled there and run on a desktop.

Those targets exist to catch assumptions about the host machine early:
the first 32-bit build found two places that used a 64-bit hash as an
index.

### Profiling

Set `.features = .{ .Tracer = zui_tracy.Tracer }` in the `Config`, call
`zui_tracy.frameMark()` after each presented frame, build with
`-Dzui-tracy=true`, and connect Tracy's profiler of the same version
(0.14.1). Every step of `beginFrame` and `endFrame` is a zone.
The raylib renderer's tour does all of this with `zig build demo
-Dzui-tracy=true`, run from `renderers/raylib/`. Without the profiler's window, Tracy's
`tracy-capture -o demo.tracy` saves a trace (run the demo with
`TRACY_NO_EXIT=1` so it waits for the capture to finish) and
`tracy-csvexport demo.tracy` lists its zones.

To keep noise out of a profile or a timing:
- pin the process to one core (`taskset -c 2` on Linux, `start /affinity 4`
  on Windows) and keep other work off it; `bench-compare` pins itself to
  the highest-numbered logical CPU, or the one `--core` names;
- fix the CPU frequency, as the next section describes;
- compare two builds by alternating them, never one after the other, as
  `zig build bench-compare` does; and prefer `zig build counts`, which no
  machine's noise can move.

### Quieting the machine

A CPU that boosts its clock with its temperature times the same code
differently from one minute to the next. `bench-compare` records the
machine's state before every run, shows it in its report, warns when it
changed during the comparison, and with `--require-quiet` refuses to run
while turbo is on or the Linux governor is not `performance`.

On Windows, from an administrator prompt:

```bat
powercfg /setactive SCHEME_MIN
powercfg /setacvalueindex scheme_current sub_processor PROCTHROTTLEMAX 99
powercfg /setactive scheme_current
```

The first line picks the High Performance plan. A maximum processor state
of 99% keeps the clock at or below its base frequency, which turns Turbo
Boost off. `PROCTHROTTLEMAX 100` turns it back on.

On Linux:

```sh
sudo cpupower frequency-set -g performance
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo   # AMD: echo 0 > .../cpufreq/boost
# keep other work off the measuring core: isolcpus=3 on the kernel command line, or
sudo cset shield --cpu 3 --kthread on
# take its hyperthread sibling offline (thread_siblings_list names it)
cat /sys/devices/system/cpu/cpu3/topology/thread_siblings_list
echo 0 | sudo tee /sys/devices/system/cpu/cpu13/online
# run without address randomization
setarch -R zig build bench-compare -- main --core 3 --require-quiet
```

Then run `zig build bench-compare -- --calibrate` once, so comparisons on
this setup are judged against its own noise.

### Comparing machines

Times from two machines are never compared directly, but what each
scenario costs relative to the others can be. On each machine, keep a
run in one shared directory:

```sh
zig build bench -- --core 3 --results-dir ~/zui-results            # also --counters on Linux
zig build bench-install -Dtarget=aarch64-linux                      # or build for another machine,
./zui-bench --core 3 --results-dir results --commit 45f48f4         # copy zig-out/bin/zui-bench there, run it, copy results/ back
zig build bench-report -- ~/zui-results
```

Each result lands in `<dir>/<machine fingerprint>/<commit>.json`, with
the OS and its version, the CPU, its cores and caches, the target the
benchmark was built for, and the power settings. `bench-report` divides
each machine's times by its own box tree's and lists the scenarios whose
relative cost differs most between machines.

Hardware counters come from `perf_event_open` on Linux, on x86-64 and
ARM alike, but only on bare metal: WSL2, Docker on Windows and GitHub's
hosted runners hide them. Windows has no public user-mode API for them:
Windows Performance Recorder can record them into a trace, from an
administrator prompt (`wpr -pmcsources` lists the counters a profile can
name), and Intel VTune and AMD uProf read them too. `bench` then records
the time and the clock speed alone.

On macOS, they come from the private kperf framework and need `sudo`, as
the macOS fork of poop reads them; `--counters` does not read them yet.

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
  `test` too, as the terminal renderer does.

`zui_testing.findRendererViolation` and `findHostViolation` return the
first violation instead of failing, and the doc comments of
`expectRendererConforms` and `expectHostConforms` list what a harness
declares. `renderers/raylib/`, `renderers/sokol/` and `renderers/terminal/` each have a
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
exe.root_module.addImport("zui_debug", zui.module("zui_debug"));
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

Renderers and the native hosts are packages of their own, reached
through the `zui` dependency's builder as the next sections show, so an
application fetches only the libraries of the renderers it uses.

### The raylib renderer

`zui_raylib` is a [raylib](https://www.raylib.com) renderer (zui's
renderer and text contracts, with raylib's fonts) and an adapter host
(zui's host contract on raylib's window), so an application runs on it
through `zui_app` in one call. It needs raylib **6.0**, the newest raylib
release whose build supports Zig 0.16, which is fetched the first time it
is built; on Linux, raylib's X11 and OpenGL development packages:
`libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl1-mesa-dev`.

![The tour's welcome screen](renderers/raylib/docs/demo.png)

```zig
// build.zig, with `zui` the dependency above
const zui_raylib = zui.builder.dependency("zui_raylib", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui_raylib", zui_raylib.module("zui_raylib"));
```

Give `zui_raylib` the same `.@"zui-tracy"` you give `zui`, if any, so the
two build one `zui` module and their types match.

```zig
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_raylib = @import("zui_raylib");

const App = struct {
    pub const Host = zui_raylib.Host;
    pub const Renderer = zui_raylib.Renderer;
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .Sources = AppSources }));

    sources: AppSources = .{},

    pub fn zuiDeclare(app: *App, ui: *Ui) void {
        // ... declare your UI ...
    }

    pub fn zuiLoader(app: *App, ui: *const Ui, io: std.Io) void {
        // ... start what the frame asked for ...
    }
};

pub fn main(init: std.process.Init) !void {
    try zui_app.run(App, init, .{ .title = "My app", .size = .{ 1100, 700 } });
}
```

`zui_raylib.Renderer` implements zui's renderer and text contracts. Its
surface is `.library`: raylib's own window between `BeginDrawing` and
`EndDrawing`, or a render texture between `BeginTextureMode` and
`EndTextureMode`. It draws each frame scaled by the record's zoom, and the
host divides the viewport and the pointer by it. Its `fonts` are raylib
`Font`s, indexed by `FontId`; an id past them draws in raylib's built-in
font. `zui_raylib.loadTrueTypeFont(data, pixel_size)` rasterizes a
TrueType font's printable ASCII into a mipmapped atlas, and measures
without a window, so a headless test lays text out as the window will;
`zui_raylib.unloadFont` frees it. `zui_app.contextConfig` builds the
`Config` from its declarations: the renderer measures text,
`ImageHandle` is raylib's `Texture2D`, so `ui.image(.{ .handle = texture
}, ...)` draws directly, and there are no optional commands and no
`CustomData`. The renderer's `switch` over the commands therefore names
exactly the base commands and `image`. raylib's OpenGL context belongs to
the thread that opened the window, so it does not declare
`zui_render_thread`, and `zui_app` submits on the UI thread.

`zui_raylib.Host` implements zui's host contract with one window and no
system material. `zuiPoll` samples raylib's input and begins drawing;
`zuiWait` presents, then sleeps in GLFW (compiled into raylib's default
desktop platform) until input arrives, the host is woken, or the instant
`nextFrame` names, and `.immediately` waits out the monitor's refresh
interval. Its `zuiWaker` sets a flag and posts an empty GLFW event, which
any thread may do; the flag is cleared only after a wait, so a wake
between `nextFrame` and the wait is not lost. Escape does not close the
window, since the application may want it. Beyond the contract:
- `drawOffscreen()` and `saveScreenshot(path)` draw into a texture and
  save it, as the tour's `--screenshot` does;
- `script(sample)` replaces raylib's input for one poll, as the host
  suite and the tour's screenshots do;
- `close()` closes the window as its close button would;
- `clear_color` is what each frame is cleared to.

| zui | raylib |
|---|---|
| `rectangle` | `DrawRectangleRec`, or `DrawRectangleRounded` with a corner radius |
| `border` | four bands inside the bounds; `DrawRectangleRoundedLinesEx` when uniform and rounded |
| `text` | `DrawTextCodepoint` per glyph, advanced by the glyph's metrics and the style's letter spacing |
| `image` | `DrawTexturePro` with the tint; with a corner radius, a fan of textured triangles through rlgl, each corner with its own radius |
| `clip_begin` / `clip_end` | `BeginScissorMode` / `EndScissorMode` with a stack, at the record's zoom |
| `gradient` / `shadow` | not drawn: zui lowers a gradient to its middle color and a shadow to nothing |
| zoom | rlgl's matrix scaled by `FrameParams.zoom`; the viewport and the pointer divided by it |
| pointer and keys | raylib's polled state, through `zui.InputSampler`; keys from `GetKeyPressed`, letters, digits and function keys included |
| wheel | `GetMouseWheelMoveV`, flipped and scaled by `InputOptions.wheel_step` |
| focus | `IsWindowFocused` changes, as the environment's `window_focused` |
| scale | `GetRenderWidth() / GetScreenWidth()`, as the record's scale |
| cursor request | `SetMouseCursor`, in `Host.zuiApply` |
| waits and wakes | GLFW's `glfwWaitEvents`, `glfwWaitEventsTimeout` and `glfwPostEmptyEvent` |

What raylib cannot do:
- **Sampled input.** raylib reports state once per frame, so a press and
  release between two frames is lost, as it is to raylib itself.
- **Corner radii.** raylib rounds all four corners of a rectangle or a
  border the same, so the largest of zui's four radii is used; an image
  rounds each corner by its own.
- **Letter spacing.** Text is measured glyph by glyph with the spacing
  after each glyph included: a glyph with no advance of its own, as in
  raylib's built-in font, takes `Renderer.bitmap_glyph_spacing` of the
  size, and the style adds its own. zui measures words and spaces
  separately and adds them up, so measurement has to be additive, and
  raylib's own `MeasureTextEx` leaves out the spacing after the last
  glyph.
- **One raster size per font.** A font's glyphs are rasterized once;
  smaller text is drawn from its mipmaps, and larger text is scaled up
  and softens. Only printable ASCII is loaded; other code points draw
  as `?`.
- **No IME window.** raylib cannot place one, so a text-input request is
  not applied.
- **One window.** `zui_capabilities.windows` is `.one`.

`zig build conformance`, run from `renderers/raylib/`, runs zui's two
suites in hidden windows: the renderer suite draws each frame into a
render texture and reads it back with `LoadImageFromTexture`, so it
checks every clip and fill, and the image's tint and rounded corners, by
their pixels; the host suite scripts the state `zui.InputSampler` reads
(`Host.script`), since raylib reports state, not events, and checks the
events' order, the waits and the wakes against the real window.

#### The tour

`zig build demo`, run from `renderers/raylib/` (see *Development* for its
flags), is a tour of what zui does today, one screen per feature. A
strip along the bottom times every zui frame: how many frames were
declared, and in the last second; why each frame was declared (input, a
resize, `requestFrame`, a `requestFrameAt` deadline, a source); what
`nextFrame` asked for; the cost of `beginFrame`, declaration, layout and
emission, and raylib's drawing; element and command counts; and how many
texts missed the measurement cache. **Ctrl+I** opens a draggable frame
inspector with the last 120 frames, the frame's limits and diagnostics,
and the environment. **F12** opens zui's own inspector, `zui_debug`,
along the right edge: the frame's diagnostics, the fallbacks in effect
(what this renderer lowers and the host lacks), each zone's time from
its `ZoneTimer` tracer, the element tree, and the configs of the element
under the pointer. `zui_app`'s `zuiObserve` hands it each frame. Its
theme does not reload from a file here, since this host has no file
watch.

| Screen | What it shows |
|---|---|
| Welcome | `requestFrameAt` ticking a clock once a second with no frames between; floating hints; focusable cards |
| Layout Lab | every sizing rule, alignment and gap on a live container; the knobs generated by `zui_reflect`; sizes read back with `rectOf`; the same layout printed as Zig |
| Box Storm | up to 14,000 animated boxes, a 90-deep spiral of `percent` containers, and text walls that either hit the whole-string cache or miss it every frame |
| Infinite Gallery | 10,000 tiles in a virtualized scroll container, loaded through `KeyedLoads` on other threads with progress, failures and cancellation; a hand-made scrollbar |
| Mission Control | `Latest` telemetry, a `Stream` log that a burst overflows into the diagnostics, a `Task` rocket launch with abort; producers run only while `framesSinceRead` says someone is watching |
| Window Manager | draggable floating windows with z order, a taskbar with tooltips, `attach_to = .element` with every anchor pair, a modal dialog in a focus scope |
| Robot Workshop | a robot editor generated by `zui_reflect` from nested structs, and environment changes (theme, contrast, reduced motion, text scale) as if the OS sent them |
| Pixel Pad | painting through `pointerLocal` on one element, tools on keys, undo with chords, and a live view of `keyEvents` and `typedText` |
| Typography | three TrueType fonts and raylib's built-in one, size, letter spacing, line height, wrap and alignment, a column to drag-resize, and a marquee looped with `measureText` and `setScrollOffset` |
| Light & Depth | `zui.Effects` on sliders with their declaration printed as Zig. This renderer does not draw `gradient` or `shadow`, so zui lowers them: a gradient to its middle color, a shadow to nothing |
| Classic | `examples/showcase.zig`, the UI every zui backend's demo shares, so the renderers can be compared |

Ctrl+1 to Ctrl+0 jump to the first ten screens, Ctrl+PgDn and Ctrl+PgUp
to the next and previous, Ctrl+= and Ctrl+- zoom (through
`FrameParams.zoom`), Ctrl+L declares a frame at every refresh to watch the
costs live, and Tab moves focus.

![The gallery loading tiles on other threads](renderers/raylib/docs/gallery.png)

`examples/demo.zig` is the tour's application as `zui_app` runs it: it
loads the fonts into the renderer, sets the record's zoom and the
environment changes the tour makes up, hands each frame to `zui_debug`
while its panel is open, and times each step for the strip;
`kit.Renderer` wraps `zui_raylib.Renderer` to time its submits. The tour
itself (`app.zig`, `kit.zig`, `perf.zig` and `screens/`) is the sokol renderer's,
with raylib's fonts in place of sokol_debugtext's and stb_truetype's,
and `zui_debug`'s panel on F12, which the sokol renderer's does not have yet.

`--measure-idle` runs the tour in a hidden window and reads its own CPU
time at two frames it asks for with `requestFrameAt`, 10 seconds apart,
after 5 seconds of warm-up, with the strip's once-a-second refresh off.
The Welcome screen's clock still ticks, so it declares about 10 frames.
`--measure-startup` reports how long after the OS created the process the
first frame was presented (Windows only: it reads the process's creation
time).

### The sokol renderer

`zui_sokol` is a [sokol](https://github.com/floooh/sokol) renderer,
through [sokol-zig](https://github.com/floooh/sokol-zig): it collects
sokol_app events into zui's frame records, measures text through zui's
text contract, and draws zui's frames as a renderer with sokol_gl,
sokol_debugtext, stb_truetype and shaders of its own, on D3D11
(Windows), Metal (macOS) or OpenGL (Linux). It draws every optional
command, gradients, shadows, backdrop blurs, transforms and materials,
and extended colors. sokol-zig and stb_truetype (from
[stb](https://github.com/nothings/stb)) are fetched the first time it is
built; on Linux it needs
`libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev libegl-dev libwayland-dev`.

```zig
// build.zig, with `zui` the dependency above; `.gl = true` renders with OpenGL instead of D3D11 or Metal
const zui_sokol = zui.builder.dependency("zui_sokol", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui_sokol", zui_sokol.module("zui_sokol"));
```

```zig
const zui = @import("zui");
const zui_sokol = @import("zui_sokol");
const Ui = zui.Context(zui_sokol.config(.{}));

// before the first frame, to draw TrueType text with `.font = body_font`:
const body_font = try text.addTrueTypeFont(@embedFile("Inter-Regular.ttf"));

// in sokol_app's init callback, after sg.setup:
renderer = .init(&text);
renderer.clear_color = background;

// in the event callback:
input.handleEvent(event, sapp.dpiScale(), now());

// in the frame callback:
const params: zui.FrameParams = .{ .now = now(), .viewport = viewport, .scale = sapp.dpiScale() };
ui.beginFrame(&.{ .params = params, .events = input.take() });
// ... declare your UI ...
const frame = ui.endFrame();
host_requests.apply(frame.requests());
try renderer.zuiSubmit(.library, frame); // one swapchain pass, cleared to clear_color
ui.release(frame);
```

`zui_sokol.Renderer` implements zui's renderer contract. Its surfaces are
`.library`, sokol_app's swapchain; `.offscreen`, an image of the renderer's
own in the surface's size and format (`.sdr` or `.scrgb_fp16`), which
`renderer.offscreenImage()` returns after `zuiSubmit`, drawn with
`renderer.offscreen_sample_count` samples per pixel (1 by default; 4
smooths its edges as a window with `.sample_count = 4` does) and resolved
to one; and on Windows `.win32`: a native host's window, such as
`zui_host`'s (in [hosts/native/](hosts/native/)), which the
renderer draws into without sokol_app, setting sokol_gfx up on a context
of its own and presenting with vsync. With D3D11 (the default) that is a
swapchain DirectComposition composes into the window with its alpha, so
where the frame draws nothing a system backdrop (Mica, Acrylic) shows.
With D3D11 the renderer declares `zui_output_formats` with `.scrgb_fp16`,
so a host on an HDR monitor can open the window in it: the swapchain then
holds half-float scRGB, the frame is drawn as into an `.scrgb_fp16`
offscreen image, and one pass copies it into the swapchain, multiplied by
the monitor's SDR white over 80 nits (read again at most twice a second),
so that SDR white shows as other windows' white does and a color above it
shows brighter. With D3D11 it draws into many windows: `zuiAttachSurface`
makes a swapchain for each window after the first on the first one's
device, which the renderer holds until `deinit`, so any window may close
first, and each window keeps its own scRGB and backdrop-blur targets;
`zuiDetachSurface` frees them before the window closes, and `zui_app`
calls both. With `-Dgl=true` it is an OpenGL 4.3 context, whose alpha
Windows ignores, and SDR only. On Linux the native surface is `.wayland`,
a native host's Wayland surface, which the renderer draws into with an
OpenGL 4.3 context made through EGL on a `wl_egl_window`, sized to each
frame's viewport in physical pixels and presenting with vsync; its
configuration has no alpha, so the compositor shows the frame opaque:

```zig
var renderer: zui_sokol.Renderer = try .initForSurface(&text, host.zuiSurface(.main));
defer renderer.deinit(); // also shuts sokol_gfx down
renderer.clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 }; // let the backdrop show
try renderer.zuiSubmit(host.zuiSurface(.main), frame);
```

`zui_host` runs the tour this way: `zui_sokol_tour` exports the tour's
application, so another loop can run it unchanged. `zui_sokol.config(...)`
builds the `Config` from its declarations: `Text` is `zui_sokol.Text`,
`ImageHandle` is `zui_sokol.Image` (the ids of a view and a sampler, made
by `zui_sokol.imageOf(view, sampler)`), `MaterialHandle` is
`zui_sokol.Material`, the optional commands are `gradient`, `shadow`,
`backdrop_blur`, `transform` and `material`, the renderer draws extended
colors (`Config.Color` may be `zui.ExtendedColor` or `zui.Color`), and
there is no `CustomData`, so the renderer's `switch` over the commands
names exactly the base commands, `image`, `gradient`, `shadow`,
`backdrop_blur`, `transform_begin`, `transform_end` and `material`. A
context with a `MaterialHandle` has its own element types, so a helper
that builds an element names `Ui.Element` (or `Ui.Decoration`,
`Ui.Style`) rather than `zui.Element`:

```zig
fn panel(seconds: f32) Ui.Decoration {
    return .{
        .background = .rgb(0x10304a), // drawn by a renderer without .material
        .material = .{ .pattern = .aurora, .first = .rgb(0x10304a), .second = .rgb(0x40e0a0), .phase = seconds / 8 },
        .corner_radius = .all(12),
    };
}
```

| zui | sokol |
|---|---|
| `rectangle` | sokol_gl quads, or a triangle fan with each corner's own radius |
| `border` | a ring of triangles inside the bounds, with per-edge widths and per-corner radii |
| `text` | `FontId` 0–5: sokol_debugtext, one call per wrapped line, with letter spacing placing each glyph on its own. From 6: a TrueType font added with `Text.addTrueTypeFont`, its glyphs rasterized by stb_truetype at the text's size in physical pixels into a glyph atlas and drawn as sokol_gl quads |
| `image` | a textured sokol_gl quad colored by the tint, or a triangle fan with each corner's own radius |
| `gradient` | the rounded outline cut into bands at most 4 units long across the gradient (64 at most), each vertex colored by `colorAt`, so sokol_gl's sRGB blend between vertices stays within a step of zui's OKLab one |
| `shadow` | the rounded box at the offset, grown by the spread, in the shadow's color, then six rings out to the blur, fading to clear along a smoothstep |
| `backdrop_blur` | the frame is drawn into an offscreen target like the swapchain, and paused at each blur: a Gaussian along x, then along y, of what lies under the element, its edge pixels repeated, summed tap by tap into two float targets the size of the frame: RGBA32F (16 bytes a pixel), or RGBA16F where the GPU cannot render, blend and filter that, though half floats round each sum as the driver chooses, and one driver's blur can differ from another's by several color steps; the frame resumes with the result drawn inside the rounded outline and the tint over it, and is copied to the swapchain at the end. A frame without one is drawn as before |
| `material` | `zui_sokol.Material`, a pattern between two colors (`solid`, `sheen`, `aurora`) moved by its phase: the rounded outline as a triangle fan, drawn by the material shader at the start of its own layer, before the layer's sokol_gl shapes. The shader and pipeline are made on the first frame with a material |
| colors | `zui.ExtendedColor` (the renderer declares `zui_extended_color`) or `zui.Color`, as the application declares them. Into an 8-bit target an extended color is clamped into SDR and sRGB's gamut and encoded to 8 bits, as `ExtendedColor.toColor` does. Into an `.scrgb_fp16` offscreen image (RGBA16F) the frame is drawn in linear light through a shader of the renderer's own, which decodes each 8-bit sRGB vertex color and texel; a color brighter than SDR white is carried divided by its brightest channel, with that channel in sokol_gl's per-vertex point size, which the shader multiplies back. Negative (out-of-sRGB-gamut) channels are still clamped there, bitmap text is drawn by sokol_gl rather than sokol_debugtext, and materials mix their colors in linear light |
| `clip_begin` / `clip_end` | `sg.applyScissorRect` per layer, at the record's `scale × zoom`; inside a transform, the box around the clip in the window |
| `transform_begin` / `transform_end` | sokol_gl's modelview matrix, loaded with the composed transform; a backdrop blur inside one blurs the box around it in the window and samples where it is drawn, and bitmap text inside one is drawn as sokol_gl quads from sokol_debugtext's own font bits, since sokol_debugtext has no matrix |
| mouse and touch | `MOUSE_*` and `TOUCHES_*` events, in order; each touch is a pointer of its own |
| wheel | `MOUSE_SCROLL` events, flipped and scaled by `InputCollector.wheel_step` |
| keys | `KEY_DOWN` and `KEY_UP` with their modifiers, repeat flag and key code as the scancode; `CHAR` as text |
| focus | `FOCUSED` and `UNFOCUSED` as the environment's `window_focused` |
| cursor request | `sapp.setMouseCursor`, through `HostRequestApplier` |

sokol_gl and sokol_debugtext each batch their own draws. To keep zui's
paint order, the renderer starts a new layer whenever a shape follows text
or the clip changes, then replays the layers in order, each under its own
scissor rectangle. The shaders, the material's, the linear-light one and
the scRGB present, are written in `src/*.glsl` and checked in as their
`.glsl.zig`, translated by sokol-shdc to GLSL 410, HLSL 5 and Metal, so
building `zui_sokol` never runs sokol-shdc; after changing the GLSL, run
`zig build shaders` from `renderers/sokol/`.

Current limits:
- **A backdrop blur's standard deviation stops at about 42 physical
  pixels**, the widest its 129 taps per axis reach, and a frame blurs at
  most 16 elements; the rest draw their tint alone, counted in
  `Renderer.backdrop_blurs.lowered`, as do all of them on a GPU that
  cannot render, blend and filter RGBA32F or RGBA16F. The format the
  blurs are summed in is `Renderer.backdrop_blurs.accumulation_format`.
- **A frame draws at most 256 materials**, of 32,768 vertices in all;
  the rest draw their fallback background, counted in
  `Renderer.materials.lowered`, as do all of them on a backend sokol-shdc
  was not asked for (GLES, WebGPU, Vulkan) or where the shader does not
  compile.
- **A turned clip cuts to the box around it.** A scissor rectangle is
  upright, so a clip inside a rotated transform lets through what lies
  between it and the box around it in the window; moved or scaled, it
  cuts exactly. Transforms nest 64 deep; deeper ones are drawn as their
  parent is, counted in `Renderer.transform_overflows`.
- **A shadow is geometry, not a blur.** Its fade is drawn in rings, so a
  wide blur on a small box shows faint steps, and a translucent element
  shows its own shadow through it.
- **Bitmap fonts are ASCII.** sokol_debugtext's fonts are 8×8 and printable
  ASCII only; other code points draw as `?`. Their glyphs are
  `Text.glyph_scale` of the text size, and every glyph has the same advance.
- **TrueType text has no kerning or shaping.** Each codepoint is one
  glyph, advanced by its own width, so measuring a run split at any word
  gives the same width. The atlas is one 1024×1024 image, remade whenever
  a frame needs glyphs it lacks (sokol_gfx images cannot be updated once
  made); when a frame needs more than it holds, it starts over, and
  `Renderer.glyph_overflows` counts frames whose glyphs still did not fit.
  Text larger than 160 physical pixels is drawn from 160-pixel glyphs.
- **No idle sleep.** sokol_app presents at every display refresh, so the
  process never sleeps. The demo declares a zui frame only when
  `nextFrame` or new input calls for one, and otherwise redraws the frame
  it holds; untick "1 Hz" in its header and an idle screen declares none.
- **No IME window.** sokol_app cannot place one, so a text-input request
  is not applied.

`zig build conformance`, run from `renderers/sokol/`, runs zui's renderer
suite (`zui_testing.expectRendererConforms`) against the renderer, in the
first frame of a sokol_app window, four times: into the window's
swapchain, into an `.offscreen` surface in `.sdr` and in `.scrgb_fp16`,
and into an `.sdr` one with four samples per pixel. `src/conformance.zig`
reads each frame back, from the swapchain with `glReadPixels` before the
window presents it and from the offscreen image with `glGetTexImage`, so
the suite checks every clip and fill, the image's tint and rounded
corners, and a drawn gradient, shadow, backdrop blur, transform and
material, by their pixels. The harness's material is `Material.solid`,
drawn through the shader. The suite declares its scene in
`zui.ExtendedColor`, HDR white among it, and checks that each color is
encoded as `ExtendedColor.toColor` does in an 8-bit target, and that HDR
white reads back four times SDR white, with colors blended and blurs
averaged in linear light, in the FP16 one. sokol_gfx cannot read a frame
back, so the suite always renders with OpenGL, whatever `-Dgl` says. CI
runs it on Linux under `xvfb-run`, and it passes on Windows.

#### Without sokol

An application that only declares frames, for a renderer elsewhere to
draw, imports `zui_sokol_ui`, which does not import sokol: `Text`,
`truetype`, `Material`, `Image`, the commands the renderer draws, and
`config`, which `zui_sokol` re-exports and checks against its renderer.
Without a C library, as on `wasm32-freestanding`, its stb_truetype
allocates nothing: it measures every font, and would rasterize no glyph.
The tour declares its `Ui` through it, so `zui_sokol_tour` builds where
sokol does not, and given a freestanding target, the package's build
fetches stb alone and makes only those two modules:

```zig
const zui_sokol = zui.builder.dependency("zui_sokol", .{ .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }) });
module.addImport("zui_sokol_tour", zui_sokol.module("zui_sokol_tour"));
```

`zig build check` compiles and links `examples/tour_freestanding.zig`,
the tour declaring a frame for `wasm32-freestanding`, so the tour keeps
building there. Nothing the tour draws depends on the target's pointer
width, so on the same clock and input it draws the same frames in
WebAssembly as natively, which zui-web's `test-demo` checks.

#### The tour on sokol

`zig build demo`, run from `renderers/sokol/` (see *Development* for its
flags), is the raylib renderer's tour on sokol: the same screens, the
strip of frame costs along the bottom, **Ctrl+I**'s frame inspector and
the same keys, but no `zui_debug` panel. Its Typography screen shows
sokol_debugtext's six bitmap fonts beside the TrueType ones, its Light &
Depth screen draws the gradients, shadows and frosted pane that the
raylib renderer lowers, and two screens are its own:

| Screen | What it shows |
|---|---|
| Transforms | `zui.Transform`: a card turned, moved and scaled about its origin from sliders, its declaration printed as Zig and its button pressed where it is drawn; turned tiles that hover and press where drawn; clock hands turned about their foot; the six bitmap fonts, turned |
| Materials | `zui_sokol.Material`: a card drawn by the renderer's own shader, its pattern, colors, wave and phase on sliders and its declaration printed as Zig; every pattern side by side; the material beside its fallback background, as a renderer without `.material` draws it; a shadow beneath one and a border and button over it |

### The terminal renderer

`zui_terminal` decodes keys, mouse reports and focus reports into the
events of zui's frame records, measures text in cells through zui's text
contract, and paints zui's frames as 24-bit-color cells, as a renderer.
It needs no library besides zui, and a terminal with VT sequences, 24-bit
color and SGR mouse reports: Windows Terminal, the Windows 10+ console,
or any xterm-compatible terminal on Linux and macOS.

```zig
// build.zig, with `zui` the dependency above
const zui_terminal = zui.builder.dependency("zui_terminal", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui_terminal", zui_terminal.module("zui_terminal"));
```

```zig
const zui = @import("zui");
const zui_terminal = @import("zui_terminal");
const Ui = zui.Context(zui_terminal.config(.{}));

var terminal = try zui_terminal.Terminal.enter(io);
defer terminal.leave();
var text: zui_terminal.Text = .{};
var ui = try Ui.init(gpa, io, &text);
var screen: zui_terminal.Screen = .{};
var renderer: zui_terminal.Renderer = .{ .gpa = gpa, .screen = &screen, .output = stdout, .background = background };
var decoder: zui_terminal.InputDecoder = .{};

while (!decoder.quit_requested) {
    const surface = terminal.surface(); // .terminal, with the size in cells
    ui.beginFrame(&.{ .params = .{ .now = terminal.now(), .viewport = viewportFor(surface) }, .events = decoder.take() });
    // ... declare your UI ...
    const frame = ui.endFrame();
    try renderer.zuiSubmit(surface, frame); // paints the cells and writes what changed
    ui.release(frame);
    terminal.wait(ui.nextFrame());
    decoder.feed(terminal.readAvailable(&read_buffer), terminal.now());
}
```

`zui_terminal.config(...)` builds the `Config` from `Renderer`'s
declarations: it declares no optional commands and no payload types, so
its `switch` over the commands names only the five base commands. To
paint into a `CellBuffer` of your own, call `zui_terminal.render` instead.

`terminal.wait` sleeps as `nextFrame` says: not at all, until a
requested instant, or until input, a resize or a wake, so an idle UI uses
no CPU. `terminal.waker()` is a `zui.Waker` for sources' producers: on
Windows it writes a console input record, elsewhere it writes to a pipe,
and either way a wake that arrives before the wait still ends it. On
Linux and macOS a resize does not wake `poll`, so an idle wait looks at
the size every 250 ms and runs a frame only when it changed.

Layout stays in pixel-like units: a cell is `Text.cell_size` units (8×16
by default), so a UI written for a pixel renderer still lays out
sensibly. A cell is painted when its center lies inside a command's
bounds.

| zui | terminal |
|---|---|
| `rectangle` | cell backgrounds; translucent colors blend over what is below |
| `border` | box drawing (`┌─┐`, or `╭─╮` with a corner radius); `[` `]` on a one-row box |
| `text` | one glyph per code point, one line per command; letter spacing moves each glyph to the nearest cell |
| `clip_begin` / `clip_end` | a stack of cell rectangles |
| pointer | SGR mouse reports as `pointer_move`, `pointer_down` and `pointer_up`, in the order they arrived |
| wheel | SGR wheel reports, `InputDecoder.wheel_step` units per notch |
| keys | navigation, function and editing keys; letters and digits also as keys, so Ctrl+S and Alt+S are chords |
| focus | focus reports (`CSI I` / `CSI O`) as the environment's `window_focused` |

What a terminal cannot do:
- **One font, one size.** `Text.zuiMeasure` ignores both: every code
  point is one cell, plus the letter spacing after it. Wide characters
  (CJK, most emoji) take two cells on screen but are measured as one.
- **Borders never overwrite glyphs.** zui draws borders after their
  children, so a border cell that already holds text keeps it.
- **No cursor shapes or IME window.** The frame's host requests are not
  applied.

### The native hosts

`zui_host` holds the native hosts: each owns its OS's windows and event
loop, and implements zui's host contract, so any renderer that draws into
the same kind of surface can draw for it. One directory of
[hosts/native/](hosts/native/) per OS, chosen by the target: Windows, and
Linux on Wayland. On Linux it needs
`libwayland-dev libxkbcommon-dev libegl-dev`.

```zig
// build.zig, with `zui` the dependency above
const zui_host = zui.builder.dependency("zui_host", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui_host", zui_host.module("zui_host"));
```

```zig
const zui_host = @import("zui_host");
const Host = zui_host.Host; // zui_host.windows.Host on Windows, zui_host.linux.Host on Linux
```

With `zui_app`, name it as the application's host:

```zig
const App = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = MyRenderer; // one that draws into .win32, or .wayland on Linux
    // ...
};
```

The host must not move between `init` and `deinit`, since its window
thread (on Windows) and the compositor's listeners (on Linux) hold a
pointer to it, as does the Linux host's signal handler. `forced_scale`,
`system_material_unavailable` (Windows) and `bus_addresses` (Linux) may
be set before `init`, which keeps them; `zui_app` starts each field at
its default. `service_fake` may be set before `init` too, or after it
with `Host.fakeServices(fake)`, before the first service call.

The examples below are run from `hosts/native/` (see *Development* for
the steps), each drawn by the sokol renderer.

#### The Windows host

`zui_host.Host` opens Win32 windows and gives renderers each one's `win32`
surface (the `HWND`). Its message loop runs on a thread of its own, so a
window keeps drawing while the user drags its edges or moves it. It:

- opens many windows (`zui_capabilities.windows = .many`): `init` opens
  `.main`, and `zuiOpenWindow(options)` up to `Host.max_windows - 1` more,
  each with an id never given twice, its own events, scale, requests,
  chrome regions, accessibility bridge and menu bar, polled by its id;
  `zuiCloseWindow(window)` closes any of them, `.main` included. One wait
  covers them all. A message-only window anchors the window thread and
  owns the clipboard and the notification icon, so every service keeps
  working whichever windows are open, and the console's terminate and
  low memory reach every window;
- reports per-monitor scale (per-monitor DPI awareness v2), keeping the
  window's size in layout units when it moves to a monitor of another DPI;
- reports the mouse, the wheel, keys with their modifiers and scan codes,
  and typed text as UTF-8, surrogate pairs joined and consecutive
  characters in one event;
- reports the environment: dark mode (also darkening the title bar), high
  contrast, animations turned off (`reduced_motion`), power (plugged, on
  battery, battery saver) and whether the window has focus;
- reports lifecycle events: Ctrl+C, Ctrl+Break, the console closing,
  logging off, shutting down and the session ending are
  `.terminate_requested`, after which the next poll reports the window
  closed; the system sleeping and waking are `.suspend` and `.resume`;
  low memory is `.low_memory`;
- reports files dropped onto the window, with their paths and where;
- sets the cursor a frame asks for, and places the IME's composition and
  candidate windows at the caret of a frame's text-input request, turning
  the IME off while no editable asks for one;
- waits as `nextFrame` says: at once, until an instant on a
  high-resolution timer, or until input or a wake, which is sticky and
  works from any thread;
- offers zui's host services: the clipboard as text,
  `Host.zuiClipboard.write(host, text)` and `read(host, request, sink)`;
  `Host.zuiOpenUrl.open(host, url)`, which hands a URL to the system's
  handler for its scheme and refuses paths and `file:` URLs;
  `Host.zuiNotifications.show(host, request, notification, sink)`, a
  balloon of the window's notification-area icon, which Windows 10 and
  11 show as a toast, answering `.notification_activated` when clicked
  and `.notification_dismissed` when it times out, is closed or is
  replaced by the next; and `Host.zuiFileDialogs.show(host, window,
  request, dialog, sink)`, the shell's open, save and folder dialogs,
  owned by the window and one at a time, answering `.files_chosen` with
  the paths chosen or `.canceled`; and `Host.zuiMenus`, Windows' own
  menus: `popup(host, window, request, items, position, sink)`, a context
  menu at a position in layout units, one at a time with a file dialog,
  answering the item chosen or `.canceled`, and `setBar(host, window,
  request, items, sink)`, which replaces the window's menu bar, or
  removes it given no items, and answers each item chosen from it, or is
  `error.Unavailable` under a custom title bar, which would hide it. Labels
  show as written, with shortcuts after them (`Ctrl+Shift+S`). Each call
  returns at once; the window thread does the work and publishes every
  answer, a `zui.ServiceReply`, into a source of the application's, so
  answers never come from two threads;
- watches up to four directories, each with its subdirectories, through
  `Host.zuiFileWatch.watch(host, directory, sink)`: a thread per
  directory waits on `ReadDirectoryChangesW` and publishes each change, a
  `zui.FileChange`, into a source of the application's, waking the window
  for the first since the last frame;
- shows the system's material behind the window when it asks for one
  (`WindowOptions.material`: `.window` is Mica, `.transient` Acrylic),
  and reports whether it shows as `Environment.system_material`: false on
  Windows 10 and Windows 11 before 22H2, with transparency effects turned
  off, or for `.none`;
- opens the surface in `.scrgb_fp16` while the window's monitor runs in
  HDR, if the window was opened with it (`zui_app` passes it when the
  renderer declares it too), and in `.sdr` otherwise, and reports
  `Environment.hdr_headroom`: the monitor's peak over the SDR white that
  its SDR content brightness slider sets, or 1 in `.sdr`. Moving to
  another monitor and turning HDR on or off change both;
- bridges `Frame.semantics()` to UI Automation, through `zuiSemantics`,
  when the window was opened with room for it (`WindowOptions.semantics`,
  which `zui_app` sizes from `Config.limits` when `features.semantics` is
  on); see *Accessibility* below;
- leaves the title bar to the application for a window opened with
  `WindowOptions.title_bar = .custom`, reporting
  `Environment.custom_title_bar` and `.window_maximized`, and answers
  Windows from the frame's chrome regions, which `zui_app` hands to
  `zuiChromeRegions`; see *A custom title bar* below.

It passes zui's host suite (`zui_testing.expectHostConforms`) against
hidden windows, two of them for its many-windows steps, whose harness
sends each window the messages Windows would.

#### The Linux host

On Linux, `zui_host.Host` opens a Wayland window through libwayland-client
and xdg-shell, and gives renderers its `wayland` surface (the `wl_display`
and `wl_surface`). It reads and dispatches the compositor's events on the
thread that polls it, since a Wayland client has no modal loop to escape.
So far it:

- reports the scale the compositor prefers: fractional
  (`wp_fractional_scale_v1`, in 120ths) where it also offers
  `wp_viewporter`, the buffer drawn at physical pixels and the viewport
  giving the surface its size; otherwise the integer buffer scale
  (`wl_surface.preferred_buffer_scale`). It keeps the window's size in
  layout units when the scale changes, and takes the size the compositor
  configures, such as a tiling compositor's tile;
- reports the mouse, the wheel (40 layout units a notch, a touchpad's
  distance as it is), keys through the compositor's keymap with their
  modifiers and evdev codes, typed text, and whether the window has
  focus;
- repeats a held key at the rate and after the delay the compositor
  gives (`wl_keyboard.repeat_info`), each repeat a `key_down` with
  `repeat` set and its text typed again; a modifier pressed meanwhile
  leaves it repeating;
- reports the environment the desktop gives over D-Bus: the theme, high
  contrast and reduced motion from the XDG desktop portal's settings
  (`org.freedesktop.appearance`), and power from UPower (on battery) and
  power-profiles-daemon (`power-saver` is the saver), each change as it
  is signalled. Without a session bus, a portal or either daemon, as in a
  container or under a bare compositor, those settings stay at zui's
  defaults, and `host.environmentSources()` says which answered;
- reports lifecycle events: SIGINT, SIGTERM and SIGHUP are
  `.terminate_requested`, after which the next poll reports the window
  closed, unless the application handles or ignores the signal itself (a
  second Ctrl+C ends the process); the system sleeping and waking
  (logind's `PrepareForSleep`) are `.suspend` and `.resume`;
- reports files dropped onto the window (`wl_data_device`, an offer of
  `text/uri-list` accepted for copying), each `file://` URI on this
  machine percent-decoded to its path, at the drop's position;
- closes when its close button or the compositor asks;
- sets the cursor a frame asks for, where the compositor offers
  `wp_cursor_shape_v1`;
- offers zui's host services over the session bus, the Windows host's
  shapes: `Host.zuiNotifications.show(host, request, notification,
  sink)`, a notification from the desktop's notification daemon
  (`org.freedesktop.Notifications`), one at a time and replaced by the
  next, answering `.notification_activated` when clicked and
  `.notification_dismissed` when it expires, is closed or is replaced;
  `Host.zuiFileDialogs.show(host, window, request, dialog, sink)`, the XDG
  desktop portal's open, save and folder dialogs (`FileChooser`), one at
  a time, answering `.files_chosen` with the paths chosen or `.canceled`;
  and `Host.zuiOpenUrl.open(host, url)`, which hands a URL to the
  portal's `OpenURI` and refuses paths and `file:` URLs. Each call only
  sends; the poll and the wait read the bus and publish every answer, a
  `zui.ServiceReply`, into a source of the application's. Without a
  session bus each call is `error.Unavailable`, and without a daemon or a
  portal the answer is `.failed = .unavailable`. There are no menus,
  which Wayland does not have;
- waits as `nextFrame` says: at once, until an instant, or until input,
  a key's repeat, a signal or a wake, which is sticky and works from any
  thread (an `eventfd`); the compositor's and the buses' other messages,
  such as a buffer released after each frame, do not end a wait;
- offers the clipboard as text, `Host.zuiClipboard.write(host, text)`
  and `read(host, request, sink)`, through the seat's selection: `write`
  offers up to 64 KiB of UTF-8 as `text/plain;charset=utf-8`,
  `UTF8_STRING` and `text/plain`, and `read` publishes a
  `zui.ServiceReply` once the selection's owner has written it, up to
  64 KiB with the rest counted as left out, `""` when the clipboard
  holds no text, or `.failed` after 2 s. Both directions go through
  pipes the host's wait reads and writes, so the host can paste its own
  text, and a reader that closes early does not raise SIGPIPE. The
  compositor names the selection only to the window with keyboard
  focus; until it names another, a read answers the last text written;
- watches up to four directories, each with its subdirectories, through
  `Host.zuiFileWatch.watch(host, directory, sink)`: one inotify
  descriptor, read in the host's wait, with a watch for each directory,
  added as subdirectories are created or moved in (up to 256 in all;
  past them, or past a path of 255 bytes, a `.rescan`), publishing each
  change, a `zui.FileChange`, into a source of the application's.

It links libwayland-client and libxkbcommon, and speaks D-Bus itself: a
client of its own, in `hosts/native/linux/dbus.zig`, reads the buses'
sockets into fixed buffers, beside the display in the same wait, so it
needs no libdbus and allocates nothing. `init` waits up to 250 ms for
the desktop's current settings, so the first frame has them. A window
opened with `visible = false` is a surface with no role, which the
compositor never shows. The services have a connection to the session
bus of their own, which reads nothing while no call waits for an
answer. Low memory, reduced transparency, the IME, a system material and
X11 are still to come.

It passes zui's host suite (`zui_testing.expectHostConforms`) against a
window the compositor never shows, whose harness delivers what a
compositor would to the host's own handlers; without a compositor to
connect to, the suite and the host's own tests are skipped with a
message. The services are answered there through the host's fake
(`Host.fakeServices`), so nothing shows. A test with
`ZUI_HOST_TEST_SHOWN_WINDOW` set shows a window for a moment, so the
compositor gives it focus, and reads text written to the clipboard back
through the compositor's own selection; without it, the clipboard's
pipes are tested with the host at both ends. The tests read no bus but
the ones named by `ZUI_HOST_TEST_SESSION_BUS`: set to a bus's address,
tests play the portal and the notification daemon on it, and check that
the settings, a notification's arguments and signals, a file chooser's
options and its answer (paths or a cancel), and `OpenURI` reach the host
or the played service, that another sender's signals do not, and that a
notification with no daemon fails without blocking.

```sh
dbus-daemon --session --nofork --address=unix:abstract=/zui-host-test --print-address
ZUI_HOST_TEST_SESSION_BUS=unix:abstract=/zui-host-test zig build test
```

#### Accessibility

A window opened with `WindowOptions.semantics` answers UI Automation's
`WM_GETOBJECT` with a fragment root, whose elements are the nodes of the
last `Frame.semantics()` the host was handed: each with its label as its
name, its role as a control type, its id in hex as its AutomationId, its
bounds in screen pixels and its place in the tree, and a heading with its
level. Each offers the pattern that stands for what it does: Toggle on a
checkbox, ExpandCollapse on a dropdown or disclosure, RangeValue on a
slider, Value on a text field or dropdown, SelectionItem on an option or
radio, Selection on a list, Scroll on a scroll container, Window on a
dialog, and Invoke on what is left that clicks.

A client's requests arrive in the next record as the actions that answer
them: Invoke, Toggle, Expand, Collapse and Select as `invoke`, answered
as a click; a range's SetValue as `adjust` by whole steps; a scroll by a
notch (a wheel step), a page or to a percentage as `scroll`;
ShowContextMenu as `show_menu`; a dialog's Close as `dismiss`; and
SetFocus as `focus`, answered as Tab would be. A text field's text is
read through its Value pattern and typed from the keyboard, since zui has
no action that replaces it. Focus, structure and property changes (name,
value, toggle, expand, selection, enabled, scroll position) are raised
only while a client listens, from the window thread.

The host copies each list into one of two snapshots it allocates in
`init`, so a list past that room is cut from the end and reported, and
nothing is allocated after `init`. Without room, the window is left to
Windows' default accessibility.

`zig build accessible` shows a heading, a button, a checkbox, a slider, a
text field, a dropdown and a scrolling log, from `zui_widgets` and zui,
for trying with Narrator or Accessibility Insights; `-- --frames 30`
draws 30 frames and quits. The sokol renderer's tour declares its
semantics too, so the tour on this host can be read the same way. The
host's tests read their windows through UI Automation's own client,
in-process, from a thread that owns no window: a window that was never
shown is exposed too.

#### The desktop through the window

`zig build material` shows a window whose root draws no background while
`ui.environment().system_material` is true, and the theme's background
otherwise: the same code shows Mica on Windows 11 and a solid background
on Windows 10. `-- --no-system-material` makes the host behave as on
Windows 10, `-- --transient` asks for Acrylic, and `-- --screenshot
file.bmp` saves what the screen shows. The renderer clears to transparent
and must keep its alpha: the sokol renderer does, with D3D11, through a
swapchain DirectComposition composes into the window; Windows ignores the
alpha of an OpenGL window, so with `-Dgl=true` the backdrop would be
added under every pixel.

#### HDR white

`zig build hdr` shows boxes of SDR white and of two and four times it, in
`zui.ExtendedColor`, with the output format and `hdr_headroom` the window
got. On a monitor in HDR the host opens it in `.scrgb_fp16` and the sokol
renderer draws into a half-float scRGB swapchain, so the brighter boxes
show brighter; elsewhere all three show as SDR white. `-- --measure`
reads the boxes back off the desktop in scRGB, where 1.0 is 80 nits,
through DXGI's desktop duplication, and fails if twice SDR white does not
show brighter than SDR white:

```
output scrgb_fp16, headroom 3.81; the desktop shows, in scRGB (1.0 is 80 nits):
  SDR white  3.500 3.500 3.500, 1.00x SDR white
  2x         7.000 7.000 7.000, 2.00x SDR white
  4x         14.000 14.000 14.000, 4.00x SDR white
```

#### A theme from a file

`zig build theme` draws a window in the colors of
`hosts/native/examples/theme.zon` and restyles it when the file changes,
on Windows and on Linux. The host's file watch publishes into a
`zui_async.Stream(zui.FileChange, ...)` among the application's sources;
declaration sees the theme's file among the changes, and the loader,
between frames, reads and parses it into a `zui_async.Latest` that the
next frame draws with. Declaration does no I/O, so a recorded session
restyles in replay as it did live.

```zig
try Host.zuiFileWatch.watch(host, "examples", .of(&app.sources.theme_files));
```

```sh
zig build theme                          # edit examples/theme.zon while it runs
zig build theme -- --theme my/theme.zon  # watch another file
zig build theme -- --check               # rewrite a theme file, wait for the restyled frame, quit
```

`--check` writes a dark theme into `zig-out/theme-check/theme.zon`,
opens the window, and once a frame draws it, writes a light one over it;
it fails unless a frame draws the light background within 10 s. On the
reference machine the restyled frame came 2 to 4 ms after the write, two
frames after the first, on Windows; on Linux under Hyprland at 60 Hz, it
came 18.7 ms after it, in the second frame.

#### Host services

`zig build services` has a button for each service, with its answer
beside it: pick a file, save a file, show a notification, open a popup
menu, set or clear the menu bar, copy, paste, and open
<https://ziglang.org>. It runs on both hosts; a service the host does not
offer says so beside its button. A right click anywhere opens the context
menu, and Ctrl+C, Ctrl+V, Ctrl+O and Ctrl+S do what the menus say.
Declaration only notes what was asked for, and the loader makes the calls
between frames through `zui_app.ServicesOf`, so every answer comes back
through one source, a `zui_async.Stream(zui.ServiceReply(16 * 1024), ...)`:

```zig
const services = zui_app.ServicesOf(zui_host.Host);

pub fn zuiLoader(app: *App, _: *const Ui, _: std.Io) void {
    if (services.has_file_dialogs and app.wants_file) {
        app.wants_file = false;
        services.file_dialogs.show(app.host, .main, .of("pick a file"), .{ .title = "Pick a file" }, .of(&app.sources.replies)) catch {};
    }
}
```

```sh
zig build services                 # interactive window
zig build services -- --check      # every service against the host's fake, in a hidden window, then quit
```

`--check` hides the window and answers every service through the host's
fake (`Host.fakeServices`), so nothing opens or shows. It presses each
button in turn, chooses an item from the menu bar as Windows would
report it, and fails unless each answer shows in a frame within 10 s.
It uses the real clipboard, and so replaces what it holds. A paste right
after a copy often finds the clipboard held by clipboard history, and is
answered `.failed = .unavailable`; the check presses Paste again, as a
user would. Setting a menu bar shrinks the window's content by the bar's
height. On Linux the check presses only the buttons of the services the
host offers, the file dialogs, the notification and the URL, and draws
nothing: a surface the compositor never shows gets no frame callbacks,
which a renderer's swap waits for.

#### A custom title bar

`zig build title-bar` draws its own title bar over Mica: a title, a
search field and minimize, maximize and close buttons. The application
marks each part with `Element.chrome`, behind `features.chrome_regions`,
and opens the window with `.title_bar = .custom`:

```zig
ui.open(.{ .id = .of("title bar"), .chrome = .title_bar, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(32) } } });
defer ui.close();
_ = widgets.textField(ui, .of("search"), &app.search, .{ .label = "Search" }); // interactive, so it stays the application's
if (captionButton(ui, .of("close"), .close_button, "Close")) app.host.close(); // the keyboard's or Narrator's click
```

The window keeps the system's frame on the left, right and bottom, so DWM
draws its border, rounded corners and shadow, and only the caption goes.
`WM_NCHITTEST` is answered from the system's borders first, then a resize
band the host keeps along the top, then the frame's regions, the last on
top: a title bar is `HTCAPTION`, so Windows drags the window, maximizes it
on a double click, opens the system menu on a right click and snaps it
with Win+arrows; the maximize button is `HTMAXBUTTON`, so hovering it
shows snap layouts; resize edges and grips are the `HT` code of their
edge; and the interactive elements inside the title bar stay
`HTCLIENT`. The host keeps a copy of up to 256 regions, in pixels, under a
lock the window thread takes shared.

Over the caption buttons the pointer still reaches zui, so they show
hover and press. The host works them itself when a press and its release
land on the same button, as Windows' own buttons, and ends the press with
`pointer_cancel` rather than a release, so zui reports no click. An
application acts on `clicked` only for the keyboard and Narrator, through
`Host.minimize`, `Host.toggleMaximized` and `Host.close`, so each button
is worked once. Maximized, the content starts below the edge of the
monitor.

```sh
zig build title-bar                          # interactive window
zig build title-bar -- --no-system-material  # the solid background Windows 10 shows
zig build title-bar -- --check               # hit-test each part in a hidden window, then quit
```

`--check` hides the window, draws it twice, sends `WM_NCHITTEST` at each
part as laid out, and exits 0 only when the title is `HTCAPTION`, the
search field and the content `HTCLIENT`, and the buttons `HTMINBUTTON`,
`HTMAXBUTTON` and `HTCLOSE`.

#### Many windows

`zig build many-windows` runs one application in two windows through
`zui_app`: each declares its own UI in a context of its own and counts
its own clicks, and a count shared by both is published into each
window's `zui_async.Latest(u32)`. Any window opens another or closes
itself, and the run ends with the last. The sokol renderer draws each
through its own swapchain on one device.

```sh
zig build many-windows                         # interactive windows
zig build many-windows -- --check              # open, click and close hidden windows, then quit
zig build many-windows -- --measure-idle       # CPU time of two idle windows over 10 s
zig build many-windows -- --measure-animation  # frame rates of one, then two, windows animating
```

`--check` opens a hidden second window, clicks its buttons through the
host, and exits 0 only when the second counts its own click, both show
the shared count, the first counted none, and the first draws on after
the second closes. On a 144 Hz monitor, two windows animating at once
each hold 143 frames a second, as one alone holds 144, and two idle
windows use no CPU.

#### The tour on a native host

`zig build tour` runs the sokol renderer's tour on this host, drawn by
the sokol renderer, which draws into a `win32` window through sokol_gfx
with D3D11, or into a `wayland` surface with OpenGL through EGL, without
sokol_app. The tour's application is the sokol renderer's own (its
`zui_sokol_tour` module), unchanged, and `zui_app.run` runs it:
`hosts/native/examples/tour.zig` names this host, the sokol renderer and
the tour's text contract (`pub const Text = zui_sokol.Text`, since that
renderer does not measure), and passes each step to the tour.

```sh
zig build tour                               # interactive window
zig build tour -- --screen box_storm         # start on one screen
zig build tour -- --frames 300 --cycle 30    # visit every screen, 30 frames each, then quit
zig build tour -- --measure-idle             # report the CPU time used over 10 idle seconds
zig build tour -- --screenshot tour.bmp      # save the window after a few frames, then quit
```

Idle, it uses no CPU: on an i9-10900K in ReleaseSafe, the Layout Lab
screen used 0.0 ms of CPU over 10 s with no frames and no wakes in three
runs of four (Windows counts CPU time in 15.6 ms ticks). On Linux, under
Hyprland with an NVIDIA RTX 2060 SUPER, it used 1.2 to 4.4 ms over 10 s,
with 0 or 1 frames and no wakes, in five runs of six. `--screenshot` saves
the window on Windows only so far.

#### The tour in another process

`zig build remote` runs the same tour in a second process, on
`zui_wire`'s host and renderer, and draws it here: a `zui_wire.Client`
joins this host and the sokol renderer to it over a loopback TCP
connection, sending this window's input and drawing the frames that come
back, each written as the changes from the one before. Closing the window
ends the tour's process.

```sh
zig build remote                         # the tour runs in a second process; this one draws it
zig build remote -- --check tour.bmp     # press Ctrl+2, Ctrl+4, Ctrl+9, wait for each screen, save, quit
zig build remote -- --serve 7420         # only the tour, waiting for a viewer on port 7420
zig build remote -- --connect 7420       # only the viewer, joining a tour served on port 7420
```

`--check` fails if a screen does not come back within 20 s, and when the
tour's process does not exit with 0. On the reference machine it takes
under a second: the first frame arrives about 3 ms after connecting.

## License

MIT; see [LICENSE](LICENSE).

The zui logo is adapted from the [Zig logo](https://codeberg.org/ziglang/logo)
and, like it, is licensed under CC BY-SA 4.0; see
[assets/LICENSE.md](assets/LICENSE.md). zui is not affiliated with or endorsed
by the Zig Software Foundation.

The raylib renderer's tour uses fonts under the SIL Open Font License
1.1: Atkinson Hyperlegible, copyright 2020 Braille Institute of America,
Inc. (see
[renderers/raylib/examples/fonts/OFL.txt](renderers/raylib/examples/fonts/OFL.txt)),
and Liberation Mono, copyright 2010 Google Corporation and 2012 Red Hat,
Inc. (see
[renderers/raylib/examples/fonts/LiberationMono-LICENSE.txt](renderers/raylib/examples/fonts/LiberationMono-LICENSE.txt)).
The sokol renderer's tour uses Atkinson Hyperlegible too (see
[renderers/sokol/examples/fonts/OFL.txt](renderers/sokol/examples/fonts/OFL.txt)).

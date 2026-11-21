# Roadmap

SPEC.md is the contract, and its §21 orders the work into stages by what
depends on what. This file is how each stage is built and judged: its
items, what is known about each, and what decides that it is done.
ARCHITECTURE.md maps where each part lives.

Each item says:
- **Grounding:** what we know, with the code that shows it.
- **Plan:** what to change.
- **Done when:** the test or measurement that decides it.
- **Spec:** the sections it implements.

## Where we are

| Release | Scope | Status |
|---|---|---|
| 0.1 | layout core, text wrapping, measurement cache, render commands | shipped |
| 0.2 | input, focus, clipping, scrolling, floating, state | shipped |
| 0.3 | task pools, `needsFrame`, frames held by a render thread | shipped; task pools are deleted in stage 2 |
| 0.4 | `zui_widgets`, `zui_reflect`, `zui_testing` | shipped |
| 0.5 | layout performance, parallel measurement, benchmarks | shipped |
| after 0.5 | declaration work: −42% to −56% | on `main` |
| 0.6, in part | `bench-compare` (R2), startup benchmarks (P1), task completions at `beginFrame` (A2), the async design (A1) | done; the rest of 0.6 became stage 1 |
| stage 1 | instruction counts in CI (R1), the tracer contract and `zui_tracy` (P2) | done |
| stage 2 | the code brought to the spec's shape: C5, S1, I4, C6, A5 and `nextFrame` (I2); letter spacing (T3); the environment and host requests (I6); sources in the core (A3); `zui_async` (A4); the backends on the new API, the demo's thumbnails on `KeyedLoads` (C8) | done; the demo idles at 0% CPU |
| stage 3 | the renderer contract and the generated commands (C1); the host contract and `RecordBuilder` (C2); the conformance suites (C3); `Features` (C7); `zui_app` (C4); the raylib adapter host (H1) | done; the backends are renderers and pass the renderer suite in CI, raylib's host passes the host suite, and the demo runs through `zui_app`, presenting its first frame 288 ms after the process starts; lowering comes with stage 8's commands |
| stage 4 | the Windows host (H2), with dropped files and lifecycle events in the record; the system material (H8); `zui_app` with the application's own text contract (C9) | done; the sokol renderer's tour runs on it unchanged, through `zui_app`, and idles at 0% CPU, and the same code shows Mica or a solid background |
| stage 5 | relay (F2); `zui_wire` (F3); replay in `zui_testing` (F4); the wire host, renderer and client (F5); file watching as a source (F6) | done; editing a theme file restyles a running window on the Windows host within 4 ms; a recorded session of the sokol renderer's tour replays to identical commands without starting any work, the sokol renderer's tour goes over the wire at a hundredth of its frames' whole size, but for the screen that moves every box, and it runs in one process and draws in another on the Windows host, its keys going back |
| stage 6 | the single-line fast path (T1), the whole-string cache (T2), static styles (L8), the box tree's layout and emission (P4) and declaration (P5), line-break segmentation (T4), the grow basis (L1), aspect ratio and natural sizes (L2), dividers and decorated images (L3), floating options (L4), right-to-left layout (L6), wrap (L7); the backends drawing images' tint and corner radius (C10) | done; the box tree's and warm text's budgets met, as they were then judged with Turbo Boost on: the box tree declares in 48.9 µs and lays out and emits in 89.2 µs, warm text in 90.5 µs; a box tree of static styles declares in 28.0 µs; the raylib and sokol renderers draw tinted, rounded images and pass the renderer suite that checks them |
| stage 7 | gestures (I5): arbitration by motion component, zoom, long press, double tap, momentum, the intents and custom recognizers; drag and drop between elements (I1) | done: a carousel in a list, a pinch starting on a list inside a map, a lasso module against a map's pan, and `zui_testing.Driver.drag` moving an item between two lists, out of one that scrolls by dragging |
| after stage 7: the foundation | G1's first slice ran 5.5% to 7.7% more instructions in scenes that draw no effect, so the work turned to what lay under it: benchmarks that can be trusted (R3 to R9) and the data-oriented design audit's findings (P6 to P10) | done; a commit compared with itself over three code layouts calls nothing, its intervals 0.52% wide on average, and a change that only moves code is not called; a tooltip declared before a 3,000-cell grid lays out in 79 µs, not 671 µs (P6); warm text −43% (P9); `init` from 138 µs to 92 µs (P7, P10); the budgets judged in benchmarking mode |
| stage 8 | gradients, shadows and glow (G1); backdrop blur (G2); effects in the corners of a decoration that draws nothing (G7); transforms with hit inversion (G3); materials (G5); HDR and wide gamut (G6) | done: the sokol renderer draws gradients, shadows, backdrop blurs, transforms and materials through a shader of its own and passes the renderer suite, its effects rounded by a decoration that draws nothing, a pointer hits a turned button where it is drawn, and a frame without effects runs no more instructions than before; `zui.ExtendedColor` is clamped for a renderer that draws only `Color`, and on a monitor in HDR the Windows host opens the window in scRGB and reports its headroom, and the sokol renderer shows twice SDR white at 2.00× and four times it at 4.00×, measured off the desktop |
| stage 9 | `zui_debug` (V1); semantics and accessibility actions (V2); safety sweeps (V3); the demo in a browser (V4) | done. V2: every `zui_widgets` control lists its semantics, and the Windows host bridges them to UI Automation with each control's pattern, its state and changes, and every action, so a client out of process toggles, sets, expands, selects, scrolls and invokes the native hosts' accessibility example; V4: the sokol renderer's tour runs in a browser at the display's frame rate, from the published page, in a Web Worker behind a page that draws its frames over `zui_wire` and sleeps between the frames the tour needs; V1 done: `Frame.inspect` and the inspector's diagnostics, fallbacks, zone times from its `ZoneTimer` tracer, element tree and hovered element's configs, and its theme reloaded from a watched file; the raylib renderer's tour opens it with F12 through `zui_app`'s `zuiObserve`, and draws every screen with it open within its limits |

No release is tagged; everything is on `main`. From here, work is
tracked by stage rather than by release number. Each stage may be tagged
when it is done.

Measured on the reference machine (i9-10900K) in benchmarking mode
(Turbo Boost off, 3.7 GHz, the `performance` governor), the fastest frame
at `9154f3f`, after the audit's P6 to P10, against the budgets of SPEC.md
§20.2:

| Scenario | Declaration | `endFrame` | Budget |
|---|---|---|---|
| 4,096 boxes, depth 8 | 57.3 µs | 108.6 µs | layout and emission < 125 µs, declaration < 69 µs: both met |
| 1,000 texts, warm caches | 17.7 µs | 66.5 µs | < 150 µs: met |
| 4,096 boxes of static styles | 28.5 µs | 104.4 µs | |
| 4,000 children of one parent | 56.3 µs | 77.1 µs | |

These are the fastest of six runs (five for the last two rows) of
`zui-bench --core 3`, whose fastest box-tree frames were 57.3 to 58.1 µs
for declaration and 108.6 to 109.0 µs for layout and emission, and warm
text's 66.5 to 67.4 µs. Until `9154f3f` the budgets were 100 µs, 55 µs
and 120 µs and were judged with Turbo Boost on, where the box tree had
measured 48.9 µs and 89.2 µs after P5. The owner moved them to the mode
`bench-compare` measures in, which is steadier (turbo-on runs had drifted
by 10% on the same instructions), scaling each by 1.25, the box tree's own
ratio of turbo-off to turbo-on time.

## The queue

Work is taken from the top. The first row whose status is not
`waiting` is the next item, and CLAUDE.md says how to take it on. An item
too large for one sitting lands in slices, each a commit with every check
green, and its **Status** line below says which slice is next.

| Item | Stage | Where | Waits for | Status |
|---|---|---|---|---|
| H4. Linux | 10 | `hosts/native/`, `renderers/sokol/` | | in progress; slice 5, the IME, is next |
| H10. Hosts whose platform owns the loop | 10 | `core/zui_app/`, `core/src/contracts.zig`, `renderers/raylib/`, `hosts/web/`, `core/zui_testing/` | | in progress; slice 2, the split contract, is next |
| H5. Web | 10 | `hosts/web/`, `renderers/webgl/` | H10 | |
| H7. Window decorations | 10 | `core/src/chrome.zig`, `core/src/context.zig`, `core/zui_app/`, `hosts/native/` | | waiting on a person: the checklist under H7's *Status*, on `zig build title-bar` in `hosts/native/` |
| M1. `zui_motion` | 11 | `core/zui_motion/` | | |
| M2. Exit animations | 11 | `core/src/`, `core/zui_motion/` | M1 | |
| K1. `zui_color` | 11 | `core/zui_color/` | | |
| K5. The skin contract | 11 | `core/zui_widgets/` | | |
| K2. The default skin | 11 | `core/zui_widgets/` | K5, K1 | |
| E1. Text editing | 11 | `core/src/`, `core/zui_widgets/`, `hosts/native/` | K5 | |
| K3. `zui_icons` | 11 | `core/zui_icons/` | | |
| K4. `zui_themes` | 11 | `themes/` | K5, K2 | |
| D1. The template project | 11 | `examples/` | | |
| D2. Samples | 11 | `examples/` | D1 | |
| D4. A profiling guide | 11 | `docs/` | | |
| D3. A developer-experience audit | 11 | `examples/`, `README.md`, `docs/` | D1, D2 | |

After stage 10's rows come stage 11's, which has joined the queue in dependency order. Stage 10's items are listed under *Stage 10: reach* and stage 11's under *Stage 11: polish*; each is given its Grounding, Plan and Done when as it is taken.

The font system is planned under *The font system*, after stage 11. It
has no rows yet; its items join the queue when the owner orders them.

macOS is not in the queue. Its work is set aside under *macOS, for
later* at the end of this file, and none of it is built until the owner
chooses to take up macOS. Until then, a progress report leaves it out.

Statuses: `next` (the first open row), `in progress` (a slice has
landed), `waiting on <what>` (blocked by something the next session cannot
do: a decision, CI, a push), or empty (not started). A finished item's
row is removed, and the item moves to *Done*. An item whose remaining
work is waiting on CI or a person counts as done for the rows that wait
for it, as long as what they need from it has landed.

Things to know:
- **Judge each item against its parent commit,** in benchmarking mode:
  `zig build bench-compare -- HEAD --require-quiet` compares the working
  tree with the last commit. A base from before `4294abe` (R5) is
  compared one whole run at a time, and one from before `c24f34b` (R7) in
  a single code layout, which where the code lands can move by several
  percent, so older bases such as `a6d8e34` are history, not a judge.
- **Measure one thing at a time.** Compile nothing while a measurement
  runs. `bench-compare` writes its progress to stderr, which `zig build`
  drops once the step succeeds; the report says which mode ran. The
  noise bands live in `.zig-cache/bench-compare/noise-floor.json`, keyed
  by the machine's fingerprint; `--calibrate` again after changing the
  setup.
- **The spec is already written.** Every item implements sections of
  SPEC.md that exist; an item that finds the spec wrong changes it in the
  same commit, with the reason.
- **The code has the spec's shape where the feature exists.** What is
  still missing is listed in ARCHITECTURE.md §7 with the item that adds
  it. With `TaskPool` deleted, outside data reaches a frame only through
  sources: `zui_async`'s (A4) or the application's own (A3).
- **A core change reaches every renderer and host at once.** Every
  package names `core/` by path, and `zig build test-all` tests them all
  with the change; the raylib renderer's tour, run from
  `renderers/raylib/`, checks the idle budget with `--measure-idle` and
  the trace with `-Dzui-tracy=true`, and the web host's checks, run from
  `hosts/web/`, draw and run the tour in a browser.
- **`bench --check-targets` checks §20.2's budgets,** including
  declaration for the box tree, judged in benchmarking mode (Turbo Boost
  off, the `performance` governor), the mode `bench-compare` measures in.
  Times vary by machine; instruction counts (`zig build counts`, R1) do
  not, and CI fails on more than 2% growth over the parent commit; the
  simulated misses beside them (R8) show direction and never fail. They
  need Valgrind, so on Windows take them in a Linux container.
- **Item IDs are stable.** A letter names a series (R measurement and
  regression checks, A async, P profiling, C contracts, T text, S scale,
  H hosts, F the frame record and the wire, L layout, I interaction, G
  graphics, V visibility, M motion, E editing, K modules, D developer
  experience). A new item takes the next number in its series, and
  numbers are never reused, so a gap is an item that was merged or
  retired.

## How stages ship

- **Measure first.** Stage 1 gave every later change an instruction
  count no machine can move. Its times did not hold: unpinned, judged by
  a hand-set 2%, and in one code layout, they could not tell a change of
  a few percent from where the code landed. R3 to R8 made them
  trustworthy before the audit's work was judged by them.
- **Fix the foundation before building on it.** When an item's counts or
  budgets fail because of the code under it rather than its own, that
  code is profiled and fixed first, as items of their own. G1 is why the
  audit's findings went ahead of stage 8.
- **One breaking change, made once.** Stage 2 changes the shape of
  `Context`, the frame record, input and outside data together, and
  stage 3 adds the contracts on top, before any native host or wire
  format can freeze the old shapes. Every backend, `zui_testing` and
  `core/bench/` are updated in the same week, and the notes say what to
  change.
- **Prove each contract twice.** An adapter proves it in stage 3; a
  native host proves it again in stage 4, because a contract with one
  implementation is not yet a contract.
- **After stage 3, new commands never break renderers.** Optional
  commands are lowered by the core for renderers that do not declare
  them, which is why effects can come in stage 8.
- **A module before core.** A feature that can be built on the public API
  is; the core gains only what a module proves it cannot do without.
- **Items may land early** once their prerequisites have. T1 and T2, for
  example, need only stage 1.
- **A speedup ships with its measurement,** and one that is not measured
  does not ship.

---

## Done

### H9. Many windows

**Grounding.** Where the code stood when H9 was taken (`daba4a7`, with
`hosts/native/` at `dbbef70` and `renderers/sokol/` at `d66de6c`):
- *The core.* A window is a `zui.WindowId` (`core/src/host.zig:5-8`), and a host
  says how many it opens in `HostCapabilities.windows`, default `.one`
  (`:14-24`). `zuiPoll`, `zuiSurface` and `zuiApply` already take a
  `WindowId`; `zuiWaker` and `zuiWait` take none, so one wake and one wait
  serve the whole host (`core/src/contracts.zig:117-121`). No host call opened
  or closed a window, and nothing told a renderer that a surface went
  away.
- *Contexts and sources.* SPEC.md §15.4 already settled the shape:
  contexts share nothing, each has its own sources, and data shared
  between windows is published into each. A source has one reader
  (§14.8). `nextFrame(sources)` is `.immediately` when a source with
  `zuiPending` holds something (`core/src/context.zig`'s `nextFrameWithSources`),
  and every `zui_async` source declares `zuiPending`.
- *`zui_app`.* `Runner` hard-coded `const window: zui.WindowId = .main`
  (`core/zui_app/zui_app.zig:324`) and owned one `Ui`, one `RecordBuilder` and
  one render-thread queue (`:327-345`). `frame` polled, declared, handed
  the frame to the host and the renderer, and waited on that one
  context's `nextFrame` (`:442-477`). `checkApp` accepted only
  `zuiDeclare(app, ui)` (`:592-600`).
- *The Windows host* is `.one` (`hosts/native/windows/host.zig:43`). It holds
  one `hwnd`, one `Inbox`, one `requests`, one `WindowThreadState`, one
  chrome snapshot, one accessibility bridge and one set of service state
  (`:191-220`), and asserts `.main` in every call that takes a window
  (`:122`, `:144`, `:157`, `:395`, `:489-518`). Its waits are already
  host-wide. The window procedure finds the host through `GWLP_USERDATA`
  (`:619`, `:671`), and `WM_DESTROY` ends the window thread (`:695`).
- *The sokol renderer* draws a `.win32` surface through one `native.Context`
  (`renderers/sokol/src/renderer.zig:92`), made in `initForSurface`, which also
  runs `sg.setup` on its device (`:139-146`). sokol_gfx is process-wide, so
  a second window needs a second swapchain on the same device, not a
  second renderer. `zuiSubmit` uses the one context for any `.win32`
  surface (`:184`, `:221`). The scRGB and backdrop-blur targets are made
  again whenever the size changes (`renderers/sokol/src/destination.zig`'s
  `prepare`, `renderers/sokol/src/backdrop_blur.zig`'s `prepare`).

**Plan.** An application opens a window through `zui_app`, between
frames, never in declaration. `zui_app` gives each window a context of
its own, made with `gpa` when the window opens, and the application
declares each window with `zuiDeclare(app, ui, window)`. Sources stay one
per context: the application returns each window's from
`zuiSources(app, window)`. One `zuiWait` covers every window: it waits for
the earliest of the contexts' `nextFrame`, and after it only the windows
that are due run a frame. The renderer stays one, with per-surface state
it attaches when a window opens and detaches before it closes. The
one-window form is untouched. In three slices:
1. **The contract and `zui_app`** (core only): `zui.OpenWindowError`;
   `zuiOpenWindow` and `zuiCloseWindow`, required with `.many` and refused
   with `.one`; `zuiAttachSurface` and `zuiDetachSurface`, declared
   together; `zui_app`'s windowed form, `Windows(App)`, `max_windows`;
   the host suite's many-windows steps; the compile-error cases.
2. **The Windows host opens many windows** (`hosts/native/`): a slot per window,
   `max_windows = 4`, each with its id, `hwnd`, inbox, requests, window
   thread state, chrome snapshot, accessibility bridge and per-window
   service state (the menu bar); a message-only window that anchors the
   window thread and owns the clipboard, so `.main` closes like any
   other; ids never reused; the console's terminate and low memory to
   every window; hosts in the conformance tests off the stack; the
   harness's `postTo`.
3. **Two windows drawn by the sokol renderer** (`renderers/sokol/`, then
   `hosts/native/`): one
   D3D11 device shared by a composition swapchain per window, found by
   `hwnd`, each with its own scRGB and backdrop-blur targets;
   `zuiAttachSurface` and `zuiDetachSurface`; the native hosts'
   `examples/many_windows.zig`, with `--check` and `--measure-idle`.

**When a window is due.** After the wait, each open window is polled and
given to `zuiRecord`. It is declared only when its record has an event,
its viewport, scale, zoom or output format changed, its `nextFrame` asked
again is `.immediately` or an instant that has passed, or it has not had
a frame. When a source of `Ui.Sources` lacks `zuiPending`, a wake cannot
be told apart, so every window is due on every turn.

**Done when.**
- `zui_app`'s tests, with a host of many windows: input reaches only its
  window; a window the user closes is closed and the others go on; the
  wait is the earliest `nextFrame`; a publish makes only its own window
  due; a render thread runs every window's frames, attaches and
  detaches; opening past the host's or `zui_app`'s limit is refused; a
  one-window application runs as before on a host with many.
- The host suite's many-windows steps pass on a host that keeps windows
  apart, and fail on one that reports every event in the first or reuses
  a closed window's id.
- `hosts/native/`'s `zig build test`: the suite passes on the Windows host, now
  `.many`, against hidden windows; `WM_CLOSE` closes one window; a DPI
  change moves one window's scale; Ctrl+C reaches every window; a fifth
  window is refused; the clipboard works after `.main` closes.
- `zig build many-windows -- --check` draws two windows, a click changes
  only its window, and the first draws on after the second closes.
- By a person: on `zig build many-windows`, each window's counter moves
  alone and the shared one in both; closing one leaves the other running;
  two windows idle at 0% CPU; two animating windows both hold the
  display's rate.
- Unchanged: the native hosts' tour, the raylib renderer's `zig build check`, and R1.

**Spec.** §6.1, §6.8, §15.4, §16.2, §16.3, §16.6, §19.4, §19.5.

**Status.** Slice 1, the contract and `zui_app`, is done:
- `zui.OpenWindowError` (`TooManyWindows`, `WindowNotCreated`).
  `checkHost` requires `zuiOpenWindow(options) OpenWindowError!WindowId`
  and `zuiCloseWindow(window)` of a host whose `zui_capabilities.windows`
  is `.many`, and refuses them on `.one`. `checkRenderer` checks
  `zuiAttachSurface(surface) !void` and `zuiDetachSurface(surface)`, and
  that they come together.
- `zui_app`'s windowed form: `zuiDeclare(app, ui, window)`, each hook with
  the window, `zuiSources(app, window)` in place of the `sources` field,
  and an optional `zuiWindowClosed(app, window)`. `Start(App).windows`, a
  `Windows(App)`, opens and closes windows; `open` on a host with one
  window is a compile error unless guarded by `has_many_windows`, and
  opening one during `zuiDeclare` panics. `max_windows` is 8.
- Each window is a heap `Window` holding its context and its record
  builder, made when it opens. The render thread's queue carries frames
  tagged with their context, and attaches and detaches that the UI thread
  waits for, so the renderer is used by one thread at a time and a
  closed window's frames are released before its context is freed.
- The one-window form keeps its fields and its path: a frame every turn.
- `expectHostConforms` opens a second window on a host with many, posts
  to each through the harness's `postTo`, closes it, and opens a third.
- R1, measured by CI's counts job on `ea5ab47`: every scenario's count is
  identical to `6b6ce6f`'s run, its code parent (`daba4a7` changed only
  documents). `core/src/` gains an error set and comptime checks only, and the
  `zui-counts` executable's `.text` (1,171,081 bytes) and `.rodata`
  (145,243 bytes) are byte-identical to `daba4a7`'s.

Slice 2, the Windows host (`bf64f7c`), is done:
- The host is `.many`, with `Host.max_windows = 4` slots. Each slot holds
  the window's `HWND`, inbox, requests, scale, terminate and low-memory
  state, window-thread state, chrome snapshot, accessibility bridge and
  menu bar (`services.MenuBar`). Every call that takes a window finds its
  slot by id; the `.main` asserts are gone, and ids are never reused.
- `zuiOpenWindow` creates a window on the window thread before it
  returns. `zuiCloseWindow` closes any window, `.main` included, once a
  dialog or menu open over it has closed, and the window thread frees the
  slot at `WM_NCDESTROY`.
- A message-only window anchors the window thread. It opens and closes
  the windows, owns the clipboard and the notification icon, and answers
  clipboard reads, URLs and notifications, so every service works after
  `.main` closes. File dialogs and popup menus are owned by the window
  named and answer with its id. The console's terminate and low memory
  reach every window.
- The conformance harness declares `postTo`, so the host suite opens a
  second hidden window, routes input to each and closes it. The host's
  own tests close one window alone, change one window's DPI, deliver
  Ctrl+C to every window, refuse a fifth window and give a new id after
  one closes, and use the clipboard and a dialog over a second window
  after `.main` has closed.
- `zig build test` passes in Debug and ReleaseSafe, `zig build
  conformance` passed 12 runs of 12 with fresh seeds, `services` and
  `title-bar -- --check` pass, and the tour idles at 0.0 ms of CPU over
  10 s.

Slice 3, the sokol renderer drawing many windows (`9ad703d`) and the
example (`c19a504`), is done:
- `zuiAttachSurface` makes a composition swapchain for each `.win32`
  window after the first, on the first one's Direct3D 11 device, and
  `zuiDetachSurface` frees it. `composition.c` takes the device to share
  and holds a reference to it, and the renderer keeps one of its own from
  `initForSurface` to `deinit`, so the first window can close while the
  others draw on.
- Each attached window has its own scRGB offscreen and backdrop-blur
  targets, swapped in for its frames, so windows of two sizes do not
  remake them every frame. With `-Dgl=true`, and on Wayland until H4,
  attaching returns `error.UnsupportedSurface`.
- `zig build many-windows` runs one `zui_app` application in two windows.
  Each window declares its own UI and counts its own clicks, and a count
  shared by both is published into each window's `Latest(u32)`. Any
  window opens another or closes itself.
- `-- --check` opens a hidden second window and clicks its buttons
  through the host. It exits 0 only when the second window counted its
  click, both show the shared count, the first counted none, and the
  first drew on after the second closed.
- **The present-wait risk, measured** on this machine's 144 Hz monitor
  with `-- --measure-animation`: one window animating alone draws 144.0
  frames a second, and two at once draw 143.3 and 143.0, in two runs of
  two. Presenting each window with a sync interval of 1 does not halve
  the rate, so nothing was changed for it.
- `-- --measure-idle` with two windows open: 0.0 ms of CPU over 10 s,
  with no frames.

Measured across the item:
- R1: unchanged. CI's counts on `ea5ab47` are identical to `6b6ce6f`'s
  scenario by scenario, and slices 2 and 3 do not touch zui.
- Idle: 0.0 ms of CPU over 10 s for two windows, and for the sokol
  renderer's tour, which runs on the host unchanged.
- Animation: 144 Hz for one window, and 143 Hz for each of two.
- The native hosts' 77 tests pass in Debug and ReleaseSafe. `zig build
  conformance` passed 12 runs of 12 with fresh seeds.
- `services`, `title-bar`, `theme`, `remote` and `many-windows` pass
  `--check`.

What remains, and where it went:
- **Seen by a person, owed:** `zig build many-windows` on the desktop.
  Open a third window from either. Click in each and see only its own
  count move, while the shared count moves in all. Drag each window and
  resize it while the other draws. Move one to a monitor at another
  scale. Close the first window and see the others run on, then close
  the last and see the process end.
- **H4, and H3 once macOS is taken up:** Linux and macOS implement the
  same contract, and their hosts stay `.one` until then. The sokol renderer's EGL
  path would attach a `wl_egl_window` and `EGLSurface` per window on one
  `EGLContext`.
- **`zui_wire`:** a connection carries one window. Many windows over the
  wire would take a connection per window, and is not queued.
- **Docking and tear-off panels** (*Later*) can now build on it.

### H6. Services

**Grounding** (at `62d0813`, with `hosts/native/` at `0dd3be1`, before the
first slice). The host contract listed six optional services by name
(`core/src/contracts.zig:23`), and `checkHost` only checked that each was a type
(`:100-102`). Only `zuiFileWatch` had a checked shape (`checkFileWatch`,
`:143`), pinned by `host_file_watch_wrong_signature`. The pattern it set
(F6) is a sink: `zui.FileChangeSink`, a pointer and a function, made by
`.of(&source)` from any source whose `publish` returns `Wake` or
`error{Full}!Wake` (`core/src/host.zig`). SPEC.md showed the other five only as
`struct { ... }` (§16.3) and said they are reached through `zui_app` with
`has_*` guards (§16.6), but nothing declared a guard. `zui_app` named the
services (`core/zui_app/zui_app.zig:177`) only to report the missing ones
(`:375`); an application reaches its host only through `Start(App).host`
(`:198`), and `zuiLoader` gets the context and the `Io`, not the host
(`:552`). `zui_app`'s test host declared `zuiClipboard = struct {}`
(`core/zui_app/tests.zig:15`).

The frame boundary had no channel for a service: `HostRequests` holds the
cursor and the IME area, diffed as state by `zuiApply`, and a new kind of
event would need a variant, storage in the context and a limit, as dropped
files have. V2 found that even a zero-size field added to `Frame` moved R1
counts. `zui_wire`'s host declares no services. A `zui_async.Stream` with
one producer panics in safe builds when two publish at once.

On Windows only the clipboard existed, unchecked
(`hosts/native/windows/host.zig:40`): `read(host, buffer) ?[]u8` copied
`CF_UNICODETEXT` on the caller's thread (`:860`), and `write(host, text)`
returned `error{InvalidUtf8, ClipboardUnavailable, OutOfMemory}` (`:873`),
where `OutOfMemory` was `GlobalAlloc` failing (`:875`): the OS's memory,
handed to the clipboard, so not the host's allocation, but named as if it
were. A synchronous read is Windows' alone: on Wayland the selection is
read from a pipe the copying client writes into (H4 slice 3), and in a
browser `navigator.clipboard.readText` is a promise (H5). The window
thread runs the message loop in a single-threaded apartment (`:387-389`),
dispatches everything through `handleMessage` (`:467`), and takes work
from the UI thread as `WM_APP` messages (`:93`). A modal loop on it, such
as a move or resize, keeps dispatching the window's messages. Test-only
settings are fields set before `init` (`:62`), and the harness sends what
the OS would (`hosts/native/windows/conformance.zig:43`).

**Plan.** Five slices; the first fixes every shape at once, so H3 and H4
build on one reviewed contract.

1. **The shapes, checked; the clipboard and URLs on Windows.** Core: the
   vocabulary in `core/src/services.zig`; `checkHost` checks every service's
   functions, with a compile-error case for each function, one for a
   service that is not a struct and one for `ServiceSink.of`;
   `zui_app.ServicesOf(Host)`, its `has_*` guards and the unguarded-call
   error; `core/tests/instantiate.zig` declares a host with all five;
   `zui_testing`'s host suite checks the services a host declares.
   `hosts/native/`: the clipboard moves to the new shape and `zuiOpenUrl` is
   added, both answered from the window thread (`windows/services.zig`).
2. **Notifications** (`hosts/native/`): `Shell_NotifyIconW` with `NIF_INFO` and
   `NOTIFYICON_VERSION_4`, the icon added on the first `show` and removed
   when the balloon ends or at `deinit`; `NIN_BALLOONUSERCLICK` answers
   `.notification_activated`, `NIN_BALLOONTIMEOUT` and `NIN_BALLOONHIDE`
   `.notification_dismissed`, as does a notification replaced by the next.
   The fake records `NIM_ADD` and `NIM_MODIFY`, and the tests send the
   callback messages Windows would.
3. **File dialogs** (`hosts/native/`): `IFileOpenDialog` and `IFileSaveDialog`
   created and shown on the window thread, owned by the window; `show`
   copies the dialog's strings into a fixed buffer, posts it and returns;
   the dialog's modal loop keeps dispatching the window's messages, and
   its paths (`SIGDN_FILESYSPATH`) or `.canceled` are published. One
   dialog or menu at a time. The vtables go in `windows/file_dialog.zig`;
   the fake builds and configures the real dialog and reads `GetOptions`
   back without `Show`.
4. **Menus** (`hosts/native/`): `popup` builds a menu with `CreatePopupMenu` and
   `AppendMenuW` on the window thread, converts the position to screen
   pixels, and shows it with `TrackPopupMenuEx(TPM_RETURNCMD)`; `setBar`
   builds one with `CreateMenu` and answers each `WM_COMMAND`. Items are
   numbered by the host (`WM_COMMAND` carries 16 bits) and mapped back.
   A menu bar's `HMENU` lives in one struct of per-window service state,
   for H9 to move into its window slots; with H7's custom title bar,
   `setBar` may answer `error.Unavailable`.
5. **The example, and closing H6** (`hosts/native/` and core):
   `examples/services.zig` and `zig build services` on `zui_app`, with a
   menu bar, a context menu, and buttons to copy, paste, notify, open,
   save, choose a folder and open a URL, each answer shown; one
   `Stream(zui.ServiceReply(16 * 1024))`, every call from `zuiLoader`
   through `ServicesOf`; `-- --check` scripts what shows nothing.

**Done when.** Automated: core's tests in Debug, ReleaseFast and
ReleaseSafe and its `wasm32-freestanding`, `powerpc-linux` and `x86-linux`
checks; each compile-error case fails with its message; the native hosts' tests
in Debug and ReleaseSafe, `check` and `fmt-check`, with the host suite
passing every service the host has built, faked through
`Host.service_fake`; the host's own tests of `error.Busy`,
`error.TooLarge`, the menu built (read back from the `HMENU`), the
popup's position in screen pixels, a menu bar's `WM_COMMAND`, the dialog's
configuration, the notification's callbacks, and `ShellExecuteW` never
reached with a refused URL; the sokol renderer's tour runs unchanged; R1 counts
unchanged. By a person, in slice 5: `zig build services` in `hosts/native/`,
choosing a file, saving, choosing a folder, a notification clicked, a
context menu and the menu bar, a URL opened in the browser, copy and
paste, each in a screenshot.

**Spec.** §14.1, §16.3, §16.6, §19.5, §19.6.

Done in five slices. Slice 1, in `578b8c1` and `22a8cd5`: core gained
`core/src/services.zig`: `zui.ServiceRequest` (`.of(name)`), `ServiceAnswer`
(the outcome, borrowed, and the bytes the host could not hold),
`ServiceReply(n)` (the plain-data copy, text cut at a character and paths
kept whole, the rest counted), `ServiceSink` (`.of(&source)` for any source
whose `publish` takes a `ServiceReply(n)`), `ServiceError`,
`ServiceFailure`, `Notification`, `FileDialog`, `FileFilter`, `MenuItem`,
`MenuItemId` and `isOpenableUrl`. `checkHost` checks each service is a
struct and each function's type, `checkFileWatch` folded into the same
table with its message unchanged; ten compile-error cases pin the
messages. `zui_app.ServicesOf(Host)` gives `has_clipboard` through
`has_file_watch` and `has_menu_bar`, and each service behind its guard.
`zui_testing.expectHostConforms` checks a clipboard round trip, that a
path, a `file:` URL and a word are refused, and with the harness's
`openedUrl` that a URL reaches the system, and with `scriptServices` that
dialogs, menus and notifications answer as scripted, each naming its
request and window; its test host passes, and one answering another
request and one opening a path fail. A delivery of replies round-trips
through `zui_wire`. On Windows, `zuiClipboard.read` and `zuiOpenUrl.open`
claim a slot and post to the window thread, which reads the clipboard
(up to 64 KiB of UTF-8, lone surrogates replaced, the rest counted as left
out) or calls `ShellExecuteW`, so every answer comes from one thread;
`write` reports `GlobalAlloc` failing as `error.Unavailable`. The host
suite passes against a hidden window with the URL opener faked. Measured:
the zui-counts executable's .text and .rodata are byte-identical to
`62d0813`'s (sha256 6ac82a44... and d05b536a...), so R1 counts are
unchanged; the sokol renderer's tour on the host, in ReleaseSafe with
`--measure-idle`, idled at 0.0 ms of CPU over 10 s, and `zui_app` now
reports only notifications, file dialogs and menus missing. Decided in
the slice, beyond the plan: `Busy` also refuses a clipboard read or a URL
still waiting for the window thread; `ServiceAnswer.left_out_bytes`
carries what the host itself could not hold; `zui.isOpenableUrl` is core,
so every host refuses the same URLs.

Slice 2, in `hosts/native/` alone (`c6fc2d8`): `zuiNotifications.show`
checks the text is UTF-8, copies the title and body into fixed buffers cut
at a character to what `NOTIFYICONDATAW` holds (63 and 255 UTF-16 units),
and posts to the window thread, which adds the window's notification-area
icon on first use (`NIM_ADD`, then `NIM_SETVERSION` to version 4) and
shows the balloon (`NIM_MODIFY` with `NIF_INFO`), which Windows 10 and 11
show as a toast. The icon's callback message answers
`.notification_activated` for `NIN_BALLOONUSERCLICK` and
`.notification_dismissed` for `NIN_BALLOONTIMEOUT` and `NIN_BALLOONHIDE`,
then removes the icon; a notification replaced by the next is answered
`.notification_dismissed` and the icon stays; `Shell_NotifyIconW` failing
is `.failed = .unavailable`; the icon goes when the window is destroyed,
and one still showing then is not answered. A second `show` while the
first waits for the window thread is `error.Busy`. The fake records each
`Shell_NotifyIconW` call by message and the balloon's text, and answers
as the harness's `scriptServices` says by posting the callback message
Windows would, so the host suite now checks a notification through the
real callback path; the host's own tests check the calls made, the title
cut at a character, a click, a replacement, a time-out removing the icon,
and a callback with nothing showing answering nothing. The sokol renderer's tour on
the host idles as before (15.6 ms of CPU over 10 s and 10 frames on the
Welcome screen in ReleaseSafe) and `zui_app` now reports only file dialogs
and menus missing. Not detected: notifications the user turned off, or Do
Not Disturb, neither of which a balloon reports, so the Windows host never
answers `.failed = .denied`.

Slice 3, in `hosts/native/` alone (`eb0150b`):
`zuiFileDialogs.show(host, window, request, dialog, sink)` copies the
dialog's strings into one fixed buffer of 8,192 UTF-16 units: the title,
the directory made absolute (`GetFullPathNameW`, since the shell takes only
absolute ones), the suggested name, and up to 16 filters as patterns
(`*.zon;*.json`, or `*.*` for one without extensions). Past either limit it
is `error.TooLarge`, and text that is not UTF-8 is `error.InvalidUtf8`. It
then posts to the window thread, which is already a single-threaded
apartment. That thread makes `IFileOpenDialog`, or `IFileSaveDialog` for
`.save_file`, through `CoCreateInstance` (`windows/file_dialog.zig`, its
vtables written by hand). It always sets `FOS_FORCEFILESYSTEM`,
`FOS_NOCHANGEDIR` (so the process's working directory never moves) and
`FOS_PATHMUSTEXIST`. Open dialogs add `FOS_FILEMUSTEXIST`, and
`.open_files` adds `FOS_ALLOWMULTISELECT`. `.save_file` adds
`FOS_OVERWRITEPROMPT` and the first filter's first extension as the
default, and `.choose_folder` adds `FOS_PICKFOLDERS`. The thread then runs
`Show` owned by the window. Its modal loop keeps dispatching the window's
messages. The answer is `.files_chosen` with each `SIGDN_FILESYSPATH`
path in UTF-8 (up to 32 KiB, paths past it counted as left out), or
`.canceled`. A dialog the shell cannot make is `.failed = .unavailable`. A
second `show` while one waits or is open is `error.Busy`. A dialog still
open when the host closes is cancelled first, and its answer is not
published, since the application's sources may be gone by then. The
window closes once `Show` has returned. `IFileDialog.Close` called from
outside the dialog's own events returned `S_OK` but did not end `Show`,
so the host posts `WM_CLOSE` to the dialog's window, found through
`IOleWindow`, which cancels it as the Cancel button does.

The fake makes and configures the real dialog and stands in for `Show`.
It reads back the options, the suggested name and the folder from the
dialog's own getters, records the filters it was given (the shell has no
getter for them), and answers what the harness's `scriptServices` scripts.
It can also hold the dialog open, dispatching the window's messages as
`Show` would. The host suite now checks file dialogs through the window
thread. The host's own tests check an open dialog's options, folder and
filters and its paths; a save dialog's name, overwrite prompt and cancel;
a folder dialog; `Busy` while one is open; paths past the reply's room
counted; `TooLarge` and `InvalidUtf8` showing nothing; and a dialog open at
close answered with nothing. Two checks of the real `Show`, run once by
hand and not committed, showed a dialog on the desktop. One, given the name
`C:\Windows\win.ini` and sent its OK command, answered `.files_chosen`
with that path. The other, open when the host closed, returned
`0x800704C7` (cancelled) and closed the host about 0.1 s later, with
nothing answered.

Found and fixed: a clipboard read (since slice 1) and a file dialog
published their answer before releasing their slot, so a call made as
soon as the answer arrived could be `error.Busy`. Two of about 20 runs of the ReleaseSafe suite failed
this way. Each now releases first. The bytes it answers with stay put,
since only the window thread writes them. Twenty runs each in Debug and
ReleaseSafe then passed. The sokol renderer's tour on the host, in ReleaseSafe with
`--measure-idle`, idled at 31.3 ms of CPU over 10 s and 10 frames on the
Welcome screen, two of Windows' 15.6 ms ticks, against one in slice 2.
`zui_app` now reports only menus missing.

Slice 4, in `hosts/native/` (`02282d5`), with one sentence added to SPEC.md
§16.3 (`fcdef0e`): `zuiMenus.popup(host, window, request, items, position,
sink)` and `setBar(host, window, request, items, sink)` copy the items
into a fixed menu of up to 256 entries and 8,192 UTF-16 units, at most
eight submenus deep (`windows/menu.zig`). Each label is shown as written,
its `&` doubled so Windows underlines nothing, with its shortcut after a
tab as Windows' own menus spell it (`Ctrl+Shift+S`, `F1`). Past a limit
it is `error.TooLarge`, and a label that is not UTF-8 is
`error.InvalidUtf8`. `popup` converts the position to client pixels with
the last poll's scale and posts to the window thread, which builds the
menu with `CreatePopupMenu` and `AppendMenuW`, converts the position to
the screen, and shows it with `TrackPopupMenuEx(TPM_RETURNCMD |
TPM_NONOTIFY)`. It answers `.menu_item_chosen` with the application's own
id, or `.canceled`, and `.failed = .unavailable` while the user is in the
bar's menus, since Windows shows one menu at a time. A file dialog and a
popup now share one claim, so either one while the other waits or is
open is `error.Busy`. A popup still open when the host closes is ended
with `EndMenu`, not answered, and the window closes after it, as an open
dialog does. `setBar` builds the bar with `CreateMenu`, sets it with
`SetMenu` and destroys the one it replaced; given no items it removes the
bar. Each `WM_COMMAND` from it answers `.menu_item_chosen` to its request.
A bar set while the user is in the old bar's menus waits until they
close (`WM_EXITMENULOOP`), so a tracked menu is never destroyed. Each bar
and each popup numbers its items from a range of its own, two bars'
ranges in turn, so a command Windows reports after the bar was replaced
still names the bar it came from and is answered to that bar's request.
SPEC.md now says so, and that `setBar` with no items removes the bar.

The fake builds the real `HMENU` and stands in for `TrackPopupMenuEx`. It
reads the menu back item by item (`GetMenuStringW`, `GetMenuState`,
`GetMenuItemID`), records the position in screen pixels, and answers the
item the harness's `scriptServices` scripts. It can also hold the menu
open, dispatching the window's messages. The host suite now checks menus
through the window thread, so it checks all five services. The host's own
tests check a popup's items, separator, submenu, grayed and checked
states, doubled `&` and shortcut read back from the `HMENU`, and its
position in screen pixels at a forced scale of 2; `Busy` across popups
and dialogs both ways, and a closed menu answering `.canceled`;
`TooLarge` and `InvalidUtf8` showing neither a popup nor a bar; a popup
open at close answered with nothing; and a menu bar read back from the
window's own `GetMenu`, answering two choices sent as `WM_COMMAND`,
waiting while its menus are open, answering a late choice from the bar it
replaced, and removed. The native hosts' tests (63) passed six times each in
Debug and ReleaseSafe. The sokol renderer's tour on the host, in ReleaseSafe
with `--measure-idle`, idled at 0.0 to 31.3 ms of CPU over 10 s with 9 to
14 frames in three runs on the Welcome screen; a fourth drew 96 frames for
the pointer over the window. `zui_app` now reports no service missing.

Slice 5, in `hosts/native/` alone, after `02282d5`: `zig build services`
(`examples/services.zig`), a window on `zui_app` with a button for each
service: pick a file, save a file, show a notification, open a popup
menu, set or clear the menu bar, copy, paste, and open
<https://ziglang.org>. Each answer shows beside its button. A right click
anywhere opens the context menu, and Ctrl+C, Ctrl+V, Ctrl+O and Ctrl+S do
what the menus say. Declaration only notes what was asked for, and reads
the answers from one `Stream(zui.ServiceReply(16 * 1024))`; a popup's or
the bar's choice asks for the action it names. The loader makes every
call through `zui_app.ServicesOf`, behind its guards. The host gained
`Host.fakeServices(fake)`, the fake set after `init`, since `zui_app`
starts every host field at its default. `-- --check` runs the window
hidden, with the fake answering as a user would. It presses each button
in turn, chooses File > Pick a file from the bar by sending the
`WM_COMMAND` Windows would, and passes once each answer shows in a
frame's text and the bar is on, then off, the window (`GetMenu`). It
fails after 10 s. The paste right after the copy usually found the
clipboard held by another application (clipboard history, which opens it
after every change) and answered `.failed = .unavailable`, as the
contract says: four of the first five runs failed this way. The check now
presses Paste again, as a user would, and says how often. It then passed
in seven of seven runs, six in Debug and one in ReleaseSafe, each
pressing Paste once or twice more. The native hosts' 63 tests pass in Debug and ReleaseSafe, with
`check` and `fmt-check`. The sokol renderer's tour on the host, in ReleaseSafe
with `--measure-idle`, idled at 0.0 ms of CPU over 10 s, with 12 frames
and no wakes.

Measured across the item: R1 counts unchanged, since the zui-counts
executable's code was byte-identical (slice 1); no host frame path
changed; the host's fixed buffers for services are part of `Host`, so
calls allocate nothing of the process's.

What remains, and where it went:
- **Seen by a person, owed:** `zig build services` on the desktop, with
  a screenshot of each: the real toast, and clicking it to see
  "clicked"; the real open and save dialogs choosing a file; the real
  popup from a right click and from its button; the real menu bar, its
  menus opened by hand and an item chosen; and the browser opening
  <https://ziglang.org>. The hidden window, the fake and the hand-run
  `Show` of slice 3 cover everything else.
- **The menu bar shrinks the client area** by its height: `setBar`
  resizes the window's content, so the next record's viewport is
  smaller, and removing the bar gives it back. A window opened at a
  size keeps its outer size, not its content's.
- **H7:** a custom title bar has no caption for Windows' menu bar to sit
  under. H7 decided: under a custom title bar `setBar` answers
  `error.Unavailable`, since a native bar would sit hidden under the
  drawn one, and the application draws its own bar and uses `popup` for
  its menus. A popup's position, in the client area's layout units, holds
  either way.
- **H9:** dialogs and menus name their `WindowId`, and the Windows host
  asserts `.main` until H9 maps ids to windows; the menu bar's state is
  one struct for H9 to keep per window.
- **H4:** the Linux host implements these shapes; `zuiMenus` has no
  Wayland counterpart, so it may declare none.
- **Not detected on Windows:** notifications turned off or Do Not
  Disturb, which a balloon does not report, so `.failed = .denied` is
  never answered there.

### V2. Semantics and accessibility actions

**Grounding.** `Frame.semantics()` lists each node in tree order
(`core/src/context.zig:552-558`), in a slot beside its frame (`:739-749`)
that is emptied when the frame is released (`:731`). A node has a `u64`
id, the index of the node around it, a role, a label, a value,
untransformed bounds in layout units, a state and its actions
(`core/src/semantics.zig:120-134`). Parents always come earlier in the list
(`context.zig:1505-1516`), so any prefix of it is a whole tree. An
`action` event (`core/src/input.zig:240-242`) is answered by `applyAction`
(`context.zig:1822-1837`); a disabled element takes none. `zui_app`
hands the list to a host that declares `zuiSemantics`, on the UI thread,
after `zuiObserve` and before submission (`core/zui_app/zui_app.zig:408`),
and opens the window with room sized from `Config.limits`
(`:371-373`). `checkHost` checks the call's signature from a table that
H7's chrome regions can join (`core/src/contracts.zig:22`, `:124`). The
Windows host keeps one `accessibility.Bridge` per window
(`hosts/native/windows/host.zig:87`); `zuiSemantics` publishes into it (`:336`), the
window thread answers `WM_GETOBJECT` (`:580`), raises events
(`:576`) and disconnects at `WM_DESTROY` (`:482`), and runs in a
single-threaded apartment (`:389`). The bridge's snapshots, elements and
root are in `windows/accessibility.zig` (`Bridge` at `:28`, `publish` at
`:77`, `Element` at `:644`, `Root` at `:1117`); patterns are offered in
`patternProvider` (`:811`) and properties in `propertyValue` (`:832`),
a request is delivered by `request` (`:795`), and `announceChanges`
(`:141`) compares each node with its last `Summaries` (`:512`).

**Plan.** `Element.semantics`, and `Frame.semantics()` filled with each
node's role, label, value, state and actions, behind
`features.semantics`, which C7 added with `semantics()` gated and empty;
actions arrive as events and answer through the intent queries. The
host receives each frame's list through an optional call,
`zuiSemantics(window, nodes) SemanticsDropped`, which `zui_app` makes on
the UI thread between `endFrame` and submission, so a render thread and
`release` never race it. The host copies the list into two snapshots it
took room for in `init`, sized by `WindowOptions.semantics`, and swaps
them under a lock; UI Automation reads the front through providers
written as hand-made COM vtables, and a request comes back as an
`action` event through the host's inbox. In slices:
1. **The contract, the tree and `invoke`** (core and `hosts/native/`): the
   contract and its compile error, `zui_app`'s call, notice and report,
   the host suite's `invoke` step, and on Windows the fragment root, an
   element per node with its name, control type, AutomationId (the id in
   hex), runtime id (`[UiaAppendRuntimeId, low, high]`), bounds in
   screen pixels and place in the tree, `ElementProviderFromPoint`,
   `GetFocus`, `Invoke` and `SetFocus` as actions, and focus-changed and
   structure-changed events raised on the window thread only while a
   client listens; `examples/accessible.zig` for Narrator.
2. **The control patterns and property events** (`hosts/native/`):
   `IToggleProvider` for checkboxes and toggles through `invoke`;
   `IExpandCollapseProvider` for a node whose `state.expanded` is set,
   through `invoke` when the state differs; `IRangeValueProvider` for
   sliders and progress bars, `SetValue` becoming `adjust` by
   `round((new − value) / step)`, and by ±1 toward the target when `step`
   is 0; `IValueProvider`, read-only, for text fields and combo boxes;
   `ISelectionItemProvider` for options and radios and
   `ISelectionProvider` on a `list_box`; and property-changed events for
   name, value, toggle, expand, selection, range and enabled, compared
   against a summary the window thread keeps. Tested through the client
   against `zui_widgets` controls.
3. **Scroll, the menu and dismissal** (core, `hosts/native/`, the tour):
   `scroll: ?SemanticScroll` on `SemanticNode` (offset, content and
   viewport per axis, filled from `ScrollState`, paid for only with the
   feature on) and `IScrollProvider`;
   `IRawElementProviderSimple2::ShowContextMenu` as `show_menu`;
   `IWindowProvider.Close` on a dialog and `Collapse` on an open combo
   box's list as `dismiss`; the heading level; and the tour with
   semantics on, with Box Storm's frame time compared before and after.

The provider does not set `ProviderOptions_UseComThreading`: it is
free-threaded, reading snapshots under the bridge's lock, with atomic
reference counts and elements assigned under a lock of their own, so it
is correct on whatever thread UI Automation calls and in either
apartment. It never holds a lock while calling into UI Automation or the
host's inbox. A text field's `SetValue` stays read-only; typing reaches
it through the keyboard.

**Done when:** a widget test checks the list for each control; the
Windows host bridges it to UI Automation, checked through the UI
Automation client in-process (each slice's tests) and with Narrator and
Accessibility Insights by a person; and with the feature off, R1 counts
are unchanged.

**Cost.** With the feature off nothing runs: `zui_app`'s call is behind
`comptime Ui.features.semantics`, the check is comptime, and a window
opened without room allocates no bridge and leaves `WM_GETOBJECT` to
Windows. With it on, `zuiSemantics` copies the list, O(nodes + text
bytes), and asks `UiaClientsAreListening` once; events are raised only
while a client listens. The bridge takes 2 × (nodes × about 96 bytes +
text bytes + an index of 8 to 16 bytes a node) and a pool of elements at
`init`, from `std.heap.page_allocator`, since a host's `init` has no
allocator. BSTRs and SAFEARRAYs handed to UI Automation are allocated by
OLE for the caller to free, as the clipboard's `GlobalAlloc` is.

**Spec.** §13.5, §16.3, §16.6.

The core and `zui_widgets` slice came first. `Element.semantics`
declares a role, label, value, state and extra actions; `Frame.semantics()`
lists each such element in tree order with its id, bounds, the index of
the node around it, its state (with `disabled` and `focused` filled in) and
its actions (with `invoke`, `focus`, `scroll` and `show_menu` taken from
its flags and gestures). Labels and text values are copied into the
frame's text bytes, counted against `max_text_bytes` and cut at a
character when they do not fit. The list lives in a slot beside each
frame, not in `Frame`: any field added to `Frame`, even a zero-size one,
reordered its arrays and moved R1 counts by −0.33% to +0.49% with the
feature off. `Event.action` carries an `ActionEvent`, answered by
`clicked`, `focused`, `adjusted`, `manipulation` and a scroll,
`contextRequested` and `dismissed`; a disabled element takes none, and
without the feature the event is dropped. Every control in
`zui_widgets` declares its semantics (button, checkbox, disclosure,
slider with its range and `adjust`, text field, dropdown with its list
and options), the slider steps through `adjusted`, the dropdown's list
closes on `dismiss`, and `zui_reflect` names each control after its field.
`zui_testing.Driver.action` sends one. Measured against `8911fb2` with
`zig build counts`: with the feature off every scenario is identical to
the instruction; with it on and nothing declared, declaration moves
−1.28% to +0.52% and `endFrame` adds 2 to 7 instructions.

Slice 1 is done, in core and in `hosts/native/`. Core gains
`zuiSemantics`, `SemanticsCapacity`,
`SemanticsDropped` and `WindowOptions.semantics`, the compile error
`host_semantics_wrong_signature`, `zui_app`'s call with
`Notice.semantics_dropped` and `Report.accessibility`, and the host
suite's `invoke` step, which `QueueHost` passes and
`QueueHost(.drops_actions)` fails. The Windows host passes the
suite with the step answered through UI Automation's client in-process
against a window that is never shown (UI Automation exposes it), and
four tests of its own: the tree reads back with names, control types,
AutomationIds, parent and siblings through the raw view, and bounds in
screen pixels at a scale of 2; `SetFocus` arrives as a `focus` action and
a disabled element offers no Invoke pattern; a window opened without
room leaves `WM_GETOBJECT` to Windows; and a list past the room is cut
from the end and reported. Out of process, Windows PowerShell's UI
Automation client read `zig build accessible`'s Save button, label,
checkbox, slider and text field with their roles and bounds, invoked
Save (the label then read "Saved 1 times") and moved focus to the
checkbox.

Slice 2 is done, in `hosts/native/` alone. Each element offers the pattern that
stands for what it does: Toggle for a node that says whether it is
checked (not a radio or option), ExpandCollapse for one that says
whether it is expanded, RangeValue for a range, Value for text,
SelectionItem for an option or a radio and Selection for a list box,
and Invoke only where none of those stands for the click, so a checkbox,
an option and a combo box no longer offer it. Toggle, Expand, Collapse,
Select and AddToSelection become `invoke` when the node is not already
as asked; a range's SetValue becomes `adjust` by whole steps, or by one
toward the target when the range has no step, and a target outside the
range fails; RemoveFromSelection fails on the selected option, since one
is always chosen. A text field's Value reads as editable while it is
enabled, which it is from the keyboard, and its SetValue fails with
UIA_E_INVALIDOPERATION, since zui has no action that replaces text; a
combo box's Value is read-only. While a client listens, the window
thread compares each node with a summary of what it last announced (a
hash of its name and text, its range value, and its checked, expanded,
selected and disabled state, in two buffers allocated in `init`) and
raises property-changed events for name, value, range value, toggle
state, expand state, selection and enabled, and the element-selected
event. Three tests drive a window of `zui_widgets` controls through UI
Automation's client: each control's pattern and state; Toggle, SetValue
(0.5 to 0.8 at a step of 0.1), Expand and Select each arriving as the
action that answers it and the next frame showing it, with the list's
Selection naming the chosen option; and a property-changed handler,
added from the test's thread, hearing the checkbox turn off. With no
pattern code in zui, R1 counts cannot move.

Slice 3 is done, in core, the tour and `hosts/native/`. Core's `SemanticNode`
gains `scroll: ?SemanticScroll` (offset, content and viewport sizes and
the axes it scrolls on, filled after layout from the element's scroll
state, so it is the clamped offset the frame drew) and `level`, which
`Semantics.level` declares for a heading. The Windows host's elements
add the Scroll pattern (a small step is a wheel notch, 40 layout units,
and a large one the view's size; `SetScrollPercent` is a place in the
content; an axis that does not move fails, and a percentage reads
`UIA_ScrollPatternNoScroll` on it), `IRawElementProviderSimple2`'s
`ShowContextMenu` as `show_menu`, the Window pattern's `Close` on a
dialog as `dismiss`, and the heading level as `HeadingLevel1` to
`HeadingLevel9`; scroll percentages join the property-changed events. A
slider, a text field and a progress bar no longer offer Invoke beside
their own pattern. A dropdown's open list closes by its combo box's
Collapse, which slice 2 already made an `invoke`. The tour turns
`features.semantics` on (`apps/tour/src/kit.zig`). Two more conformance tests
drive a real scroll container through UI Automation (a notch, then 100%,
and a refused horizontal step), and a dialog's Close, a button's
ShowContextMenu and a heading's level. Out of process, Windows
PowerShell's UI Automation client read `zig build accessible`'s heading
(Level1), button, label, checkbox, slider, text field, dropdown and
scroll pane each with only its own patterns; toggled the checkbox off,
set the slider to 0.8, expanded the dropdown and selected High (its
value then read High, collapsed), scrolled the log by a notch and to
100%, and invoked Save. Measured: the zui-counts executable's `.text`
and `.rodata` are byte-identical to `7711b15`'s, so R1 counts are
unchanged with the feature off; Box Storm's frame, timed headlessly over
400 frames in ReleaseFast with Turbo Boost on, took a median of 198 and
197 µs with semantics off and 195, 198 and 197 µs with it on, within the
runs' spread; the tour on the Windows host with the bridge drew 300
frames across every screen with diagnostics ok and idled at 0.0 ms of
CPU over 10 s. A person's check with Narrator and Accessibility Insights
on `zig build accessible` and the tour has not been made; the automated
checks cover what it would see.

### G6. HDR and wide gamut

**Plan.** `Config.Color = zui.ExtendedColor`, clamped for renderers
without `zui_extended_color`; headroom from the environment; the output
format negotiated through `Surface`.

**Done when:** snapshot and lowering tests; the renderer suite's
reference scene declares it, and one renderer that declares it passes
the suite; the Windows host shows HDR white brighter than SDR white.

The first slice landed the core: `zui.ExtendedColor`
(4×f16 linear scRGB, with `Color`'s helpers), `Config.Color` and its
compile error, and `Config.extended_color`, which `zui_app.contextConfig`
takes from the renderer. Every type that holds a color is generic over
it (`zui.BorderWith`, `EffectsWith`, `GradientWith`, `ShadowWith`,
`BackdropBlurWith`, `DecorationWith(Color, MaterialHandle)`,
`TextStyleWith`), named by the context as `Ui.Border` and the rest, and
`zui`'s own unless `Color` is `ExtendedColor`. The commands carry
`Ui.CommandColor`: emission clamps each color for a renderer that draws
only `Color` and sets `Diagnostics.clamped_colors` when that changed
one. A context in `Color` runs the same instructions as before in
every `counts` scenario, and `bench-compare` against `2ac7223` calls
no scenario slower. The flag first made `Diagnostics` 104 bytes, which
moved every array of the frame after it by 8 and made the box tree's
declaration 3.4% slower (2.8% for the documents view);
`duplicate_ids` became a saturating `u16`, so it stays 96.
The second slice declares the renderer suite's reference scene in
`ExtendedColor`, with a box of HDR white, and takes the suite's
`extended_color` from the renderer, so one that declares
`zui_extended_color` is given every color as declared and must encode
it as `toColor` does (a test renderer that skips the encoding fails);
`zui_wire.Renderer(Ui)` declares `zui_extended_color` when `Ui`'s
commands carry `ExtendedColor`, and its commands round-trip in either
color. `toColor(fromColor(c))` is `c` for every 8-bit channel, so
the terminal renderer still passes at a tolerance of 0, and the raylib
and sokol renderers pass unchanged.
The third slice, in the sokol renderer (`06a28fa`):
its renderer declares `zui_extended_color`, so `zui_sokol.config`
sets `extended_color`, and it encodes each command's color at the
point it is drawn, as `toColor` does, from either color the
application declares; it passes the suite in its sokol_app window, and
fails it when the channels are encoded linearly instead.
The fourth slice negotiates the output format: `zui.OutputFormat`
(`.sdr`, `.scrgb_fp16`) and a host's and a renderer's optional
`zui_output_formats`, which must include `.sdr`, and in a renderer
names `.scrgb_fp16` only beside `zui_extended_color`, each a compile
error. `zui_app` opens the window with the formats both declare,
`zui.sharedOutputFormats`, in `WindowOptions.output_formats`, and
reports them; each native `Surface` carries the format the host chose,
`.sdr` by default, so the backends compile unchanged, and
`surface.outputFormat()` reads it. The host suite fails a surface in a
format the host does not declare. The core's hot paths are untouched;
the raylib, sokol and terminal renderers pass unchanged.
The fifth slice reads an `.scrgb_fp16` target back: a harness whose
`beginDraw` returns a surface in that format is read through its
optional `extendedPixel`, HDR white must read back as `hdr_white`
(four times SDR white, within the tolerance's share of it), and a
translucent color is expected to blend, and a blur to average, in
linear light there. The suite's own test renderer draws into either
target and passes in both; one that clamps HDR into its FP16 target
fails, reading back SDR white. Nothing outside `zui_testing` changed.
The sixth slice, in the sokol renderer (`e06389e`): its
renderer takes an `.offscreen` surface and draws into an image of its
own in the surface's format, RGBA16F for `.scrgb_fp16`, in linear
light, through a shader with sokol_gl's layout that decodes each 8-bit
sRGB vertex color and texel; a color brighter than SDR white is
carried divided by its brightest channel, which rides in sokol_gl's
per-vertex point size and is multiplied back. Its conformance run
passes the suite into the swapchain and into `.sdr` and `.scrgb_fp16`
offscreen images, and fails the FP16 run when HDR is clamped. It does
not declare `zui_output_formats` yet, since its `.win32` swapchain is
still 8-bit.

The seventh slice, in `hosts/native/` (`da286d5`): the Windows host declares
`zui_output_formats` with `.scrgb_fp16`. It reads the monitor the window
is on through DXGI (whether Windows runs it in HDR, and its peak) and the
display configuration (the SDR white level the SDR content brightness
slider sets), opens the surface in `.scrgb_fp16` there when the window
was opened with it and in `.sdr` otherwise, and reports
`Environment.hdr_headroom`, the peak over SDR white, or 1 in `.sdr`. It
reads them again when the window moves to another monitor, the displays
change, or a setting does. `forced_display_color` keeps its tests off the
monitor.
The eighth slice, in the sokol renderer (`f81fd03`): the renderer declares
`zui_output_formats` with `.scrgb_fp16` when it draws through
DirectComposition (not with `-Dgl=true`). A `.win32` surface in
`.scrgb_fp16` resizes the composition swapchain to RGBA16F in linear
scRGB, draws the frame as into an `.scrgb_fp16` offscreen image, which
the suite checks, and copies it into the swapchain through a shader that
multiplies each color by the monitor's SDR white over 80 nits, since
zui's scRGB puts SDR white at 1.0 and the swapchain's puts 80 nits there.
The level is read at most twice a second, since the slider tells no
window when it moves.
The ninth, in `hosts/native/` (`cc3033b`): `zig build hdr` shows boxes of SDR
white and two and four times it, and `-- --measure` reads them back off
the desktop in scRGB through DXGI's desktop duplication, which sees past
SDR white where GDI clips at it. On the reference machine's monitor in
HDR (a 1,068-nit peak, SDR white at 280 nits): `scrgb_fp16`, headroom
3.81; SDR white 3.500 in scRGB, twice it 7.000, four times it 14.000,
2.00× and 4.00× SDR white. The native hosts' tour, the sokol renderer's
demo, its conformance run and every test pass in `.sdr` as before.

Left for later: the SDR content brightness slider is read again only
when the window moves, the displays change or a setting does, and by
the sokol renderer twice a second, so a headroom reported after the
slider moves waits for one of those; the Linux host (H4) and macOS (H3)
report no headroom.

**Spec.** §13.1, §13.3, §16.4, §18.

### R9. Measuring across operating systems and hardware

**Grounding.** A result in a commit message records neither the OS, the
CPU nor the power settings it came from, so results from two machines
cannot be set side by side.

**Plan.** Each result keeps the machine it came from, and a report sets
machines side by side, each normalized to its own box tree, to show how
each platform's costs differ rather than which CPU is faster.

**Done when:** one commit's results from two operating systems, or two
CPU architectures, appear side by side in `bench-report`.

Built in `fe4f48e`. `Machine` records the OS and its version, the CPU
vendor, the physical cores, the L1d, L2 and L3 sizes, the target and CPU
model built for, and the commit, on Linux, Windows and macOS; the commit
and the clock stay out of the fingerprint. `bench --results-dir <dir>`
writes `<dir>/<fingerprint>/<commit>.json`, and
`zig build bench-report -- <dir> [<commit>]` names the five scenarios
whose relative cost differs most. README's *Comparing machines* gives the
recipe, cross-built executables included.

Both halves ran at `be96e84` on the reference machine, pinned to core 19,
into `cross-os-files/source/repos/AaronJClausen/zui/bench-results` on the
shared data drive: bare-metal Linux 7.2.15 with turbo off and the
`performance` governor (`3b27f9488f36046b`), and Windows 11 10.0.26300
on the High performance plan, boost mode 3, turbo on (`38f4bf8363de7681`),
neither allocating after `init`. The box tree laid out in 110.1 µs and
83.7 µs. Over each machine's own box tree, every scenario's frame,
declaration and read agree within 4%, but the documents view's
declaration (1.16×) and `depth 64`'s (1.14×), scenes of a few
microseconds where the Windows clock's 0.1 µs steps count. Startup is
where the two operating systems differ: the documents view's first
frame costs 0.56× the box tree on Windows and 0.15× on Linux (3.69×),
`init` 0.70× and 1.01× (1.44×), the first frame of 1,000 texts 3.38× and
2.55× (1.32×). Each touches memory for the first time, which Windows
pays for more. `--counters` builds for ARM Linux but is unverified there;
macOS's counters through kperf are not written.

**Spec.** §20.3.

### P12. Text commands that point at their style

**Grounding.** `RenderCommand.Text` (`core/src/commands.zig:85`) holds a copy
of its `TextStyle`, 20 bytes of its 40, and `emitText`
(`core/src/emission.zig:330`) copies the record's style into every line. A
command is 80 bytes.

**Plan.** `style: *const TextStyle`, pointing at the text record's style,
which the frame holds until it is released as it holds `content`.
Renderers read `text.style.size` unchanged. `zui_wire` sends a single
pointer as what it points at, and keeps a copy beside the command's text
in its histories and the remote's slots.

**Done when:** a renderer reading a text-heavy frame's commands is faster
by `bench-compare`, and no scene is slower.

**Status.** Measured at `9154f3f` in the core alone, then set aside on
the branch `p12-text-style-pointer` (`7e9d2fb`, off `fb3c7bd`), whose
commit message lists what is left. A command becomes 72 bytes, not
fewer, since a border's 36-byte payload then sets the union's size, and
a text payload 32. By `counts`, the text scenes run 0.06% to 0.24% fewer
instructions and their simulated D1 misses change by under 0.1%, while
`4096 interactive boxes`, which draws no text, runs 1.17% more. No
scene reads the commands as a renderer does, which is where the audit
put the saving. `1000 labels, rendered` (`core/bench/scenes.zig`) now does:
1,000 single-line labels in 8 bordered columns, all inside the viewport,
whose commands are read after each frame as the sokol and raylib
renderers read them, each command's bounds and payload and, for a text,
its style and every byte of its content, a pen advanced glyph by glyph.
`bench` times the read as a phase of its own (`, read`), and `counts`
counts it: 35.5 µs and 244,757 instructions a frame at its commit, from
about 1,000 text commands and 16 for the columns.

Carried onto `main` after `a021c1d` and finished, then judged and not
shipped: parked on `p12-text-style-pointer-on-main` (`7e27942`), which
supersedes `p12-text-style-pointer`, with the terminal renderer's two
tests changed beside it. A context that clamps
`ExtendedColor` points its commands at a clamped copy per text record,
`Frame.clamped_text_styles`, which exists only there; `zui_wire` copies
the style beside the text in its histories and the remote's slots.
The raylib and sokol renderers pass against it unchanged; the web host's tests,
which build three text commands by value, were not updated. Every check
passes. `bench-compare -- a021c1d --require-quiet` (100 rounds over 3
layouts, turbo off, pinned): the read +0.4% (+0.1% to +0.9%), within
its band, so not faster; called slower, beyond their bands, are
`4096 interactive boxes`' declaration +2.3%, the documents view's +2.4%,
both cells scenes' +0.8% and +1.3%, warm, single-line and cold text's
+1.1% to +1.2%, and `depth 64`'s `endFrame` +1.3%. By `counts`, the
read runs 0.76% more instructions with 45.6% more simulated D1 misses
(1,917 to 2,791 a frame): the style becomes a load from the frame's text
records, away from the command the renderer is already reading, while
every `endFrame` runs 0.05% to 1.09% fewer instructions. The saving the
audit predicted is not there for a renderer that reads the commands in
order.

**Retired by the owner** on those measurements. The scene stays on
`main`.

### P11. Flat child lists

**Grounding.** `Frame.Children.next` (`core/src/context.zig:487`) and
`FlowChildren` (`core/src/layout.zig:76`) step to each sibling through
`subtree_end`, one dependent load at a time.

**Plan.** Only after `perf` attributes cycles of `4000 children of one
parent` to these walks: child indices in one array, built after
declaration from `child_counts` and a prefix sum. P4 recorded that
reshaping these passes cost 3% to 17% before.

**Done when:** the wide tree is faster by `bench-compare` and the box tree
no slower; or retired with the profile.

**Retired by the owner,** on the profile taken at `85242fc` and
`a4dfbf4`; nothing was built. Under Callgrind, `Children.next` takes
24,000 steps a frame in `4000 children of one parent`, 5.5% of its
`endFrame` instructions. `bench --counters` (turbo off, pinned) counts
that `endFrame` at 877,162 instructions in 289,703 cycles, 3.0 a cycle,
with 34 branch misses and no last-level misses: a pass waiting on a chain
of dependent loads could not keep that rate. The box tree runs 3.1 a
cycle. `perf record -e cycles:upp` over 40 runs of the scene (35,520
samples) puts 0.9% of its cycles on the walk's lines
(`context.zig:489-491`), against 21% in `distribute` and `position` as a
whole: the time goes to each child's work, most of it reading the
child's sizing through its `layout` pointer (`context.zig:506`, `:517`)
and its size, not to finding the next child. A flat child list could
save at most that 0.9%, and would build two more passes every frame.

### V4. The demo in a browser

**Plan.** The demo streaming over the wire (F5) to a thin browser client,
published from CI. **Done when:** the demo runs at its native frame rate
in a browser.

The owner opened the published page in a desktop
browser: the tour keeps the display's frame rate, the mouse, the wheel
and its shortcuts drive it, and its gradients, shadows, blurs and
materials look right. They found two defects, fixed before V4 closed:
- **Timings read 0 µs.** The tour's strip and frame inspector read 0 µs
  for every timing, their bars at 0: the web host's `TourSession` never
  recorded the tour's `Perf` samples, which the native host takes
  around `beginFrame`, the declaration and `endFrame`, and had it, the
  worker's `SteppedIo` reads the page's one instant for the whole frame.
  The session now times each frame on a stopwatch of its own, the
  worker's `performance.now()` imported by the module, and records what
  the native host records, with the page's time to draw the frame before
  as its submit time. `test-demo` still compares every frame byte for
  byte with the native run: real timings differ from run to run and move
  the strip's text and bars, so no mask could compare them, and both
  runs time frames on a steady stopwatch instead, 1 µs a reading.
  `test-site` now fails unless the page times its frames above 0 µs: it
  failed before the fix (no frame above 0 µs within 10 s), and after it
  the newest frame was declared in 745 µs, at 37 frames a second in
  headless Chromium.
- **Only text was smoothed.** The sokol renderer has no coverage of
  its own for shapes; its demo window smooths every edge with
  `sample_count = 4`, and the page drew with one sample per pixel.
  `test-draw` could not tell: its reference was drawn into an offscreen
  image of one sample per pixel, and an unsmoothed pixel matches a
  neighbor across the edge within the check's reach. The page now draws
  into a renderbuffer of four samples per pixel and resolves it into the
  texture that backdrop blurs sample and the canvas shows. The sokol
  renderer (`58c114a`) draws an `.offscreen` surface with
  `renderer.offscreen_sample_count` samples per pixel, and passes the
  renderer suite with four. `test-draw` draws each frame twice: with one
  sample per pixel and every command, compared as before, and with four
  and without text, where each reference pixel must also match the
  drawing, a pixel may differ by one sample's share of the colors within
  two pixels (SwiftShader snaps vertices to a sixteenth of a pixel), and
  four pixels a frame may match nothing (a line thinner than a pixel has
  two edges, each moving a sample). Text is left out there, since where a
  glyph's quad covers part of a pixel a GPU may sample the glyph anywhere
  in the pixel, and SwiftShader and NVIDIA's driver choose differently.
  With four samples, the unsmoothed page failed every frame, 338 to 2,374
  pixels a frame matching nothing; the smoothed one passes every frame,
  at most 2 pixels a frame matching nothing. Its run in CI, its reference
  drawn by llvmpipe, is to be confirmed.

After V4 closed, the owner found the page never slept: it stepped the
tour and drew a frame at every `requestAnimationFrame`, and the worker
asked `ui.nextFrame()` only to label those frames "requested". The page
(`22c4330`) now sleeps as native hosts do. Each answer from the worker
carries when to step the tour again: its `nextFrame`, or sooner when one
of its tasks' sleeps ends, since under `SteppedIo` tasks run only while a
frame waits for them, and while a Gallery tile loads or a Mission Control
producer sleeps, `nextFrame` says `.on_event`. The page asks for an
animation frame at once, sets a timer for a deadline, or waits for the
canvas's input, a resize or a change of `devicePixelRatio`. A step
declares a frame only when one is due, for the reasons the native tour
declares one, and `test-demo`'s byte-for-byte run still declares one
every tick. `test-site` now checks that the idle page draws only the
tour's heartbeat while the display runs on, that input wakes it and is
drawn, that Mission Control's producers keep drawing and every Gallery
tile loads without input, and that the page then sleeps again. Idle on
Welcome in headless Chromium, the page drew 19 frames a second before,
every animation frame it had (drawing each held SwiftShader there), and
1 after, the tour's heartbeat, while the display ran at 60. Box Storm,
Typography, Light and Depth, Transforms and Materials animate and still
ask for every frame, as natively, where the native tour declares all
300 of 300 display frames on each, against 4 on Welcome.

It landed in five slices, in `hosts/web/` unless one says otherwise:
1. **The client's decoder in WebAssembly.** The web host's
   `FrameStream(Ui)` holds what has arrived of a stream and decodes each
   frame once it is whole, and `src/browser.zig` exports it for the page
   as `zui-web.wasm` (19 KB in ReleaseSmall, 12 MiB of memory reserved by
   `zuiWebInit`). `DemoUi` declares the tour's commands, colors and
   payload types field for field, so the browser decodes the tour without
   sokol. `zig build test-demo` declares the tour's thirteen screens
   headlessly for 24 frames each, the mouse crossing each, writes them as
   the wire renderer does (2,619,982 bytes, every command kind but
   `image`, which the tour never draws), feeds them under Node to the
   client built for `wasm32-freestanding` in pieces of 1 to 16,384 bytes,
   and checks that each of the 312 frames, written whole again in the
   browser, hashes as the frame drawn did; a flipped bit in the stream or
   in the expected hashes fails it. CI runs it on Linux. In core, a test
   pins the decoder reading again a message cut short at any byte.
2. **Drawing,** in parts. The client lays each frame's commands out as
   triangles in the sokol renderer's geometry (`DrawList`: rounded
   corners in eight segments, borders inside their bounds, gradients in
   bands of OKLab color, shadows faded in six rings, transforms applied to
   each vertex, a batch per clip scissored as sokol_gfx truncates it), and
   `web/frame_drawer.mjs` draws them through WebGL 2, one draw call per
   batch (Decisions, Made: how the browser draws). The client is now
   37 KB in ReleaseSmall and reserves 20 MiB, 8 of them for the
   vertices. `zig build test-draw`
   draws the middle frame of each of the tour's thirteen screens with
   the sokol renderer into an `.sdr` offscreen image, through OpenGL in
   a sokol_app window, and with the client in headless Chromium on
   SwiftShader, keeping in both only the commands the client draws, and
   compares them pixel by pixel. A pixel matches when its colors are within
   2 of the reference's, or of a neighbor's, since two rasterizers may put
   an edge a pixel apart.
   - **Shapes:** rectangles, borders, clips, gradients, shadows and
     transforms. Every pixel of the 13 frames matches: 1 to 12,638 of
     each frame's 1,296,000 pixels differ at all, and 1 to 209 by more
     than 2 (at most 231), each on the edge of a rounded corner or a fan's
     triangle and matching a neighbor. The reference reads back the same
     bytes on every run. Drawing the shadows with five rings instead of
     six fails it. CI runs it on Linux under Xvfb with Google Chrome; its
     first run there is to be confirmed.
   - **Text.** The
     page hands the client the stream's fonts: the TrueType ones, which
     follow the ids of sokol's six built-in bitmap fonts in the order the
     host added them, and those six. stb_truetype, at the sokol renderer's
     commit, is compiled into the client without a C library, allocating
     from a scratch reserved at init, and rasterizes into a 1024² RG8 atlas
     packed as the sokol renderer packs its RGBA one, so a glyph sampled at its
     edge blends with the same neighbors; bitmap glyphs are an R8 texture
     sampled at the nearest texel. A vertex grows from 12 bytes to 56: an
     atlas glyph carries the map from a pixel's position to its texture
     coordinates, and its texel bounds, and the page finds both pixel by
     pixel, since SwiftShader snaps vertices to a sixteenth of a pixel
     and coordinates interpolated across a turned glyph differed from
     the reference by up to 31 at 237 pixels of the Transforms screen.
     The client is 63 KB in ReleaseSmall and reserves 35 MiB, 14 of them
     for 2^18 vertices (6.7 times the busiest compared frame's 38,790).
     `test-draw` compares the text too, its reference drawn with the
     tour's fonts and failing if the sokol renderer's glyph atlas overflowed, and
     a frame passes with at most one pixel matching nothing within 1
     (`maxUnmatchedPixelsPerFrame`; Decisions, Made: a pixel on a glyph's
     edge). In Debug and ReleaseSafe alike, 1 to 12,717 of each frame's
     1,296,000 pixels differ at all, 1 to 2,872 by more than 2 (at most
     231), and every frame has no unmatched pixel but frame 252, on the
     Transforms screen, which has one: its centre 0.0002 texels inside a
     glyph's right edge, drawn by the client (75, 75, 85) and left as the
     button's background (35, 35, 50) by the sokol renderer's OpenGL capture.
     Handing the client the Bold and Regular fonts swapped fails all 13
     frames (13,480 to 61,256 unmatched pixels), and moving every
     TrueType glyph a pixel right fails frames 204 and 252 (7 and 2,327);
     the neighbor rule absorbs the shift elsewhere. CI's first `test-draw`
     with text, its reference drawn by Mesa under Xvfb rather than this
     machine's NVIDIA driver, is to be confirmed.
   - **Backdrop blurs and materials.** A blur starts a batch, and
     before it the page copies the canvas into a texture and runs
     the sokol renderer's two passes: each Gaussian tap, split into the coarse and
     fine weights its 8-bit vertex colors add, is an instance of a
     quad over the blur's whole pixels, adding its linearly filtered
     sample into a float target along x, then from that into another
     along y, the sample clamped per pixel to the region's edge pixels,
     which is what the sokol renderer's three quads per tap draw. The batch's fan
     then takes the blurred texel at each pixel, under the tint. A
     material is a batch of its own, its uniforms the sokol renderer's, its
     pattern found at each vertex's place in the element by the sokol renderer's
     material shader ported to GLSL ES. The targets are RGBA32F where
     WebGL can render, blend and filter it, else RGBA16F; without
     `EXT_color_buffer_float` a blur is its tint alone; past 16 blurs or 256 materials a frame
     draws the tint or the fallback, counted, as the sokol renderer does. The client
     is 66 KB in ReleaseSmall and still reserves 35 MiB. `test-draw` now
     keeps every command but `image`, which the tour never draws. In
     Debug and ReleaseSafe alike, 1 to 16,682 of each frame's 1,296,000
     pixels differ at all and 1 to 2,872 by more than 2 (at most 231),
     each matching a neighbor, and frame 252 keeps its one unmatched pixel;
     inside the frosted pane on Light & Depth (frame 228) and the material
     cards on Materials (frame 276) no pixel differs by more than 1.
     Blurring with a radius of 8 instead of 10 fails frame 228 (550
     unmatched pixels), and turning every material's phase by 0.02 more
     fails frame 276 (48,254). The check's removal of Chromium's profile
     now retries, since a child process could still be writing to it.
     CI's first `test-draw` with blurs failed frame 228 (17,654 unmatched
     pixels): Mesa's llvmpipe, drawing the reference under Xvfb, rounds
     each tap's addition to an RGBA16F target differently and summed the
     pane 2 to 6 color steps darker than NVIDIA. The sokol renderer (`05724a9`)
     now sums blurs in RGBA32F where the GPU can, and RGBA16F otherwise,
     and so does the client; `test-draw` fails if either side cannot sum
     in RGBA32F, and reports each failing frame's numbers and uploads its
     images from CI. Against references drawn by NVIDIA and by llvmpipe
     alike, no pixel inside the pane differs by more than 1, and every
     frame but 252 (its one pixel) has none unmatched; 1 to 13,740 of each
     frame's pixels differ at all on NVIDIA, 5,516 to 22,905 on llvmpipe.
     Its run in CI is to be confirmed.
3. **Input.** `web/input_recorder.mjs` turns a canvas's pointer,
   wheel, key and text events, its size and `devicePixelRatio` into calls
   the client makes records of: the web host's `RecordStream(Ui)` fills a
   `RecordBuilder` and writes, through `zui_wire`'s `Encoder`, the
   stream's header and then a record only when it holds events or the
   viewport or scale changed, as F5's client sends. Its message buffer is
   reserved at init for every event the builder holds at twice its size
   in memory, which a test fills with the largest events. A key is the
   one `KeyboardEvent.key` names, or for a digit or a mark the one its
   `code` places, so Ctrl+2 is Ctrl+2 on any layout, and a key that types
   a character without Ctrl or Meta sends it as text; a wheel's lines are
   40/3 units, a notch of three as far as the Windows host scrolls. The
   newest frame's cursor is set on the canvas by its CSS name. The tour
   has sources, so its records end with their deliveries, which a live
   record writes as none whatever the sources: `DemoUi` declares one that
   delivers nothing, without which the tour's host read past the end of
   the browser's records. `zig build test-input` gives the page a mouse
   move and a click on the rail, Ctrl+3, Ctrl+PageDown, two typed keys,
   the wheel, a touch and a resize through headless Chromium's DevTools
   protocol, runs the tour on the 9 records (429 bytes) the client wrote,
   checks each against what the page was given and that the tour moved
   to Mission Control, Box Storm and the Gallery and asked for the
   pointer cursor over the rail, and sends its frames back to the page,
   which must show that cursor. Dropping `ctrlKey` from the page's
   modifiers fails record 3, positions in device pixels fail record 1,
   and not setting the cursor fails frame 0. The client is 75 KB in
   ReleaseSmall and still reserves 35 MiB. The IME's text input area, and
   composed text, wait for E1; CI's first `test-input` is to be confirmed.
4. **The demo behind the page, in a Web Worker** (Decisions, Made): the
   tour built for `wasm32-freestanding`, its frames posted to the page as
   wire bytes and the page's records posted back. In parts:
   - **The tour without sokol** (in the sokol renderer, `ef05a67`). A
     module of the sokol renderer's that does not import sokol holds
     `Text`, `truetype`, `Material`, `Image`, the commands the renderer
     draws and `config`; `zui_sokol` re-exports them, and its `config`
     checks the renderer. `Image` is now the ids of a sokol_gfx view and
     sampler, field for field what the web host's `DemoUi` decodes, and
     `zui_sokol.imageOf` makes one from sokol's handles. The tour declares
     its `Ui` through that module, so the tour imports no sokol, and given
     a freestanding target the sokol renderer's build makes only those two
     modules. Without a C library stb_truetype allocates nothing: it
     measures, and would rasterize no glyph. The sokol renderer's
     `zig build check` compiles and links the tour declaring a frame for
     `wasm32-freestanding` on `std.Io.failing` (7.5 MB in Debug,
     importing nothing from the page); run once by hand under Node, it
     declared the frame. The tour's frames are unchanged: the web host's
     `test-demo` writes the same stream byte for byte, its reference for
     `test-draw` is the same, and `test-input` passes.
   - **The worker** (on the tour at `5242889`).
     `zig build`
     writes `zui-web-tour.wasm`, the tour built for
     `wasm32-freestanding` with atomics and bulk memory, on memory it
     imports shared: 793 KB in ReleaseSmall, 8.0 MB in Debug, and about
     49 MiB once `zuiTourInit` reserves it (the tour, 16 thread stacks of
     256 KiB and 4 MiB for a frame's bytes). The web host's `TourSession`
     runs the tour as a loop that owns its clock: each frame it steps the
     tour's `Io` to the page's instant, takes the records that arrived
     whole, declares the frame and writes it through `zui_wire`'s
     `Encoder`, and `web/tour_worker.mjs` posts those bytes to the page.
     The tour's tasks run on an `Io` of the worker's own, `SteppedIo`
     (Decisions, Made: how the tour's tasks run in the worker): its
     clocks read the page's instant, and its tasks take turns on 16
     threads, each a worker on the tour's memory (`web/tour_thread.mjs`,
     setting its own stack pointer and thread-local storage), one at a
     time and only while the frame waits for them; a task runs as it
     starts until it first waits, and waits for a thread while all 16
     are taken. `test-demo` now also runs the tour in that worker under
     Node, on the records the client wrote of the mouse crossing each of
     the thirteen screens and Ctrl+PageDown between them, 312 frames at
     60 Hz on the page's clock, and runs it natively on the same ticks
     (`tools/tour_frames.zig`, the same `SteppedIo` on 16 native threads):
     every frame is the same bytes (2,628,746 in all), the tour started
     and finished 66 tasks and was refused none on both, and the client
     decodes every frame. In the worker the 312 frames take 0.9 s in
     Debug and 0.1 to 0.2 s in ReleaseSafe, ReleaseFast and ReleaseSmall,
     starting the threads included; three runs of each agree. A worker
     refusing every task, as `std.Io.failing` does, fails it (no task
     finished), and so does a worker on 4 threads (frame 76 differs), and
     at the tour of `ef05a67`, where the Gallery's tiles depended on the
     pointer width, frame 88 differs. By hand, in headless Chromium
     serving the page cross-origin isolated, the worker drew 312 frames
     in 115 ms in ReleaseSmall, after 28 ms starting its threads, and ran
     the same 66 tasks; served without those headers, the page cannot
     post shared memory to its worker, so slice 5 must serve it isolated,
     which GitHub Pages cannot set headers for: a service worker that
     adds them, or another host.
5. **Published from CI.** The
   page, `web/index.html`, starts the tour's worker, and on each of the
   display's frames sends it the page's clock and the record the canvas's
   input made, draws the frame it answers with, and shows its cursor
   (`web/tour_page.mjs`). It stays on GitHub Pages, made cross-origin
   isolated by a service worker of its own (Decisions, Made: how the
   published page is isolated): `web/isolation_service_worker.js`
   serves the page and everything it loads again with
   `Cross-Origin-Opener-Policy: same-origin` and
   `Cross-Origin-Embedder-Policy: require-corp`, and the page registers it
   and reloads once, and says so rather than reload again if it is still
   not isolated. `zig build site` writes the page, the client, the tour's
   worker, sokol's built-in bitmap fonts and the tour's TrueType fonts with
   their license to `zig-out/site`, 1.0 MB in ReleaseSmall (the client
   77 KB, the tour 793 KB); the Pages workflow builds it in
   ReleaseSmall on each push to `main`, runs `test-site` on it and
   publishes it. `zig build test-site` serves the site as GitHub Pages
   does, without the isolation headers, opens it in headless Chromium and
   checks that the page is isolated, through its own service worker,
   after one reload, draws the worker's frames (49 of headless Chromium's
   55 animation frames a second, on SwiftShader at 1600 by 1000 pixels,
   the worker answering in 0.5 ms and the page drawing in 0.7 ms at the
   median, in ReleaseSmall), and that its input reaches the tour: the
   mouse over the rail turns the canvas's cursor to the pointer, and a
   click on Mission Control's entry starts its two producers' tasks. A
   service worker that leaves out `Cross-Origin-Embedder-Policy` fails it
   (the page says it is not isolated), and so does a page that sends only
   its first record, draws nothing, or shows no cursor. CI runs it too.

### F7. The wire's renderer declares its context's payload types

**Plan.** `zui_wire.Renderer(Ui)` declares `Ui`'s `ImageHandle`,
`CustomData`, `MaterialHandle` and `FontId`. **Done when:**
`zui.checkRenderer` accepts `zui_wire.Renderer` of the tests'
every-command context, and `zui_app.contextConfig` of it gives back
that context's payload types.

The renderer declared `zui_commands` from `Ui` but none of its payload
types, so for a `Ui` with `.material` among its commands
`zui.checkRenderer` failed ("… .zui_commands includes .material but
… .MaterialHandle is void"), and `zui_app.contextConfig` of it lost a
`Ui`'s images, custom payloads and materials. It now takes each from
`Ui.RenderCommand`: the image's and the material's handle types, the
`custom` payload's type when there is one, and `Ui.FontId`. The plan
said to declare each only when it is not `void`, but Zig cannot declare
conditionally, and a `void` declaration is what `checkRenderer` and
`contextConfig` already take for an absent one. A test checks the
renderer of the every-command context and that `zui.Context` of
`contextConfig` of it is that context again; it fails to compile
without the change with the message above.

The native hosts' `remote` example, `zui.checkRenderer` of
`zui_wire.Renderer(tour.kit.Ui)`, failed the same way against the tour
of `5242889`, which has a Materials screen; with this commit it compiles
(`zig build check -Dtarget=x86_64-windows`), and needs no change of its
own. Nothing on a hot path changed. The sokol renderer (`374702f`) and
the native hosts (`b10af14`) build on this commit, and the hosts' check
for x86_64 and aarch64 Windows compiles the `remote` example.

### V3. Safety sweeps

**Plan.** The invariant checks that read only a `Frame`, at the end of
`endFrame`, behind `features.safety_sweeps`, which C7 added. **Done
when:** the randomized tests run through it, a debug demo runs with it
on, and with the feature off, R1 counts are unchanged.

`Frame.sweep()`, in `core/src/sweeps.zig`, returns the first invariant a
frame breaks as a `zui.SweepFailure`, naming a `zui.Invariant` and the
element or command: sizes and positions finite and not negative; child
lists that agree with the parent links, declaration order and counts;
overflow only once every shrinkable child is at its minimum, free space
only once every growing child is at its max, `grow_from_min` siblings
grown by equal shares, growing children filling the content box across;
a wrapping row's lines fitting it and not overlapping; children in the
flow starting inside the content box on each axis that does not scroll;
and commands in nondecreasing layers, with clips balanced in each. Its
slack grows with the sizes compared, since sums of thousands of sizes
round in `f32`. With `features.safety_sweeps`, `endFrame` runs it after
emission and panics on a failure, naming the frame and the element.
These were the randomized test's own checks; they moved into the core,
and the test now runs 2,000 random trees through `endFrame`. The tests'
shared context turns the feature on, so every test frame is swept in
every build mode, and a test pins that a negative and a NaN size are
named. SPEC.md §20.1 said children lie within their parent's clip; it
now says they start inside the content box on an axis that does not
scroll, since an overflowing child that cannot shrink passes the clip by
design and a scrolled axis is offset by state the frame does not keep.

The raylib renderer's tour needs no change: its Debug build has the
feature on by default, and its run with `--hidden --frames 900 --cycle 40`
drew 900 frames across every screen, every limit held, with no failure.
The raylib, sokol and terminal renderers' tests pass.

Measured against `4f9d316` with `zig build counts`: with the feature
off (its ReleaseFast default) every scenario is identical to the
instruction. With it on, declaration, whose code did not change, moves
−0.10% to +0.74% as the code lands elsewhere, and `endFrame` grows by about 220 instructions an element: +71.9% for the
4,096-box tree, +58.4% for 4,000 children of one parent, +45.5% for the
interactive boxes, +23.1% for warm text and +6.5% for cold text.

### V1. `zui_debug`

**Plan.** An inspector over `Frame.inspect`: the element tree, the
hovered element and its configs, diagnostics, lowerings and fallbacks,
and a performance overlay from the tracer, its theme reloaded when its
file changes. **Done when:** `zui_testing` drives it over the Documents
view, and the demo toggles it with a key.

`Frame.inspect(index)` returns an `ElementView` of every element a frame
kept (`046724e`). The `zui_debug` module's `Inspector(Ui)` copies a
frame's tree out of it in `observe(frame, pointer)`, leaving out its own
panel, and `declare(ui)` floats a panel at the viewport's right edge
(`858acf3`): the frame's `Diagnostics`, each exceeded limit named by its
`limits` field, and the fallbacks in effect, with a line for each part
of what `reportRun` was handed, such as `zui_app`'s `Report`
(`5ee8be5`); each zone's time in the last frame, its mean and peak over
the last 60, from `zui_debug.ZoneTimer(Inner)`, a tracer that passes
each zone on to `Inner` (`54c97ac`); then the element under the pointer,
every field of its configs that differs from the default, and a row per
element, indented by depth. Its theme, `PanelTheme(FontId, Color)`, is
read from a ZON file when the host's file watch says it changed, with
no allocation, through a `Stream(zui.FileChange)` and a `Latest` of the
theme among the context's sources, so a replay restyles without reading
a file (`389e497`). `zui_app`'s optional `zuiObserve(app, ui, frame)`
hook hands the application each frame on the UI thread before it is
submitted, and `zui_testing`'s driver runs the inspector over the
Documents view of `core/bench/scenes.zig`: a row per element, and the sixth
document under the pointer with its rectangle, flags and hovered
background (`676799c`).

The raylib renderer's tour (`6a12de7`) toggles the panel with F12,
or opens it with `--zui-debug`, observing frames only while it is open;
its tracer is `ZoneTimer(zui_tracy.Tracer)`, and its fallbacks list the
`Report` `zui_app` started with. Its theme does not reload there, since
raylib's host has no file watch. The tour's headless test opened the
panel with F12 over the Classic screen and checked it lists the frame's
elements with every limit held.

Measured: `core/src/` gained only `Frame.inspect`, which no frame calls, so
no hot path or instruction count moved. The hidden demo drew 480 frames
across every screen with the panel open, every limit held; the panel
lists a row per element, so a Box Storm raised to 14,000 boxes would
exceed `max_elements` with it open and say so in its diagnostics. The
idle budget was not measured again, since the machine was not in
benchmarking mode; a closed panel adds one branch per frame.

### G5. Materials

**Plan.** The decoration's `material`, typed by the renderer's
`MaterialHandle`, emitted in place of the background and lowered to it.
**Done when:** snapshot and lowering tests; the renderer suite's
reference scene declares it, and one renderer that declares the command
passes the suite; `counts` moves no scene beyond the noise.

`style.DecorationWith(MaterialHandle)`, `StyleWith` and `ElementWith`
make a context's types, `Ui.Decoration`, `Ui.Style` and `Ui.Element`,
identical to `zui.Decoration`, `zui.Style` and `zui.Element` when the
handle is `void` (`7af04c6`). A decoration with a material is kept even
without a background, and emission draws the `material` command over
the shadow and backdrop blur and under the gradient, its fallback the
background or transparent; for a renderer without `.material` it draws
the background and lists `.material` in `Diagnostics.lowered`.
`core/src/tests/materials.zig` tests both ways, a static style's material and
the order; snapshots write a material. The renderer suite's reference
scene declares a material when the harness gives one
(`harness.material(color)`), and its pixel renderer passes drawing it
and with it lowered, and fails drawing the fallback in its place.

The sokol renderer (`5903f48`) declares it with
`zui_sokol.Material`, a pattern between two colors (`solid`, `sheen`,
`aurora`) moved by a phase the application turns, and passes the suite
on Linux with `Material.solid` drawn through its shader, in a frame that
also blurs a backdrop. sokol_gl takes no shader of its own, so a
material is a triangle fan drawn with sokol_gfx at the start of its own
layer, before that layer's sokol_gl shapes; the shader is written in
GLSL and checked in as sokol-shdc's translation to GLSL 410, HLSL 5 and
Metal. Its tour gains a Materials screen: a card drawn by the shader
with every field on a slider, each pattern, a material beside its
fallback, and a shadow beneath one with a border and button over it.
The tour's helpers that build elements now name `Ui.Element`.

Measured: `counts` against `613760e` moved one scene, the documents
view's declaration, by 40 instructions (30,527 to 30,567, +0.13%), every
other scene and phase unchanged; `materialOf` is `inline`, since out of
line its `null` for a `void` handle was not folded and declaration grew
up to 6.3%. The sokol renderer's Materials screen held 144 fps at 144 Hz on
Linux, its "sokol submit" reading 2.3 ms in one sample; the GPU's cost
is not timed.

Not done: the sokol renderer's material has been drawn only with OpenGL;
its HLSL and Metal are sokol-shdc's and compile only when the tour runs
on Windows or macOS. The raylib and terminal renderers draw the fallback.

**Spec.** §10.1, §13.1, §13.3.

### G3. Transforms

**Plan.** Transforms applied when painting only; hit testing inverts
them.
**Done when:** snapshot and lowering tests; the renderer suite's
reference scene declares it, and one renderer that declares the command
passes the suite; an interaction test clicks a rotated button.

`Effects.transform` (`zui.Transform`, its `affine(bounds)` and
`zui.Affine`) is emitted as `transform_begin` before the element's
shadow and `transform_end` after its subtree and clip, begun again on a
floating element's own layer, culled through the box around the clip in
the element's units, and lowered to the element as laid out, listed in
`Diagnostics.lowered` (`592e305`). Each transformed element enters a
space in the hit results, and every hit test goes through
`Results.hits`, which maps the pointer into the region's space and
checks the clip around each transform. `core/src/tests/transforms.zig` clicks
a rotated button where it is drawn and not where it was laid out, and
through nested transforms up to the clip around them. `checkCommands`
checks transforms and clips nest; snapshots write a transform's fields.
The renderer suite's reference scene turns a box of two halves a
quarter, and its pixel renderer passes drawing it and with it lowered,
and fails turning it the wrong way; the raylib and terminal renderers
pass it lowered.

The sokol renderer (`f153f57`) declares it and passes the
suite on Linux, read back by `glReadPixels`. Each `transform_begin`
composes its affine with those around it and loads the result as
sokol_gl's modelview matrix, which sokol_gl bakes into each draw, so it
holds across the layers paint order needs. sokol's built-in bitmap text
has no matrix, so bitmap text inside a transform is drawn as sokol_gl quads
from a texture of its own font bits. A clip inside a transform is
scissored to the box around it in the window, and a backdrop blur inside
one blurs that box and samples each vertex where it is drawn. Its tour
gains a Transforms screen: a card turned, moved and scaled from sliders
and pressed where it is drawn, turned tiles, clock hands turned about
their foot, and sokol's six built-in bitmap fonts turned.

Measured: against `cceecfa`, `counts` moved no declaration and every
`endFrame` by −0.04% to −0.39%; `bench-compare`, turbo off, called no
frame scene slower and `init` 2.9% slower (+1.0% to +6.6%), `Effects`
having grown 32 bytes for each of its 256 copies a frame. The sokol renderer's
Transforms screen held 144 fps at 144 Hz on Linux, its "sokol submit"
reading 2.8 ms in one sample; the GPU's cost is not timed.

Not done: a pan or wheel over a transformed scroll container moves it
along the window's axes, and `Drag` and the pointer events report window
units; SPEC.md does not yet say which units they take inside a
transform. The sokol renderer cuts a clip inside a turned transform to the box
around it, since a scissor is upright; a stencil would cut it exactly.
The raylib and terminal renderers draw the element as laid out.

**Spec.** §13.1, §13.3, §16.4.

### G7. Effects in the corners of a decoration that draws nothing

**Plan.** Keep the decoration of an element that declares effects even
when it draws nothing itself, declared or through a static style, and
every other decoration as before.
**Done when:** a test finds the radius on each effect's command and its
lowered form, both ways; `counts` moves no scene by more than the noise;
the sokol renderer's tour, on the fix, shows the card and the pane rounded.

Declaration stored a decoration only when it had a background or a
border, so an element with a corner radius and effects alone drew them
square; G2 found it on the sokol renderer's tour. It now keeps the decoration
whenever the element declares effects (`keepsDecoration`, `62a21d2`),
and emission draws nothing for it but the effects' corners. Two tests in
`core/src/tests/effects.zig` find the radius on the `shadow`,
`backdrop_blur` and `gradient` commands and on the lowered rectangles,
declared and static, and fail without the fix. The sokol renderer
(`6dbf06d`) draws the Light & Depth card's gradient and shadow
and the frosted pane rounded.

Measured: `counts` against the parent moved one scene, which declares no
effects: the documents view's declaration ran 40 fewer instructions
(30,567 to 30,527, −0.13%), the code generated for declaration having
changed; every other scene and phase was unchanged.

**Spec.** §13.1.

### G2. Backdrop blur

**Plan.** Backdrop blur of zui's own content, lowered to a tint.
**Done when:** snapshot and lowering tests; the renderer suite's
reference scene declares it, and one renderer that declares the command
passes the suite.

`Effects.backdrop_blur` (`zui.BackdropBlur`, a radius as CSS's standard
deviation and one tint) is emitted over the shadow and under the
background, in the decoration's corners, culled with its element, and
lowered to a rectangle in its tint, listed in `Diagnostics.lowered`
(`43e3d8f`). The renderer suite's viewport is 320 by 192 for a third
row: a blur floating over eight stripes, which a declared blur averages
under its tint and a lowered one tints stripe by stripe; its pixel
renderer passes both ways, box-averaging, and fails tinting without
blurring. The raylib and terminal renderers pass it lowered.

The sokol renderer (`d738cdc`) declares it and passes the
suite on Windows, read back by `glReadPixels`, and fails it drawing only
the tint. A frame with a blur is drawn into an offscreen target made
like the swapchain, so sokol_gl's pipelines and those of sokol's built-in
bitmap text draw into it unchanged, and copied to the swapchain at the end; at each blur
the scene's pass ends, a Gaussian runs along x then y into two RGBA16F
targets, its neighbouring pixels paired into one filtered sample and the
element's edge pixels repeated, and the pass resumes with the result
inside the rounded outline and the tint over it. sokol_gl's vertex
colors are 8-bit, so each weight is drawn as a coarse part and a
remainder scaled by a pipeline's fixed blend color of 1/255, which sums
the widest blur's weights to one within a quarter of a color step. A
frame without a blur is drawn as before. Its tour shows a frosted pane
drifting over the Light & Depth card, and on D3D11 the title under it
blurs in place, not mirrored.

Measured: the core's `counts` were unchanged in every scene, and
`bench-compare`, turbo off, called the box trees' `endFrame` 0.8% to
1.3% slower in the same instructions and simulated misses, `Effects`
having grown 12 bytes; moving the effects' storage last instead made
declaration 1% to 5% slower in most scenes, so it stays where G1 put it.
In the sokol renderer, one D3D11 sample of the Light & Depth screen at 144 Hz
reads "sokol submit" 5.7 ms against 3.9 ms before, both holding 141 to
144 fps; the GPU's cost is not timed.

Found on the way: an element whose decoration has a corner radius but
no background or border keeps no decoration (`core/src/context.zig:1223`,
`drawnDecoration`), so its effects are drawn square. Both the tour's
gradient card (G1) and its frosted pane show it; it is in ARCHITECTURE.md
§7, and G7 fixes it.

Not done: the raylib and terminal renderers draw the tint alone. The sokol renderer
stops a blur's standard deviation at about 42 physical pixels (129 taps
per axis) and a frame at 16 blurs, drawing the rest as their tint and
counting them in `Renderer.backdrop_blurs.lowered`; downsampling would
lift the first.

**Spec.** §13.1, §13.3, §16.4.

### G1. Gradients, shadows and glow

**Plan.** Gradients and shadows as optional commands, interpolated in
OKLab, declared by elements and lowered for renderers that do not draw
them. **Done when:** snapshot and lowering tests; the renderer suite's
reference scene declares both, and one renderer that declares the
commands passes the suite.

Elements declare `.effects = &zui.Effects{ .gradient, .shadow }`, a
pointer copied when declared; emission paints shadow, background,
gradient, culls a shadow by what it paints, and for a renderer that does
not declare them lowers a gradient to its OKLab middle and a shadow to
nothing, listing both in `Diagnostics.lowered`. `limits.max_effects`
(256) bounds their copies. The renderer suite's reference scene declares
both; its pixel renderer passes it drawing them and with them lowered,
and fails it interpolating in sRGB.

The sokol renderer (`c5b5de4`) declares both and passes the
suite on Linux, read back by `glReadPixels`: a gradient in bands at most
4 units long, each vertex its OKLab `colorAt`, so sokol_gl's sRGB blend
between vertices stays within a step of it; a shadow as its box at the
offset grown by the spread, then six rings fading out to the blur. Its
tour shows them on a Light & Depth screen.

Against `c7810b7`, `counts` moves no scene by more than +0.77% (the
tooltip grids' `endFrame`) and no declaration at all; `bench-compare`,
turbo off, calls ten scenes faster (the documents view's declaration
−10.3%, the others −0.9% to −3.0%), none of the frame scenes slower, and
`init` +1.5% and the documents view's first frame +1.6% for the effects'
storage. One shadowed element makes the box tree's `endFrame` 3.1% more
instructions, the walk that looks for them.

Found on the way, each against the parent by `counts`: `Element.effects`
as a value made the interactive boxes' declaration 22% slower; a
`Style.effects` cost the static box tree's declaration 3.5%; one compare
added to the walk moved `endFrame` by up to 3.5%, and a second
instantiation of the walk stopped `emitText`, `floatingLayer` and
`sortLayers` being inlined, 4%; storage for every element made `init`
21% slower.

Not done: the raylib and terminal renderers still draw the lowered forms.

**Spec.** §13.1, §13.3, §16.4.

### P10. The string cache's keys apart from its values

**Grounding.** Under Callgrind's cache simulation, 39% of cold text's
simulated D1 read misses in `endFrame` (67,646 of 174,532 over 10
frames), and 34% of new strings', fell on one line: the string cache's
probe in `lookupOrClaim`. A text it has not seen walks the whole probe
window for the least recently used entry, and every step lands on a
different 112-byte entry, about 7 misses a text.

**Plan.** Keys and ages in arrays of their own. **Done when:** the cold
scenes are faster by `bench-compare`, warm text no slower.

`LruTable` takes a `KeyLayout`: the string cache keeps its keys and ages
apart from its values, so a window's 8 keys share one or two lines; the
segment cache, probed once a word and hit on its first step, keeps each
key with its 8-byte value, which a hit reads in one line.

`zig build bench-compare -- 5d2eb30` (100 rounds over 3 layouts, turbo
off, pinned): cold text −2.0% (265.2 to 260.0 µs), warm text −1.2% (69.7
to 68.9 µs), single-line texts −1.1%, `init` −11.9% (104.9 to 91.8 µs),
whose reset now walks 8 KiB of keys rather than every entry,
`initBuffer` −1.3%; nothing slower. This wins back what P9 cost cold
text and `init`. `zig build counts`: the cold scenes' `endFrame` −0.7%
instructions with 17.4% fewer simulated D1 misses; warm text's has 5.4%
more, from its key and its value now on two lines.

Tried and dropped: **both tables split:** +6% to +7% instructions in the
cold scenes, from three addresses to work out at each of the segment
cache's probes, once a word. Not tried: prefetching the next texts'
keys, which the audit also proposed.

**Spec.** §9.3.

### P9. Wrapped lines kept with the string cache

**Grounding.** `wrapTexts` wrapped every text wider than its box from its
bytes every frame, though a warm hit in the string cache already proved
the text unchanged. Under Callgrind, `wrapTexts` was 47% of warm text's
`endFrame`.

**Plan.** Keep the lines of a text's last wrap beside its cache entry.
**Done when:** warm text is faster by `bench-compare`, cold text no
slower, and the string cache's growth is recorded.

`measureText` now writes the metrics into the text's record and returns
the index of its string's entry, or `new_string` for a string it had to
measure; the record keeps the index in what was padding, so it stays 64
bytes. `wrapTexts` writes a text that fits on one line itself, without
calling into the wrap. A text that wraps first looks at its entry: if
the entry was last wrapped at exactly this width, its lines are copied
and nothing is measured or walked. Otherwise the text is wrapped and,
for a string found rather than measured, its lines kept when there are at
most 4 of a text under 64 KiB. Lines are kept in an array beside the
entries, so a frame that only measures never touches them. An entry
records the generation it was measured in, so a text whose entry another
string takes later in the same frame neither reuses nor keeps lines
there.

The string cache grows by 8 bytes an entry and 36 bytes of lines an entry,
44 KiB at the default 1,024 entries; SPEC.md §20.2 has no memory budget.

`zig build bench-compare -- adc5677` (100 rounds over 3 layouts, turbo
off, pinned): warm text −43.4% (123.0 to 69.6 µs), the documents view
−12.5%, single-line texts −9.7% (60.8 to 54.9 µs), depth 64 −1.7%. Slower:
`init` +3.4% (101.6 to 105.2 µs) and `initBuffer` +1.5% (8.4 to 8.5 µs),
from the larger cache; cold text +0.7% (263.2 to 265.3 µs); new strings
+0.3%, within noise. `zig build counts`: warm text's `endFrame` −36.8%,
single-line −7.1%, documents view −11.9%; cold text +1.4% and new strings
+1.3%, for the index and the two fields of every string they measure.

Tried and dropped:
- **looking the string up again by its key in `wrapTexts`,** with an
  8-byte key in the record: cold text +7.6% instructions;
- **one flag for a frame in which any entry in use was given up:** the
  warm text wall fills 98% of the cache, so the flag was set every frame
  and nothing was reused;
- **a 4-byte index in the record,** which made it 68 bytes: +2
  instructions a text in declaration.

**Spec.** §9.3.

### P8. One hit test per press

**Grounding.** A primary `pointer_down` ran `Results.topmostAt` in
`refreshHover`, `longPressOwner` and `recognizerAt`, and `startZoom` a
fourth time when another contact was down, each at the same point over
the same results.

**Plan.** Hit-test once per press. **Done when:** `4096 interactive,
pressed` runs fewer instructions in its declaration by `counts`, and no
scenario is slower.

The press hit-tests once and hands the region to the four; a move, a
release and the wheel still hit-test for themselves. `zig build counts`
against `b0106bd`: `4096 interactive, pressed` declares in 2.6% fewer
instructions (1,303,365 to 1,269,280, `beginFrame`'s events included),
with 10.3% fewer simulated D1 misses; nothing else changed.
`zig build bench-compare -- b0106bd` calls nothing faster or slower: the
scene presses on every other frame, and `bench` keeps each scene's
fastest frame, which is always a release, so the clock cannot see a
press. `4096 interactive, clicked every frame` was added after it to
time one: with that scene on both, `bench-compare` (100 rounds over 3
layouts, turbo off) times its declaration 3.9% faster (137.3 µs to
131.9 µs, 95% interval −4.5% to −3.1%) and calls nothing slower.

**Spec.** §11.

### P7. A narrow id → rect table

**Grounding.** `Results.entries` was `nextPowerOfTwo(2 × max_elements)`
slots of 32 bytes, 256 KiB at the default limits, written at random once
per element with an id and read by `widgetState`, `rectOf`, coasting and
zoom; `regionFlags` then read the region as well.

**Plan.** Slots that index dense entries. **Done when:** the interactive
scenes are faster by `bench-compare`, and no scenario slower.

Each slot now holds the smallest index type into `entries`, which are
dense in emission order: 16 KiB of slots at the default limits, 2 bytes
each. `slot_of_entry` keeps the slot each entry took, so `clear` empties
only those, and each entry carries its region's flags in what was its
padding, so `widgetState` reads no region. `Results` is 96 KiB smaller.

`zig build bench-compare -- d0809fd` (100 rounds over 3 layouts, turbo
off, pinned): `4096 interactive boxes` −5.9% (191.5 to 179.0 µs) and its
declaration −7.2% (124.8 to 115.2 µs); pressed −5.7% and −8.5%; `init`
−26.9% (138.3 to 101.0 µs) and `initBuffer` −50.5% (17.0 to 8.4 µs), which
empty the smaller table; nothing slower. `zig build counts`: the
interactive scenes' `endFrame` +1.3% instructions, with 3.1% fewer
simulated D1 misses, and their declaration −0.3%, with 3.2% to 4.1% fewer.

**Spec.** §5, §11.

### P6. The layer sort

**Grounding.** Any frame with a floating element ran `std.sort.block`
over all its 80-byte commands. With a tooltip declared before a 3,000-cell
grid, `endFrame` took 670.9 µs, against 81.3 µs declared after it.

**Plan.** Sort only what is out of place. **Done when:** both tooltip
scenes are faster by `bench-compare`, and no scenario is slower.

A frame's commands change layer only where emission enters a floating
element or leaves one, so the emitter records each run of commands
outside layer 0 there, and `push` is unchanged. After emission, the runs
are gathered into the unused end of the commands; layer 0's commands
close up behind them, each moving at most once and not at all when no
run comes before them; the gathered runs are sorted only if their layers
were emitted out of order, and copied back in place, the layers below 0
rotated in front. Past 64 runs, or without room at the end, the whole
frame is sorted as before. The `sort_layers` zone now runs when a frame
draws outside layer 0, not when it merely declares a floating element.

`zig build bench-compare -- fb3c7bd` (100 rounds over 3 layouts, turbo
off, pinned): tooltip first −88.2% (671.0 to 79.4 µs), tooltip last
−9.8% (81.3 to 73.4 µs); nothing slower. `zig build counts`: tooltip
first's `endFrame` −86.4% (5,853,440 to 798,765 instructions), tooltip
last's −7.6%; the other scenes' `endFrame` +0.1% to +1.0%, from the layer
check when a level ends.

Tried and dropped, each measured by `counts`:
- **layered commands written backwards from the end in `push`,** as the
  audit sketched: up to +2.9% instructions in scenes with no floating
  element, as `push` choosing between two destinations kept LLVM from
  building each command in place;
- **one cursor and step in `push`, switched out of line:** up to +5.5%,
  from the call on its path;
- **the level's clip and layer endings in one packed byte:** up to
  +3.7%.

**Spec.** §16 (the tracer's zones), §17.2.

### R8. Simulated cache and branch misses in `counts`

**Grounding.** Instruction counts cannot see a change to memory layout,
which is most of what the audit proposed.

**Plan.** Callgrind's cache and branch simulation under a fixed cache
geometry, its misses informational. **Done when:** two CI runs give
identical miss counts, and the job stays within 10 minutes.

`counts` runs Callgrind with `--cache-sim=yes --branch-sim=yes` and a
fixed 32 KiB 8-way I1 and D1 and an 8 MiB 16-way LL, so the misses do not
depend on the host. Each `"<scene>, <phase>"` instruction key gains
`I1 misses`, `D1 misses`, `LL misses` and `branch misses`; only the
instructions fail `--compare`. Every instruction count moved by 7 to 13
a frame (at most −0.06%).

The first two CI runs agreed on every count but 21 of 30 D1 misses, by up
to 0.8%: the simulated cache sees real addresses, and the environment and
the executable's path are copied onto the initial stack. Each child now
runs as `./zui-counts` from its own directory with an empty environment
(`9d0ddac`), and two CI runs then agreed on all 150 counts, in 2.5 to 5
minutes. This machine still differs from CI on 15 D1 counts by a few
misses, through Valgrind's version and its preload path; CI only ever
compares with CI.

**Spec.** §20.3.

### R7. Code and memory layout as a random factor

**Grounding.** In T4, warm text ran the same instructions as `c5b0401`,
with the same simulated misses, and measured +7.8%: Mytkowicz et al.'s
layout bias, which one build per commit treats as the truth.

**Plan.** Seeds that move the stack, the `Context`'s memory and the
code, with the rounds taking turns over several. **Done when:** a change
that only moves code is reported as within noise.

`ZUI_BENCH_LAYOUT_SEED` moves the stack down by up to 4 KiB in steps of
64 bytes and starts each `Context` at a multiple of 128 bytes inside an
allocation 4 KiB larger. `-Dbench-layout-seed` moves every function by
up to 4080 bytes in steps of 16, through module assembly LLVM emits
before any function (`nm`: exactly +48 and +1040 bytes). `bench-compare
--layouts <k>` (3) picks fresh seeds per comparison, builds each side
once per layout, all builds at once, and on Linux adds 0 to 4 KiB of
environment padding; the bootstrap resamples layouts, then rounds.

T4's variant was never committed, so the case was built: a commit that
only pads the code by 864 bytes. Run directly, four code shifts moved
static-styled boxes from 103.9 to 107.8 µs, against 1.3% between repeats.
With `--layouts 1`, `bench-compare` called eight changes, static-styled
boxes +2.6% (+2.5% to +2.7%); with 3 layouts it called none (−1.0%, −2.7%
to +2.7%), in 364 s with twelve builds. A commit against itself over 3
layouts calls nothing, its intervals 0.52% wide on average. The price is
honest width: in the layout-sensitive scenes, a real change under about
2% is no longer called.

**Spec.** §20.3.

### R6. Hardware counters per phase

**Plan.** Cycles, instructions, branch misses, L1D read misses and
last-level misses for each phase, through `perf_event_open`. **Done
when:** on bare-metal Linux, cycles compared with themselves give a noise
band well under nanoseconds'.

`bench --counters` opens one group of the five events, user mode only,
refuses multiplexed counts, and keeps each event's fewest per frame
under keys beside the times; `bench-compare --metric
cycles|instructions` compares them. The box tree's declaration: 440,424
instructions in 216,504 cycles, 58.5 µs at 3.7 GHz against 58.7 µs
timed.

Closed by the owner without the gain the *Done when* expected. With
turbo off, cycles and nanoseconds are one measurement. With turbo on
(`abd12ce` against itself, 100 rounds over 3 layouts), the intervals
reached a median 0.30% from no change in both: each time is a pinned
run's fastest frame, which runs at the top clock either way. The counters
stay for explaining a change, since instructions against cycles tells
more work from more waiting, and nanoseconds stay the default.

Not built: reading the counters through `rdpmc`, which matters less than
planned, since user-mode counting already leaves the `ioctl`s out.

**Spec.** §20.3.

### R5. Each scenario on its own, in a shuffled order

**Plan.** `bench --scenario <name>` and `--order-seed <n>`, and
`bench-compare` running one scenario at a time from each side's
installed benchmark, in a new order every round. **Done when:** a commit
compared with itself calls nothing.

`bench --list-scenarios` names each scenario as compared, reported or
startup; startup scenarios always run last, since their page faults are
part of what they time. `zig build bench-install` installs the
benchmark. When both sides support it, each round runs one scenario at a
time, alternating which side goes first; an older base keeps the
whole-run alternation. `4294abe` against itself (100 rounds, turbo on,
pinned) called nothing. The report still lists times in the first
round's order, not the table's.

**Spec.** §20.3.

### R4. Confidence intervals and a measured noise floor

**Grounding.** R2's middle half of 10 ratios is no confidence interval,
and its 2% threshold was set by hand once.

**Plan.** A bootstrap interval of the median ratio, a noise band
measured per machine, rounds until the interval is narrow enough.
**Done when:** a commit compared with itself gives intervals that all
contain zero, and R2's store-forwarding stall is still called faster.

`core/bench/statistics.zig` holds the bootstrap (a fixed seed, 10,000
resamples, two-stage for R7's layouts) and a test for two clusters of
frames, which `bench` warns about, beside each phase's p95.
`bench-compare --calibrate` compares a commit with itself and saves each
time's band by machine fingerprint; without one, a band is 2%. A change
is called only when its whole interval lies beyond its band. Rounds
continue until each interval is under `--target-width` (1%) or
`--time-budget` (420 s) is spent. `bench --compare` is removed.

`--calibrate` at `468ffc8` (61 rounds, turbo on, pinned) called nothing,
with bands of 0.5% to 0.9%; 29 of 30 intervals contained zero. `946405e~1`
to `946405e` is still called faster: the box tree's declaration −27.4%
(−27.5% to −27.4%). On Windows the 0.1 µs clock keeps small scenes'
intervals in whole steps, so rounds there rarely stop early.

**Spec.** §20.3.

### R3. Pinned runs, with the machine's state recorded

**Plan.** `bench --core <n>` pins to one core at a raised priority and
`--machine-json` records the machine; `bench-compare` builds unpinned,
then pins itself, records the state before every run, and warns when it
changes. **Done when:** a commit compared with itself, pinned and with
turbo off, is narrower than unpinned.

`core/bench/machine.zig` reads the power plan, `PROCTHROTTLEMAX`,
`PERFBOOSTMODE` and the clock on Windows, and the governor, turbo, the
core's siblings and `randomize_va_space` on Linux. `--require-quiet`
refuses to run with turbo on or another governor. README's *Quieting the
machine* gives the setup. On the i9-10900K under bare-metal Linux with
turbo off, `f099fd1` against itself over 10 rounds: intervals 1.74% wide
on average pinned (median 0.80%), against 10.65% unpinned (median
5.25%, widest 78.7%); the clock read 3699 to 3700 MHz pinned. Windows
reports the base clock as the current one, so it cannot show boosting.

**Spec.** §20.3.

### I1. Drag and drop between elements

**Grounding.** I5 arbitrates every pointer by motion component past the
touch slop (`core/src/context.zig`, `pan` and `panOwner`), and `Gestures` had
two spare bits; SPEC.md §11.5 named `dragging`, `dropped` and `startDrag`
and the payload's place in the state table, but no element could declare
`drag`.

**Plan.** `dragging`, `dropped` and `startDrag`, with typed payloads in
the state table, arbitrated by I5.

**Done when:** `zui_testing.Driver.drag` moves an item between two lists,
including out of a list that scrolls by dragging.

**Spec.** §11.5.

**Status.** Done, in one commit. `Gestures.drag` makes an element a drag
source: past the touch slop it takes the pointer on the axes no region
around it pans on for that pointer, after any region inside it that pans
on the axis, so a card in a list that scrolls vertically drags sideways
and scrolls the list vertically, and with the mouse, which scrolls a list
with its wheel, drags on both axes. The source is then neither pressed
by another element, clicked, scrolled nor zoomed. `ui.dragging(id)`
returns a `zui.Drag`: the pointer, its position and its translation from
the press. `ui.startDrag(id, payload)` keeps the payload in the state
table under the source as a type of its own, `DragPayload(T)`, so it never
shares a slot with the application's state of `T`; called on a source
whose press is still down but that nothing drags, it starts the drag
there, taking the pointer from any pan, zoom or recognizer, which lifts a
card after a long press. While a drag lasts, `beginFrame` touches its
payload's slot through `StateTable.touch`, behind a flag, so the source
may go undeclared. `ui.dropped(id, Payload)` and `ui.draggedOver(id,
Payload)` answer for every region the hit test at the pointer passes
through, and only for the payload's own type. `draggedOver` was added to
SPEC.md §11.5, since a target needs to show it would take a drag before
the release and touch has no hover. The four need `features.gestures`,
and `dropped` without it fails with
`"zui: dropped() needs Config.features.gestures = true"`; a payload above
64 bytes fails with the state table's message, naming the payload's type.

Tests: in the core, a card dragged sideways out of a list that scrolls by
touch, over the other list (`draggedOver`) and dropped on it; a vertical
drag on a card scrolling its list, and a tap clicking one; the mouse
dragging a card on either axis; a drop yielding its payload to the list
and the card under it and null to other types and lists; a drag released
in the record that started it and a cancelled one dropping nothing; a
payload given once outliving ten frames in which its source is not
declared; a long press and `startDrag` lifting a card that then drags
along its list. In `zui_testing`, `Driver.drag` scrolling a list that
declares `.pan = .vertical`, then moving an item out of it into a second
list and another back, the dragged item drawn as a floating element with
`capture = false`.

`zig build counts` against `8d75b8d`, in a local Docker container: with
the feature off, every scenario within −4 to 0 instructions; with it on,
as the benchmarks run, every declaration within +2 and every `endFrame`
unchanged. `zig build bench -- --check-targets`, over four runs, met every budget
in the last three: the box tree declares in 51.6 to 52.1 µs and lays out
and emits in 92.2 to 92.8 µs, warm text in 90.9 to 97.3 µs; the first,
right after the build, missed the declaration budget at 68.0 µs, as first
runs here often do. The 32-bit tests (`-Dtarget=x86-linux`) pass in the
Linux container.

### I5. Gestures: arbitration, intents, momentum, custom recognizers

**Grounding.**
- The slider drags with `pressed` and `pointerLocal`
  (`core/zui_widgets/zui_widgets.zig:290`); drag-to-scroll and drag and drop
  want the same pointer, and nothing decides between them.
- Routing by gesture kind fails: a vertical drag on a horizontal carousel
  inside a vertical list goes to the carousel, and a pinch that starts on
  a list inside a map goes to the list.

**Plan.** As SPEC.md §11.3–§11.4: accepted gestures in hit regions, one
rule by motion component, opt-in delays, intents, momentum in the state
table, and custom recognizers over `pointerEvents`, `claim` and
`decline`. All of it behind `features.gestures`, which C7 added with
`manipulation`, gated and null until this item fills it; each new
gesture query is gated the same way, and `Element.gestures` is ignored
without it, so that widgets declare gestures for every context.

**Done when:** interaction tests cover a button in a list in a zoomable
map, a carousel in a vertical list, a pinch that starts on the list, a
slider in a drag-scrolled list, a long press, a double tap next to a
single tap, a flick within one frame, and a lasso written as a module
function against the map's pan; and with the feature off, R1 counts are
unchanged.

**Spec.** §11.3, §11.4.

**Status.** Done, in five slices, each with its tests and with R1 counts
unchanged with the feature off:
1. *Pans* (done): `zui.Gestures` with `pan`, stored in hit regions;
   the one rule by motion component past the touch slop, with scroll
   chaining; scroll containers that pan by touch and pen; presses
   cancelled by a pan; `manipulation`'s translation from pans and the
   wheel; the slider keeping a horizontal drag.
2. *Zoom* (done): `zoom`, two-pointer scale, rotation and pivot to the
   innermost region that accepts it, and `Driver.pinch` (from I4): a
   button in a list in a zoomable map, a pinch that starts on the list.
3. *Timers and intents* (done): `long_press` and `double_tap` with their
   deadlines in `nextFrame` (from I2), `contextRequested`, a double-tap
   query, `dismissed`, `adjusted`, `navigated`: a long press, a double
   tap next to a single tap.
4. *Momentum* (done): velocity from the events' instants, momentum in the
   state table under the element, its deadline in `nextFrame`: a flick
   within one frame.
5. *Custom recognizers* (done): `custom`, `pointerEvents`, `claim` and
   `decline` (open decision 1): a lasso in a module against the map's
   pan.

Slice 1: the core's tests cover a carousel in a vertical list (a
vertical drag on it scrolls the list, a horizontal one the carousel), a
button in a list (a tap clicks, a drag scrolls the list and cancels the
press), a slider-like element that pans horizontally in a list, scroll
chaining at a carousel's end and a list's start, a mouse drag that does
not scroll a list while the wheel does, a map panning freely on both
axes with the mouse and the wheel, a button on the map, and a context
without the feature ignoring `Element.gestures`. `zui_widgets`' slider
declares `.pan = .horizontal`, tested in a list driven by
`Driver.dragFingers`. `zig build counts` against `397ce28`, in a local
Docker container: with the feature off, every scenario within ±2
instructions; with it on, as the benchmarks run, the same, but for the
documents view, whose interactive elements store their gestures:
declaration +0.38% (33,320 to 33,447) and `endFrame` +0.49% (61,189 to
61,489). `zig build bench -- --check-targets` meets every budget over
three runs: the box tree declares in 50.4 to 51.0 µs and lays out and
emits in 93.4 to 94.7 µs, warm text in 100.9 to 101.5 µs, on the
instructions it had before. The 32-bit tests (`-Dtarget=x86-linux`) run
in the Linux container, since Windows cannot execute them.

Slice 2: a second pointer pressed while another is down, both inside an
element that accepts `zoom`, makes the two zoom the innermost such
element, taking both from whatever else they pressed or panned, so a
pinch that starts on a list in a map zooms the map even after the first
finger began scrolling the list. Each move adds the change in the two
pointers' centroid to `translation`, multiplies `scale` by the change in
their distance and adds the change in their angle to `rotation`
(clockwise on screen), with `pivot` where the centroid ended; when one
lifts, the other goes on panning the element if it pans. Tests: a button
in a list in a zoomable map (a tap clicks it, a vertical drag scrolls
the list, a horizontal one pans the map, a pinch over it zooms the map
and neither presses nor clicks it), a pinch that starts on the list, a
rotation by a quarter turn, two pointers on elements that do not zoom
each panning their own, and `zui_testing.Driver.pinch`, which I4 left
waiting. `zig build counts` against `397ce28`: the same as slice 1, with
the feature off and on, since only input changed.

Slice 3: a press on an element with `long_press`, held within the slop
for 0.5 s, is `contextRequested` and not a tap, fired by the first frame
whose `now` reaches it (or by a release that comes later, in the same
record), with that instant as the next frame's deadline. A tap on an
element with `double_tap` waits 0.3 s from its release: a second tap in
time is `doubleTapped`, and otherwise the first is `clicked` in the
frame that reaches the deadline, which `nextFrame` asks for. The other
intents: `contextRequested` from a right click and the menu key,
`dismissed` by Escape while the element or one in its focus scope is
focused, `adjusted` and `navigated` from the arrows on the focused
element. Only `doubleTapped` and `manipulation` need the feature, and
`doubleTapped` without it fails with
`"zui: doubleTapped() needs Config.features.gestures = true"`. Tests: a
long press firing once when due and not tapping, one released in the
frame it falls due, a short press tapping, a moved press not long
pressing; a double tap next to a single tap (one clicks at once, the
other once its window passes, a double tap is never clicked, a late
second tap is a click of its own); a right click, the menu key, Escape
in a dialog's scope, and the arrows. Looking for due timers at every
`beginFrame` cost depth 64's declaration 1.28%, so a flag says whether
any timer is armed. `zig build counts` against `397ce28`: with the
feature off, unchanged from slice 1; with it on, every declaration within
+8 instructions but the documents view's, +0.40% (33,453), and every
`endFrame` as in slice 1. `zig build bench -- --check-targets` meets every budget
over three runs: the box tree declares in 50.3 to 51.1 µs and lays out
and emits in 91.9 to 93.9 µs, warm text in 94.4 to 95.5 µs.

Slice 4: each pressed pointer keeps its last four positions with their
instants. A pan released faster than 50 units a second, over the samples
of the last 0.1 s, coasts on the axes it panned: `zui.Momentum` in the
state table under the element, slowing exponentially with a time
constant of 0.325 s and moved to each record's `now` before its events,
through the same path as a pan, so a scroll container scrolls and every
element reports a `manipulation`. It stops below 10 units a second, at
the end of a scroll container's content, when a pointer presses on it,
or when the element was not declared in the last frame; while it coasts,
`nextFrame` asks for a frame 1/120 s after `now`. Tests: a flick within
one frame (press, four moves and release 10 ms apart) scrolls a list by
the finger's 80 units, then coasts each frame by less, stopping after
about 2,000 units a second times 0.325 s; a slow release does not coast;
a press stops a coasting list; a flung map coasts as manipulations and
stops when it is no longer declared. `zig build counts` against
`397ce28`: with the feature off, unchanged; with it on, every declaration
within +16 instructions but the documents view's, +0.42% (33,461), and
every `endFrame` as in slice 1. `zig build bench -- --check-targets`, over four runs, met
every budget in the last three: the box tree declares in 51.0 to 51.3 µs
and lays out and emits in 91.1 to 92.0 µs, warm text in 98.2 to 98.4 µs;
the first, right after the build, ran every scenario slower alike and
missed the declaration budget at 68.8 µs, as first runs here often do.

Slice 5: an element that declares `custom` holds every pointer pressed on
it: no pan, zoom or long press of its own or its ancestors' starts while
it is undecided, and `ui.pointerEvents(id)` returns the frame's events of
those pointers, in order, through a `zui.PointerEvents` iterator.
`ui.claim(pointer)` makes the pointer the recognizer's alone from the
next `beginFrame`, taking its press from whatever it pressed;
`ui.decline(pointer)` gives it back, and that `beginFrame` arbitrates it
over all its motion since the press, so nothing moved meanwhile is lost.
A pointer released undecided is a tap. Open decision 1, that a decision
lands a frame late, is taken as planned: the lasso scene passes with it,
the finger's pan arriving whole one frame after its press. The lasso is
`zui_widgets`' `lasso(ui, id, &path)`, written on the public API alone: a
pen pressed on the element draws a `zui_widgets.Lasso` path in the
application's memory, and every other pointer is declined, so fingers
pan and zoom the map. `pointerEvents` without the feature fails with
`"zui: pointerEvents() needs Config.features.gestures = true"`. Tests: a
lasso drawn by a pen over a map that does not move, then a finger that
pans the map by its whole motion; in the core, a recognizer holding a
list off until it declines and the list then scrolling by everything
the pointer moved, a claimed pointer taking a button's press and never
scrolling the list, and a pointer released undecided tapping. Looking at
every contact at each `beginFrame` cost depth 64's declaration 0.79%, so
a flag says whether a decision is waiting. `zig build counts` against
`397ce28`: with the feature off, every scenario within ±2 instructions,
as for every slice; with it on, every declaration within +19 instructions
but the documents view's, +0.43% (33,320 to 33,464), every `endFrame`
within +2 but the documents view's, +0.49% (61,189 to 61,489).
`zig build bench -- --check-targets` meets every budget over four runs:
the box tree declares in 51.1 to 52.4 µs and lays out and emits in 92.5
to 93.6 µs, warm text in 91.1 to 92.6 µs.

The whole item, by `zig build bench-compare -- 397ce28` (10 rounds):
layout and emission unchanged or faster (the box tree's −1.8%, single-line
text's −3.7%); declarations slower where they include `beginFrame` and
little else: warm and cold text's +5.6% and +5.2% (15.3 to 16.1 µs) on 19
more instructions of 106,521, the box tree's +1.9% on 102 fewer than
slice 3 had, the documents view's +3.0%; the documents view's first frame
+4.2%. Instruction counts, which do not move with code placement, are
within +0.02% for every declaration but the documents view's, so this is
where `beginFrame`'s code now lands, as T4 and L4 found for warm text,
not work added.

### C10. The backends draw images' tint and corner radius

**Grounding.** Since L3 the `image` command carries `tint` and
`corner_radius`, but the raylib renderer draws an image with its handle and bounds
alone (`renderers/raylib/src/root.zig:541`, `drawTexture(image.handle, bounds)`), and so
does the sokol renderer (`renderers/sokol/src/renderer.zig:185`); the terminal renderer has no images. The
renderer suite's reference scene declares an untinted, square image.

**Plan.** Each backend multiplies the tint into the image and rounds its
corners; the renderer suite's reference scene declares a tinted image
with a corner radius and checks a pixel inside it and one in a corner.

**Done when:** the raylib and sokol renderers pass the extended renderer suite
in CI.

**Spec.** §10.1, §13.1, §16.2.

**Status.** Done. The renderer suite's reference scene declares its image
with a tint, `0xffff80`, and corners rounded by 12 units, and checks the
pixel at its center for the image's color times the tint, `0x00ff80`, and
the pixels just inside its top-left and bottom-right corners for the
background behind it. A renderer that draws the image untinted, or that
replaces its pixels with the tint, is a whole channel off at the center;
one that draws it square fills the corners. `zui_testing`'s own software
renderer multiplies the tint and tests each pixel against the rounded
corners, and a flawed copy of it that draws images untinted and square
fails with
`drew #00ffff at (32, 112) in the reference scene, where a tinted image of one color should be #00ff80`.

The sokol renderer sets the tint as the vertex color, which sokol_gl multiplies
into each texel, and draws a rounded image as a fan of textured triangles
from its center over the outline its rounded rectangles already trace,
each corner with its own radius. raylib multiplies a texture by a tint
too, but cannot round one, so the raylib renderer draws a rounded image the same
way through rlgl, wound counter-clockwise on screen as raylib's culling
wants, with each corner's own radius, though its rectangles round all
four corners by the largest. A square image is drawn as before, one
quad, with the tint.

Neither renderer's code changes beyond drawing images, and the terminal
renderer, which has no images, does not change. The raylib renderer's
renderer and host suites and the sokol renderer's renderer suite pass
on Windows, and the raylib renderer's old drawing fails the extended
suite with the message above; CI runs the suites on Linux under
`xvfb-run`. The core is unchanged, so its instruction counts and times
are too.

### L7. Wrap

**Plan.** Wrapping for rows that opt in, compiled out without
`features.flex_wrap`, which C7 added; asking for it with the feature off
fails as a gated API does. **Done when:** golden tests for wrapping under
each alignment, and with the feature off, R1 counts are unchanged.
**Spec.** §8.1, §8.2.

A row wraps when `ui.wrapChildren()` is called after its `open`, not by
a `Layout.wrap` field as SPEC.md had it: a field's value is not known at
compile time, so it could not fail with
`"zui: wrapChildren() needs Config.features.flex_wrap = true"`, and
`Layout` has no byte free, so a field would make it 60 bytes, the size
that made the box tree's `endFrame` 6.7% slower in L2. The call sets an
element flag, the last free bit, and a column ignores it. SPEC.md §8.1
and §8.2 now say so, and that the work is spread over the existing
passes rather than in a pass of its own between distribution and
positioning, where a fit row's height could no longer follow its lines.

Pass 1 sizes a wrapping row from its children: as wide as one line, no
narrower than its widest child's minimum. Pass 2 breaks the children into
lines at the size each rule asks for before free space is handed out,
recording each line's first child in `Frame.starts_line`, an array that
is empty without the feature, then grows or shrinks each line as a row,
so a child wider than the row takes a line of its own and shrinks to it.
Pass 4 makes the row as tall as its lines, each as tall as its tallest
child and `child_gap` apart; pass 5 stretches a growing height to its
line; pass 6 places line by line, `child_alignment.y` placing the lines
as a group and each child in its line, `.x` each line along the row,
and reflects them when the row is mirrored. Dividers sit between the
children of a line, as tall as the line, and between the lines, across
the row. Each step is behind `features.flex_wrap` and out of line, so a
frame that does not wrap pays one flag test per parent, and nothing
without the feature.

Tests: every alignment of a two-line row, against the formula and once by
hand, and mirrored, the row reflected; growing children sharing each
line's free space; a text wider than the row on a line of its own,
wrapping; a fit row as wide as one line, narrowing in a narrower column;
a growing height stretched to its line; a floating child outside the
lines; a column that does not wrap; a gallery scrolling through its lines;
dividers in a line and between lines; and the compile error. The test
context turns the feature on, and the randomized trees wrap one container
in six, checking that each line fits unless it holds one child, leaves
space only when its growing children are at their max, and lies below
the one before, and still mirror exactly.

`zig build counts` against `0bd3ac2`, in a local Docker container, with
the feature off as in every benchmark: every declaration within ±2
instructions; warm text's `endFrame` unchanged (1,036,572), and every
other text scenario too; the box tree's −0.28% (1,261,249 to 1,257,778),
the documents view's −0.14%, 4,000 children's +0.06%, depth 64's −0.02%,
from `grow`, `growFromMin` and `shrink` taking the children to share
rather than the parent. Sharing the rest of distribution's steps with
the wrapping path had cost the box tree +1.47%, so `distribute` keeps
its own. `zig build bench-compare -- 0bd3ac2` (6 rounds): warm text's
`endFrame` −9.8% (101.4 to 91.4 µs) on the same instructions, back from
the drift of L2 to L6; the box tree's +1.3% and the static-styled tree's
+1.2%, on fewer instructions; none called slower. `zig build bench --
--check-targets`, over six runs, met every budget in five: the box tree
declares in 49.8 to 51.0 µs and lays out and emits in 93.6 to 95.0 µs,
warm text in 90.5 to 91.2 µs; one run's box-tree declaration came out at
65.3 µs, its other scenarios slower alike, on code this item does not
change.

### L6. Right-to-left layout

**Plan.** `Direction.right_to_left`, `Layout.mirrored`, and logical
padding, alignment and anchors, following the environment's direction.
**Done when:** golden tests mirror every alignment and anchor.
**Spec.** §8.1.

`Layout.mirrored` is `zui.Mirrored`, `.inherit`, `.yes` or `.no`: an
element is mirrored by its own, else by its parent's, and the root by the
environment's `direction`. A `?bool`, as SPEC.md had it, is two bytes and
would have made every `Layout` 60 bytes instead of 56, the size that made
the box tree's `endFrame` 6.7% slower in L2; SPEC.md §8.1 now says so.
`Direction` gains `right_to_left`, which reverses an element for its own
children alone, as CSS `row-reverse`, so in a mirrored element it flows
from the left. An element places its children from the right when it is
mirrored or `right_to_left`, not both: the position pass lays them out as
before, then reflects them across the parent's box, which carries the
padding (`left` is the start side), the alignment on both axes and the
scroll offset over with them, and a floating child's position across the
box it attaches to, which reflects its anchor, attach point and offset.
A mirrored text's `.start` and `.end` swap, in the text record, so the
text path does no work for it. A reversed scroll container's horizontal
offset grows to the left, and its region carries `scroll_x_reversed`, so
the wheel's physical delta moves it the way the pointer goes. Dividers
sit in the gap between two children whichever way they flow. Positions
and borders stay physical.

Nothing is paid for it in a frame that does not mirror. `Frame.may_mirror`
starts true only in a right-to-left environment; otherwise the position
pass looks at each parent's `direction` and `mirrored` and, at the first
that mirrors, starts again with a copy of the pass that works out each
element's `mirrored` and `reversed` flags. Detecting it at declaration
instead cost the static-styled tree's declaration 5.4% more instructions,
since a static style's layout is not folded there.

Tests: each of the nine alignments of a row and a column, with uneven
padding, mirrored by the environment, by an ancestor's `.mirrored = .yes`
and by the row's own `right_to_left`, is the left-to-right layout
reflected; and one by hand. Each of the 81 anchor and attach point pairs,
for a parent, the root and an element target, likewise, and a menu by
hand. A text's alignments; `.no` and `.yes` overriding the parent, and
`right_to_left` in a mirrored row flowing from the left; a mirrored
scroller starting at its right edge and following the wheel; a reversed
row's dividers; a frame that cannot mirror setting no flag. The
randomized trees declare `right_to_left` and `mirrored`, check that
children start inside the content box at the right for a reversed
parent, and 500 of them, laid out in a right-to-left environment, are the
left-to-right trees reflected, element by element.

`zig build counts` against `68545eb`, in a local Docker container: the
box tree's declaration +0.94% (436,051 to 440,150), one store per element
for the `mirrored` byte that was padding, and every other declaration
within +0.54%; the box tree's `endFrame` +0.82% (1,251,001 to 1,261,249)
and depth 64's +1.00%, from looking at each parent's `direction` and
`mirrored`; the documents view's +0.86%; warm text's +0.03% (1,036,264 to
1,036,572), and every other text scenario within +0.05%.
`zig build bench-compare -- 68545eb` (6 rounds): declarations −1.1% to
+0.3%; the box tree's `endFrame` +1.0%, the static-styled tree's +1.8%,
warm text's +1.5% (100.0 to 101.1 µs), with the same instructions but
308; called slower only depth 64's declaration, one step of its 0.1 µs
resolution, and `initBuffer`, a startup time this does not touch.
`zig build bench -- --check-targets` meets every budget, over three runs:
the box tree declares in 50.4 to 51.0 µs and lays out and emits in 92.1
to 93.2 µs, warm text in 101.3 to 101.7 µs.

### L4. Floating options

**Grounding.** Every floating element got a hit region, so a tooltip
blocked what was under it; floating elements always escaped their
ancestors' clip; a target declared after the floating element fell back
to the parent. **Plan.** `Floating.capture`, `Floating.clip`, and later
targets placed after pass 6. **Done when:** interaction, layer and golden
tests for each. **Spec.** §8.4.

`Floating.capture` (true) and `Floating.clip` (`.none`, or `.target`).
With `capture = false` a floating element has no hit region of its own,
so the pointer reaches what it covers, while interactive elements inside
it still take it. `.clip = .target` cuts it off where its target's
children are: as a child in the flow for `.parent`, by the element's own
clip within its ancestors' for an element (found by walking up from it,
bounded, since it is not on the stack of open levels), and by the
viewport for `.root`. That clip, merged with the element's own, is one
`clip_begin` pushed in its layer before it draws, since sorting moves the
layer away from its ancestors' clips; its region is cut off with it.
To end that one clip after the border, every border is now emitted
before its element's own `clip_end`: it lies in the element's box, so
its own clip leaves it whole, and SPEC.md §13.2 says so.

A floating element whose target is declared later is placed against its
parent in pass 6, then placed again with its subtree once the pass is
over, in declaration order, so nested floating elements, `.root` ones
included, end up against their own targets. A target inside the floating
element's own subtree, or an id no element has, falls back to the parent.
`capture` and `clip == .target` are copied into the element's flags at
declaration, so emission reads them without the floating config.

Tests: a menu attached to a later element, its child moved with it and a
`.root`-attached element inside it left in the corner; a later target in
a scrolled list followed where the scroll put it; a target inside the
subtree falling back to the parent; a floating element clipped to its
parent's clip, to a row of a scrolled list (with its own clip and border
in one clip pair) and to a target outside every clip; a tooltip with
`capture = false` passing the pointer to the button under it while a chip
inside it is hovered; a flyout clipped to its pane taking the pointer
only inside the pane; a button attached to a later target clicked where
it is drawn. The randomized trees float elements with random `capture`
and `clip`, attached to earlier, later, inner and missing targets.

`zig build counts` against `96cbb40`, in a local Docker container: every
declaration unchanged; the box tree's `endFrame` −0.41% (1,256,130 to
1,251,001), depth 64's −1.96%, 4,000 children's +1.39%, warm text's
+0.51%, the documents view's +0.38%. The first versions cost up to +21%:
emission reading the floating config for every element, a `Level` field
for the target's clip, and a call to place floating elements that kept
the passes' hot loops from staying in registers. Testing whether an
element draws anything in emission's loop, before `enter`, is what
brought the box tree and depth 64 below their old counts.
`zig build bench-compare -- 96cbb40` (6 rounds): the box tree's
`endFrame` −0.4%, the static-styled tree's −1.4%, depth 64's −4.5%;
called slower: warm text's `endFrame` +8.1% (92.5 to 99.7 µs), single-line
text's +2.7% and 4,000 children's +3.6%. Callgrind's branch and cache
simulation of warm text gives the same mispredictions and misses as
`96cbb40`, and 0.5% more instructions, so this is where the code lands,
as T4 found, and not work added. `zig build bench -- --check-targets`
meets every budget: the box tree declares in 50.7 µs and lays out and
emits in 91.2 µs, warm text in 99.8 µs.

### L3. Dividers and decorated images

**Plan.** `Border.between_children`; image commands with `corner_radius`
and `tint`. **Done when:** snapshot tests for both. **Spec.** §10.1,
§13.1.

`Border.between_children` is the width of a divider between each two
adjacent children in the flow, emitted as a `rectangle` in the border's
color rather than a command of its own, so no renderer breaks. It is
centered in the gap, from the end of one child to the start of the next,
so alignment and scrolling move it with them, and it spans the element
across its flow inside the border's widths. Floating children take no
part. Dividers are emitted when the element's subtree ends, inside its
clip, so they paint over the children, scroll and are cut off with them,
and come before the border. `Border.widths` now defaults to zero, and a
border of zero widths emits no `border` command, so
`.border = .{ .color = line, .between_children = 1 }` draws dividers
alone. SPEC.md §10.1 now shows `Decoration` and `Border` and says so.

`Ui.Image` takes `tint` (white) and `corner_radius` (square), and the
`image` command carries both, with the same defaults so that renderers
and tests that build one with a handle alone still compile.
`zui_testing.snapshot` writes them when they are not the defaults.
The raylib and sokol renderers draw images without them until C10.

Tests: dividers across a row with a border, sitting in the gaps inside
the border's widths, after the children and before the border; down a
column with no outline, skipping a floating child, with no `border`
command; in a clipping container, only the divider inside the clip,
between `clip_begin` and `clip_end`. An image command's default and
declared tint and corner radius, and `zui_testing`'s snapshot of both.

`zig build counts` against `5824aea`, in a local Docker container: every
declaration unchanged; every `endFrame` +15 instructions, but the
documents view's +1.36% (59,710 to 60,522), about 20 instructions in
`leave` for each of its 40 focusable rows, which leave a level of their
own and carry a decoration.
Emitting the dividers inline, and comparing the widths with
`std.meta.eql`, had made it +1.86%; `emitDividers` is never inlined, and
`leave` reads the border through a pointer.
`zig build bench-compare -- 5824aea` (8 rounds): the box tree's
`endFrame` −0.8% and declaration +0.4%, the static-styled tree's −1.0%,
the documents view's `endFrame` +2.1% (−2.0% to +2.1%); called slower:
warm text's `endFrame` +2.8% (90.0 to 92.6 µs), which runs the same
instructions but 15, so code placement as T4 found, and depth 64's
+4.8%, one step of its 0.1 µs resolution. `zig build bench --
--check-targets` meets every budget: the box tree declares in 51.0 µs and
lays out and emits in 91.8 µs, warm text in 92.0 µs.

### L2. Aspect ratio and natural sizes

**Plan.** `Layout.aspect_ratio`, deriving height from the settled width;
`Image.natural_size` for `fit` images. **Done when:** golden tests cover
aspect ratio under every rule on the other axis, and a `fit` image takes
its natural size. **Spec.** §8.1, §10.1.

The aspect ratio is a height rule, `Sizing.Rule.aspect_ratio`, written
`.height = .aspectRatio(16.0 / 9.0)`, rather than a `Layout` field, as
the grow basis is a rule (L1): `aspect_ratio: ?f32` made every `Layout`
eight bytes larger (56 to 64), and the box tree's declaration 0.94% more
instructions and 6.6% slower on the wall clock (49.1 to 52.7 µs, of a
55 µs budget); a plain `f32` made it 60 bytes, and the box tree's
`endFrame` 6.7% slower. SPEC.md §8.1 now says so. The fit pass of the
heights derives it from the settled width, `width / ratio` within `min`
and `max`, so no pass is added; a parent neither stretches nor grows it,
and children overflow it. On a width, or with a ratio that is not
positive, it takes the content's size.

`Ui.Image` is now the declaration's own type, `handle` and
`natural_size`, apart from the `image` command, which keeps only the
handle until L3 adds `tint` and `corner_radius`; image storage is
reserved only when `ImageHandle` is not `void`. A natural size is the
image's content, inside its padding; its width may shrink below it, as a
leaf's does in a narrower parent, and its height then keeps the natural
proportions unless its own rule is `aspect_ratio`, `fixed` or `percent`.
The natural size is read only when `ImageHandle` is not `void`.

Where the rule sits in the fit pass decided its cost. In an arm of its
own, LLVM either summed the content before the `switch`, for `fixed`
elements too (4,000 fixed-height children +4.2% instructions), or turned
the `switch` into a jump table whose mispredictions doubled the box
tree's indirect branches and made its `endFrame` 5.5% slower. It shares
the content-based arm instead, as the fourth of one range of rules.

Tests: golden layouts for an aspect ratio under every width rule
(`fixed`, `grow`, `grow_equal`, `percent`, `fit`), within `min` and
`max`, with padding inside it, neither stretched across a row nor grown
down a column beside a `grow` sibling, wrapped by a `fit` parent,
overflowed by a child, and on a width or with a zero ratio. Images: a
natural size with and without padding and none at all, the command's
bounds and handle; a growing and a squeezed image keeping their
proportions; `aspectRatio`, fixed sizes and a zero natural width taking
precedence.

`zig build counts` against `075fbbd`, in a local Docker container: every
declaration unchanged; the box tree's `endFrame` +1.36% (1,239,211 to
1,256,115), depth 64's +1.65%, 4,000 children's +0.47%, every text
scenario within +0.11%; branch mispredictions in the box tree's
`endFrame` unchanged (137,390 to 137,270). `zig build bench-compare --
075fbbd` (8 rounds) called no frame slower: the box tree's `endFrame`
+1.5% (0.0% to +1.7%), its declaration +1.0%; only the first frame of
the documents view, a startup time, came out +4.4% (+3.1% to +6.0%).

### L1. A grow basis

**Grounding.** Two `.grow` siblings holding "a" and "abcdefghijklmnop" in
300 px came out 90 / 210, as with CSS `flex-basis: auto`, and there was no
way to ask for equal columns. **Plan.** `Sizing.basis`, and
`Sizing.grow_equal`. **Done when:** golden tests for both bases, with the
weight invariant. **Spec.** §8.1.

The zero basis is a rule, `Sizing.Rule.grow_from_min`, rather than a
`basis` field: `Sizing` had no room for one without padding, and two
two-byte fields (`rule` and `basis`) made the box tree's declaration 3.8%
more instructions (436,050 to 452,435) with no change to layout.
`Sizing.grow_equal` is `.{ .rule = .grow_from_min, .amount = 1 }`, and
SPEC.md §8.1 records why. It comes after `grow` in the enum, so that
`fit`, `grow` and `grow_from_min` are one range: after `percent`, the
`switch`es over the rule cost the box tree's `endFrame` 2.6% more
instructions.

A `grow_from_min` child starts at its `min` and shares the parent's
content box by weight, as CSS `flex: 1`, but is never narrower than its
content's minimum, so a word never overflows a column: the others share
what it leaves, still by weight. Distribution holds it at that minimum,
and when a parent has one, `growFromMin` raises every growing child to
`clamp(start + share × weight, floor, max)` with one `share`, found by
walking up through the points where a child leaves its floor or reaches
its max. Parents without one keep `grow` as it was: the same walk for
the box tree's capped children cost 0.9% more instructions but ran 6.8%
slower on the wall clock, from its divisions.

Tests: golden layouts for a content basis (90 / 210) and a zero basis
(150 / 150), weights over the whole box, a child held at its content's
minimum with the rest shared 1 : 2, a max, a content and a zero basis
side by side, a zero weight, a `fit` parent, overflow, and rows down a
column. The randomized trees declare `grow_equal` and weighted
`grow_from_min` with mins and maxes, and check the weight invariant:
`grow_from_min` siblings that are neither at their floor nor at their max
have grown from `min` by one share of their weights.

`zig build counts` against `9b506be`, in a local Docker container: every
scenario within −0.51% to +0.02% (the box tree's `endFrame` 1,239,720 to
1,239,211, warm text's 1,033,320 to 1,030,421). `zig build bench-compare
-- 9b506be` (8 rounds) calls nothing slower beyond the 0.1 µs resolution
of depth 64 and the documents view; the box tree's `endFrame` +1.6%
(−1.3% to +3.3%, fastest 90.9 µs), the static-styled tree's +2.6%, warm
text's −5.7%, with the same instructions: code placement, as T4 found.

### T4. Line-break segmentation

**Plan.** The optional `zuiSegment` on the text contract, writing break
opportunities into a `BreakSink`; ASCII spaces and newlines without it.
**Done when:** a golden test wraps CJK text with a segmenting test
contract, and texts without it are no slower. **Spec.** §9.2, §9.4.

`zuiSegment(self, paragraph, breaks: *zui.BreakSink)`, checked by
`checkText`, with a compile-error test for a wrong signature. zui splits
a text at newlines itself and asks the contract for one paragraph at a
time; the segments between its breaks are measured and wrapped as words
are, each without the spaces that end it, which hang past the end of a
line that breaks after it. The breaks go into a scratch buffer of
`limits.max_text_bytes` offsets, in `Context` memory only when the
contract declares `zuiSegment`. Without it, nothing changes: the
segmenting path is chosen at compile time, its own functions
(`measureSegments`, `wrapSegmentedLines`), so the default path's code is
the code it was.

Tests: CJK text wraps between characters at the width of whole
characters; Latin words stay whole beside CJK, and the space before a
break hangs; each paragraph is segmented on its own and the contract
never sees a newline; a cached string past the 16 widths a cache entry
keeps wraps as a fresh one, with no new measurements; a contract that
breaks after every space reproduces the default's metrics and lines over
2,000 random texts. `zig build check` declares a thread-safe segmenting
contract, so the parallel path's run iterator is type-checked on every
target.

Fixed on the way: the first word of a paragraph after the first was
given the width of a space before it, so the first line of every later
paragraph came out a space wide too, and sooner wrapped.

`zig build counts` against `c5b0401`, in a local Docker container: warm
text's `endFrame` −2.6% (1,060,636 to 1,033,320), from the fix, and the
other text scenarios −0.2% to −1.2%; every other scenario unchanged.
`zig build bench-compare -- c5b0401` called no scenario slower over 10
rounds, but put warm text's `endFrame` at +4.0% (+0.4% to +5.4%), and
an earlier run of the same code at +6.8%. With the fix taken out, warm
text ran the very same instructions as at `c5b0401`, with the same
simulated cache misses and branch mispredictions, and still measured
+7.8%; and `c5b0401` with only `wrapLines` aligned to 64 bytes measured
the new-strings scenario +2.8% slower. So on this machine where the code
lands moves the text scenarios by several percent, and wall-clock
comparisons of them below that are not meaningful; instruction counts
are. Aligning `wrapLines` did not pin it down and was dropped.

### P5. The box tree's declaration within budget

**Plan.** With L8's config references in place, cut the per-element
stores of `open`, and store the flags without reloading the element's
fields, through a different `Element` shape if the compiler cannot be
led to it. **Done when:** `zig build bench -- --check-targets` meets the
declaration budget on the reference machine, and no scenario is slower
by `bench-compare`. **Spec.** §5.1, §10.1, §20.2.

The box tree declares in 48.9 to 50.2 µs at best over five runs of
`zig build bench -- --check-targets`, against 55 µs, and lays out and
emits in 89.2 to 93.5 µs. Callgrind's profile of an `open` after L8 put
most of what was left in two places that were not the stores of element
storage:
- **The element's switches.** Zig writes a `bool` field of a struct
  literal as one bit and reads it as a byte, and LLVM cannot forward a
  store to a wider load, so the scene's `Element` stayed on the stack:
  every `open` stored `interactive`, `focusable`, `focus_scope` and
  `disabled` and loaded and masked them back, about 25 instructions. An
  optional is stored and loaded as bytes, and its defaults fold, so the
  four are `?bool`, null meaning false. They are written as before, and
  SPEC.md §10.1 records why. A switch set at run time still costs a store
  and a load, half of what a `bool` did. `Axes` was a two-bit enum with
  the same problem, so it is a byte.
- **Reloads through the frame.** The copied layout and decoration take
  their slot in a local before the copy, so the cursor is not loaded
  again after it.

And in element storage, `child_count` and `flow_child_count` are one
array of pairs, `child_counts`, so declaration zeroes both in one store
and counts a flow child in one addition; the passes read each half as
before. `fit` takes each element's sizing from `contentSize`, which
already read its layout, and a text element's from the default layout
without reading its reference.

`zig build counts` against `beb36f5`, in a local Docker container: the
box tree's declaration −24.1% (574,326 to 436,050) and its `endFrame`
−1.1%; the static-styled tree's declaration −31.2%, the wide tree's
−35.0% and depth 64's −15.0%; the texts' declarations −3.1% to −6.9%;
every scenario fewer in both phases. `zig build bench-compare --
beb36f5` (6 rounds): the box tree's declaration −15.6% (58.3 to
49.6 µs), the static-styled tree's −20.8%, the wide tree's −11.9%, depth
64's −13.3%; warm text's `endFrame` −6.6% (97.9 to 91.5 µs), the box
tree's −2.6%; none slower. Against `342b04a`, before L8 (8 rounds), warm
text's `endFrame` is +1.4%, within noise, where L8 had left it +7.0%.

Tried and dropped:
- **The content kind in the flags,** saving one store an element:
  declaration −1%, but `endFrame` +1%, from masking the kind out of the
  flags in every pass;
- **`sizingOf` answering a text element without its reference,**
  everywhere: warm text's `endFrame` −0.4% and its read misses −1.2%,
  but the box tree's `endFrame` +2.5%;
- **the pair of child counts as a packed struct:** the same declaration,
  but the box tree's `endFrame` +2.9%, from extracting each half.

### P4. The box tree's layout and emission within budget

**Grounding.** At `a6d8e34` the box tree's `endFrame` took 101.2 µs
against a 100 µs budget, and no item was aimed at it. Stage 2 has changed
emission since (scale and zoom snapping, the frame's diagnostics), so the
first step is to measure it again.

**Plan.** Re-measure on the reference machine. If it is still over, take
a P2 trace of the passes and work on the costliest, judged by R1's counts
and `bench-compare`.

**Done when:** `zig build bench -- --check-targets` meets both box-tree
budgets on the reference machine, and no other scenario is slower by
`bench-compare`.

Done with P5, which brought the declaration within budget. After P5,
`zig build bench-compare -- afacf87` (8 rounds) calls no scenario
slower: the box tree's `endFrame` −19.0% and declaration −27.4%, warm
text −6.1%, the wide tree −7.6% and −7.9%, the documents view −9.3%,
everything else within noise.

Measured first at `afacf87` on the reference machine:
`endFrame` 111.0 µs and declaration 68.5 µs, the machine running slower
than at `a6d8e34` (*Where we are*). Callgrind's profile of `endFrame` gave
position 21% (82 instructions an element: its along and across
coordinates were indexed at run time, so each parent spilled them to the
stack), the two distribute passes 20%, the two fit passes 20% and emission
12%. Landed:
- **Position by parent.** Each parent places its flow children in one
  loop specialized by the flow's axis; the per-parent placement records
  are gone. Position went from 365,000 to 232,000 instructions a frame.
- **A default layout at `layouts[none_index]`,** so `layoutOf` and
  `sizingOf` never branch.
- **Declaration:** an element without an id takes `id.internal`, one
  multiply where `mix` took two, because such ids are never looked up;
  `Sizing.Rule` is four bytes, so a layout has no padding bytes to copy;
  `content_index` is not written for a plain box; `flagsFor` is inline;
  the root is a comptime case of `appendElement`.

Against `afacf87`, `zig build counts` in a local Docker container: the box
tree's `endFrame` −14.3% (1,562,373 to 1,339,297) and declaration −23.2%
(765,869 to 588,146); every other scenario fewer in both phases (text
declarations −10% to −18%, `endFrame` −0.4% to −15%). `zig build
bench-compare -- afacf87` (8 rounds): box tree `endFrame` −16.0% (111.0
to 93.5 µs), declaration −9.6% (68.5 to 61.9 µs), warm text −5.8%,
depth 64 −8.3%, documents view −3.8%; slower: the text walls' declaration
+3.7% (16.3 to 16.9 µs) and the wide tree's +4.4%, with 18% and 11% fewer
instructions and the same simulated cache misses (Callgrind
`--cache-sim`), which points at code placement rather than work.

Tried and dropped:
- zeroing `size` and `min_size` at the start of `endFrame` rather than
  in declaration: declaration −8%, but `endFrame` +3% for the box and wide
  trees, the cost of touching 128 KB, so it would only move the time;
  `@memset` there was compiler_rt's, 90,000 instructions without libc,
  and `rep stosb` was slower still;
- one integer for `child_count` and `flow_child_count`: −4,000
  instructions in declaration, +40,000 in `endFrame`;
- layouts and decorations at the element's own index, with no counts:
  −2% in declaration, but the first frame of 1,000 texts +5.7%, from the
  pages the sparse layouts touch;
- `sizingOf` returning `.fit` without a load: +86,000 instructions in the
  box tree's `endFrame`; `.fit` tested before the switch in `distribute`:
  no change;
- computing the flags before the first store: no change (see P5).

**Spec.** §8.2, §20.2.

### L8. Static styles

**Plan.** `zui.static` and `Static(T)`; config references in element
storage as pointers into the frame arena or static memory; fields on the
element overriding the style's. **Done when:** the box tree's
declaration stays within its 55 µs budget with references, and declaring
an element with a static style copies no config (R1). **Spec.** §10.3.

`zui.Style` (a layout and a decoration), `zui.Static(T)`, which holds a
pointer to read-only memory, and `zui.static(comptime value)`, which is
the only way to make one; `Element.style`, with `layout` and
`decoration` set on the element replacing the style's. A frame now keeps
`layout: [max_elements]*const Layout`, pointing at a copy in its arena,
a static style's, or one default layout, and `decoration:
[max_elements]?*const Decoration`, null where nothing is drawn (a static
style whose decoration draws nothing included); `Frame.layoutOf` and the
new `decorationOf` read them. Copies go through a cursor into the arena,
`next_layout` and `next_decoration`, rather than a count, which saved
the address arithmetic that otherwise made declaration grow by up to 4%.

Tests: a styled element lays out and draws exactly as one with the same
configs copied; the frame holds the static style's own addresses;
an element's own layout or empty decoration replaces the style's, and a
static decoration that draws nothing is none; a style's direction flows
its children. `zig build check` declares a styled element on every
target. A new scenario, `4096 static-styled boxes`, is the box tree with
each element's configs in one of 32 static styles.

`zig build counts` against `342b04a`, in a local Docker container: the
box tree's declaration −2.35% (588,151 to 574,326) and `endFrame` −4.8%;
`endFrame` fewer in every scenario (−0.3% to −5.0%), declaration within
+0.7% elsewhere (depth 64, 14,405 to 14,502), the wide tree's −3.9%. The
static-styled tree declares in 445,291 instructions, 22.5% fewer than
copying, with the same `endFrame`. `zig build bench -- --check-targets`,
four runs: the static-styled tree's declaration 34.5 to 34.7 µs at best,
within the 55 µs budget; the copying box tree's 57.7 to 58.5 µs, still
over it (P5), and its layout and emission 92.3 to 94.4 µs; warm text
97.5 to 102.7 µs. `zig build bench-compare -- 342b04a` (4 rounds): the
box tree's declaration −6.1% and the wide tree's −8.3%, depth 64's
`endFrame` −4.5%; slower, warm text's `endFrame` +7.0% (91.4 to 98.4 µs,
within its 120 µs budget, with 0.8% fewer instructions) and the
documents view's first frame +5.8%. Callgrind's cache simulation puts
warm text's extra time in the wider arrays: 6% more first-level read
misses, from two 8-byte references an element where there were two
2-byte indices.

Tried and dropped:
- **Indices into tables of references** (`layout_index` into
  `layout_refs`): read misses back to before, but declaration +4.2% for
  the box tree and +10.6% for the wide tree, a store more per config;
- **a `decorated` flag,** writing the decoration only where one is drawn:
  warm text's misses unchanged, and the static-styled tree's declaration
  +11.6%, reading each style's decoration to set the flag.

Decided here:
- **What a reference is:** a pointer, as SPEC.md §10.3 says, also for the
  default layout, a constant in read-only memory, so a pass never
  branches on whether an element has a layout.
- **Overriding** is by kind: an element's `layout` replaces the style's
  layout whole, as does its `decoration`, so a reference is never
  merged into a copy.

The copying box tree's declaration budget was met by P5.

### F6. Watching files

**Plan.** A source of file changes from the host (`zuiFileWatch`), which
`zui_debug` uses to reload themes and assets. **Done when:** editing a
theme file restyles the running demo. **Spec.** §16.3.

zui (`ad90c3a`) gained the vocabulary: `zui.FileChange`, plain data with
its path inline (255 bytes, relative, `/`-separated), so a source of them
relays, replays and goes over the wire; `.rescan` for changes the OS lost
or a path that does not fit; `zui.FileChangeSink`, a pointer and a
function as `Waker` is, which `.of(&source)` makes from any source whose
`publish` returns `Wake` or `error{Full}!Wake`; and `zui.FileWatchError`.
`checkHost` checks `zuiFileWatch.watch(host, directory, sink)
zui.FileWatchError!void`, pinned by a compile-error test. Tests: a test
host's watch publishes into a source and wakes once; a too-long path is a
`.rescan`; a `zui_async.Stream` of changes reaches a frame and reports a
refusal; a delivery of changes round-trips through `zui_wire`; `zig build
check` watches on every target. Nothing on a hot path changed.

The Windows host (`0e9690f`) watches up to four directories
with their subdirectories: a thread per directory issues each overlapped
`ReadDirectoryChangesW` and publishes each change, waking the window for
the first since the last frame; `watch` returns once the first read is
pending, so no change after it is missed. Tests against a hidden window
see files added, written, renamed, added in a new subdirectory and
removed, each within 2 s, and a missing directory and a fifth watch
fail.

The demo is the native hosts' `zig build theme`: a window in the colors of a
ZON theme, whose application declares a `Stream(zui.FileChange)` and a
`Latest(Theme)` among its sources; declaration sees the theme's file
among the changes, and the loader reads and parses it into the `Latest`,
so a replay restyles as the live run did. `-- --check` writes a dark
theme, waits for a frame drawing it, writes a light one over it, and
fails unless a frame draws the light background within 10 s. In three
runs on the reference machine each restyled in the second frame after
the first, 2.4 to 3.6 ms after the write.

Decided here:
- **The service's shape:** `watch(host, directory, sink)` until the
  host's `deinit`, subdirectories included, with no `unwatch` until an
  application needs one; a host holds a fixed number of watches.
- **A watch publishes, a source holds:** the host never names the
  source's type; the application chooses it, usually a `Stream`, so a
  full one refuses and is reported like any other source.
- **Who reads the file:** the loader, between frames, into a source of
  its own, since declaration does no I/O; declaration only sees which
  files changed.

Since then, `zui_debug` (V1) reloads its theme this way (`389e497`).
The demo is an example of the native hosts' rather than the sokol
renderer's tour, which was changing under another item at the time.

### F5. Rendering somewhere else

**Plan.** A wire renderer and a wire host, so a remote client is a host
plus a renderer. **Done when:** the demo runs in one process and draws in
another, with input going back. **Spec.** §16.4, §19.6.

`zui_wire.Host(Ui)` takes one end of a `std.Io.net` stream with
`attach`, reads the client's header and first record, then reads records
on a task of the `Io`; a poll gives what arrived since the last one (the
newest viewport and scale, every event in order) in the client's clock,
counted on from the last record between records, so `.at` waits and
wakes need nothing from the client. The connection ending closes the
window. It gives a new `wire` surface, the core's only change, into which
`zui_wire.Renderer(Ui)` writes each frame as changes, after a header with
the application's fonts' fingerprint, from `zui_app`'s render thread.
`zui_wire.Client(Ui)` is the other end, over any host and renderer: it
sends a record when it holds events or the viewport or scale changed,
presents the newest frame that came back and applies its host requests,
reading frames on a task that wakes its host; closing it stops sending
first and reads until the application has closed its end, so the
application never writes into a closed connection.

Tests, over loopback TCP: the wire host passes zui's host suite; an
application run by `zui_app` on the wire host and renderer is drawn by a
client on another thread, two clicks going back and the button's cursor
coming back; a client refuses a stream measured with other fonts; the
host closes on bytes that are not a record and reports `Malformed`. They
pass in the three modes on Windows, and on Linux and x86-linux in
Docker. `zig build check` instantiates the three for every target with a
network.

The demo: the native hosts' `zig build remote -- --check tour.bmp` starts
the tour, unchanged, in a second process on the wire host and
renderer, listening on a loopback port it prints, and draws it in a
window of the Windows host with the sokol renderer through a client.
It presses Ctrl+2, Ctrl+4 and Ctrl+9 and waits for frames showing each
screen's tagline, saves the window, and closes it, after which the tour's
process exits with 0. In five runs in a row on the reference machine,
each run took under a second; the welcome screen's first frame arrived
3 to 5 ms after the client connected, and each screen came back within
the script's 50 ms polling interval of its key.

Decided here:
- **Who makes the connection:** the application, which hands the wire
  host a stream with `attach` (under `zui_app`, in its `init`), since a
  host's `init` takes only the `Io` and the window's options.
- **Whose clock a record carries:** the client's host's; the wire host
  counts on from the last record, so the client sends only records with
  events or a new viewport or scale, never one for time alone.
- **Where host requests go:** with the frame, which already carries them,
  for the client to apply to its own host; the wire host's `zuiApply`
  does nothing.
- **What a client skips:** frames that arrive faster than it presents
  them; each is decoded, since frames are changes, and only the newest is
  drawn.

### F4. Replay in `zui_testing`

**Done when:** a recorded demo session replays to identical commands
without starting any work. **Spec.** §6.8, §19.4.

`zui_testing.Recording(Ui)` is a relay listener that keeps each applied
record, its typed text, dropped paths and deliveries copied into memory
reserved by `init`; a record that does not fit is dropped whole and
counted. `Driver.replay(app, declare, record)` runs one frame from a
record, as `beginFrame` replays it, with no loader between frames.

Replaying the tour showed that `KeyedLoads` did not replay exactly: its
delivery held only the loads completed at a swap, but a key's
`.running` status and progress come from the loader's `toStart` and the
producers between frames, so a replay showed loading tiles as idle. Its
delivery now also carries, when relayed, the keys loading with the
progress the frame saw and the abandoned loads that finished; its
`zuiInject` starts those loads, hands back the abandoned ones, and frees
what the live loader released through `toRelease` before the frame. The
live swap pays one store per abandoned load that finishes; the rest is
in `zuiDelivery`, which runs only with a listener.

Tests: `zui_testing` records three frames of two sources and typed text
and replays them in a fresh context whose sources hold other values;
a recording drops a record too large for it whole; and `zui_async`'s
gallery session, a grid of tiles loaded by key with loads that finish a
frame later, a battery level and a log, replays to the same commands
with no load started.

The demo: in the sokol renderer's tour at `9b616d5`, declared headlessly with
real fonts and its real loaders (tiles loaded on threads, telemetry), 30
frames on each of its ten screens recorded with `Recording`, then
replayed into a fresh context and a fresh application whose loaders
never run: 300 of 300 frames identical, compared through
`zui_wire.writeKeyFrame`'s bytes, with no wake during the replay, once
the gallery's legend is left out. That legend shows counts its loads
keep in atomics outside its sources (`started`, `completed`, `glitched`,
`abandoned`), which no record carries, so with it 29 gallery frames
differ in those numbers: the application's side of §6.8, which SPEC.md
now names. The tour's relayed records grew from 40 to 79 bytes a frame
on the wire with the keys loading.

Decided here:
- **Replay is a `Driver` method** taking one record, so a test can
  inspect each replayed frame, and `Recording` is the listener that keeps
  them; the spec's `replay(records)` is that loop.
- **A source delivers what its loader changes between frames,** when
  relayed, since a replay runs no loader; `KeyedLoads` is the one default
  source whose view the loader changes.

### F3. `zui_wire`

**Plan.** A versioned encoding of records and frames, as deltas; payloads
serialized when plain data and otherwise through `zuiSerialize`; the text
contract's fingerprint. **Done when:** round trips are tested for every
event, delivery and command kind, and a delta stream of the demo is
measured against full frames. **Spec.** §19.6.

A new module, `zui_wire`: `writeHeader` and `readHeader` (magic, version,
the fonts' fingerprint), `Encoder(Ui)` with `writeRecord`, `writeFrame`
and `writeKeyFrame`, and `Decoder(Ui)`, whose `next` gives a record that
`beginFrame` takes or a frame a renderer takes. Values are written by one
comptime codec: integers as LEB128, floats by their bits, unions by tag,
slices by length, errors by name, and a type with `zuiSerialize` by
itself. A record's parameters are written as changes from the last
record's; a frame's commands as runs kept, skipped, inserted or changed
in the fields that differ, against the last frame written, resynchronized
by element id and kind within 32 commands. `zui_async`'s `Stream` and
`KeyedLoads` deliveries serialize only the items taken. The text
contract's `zuiFingerprint` is checked for its signature
(`fn (*const Text) u64`).

`core/zui_wire/tests.zig` round-trips every `Event` and `EnvironmentChange`
kind, every delivery of `zui_async` and one holding a pointer that sends
a number instead, and every command kind whole and as changes; checks
that a key frame lets a reader join, that a message beyond the decoder's
capacity fails, that other fonts and other versions are rejected; and
encodes a live session whose decoded frames are the frames drawn and
whose decoded records replay to the same commands. Compile-error tests
pin a delivery and an `ImageHandle` holding a pointer, `zuiSerialize`
without `zuiDeserialize`, and a wrong `zuiFingerprint`; `zig build check`
encodes and decodes a record and a frame on every target.

Measured on the sokol renderer's tour at `9b616d5`, declared headlessly as its
tour test does, with real fonts: 120 frames on each of its ten screens
at 1440×900, the mouse crossing each screen, every frame written whole
by one encoder and as changes by another, and each decoded frame
checked equal to the one drawn:

| Screen | Commands | Whole frame | Changes, mean |
|---|---|---|---|
| welcome | 306 | 16,406 B | 206 B |
| layout_lab | 364 | 18,605 B | 147 B |
| box_storm | 4,359 | 201,585 B | 91,408 B |
| gallery | 578 | 28,982 B | 278 B |
| mission_control | 428 | 21,085 B | 254 B |
| window_manager | 388 | 19,272 B | 151 B |
| robot_workshop | 375 | 18,868 B | 177 B |
| pixel_pad | 1,425 | 66,919 B | 695 B |
| typography | 318 | 16,626 B | 139 B |
| classic | 273 | 13,857 B | 107 B |

Over all 1,200 frames: 42,221 bytes a frame whole, 9,356 as changes
(median 20, largest 198,951, the first frame of a screen); without
`box_storm`, whose thousands of boxes all move every frame, 24,514
against 240, a hundredth. The records, relayed from the same session,
took 40 bytes a frame. The core's code is unchanged but for a comptime
check, so instruction counts and budgets are as they were.

Decided here:
- **What a frame on the wire holds:** what a renderer and a host need
  (number, parameters, host requests, commands). Hit regions and
  semantics stay with the context; the inspector over the wire, which
  V1 left unqueued, adds what it needs then.
- **A message that does not fit the decoder** fails with
  `error.CapacityExceeded` rather than keeping what fits, since a delta
  applied in part would corrupt every frame after it.
- **How `zuiSerialize` is reached:** `serializer.write(value)` and
  `deserializer.read(T)`, taken as `anytype`, so a source that declares
  them, as `zui_async`'s do, never imports `zui_wire`. Slices are allowed
  inside it, and in zui's own vocabulary (typed text, dropped paths,
  command text), but not in a payload that serializes automatically,
  since a decoded slice lives only until the next message.
- **The fingerprint** is checked only when both sides declare one.

### F2. Relay

**Plan.** `relayTo(listener)`: each applied record, with deliveries from
`zuiDelivery`, without allocating when no listener is attached, in a
`relay` trace zone. **Done when:** a test relays a session into a buffer
and gets back exactly the records applied. **Spec.** §6.8.

`ui.relayTo(listener)` takes a `?Ui.Relay`, `zui.Relay(Ui.FrameRecord)`:
a context pointer and a function, as `Waker` is. At the end of
`beginFrame`, after the sources swap and inside the new `relay` zone, the
listener gets the record as applied: its parameters, the events zui kept
(the first `max_events_per_frame`), and the deliveries, which a live
frame fills from each source's `zuiDelivery` into `relayed_deliveries`
in the context's reservation, and a replayed one passes through.
`relayTo(null)` detaches it.

`core/src/tests/relay.zig` relays a four-frame session (a click with typed
text, a published value, six events where four are kept) into a
recorder, checks each record against what was applied, then feeds the
recorded records with their deliveries to a fresh context and gets the
same commands, typed text and clicks frame by frame, and the same
deliveries relayed again. A context without sources relays records
without deliveries; the tracer test sees the `relay` zone only with a
listener; `zig build check` relays a source's delivery on every target.

`zig build counts` against `1e16727`, in a local Docker container:
declaration +2 instructions in every scenario (+3 with ten idle
`zui_async` sources), `endFrame` unchanged; ten idle sources still cost
what they did over none. The reservation grows by `Deliveries`' size,
and not at all without sources. `bench --check-targets` misses only the
declaration budget, as before (P5).

Decided here:
- **What is relayed** is the record as applied: the events zui kept, so
  a replay of it applies exactly those, and a text event whole, since
  zui cuts it the same way again.
- **Where the relayed deliveries live:** in the reservation, as
  SPEC.md §5 lists "the relay buffer", since a `Delivery` can hold a
  stream's whole capacity and does not belong on the stack.

### C9. `zui_app` with a separate text contract

Taken ahead of the queue, since stage 10's "the demo runs unchanged on
each host" needs one loop for every application.

**Grounding.** `zui_app.checkApp` made any `Text` but the renderer a
compile error (C4), and `contextConfig` replaced an override's `Text`
with a renderer that measures. The sokol renderer's tour measures with
`zui_sokol.Text`, a separate type its renderer holds a pointer to, so
H2 ran it on the Windows host under a hand-written loop.

**Plan.** Let the application name its text contract, keeping "the
renderer measures" as the default, with exact, pinned compile errors.

**Done when:** the native hosts' `tour` step runs the sokol renderer's
tour through `zui_app.run`, `zui_app`'s tests cover both cases, and the
raylib renderer's demo builds unchanged.

What landed:
- **`App.Text`.** An application whose `Config` names `.Text = Fonts`
  declares `pub const Text = Fonts`; `zui_app` makes one (its `init(self)
  !void` and `deinit` if it declares them, else its defaults), gives the
  context a pointer, and gives it to a renderer whose `init` takes
  `(self, surface, text: *const Text)`. `contextConfig` keeps an
  override's `Text`. Four new compile errors are pinned: a `Ui` measuring
  with a type the application does not declare, an `App.Text` that is
  not the `Ui`'s, a renderer `init` taking the wrong text, and a
  `zuiRecord` of the wrong signature.
- **What running the tour unchanged needed besides:** `zuiRecord(app,
  record)`, after the host's poll, where the application sets its zoom
  (which `zui_app` could only set once, from `Options.zoom`) and appends
  events it makes itself (the tour's theme switch); `Start.renderer`;
  `sources` as a field holding the `Sources` or pointing to them, so a
  wrapper uses the sources of the application it wraps; and each field
  of the host, the renderer and the text that has a default holding it
  when their `init` is called. The Windows host's `Host.init` reads
  `forced_scale` and `system_material_unavailable` from itself, which
  under `zui_app` had been undefined.

The native hosts (`d6fe429`) run the tour
with `examples/tour.zig` now `zui_app.run(TourOnHost, ...)`:
`TourOnHost` names the host, the renderer and `zui_sokol.Text`, and
passes each step to the tour's own `App`; a small `SokolRenderer`
opens the sokol renderer with `initForSurface` and times each submit
for the tour's strip, since the sokol renderer's `Renderer.init` predates
`zui_app` and was changing under another item at the time. The
tour visits every screen (`--frames 300 --cycle 30`, diagnostics ok), its
screenshot shows the dark theme `zuiRecord` applied, and in ReleaseSafe
on the reference machine Layout Lab idles at 0.0, 31.3, 15.6 and 0.0 ms
of CPU over 10 s with 0 frames and 0 wakes; Welcome at 0.0 ms with its
11 heartbeat frames. The raylib renderer's demo, tests and suites build
and pass unchanged. Nothing in the core changed, so there is
nothing to count.

Decided here:
- **The text contract under `zui_app`** is the renderer by default, or
  the application's `pub const Text`, which `zui_app` owns.
- **The application's part of the record** is `zuiRecord`, after the
  host's poll: the zoom is the application's (SPEC.md §16.3), and the
  host converted this poll's events at the zoom then on screen.

What remains: the sokol renderer's `Renderer` could take `zui_app`'s
`init(self, surface, text)` itself, which would retire the native hosts'
`SokolRenderer` (`hosts/native/examples/sokol_renderer.zig`).

### H8. The desktop showing through the window

`zui.SystemMaterial` (`none`, `window`, `transient`) in
`WindowOptions.material`, passed by `zui_app.Options.material`, and
`Environment.system_material`, the host's answer on this machine, an
environment change like every other (`50430d8`). The Windows host
(`a958595`) declares `system_material`: it asks DWM for the backdrop
(`DWMWA_SYSTEMBACKDROP_TYPE`, Mica or Acrylic), extends the frame over the
client area and paints it black, which is transparent there, and reports
`system_material` (the backdrop taken and transparency effects on) and
`reduced_transparency`, again when the settings change.
`Host.system_material_unavailable` makes it behave as Windows 10, which
refuses the attribute.

The renderer clears to transparent and must keep its alpha. Windows
ignores the alpha of an OpenGL window and of a Direct3D swapchain made for
a window: over Acrylic's #545454, an opaque #2d2d2d card showed #818181,
the backdrop added under every pixel. So the sokol renderer (`6d49d41`)
now draws into a `win32` window with D3D11, its default backend, through a
swapchain DirectComposition composes into the window with premultiplied
alpha, and its sokol_gl pipeline writes alpha, which sokol_gl does not by
default. sokol's built-in bitmap text writes 0 between a glyph's strokes, which let the
backdrop through each glyph's cell over a card, so when the surface
composes alpha every rectangle and border is drawn again into the alpha
channel after the text, with MAX blending.

`zig build material` in `hosts/native/` declares a root without a background
while `system_material` is true and with the theme's otherwise. Read back
from the screen on the reference machine (Windows 11): Mica shows #202020
where nothing is drawn (black without it), Acrylic #545454, and a #2d2d2d
card at 69% alpha blends over each as drawn (#292929, #393939); with the
material forced unavailable, the root's own #202020 and the same card.
The tour draws through the same D3D11 path and idles at 0.0 ms of CPU over
10 s in three runs of four (62.5 ms, 2 frames, in the fourth), ReleaseSafe.

Decided here:
- **Whether the material shows is an environment setting,** not a
  status a host call returns, so it is in the record, replays, and the
  application reads it where it reads the theme.
- **A native window's renderer composes with alpha** through
  DirectComposition on Windows; the sokol renderer's OpenGL path stays for
  `-Dgl=true` and its renderer suite, and does not show the material.

What remains, and where it went:
- **Windows 10 was not seen:** the fallback there is the path forced by
  `system_material_unavailable`, where the attribute's refusal is the only
  difference; this machine is Windows 11.
- **A light theme and a second monitor** were not seen either; the
  machine is in dark mode.

### H2. The Windows host

`zui_host`, in `hosts/native/` (`0731195`), created here, one
directory per OS; `zui_host.Host` is `windows/host.zig` on Windows and a
compile error naming the OS elsewhere. The Windows host:
- runs its window's message loop on a thread of its own, so the window
  keeps drawing while Windows runs a move or resize loop; the window
  thread queues events in physical pixels under a lock, and `zuiPoll`
  converts them with the record's scale and zoom;
- waits on a sticky manual-reset wake event, an input event the poll
  resets, and a high-resolution waitable timer for `.at`;
- reports per-monitor scale (DPI awareness v2, `WM_DPICHANGED`), the
  mouse, the wheel (40 layout units a notch, as raylib and sokol), keys
  with modifiers and scan codes, UTF-8 text with surrogate pairs joined
  and consecutive characters in one event, the environment (dark mode,
  which also darkens the title bar, high contrast, animations, power,
  focus), dropped files (`WM_DROPFILES`), and lifecycle events: console
  control events and `WM_QUERYENDSESSION` are `.terminate_requested`,
  `WM_POWERBROADCAST` gives `.suspend` and `.resume`, and a memory
  resource notification `.low_memory`;
- sets the cursor and places the IME's composition and candidate windows
  at the caret, turning the IME off while no editable asks for text;
- offers the clipboard as text through `zuiClipboard`.

The core gained what such a host reports and the record could not carry
(`d9d279e`): `Event.files_dropped` (`zui.FilesDropped`, paths copied
whole into the new `limits.max_dropped_path_bytes`, `ui.filesDropped()`,
`RecordBuilder.appendFilesDropped`) and `Event.lifecycle`
(`zui.Lifecycle`, `ui.lifecycle()`). `zig build counts` against `638080d`,
in a local Docker container: declaration +1 instruction in every
scenario, `endFrame` unchanged.

The sokol renderer (`05485b5`, `2d11a00`) draws into a `win32` surface
when built with OpenGL (`-Dgl=true`): `Renderer.initForSurface` makes the
window's OpenGL 4.3 core context through WGL and sets sokol_gfx up on it
without sokol_app, and `zuiSubmit` presents with vsync. A D3D11 build does
not declare the surface, so pairing it with the host fails to compile.

It passes C3: `expectHostConforms` against a hidden window, with a
harness that sends the messages Windows would, and ten more tests (DPI
changes, text, the wheel, dropped files, the session ending, Ctrl+C, the
clipboard, requests). The demo is the sokol renderer's tour, whose
application the sokol renderer exports as a module of its own and the
native hosts run unchanged under their own six-line loop; under
sokol_app it runs as before (its tour test passes). Measured on the
reference machine in ReleaseSafe with
`--measure-idle` on the Layout Lab screen (heartbeat off): 15.6, 15.6,
31.3 and 62.5 ms of CPU over 10 s, 0 or 1 frames and 0 wakes; the Welcome
screen, which animates once a second, 15.6 ms and 10 frames. A screenshot
through the compositor (`--screenshot`) shows the tour drawn. The native
hosts' CI checks the format, runs the tests and the host suite on GitHub's
Windows runner in Debug and ReleaseSafe, and cross-compiles from Linux for
x86-64 and ARM64 Windows, which found a function-pointer alignment that
only ARM64 enforces in the sokol renderer's WGL code (`2d11a00`).

Decided here:
- **The demo for a native host is the sokol renderer's tour,** not the raylib renderer's
  demo: raylib owns its window and cannot draw into another, so the
  application that runs unchanged across hosts is the one whose renderer
  can. The tour runs under a loop written by hand, not `zui_app`, because
  `zui_app` gives the context the renderer as its text contract and
  the sokol renderer's text contract is a separate `Text`.
- **The window's loop runs on its own thread,** so Windows' modal move
  and resize loops never stop frames; the contract does not change, as
  the host owns its threads.
- **A terminate request closes the window one frame later:** the host
  delivers it, and its next `zuiPoll` returns false, the OS default with a
  frame to react (SPEC.md §7.1).
- **The clipboard service** is `zuiClipboard`, a type with
  `read(host, buffer) ?[]u8` and `write(host, text) !void`, until H6 gives
  the services one shape.
- **A test may fix the host's scale** (`Host.forced_scale`), so the suite's
  positions in layout units are whole pixels on any monitor.

What remains, and where it went:
- **Touch and pen** (`WM_POINTER`) are not reported yet; nothing in H2's
  plan asked for them, and I5's gestures will.
- **IME composition text** is shown by the IME's own window; the
  `composition` event and the IME area's use by an editable are E1's.
- **A console close, logoff or shutdown** ends the process when the
  handler returns, so the application's frame for that request may not
  run; `WM_QUERYENDSESSION` gives it the time Windows allows.
- **Seen only on this machine:** one monitor at 125%; a second monitor of
  another DPI was simulated by sending `WM_DPICHANGED`.

### H1. The raylib adapter host

The raylib renderer (`80981d0`) has `zui_raylib.Host`,
zui's host contract on raylib's window, with one window and no system
material:
- `zuiPoll` samples raylib's state through `zui.InputSampler` and begins
  drawing; `zuiWait` presents, then sleeps in GLFW (`glfwWaitEvents`,
  `glfwWaitEventsTimeout`) until input, a wake, or the instant
  `nextFrame` names, and `.immediately` waits out the monitor's refresh
  interval. `FramePacer`'s timer tasks are gone.
- The wake sets a flag that is cleared only after a wait, and posts an
  empty GLFW event, so it is sticky and works from any thread. GLFW
  callbacks put in front of raylib's tell a wait that input arrived, so
  a spurious OS event does not end a wait early.
- `zuiApply` sets the cursor (raylib places no IME window). Escape no
  longer closes the window.
- Beyond the contract: `drawOffscreen` and `saveScreenshot`, `script`
  (input for one poll), `close`, `clear_color`, and `opened_at` and
  `first_present` for the cold start.

The renderer is now also the text contract, so
`zui_app.contextConfig(Renderer, ...)` replaced `zui_raylib.config`.
`renderers/raylib/src/conformance.zig` runs `expectHostConforms` beside the renderer
suite; its harness's `post` scripts the state `InputSampler` reads. Both
pass on Windows here and on Linux CI under Xvfb, where the demo's
screenshots, its abandoned loads and its idle measurement (23.7 ms over
10 s, 1 frame, 0 wakes) run as before.

### C4. `zui_app`

`zui_app.contextConfig(Renderer, overrides)`, and `run(App, init,
options)` with `Runner(App)` to run it a frame at a time: the loop of
SPEC.md §6.1 with the application's `zuiDeclare` and optional
`zuiLoader`, `init` and `deinit`. A renderer that declares the new
`zui_render_thread` submits on a task of the application's `Io`, fed by
a queue of `frames_in_flight` frames; otherwise frames submit on the UI
thread, and the start report says why (the renderer, one frame in
flight, the options, or an `Io` without concurrency). `Options.notify`
gets the start report (host, capabilities, submission, lowered commands,
missing services) and then, once each, dropped input, every exceeded
limit, refusals, duplicate ids and an unbalanced tree; the default logs
them. Each mistake in the application is a compile error, pinned by six
tests, and `zui_render_thread` that is not a bool by a seventh. Tests run
the loop against an offscreen host and renderer, on threads and on a
single-threaded `Io`; `zig build check` instantiates `run` and `Runner`
on every target.

The demo runs on it, through H1's host. Its application and loop went
from 116 lines (`App` and `main`) to 106 (`App`, now with its lifecycle,
and a three-line `main`), with a startup measurement added; the file
went from 649 to 671 lines, the new `--measure-startup` taking about 30.

Measured on the reference machine, six runs each, from the OS creating
the process to the first frame presented (`--measure-startup`):

| Build | Fastest | Median | After the window was open |
|---|---|---|---|
| ReleaseSafe | 287.5 ms | 316 ms | 4.3–5.1 ms |
| ReleaseFast | 296.1 ms | 319 ms | 2.7–4.8 ms |

raylib opening its window and OpenGL context is all but about 5 ms of
it: `Context.init`, the first frame's layout and drawing, and presenting
it take the rest. Idle in ReleaseSafe: documents 0.0–31.3 ms of CPU over
10 s, thumbnails 31.3–46.9 ms, settings 15.6 ms, each 1 frame (the
measurement's own, now drawn and presented) and 0 wakes.

Nothing on a hot path changed, so there is nothing to count or compare.

### C7. `Features`

`Features.semantics` (off), `gestures` (on), `flex_wrap` (off) and
`safety_sweeps` (on in safe builds), as SPEC.md §4 gives them, and the
machinery that makes calling an API whose feature is off a compile error
naming the field: each gated API calls `requireFeature(.field, "api()")`
at comptime, and the field comes from `std.meta.FieldEnum(Features)`, so
a message can never name a field that does not exist. Two gated entry
points pin it, each with its compile-error test:
- `Frame.semantics()`, a `[]const zui.SemanticNode` that is empty until
  V2 declares semantics: "zui: semantics() needs Config.features.semantics = true";
- `ui.manipulation(id)`, a `?zui.Manipulation` that is null until I5
  recognizes gestures: "zui: manipulation() needs Config.features.gestures = true".

`flex_wrap` and `safety_sweeps` gate nothing yet: their code comes with
L7 and V3. `zig build check` instantiates both stubs with their features on.

Against `0268dbd`, `zig build counts` in a local Docker container: every
scenario identical to the instruction, with today's defaults and with
every feature off (`counts.zig`'s `Config` given `.features` all false
for the run). No feature adds memory to the reservation.

Decided here: C7 is the mechanism, and each feature's item gates its
real code behind its field; V2, I5, L7 and V3 now say so, and each one's
*Done when* includes R1 counts unchanged with its feature off.

### C3. Conformance suites

`zui_testing.expectRendererConforms(Renderer, harness, .{ .gpa, .io })`
and `expectHostConforms(Host, harness, .{ .io })`, with
`findRendererViolation` and `findHostViolation` returning the first
violation instead. Each takes a harness, as `expectSourceConforms` does,
for what only the implementation can do.

The renderer suite draws five frames from a `Context` built on the
backend's own `Config`: a reference scene of a fill, a border, text, an
image when the renderer has `ImageHandle` and a clip inside a clip, each
clip cutting off a child larger than itself; clips nested 100 deep, then a
fill drawn after them; commands of no size and 100,000 units wide; an
empty frame; and the reference scene again. With a harness that reads
pixels back it checks the colors at 10 points of the scene, inside, outside and below
each clip and after each clip ends, and that the text's bounds hold its
color somewhere, since glyphs differ between fonts. A software renderer
in `zui_testing`'s tests passes with no tolerance; the same renderer
restoring no clip when an inner one ends fails with "drew #0040ff at
(248, 64) in the reference scene, where what the outer clip cut off
should be #203040".

The host suite generalizes C2's test host's checks: a poll keeps the
application's zoom, reports a viewport and gives back what the harness
posted (a click, a key, typed text and a move) in order; `zuiSurface`
gives a kind `zui_surfaces` names; `.immediately` returns at once; a wake
before an `.on_event` wait ends it at once and is cleared, so the next
30 ms `.at` wait lasts until its instant; a wake from another thread
ends an `.on_event` wait; an `.at` wait ends within `prompt_ns` of its
instant; and a closed window polls false. Every wait is bounded: past
`lost_wake_ns` the suite keeps waking the host, so a lost wake fails it
rather than hanging it. A test host in `zui_testing` passes; one that
clears its wake before waiting fails with `WakeNotSticky`. The three wait
tests of `core/src/tests/hosts.zig` moved into the suite. `zig build check`
instantiates both suites on every target.

Each backend has `src/conformance.zig` and a `conformance` step, which
its CI runs (README.md's *Conformance suites* is the recipe):
- **the terminal renderer** reads each pixel as the cell covering it, and passes
  with no tolerance; its `test` step runs the suite too;
- **the raylib renderer** draws into a render texture of a hidden window and reads
  it back with `LoadImageFromTexture`; on Linux CI under Xvfb;
- **the sokol renderer** runs the suite in a sokol_app window's first frame,
  reading each frame back with `glReadPixels` before it is presented, so
  its suite always renders with OpenGL; on Linux CI under Xvfb.

All three pass on Windows here. Breaking either readback (rows read top
down) fails the suite at the scene's first point.

Nothing on a hot path changed, so there is nothing to count or compare.

What remains, and where it went:
- **The host suite against a real host** is H1's: the raylib adapter
  runs `expectHostConforms` in its `conformance` step.
- **Optional commands** are drawn by no scene yet, since no declaration
  produces one; each stage-8 item adds its command to the reference scene
  with the declaration (*Done when* of stage 8).

### C2. The host contract

`zui.checkHost(Host)`: `zuiPoll`, `zuiWaker`, `zuiWait`, `zuiSurface`,
`zuiApply` and `zui_surfaces` required; `zui_capabilities`
(`zui.HostCapabilities`: one window or many, a system material) and the
services (`zuiClipboard` and the rest, each a type until H6 defines them)
optional; each mistake a compile error with its message, pinned by five
compile-error tests. `zui.checkHostAndRenderer(Host, Renderer)` checks
both and fails, naming both and listing each one's kinds, when the host
gives no surface kind the renderer draws into; a sixth test pins it.
`zui.WindowId`, and `zui.RecordBuilder`, which a host fills in `zuiPoll`
in memory the application reserved: `begin` sets what the host measures
(`now`, viewport, scale) and keeps the application's zoom, `append` keeps
events in arrival order and drops the newest that do not fit,
`appendText` copies committed text and cuts it at a character boundary,
and each drop is counted on the builder; `record()` and
`recordWith(Ui.Deliveries)` make the record for a context without and
with sources.

A test host in `core/src/tests/hosts.zig` runs the loop of SPEC.md §6.1 with a
`Context` and a renderer on its offscreen surface: a click and typed text
queued as the OS's events arrive through the builder, the frame's cursor
request is applied, and the loop ends when the window closes. Its wake is
an `Io.Event` reset after the wait, never before, and tests show it
sticky (a wake before the wait ends it at once), ended by a wake from
another thread, and honoring `.immediately` and `.at`; every wait has a
deadline. `zig build check` instantiates a host and the builder on every
target.

Nothing on a hot path changed, so there is nothing to count or compare.

What remains, and where it went:
- **A host suite and a real host.** "The raylib adapter (H1) passes C3's
  host suite" is H1's *Done when*; C3's plan now builds
  `expectHostConforms` from this test host's checks.

### C1. The renderer contract and the generated commands

`zui.checkRenderer(Renderer)`: `zuiSubmit(self, surface: zui.Surface,
frame: anytype) !void` and `zui_surfaces` required; `zui_commands`,
`zui_extended_color` and the payload types `ImageHandle`,
`MaterialHandle`, `CustomData` and `FontId` optional; each mistake a
compile error with its message, pinned by six compile-error tests, and
`.material` without a `MaterialHandle` one more, in the renderer and in
`Config`. `Config.commands` (a `zui.CommandSet` of `zui.OptionalCommand`)
and `Config.MaterialHandle`, and `RenderCommand` generated with `@Union`:
the five base commands, `image` and `custom` only when their payload
type is set, then each optional command declared (`gradient`, `shadow`,
`backdrop_blur`, `transform_begin`/`transform_end`, `material`), so a
renderer that declares nothing optional switches over five variants. The
vocabulary of surfaces (`zui.Surface`, `SurfaceKind`, `SurfaceKinds`),
which the renderer contract names, landed here rather than in C2. A frame
carries its record's parameters (`Frame.params`), which a renderer needs
to draw. `zig build check` instantiates a renderer that declares every
optional command and payload type on every target.

The raylib, sokol and terminal renderers are renderers: each has a
`Renderer` whose `config()` builds the `Config` from its declarations and
whose `zuiSubmit` switches exhaustively over the commands. raylib and
sokol draw into their library's own window (`.library`); the terminal
into `.terminal`, by its size in cells, and its `switch` names only the
five base commands. Run here on Windows: raylib's demo saves its
screenshots as before (documents and thumbnail grid), sokol's draws 31
frames from 1 declared, and the terminal's `--dump` prints the showcase.

Against `04461bd`, `zig build counts` in a local Docker container:
declaration unchanged (within 2 instructions in every scenario but new
strings, +0.46%, and depth 64, −0.66%); `endFrame` −0.2% to −4.3% (box
tree −1.7%, 4,000 children −4.3%, documents view −1.9%), from the
`image` and `custom` variants a default config no longer has. Folding
the frame's viewport and zoom into `params` kept declaration flat: a
separate field cost an instruction an element there. `zig build
bench-compare -- 04461bd` (4 rounds) called nothing slower; 4,000
children −5.0% and the documents view's first frame −6.6% faster.

What remains, and where it went:
- **Lowering.** No declaration can yet produce an optional command, so
  there is nothing to lower and `Diagnostics` lists no lowerings; each
  lands, with its lowering test, with the stage-8 item that adds the
  command's declaration (G1, G2, G3, G5, G6).
- **The renderer suite.** "Each backend passes C3's renderer suite" is
  C3's: its plan now includes running `expectRendererConforms` in the
  three backends' CI.

### T2. The whole-string cache

`Limits.string_cache_entries` (1,024 by default, a power of two, with its
compile-error test), and a second table in the measurement cache keyed by
the whole string, its `MeasureKey`, the zoom and the wrap mode. An entry
holds the text's metrics and the widths of up to 16 runs; a hit copies
them into the frame and walks no words, so with T1's fast path a warm
label does no per-word work, and a warm text that wraps reads its word
widths without probing. A text of more than 16 runs is cached by its
metrics alone, and `wrapTexts` measures its runs only when it does not
fit on one line. A golden test lays out wrapping, single-line, long,
newline-separated and zoomed texts in one context over five frames at two
widths and two zooms, against a fresh context each frame, with the run
widths moving between frames; it fails if pending runs are not measured
or if the zoom is left out of the key.

A Callgrind profile first confirmed the cost: at `b99fa79`, 60% of the
warm text wall's `endFrame` was measuring through per-word probes
(`measureMetrics` 27.0%, `Measurer.measure` 21.4%, wyhash 12.1%), and 20%
`wrapLines`. Most of the wall's texts wrap, which is why an entry holds
word widths, not only the metrics SPEC.md §9.3 first listed; the spec now
says so. `1000 new strings, warm words` (its own commit, `77027e8`) is the
frame that changes every string. Against `77027e8`:
- `zig build counts`, in a local Docker container: warm text wall
  `endFrame` −53.8% (2,361,336 to 1,090,886), single-line texts −67.6%,
  documents view −25.9%; new strings +0.3% and the cold wall +1.2%, the
  string hash and probe of a miss; nothing else moved by more than one
  instruction;
- `zig build bench-compare -- 77027e8` (10 rounds): warm text wall
  −56.4% (225.3 to 98.5 µs), single-line texts −71.2%, documents view
  −27.8%; new strings −3.9% and the cold wall −5.0%, faster, not slower;
  first frame of 1,000 texts −6.4%; `init` +19.1% (110.7 to 134.8 µs) and
  `initBuffer` +13.2% (9.5 to 10.8 µs), clearing the new table's 104 KB
  (`init` allocates 4.75 MiB, from 4.61);
- `zig build bench -- --check-targets`: warm text's fastest frame 98.9 µs
  against the 120 µs budget (see *Where we are*).

Laying the tables out as structure-of-arrays moved those page faults from
`init` into the first frame (+76% for the documents view's) and grew the
miss paths by 7% in counts, so the entries stay whole.

### T1. The single-line fast path

`Metrics.has_paragraph_break`, and `wrapLines` emitting a text without one
whose unwrapped width fits as one line, with that width, without walking
its words; a text with `.newlines` and no newline, too. `measureMetrics`
learns of a break from a widest-ended-paragraph width that starts
negative, because a flag carried through its word loop cost about 4
instructions a word. A randomized test checks that the fast path emits
exactly the line greedy wrapping does, over 2,000 texts of spaces,
newlines and letters at random widths; the golden and randomized layout
tests pass unchanged.

The warm text wall wraps nearly every text in its 160-unit panels, so a
new scenario, `1000 single-line texts, warm`, lays the same sentences in
panels 480 units wide (its own commit, `bf807b9`, so each side of a
comparison has it). Against `bf807b9`:
- `zig build counts`, in a local Docker container: the single-line
  scenario's `endFrame` −17.8% (2,287,233 to 1,879,297 instructions), the
  documents view's −7.8% (97,370 to 89,782); the text walls' `endFrame`
  +0.3%, and text declarations +0.8% (one instruction a text, from the
  larger record);
- `zig build bench-compare -- bf807b9` (10 rounds, i9-10900K): the
  single-line scenario −26.2% (216.0 to 159.9 µs, middle half −26.6% to
  −25.7%), the documents view −2.7%; nothing slower.

### C8. The backends on the stage-2 API

The raylib renderer (`66c3d77`), the sokol renderer (`e8ce40f`) and the
terminal renderer (`d7930bb`) move to the API of `2df48f7`, and each
one's CI passes on Linux, Windows and macOS. In each:
- `Platform` is `Text`, the text contract, set by the backend's
  `config()`: `zuiMeasure` with a `MeasureKey`, counting the letter
  spacing after every glyph, and text commands drawn with their spacing
  (per glyph in sokol's built-in bitmap text, to the nearest cell in a terminal);
- the loop builds a `FrameRecord`, takes `endFrame()`'s frame, and waits
  as `nextFrame` says;
- the frame's cursor request is applied where the library has cursors
  (raylib, sokol_app), and focus changes are `window_focused` events.

The demo's thumbnails are a `zui_async.KeyedLoads` source: declaration
asks for the keys of the rows near the visible area, the loader starts
each load as its own task on the application's `Io` after `endFrame`, and
keys unread for 30 frames are abandoned (34 of 98 in a scripted fast
scroll). Measured in the raylib renderer's demo:
- **0% CPU idle.** `--measure-idle` has the demo read its own CPU time
  at two frames it requests 10 s apart. On Windows (i9-10900K,
  ReleaseSafe): 0.0 ms in the thumbnail grid and the settings view,
  31–47 ms in the documents view, with 1 frame (the measurement's own)
  and 0 wakes in each window; Windows counts CPU in 15.6 ms ticks. On
  CI's Linux runner, under Xvfb: 24.0 ms for the grid, 1 frame, 0 wakes.
- **One wake for 100 loads.** A test of the demo's thumbnails asks
  for 100 thumbnails in one frame, finishes them on 100 tasks before the
  next, and counts 1 wake; the next frame shows all 100 and `nextFrame`
  is `.on_event` again.

Decided here:
- **Backends that see events send events.** sokol_app and the terminal
  report events, so their collectors emit them in order and a click
  inside one frame is kept; only raylib, which reports state, goes
  through `zui.InputSampler`.
- **A deadline wakes raylib through a timer.** raylib's `EndDrawing`
  can wait for events but not for a time, so `FramePacer` turns `.at`
  into event waiting plus a task that posts an empty event at the
  instant, sleeping until the instant has truly passed: a wake just
  before it asked for the same instant again and slept for good.
- **sokol_app cannot sleep,** since it presents at every refresh, so its
  demo declares a zui frame only when `nextFrame` or input calls for one
  and redraws the frame it holds otherwise: 2 zui frames in 121 drawn.
- **Idle is measured by the process itself,** between two frames it asks
  for with `requestFrameAt`, so a run ends on its own and the same check
  runs in CI.

### P2. The tracer contract

`Features.Tracer`: a zone per layout pass, per emission step and per
`beginFrame` step, through `zuiBegin` and `zuiEnd`, and nothing analyzed
when it is `void`; `zui.TraceZone` and five compile-error tests; a
recording tracer in `core/src/tests/support.zig`, and a test that one frame
produces every zone, each nested in `begin_frame` or `end_frame`;
`zui_tracy`, with Tracy as a lazy dependency linked by
`-Dzui-tracy=true`, tested with Tracy's client on all three systems (in a
MinGW build Tracy's callstacks are off: with them the process exits with
code 9 after Tracy shuts down); the profiling guide, in README.md's
*Profiling*.

`zig build counts` without a tracer was identical to the instruction in
every scenario, against `994a631`, in a local Docker container.

The trace of the demo was captured headlessly: the raylib renderer's demo built
with `-Dzui-tracy=true` and run with `TRACY_NO_EXIT=1`, Tracy 0.14.1's
`tracy-capture` saving the trace and `tracy-csvexport` listing its
zones. In the thumbnail grid's 36 frames, each of the 14 zones other than
`sort_layers` appears 36 times; in the documents view, whose tooltip floats,
`sort_layers` appears in the 2 frames that showed it. Every zone of
`zui.TraceZone` appears.

### A4. `zui_async`

`zui_async`, the default sources of SPEC.md §19.1, each memory fixed at
comptime in the application's own struct:
- `Latest(T)`: a triple buffer and one atomic byte;
- `Stream(T, .{ .capacity, .producers })`: a ring with a sequence per
  slot, claimed by compare-and-swap for `.many` and a plain store for
  `.one`, refusing the newest item when full;
- `Task(Result, .{ .Progress })`: a `Latest` of its status, one run at a
  time through `begin`, `progress`, `finish`, `abandon` and `clear`, and
  `publishing(f)` to finish a run with a plain function's result;
- `KeyedLoads(Key, Result, .{ .capacity, .unread_frames_before_release,
  .owns_resources, .Progress })`: keys moved from wanted to loading by
  `toStart`, completions through a ring with a place per slot, release
  after `max(unread_frames_before_release, frames_in_flight)` unread
  frames, and with `owns_resources` everything handed back by
  `toRelease`.

Safe builds assert what SPEC.md §14.9 gives the sources: one reader (the
frame numbers `zuiEndFrame` sees only increase), one producer for
`Latest` and `Stream(.one)`, and a run or load finished once. Every
publish reports `Wake`, so 100 loads finishing between two frames cause
one wake, which a test proves with 100 producers on threads.

`zui_testing` gains `expectSourceConforms(Source, harness, .{ .io })` (and
`findSourceViolation`): producers publish items through a harness while
the reader swaps at random intervals, and every frame checks the
delivery against the view and injects it into a replica. It fails on a
lost, repeated, reordered or unreported item, a lost wake, or more wakes
than swaps. All four sources pass it on `std.testing.io` with threads and
on `Io.Threaded.init_single_threaded`, where every producer runs inline
and refuses rather than waits; and under ThreadSanitizer
(`-Dzui-sanitize-thread=true`, through LLVM), locally in a Linux container
and in CI. Weakening `Latest`'s exchanges to `.monotonic` makes
ThreadSanitizer report races, so the suite reaches them. `Driver` takes
the application's `.sources` and gains `frameDelivering`.

Decided here, and written into SPEC.md:
- **`publishing` is declared on the `Task` type** and takes `f`'s
  arguments as one tuple, `.{ run, .{ io, url } }`: `Io.Group.async`
  needs a concrete function type, and a `Run`'s type depends on
  `Progress`, which `f` does not name.
- **`Stream`'s capacity is a power of two,** so positions may wrap a
  32-bit `usize` without changing slot.
- **`KeyedLoads`' `Progress` fits a `usize`,** not 64 bits: 32-bit
  targets have no 64-bit atomic store, and `zig build check` for x86,
  PowerPC and WebAssembly caught it.
- **A slot is reused only after its completion is swapped,** so
  generations are needed only to catch a load finished twice, and exist
  only in safe builds.
- **A key `get` cannot track is reported by the next frame:** refusals
  are counted after the swap, and `get` runs during declaration.
- **`frameDelivering` delivers nothing to a source it does not name:**
  `null` for an optional `Delivery`, `Delivery.empty` otherwise, and a
  compile error naming the source when neither exists.

`zig build counts` against `179e88d`, in a local Docker container: the
core did not change, and every existing scenario is identical but the
documents view's declaration, 5 fewer (38,186), the shift of constant
data R1 describes. A new scenario, depth 64 reading ten idle `zui_async`
sources (four `Latest`, two `Stream`, two `Task`, two `KeyedLoads` with
one key read each frame), takes 16,346 instructions in declaration
against 16,003 for depth 64 alone (about 34 per source: the swaps, a
`KeyedLoads` key hashed and probed), and 24,915 in `endFrame` against
24,881. `KeyedLoads` walks its
slots only once a key could have gone unread long enough; before that
change the scenario's `endFrame` took 25,955.

The demo's thumbnail grid on `KeyedLoads`, idling at 0% CPU, and its 100
loads causing one wake, were done in the raylib renderer by C8.

### A3. Sources in the core

`Config.Sources`, checked at instantiation: a struct whose every field
implements the source contract, with each missing or misspelled
declaration and each wrong signature a compile error naming the field
(`AppSources.quotes`). `beginFrame(record, sources)` swaps each field in
order, or injects `record.deliveries`, in a `swap_sources` zone, and adds
each source's `zuiRefusedCount` to the diagnostics
(`refused_publishes`, `first_refusing_source`). `ui.source(.field)`
returns the field's `View` and records the frame's demand, which
`framesSinceRead` reports; `endFrame` calls each `zuiEndFrame`;
`nextFrame(sources)` is immediate while a source's `zuiPending` is true.
`Ui.FrameRecord`, `Ui.Deliveries` and `Ui.SourceField` are derived from
`Sources`; with `Sources = void` none of this exists and no parameter
changes. The vocabulary is core: `zui.Status`, `StatusWithProgress` (with
`fromResult`), `Waker` (with `wakeIf`), `Wake` and `EndFrameInfo`.
Eleven compile-error tests pin the messages of SPEC.md §14.9.

Decided here, and written into SPEC.md:
- **`nextFrame` takes the sources,** as `beginFrame` does, because zui
  keeps no pointer into them between frames and the loader's publishes,
  made after `endFrame`, must count.
- **`ui.source` outside a frame panics in every build,** for the same
  reason: there is no last view to read.
- **A read is one store** of the frame's number into a per-source
  counter, so `endFrame` settles nothing for the core's own demand.
- **`.failed` carries `Result`'s whole error set:** Zig 0.16 cannot build
  an error set without `Canceled` at comptime. It exists only when there
  is an error besides `Canceled`, and `fromResult` never puts `Canceled`
  in it.
- **"Two contexts swapping one source" is asserted by the source,** as
  the core keeps nothing in it; that assertion and the producer-side ones
  are `zui_async`'s (A4).

`zig build counts` against `66f4ca7`, in a local Docker container, with a
new scenario, depth 64 reading ten sources that receive nothing: its
declaration takes 80 instructions more than depth 64 alone (16,083
against 16,003), about 8 per source, almost all the test source's own
swap and the reads; its `endFrame` takes 1 more (24,882 against 24,881).
Scenarios without sources moved by 6 instructions in declaration (+0.04%
at most), from the two diagnostics fields `beginFrame` resets. That is
how SPEC.md §20.2's "no more instructions than with none" is met: what
remains is each source's own swap. The scenario is deliberately depth 64:
a second instantiation of the documents view made LLVM outline its label
formatting, which raised that scenario's declaration by 5.8%.

### I6. The environment and host requests

`zui.Environment`, kept by the core and changed one field at a time by
`environment` events, which apply before the declaration of the frame
that carries them; `ui.environment()`. `Frame.requests()` returns
`HostRequests`: the cursor of the innermost element under the hovering
pointer that sets `Element.cursor`, and the caret rectangle an editable
asks for with `ui.requestTextInput(editable, caret)` while it is focused.
`zui_widgets` gains `dark_theme`, used while the environment is dark, and
its controls ask for the pointer, or the I-beam over a text field, which
also requests text input at its caret.

Decided here: `EnvironmentChange` is a union with one variant per field,
so applying one is an `inline else`; `Locale` is a BCP 47 tag of up to
23 bytes held inline, so the event stays plain data; the reading
direction is its own `ReadingDirection`, since `Layout.Direction` also
flows top to bottom.

`zig build counts` against `1447ed1`, in a local Docker container: every
scenario within 1% (declaration of the box tree −0.07%, its `endFrame`
+0.06%), as an `Element.cursor` left null is compiled away at each
declaration.

### T3. Letter spacing, through a measurement key

`TextStyle.letter_spacing`, and `MeasureKey { font, size, letter_spacing }`
passed to `zuiMeasure` and used as both the cache key and the hash seed,
with size and spacing multiplied by zoom. Text commands carry the
spacing in their style. Both `FixedMetricsText` contracts (the core's
test one and `zui_testing`'s) now add the spacing after every byte, as
SPEC.md §9.4 asks of every contract, so golden tests lay out spaced text:
it widens every character including the last, wraps sooner, is aligned
by its spaced width, and lays out identically at zooms of 0.5, 1 and 2.
Nothing on a hot path changed, so there is nothing to measure. Drawing
the spacing belongs to the renderers, which C8 did.

### R1. Instruction counts in CI

`zig build counts` runs each single-threaded scenario of `core/bench/` in a
fresh process under Callgrind, collecting only `beginFrame` with
declaration, or only `endFrame`, over 10 frames after 4 of warm-up. The
executable is always built for x86-64-v3 Linux without libc, so every
machine runs the same instructions. CI counts the parent commit with its
own scenarios, then this one, and fails on more than 2% growth.

At `cd534f4` the counts were identical in a local Docker container
(i9-10900K) and in two runs of the CI job. Instructions per frame:

| Scenario | Declaration | `endFrame` |
|---|---|---|
| 4,096 boxes, depth 8 | 766,377 | 1,561,476 |
| 1,000 texts, warm cache | 137,324 | 2,350,337 |
| 1,000 texts, cold cache | 137,326 | 2,344,117 |
| depth 64 | 15,966 | 25,011 |
| 4,000 children of one parent | 471,656 | 1,086,532 |
| documents view | 38,317 | 97,371 |

Warm and cold text cost nearly the same in `endFrame` because the
benchmark's glyph-table measurement costs about as much as a cache probe.
A change anywhere in the executable can still move a count by a few
instructions, by moving the constant data a scenario copies: the
documents view's declaration moved by 5 when only the report's printing
changed.

### R2. `zig build bench-compare -- <ref>`

Builds both commits, alternates them locally, and reports the median
ratio and its spread (SPEC.md §20.3). `zig build bench-compare --
946405e~1 946405e` reports the box tree's declaration −26.4% (middle half
−27.5% to −26.1%) and calls it faster: the `depth: u16` store-forwarding
stall, which left the instruction count unchanged. A commit compared with
itself calls nothing faster or slower. R3 to R7 replaced how it judges a
change; the alternation of each commit's own benchmarks remains.

### P1. Startup benchmarks

`init`, `initBuffer` and first-frame scenarios, in `--json` and
`--compare`. With the library at `a6d8e34`, the fastest samples were:

| Scenario | Fastest |
|---|---|
| `init`, default config (4.63 MiB) | 74.6 µs |
| `initBuffer`, default config | 10.0 µs |
| first frame, Documents view | 30.3 µs (steady: 9.9 µs) |
| first frame, 1,000 texts | 230.0 µs |

The demo's cold start moved to C4, because the demo is the raylib renderer's.

### A1. The async and parallel audit

Done as a design: sources, demand and the loader replace task pools, and
are SPEC.md §14 and §15. The working document was folded into SPEC.md and
deleted. Its two lessons stay:
- **A bounded queue whose bound relies on how often it is drained** is a
  hang waiting to happen. `KeyedLoads` sizes its completion ring by
  claims, so it cannot overflow however rarely it is drained.
- **A cancel that waits on the UI thread** is never acceptable. zui no
  longer cancels anything; an abandon flag is read by the producer at its
  own pace.

### A2. Task completions at `beginFrame`

`beginFrame` applies each pool's completions; `request` only reads. The
code is deleted with `TaskPool` in stage 2 (A5), but what it showed shapes
the sources: completions belong to the frame record, and with an inline
`Io` a result is ready one frame later, not during the request.

---

## Stage 2: the frame record

The breaking change, made once, and done (C8 is in *Done*). What remains
of an item here waits for a later stage, as its **Status** says.

### C5. `Context(config)` and the text contract

**Grounding.** `Platform` mixes what belongs to three parties: text
measurement belongs to the renderer (it owns the fonts), `wake` to the
host (it owns the loop), and `scale()` is read during the frame, outside
any record, so a replayed frame can lay out differently from the
original.

**Plan.** `Context(comptime config: Config)`, with `Config.Text` holding
the text contract (`zuiMeasure`, optional `zuiSegment`,
`zui_thread_safe`, `zuiFingerprint`), and `init(gpa, io, text)`. With
`Text = void`, `text` is absent from the API. The rule that every
`zui`-prefixed declaration must belong to a contract is checked here
first.

**Done when:** every test, widget and benchmark builds on `Context(config)`;
compile-error tests pin each contract message.

**Status.** Done in the core.

**Spec.** §4, §5, §9.4, §16.1.

### S1. The frame record's parameters: time, scale and zoom

**Grounding.** `Platform.scale` only snaps command bounds
(`core/src/emission.zig:32`). Nothing lets an application zoom its UI. Time
arrives as `dt_seconds`, so deadlines and velocities cannot be expressed
in the host's clock.

**Plan.** `FrameRecord.params = .{ now, viewport, scale, zoom }`.
`ui.dt()` is derived from two records. Layout stays in logical units;
text is measured at `size × zoom`; snapping uses `scale × zoom`.

**Done when:** golden tests at three zoom levels, and a replayed record
reproduces the frame exactly with any scale.

**Status.** Done but for replay, which waits for F2 and F4.

**Spec.** §6.2.

### I4. Input as an ordered event log

**Grounding.**
- `Input.buttons` is the state at poll time (`core/src/context.zig:902`), so a
  press and release between two polls is never a click. zui sleeps until
  input arrives, which makes that likely, and a touch tap usually
  vanishes.
- There is one pointer: one `press_target` and one `hover_chain`
  (`core/src/interaction.zig:181`).
- `Key` has no letters (`core/src/interaction.zig:8`), so Ctrl+S cannot be
  expressed, and modifiers are sampled once per frame rather than per key.

I3, which was to settle this format before the host contract, is merged
here: the format is SPEC.md §7.

**Plan.** `FrameRecord.events` as SPEC.md §7.1; a pointer table of
`max_input_contacts`; moves coalesced per pointer; `Key` with letters,
digits, punctuation and function keys, plus the opaque scancode;
`chordPressed`;
`zui.InputSampler` for backends that report only state;
`zui_testing.Driver` emitting events, with `tap`, `pinch` and
multi-pointer `drag`. First rebuild `resolveInput` over the log with
`max_input_contacts = 1` behind today's queries, then widen.

**Done when:**
- the interaction, widget and `zui_testing` tests pass on events;
- a press and release inside one frame is a click;
- 133 moves in one frame cost at most one hover hit test per pointer;
- two pointers press two buttons at once;
- R1's counts on the mouse-only scenarios are no higher than before.

**Status.** Done (`pinch` came with I5) but for R1's
counts: `zig build counts` has no scenario with input yet, and commits
from before I4 cannot be counted by today's scenarios, so the mouse-only
check becomes a counted input scenario that later changes must not grow. Every hovering pointer is hit-tested once a
frame even without a move, so hover follows a layout that moved under a
still mouse. A lifted touch stays readable until the next frame, so the
frame that sees a tap can ask where it was.

### I2. `nextFrame()`

**Grounding.** `needsFrame` is yes or no. A blinking caret needs "a frame
at this instant", and a frame-rate cap needs to know it.

**Plan.** `NextFrame = union { immediately, at: Instant, on_event }`,
from requested frames, pending sources, `requestFrameAt`, momentum and
gesture timers. `needsFrame` goes.

**Done when:** a test's caret blinks with frames only at its instants,
and an idle context reports `.on_event`.

**Status.** `requestFrame`, `requestFrameAt` and pending sources (A3) are
done; so are long-press and double-tap timers and momentum (I5).

**Spec.** §6.6.

### C6. `endFrame` always returns a frame

**Plan.** `endFrame() *const Frame`; the part that fit is laid out, and
`frame.diagnostics` names the limit, by how much, the peak and the first
id. `diagnostics.check()` returns `error.CapacityExceeded`. `lastFrame`
goes. `tryBeginFrame` for hosts that cannot block.

**Done when:** the memory tests pass with the new reporting, and a frame
over every limit still draws what fit.

**Status.** Done.

**Spec.** §6.3, §6.5, §17.

### A5. Delete `TaskPool`

**Plan.** Remove `src/tasks.zig`, its tests and every reference; the
demo's loads move to A4's sources.

**Done when:** nothing in the core or the renderers names a task
pool.

**Status.** Done; the backends and the demo's loads moved off it in C8.

---

## Stage 3: the contracts

Done: C1, C2, C3, C7, C4 and H1 are in *Done*. Lowering comes with
stage 8's commands; the sokol and terminal renderers remain without
a host of their own, and the sokol renderer gains a native surface
with H2.

---

## Stage 4: a native host

Done: H2 and H8 are in *Done*.

---

## Stage 5: the wire

F1, feeds, is retired: sources (A3) are the mechanism for outside data.
Done: F2, F3, F4, F5, F6 and F7 are in *Done*.

---

## Stage 6: text and layout

Done: T1, T2, L8, P4, P5, T4, L1, L2, L3, L4, L6, L7 and C10 are in
*Done*.

---

## Stage 7: gestures

Done: I5 and I1 are in *Done*.

---

## The foundation, after stage 7

G1's first slice (`80db29e`, on `wip/g1-gradients-shadows-and-glow`)
passed every test but ran 5.5% more instructions in the box tree's
declaration and 7.7% more in the wide tree's, scenes that draw no
effect. Rather than build stage 8 on that, the work turned to the
measurements and the code under it: a data-oriented design audit, scenes
for the paths it found unmeasured, benchmarks that could judge its
changes (R3 to R9, planned in `docs/plans/benchmarking.md` as B1 to B8),
and the audit's findings (P6 to P12). With these done or waiting, stage
8 resumed, and G1 landed on `main` (in *Done*).

---

## The data-oriented design audit

`DOD-AUDIT-2026-11-09-5b032b7.md` found the costs next to the layout
sweeps, in paths no benchmark ran until `db4ea4d` added scenes for them:
floating layers, ids on every element, and a pointer pressing. The owner
put its findings ahead of stage 8. P6 (the layer sort), P7 (the id → rect
table), P8 (one hit test per press), P9 (wrapped lines kept with the string
cache) and P10 (the string cache's keys apart) are in *Done*, and so is
P11 (flat child lists), retired on its profile. So is P12 (text
commands that point at their style), retired when a scene that reads
the commands as a renderer does was no faster with it.

Each item is judged by `bench-compare` against its parent, with turbo
off, and by `counts`; one that costs more elsewhere than it saves in its
scene does not ship.

---

## Stage 8: effects

Done: G1, G2, G7, G3, G5 and G6 are in *Done*.

---

## Stage 9: seeing the UI

Done: V1, V2, V3 and V4 are in *Done*.

---

## Stage 10: reach

- **H4. Linux** (Wayland, then X11; KDE blur where offered).
- **H5. Web** (a canvas surface, on the loop H10 gives a host that cannot
  block).
- **H6. Services:** clipboard, notifications, file dialogs, opening URLs,
  native menus, each an optional host declaration.
- **H7. Window decorations:** native by default; a custom title bar uses
  chrome regions so the OS still moves, resizes and snaps the window.
- **H9. Many windows:** one `Context` per window, with sources published
  into each.
- **H10. Hosts whose platform owns the loop:** the browser's main
  thread, macOS, iOS and Android, driving `zui_app` from their own
  callbacks, and a surface the platform takes away and gives back.

**Done when (each):** the host passes C3, and the demo runs on it
unchanged.

H3, the macOS host, is set aside under *macOS, for later*, and stage 10
is done without it.

### H4. Linux

**Grounding.** `hosts/native/` has one directory per OS, and `zui_host.Host`
is a compile error on anything but Windows (`hosts/native/zui_host.zig:8-11`); its
build links Win32 libraries and builds the examples only there
(`hosts/native/build.zig:17-19`, `hosts/native/build.zig:43`). The Windows host is the shape to
follow: an `Inbox` of events in physical pixels (`hosts/native/windows/host.zig:84`),
converted to layout units at `zuiPoll` (`:203`, `:245`), a sticky wake
cleared after the wait (`:272`), and a harness that delivers what the OS
would, synchronously, to the host's own handlers
(`hosts/native/windows/conformance.zig:36`, `:66`). Its message loop runs on a thread
of its own (`:348`) only because Windows runs moves and resizes in a
modal loop; a Wayland client has no such loop, so one thread suffices.
SPEC.md §16.4's `wayland` surface is a display and a surface
(`core/src/surface.zig:48`), the objects of libwayland-client: EGL's and
Vulkan's Wayland platforms take exactly those, so a host that spoke the
protocol itself would give a surface no GPU driver can draw into.
sokol-zig links libwayland-client, libwayland-egl, libxkbcommon and EGL
for its own Wayland window (its `build.zig`, the `wayland` option), so
linking them is the ecosystem's way. `zui_sokol` draws into a native window
only on Windows (`renderers/sokol/src/renderer.zig:29`, `:50`, `:119`), through a context
of its own, as `renderers/sokol/src/wgl.zig` does with WGL; on Linux sokol_gfx draws with
OpenGL, so a `.wayland` surface is an EGL context on a `wl_egl_window`.
The tour on the host (`hosts/native/examples/tour.zig:171`, `:114`, `:217`) names
`.win32` and reads the process's CPU time and the screen through Win32.

**Plan.** In slices, each passing C3 where it can run:
1. **A Wayland window** (`hosts/native/linux/`): libwayland-client with xdg-shell's
   interfaces written in Zig, a `.wayland` surface, integer scale from
   `wl_surface.preferred_buffer_scale`, the pointer, the wheel by
   notch, keys through xkbcommon with modifiers, the evdev code and
   typed text, focus, the close button, the cursor through
   `wp_cursor_shape_v1`, and waits on the display, an `eventfd` wake and
   a deadline. `zui_sokol` draws into `.wayland` through EGL; the tour runs
   on it; the host suite runs against an unmapped window, skipping with
   a message where no compositor runs.
2. **Repeat, lifecycle and the environment:** key repeat from
   `repeat_info`, SIGINT and SIGTERM as `.terminate_requested` (the
   handler sets a flag and wakes), the theme, contrast and reduced
   motion from the XDG desktop portal's settings over D-Bus, and power
   from UPower.
3. **Fractional scale, the clipboard, drops and file watching:**
   `wp_fractional_scale_v1` with `wp_viewporter`, `wl_data_device`'s
   selection as `zuiClipboard` and its drops as `files_dropped`,
   `zuiFileWatch` through inotify; `zig build theme` on Linux.
4. **Services,** H6's shapes on Linux: notifications through
   `org.freedesktop.Notifications`, file dialogs through the desktop
   portal's `FileChooser`, URLs through its `OpenURI`, on the host's own
   D-Bus client; no `zuiMenus`, which Wayland lacks; `zig build services`
   on Linux.
5. **The IME:** `zwp_text_input_v3`, enabled while a frame asks for text
   input, its cursor rectangle at the caret, committed text as `text`.
6. **A custom title bar,** H7's on Linux: `xdg-decoration` asked for
   client-side, presses on `.caption` and the edges handed to
   `xdg_toplevel.move` and `resize`, the caption buttons worked by the
   host, `window_maximized` from the toplevel's states; `zig build
   title-bar` on Linux.
7. **Many windows,** H9's on Linux: the host `.many`, a toplevel and a
   surface per window, and `zui_sokol` attaching a `wl_egl_window` and
   `EGLSurface` per window on one `EGLContext`; `zig build many-windows`
   on Linux.
8. **The material:** an alpha surface, KDE's `org_kde_kwin_blur` where
   KWin offers it, and `ext_background_effect_v1` where a compositor
   offers that, reported as `Environment.system_material`.
9. **X11:** an X11 host with the same reports, and `zui_host.Host`
   choosing Wayland when a compositor answers and X11 otherwise, its
   surface `.wayland` or `.x11`; `zui_sokol` draws both through EGL.

Slices 4, 6 and 7 were added when the Windows host's H6, H7 and H9 had
landed, so that the Linux host makes every report the Windows host makes.

**Done when:** the host passes C3 on Wayland and on X11, in CI under a
headless compositor and Xvfb; the tour runs on it unchanged and
idles at 0% CPU; and the theme example restyles on a file change.

**Spec.** §7, §16.3, §16.4, §21 (stage 10).

**Status.** Slice 1 is done: `aab0e37` (`hosts/native/linux/host.zig`,
`hosts/native/linux/wayland.zig`, `hosts/native/linux/xkb.zig`, `hosts/native/linux/keys.zig`) and
`77e9448` (`renderers/sokol/src/egl.zig`). On Hyprland with an NVIDIA RTX 2060
SUPER, the host suite and six tests of the host's own pass in Debug,
ReleaseFast and ReleaseSafe against a window the compositor never shows,
and skip with a message without a compositor; the tour drew 1,500 frames
across every screen in a tiled window, seen in a screenshot, with no
layer overflow; and Layout Lab idled at 1.2 to 4.4 ms of CPU over 10 s,
with 0 or 1 frames and no wakes, in five ReleaseSafe runs of six (the
sixth drew 96 frames for the pointer over the window). The native hosts'
CI gains a Linux job under a headless Weston, which passes (`d703a34`).

Slice 2 is done in `hosts/native/` alone, `3bd5c13` (`hosts/native/linux/host.zig`,
`hosts/native/linux/dbus.zig`, `hosts/native/linux/desktop_bus.zig`), reporting what the Windows host reports
(`hosts/native/windows/host.zig:504`, `:534-544`, `:672-706`, `:768-777`) where Linux
has it. A held key repeats at `repeat_info`'s rate and delay, each repeat
a `key_down` with `repeat` set that types again, and a wait ends at the
next repeat. SIGINT, SIGTERM and SIGHUP set a flag and wake, and the next
poll delivers `.terminate_requested`, after which the window reports
closed; logind's `PrepareForSleep` is `.suspend` and `.resume`. The
theme, contrast and reduced motion come from the portal's
`org.freedesktop.appearance` settings (`ReadAll`, then `SettingChanged`),
and power from UPower's `OnBattery` and power-profiles-daemon's
`ActiveProfile` (`power-saver` is `.saver`), each change as signalled,
the buses' sockets waited on beside the display. Without a bus, portal
or daemon they stay at zui's defaults, and `environmentSources()` says
which answered. On Hyprland, with the portal, UPower and
power-profiles-daemon running, `init` took 1.9 ms in all and the first
record held the dark theme the portal reported; the host suite and 13
tests of the host's own pass in Debug, ReleaseFast and ReleaseSafe, 15
unit tests beside them, one of which plays the portal on a
`dbus-daemon` of its own and checks that its answer and signal arrive
and an impostor's signal does not (CI starts such a daemon). The tour
drew 300 frames across every screen with no layer overflow, and Layout
Lab idled at 9.7 to 15.2 ms of CPU over 10 s with 9 to 11 frames and no
wakes in three runs of four (the fourth drew 58 frames for the pointer),
as `d703a34` did the same day (10.6 and 12.8 ms, 9 and 10 frames): a run
counted no reads of either bus while idle, and the frames come from the
compositor's events. Not reported yet: `.low_memory` (the Windows host's
memory notification has no unprivileged counterpart but pressure
triggers), reduced transparency and text scale, which the portal does not
carry.

Slice 3 is done in `hosts/native/` alone, `3f3d57a` (`hosts/native/linux/data_device.zig`,
`hosts/native/linux/file_watch.zig`). With `wp_fractional_scale_v1` and
`wp_viewporter` both offered, the record's scale is `preferred_scale /
120` and the buffer `round(size × scale)` with a buffer scale of 1; one
function, `pixelsPerSurfaceCoordinate`, converts surface coordinates, and
`forced_scale` still wins. `zuiClipboard`, in H6's shape, offers a
`wl_data_source` of three text types and reads the selection through a
pipe from the wait loop, each transfer bounded at 2 s, into 64 KiB with
text past it cut at a character and counted; until another selection is
named, a read answers the last text written. Hyprland names a selection
only to the focused client, so the unshown suite reads its own text, and
an opt-in test (`ZUI_HOST_TEST_SHOWN_WINDOW=1`) shows a window for a
moment and reads back through the compositor; the suite leaves the
desktop's clipboard empty, as the Windows host's overwrites it. Drops of
`text/uri-list` arrive as one `files_dropped` at the drag position,
`file://` URIs percent-decoded. `zuiFileWatch` reads one inotify
descriptor in the same `ppoll`, without threads: 4 roots and 256
directory watches, a subdirectory watched as it appears and what it
already holds reported as added, overflow published as a rescan. `zig
build theme -- --check` restyled 18.7 ms after the file was rewritten,
against 2 to 4 ms on Windows. The tour idled at 10.3 and 10.8 ms of CPU
over 10 s, 9 and 10 frames, no wakes. Not run: a drag from another
application, and a fractional scale on a monitor (the tests convert at
1.25 and 1.5 through the listeners).

Slice 4 is done in `hosts/native/` alone, `342302e` (`hosts/native/linux/services.zig`,
`hosts/native/linux/dbus.zig`): H6's shapes on a second session-bus
connection of the host's own, its socket in the same `ppoll`. A call
only writes, at most 100 ms, and answers are published from `zuiPoll`
and `zuiWait`. `zuiNotifications` calls `org.freedesktop.Notifications`'
`Notify` with a `default` action, `ActionInvoked` answering
`.notification_activated` and `NotificationClosed` (or a replacement)
`.notification_dismissed`, from the daemon's unique name only, its match
rule added only while one shows, so an idle host reads no other
application's notifications. `zuiFileDialogs` calls the portal's
`FileChooser`, its `Response` match on the predicted request path added
before the call; `file://` URIs are decoded to paths. `zuiOpenUrl` calls
the portal's `OpenURI` without a reply. No `zuiMenus`. Without a bus a
call is `error.Unavailable` at once; without the daemon or the portal it
answers `.failed = .unavailable`. With `ZUI_HOST_TEST_SESSION_BUS` on a
private `dbus-daemon`, tests play the daemon and the portal: a
notification's arguments and signals, an impostor's ignored, a dialog's
paths and cancel, `OpenURI`'s URL; 57 of 58 tests pass in Debug,
ReleaseFast and ReleaseSafe with both slices, one opt-in skip. `zig
build services -- --check` exits 0, copying and pasting through slice
3's clipboard; against the real desktop, quickshell numbered a
notification and the portal answered `OpenFile`. Tour idle: 10.2 to 13.9
ms of CPU over 10 s, 9 to 11 frames, no wakes, as without the change.
The Linux check draws nothing: `zui_sokol` drawing a surface the
compositor never shows waits in `eglSwapBuffers` for a frame callback
that never comes, which slice 7's hidden many-windows check will meet.
Slice 5 is next.

Decided here:
- **libwayland-client, linked,** as sokol-zig links it, since the surface
  must be its objects; xdg-shell's and cursor-shape-v1's interfaces are
  written in Zig rather than generated at build time, so the build needs
  no wayland-scanner or protocol files.
- **One thread:** the host reads and dispatches in `zuiPoll` and
  `zuiWait`; a wait ends on input, a wake, a configure, a new scale or
  the close button, and the compositor's other events (a buffer
  released after each frame) are dispatched without ending it, which is
  what lets the tour idle.
- **The renderer sizes the surface:** `zui_sokol` resizes its
  `wl_egl_window` to each frame's viewport in physical pixels, since a
  Wayland surface has no size until a buffer is attached.
- **An unshown window is a surface without a role,** so the suite runs
  against a real compositor without showing a window.
- **A logical key** is the keysym at the key's first level, or its US
  place where that names no key; `scancode` is the evdev code.
- **A D-Bus client of the host's own,** not libdbus or sd-bus. Slice 1
  linked libwayland because a surface must be its objects for EGL to draw
  into; nothing outside the host shares a D-Bus connection, so no such
  reason holds here. The portal and the daemons need a SASL `EXTERNAL`
  handshake, a few method calls and three signals over a Unix socket,
  about 900 lines beside their tests, read into fixed buffers on the
  polling thread, so the host allocates nothing after `init` and waits
  on the buses in the same `ppoll` as the display. libdbus would add a
  runtime dependency and a `-dev` package, allocate per message, need
  `dbus_threads_init_default` and a watch-and-timeout main-loop
  integration; sd-bus would tie the host to systemd's libraries, which
  musl distributions lack.
- **The first frame has the desktop's settings:** `init` waits up to
  250 ms for the answers, and one that comes later arrives as a change.
  Match rules name the sender, so another client's signal is not taken
  for the portal's.
- **A signal the application handles or ignores is left alone,** and the
  host's handler resets itself as it runs, so a second Ctrl+C ends a
  process the first did not.
- **Repeats keep their own instants,** and a frame late by more than four
  gets four, not a burst.

### H7. Window decorations

**Grounding.**
- Before H7, nothing implemented chrome regions. SPEC.md listed
  `Frame.chromeRegions()` (§6.5), and §13.4 had one sentence about them.
- Hit regions are not a list in the frame. Emission writes them into the
  context's `memory.results` (`core/src/emission.zig:65-66`, `:328-331`), so
  chrome is computed beside the frame instead, after layout, and emission
  is not touched. Its walk is copied per frame kind because any change to
  it moved `endFrame` by up to 5% (`core/src/emission.zig:56-61`).
- The pattern for data beside a frame is V2's: a list in `FrameSlot`
  (`core/src/context.zig:771`). Any field added to `Frame` moved R1 counts.
- `appendElement` is `inline`, so an `Element` field left at its default
  costs nothing. V2's `semantics` field left the counts identical with the
  feature off.
- The Windows host:
  - runs its message loop on a thread of its own
    (`hosts/native/windows/host.zig:541`);
  - sizes the window with `AdjustWindowRectExForDpi` (`:588`);
  - handles no non-client message, and sets the application's cursor only
    over `HTCLIENT` (`:724`);
  - stores requests under its SRW lock in `zuiApply` (`:479`), for the
    window thread to apply (`:864`);
  - extends the frame over the client for Mica (`:900`), and sets dark
    mode in `reportEnvironment` (`:914`).
- H6's `zuiMenus.setBar` (`hosts/native/windows/host.zig:150`) sets a native menu bar,
  which is non-client.

**Plan.** A custom title bar is asked for in `WindowOptions`. The
application marks its parts with `Element.chrome`, behind
`features.chrome_regions`. The frame lists them in a slot beside it, and
`zui_app` hands the list to the host through an optional frame call,
`zuiChromeRegions`, as it hands semantics to `zuiSemantics`. The Windows
host keeps a snapshot, answers `WM_NCHITTEST` from it, and works the
caption buttons itself.
1. **The core, `zui_app` and `zui_testing`** (core only):
   - `ChromeKind`, `ChromeRegion` (`core/src/chrome.zig`).
   - `TitleBar`, `WindowOptions.title_bar` and
     `HostCapabilities.custom_title_bar` (`core/src/host.zig`).
   - `Environment.custom_title_bar` and `.window_maximized`, with their
     changes (`core/src/input.zig`).
   - `Features.chrome_regions`, `Element.chrome`, `Frame.chromeRegions()`,
     and the list in `FrameSlot` (`core/src/context.zig`).
   - `zuiChromeRegions` checked as a frame call, and `custom_title_bar`
     checked against it (`core/src/contracts.zig`).
   - `zui_app.Options.title_bar`.
   - A step in the host suite.
2. **The Windows host** (`hosts/native/`, then the documents):
   - `WM_NCCALCSIZE` removes only the caption, so DWM keeps the border,
     the rounded corners and the shadow. A maximized window is inset by
     the frame's thickness.
   - `WM_NCHITTEST` answers, in this order:
     - `DefWindowProcW`'s border codes;
     - a top resize band, from `SM_CYSIZEFRAME + SM_CXPADDEDBORDER`, when
       not maximized;
     - a snapshot of the regions, from the last to the first, under the
       lock taken shared (`HTCAPTION`, `HTMINBUTTON`, `HTMAXBUTTON`,
       `HTCLOSE`, `HTTOP` … `HTBOTTOMRIGHT`, `HTCLIENT`);
     - otherwise `HTCLIENT`.
   - `WM_NCMOUSEMOVE` and `WM_NCMOUSELEAVE` become pointer moves and
     leaves at client points.
   - `WM_NCLBUTTONDOWN` and `WM_NCLBUTTONUP` on a caption button become a
     press and a release, and the host minimizes, maximizes or restores,
     or closes on the release.
   - Presses on the caption and the edges go to `DefWindowProcW`, which
     moves, resizes, maximizes on a double click and opens the system
     menu.
   - Public `minimize`, `toggleMaximized` and `close` let an application
     act on `clicked` for the keyboard and Narrator.
   - The snapshot holds 256 regions, and nothing is allocated after
     `init`.
   - Conformance tests send `WM_NCHITTEST` and the non-client mouse
     messages to hidden windows.
   - `hosts/native/examples/title_bar.zig` and `zig build title-bar`.
   - Under a custom title bar `zuiMenus.setBar` answers
     `error.Unavailable`, since a native bar would sit hidden under the
     drawn one.

**Decisions.** Made by the owner when H7 was taken:
- The host works the caption buttons, as the system's own. It also has
  public calls for an application that acts on `clicked`. Slice 2 found
  that a pointer's click would then be worked twice, by the host and by
  `clicked`, and a double maximize undoes itself, so the host ends a
  caption button's press with `pointer_cancel`: zui shows the press and
  reports no click, and `clicked` comes only from the keyboard and
  assistive technologies.
- Under a custom title bar `zuiMenus.setBar` is `error.Unavailable`
  (recorded in H6 too).
- The channel is an optional frame call, `zuiChromeRegions`, not a field
  of `HostRequests`.
- A title bar's `.client` regions are derived from its interactive,
  disabled and scrolling descendants.
- The Windows host makes the top resize band itself.
- The title bar's state is reported in `Environment`.
- `zui_app.start` refuses `.custom` without the feature.
- A person checks it on a new `hosts/native/examples/title_bar.zig`.

**Done when:**
- A core test lists declared chrome with its bounds and its `.client`
  regions.
- `zui_app` hands the host each frame's list.
- `zui_host`'s tests get `HTCAPTION`, `HTMAXBUTTON`, `HTMINBUTTON`,
  `HTCLOSE`, `HTCLIENT` and the edges from `WM_NCHITTEST`, and the host
  suite passes on a custom window.
- A person drags, double-clicks, snaps with Win+arrows, sees snap layouts
  over the maximize button, and resizes from every edge on
  `zig build title-bar`, with Mica and dark mode showing.
- With the feature off, R1 counts are unchanged.

**Spec.** §6.5, §7.2, §10.1, §13.4, §16.3, §19.5.

**Status.** Slice 1, the core, is done:
- `Element.chrome` declares a `ChromeKind`, ignored without
  `features.chrome_regions`.
- `Frame.chromeRegions()` lists the declared chrome in tree order, with
  each element's laid-out bounds and id. Each title bar is followed by a
  `.client` region for each interactive, disabled or scrolling element
  inside it that declares no chrome, in one walk that visits each element
  once from the first chrome element on.
- The list lives in `FrameSlot` beside the semantic list. It holds
  `max_elements` regions, since each element adds at most one, so no
  limit was added.
- `zuiChromeRegions(window, regions)` is a host frame call, checked as
  `zuiSemantics` is. A host whose capabilities set `custom_title_bar`
  without it is a compile error.
- `zui_app` hands the list to the host after `zuiSemantics`, on the UI
  thread and before the frame is submitted, so a render thread never
  races it. `Options.title_bar = .custom` without the feature fails
  `start`.
- The host suite hands a host that declares the call two regions from a
  buffer it then overwrites.
- R1, measured by CI's counts job on `6b6ce6f` against its parent
  `e2ba59b`: every scenario's declaration and `endFrame` per frame is
  identical to the instruction (4096 boxes declare 436,605 and
  `endFrame` 1,264,648; 1000 warm texts' `endFrame` 654,147).

Slice 2, the Windows host (`0e3e704`), is done:
- A window opened with `title_bar = .custom` drops its caption in
  `WM_NCCALCSIZE` and keeps the system's frame on the other three sides,
  so DWM draws its border, rounded corners and shadow. Maximized, its
  client top is inset by the frame's thickness. It is sized so its client
  area is still the size asked for.
- `WM_NCHITTEST` answers the system's borders, then a top resize band
  (`SM_CYSIZEFRAME + SM_CXPADDEDBORDER`), then a snapshot of the regions,
  the last on top. The snapshot is one `ChromeSnapshot` field with its
  own SRW lock, holding up to 256 regions in pixels, ready for H9 to move
  into each window's state.
- Non-client moves and leaves over the caption buttons reach zui at
  their client points. A press and its release on the same button work
  it through `WM_SYSCOMMAND`, and the release arrives as `pointer_cancel`.
  `Host.minimize`, `Host.toggleMaximized` and `Host.close` serve the
  keyboard and Narrator.
- The first report includes `custom_title_bar`, and `WM_SIZE` reports
  `window_maximized`. `zuiMenus.setBar` is `error.Unavailable` under a
  custom title bar.
- The host suite passes on a custom window. New tests send
  `WM_NCHITTEST` at the title bar, a search field inside it, each
  caption button, a grip, the top band and the three borders at a scale
  of 2, from a buffer overwritten after the call. They also send
  non-client moves, leaves, presses and releases, and check that a
  native window keeps the system's answers.
- `zig build title-bar -- --check` hit-tests each part as `zui_app` laid
  it out in a hidden window, and exits 0.

Waiting on a person, on `zig build title-bar` in `hosts/native/`, with and
without `--no-system-material`, in light and dark mode:
- Dragging the title bar moves the window, double-clicking it maximizes
  and restores it, and right-clicking it opens the system menu.
- Win+Up, Win+Down, Win+Left and Win+Right snap the window, and so does
  dragging it to a screen edge.
- Hovering the maximize button shows snap layouts.
- Resizing works from all four edges and four corners, the top included.
- The caption buttons show hover and press, and minimize,
  maximize/restore and close each work once.
- Maximized, the title bar is not cut off at the top.
- Mica, dark mode, and the DWM border and shadow show.
- Moving the window to a monitor at another scale keeps the parts where
  they are drawn.
Once checked, H7 moves to *Done*.

### H10. Hosts whose platform owns the loop

**Grounding.**
- `zui_app.run` owned the loop: `while (try runner.frame()) {}`, each
  turn polling the host, declaring and submitting, then blocking in the
  host's `zuiWait`, so nothing could turn it without blocking. The host
  contract required `zuiWait` (`core/src/contracts.zig:144`).
- The web host's worker forked the frame logic to get a turn that does
  not block: `TourSession.frame` (`hosts/web/src/tour_session.zig:182`)
  begins and ends the tour's frames itself, `frameReason` (`:262`)
  repeats `zui_app`'s judgement of whether a frame is due, and `nextWake`
  (`:249`) folds the stepped `Io`'s next wake into `nextFrame`.
- `zui_raylib.Host` began raylib's drawing in `zuiPoll` and presented it
  in `zuiWait`, so it could not be polled without being waited on.
- The browser's main thread, macOS, iOS and Android own their loops and
  call the application back; Android and a lost GPU device also take the
  surface away and give it back. `zuiAttachSurface` and
  `zuiDetachSurface` (`core/src/contracts.zig:23`) already let a renderer
  drop and take a window's surface while its context lives on (H9).

**Plan.** One non-blocking step is the unit of `zui_app`'s frame logic,
and three loops turn it (open decision 2, settled: the owner's choice of
option D). A host is two halves: the window half every host gives
(`zui_surfaces`, `zuiPoll` as a drain that never blocks or presents,
`zuiWaker`, `zuiSurface`, `zuiApply`), and at most one call of the loop
half:
- `zuiWait`: zui pulls the loop, `run` stepping and waiting in turn;
- `zuiRun(self, io, window, driver)`: the platform pushes it, and the
  host calls a `zui.Driver` from its callbacks (`start(io)`, `step`,
  `suspendSurfaces`, `resumeSurfaces`, `stop`), scheduling each turn as
  the `NextFrame` the step returns says; `run` returns as `zuiRun` does,
  `noreturn` included;
- neither: only the application's own loop steps a `zui_app.Session`.

In slices, each a commit with every check green:
1. **The step.** `Runner.frame` splits into `step`, which never blocks and
   judges which windows are due on the one-window path as on the many,
   and `wait`. `NextFrame.sooner` folds two schedules; `Context.hasFreeFrame`
   says whether `beginFrame` would wait. raylib's renderer presents in
   `zuiSubmit`, and its host's `zuiPoll` only drains.
2. **The split contract.** `zuiWait` becomes the optional loop half beside
   `zuiRun` and `zui.Driver`; `Runner` becomes `Session`, with `Loop`,
   `runWith` and a compile error for each mistake; SPEC.md, README.md,
   ARCHITECTURE.md and the feature tour describe it.
3. **Surface loss.** `Session.suspendSurfaces` and `resumeSurfaces`
   detach and re-attach every window's surface through the renderer.
4. **The browser's worker on `Session`.** A stepped host over the page's
   records, `zui_wire`'s renderer and the tour's own `App`, in place of
   `TourSession`'s frames; the owner of the stepped `Io` folds its next
   wake with `sooner`.
5. **Conformance.** `zui_testing` suites for a host that runs its loop
   and one that is stepped, beside the pull suite.

**Done when:**
- `zui_app`'s tests drive a fake host that runs its loop from a scripted
  list of callbacks, on a UI-thread and a render-thread renderer: input
  reaches its window, a step declares only what is due, a lost surface
  is let go and given back with every context and the application's
  state kept, and `run`'s type is `noreturn` for a `zuiRun` that is;
- an application's own loop steps a `Session` on a host with no loop
  half, and declares only the frames that are due;
- every new rule is a compile error with its message pinned;
- the web host's worker runs the tour through `Session`: `test-demo`,
  `test-draw`, `test-input` and `test-site` pass, the worker and the
  native `tour-frames` writing the same bytes;
- every native host's and renderer's tour cycle still prints
  `diagnostics ok: true`, and R1 counts are unchanged.

**Spec.** §6.1, §6.3, §16.2, §16.3, §19.4, §19.5.

**Status.** Slice 1 is done: `Runner.step` and `wait`, one judgement of
whether a frame is due for one window and many, `NextFrame.sooner`,
`Context.hasFreeFrame`, and raylib presenting from its renderer (raylib
built with `SUPPORT_CUSTOM_FRAME_CONTROL`, its host polling input once a
turn in `zuiWait`). The turn after `zuiWait` stays due for an
application with one window, measured: without that rule an idle tour
declared 10 frames in 10 s on the Wayland host against 11 (24.8 against
27.9 ms of CPU, within noise), and 10 against 10 on raylib; the busy
cycles were unchanged; nine of `zui_app`'s tests and the showcase's,
whose fake hosts return from every wait with an empty record, declared
fewer frames. Too little to gain for a frame a host's wait may ask for
without a record that shows it. Slice 2, the split contract, is next.

---

## Stage 11: polish

- **M1. `zui_motion`:** tweens over `state(id, T)` and `dt()`, requesting
  frames by instant and finishing at once under `reduced_motion`.
- **M2. Exit animations:** `exit_seconds` and the ghost buffer.
- **E1. Text editing:** selection, word movement, the clipboard through
  the host, multiple lines, and IME composition with the IME area in
  `HostRequests`.
- **K1. `zui_color`:** OKLab, OKLCH and HSL, mixing and palettes, at
  comptime.
- **K2. The default skin:** light, dark and high contrast, following the
  environment.
- **K3. `zui_icons`.**
- **K4. `zui_themes`:** skins for Windows, GNOME and KDE, in `themes/`. macOS's skin
  is set aside under *macOS, for later*.
- **K5. The skin contract:** `Widgets(Ui, Skin)` and `zuiStyle`, so a
  theme pack restyles every widget without forking it.
- **D1. The template project,** in `examples/template/`.
- **D2. Samples:** a settings screen with `zui_reflect` and ZON, a data
  feed, a multi-window tool, a remote session.
- **D3. A developer-experience audit:** a new user builds each sample from
  the docs alone, and every place they get stuck becomes an item.
- **D4. A profiling guide** over P2's tracer.

**Done when (each):** `zui_testing` coverage; IME works on Windows.

**Spec.** §19.2, §19.8, §19.9.

---

## The font system

A contract with default implementations, through which an application
brings any typeface and any compatible font library, and zui makes it
work on every renderer. The packages already have room for it: what font
systems and renderers share is `zui_glyphs` (`text/glyphs/`), the
default font system is `zui_truetype` (`text/truetype/`), and the
bundled typefaces are `zui_fonts` (`text/fonts/`), so the font system
moves nothing. Measuring and drawing already take their glyphs from one
layout, so it inherits no two loops that must agree. Its items are given
their Grounding, Plan and Done when as they join the queue.

**The layers.** Every mature text stack splits text into the same parts:
Skia (typeface, font, shaper, text blob), cosmic-text (fontdb for
discovery, rustybuzz for shaping, swash for rasterization, its own layout
and glyph cache), egui (fonts laid out into a galley of positioned glyphs,
rasterized on demand into one atlas, drawn as textured triangles), and
Dear ImGui 1.92 (a font loader interface with stb_truetype and FreeType
behind it, glyphs loaded on demand into an atlas that grows, which the
renderer backend uploads):

| Layer | Turns | into | Implementations, now or later |
|---|---|---|---|
| source | a name, a file, embedded bytes, a system font | font bytes | `zui_fonts`; a host's system fonts (DirectWrite, fontconfig, CoreText), as a host service |
| face | font bytes | metrics, glyph ids, outlines or bitmaps | `zui_truetype` (stb); FreeType; DirectWrite and CoreText faces; bitmap faces |
| layout | a run and a `MeasureKey` | positioned glyphs and their extent | one per-glyph pen in `zui_glyphs`, additive as SPEC.md §9.4 requires; a shaper (HarfBuzz) and font fallback later |
| raster | a glyph at a size | coverage, SDF, color, or nothing | stb, FreeType, platform rasterizers; nothing for a renderer that draws cells or outlines |
| atlas | rasters | texels in a cache with dirty rectangles | `zui_glyphs`, in the texel layout each renderer asks for |
| draw | positioned glyphs and an atlas | pixels or cells | each renderer |

**The rules it keeps:**
- **One layout, two readers.** A text's `zuiMeasure` and its drawing take
  their glyph positions from the same function, in `zui_glyphs`. A
  renderer places what the layout gives it and advances no pen of its
  own. Commands carry the text and its style, not glyphs, so frames and
  the wire stay as they are; a remote renderer runs the same layout,
  which the text contract's `zuiFingerprint` guards.
- **The renderer declares what it draws, the font system provides it.**
  As a renderer declares `zui_commands` and `zui_output_formats`, it
  declares the glyph placement it can draw (`glyph_placement`): on a
  pixel grid, or one glyph per cell, as the terminal does. The font
  system lays text out for it, so a typeface brought by the application
  works on the terminal, with every glyph one cell wide and measured as
  such, and on a GPU, with its own advances. This is how the terminal
  runs the tour.
- **Core stays out of fonts.** The text contract in `zui_core` (SPEC.md
  §9.4: `zuiMeasure`, `zuiSegment`, `zuiFingerprint`, `FontId`,
  `MeasureKey`) does not import `zui_glyphs`. What font systems and
  renderers agree on lives in `zui_glyphs`, as does its conformance
  suite, since `zui_testing` is part of core.
- **Text looks its best with no setup.** Out of the box, text is drawn in
  `zui_fonts`' typefaces through `zui_truetype`: an application that
  names no fonts gets Atkinson Hyperlegible as font 0. A renderer's or
  library's built-in fonts (sokol's 8×8 bitmap fonts, raylib's default
  font) are never a default and are not part of zui.
- **`text/` is a family,** as `renderers/` and `hosts/` are. A new face,
  shaper or rasterizer is a new package beside `truetype/` (`freetype/`,
  `harfbuzz/`), and a platform's system fonts are its host's. None is
  created ahead of the font system's own items.

**What `zui_glyphs` holds today** is what today's renderers need, and
the font system's items design the contract properly and may change all
of it:
- `Codepoints`, a run's codepoints;
- `Fonts`, the type-erased fonts a renderer draws through, with
  `FontMetrics` and `GlyphBox`, made from any text contract that
  provides `fontMetrics`, `advance`, `glyphIndex`, `glyphBox` and
  `rasterize`;
- `Placement` and `placementOf(Renderer)`, the pixel grid or cells;
- `layOut` and `measure`: the pen that lays a run out from each glyph's
  advance and the letter spacing, without kerning, so measurement stays
  additive, into `PositionedGlyph`s (font, glyph id, position), every
  glyph one cell in cell placement;
- `glyphQuads`, the pixel grid's quads, each half a texel wider than its
  glyph's coverage;
- `Atlas`, which takes coverage from any face on first use into memory
  reserved at `init`, packs it in rows, and lays it out in the
  `TexelLayout` the renderer asks for (sokol's and raylib's RGBA, the
  browser's RG8);
- `expectFontsConform`, the font systems' conformance suite.

---

## Later

Only with a measured win or a demonstrated need:
- **Docking and tear-off panels,** once H9 has more than one window.
- **A grid layout,** if wrap is not enough.
- **Layout islands** (SPEC.md §8.5), with a benchmark above roughly 10k
  elements.
- **Static subtrees:** pre-recorded element records copied in with one
  `@memcpy` and laid out normally.
- **P3. SIMD candidates,** each measured by R1 and R2 before it ships.
- **R10. A dedicated benchmark machine:** a self-hosted, bare-metal CI
  runner set up as R3 describes, the only way wall-clock times could gate
  CI. Until then CI reports times and gates on instruction counts. A
  decision for when the hardware exists.

## Not taken from Clay

Deliberate, and each a reason to choose zui:
- a global current context;
- `void*` payloads and callbacks in the hot path;
- 32-bit ids;
- limits set at run time. zui's are comptime so that `required_bytes` is
  exact and `initBuffer` works with a static buffer.

---

## Decisions

### Made

| Decision | Outcome |
|---|---|
| The frame boundary | the cornerstone: a record in at `beginFrame`, a frame out of `endFrame` |
| A surface the platform takes away (H10) | part of H10's design, settled by the owner: `suspendSurfaces` and `resumeSurfaces` detach and re-attach every window's surface through the renderer's `zuiDetachSurface` and `zuiAttachSurface`, so the renderer lets go of what it keeps for each while it, the contexts and the application live on; not left for the Android host. It replaced an earlier choice, `suspendSurface` then a fresh `start(surface)`, which would have remade the renderer and the text, when the calls H9 built already drop and take a surface |
| Who owns the loop (H10) | settled by the owner, after two prototypes: one non-blocking `step` and three loops over it. A host declares at most one loop call: `zuiWait`, and `run` pulls the loop; `zuiRun(io, window, driver)`, and the platform pushes it through a `zui.Driver`; or neither, and the application's own loop steps a `zui_app.Session`. It took option 3 (one step, `zuiWait` kept where a host may block) and added the stepped host, so a game engine or an editor that owns its loop and window has a contract too; option 2, push only, would have changed every host and still left that case out. The other prototype made `std.Io` the loop: `zui_app` waits on a futex through its `Io`, and a platform that calls back steps an `Io` that suspends the loop on a stack of its own, a fiber or, in a browser, JS Promise Integration. Not taken: on such an `Io` a loop asked for a frame `.immediately` never returns control to the platform; the application's tasks have nowhere to run on it; zui would own stack-switching assembly; and its test runs on neither Windows nor ThreadSanitizer. What it found stands: under JSPI, `zui_app`'s own loop ran on a page's main thread, in Node 26, with every callback returning; `Io.Dispatch` resumes a fiber off the main thread, so it cannot hold AppKit's loop; and `std.Io` has no wait on a descriptor, so a host that polls one (Wayland, X11) keeps `zuiWait`. Zig 0.17.1 changes none of this |
| The turn after `zuiWait` (H10) | stays due for an application with one window, since a host's wait may end for a repaint its record does not show; measured before deciding: judging that turn too saved one idle frame in ten seconds on the Wayland host and none on raylib, with no change while busy |
| Outside data | sources swapped at `beginFrame`, demand out, a loader between frames; zui starts and cancels nothing (A1) |
| `TaskPool` and feeds | deleted and retired; sources replace both (A5, F1) |
| `Platform` | split: the text contract in `Config`, `Waker` from the host, scale in the record (C5, S1) |
| Time | an instant in the record, not a delta (S1) |
| Replay | one `beginFrame`; a record with deliveries is a replay |
| `endFrame` | always returns a frame; limits are diagnostics (C6) |
| Render commands | generated from what the renderer declares; the rest lowered (C1) |
| Contract members | all `zui`-prefixed; unknown ones are compile errors |
| Static styles | approved: pointers to comptime configs, measured against the declaration budget (L8) |
| An element's switches | `?bool`, null meaning false, so that their defaults fold away; written as booleans (P5) |
| Line-break segmentation | the text contract's `zuiSegment`, one paragraph at a time; spaces before a break hang (T4) |
| Aspect ratio (L2) | a height rule, `.aspectRatio(r)`, not a `Layout` field, which made every layout eight bytes larger and declaration 6.6% slower; neither stretched nor grown by its parent; on a width, or not positive, the content's size |
| Wrap (L7) | `ui.wrapChildren()` after a row's `open`, gated by `features.flex_wrap` with a compile error, not a `Layout.wrap` field, whose value is not known at compile time and which would make `Layout` four bytes larger; a column ignores it; lines break at each child's size before free space, then grow and shrink as rows; lines are as tall as their tallest child and `child_gap` apart; `child_alignment.y` places the lines and each child in its line; dividers between a line's children and between lines |
| Right-to-left layout (L6) | `Layout.mirrored: zui.Mirrored` (`.inherit`, `.yes`, `.no`), one byte rather than a `?bool`, which would make every `Layout` four bytes larger; inherited, the root's from the environment's `direction`; a mirrored or `right_to_left` element, not both, reflects its children across its box, so padding's `left` is the start side, alignment and floating anchors and offsets mirror, and a text's `.start` and `.end` swap; `right_to_left` covers the element's own children only, as `row-reverse`; a reversed scroller's offset grows to the left and takes the wheel's physical delta reversed; positions and borders stay physical; found by the position pass, which starts again mirroring at the first parent that mirrors, so other frames pay nothing |
| Floating options (L4) | `capture = false` gives the floating element no hit region of its own, while interactive elements inside it keep theirs; `.clip = .target` cuts it off where its target's children are, merged with its own clip into one pair pushed in its layer before it draws; a later target places the subtree again after pass 6, in declaration order, and a target inside the subtree falls back to the parent; `capture` and `clip` are copied into the element's flags, so emission reads no floating config for other elements |
| A border inside its element's clip (L4) | emitted before the element's own `clip_end`, which leaves it whole since it lies in the element's box, so a floating element's merged clip also cuts off its border with one clip pair |
| Effects (G1) | `Element.effects: ?*const zui.Effects`, copied when declared, not a value in `Element` (interactive boxes' declaration +22%) or `Decoration` (every decorated element copies it), and not in `Style` (+3.5% of the static box tree's declaration); in the shape of the decoration's corners; painted shadow, background, gradient; a gradient in OKLab along a line through the center, long enough that the far corners take its ends; a shadow culled by what it paints; bounded by `limits.max_effects`; a frame without effects is emitted by a walk that never looks for them |
| Dividers (L3) | `Border.between_children`, emitted as `rectangle` commands in the border's color, so no renderer breaks; centered in the gap, spanning the element inside its widths; inside the element's clip, after its children and before its border; a border of zero widths emits no `border` command |
| Images' tint and corner radius (L3) | declared on `Ui.Image` and carried by the `image` command with defaults (white, square), so existing renderers and their tests still compile; drawing them is the backends' (C10) |
| Drawing images' tint and corner radius (C10) | the tint multiplies the texels as the vertex color; a rounded image is a fan of textured triangles from its center, each corner with its own radius, in the raylib renderer too, whose rectangles keep raylib's one radius; the renderer suite checks the tinted color at the image's center and the background just inside two of its corners |
| Natural sizes (L2) | `Ui.Image` is the declaration's type, apart from the `image` command; a natural size is the content inside the padding, may shrink in a narrower parent, and gives the height its proportions unless the height has a rule of its own |
| A grow basis (L1) | a rule, `grow_from_min`, not a `basis` field, which would cost declaration; never narrower than the content's minimum, the rest shared by weight |
| Config references (L8) | pointers in element storage, the default layout one constant; an element's own `layout` or `decoration` replaces the style's whole |
| Budgets | as in SPEC.md §20.2, judged in benchmarking mode (Turbo Boost off, the `performance` governor) from after the audit's P10: the box tree < 125 µs and its declaration < 69 µs, warm text < 150 µs, each the earlier turbo-on budget × 1.25 |
| Where the contracts live | in the `zui` repo |
| Native hosts | one package, `zui_host` in `hosts/native/`, one directory per OS |
| Who orchestrates | the host, through one contract; adapters for libraries that own their window (H1) |
| Signals | lifecycle events; uncatchable signals are not representable |
| Input | an ordered event log with host instants, many pointers (I4) |
| Gesture arbitration | elements declare what they accept; one rule, by motion component (I5) |
| How a frame's semantics reach a host (V2) | an optional host call, `zuiSemantics(window, nodes) SemanticsDropped`, which `zui_app` makes on the UI thread between `endFrame` and submission, into room the window opened with (`WindowOptions.semantics`, sized from `Config.limits`); not a field of `HostRequests`, which every `zuiApply` compares, nor a generic call taking the whole frame |
| How a host holds many windows (H9) | the Windows host is one type, `.many`, with `Host.max_windows = 4` fixed slots in every application, settled by the owner; a generic `HostWith(.{ .max_windows })` that pays only for what is declared was the other option |
| When `zui_app.run` returns with many windows (H9) | once the last window has closed, settled by the owner; an application that wants closing `.main` to quit closes the rest in `zuiWindowClosed`. Returning when `.main` closes was the other option |
| When a window's context is made (H9) | when the window opens, allocated with `gpa` as `init` makes the first, settled by the owner; reserving every context at `start` was the other option |
| Which windows run a frame each turn (H9) | only those due: an event, new parameters or output format, a due `nextFrame`, or no frame yet, settled by the owner; every window every turn was the other option, which would redraw every window for one that animates |
| How a renderer learns of windows (H9) | `zuiAttachSurface` and `zuiDetachSurface`, optional and declared together, on the thread that submits, settled by the owner; attaching a surface lazily at its first submit was the other option, which would turn a failure into a render error that ends the run |
| How the hooks name the window (H9) | every hook of the windowed form takes `window: zui.WindowId`, settled by the owner; a `zui_app.Window(App)` value in place of `ui` was the other option |
| A text field's Value pattern (V2) | read: its `SetValue` fails with `UIA_E_INVALIDOPERATION`, since zui has no action that replaces text, but an enabled text field reports `IsReadOnly` false, since it is typed into from the keyboard and Narrator would otherwise call it read only; a combo box's Value is read-only |
| A custom recognizer's decision lands a frame late (I5, open decision 1) | accepted: `claim` and `decline` apply at the next `beginFrame`, and a declined pointer is arbitrated over all its motion since the press, so nothing is lost; the lasso against a map's pan passes with it |
| Custom recognizers (I5) | an element with `custom` holds each pointer pressed on it from every built-in gesture until it decides; `pointerEvents(id)` is an iterator, `zui.PointerEvents`, over the frame's events of the pointers it holds; a claimed pointer takes the press from what it pressed and is never a tap; one released undecided is a tap; the lasso is `zui_widgets.Widgets.lasso`, a pen drawing and every other pointer declined |
| Momentum (I5) | a pan released faster than 50 units a second over its last 0.1 s coasts on its axes, slowing exponentially with a time constant of 0.325 s, moved to each record's `now` before its events through the pan's path; it stops below 10 units a second, at a scroll container's end, under a press, or when its element was not declared; it asks for frames 1/120 s apart; at most `max_input_contacts` elements coast, and a fling beyond them is reported on that limit |
| Long press and double tap (I5) | timed from the events' instants against the record's `now`, setting the next frame's deadline: a long press after 0.5 s held within the slop, which is not a tap; a double tap within 0.3 s of the first tap's release, whose single tap is clicked only when that window passes; `doubleTapped(id)`, which SPEC.md lacked; `navigated` returns `zui.NavigationDirection`, since `Direction` has no up or left; `dismissed` while the element or one in its focus scope is focused; `contextRequested`, `dismissed`, `adjusted` and `navigated` need no feature, `doubleTapped` needs `features.gestures` |
| Zoom (I5) | a second pointer pressed while another is down, both inside an element that accepts zoom, makes the pair zoom the innermost such element, taking both pointers from what they pressed or panned; `scale`, `rotation` (clockwise) and the centroid's `translation` are summed over the frame, `pivot` is where the centroid ended; the pointer left when one lifts pans the element if it pans |
| Pans (I5) | past a touch slop of 8 layout units from the press, the axis locks to the larger component and the innermost region under the press that pans on it with room to move takes the pointer until it lifts, both axes if it pans on both; any other element it pressed loses the press; a scroll container pans on its scrolled axes with touch and pen only, since the mouse has the wheel, unless it declares `pan`, which takes every pointer; declaring a gesture makes an element interactive; `Element.gestures` is ignored without `features.gestures` rather than failing to compile, so widgets declare gestures for every context; `manipulation` reports pans and the wheel, scroll containers included, `translation` moving content with the pointer |
| Drag and drop (I1) | a source declares `Gestures.drag` and takes a pointer past the slop on the axes no region around it pans on for that pointer, after any region inside it that pans; `startDrag` gives the payload, in the state table under the source as `DragPayload(T)`, or starts the drag with a pointer still pressed on the source, which is how a long press or a recognizer lifts it; the payload is kept while the drag lasts, the source may go undeclared; a target is any element with a hit region the hit test at the pointer passes through; `draggedOver`, which SPEC.md lacked, shows a drop target before the release; a drag released in its starting record, before it had a payload, or cancelled, drops nothing |
| Custom gestures | code in declaration over `pointerEvents` and `state`, not a registry |
| Comparing two commits | each commit's own benchmarks, alternated (R2), one scenario at a time in a shuffled order (R5), over 3 code and memory layouts (R7), pinned (R3); a change is called when the bootstrap 95% interval of its median ratio lies wholly beyond the machine's calibrated noise band (R4) |
| Nanoseconds or cycles (R6) | nanoseconds stay `bench-compare`'s default, since cycles proved no narrower; the counters explain a change, more work against more waiting |
| Simulated misses (R8) | reported beside the instruction counts, never failing CI, since Callgrind's cache model shows direction, not cost |
| Building on a slow foundation | not done: when an item's counts or budgets fail because of the code under it, the foundation is profiled and fixed first, as items of their own; the audit's findings went ahead of stage 8 for G1 |
| The benchmarking plan | its steps B1 to B8 became R3 to R10; the plan keeps its motivation and sources |
| G1's first slice | not rebased, and superseded by G1 on `main`; `wip/g1-gradients-shadows-and-glow` is history, not work to resume |
| Flat child lists (P11) | retired by the owner: its profile puts at most 0.9% of the wide tree's cycles on the walk, and a flat list would build two more passes a frame |
| Text commands that point at their style (P12) | the owner approved building the scene a renderer reads, `1000 labels, rendered`; judged by it and not shipped, then retired by the owner; the scene stays |
| The inspector | a module over `Frame.inspect` (V1) |
| Animation | not in the core; `zui_motion` (M1) |
| Safety checks | built, as `features.safety_sweeps` (V3) |
| Instruction counts | Callgrind on a fixed CPU model and fixed frames, in a fresh process per scenario and phase; CI fails on 2% growth over the parent (R1) |
| Where the Tracy binding lives (P2) | a `zui_tracy` module in this repository, with Tracy as a lazy dependency, so every backend's demo can trace and applications that do not import it never fetch it |
| Turning Tracy on (P2) | a build option, `-Dzui-tracy`; without it `zui_tracy.Tracer` is `void`, so code that names it compiles tracing out and fetches nothing |
| Sources between frames (A3) | zui holds them only from `beginFrame` to `endFrame`; `nextFrame` takes them as a parameter, and `ui.source` outside a frame panics in every build |
| `Status.failed` (A3) | `Result`'s whole error set, since Zig cannot subtract one at comptime; `fromResult` maps `Canceled` to `.canceled` |
| One reader per source (A3) | asserted by the source from `zuiEndFrame`'s frame numbers, not by the core (A4) |
| The tracer's shape (P2) | plain functions with the zone at comptime, no tracer value: profilers keep per-thread state, and Tracy needs a static location per zone |
| `Task` restarts (A4) | one run at a time; `begin` refuses while a run is active or its final status is unswapped, and restartable work is keyed in `KeyedLoads` |
| `unread_frames_before_release`'s default (A4) | 30 frames, since reloading a thumbnail costs far more than keeping it |
| `Task.publishing` (A4) | declared on the `Task` type, taking the function's arguments as one tuple |
| `KeyedLoads`' `Progress` (A4) | at most a `usize`, so every target stores it with one atomic |
| Sources in tests (A4) | `Driver` takes `.sources`; `frameDelivering` gives sources it does not name `null` or `Delivery.empty`; `expectSourceConforms` publishes through a harness |
| Input from backends (C8) | events where the library reports events (sokol_app, the terminal), so a click inside one frame is kept; `zui.InputSampler` only where it reports state (raylib) |
| The backends' text contract (C8) | each backend's `Text`, set by its `config()`, in place of `Platform` |
| Waiting until an instant in raylib (C8) | `FramePacer`: raylib's event wait plus a task that posts an empty event once the instant has passed |
| Measuring idle CPU (C8) | by the demo itself (`--measure-idle`), between two frames it requests 10 s apart, so the run ends on its own and CI can repeat it |
| What a cached string holds (T2) | its metrics and the widths of up to 16 runs, so a warm text that wraps probes nothing per word; a longer one keeps only its metrics and measures its runs only to wrap |
| The string cache's key (T2) | the bytes, `MeasureKey`, zoom and wrap mode, so a hit returns exactly the layout units a miss computed |
| `zuiSubmit`'s frame (C1) | `anytype`: a renderer is not generic over the `Context`; its exhaustive `switch` over the payload is the check that it draws what the frame holds |
| Surfaces that are not native windows (C1) | `zui.Surface` gains `terminal` (cells) and `library` (a window a library such as raylib or sokol_app owns, which only its adapter host provides) |
| Where the surface vocabulary lands (C1) | with the renderer contract, which names it; C2 adds the host side and the check that a host and a renderer share a kind |
| Who checks that a host and a renderer meet (C2) | `zui.checkHostAndRenderer`, called by the composition root (the application or `zui_app`), the one place that names both |
| What fills a record (C2) | `zui.RecordBuilder`, over the application's buffers: the host sets `now`, viewport and scale with `begin` and appends events; the zoom is the application's and survives `begin`; what does not fit is dropped newest first and counted on the builder, which `zui_app` reports |
| A record for a context with sources (C2) | `builder.recordWith(Ui.Deliveries)`, since `Ui.FrameRecord` is a different type there; a live record has no deliveries |
| When a sticky wake is cleared (C2) | after the wait returns, never before it: a wake between `nextFrame` and the wait then ends the wait, and one cleared after it belongs to a publish the next swap sees |
| A backend's `config()` (C1) | built from its `Renderer`'s declarations, overriding the application's `commands` and payload types, since the renderer draws only those; `zui_app.contextConfig` (C4) generalizes it |
| Lowering before stage 8 (C1) | none: no declaration can produce an optional command until its stage-8 item adds one, which lands the lowering with it |
| `Features` (C7) | the mechanism first: the four fields with SPEC.md's defaults, and a gated API's compile error naming its field, pinned on `Frame.semantics()` and `manipulation`; each feature's item (V2, I5, L7, V3) gates its own code, with R1 counts unchanged when it is off |
| What a conformance suite takes (C3) | a harness, as `expectSourceConforms` does: the implementation makes the drawing target and reads it back, or makes the OS report an event; the suite owns the frames, the waits and the checks |
| Reading pixels back (C3) | optional: without `pixel` the renderer suite checks only that each frame draws without an error; every backend today reads back, `zui_sokol` through OpenGL's `glReadPixels`, so its suite renders with OpenGL on every system |
| A lost wake in the host suite (C3) | bounded: after `lost_wake_ns` the suite wakes the host every 50 ms until the wait ends, and fails |
| Warm benchmark scenes (T2) | sized to hold every string (`string_cache_entries = 2048` for 1,000 texts): 1,000 strings in 1,024 entries overflow eight-entry probe windows, and about a fifth of them missed every frame |
| How `zui_app` knows the host and renderer (C4) | the application declares `pub const Host` and `pub const Renderer`, plain names like a renderer's payload types; `Ui` is read from `zuiDeclare`'s parameter |
| How `zui_app` opens them (C4) | the host's `init(self, io, zui.WindowOptions) !void` and `deinit`; the renderer's optional `init(self, surface) !void`; `zui.WindowOptions` is core vocabulary, since every host opens windows with it, and `zuiOpenWindow` opens each window after the first with it (H9) |
| When a renderer may submit on another thread (C4) | when it declares `zui_render_thread = true`; raylib and OpenGL-bound renderers leave it out, and `zui_app` reports why it submits on the UI thread |
| How `zui_app` reports (C4) | `Options.notify`, a plain function given each notice once, logging through `std.log` by default; tests record them |
| The application's text contract under `zui_app` (C4, C9) | the renderer, through `contextConfig`, or the application's `pub const Text`, which `zui_app` makes and passes to the context and the renderer's `init`; any other `Text` is a compile error |
| The application's part of the record (C9) | `zuiRecord(app, record)`, after the host's poll and before `beginFrame`: the zoom, and events the application makes itself |
| What `init` finds under `zui_app` (C9) | each field with a default holds it, so a host's settings made on its type (`forced_scale`) survive; the rest is undefined |
| How the raylib host waits (H1) | in GLFW, past raylib: `glfwWaitEventsTimeout` until an instant, `glfwWaitEvents` on event, and callbacks in front of raylib's to tell input from a spurious OS event; raylib's `EndDrawing` only presents and polls |
| How a host harness posts events raylib cannot inject (H1) | `Host.script(sample)`, input for one poll instead of raylib's; the demo's screenshots use it too |
| The raylib renderer's text contract (H1) | the renderer itself, as SPEC.md §16.1 expects of most renderers, so `zui_app.contextConfig` gives it to the context |
| The first renderer on a native surface (H2) | sokol_gfx, with OpenGL through WGL: the sokol renderer makes the window's context itself, without sokol_app |
| The demo on a native host (H2) | the sokol renderer's tour, unchanged, through `zui_app` since C9; raylib cannot draw into a window it does not own |
| A native host's loop (H2) | the Windows host runs its message loop on a thread of its own, so modal move and resize loops never stop frames |
| Whether a system material shows (H8) | `Environment.system_material`, reported by the host, so it is in the record and replays |
| A renderer over a system material (H8) | composes with alpha: `zui_sokol` draws a native window through a DirectComposition swapchain, since Windows ignores an OpenGL or window swapchain's alpha |
| A terminate request (H2) | delivered in one record; the host's next `zuiPoll` returns false |
| The clipboard service before H6 (H2) | `zuiClipboard`, a type with `read(host, buffer)` and `write(host, text)`; H6 gave it the services' shape |
| How a service answers (H6, decision 1) | published into a `zui.ServiceSink` made from a source the application chooses, usually a `Stream(zui.ServiceReply(n))`, as file changes are, chosen by the owner: nothing on a hot path changes and answers relay and replay. Events in the record, which would need storage and limits in the context, and demand in `HostRequests`, carried by every frame, were the other options; E1 may add the latter for the clipboard alone |
| Where a service is called (H6) | by the application, between frames, usually from `zuiLoader`, through `zui_app.ServicesOf(Host)`'s comptime `has_*` guards; never from declaration, since a call is work that replay would repeat |
| Where a modal dialog runs on Windows (H6, decision 2) | on the window thread, chosen by the owner: its modal loop keeps dispatching the window's messages, as a move or resize does, and menus must run there anyway; a dialog thread of its own would join the two threads' input queues |
| Notifications on Windows (H6, decision 3) | `Shell_NotifyIconW` balloons, which Windows 10 and 11 show as toasts, chosen by the owner; WinRT's toasts need package identity or a registered activator for an unpackaged application |
| Text longer than the system shows (H6, decision 4) | cut at a character, as a label is, chosen by the owner, since the lengths differ by system and the application cannot know them |
| A URL the system then fails to open (H6, decision 5) | not answered: `open` takes no sink, chosen by the owner; the system shows its own error |
| What a relay listener gets (F2) | the record as applied: the events kept, and deliveries from `zuiDelivery`, filled in the reservation, or a replay's own |
| A frame on the wire (F3) | number, parameters, host requests and commands, as changes from the last frame written; hit regions and semantics stay with the context |
| A wire message beyond the decoder's capacity (F3) | `error.CapacityExceeded`, since a delta cannot be applied in part |
| Serializing a payload with pointers (F3) | `zuiSerialize(self, serializer)` and `zuiDeserialize(deserializer)`, taking the wire's types as `anytype`, so a source never imports `zui_wire` |
| Replay in tests (F4) | `Recording(Ui)`, a relay listener, and `Driver.replay(app, declare, record)`, one frame per record |
| What the loader changes between frames (F4) | delivered by the source when relayed, so a replay without a loader shows it: `KeyedLoads` relays the keys loading and the abandoned loads that finished |
| How a remote client joins (F5) | `zui_wire.Host` and `Renderer` where the application runs, over a stream the application attaches; `zui_wire.Client` over any host and renderer where it draws; a `wire` surface kind between the two halves |
| Time on the wire (F5) | the client's host's clock, counted on by the wire host between records, so records are sent only for events or a new viewport or scale |
| Watching files (F6) | `zuiFileWatch.watch(host, directory, sink)` until `deinit`, subdirectories included; the host publishes `zui.FileChange`s into a `zui.FileChangeSink` made from a source the application chooses, and the loader reads the files |
| Where the demo runs behind the published page (V4, open decision 3) | in a Web Worker, settled by the owner: the tour built for `wasm32-freestanding`, its frames posted to the page as wire bytes, since a page CI publishes has no server to reach. A native process behind a WebSocket was the other option |
| A pixel on a glyph's edge (V4, open decision 3) | `test-draw` passes a frame with at most one pixel that matches no reference pixel within 1, settled by the owner: a glyph's partial coverage near its edge is a color no neighbor has, and two rasterizers decide a pixel whose centre lies that close to the edge differently. The tolerance of 2 and the neighbor rule are unchanged. Leaving text inside a turning transform out of the comparison, or having the client drop a pixel within 1/256 pixel of a glyph's edge, which is tuned to one machine's reference, were the other options |
| How the tour's tasks run in the browser's worker (V4) | on an `Io` of the worker's own, `SteppedIo`, chosen in V4's worker part: its clocks read the page's instant, and the tour's tasks take turns on a fixed set of threads, each a worker on the tour's shared memory, one at a time and only while the frame waits for them, so the worker draws on the page's clock exactly the frames the tour draws natively on the same ticks, which `test-demo` checks byte for byte. A worker per loader was the other option: without shared memory it cannot reach the sources and loads the loaders write, so the tour's loaders would have been rewritten around messages, and with it, it is the same threads without the turns that keep frames alike. Its cost is a page served cross-origin isolated |
| How the published page is isolated (V4) | on GitHub Pages, by a service worker of the page's own, chosen in V4's slice 5: it serves the page and everything it loads again with `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`, which GitHub Pages cannot send, and the page reloads once after registering it. A host that sends the headers itself was the other option; it would add an account and a deploy outside the repository's own CI for two headers |
| How the browser draws (V4) | the client lays every command out as the sokol renderer does, triangle for triangle, and the page draws the triangles through WebGL 2, with four samples per pixel resolved to one, as the sokol renderer's demo window smooths its edges; `test-draw` compares them with one sample per pixel too. A 2D canvas smooths every edge its own way and cannot fade a shadow's rings vertex by vertex, so its frames could not be compared with the sokol renderer's pixel by pixel |
| A web renderer or a thin client over the wire (V4) | a thin client over `zui_wire`, as planned, since F5 built it: the web host's page draws the frames an application in a Web Worker writes. A web host with a canvas surface, the application on the page itself, is H5's |
| A D-Bus client for the Linux host (H4) | the host's own, over a Unix socket into fixed buffers, not libdbus or sd-bus: no outside code shares the connection, as EGL shares libwayland's objects, and the portal and UPower need only a handshake, a few calls and three signals; libdbus allocates per message and is thread-unfriendly, sd-bus ties the host to systemd |
| macOS (H3) | set aside by the owner, who has no macOS hardware: its work is listed under *macOS, for later*, out of the queue, until the owner chooses to take it up. What fixes a contract's shape for macOS stays in the code as a stub: the `cocoa` surface, the system material's vibrancy, and bench's `.macos` machine readings and counters message. CI keeps its macOS runners, which need no hardware here |
| Where an element declares its material (G5) | `Ui.Decoration.material`, typed by the renderer's `MaterialHandle`: `Ui.Element`, `Ui.Decoration` and `Ui.Style` are the context's own, and are `zui.Element`, `zui.Decoration` and `zui.Style` without a handle, so no existing code changes. `open` taking `anytype` to accept both was rejected: a literal passed through `anytype` is not converted to `Ui.Element` |

### Open

Each is planned with its first option. SPEC.md §22 has those that change
the spec.

1. **Physical keys.** Planned: logical keys plus the opaque scancode.

---

## macOS, for later

Not to be built until the owner chooses to take up macOS: there is no
macOS hardware to run or check it on. Nothing here is in the queue, is
next, or counts against a stage; stage 10 and stage 11 are done without
it. When macOS is taken up, these items return to the queue in this
order, each given its Grounding, Plan and Done when as it is taken.

What fixes a contract's shape for macOS is already in the code, as a
stub with nothing behind it, so taking up macOS changes no contract:
- `zui.Surface.cocoa`, an `NSView` by pointer, and `.cocoa` among the
  surface kinds (`core/src/surface.zig`);
- `HostCapabilities.system_material` and `Environment.system_material`,
  which name vibrancy beside Mica;
- `Modifiers.super`, which a macOS host reports for Command;
- bench's `Machine`, which reads a Mac's OS version and caches
  (`core/bench/machine.zig`), and `--counters`, which says that kperf's
  counters are not read (`core/bench/counters.zig`).

`zui_host.Host` stays a compile error on macOS until H3 adds
its directory to `hosts/native/`. CI's macOS runners stay: they are GitHub's, and they check
that the core and its modules build and pass there.

The items:
- **H3. macOS** (stage 10, `hosts/native/`): a Cocoa host passing C3, its
  surface `.cocoa`, its event loop on the main thread as AppKit requires,
  driving `zui_app` through H10's `zuiRun`;
  vibrancy through `NSVisualEffectView` as the system material (H8);
  many windows, a context each, as H9 built on Windows; the EDR headroom
  that G6 left unreported; a custom title bar's chrome regions (H7); and
  the services of H6 (`NSPasteboard`, `NSOpenPanel`, the menu bar, user
  notifications, `NSWorkspace`). `zui_sokol` draws into it through Metal,
  which also first compiles the Metal that sokol-shdc wrote for G5's
  material shader.
- **macOS's hardware counters** (R9's remainder, `core/bench/counters.zig`):
  `--counters` through kperf, which needs `sudo`.
- **macOS's skin** (K4's remainder, `themes/`), once K4 ships the
  others.
- **The IME on macOS** (E1's remainder): `NSTextInputClient` on H3's
  view, against E1's composition events and IME area.

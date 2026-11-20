# Architecture

SPEC.md is the contract. This document is the map: which layer holds each
part of an application built on zui, how the parts meet at the frame
boundary, and how today's code becomes what the spec describes.
ROADMAP.md says when each part is built.

## 1. The layers

| Layer | Holds | Rule that keeps it in bounds |
|---|---|---|
| **Core** (`zui`) | layout, interaction, state, the frame boundary, sources and demand, the vocabulary, every contract and its checks | no OS calls, no drawing, no threads but the `Io` it is given; the same behavior on every target |
| **Modules** (`zui_*`, this repo) | default sources, widgets, reflection, testing, tracing, the app runner, wire, debug, motion, color, icons | the public API only, enforced by the module boundary (SPEC.md §3.3) |
| **Renderers** | drawing, fonts, text measurement, images, materials | implement the renderer and text contracts; never import a host |
| **Hosts** | windows, the event loop, OS events and services, frame pacing | implement the host contract; never import a renderer |
| **Theme packs** | OS design languages | skins: data only |

```
                          application
                               │
                    zui_app (optional runner)
              ┌────────────────┼─────────────────┐
            host               │              renderer
   (native, adapter, wire)     │      (sokol, raylib, web, wire)
              └───────┬────────┴────────┬────────┘
                      │                 │
        modules: async, widgets,     zui_wire
        motion, debug, color, ...       │
                      └────────┬────────┘
                               │
                           zui core
           (engine, vocabulary, contracts and their checks)
```

- **Dependencies point one way.** The core depends on nothing. A renderer
  that imports `zui` only for its vocabulary pays nothing for the engine,
  because Zig analyzes only what is used, so there is no separate types
  package.
- **Hosts and renderers meet at one type,** `zui.Surface`.
- **The composition root** is the application or `zui_app`, the only
  place that names a concrete host and renderer.
- **Every default is replaceable.** Nothing in the core names a module, so
  an application can swap `zui_async` for its own sources, `zui_widgets`
  for its own controls, or `zui_app` for its own loop, and keep the rest.

## 2. The frame boundary

```
Frame = endFrame(declare(beginFrame(state, FrameRecord, Sources)))
```

| Inbound: the `FrameRecord`, applied at `beginFrame` | Outbound: the `Frame`, produced by `endFrame` |
|---|---|
| `params`: `now`, viewport, scale, zoom | render commands, generated for this renderer |
| `events`, in arrival order: pointers, wheel, keys, text, composition, OS gestures, accessibility actions, environment changes, dropped files, lifecycle | hit regions and chrome regions |
| source deliveries: each field of `Sources` swapped, or injected from a recorded record | semantics |
| | host requests: cursor, IME area |
| | diagnostics: limits, refusals, lowerings |
| | after the frame: demand (`framesSinceRead`, keys asked) and `nextFrame(sources)` |

Nothing crosses in between. That is what makes relay, replay, testing and
remote rendering the same mechanism: each is a producer or consumer of
one of those two values.

- **A recorder, a network link and a test driver** are all listeners on
  `relayTo` or producers of records.
- **Replay drives declaration only.** No loader runs, so replay does no
  real I/O.
- **The application keeps its side** by reading the outside world only
  through the record and its sources (SPEC.md §6.8).

## 3. One frame across the layers

```
host.zuiPoll ──► FrameRecord ──► ui.beginFrame(record, &sources)
                                    │  take an arena (the only wait)
                                    │  evict state, apply events
                                    │  swap or inject each source
                                    │  relay
                                    ▼
                          app declares (reads sources → demand)
                                    │
                                    ▼
                               ui.endFrame ──► *const Frame
                                    │              │
           ┌────────────────────────┤              ├──► renderer.zuiSubmit (any thread) ──► ui.release
           │                        │              └──► host.zuiApply(frame.requests())
           ▼                        ▼
   app loader: demand → work   ui.nextFrame() ──► host.zuiWait
   (starts, abandons, releases      ▲
    on the app's own Io)            │
           │                        │
           └── producers publish ───┴── Waker.wake (sticky)
```

The loader runs after `endFrame`, so it sees the demand of the frame just
declared, and before the wait, so work it starts can end that wait.

## 4. The contracts at a glance

Every contract is a set of `zui`-prefixed declarations, checked once at
comptime with exact messages. An unknown `zui`-prefixed declaration is a
compile error, so a misspelled optional member never goes unnoticed. The
only plain names are types the application uses directly: a source's
`Delivery` and `View`, and a renderer's payload types (SPEC.md §16.1).

| Contract | Implemented by | Required | Optional | SPEC.md |
|---|---|---|---|---|
| Text | a renderer or a font library | `zuiMeasure` | `zuiSegment`, `zui_thread_safe`, `zuiFingerprint` | §9.4 |
| Source | `zui_async` or the application | `Delivery`, `View`, `zuiSwap`, `zuiView`, `zuiDelivery`, `zuiInject` | `zuiPending`, `zuiEndFrame`, `zuiRefusedCount` | §14.2 |
| Renderer | a renderer | `zuiSubmit`, `zui_surfaces` | `zui_commands`, `zui_extended_color`, `zui_render_thread`, payload types, `zuiAttachSurface` with `zuiDetachSurface` | §16.2 |
| Host | a host | `zuiPoll`, `zuiWaker`, `zuiWait`, `zuiSurface`, `zuiApply`, `zui_surfaces` | `zui_capabilities`, `zuiOpenWindow` and `zuiCloseWindow` (exactly when `.many`), `zuiSemantics`, `zuiChromeRegions`, services (`zuiClipboard`, `zuiNotifications`, `zuiFileDialogs`, `zuiOpenUrl`, `zuiMenus`, `zuiFileWatch`), each a struct of functions whose types are checked | §16.3 |
| Tracer | a profiler binding | `zuiBegin`, `zuiEnd` | | §16.5 |
| Application | the application, run by `zui_app` | `Host`, `Renderer`, `zuiDeclare` | `Text`, `zuiRecord`, `zuiObserve`, `zuiLoader`, `init`, `deinit`; with many windows, `zuiDeclare` and each hook take the window, and `zuiSources`, `zuiWindowClosed` | §19.5 |
| Skin | a theme pack or the application | `zuiStyle` | | §19.2 |
| Wire payload | an application type with pointers | `zuiSerialize`, `zuiDeserialize` | | §19.6 |

**Proving a contract takes two implementations.** Each has a conformance
suite in `zui_testing` that every implementation runs in its own CI, and
each is proven by an adapter before a native implementation (the raylib
adapter, then the Windows host).

**What happens when something is missing** follows one table
(SPEC.md §16.6): what zui needs is a compile error; what zui uses quietly
falls back to a documented default; what the application asks for by name
is a compile error at the call unless guarded by `has_*`; what only this
machine lacks is a returned status. `zui_app` and the inspector list every
fallback in effect.

## 5. Threads

| Thread | Runs | Waits for |
|---|---|---|
| the host's main thread | the event loop, and declaration by default (macOS requires the loop there) | `zuiWait(nextFrame)`; a free arena in `beginFrame` |
| a render thread, optional | `zuiSubmit`, then `release` | nothing of zui's |
| producers, on the application's `Io` | the application's work; they publish into sources and wake | nothing of zui's; a full source refuses |
| zui's measuring tasks | cold text, with `zui_thread_safe` text | nothing |
| signal handlers | set an atomic flag and wake; the lifecycle event arrives in the next record | nothing |

zui runs no application code on another thread, and nothing on the UI
thread waits for application work.

## 6. Where each feature lives

The stage is the one in SPEC.md §21 that builds it.

| Feature | Lives in | Stage |
|---|---|---|
| instruction counts, trace zones | CI; the tracer contract in the core; the Tracy binding in `zui_tracy` | 1 |
| hardware counters | `core/bench/counters.zig`, through Linux's `perf_event_open`; read by `bench --counters` and `bench-compare --metric`, never by the core | 1 |
| trustworthy times: pinned runs, shuffled scenarios, random code and memory layouts, intervals against a noise band; simulated misses; machines side by side | `core/bench/` (`machine.zig`, `statistics.zig`, `compare.zig`, `counts.zig`, `report.zig`), never the core | 1, redone after 7 |
| frame record, time as an instant, scale and zoom | core | 2 |
| input as events, many pointers, environment | host reports; core applies | 2 |
| outside data, demand, `Status`, `Waker` | core contract; default sources in `zui_async` | 2 |
| letter spacing | core's `MeasureKey`; renderers measure and draw it | 2 |
| renderer and host contracts, surfaces | core vocabulary and checks | 3 |
| optional commands and their lowering | core emits and lowers; renderers draw | 3, 8 |
| the standard loop, capabilities and fallbacks | `zui_app` | 3 |
| system materials (Mica, vibrancy) | host asks the OS; renderer clears to transparent | 4 |
| per-monitor scale, lifecycle, signals | host, as record parameters and events | 4 |
| relay, replay, remote rendering | core relay and the `wire` surface kind; `zui_wire`'s encoding, wire host, wire renderer and client; `zui_testing`'s `Recording` and `Driver.replay` | 5 |
| hot reload of themes and assets | a file-watching source from the host, plus `zui_debug` | 5 |
| whole-string text cache, line-break segmentation | core caches; segmentation through the text contract | 6 |
| grow basis, aspect ratio, right-to-left, wrap, floating options | core layout | 6 |
| dividers, images' tint and corner radius | core emission; renderers draw them | 6 |
| static styles | core | 6 |
| gestures, intents, momentum, drag and drop | core arbitration; custom recognizers in modules | 7 |
| gradients, shadows, blur, transforms, materials, HDR | core commands and lowering; renderers draw; host reports headroom | 8 |
| inspector, and its overlay of zone times | `zui_debug` over `Frame.inspect`, and its `ZoneTimer` tracer over the tracer contract | 9 |
| accessibility | core semantics and actions; `zui_widgets` declares each control's; host bridges to the platform API | 9 |
| safety sweeps | core, over a finished frame; `endFrame` runs them behind `features.safety_sweeps` | 9 |
| the demo in a browser | `zui-web`: the application in a Web Worker, its frames drawn by a thin client over `zui_wire` | 9 |
| Linux and web hosts; many windows | `zui-host`; one `Context` per window, each made and declared through `zui_app`, and one renderer with a surface per window | 10 |
| the macOS host | `zui-host`, as the others; only its contract shapes exist (the `cocoa` surface, vibrancy as the system material), as stubs | set aside |
| window decorations: a custom title bar the OS still moves, resizes and snaps | chrome regions in the core, beside the frame, behind `features.chrome_regions`; `zui_app` hands them to the host's `zuiChromeRegions`; each host answers its window manager | 10 |
| host services: the clipboard, notifications, file dialogs, opening URLs, menus | the core's vocabulary and checks (`core/src/services.zig`); `zui_app.ServicesOf`'s guards; each host implements them, answering into a source the application chooses | 10 |
| motion and exit animations | `zui_motion`; ghost buffer in the core | 11 |
| text editing and IME | `zui_widgets`; composition events and the IME area from the core | 11 |
| color spaces, palettes, icons | `zui_color`, `zui_icons` | 11 |
| themes and skins | `zui_widgets`' default skin; `zui_themes`, in `themes/` | 11 |
| fonts, shaping, bidirectional text | behind the text contract | — |
| number, date and plural formatting | out of scope: a localization library | — |

## 7. From today's code to the spec

What exists today, by stage:

- **Releases 0.1 to 0.5, and 0.6 in part:** layout, text, input, state,
  the modules `zui_widgets`, `zui_reflect` and `zui_testing`, the
  benchmarks and `bench-compare`.
- **Stage 1:** instruction counts in CI, the tracer contract and
  `zui_tracy`.
- **Stage 2:** `Context(config)` with `Config.limits` and the text
  contract; the frame record with `now`, scale and zoom; input as an
  ordered event log over a pointer table; `endFrame` that always returns
  a frame; `nextFrame()`; letter spacing through the measurement key; the
  environment and host requests; sources in the core (the contract and
  its checks, swap and injection, demand, `Status` and `Waker`); the
  default sources in `zui_async`, with `zui_testing`'s conformance suite
  for sources; and `Element` with `decoration` and `clip: Axes`.
  `TaskPool` is deleted, and the three backends and the demo are on this
  API.
- **Stage 3:** the renderer contract and the `RenderCommand` union
  generated from `Config.commands` and the payload types, with the three
  backends as renderers; the host contract, with `RecordBuilder` and the
  check that a host and a renderer share a surface kind, proven by
  zui-raylib's adapter host (H1); the conformance suites for renderers
  and hosts in `zui_testing`, whose renderer suite the three backends run
  in CI and whose host suite raylib's host runs; `Features`, whose fields
  gate their APIs with compile errors naming them; and `zui_app`, the
  loop of SPEC.md §6.1 as a library, with a render thread, pacing and its
  reports, running the demo on raylib's host.
- **Stage 4:** the Windows host in `zui-host`, with dropped files and
  lifecycle events in the record and the system material reported in the
  environment; zui-sokol's renderer draws into its `win32` window,
  composed with alpha.
- **Stage 5:** relay, `relayTo` handing a listener each applied record
  with its deliveries; `zui_wire`, which writes records and frames, each
  frame as changes from the last, and its wire host, wire renderer and
  client, which run an application in one process and draw it in another
  over a `.wire` surface; `zui_testing`'s `Recording` and
  `Driver.replay`; and file watching, a host service that publishes
  `zui.FileChange`s into a source the application chooses, which
  zui-host's Windows host implements.
- **Stage 6:** the single-line fast path, the whole-string cache and
  static styles: element storage holds config references, pointers into
  the frame arena or to a style made at comptime with `zui.static`;
  line-break segmentation through the text contract's `zuiSegment`; the
  grow basis, `grow` starting from the content and `grow_from_min` from
  `min`; the `aspect_ratio` rule and images' natural sizes; dividers,
  `Border.between_children`, and images' tint and corner radius in the
  `image` command, which zui-raylib and zui-sokol draw and the renderer
  suite checks; the floating options, targets declared later,
  `Floating.capture` and `Floating.clip`; right-to-left layout,
  `Layout.mirrored` inherited from the environment's direction and
  `Direction.right_to_left`; and wrapping rows, `ui.wrapChildren()`
  behind `features.flex_wrap`.
- **Stage 7:** pans, by `Element.gestures`, a pointer past the touch slop
  going to the innermost element that pans on its axis with room to move;
  two-pointer zoom of the innermost element that accepts `zoom`, both
  reported by `manipulation`; long presses and double taps, timed against
  the record's `now`; momentum after a fling; custom recognizers over
  `pointerEvents`, `claim` and `decline`, such as `zui_widgets`' lasso;
  the intents `contextRequested`, `doubleTapped`, `dismissed`, `adjusted`
  and `navigated`; and drag and drop, a source that declares `drag`
  taking a pointer on the axes no region around it pans on, `startDrag`
  keeping its typed payload in the state table, and a target reading it
  with `dropped` or `draggedOver`.
- **The foundation, after stage 7:** `bench` and `bench-compare` pin to
  one core, record the machine, run each scenario alone in a shuffled
  order over several code and memory layouts, and judge a change by a
  bootstrap interval against a calibrated noise band; `bench --counters`
  reads hardware counters; `counts` simulates cache and branch misses;
  `bench-report` sets machines side by side. In the core, the layer sort
  moves only the commands outside layer 0; the id-to-rect results are
  narrow slots indexing dense entries that carry their region's flags; a
  press hit-tests once; and the string cache keeps a text's wrapped lines
  beside its entries, and its keys and ages apart from its values.
- **Stage 9:** `Frame.inspect`, and `zui_debug`'s inspector of
  the frame's diagnostics and fallbacks, the zone times its
  `ZoneTimer` tracer takes, the element tree and the hovered element's
  configs, in a theme reloaded from its file through the host's file
  watch; `zui_app` hands it each frame through `zuiObserve`, and
  zui-raylib's tour opens it with F12. Behind `features.semantics`,
  `Element.semantics` and `Frame.semantics()`, each node's role, label,
  value, bounds, state and actions in tree order, kept beside its frame;
  `action` events answered by `clicked`, `focused`, `adjusted`,
  `manipulation`, `contextRequested` and `dismissed`; and every
  `zui_widgets` control declaring its own, each scroll container's view
  and each heading's level; zui-host's Windows host bridges the list to
  UI Automation through `zuiSemantics`, with every control's pattern,
  state, changes and actions. `Frame.sweep()` checks the
  layout and command invariants a frame must keep, and with
  `features.safety_sweeps` `endFrame` panics on the first one broken.
  zui-web runs zui-sokol's tour in a browser: the tour in a Web Worker
  on an `Io` stepped to the page's clock, its frames drawn over
  `zui_wire` through WebGL 2 with four samples per pixel and the
  canvas's input sent back as records, published to GitHub Pages.

The code and the spec still differ in these places, each closed by the
roadmap item named:

| Today | The spec | Where today | Item |
|---|---|---|---|
| `Widgets(Ui)` with a `Theme` struct | `Widgets(Ui, Skin)` | `core/zui_widgets/` | K5 |
| `zui_debug`'s inspector runs in the application's process; a frame on the wire carries no elements for it | over the wire, the inspector runs in another process (SPEC.md §19.7) | `core/zui_debug/`, `core/zui_wire/` | not yet queued |
| a frame on the wire carries no chrome regions, and the wire host declares no `zuiChromeRegions`, so a remote window keeps the system's title bar | chrome over the wire | `core/zui_wire/` | not yet queued |
| zui-host's Linux host speaks Wayland only, opens one window, reports no low memory, IME or semantics, and keeps the compositor's title bar; its environment comes from the desktop portal and UPower over D-Bus, and stays at the defaults without them; its services have no menus, which Wayland lacks | a Linux host on Wayland and X11 with every report the Windows host makes, and a system material where the compositor offers one | `../zui-host` | H4 |

Unchanged in shape: element storage in pre-order structure-of-arrays, the
layout passes, the segment cache, ids, the state table, the frame arenas,
parallel measurement and the module boundary.

## 8. Repositories

| Repository | Holds |
|---|---|
| `zui` | in `core/`, the package `zui_core`: the core, the contracts, and the modules: async, widgets, reflect, testing, tracy, app, wire, debug, motion, color, icons; at the root, the package `zui` that users fetch, which re-exports core's modules and runs every package's steps |
| `zui-host` | native hosts, one directory per OS, chosen by target: `windows/` (H2) and `linux/`, on Wayland (H4) |
| `zui-raylib`, `zui-sokol` | renderers; `zui-raylib` also ships the raylib adapter host |
| `zui`, in `renderers/terminal/` | the package `zui_terminal`: the terminal renderer, its input decoder and raw-mode terminal, its conformance harness and its demo; no third-party library |
| `zui-web` | the browser: a thin client over `zui_wire` (V4), then a web host (H5); today the client's decoder, in WebAssembly, and its drawing of shapes, text, backdrop blurs and materials through WebGL 2 with four samples per pixel, checked against zui-sokol's renderer drawing the tour's frames, and the page's input written back as records the tour takes, with the cursor its frames ask for shown on the canvas; and zui-sokol's tour in a Web Worker on an `Io` of its own, whose tasks take turns on workers sharing its memory, drawing the frames it draws natively and timing them on the worker's clock; and the page that puts them together, published to GitHub Pages from CI and made cross-origin isolated by a service worker of its own |
| `zui`, in `themes/` | the package `zui_themes`: skins for OS design languages (K4); a skeleton today |
| `zui`, in `examples/` | the package `zui_examples`: samples and the template project (D1, D2); a skeleton today |

`zui-web`, `themes/` and `examples/` were created ahead of their items.
`zui-web` has its build, CI and an agent guide, and pins zui by commit;
`themes/`, `examples/` and `renderers/terminal/` each have their build
and CI jobs, and name core by path, so a change to core is built and
tested against each of them in place; each runs its own steps from its
own directory, and the root's `test-all` and `check-all` run them all.

zui-raylib and zui-sokol pin zui by commit, moved to stage 2 with it
(C8), and to the end of stage 6 with C10. Each renderer declares `Text`, a text
contract, and its loop builds a `FrameRecord`, from events where its library reports them and through
`zui.InputSampler` where it reports state (raylib), then waits as
`nextFrame` says. Each is a renderer (C1): a `Renderer` type implementing
the renderer contract, whose `config()` (zui-raylib's through
`zui_app.contextConfig`) builds the `Config` from its
declarations, so its `switch` over the commands names exactly what it
draws (the terminal's names only the five base commands). zui-raylib is
also a host (H1): `zui_raylib.Host` waits in GLFW and samples raylib's
input, and its demo runs through `zui_app`. zui-sokol's and
the terminal renderer's loops still do a host's work by hand, but zui-sokol's
renderer also draws into a native host's `win32` window without
sokol_app, with D3D11 through a DirectComposition swapchain that keeps
alpha so a system material shows (H8), and zui-host runs zui-sokol's tour
that way (H2), through `zui_app` with the tour's own text contract (C9);
on Linux it draws into a native host's `wayland` surface with OpenGL
through EGL, and zui-host's Linux host runs the same tour (H4). zui-host pins zui and zui-sokol by commit, as the renderers pin
zui; its Windows host runs its message loop on a thread of its own. Its
`remote` example runs zui-sokol's tour on `zui_wire`'s host and renderer
in one process, and draws it in another, through a `zui_wire.Client` over
the Windows host and zui-sokol's renderer (F5), and its `theme` example
restyles a window when its theme file changes, through the host's file
watch (F6). zui-sokol's context types (`Text`, `Image`, `Material`, its
`config`) live in `zui_sokol_ui`, which does not import sokol, so its
tour builds for `wasm32-freestanding`, for zui-web to run in a worker
(V4).

The terminal renderer, `zui_terminal`, keeps layout in pixel-like units,
`Text.cell_size` (8×16) to a cell, and paints a cell when its center lies
inside a command's bounds. `src/cells.zig` paints a frame's commands into
a `CellBuffer`; `src/screen.zig` double-buffers it and writes only the
cells that changed; `src/input.zig`'s `InputDecoder` turns UTF-8, VT key
sequences, SGR mouse reports and focus reports into a frame record's
events; `src/terminal.zig` enters raw mode on the alternate screen, waits
as `nextFrame` says, and wakes through a console input record on Windows
and a pipe elsewhere. Its conformance harness reads each pixel back as
the cell covering it, so it passes the renderer suite at a tolerance of
0, and its `test` step runs the suite too. It builds `examples/demo.zig`,
which draws `examples/showcase.zig`, the same UI as zui-sokol's demo.

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
| Renderer | a renderer | `zuiSubmit`, `zui_surfaces` | `zui_commands`, `zui_extended_color`, `zui_render_thread`, payload types | §16.2 |
| Host | a host | `zuiPoll`, `zuiWaker`, `zuiWait`, `zuiSurface`, `zuiApply`, `zui_surfaces` | `zui_capabilities`, services (`zuiClipboard`, `zuiFileDialogs`, …) | §16.3 |
| Tracer | a profiler binding | `zuiBegin`, `zuiEnd` | | §16.5 |
| Application | the application, run by `zui_app` | `Host`, `Renderer`, `zuiDeclare` | `Text`, `zuiRecord`, `zuiLoader`, `init`, `deinit` | §19.5 |
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
| static styles | core | 6 |
| gestures, intents, momentum, drag and drop | core arbitration; custom recognizers in modules | 7 |
| gradients, shadows, blur, transforms, materials, HDR | core commands and lowering; renderers draw; host reports headroom | 8 |
| inspector | `zui_debug` over `Frame.inspect` | 9 |
| accessibility | core semantics; host bridges to the platform API | 9 |
| macOS, Linux and web hosts; services; decorations; many windows | `zui-host`; one `Context` per window | 10 |
| motion and exit animations | `zui_motion`; ghost buffer in the core | 11 |
| text editing and IME | `zui_widgets`; composition events and the IME area from the core | 11 |
| color spaces, palettes, icons | `zui_color`, `zui_icons` | 11 |
| themes and skins | `zui_widgets`' default skin; `zui-themes` | 11 |
| fonts, shaping, bidirectional text | behind the text contract | — |
| number, date and plural formatting | out of scope: a localization library | — |

## 7. From today's code to the spec

What exists today is releases 0.1–0.5, the start of 0.6, stage 1
(instruction counts in CI, the tracer contract and `zui_tracy`), and
stage 2: `Context(config)` with `Config.limits` and the text contract,
the frame record with `now`, scale and zoom, input as an ordered event
log over a pointer table, `endFrame` that always returns a frame,
`nextFrame()`, letter spacing through the measurement key, the
environment and host requests, sources in the core (the contract and its
checks, swap and injection, demand, `Status` and `Waker`), the default
sources in `zui_async` with `zui_testing`'s conformance suite for
sources, and `Element` with `decoration` and `clip: Axes`. `TaskPool` is
deleted, and the three backends and the demo are on this API. From stage
3, the renderer contract and the `RenderCommand` union generated from
`Config.commands` and the payload types have landed, and the three
backends are renderers; so has the host contract, with `RecordBuilder`
and the check that a host and a renderer share a surface kind, proven by
zui-raylib's adapter host (H1); and the conformance
suites for renderers and hosts in `zui_testing`, whose renderer suite the
three backends run in CI, and whose host suite raylib's host runs; and `Features`, whose fields gate their APIs
with compile errors naming them; and `zui_app`, the loop of SPEC.md §6.1 as a
library, with a render thread, pacing and its reports, tested against an
offscreen host, and running the demo on raylib's host. From stage 4, the
Windows host in `zui-host`, with dropped files and lifecycle events in
the record and the system material reported in the environment, has
landed, and zui-sokol's renderer draws into its `win32` window, composed
with alpha. From stage 5, relay has landed: `relayTo` hands a listener
each applied record with its deliveries; and so has `zui_wire`, which
writes records and frames, each frame as changes from the last, and reads
them back; and its wire host, wire renderer and client, which run an
application in one process and draw it in another, over a `.wire`
surface. `zui_testing` records a session's records and replays them
(`Recording`, `Driver.replay`); and so has file watching, a host service
that publishes `zui.FileChange`s into a source the application chooses,
which zui-host's Windows host implements. From stage 6, the single-line
fast path, the whole-string cache and static styles have landed: element
storage holds config references, pointers into the frame arena or to a
style made at comptime with `zui.static`.

The code and the spec still differ in these places, each closed by the
roadmap item named:

| Today | The spec | Where today | Item |
|---|---|---|---|
| optional commands have variants, but nothing in declaration produces one, so nothing is lowered and `Diagnostics` lists no lowerings | `Decoration` and `Element` carry gradients, shadows, blur, transforms and materials, each lowered for a renderer that does not declare it | `src/style.zig`, `src/emission.zig` | G1, G2, G3, G5 |
| no `Config.Color`; colors are RGBA8 only | `zui.Color` or `zui.ExtendedColor`, clamped for a renderer without `zui_extended_color` | `src/context.zig`, `src/commands.zig` | G6 |
| `Widgets(Ui)` with a `Theme` struct | `Widgets(Ui, Skin)` | `zui_widgets/` | K5 |
| `Frame` exposes its storage arrays and `rectOf` | `Frame.inspect(index)` | `src/context.zig` | V1 |
| `Features` has every field and gates its API, but `Frame.semantics()` is always empty, `manipulation` always null, and `flex_wrap` and `safety_sweeps` change nothing | semantics, gestures, wrap and safety sweeps, each behind its field | `src/context.zig`, `src/layout.zig` | V2, I5, L7, V3 |

Unchanged in shape: element storage in pre-order structure-of-arrays, the
layout passes, the segment and string caches, ids, the state table, the
frame arenas, parallel measurement and the module boundary.

## 8. Repositories

| Repository | Holds |
|---|---|
| `zui` | the core, the contracts, and the modules: async, widgets, reflect, testing, tracy, app, wire, debug, motion, color, icons |
| `zui-host` | native hosts, one directory per OS, chosen by target: `windows/` today (H2) |
| `zui-raylib`, `zui-sokol`, `zui-terminal`, later `zui-web` | renderers; `zui-raylib` also ships the raylib adapter host |
| `zui-themes` | skins for OS design languages |
| `zui-examples` | samples and the template project |

The renderer repositories pin zui by commit and moved to stage 2 with it
(C8): each declares `Text`, a text contract, and its loop builds a
`FrameRecord`, from events where its library reports them and through
`zui.InputSampler` where it reports state (raylib), then waits as
`nextFrame` says. Each is a renderer (C1): a `Renderer` type implementing
the renderer contract, whose `config()` (zui-raylib's through
`zui_app.contextConfig`) builds the `Config` from its
declarations, so its `switch` over the commands names exactly what it
draws (the terminal's names only the five base commands). zui-raylib is
also a host (H1): `zui_raylib.Host` waits in GLFW and samples raylib's
input, and its demo runs through `zui_app`. zui-sokol's and
zui-terminal's loops still do a host's work by hand, but zui-sokol's
renderer also draws into a native host's `win32` window without
sokol_app, with D3D11 through a DirectComposition swapchain that keeps
alpha so a system material shows (H8), and zui-host runs zui-sokol's tour
that way (H2), through `zui_app` with the tour's own text contract (C9). zui-host pins zui and zui-sokol by commit, as the renderers pin
zui; its Windows host runs its message loop on a thread of its own. Its
`remote` example runs zui-sokol's tour on `zui_wire`'s host and renderer
in one process, and draws it in another, through a `zui_wire.Client` over
the Windows host and zui-sokol's renderer (F5), and its `theme` example
restyles a window when its theme file changes, through the host's file
watch (F6).

# Platform Audit and Plan

| | |
|---|---|
| Repository | zui |
| Commit | `dbdf31310c1fe51cfde3e5190ac581f1c2264931` (`main`) |
| Working tree | clean |
| Date | 2026-11-27 |
| Method | Static reading. SPEC.md, ARCHITECTURE.md, ROADMAP.md and `roadmap/decisions.md` in full; the core's vocabulary and the text packages directly; the hosts, the renderers, the terminal, the web path and `zui_app` through seven parallel read-only audits; the findings the plan rests on most were then checked by hand, and every cited line was opened. Nothing was built, run or measured: a figure marked *est.* is inferred from the code. Line numbers are as of this commit, and each item checks its ground again before it starts. |
| Standing | The owner has accepted every recommendation here as the plan of record. An item that proves wrong is changed in its own entry when that is found. |

## 1. Summary

zui's core already has the shape a platform-agnostic framework needs:
one frame boundary of plain data, contracts checked at comptime,
lowering driven by what a renderer declares, intents, replay and a wire
format. What it lacks is everything beneath the frame. zui was specified
as "layout and interaction, not rendering" (SPEC.md §1), so drawing, the
GPU, presentation and text were left to libraries and to whoever wrote a
renderer.

The owner's direction reverses that. zui will own its windowing and its
renderers for every GPU API, and drop sokol, raylib and every other
layer between it and the system, so that each target can be made as good
as it can be and progressive enhancement is enhancement, not fallback.

This report audits the code against that direction. It records each
finding with its grounding, the decisions that change, and the work that
closes them: 13 groups of items, each with a goal, a strategy, what it
depends on, and the boxes that must be checked for it to count as done.

The findings come to six structural gaps, in the order they block the
direction, and three smaller sets:

| # | Gap | Findings | Closed by |
|---|---|---|---|
| 1 | No GPU seam and no shared drawing stage: one `zuiSubmit` owns everything, the drawing code exists three times, and geometry is tessellated on the CPU every frame | F-01 to F-06 | `17-draw`, `18-gpu` |
| 2 | Nobody owns presentation or pacing | F-07 to F-09 | `19-present` |
| 3 | Text's rules forbid shaping, and every renderer lays every line out again each frame | F-11 to F-14 | `12-font-system` |
| 4 | Linux windowing rests on link-time libraries that the GPU's window integration ties zui to | F-09, F-10 | `19-present`, `21-windowing` |
| 5 | The input and host vocabulary is too small, so a second breaking change is unavoidable | F-15 to F-20 | `20-input`, `21-windowing`, `23-accessibility` |
| 6 | Cells are not a unit the core knows | F-21 | `19-present`, `21-windowing` |
| | Standing defects in the hosts, the core and the web path | F-22 to F-26 | `16-defects`, `22-web` |
| | Structure and process that the new direction strains | F-27 to F-31 | `15-charter`, `17-draw`, `19-present`, `20-input` |
| | Scope that does not exist yet: audio, mobile, macOS | F-32 | `25-audio`, `24-mobile`, `14-macos` |

The first step needs no platform work. A shared drawing stage with a CPU
reference renderer (`17-draw`) removes the duplication and most of
sokol, and gives every later GPU backend an exact answer to be checked
against.

## 2. How to read and track this document

- **Findings** are `F-01` to `F-32` (§5). Each has its grounding in the
  code, what follows from it, and the items that resolve it.
- **Decisions** are `D-01` to `D-18` (§6): what is recorded today, and
  what replaces it.
- **Work items** (§7) are labelled as the roadmap labels them,
  `{group}:{item}`, so they can be entered into `roadmap/` unchanged.
  The labels are proposed here and become final when
  `15-charter:02-enter-the-roadmap` enters them. Text items join the
  existing group `12-font-system` and the Metal backend joins
  `14-macos`.
- **Each item** gives a *Goal*, its *Grounding* (the findings it
  closes), a *Strategy*, what it *Depends on*, *Done when* as boxes to
  check, and *To settle* where a choice is left for the session that
  takes it, with the default to take if nothing better is found.
- **Items are deliberately high level.** Each is researched, planned and
  sliced when it is taken, as CLAUDE.md's "Tackle the next item" says; a
  slice is a commit that leaves every check green.
- **Order** is in §7.1: seven waves and a dependency map. An item may
  start when everything it depends on is done.
- **Tracking.** Until the items are in ROADMAP.md, the master list in
  §7.2 is the tracker: check an item there when all of its own boxes are
  checked. After that the roadmap tracks them and this report is the
  record of why.

An item counts as complete when all of these hold, beside its own boxes:

- [ ] every check CLAUDE.md lists under *Verifying* for the packages it
  touches is green, in all three optimize modes where they apply;
- [ ] the documents moved with it: SPEC.md, ARCHITECTURE.md §7, the
  package's README and the feature tour;
- [ ] a new contract has its compile-error cases, its conformance suite
  and a reference implementation that passes it;
- [ ] a change to a hot path has its instruction counts and a
  `bench-compare` against its parent;
- [ ] nothing it replaced is left behind: the old code, its build steps,
  its CI legs and its documents are removed in the same item.

## 3. The map

### 3.1 Goals

1. **Nothing third-party between zui and the system.** zui talks to each
   OS, each window system and each GPU API itself. What remains outside
   is the system's own: its kernel, its DLLs, its GPU drivers.
2. **One drawing implementation, many outputs.** A frame's commands are
   turned into what an output executes in one place. A GPU backend, the
   CPU reference, a terminal and the wire are outputs of it.
3. **Every target at its best.** A feature a target can do is done there
   natively and well. A fallback is the exception, is chosen by one
   stage, and is always reported.
4. **The core stays pure.** The frame boundary is unchanged in kind: a
   record in, a frame out, no OS and no drawing in the core.
5. **Every layer is a contract.** Each is checked at comptime with exact
   messages, has a conformance suite, and has a reference
   implementation.
6. **Apps, games and websites.** Idle applications cost nothing, games
   get display timing, raw input and the GPU, and a page is reachable by
   assistive technology and by its URL.

### 3.2 The layers

```
                          application
                               │
                    zui_app (optional runner)
                               │
        ┌───────── core: a record in, a frame out ─────────┐
        │                                                  │
      record                    commands     semantics   requests
        ▲                          │             │           │
        │                      zui_draw          │           │
        │              ┌───────────┼────────┐    │           │
        │          primitives    cells    wire   │           │
        │          ┌───┴────┐      │             │           │
        │       zui_gpu    CPU     │             │           │
        │      backends  reference │             │           │
        │          └───┬────┘      │             │           │
        │           present        │             │           │
        │              ▼           ▼             ▼           ▼
   hosts: surfaces and the frame clock, input, text input, services,
          the accessibility bridge
          (Windows, Wayland, X11, terminal, web; later macOS, mobile)
```

| Layer | Holds | Today | After |
|---|---|---|---|
| System | memory, the clock, threads, files, sockets | Zig's `std` and the `std.Io` the application passes | the same: zui builds no layer here, and adds what `std` lacks behind a host |
| Hosts | windows and surfaces, input, text input, services, the accessibility bridge, the frame clock | in-house on Windows; on Linux through libwayland-client, xcb and Xlib; raylib's adapter; a terminal; a web host | every host in-house, down to the wire or the system's own ABI; no adapter hosts |
| GPU | devices, swapchains, buffers, textures, pipelines, passes | none of zui's: sokol_gfx, raylib and the page's JavaScript | `zui_gpu`, a contract, with a backend for each API |
| Text | faces, shaping, rasterizing, the atlas | a per-codepoint pen and an atlas in `zui_glyphs`; stb_truetype | zui's own parser, shaper and rasterizer; glyph runs made once |
| Draw | a frame's commands into what an output executes | inside each renderer, three times over | `zui_draw`, one stage, with a CPU reference |
| Core and modules | the frame boundary, layout, interaction, state, widgets, design | as SPEC.md has them | unchanged in kind, with a larger input and request vocabulary |

### 3.3 The contracts

| Contract | Today | After | Item |
|---|---|---|---|
| Text | `zuiMeasure`, additive; drawing fixed to a per-codepoint pen | measuring and shaping; a shaped run cached and carried by the command; caret queries; fallback | `12-font-system:01` |
| Renderer | `zuiSubmit(surface, frame)`, one implementation per library | one per output family (GPU, CPU, cells, wire), each on `zui_draw` | `17-draw:02`, `18-gpu:01` |
| GPU | none | device, swapchain, resources, a fixed pipeline list, read-back, capabilities reported at run time | `18-gpu:01` |
| Surface | a union of native handles | a window's id, pixel size, scale, format and present path | `19-present:01` |
| Host | a window half and a loop half; cursor and caret requests | the same halves, with a frame clock, presentation feedback, window operations, popups and a text-input session | `19-present:01`, `20-input:01` |
| Record | pointers, wheel, keys, text, environment, lifecycle, actions | modifiers, units and phases, composition, physical keys, touch and pen on every host, gamepads, redraw, insets | `20-input:01` |
| Semantics | the whole list every frame, on one host | more roles, text and live regions, sent as changes, on every host | `20-input:01`, `23-accessibility` |

### 3.4 What leaves and what stays

| Dependency | Used for | Outcome | By |
|---|---|---|---|
| sokol_gl | immediate-mode vertices and batching | leaves first | `17-draw:05` |
| raylib | a renderer and an adapter host | leaves | `17-draw:05` |
| sokol_gfx, sokol_app, sokol-shdc | GPU objects, a test window, shader translation | leave | `18-gpu:08` |
| `composition.c` | the Direct3D composition swapchain, in C | ported into the Direct3D backend | `18-gpu:03` |
| stb_truetype | font parsing and rasterizing | leaves | `12-font-system:02` |
| libwayland-client, wayland-egl | the Wayland connection and EGL's window | leave | `21-windowing:04` |
| libxcb and its extensions, libX11 | the X11 connection and EGL's display | leave | `21-windowing:05` |
| libxkbcommon | keymaps and compose | stays for now, loaded at run time | `21-windowing:06` |
| EGL, Vulkan and the vendors' drivers | the GPU | stay: they are the system's; loaded at run time | `18-gpu:04`, `18-gpu:06` |
| libc on Linux | the loader the drivers need | stays | |
| Windows' system DLLs | the OS | stay | |
| Tracy; Node and Chromium | profiling; the web checks | stay | |

### 3.5 Where the new parts live

Working names, settled by `15-charter:01-scope-in-spec`:

| Directory | Package | Holds |
|---|---|---|
| `draw/` | `zui_draw` | the primitive format, the coverage math, the scene builder and the CPU reference |
| `gpu/` | `zui_gpu` | the GPU contract and its checks, and a backend per directory: `direct3d/`, `gl/`, `vulkan/`, `webgpu/`, `metal/` |
| `renderers/` | one per output family | the GPU renderer (`zui_draw` on a set of backends), the CPU renderer, the terminal's cells; `sokol/`, `raylib/` and `webgl/` are removed |
| `text/` | as today | the face, the shaper and the atlas replace `truetype/`'s stb and `glyphs/`' pen |
| `hosts/` | as today | `native/` gains its own wire clients; mobile hosts join it |

### 3.6 Strategies

- **The spec moves first.** SPEC.md is the contract, and today it
  forbids this work. Each group starts by writing its contract into the
  spec; no item builds ahead of it.
- **The CPU reference is the oracle.** It is written before any in-house
  GPU backend, and every backend is judged by how closely it matches it.
  Pixel checks stop depending on which machine's rasterizer drew them.
- **Bridge, then replace.** Every wave leaves every target running.
  sokol_gfx stays as a bridge under the new drawing stage until zui's
  own backends pass; nothing is removed before its replacement is
  checked.
- **Prove each contract twice** before building on it, as the roadmap
  already requires: the GPU contract by the CPU reference's side and one
  real backend before the others are written; the present contract by
  two hosts.
- **One more breaking change, made once.** Everything that changes the
  record, the events, the requests and the wire lands as one designed
  change (`20-input:01`), not as a trickle.
- **Comptime for what a target is, run time for what a machine has.**
  Which backends exist is a comptime set, and only those compile. Which
  one starts, and what this device cannot do, is found at run time and
  reported.
- **Measure, as now.** Core budgets (SPEC.md §20.2) do not move. The
  drawing stage and each backend get budgets of their own when their
  contract is written, and a claimed win ships with its measurement.

## 4. What is sound

These are kept as they are, and the plan leans on them.

- **The frame boundary.** A record in and a frame out, with relay,
  replay and `zui_wire` built on it (SPEC.md §6, §19.6). Sources and
  demand give outside data the same treatment (§14).
- **Comptime contracts.** Every contract is `zui`-prefixed declarations
  checked once, with exact messages and unknown declarations refused
  (`core/src/contracts.zig`); 162 compile-error cases pin them.
- **Generated commands and lowering.** `RenderCommand`'s payload is
  built from what the renderer declares (`core/src/commands.zig:55`), so
  an exhaustive `switch` covers exactly what is drawn and an undeclared
  effect is lowered at no cost.
- **Who owns the loop.** One non-blocking `step` turned by a pulled,
  pushed or stepped host (SPEC.md §6.1, §16.3) already fits the browser,
  mobile and an embedding application.
- **Memory and measurement.** One reservation planned at comptime,
  structure-of-arrays in declaration order, no allocation after `init`,
  instruction counts gating CI, and `bench-compare` judging by
  confidence intervals.
- **Intents, gestures and semantics** as plain data answered by one set
  of queries (SPEC.md §11.3, §13.5).
- **Most of the window layer is already in-house.** The Windows host is
  hand-written declarations against system DLLs. The Linux host has its
  own D-Bus client (`hosts/native/linux/dbus.zig`) and hand-written
  Wayland protocol tables (`hosts/native/linux/wayland.zig:141`). The
  terminal package has no third-party code and is already layered as
  terminal, host, input decoder, cell painter and screen.
- **Conformance suites, the test card and snapshots**
  (`core/zui_testing/`, `apps/test_card/`).
- **The design system** (SPEC.md §18): roles, solved contrast, color
  vision and the audit of a finished frame.

## 5. Findings

Each finding gives its grounding in the code, what follows from it, and
the items that resolve it. Paths are from the repository's root.

### Drawing and the GPU

#### F-01 — One call owns the device, the swapchain, presentation and the drawing

- **Grounding.** The renderer contract is `zuiSubmit(surface, frame)`
  and `zui_surfaces` (SPEC.md §16.2). `renderers/sokol/src/renderer.zig`
  is one struct that makes the device, keeps a swapchain per window,
  tessellates, draws text and presents. An image handle is a sokol id,
  so an application calls sokol_gfx to make one
  (`renderers/sokol/src/root.zig:21`).
- **Consequence.** There is no seam at which a GPU API can be swapped.
  Each new API would be a whole renderer.
- **Resolution.** `17-draw:02`, `18-gpu:01`.

#### F-02 — Geometry is tessellated on the CPU every frame

- **Grounding.** Every shape goes through sokol_gl's immediate mode, at
  about 120 call sites. A rounded rectangle is an outline of 4 × (8 + 1)
  points filled as a fan, 108 vertices; a border is 216; a blurred
  shadow about 1,400 (`renderers/sokol/src/renderer.zig:95`, `:716`,
  `:798`, `:933`). Anti-aliasing is 4× multisampling alone
  (`renderers/sokol/src/egl.zig:118`). Nothing is kept between frames.
- **Consequence.** For 1,000 rounded rectangles and 1,000 lines of text,
  about 350,000 vertices and 10 MB are built and uploaded each frame,
  and a draw call starts at every switch between shapes and text
  (*est.*). Edge quality depends on the sample count the surface offers.
- **Resolution.** `17-draw:01`, `17-draw:02`.

#### F-03 — The drawing code exists three times

- **Grounding.** `renderers/webgl/src/draw_list.zig:496-895` copies
  `renderers/sokol/src/renderer.zig:588-988`: the outline tracer, the
  subpixel grid, the clip and transform stacks, the gradient, the shadow
  and the border. The blur's taps are copied too
  (`renderers/webgl/src/backdrop_blur.zig:6` and
  `renderers/sokol/src/backdrop_blur.zig:345`).
  `renderers/raylib/src/root.zig:699` has a third tracer. The WebGL copy
  is bent to match sokol_gl: tap weights split for 8-bit vertex colors,
  gradients in bands.
- **Consequence.** A change to how anything is drawn is made three times
  and compared by pixels. More backends would multiply it.
- **Resolution.** `17-draw:02`, `17-draw:05`.

#### F-04 — Overflow and failure in the renderer are silent

- **Grounding.** sokol_gl is set up for 524,288 vertices and 16,384
  commands (`renderers/sokol/src/renderer.zig:136`) and nothing reads
  its error, so the rest of a frame past either is not drawn. The glyph
  atlas is `create(...) catch null` (`:139`), so text disappears if it
  fails. Present and resize results are discarded
  (`renderers/sokol/src/composition.zig:75`, `:105`). There is no path
  for a lost device.
- **Consequence.** These break SPEC.md's principle 11, "nothing is
  silent", below the frame.
- **Resolution.** `17-draw:02`, `19-present:04`.

#### F-05 — Effects are costly and blend two ways

- **Grounding.** One backdrop blur is up to 516 blended draws over its
  region at full resolution, into two full-frame RGBA32F targets
  (`renderers/sokol/src/backdrop_blur.zig:21`, `:114-160`). A shadow is
  a caster and six rings of fading triangles, not a blur. An SDR target
  blends in sRGB encoding and an FP16 target in linear light
  (`renderers/sokol/src/destination.zig:128`, `:146`). Linux needs
  OpenGL 4.3 core (`renderers/sokol/src/egl.zig:157`).
- **Consequence.** The same frame looks different in SDR and HDR,
  effects are the most expensive thing drawn, and the floor is higher
  than the drawing needs.
- **Resolution.** `17-draw:01`, `17-draw:06`, `18-gpu:04`.

#### F-06 — The draw vocabulary is narrow

- **Grounding.** A clip is a rectangle; a gradient is linear with two
  stops; a border has one color; an image has no source rectangle; there
  is no opacity for a group, which is why overlays enter by sliding and
  not fading (ARCHITECTURE.md §7); there are no paths, so every icon is
  a font glyph (`core/src/commands.zig:61-133`). A clip inside a
  rotation scissors to its bounding box
  (`renderers/sokol/src/renderer.zig:419`). The web renderer does not
  draw images at all (`renderers/webgl/src/draw_list.zig:261`).
- **Consequence.** Designs the components' specs ask for cannot be
  drawn, on any target.
- **Resolution.** `17-draw:07`.

### Presentation

#### F-07 — The contract has no display timing

- **Grounding.** `NextFrame` is `immediately`, `at` or `on_event`, and
  `FrameParams` is `now`, viewport, scale and zoom
  (`core/src/record.zig:40`, `:257`). `now` is read when the host is
  polled. Each host then improvises: Windows and X11 return at once from
  `.immediately` (`hosts/native/windows/host.zig:1005`,
  `hosts/native/linux/x11_host.zig:754`), so the rate is however long
  the swap blocks; Wayland holds for its frame callback inside
  `zuiWait`, for all windows together
  (`hosts/native/linux/wayland_host.zig:787`); the terminal does not
  pace at all (`renderers/terminal/src/terminal.zig:87`).
- **Consequence.** An animation runs at a different rate on each host,
  spins where a swap does not block, and is timed by when input was
  polled, not by when its frame is shown. Two windows on different
  displays run at the slower one's rate.
- **Resolution.** `19-present:01`, `19-present:03`.

#### F-08 — Commit, resize and loss have no owner

- **Grounding.** On Wayland the host sets the viewport, the scale and
  the frame callback, and the renderer commits through `eglSwapBuffers`.
  The host learns that a frame was drawn from `zuiApply`
  (`hosts/native/linux/wayland_host.zig:898`), which `zui_app` calls
  before a render thread's submit (`core/zui_app/zui_app.zig:921`).
  Nothing synchronizes a resize with the frame drawn for it on any host.
  There is no damage, and no redraw event; a single pulled window
  redeclares after every wait to make up for it
  (`core/zui_app/zui_app.zig:783`). A renderer's error ends the run.
  Attaching, detaching and stopping wait on the render thread without a
  bound (`:994`, `:1007`, `:1021`).
- **Consequence.** Pacing breaks as soon as a renderer submits on its
  own thread, a resize shows frames of the wrong size, a small change
  redraws everything, and a driver reset is fatal.
- **Resolution.** `19-present:01`, `19-present:02`, `19-present:04`,
  `19-present:05`.

#### F-09 — `Surface` is a union of native handles

- **Grounding.** `zui.Surface` is a closed union in the core: `win32`,
  `cocoa`, `wayland` (libwayland's display and surface), `x11` (an Xlib
  display), `web`, `offscreen`, `terminal`, `wire`, and `library` for a
  window raylib or sokol_app owns (`core/src/surface.zig:45`). The
  renderer is given no pixel size, which it derives as
  `round(viewport × scale × zoom)`
  (`renderers/sokol/src/renderer.zig:669`), and no window id, so it
  matches windows by raw handle.
- **Consequence.** A surface cannot say that the host presents the
  buffers, which owning the wire requires (F-10). Pixel sizes can
  disagree with the compositor's at fractional scales. Adapter surfaces
  outlive the adapters.
- **Resolution.** `19-present:01`.

### Windowing

#### F-10 — Linux windowing is tied to link-time libraries

- **Grounding.** `hosts/native/build.zig:24` links libc and eight
  libraries: wayland-client, xkbcommon, X11, X11-xcb, xcb, xcb-xkb,
  xcb-cursor and xkbcommon-x11. The renderer adds EGL, wayland-egl and
  X11 (`renderers/sokol/build.zig:117`). EGL and Vulkan's window
  integration take libwayland's or Xlib's own objects, which is why
  `Surface` carries them.
- **Consequence.** zui cannot speak the wire itself while a library
  presents for it. The Linux packages need the system's libraries to
  link, so they do not cross-compile as the Windows host does, and
  libwayland allocates for each frame's callback and xcb for each event
  and reply, outside zui's "no allocation after `init`".
- **Resolution.** `21-windowing:04`, `21-windowing:05`,
  `21-windowing:06`.

### Text

#### F-11 — A text command carries bytes, so every line is laid out again each frame

- **Grounding.** The `text` payload is the line's UTF-8, its style and a
  line index (`core/src/commands.zig:107`). Each renderer walks every
  text command's codepoints to fill the atlas
  (`text/glyphs/src/atlas.zig:156`) and again to place quads
  (`text/glyphs/src/pixel_grid.zig:94`), with two atlas probes and two
  indirect calls for each glyph. The core's caches spare measuring, but
  only the atlas survives a frame in a renderer. The caches are keyed by
  size × zoom, so an animated size misses everything
  (`core/src/text.zig:370`), and the widgets find a caret by measuring
  every prefix (`core/zui_widgets/zui_widgets.zig:3257`).
- **Consequence.** Drawing warm text costs a full layout per frame per
  renderer, and there is nowhere to keep the result of shaping.
- **Resolution.** `12-font-system:01`, `12-font-system:03`.

#### F-12 — The text rules forbid shaping

- **Grounding.** `zui_glyphs.layOut` is a pen that adds one advance per
  codepoint in one font (`text/glyphs/src/layout.zig:53`). A renderer
  reaches fonts through `Fonts.advance(font, codepoint)`
  (`text/glyphs/src/fonts.zig:59`), and the font systems' conformance
  suite fails a glyph whose advance depends on its neighbours
  (`text/glyphs/src/conformance.zig:50`). `roadmap/12-font-system.md`
  records "commands carry the text and its style, not glyphs".
  `zui_truetype` declares no `zuiSegment`.
- **Consequence.** No kerning, ligatures, combining marks, bidirectional
  text or fallback fonts; a glyph a font lacks is drawn as its
  missing-glyph box; CJK and Thai never wrap. The core's contract is
  close to enough, since additive measurement over segments allows
  shaped widths (SPEC.md §9.4); the drawing side is what blocks it.
- **Resolution.** `12-font-system:01`, `12-font-system:04`,
  `12-font-system:05`, `12-font-system:06`.

#### F-13 — The glyph atlas thrashes and wastes

- **Grounding.** The atlas is 1024 × 1024, fixed at comptime, keyed by
  font, whole pixel size and codepoint, with no eviction
  (`text/glyphs/src/atlas.zig:44-95`). `addGlyphs` returns at the first
  `error.Full`, which a single glyph box over 320 pixels also raises
  (`:133`); the retry after `reset` fails at the same glyph, so the
  atlas is wiped, rasterized again and uploaded again every frame, and
  the glyphs after it never appear (`:156-176`). Any new glyph uploads
  the whole image, and sokol makes a new 4 MiB texture for it
  (`renderers/sokol/src/renderer.zig:500`). The RGBA layout spends four
  bytes on one byte of coverage. Each glyph's origin is rounded to a
  whole pixel by itself (`text/glyphs/src/pixel_grid.zig:60`).
- **Consequence.** One oversize glyph or a full atlas costs a
  rasterization of everything each frame. Spacing is uneven at a scale
  of 1, and an animated size adds a set of glyphs for each pixel size.
- **Resolution.** `16-defects:05` now, `12-font-system:03` for good.

#### F-14 — The font parser is C that trusts its input

- **Grounding.** `text/truetype/src/face.zig` binds stb_truetype, which
  checks no bounds; the web host loads fonts that arrive at run time and
  says so (`hosts/web/src/text.zig:31`). A collection's tables are read
  at offsets relative to the wrong start
  (`text/truetype/src/face.zig:81`, `:179`), and only its first face
  loads. A `Text` holds eight fonts (`text/truetype/src/root.zig:33`).
  Rasterizing is unhinted coverage with no subpixel offset
  (`text/truetype/src/face.zig:130`).
- **Consequence.** A malformed font reads out of bounds, and the face
  layer cannot grow into shaping, variable fonts or color glyphs.
- **Resolution.** `12-font-system:02`.

### Input and the host

#### F-15 — IME composition is specified and absent

- **Grounding.** SPEC.md §7.1 lists a `composition` event and an
  `os_gesture` event, and §11.1 a `ui.composition()` query.
  `core/src/input.zig:224`'s `Event` has neither, and ARCHITECTURE.md §7
  does not list the difference. The Linux host keeps the preedit text
  and cannot report it, though it tells IBus that the client draws it
  (`hosts/native/linux/text_input.zig:10`,
  `hosts/native/linux/ibus.zig:25`). The Windows host handles no
  `WM_IME_*` message. The web host sends only committed text
  (`hosts/web/web/page_text_field.mjs:28`). No host is told the text
  around the caret or what a field is for.
- **Consequence.** Text being composed is invisible on every host, and
  an on-screen keyboard cannot correct, predict or choose its layout.
- **Resolution.** `20-input:01`, `20-input:02`, `20-input:04`.

#### F-16 — Pointer, wheel and key events carry too little

- **Grounding.** A pointer event has no modifiers and three buttons
  (`core/src/input.zig:14`, `:27`), so a table cannot add to a selection
  with a click (ARCHITECTURE.md §7). `Wheel` is a position and a delta:
  no unit, no phase, no modifiers (`:94`), though SPEC.md §7.1 says
  "precise or in lines". A key is a logical key and an opaque scancode
  (`:203`), with no keypad, media or keys past F12; physical keys are
  open question 1 (SPEC.md §22). There are no gamepad events, no
  relative pointer motion and no pointer lock.
- **Consequence.** Ordinary desktop interactions and most game input
  cannot be expressed.
- **Resolution.** `20-input:01`, `21-windowing:09`.

#### F-17 — Touch and pen reach zui only in the browser

- **Grounding.** The Windows host reads legacy mouse messages and
  reports every pointer as a mouse (`hosts/native/windows/host.zig:475`,
  `:1291`); nothing handles `WM_POINTER`. The Wayland host takes a
  seat's pointer and keyboard only
  (`hosts/native/linux/wayland_host.zig:1304`). The X11 host uses the
  core protocol and XKB. Only the web host, through Pointer Events,
  sends touch and pen (`hosts/web/web/input_recorder.mjs:123`).
- **Consequence.** Stage 7's pans, pinches, long presses and momentum
  cannot be reached on a native host.
- **Resolution.** `21-windowing:03`.

#### F-18 — A frame can ask the host for a cursor and a caret, and nothing else

- **Grounding.** `HostRequests` is `cursor` and `text_input.caret`
  (`core/src/record.zig:250`). A window's title, size and state are
  fixed when it opens (`core/src/host.zig:35`). No host makes a popup:
  every window is top-level, at most four of them
  (`hosts/native/windows/host.zig:53`,
  `hosts/native/linux/x11_host.zig:99`), and the Wayland host binds no
  popup: the positioner request sits in its tables, untyped and unused
  (`hosts/native/linux/wayland.zig:150`).
- **Consequence.** A menu, a tooltip or a dropdown cannot leave its
  window on any host. An application cannot retitle, resize or make its
  window fullscreen.
- **Resolution.** `20-input:01`, `21-windowing:01`, `21-windowing:02`.

#### F-19 — Lifecycle and environment stop short of mobile

- **Grounding.** `Lifecycle` is sleep, wake, a terminate request and low
  memory (`core/src/input.zig:267`). The environment has no safe-area
  insets, no keyboard occlusion, and no word for whether the pointer is
  coarse or can hover. A renderer's `init` needs a surface, so an
  application cannot start before its first surface exists
  (`core/src/host.zig:202`). Dialogs, drops and file watching speak
  paths, not grants (`core/src/services.zig:57`). The Windows host never
  reports `text_scale`, `locale` or `direction`.
- **Consequence.** The contracts cannot yet describe Android or iOS, and
  a desktop application misses settings the OS has.
- **Resolution.** `20-input:01`, `16-defects:02`, `24-mobile`.

#### F-20 — Accessibility is bridged on one host

- **Grounding.** Only the Windows host declares `zuiSemantics`. It
  copies every node and its text each frame, client or no client
  (`hosts/native/windows/accessibility.zig:79`), finds an element by a
  linear scan under a lock (`:250`), and has no text, grid, table or
  tree pattern, no live regions and refuses `SetValue` (`:1133`).
  `zui.SemanticRole` has no tab, grid, row, tree or spin button
  (`core/src/semantics.zig:6`), so widgets report the nearest wrong role
  (ARCHITECTURE.md §7). The Linux host has no bridge, and the web page
  is one canvas (`hosts/web/web/index.html:12`).
- **Consequence.** An application is reachable by assistive technology
  on Windows alone, and there in part.
- **Resolution.** `20-input:01`, `23-accessibility`.

### Units

#### F-21 — Cells are not a unit the core knows

- **Grounding.** The terminal maps 8 × 16 layout units to a cell inside
  its own package (`renderers/terminal/src/root.zig:27`), and paints a
  cell when its center lies in a command's bounds
  (`renderers/terminal/src/cells.zig:27`). The core snaps to pixels only
  (`core/src/emission.zig:287`). The cell size has three sources. Every
  codepoint takes one cell (`text/glyphs/src/layout.zig:90`), and the
  screen assumes the cursor moved one column
  (`renderers/terminal/src/screen.zig:52`). A cell is a codepoint and
  two colors (`renderers/terminal/src/cells.zig:5`).
- **Consequence.** Anything under half a cell vanishes: one-unit
  dividers, thin scrollbars. Wide characters and combining marks shift
  the rest of a row. There is no bold, underline or color depth below
  true color.
- **Resolution.** `19-present:06`, `21-windowing:07`.

### Standing defects

#### F-22 — The Windows host

- **Grounding.** `zuiPoll` resets the one `input_arrived` event for
  whichever window is polled (`hosts/native/windows/host.zig:936`), so
  with two windows an event for the first that arrives before the second
  is polled is stranded until another arrives. No `WM_CAPTURECHANGED` is
  handled, so a release lost to another window leaves the capture stuck.
  A full inbox drops the newest event, a release included, and moves are
  not coalesced (`:272`). `WM_SYSCHAR` is unhandled, and the session's
  end can outrun the record that reports it (`:570`).
- **Resolution.** `16-defects:02`.

#### F-23 — The Linux host

- **Grounding.** A decoration is asked for only when the compositor
  offers xdg-decoration (`hosts/native/linux/wayland_host.zig:646`), so
  by the code a native-title-bar window has none on a compositor that
  leaves decorations to the client, as GNOME's does; this was not run. A
  cursor shows only with cursor-shape-v1 (`:1257`). The result of
  dispatching pending events is ignored (`:848`). Wheel deltas are not
  converted to layout units (`hosts/native/linux/inbox.zig:88`). The
  inbox drops as Windows' does.
- **Resolution.** `16-defects:03`.

#### F-24 — The terminal host

- **Grounding.** No signal handler or panic hook restores the terminal:
  raw mode, the alternate screen and mouse tracking are left on
  (`renderers/terminal/src/terminal.zig:38`). Ctrl+C and Ctrl+Q end the
  run inside the decoder (`renderers/terminal/src/input.zig:80`), so an
  application cannot bind them. A resize is found by reading the size
  every 250 ms (`renderers/terminal/src/terminal.zig:96`). Paste is not
  bracketed, so pasted newlines press Enter. C1 control characters are
  written through (`renderers/terminal/src/cells.zig:213`). Mouse
  buttons past the third decode as the first three
  (`renderers/terminal/src/input.zig:188`).
- **Resolution.** `16-defects:04`.

#### F-25 — Differences the core already knows and has not queued

- **Grounding.** ARCHITECTURE.md §7 lists them with "not yet queued":
  past `max_render_commands` the emitter drops a `clip_end` whose
  `clip_begin` it kept, so the sweep panics (`core/src/emission.zig`); a
  pinch that begins on an element with a custom recognizer never zooms
  (`core/src/context.zig`); the inspector and chrome regions do not
  cross the wire.
- **Consequence.** The first breaks SPEC.md §17.2, "never corrupt".
- **Resolution.** `16-defects:01`, `15-charter:02`.

#### F-26 — The web path

- **Grounding.** The host needs cross-origin isolation and throws
  without it (`hosts/web/web/host_page.mjs:30`), though its workers take
  turns one at a time (`hosts/web/src/stepped_io.zig:128`); there is no
  single-threaded build. Every `keydown` on the canvas is cancelled
  (`hosts/web/web/input_recorder.mjs:136`), which traps Tab and the
  browser's shortcuts. Two ways of running exist, a thin client over
  `zui_wire` and the host in a worker, and only the second is published
  (`hosts/web/build.zig:259`). The client is fixed to one context's
  shape (`hosts/web/src/browser.zig:9`), the package exports no module
  (`hosts/web/build.zig:160`), and the drawer's constants are copied by
  hand between Zig and JavaScript
  (`renderers/webgl/web/frame_drawer.mjs:1`). There is no URL, history,
  file dialog or fullscreen, and text entry on a phone is unproven.
- **Resolution.** `22-web`.

### Structure and process

#### F-27 — Conformance cannot hold quality across backends

- **Grounding.** The renderer suite draws 320 × 192 at a scale of 1,
  allows a color to differ by 32 in 255, and checks text by its presence
  (`core/zui_testing/renderer_conformance.zig:9`, `:620`). The web's
  pixel check compares with sokol drawn by whatever rasterizer the
  machine has, with tolerances written for Mesa's llvmpipe
  (`roadmap/decisions.md`, "A reference drawn by llvmpipe"). The test
  card's pixel hashes are planned to accept any rasterizer they do not
  know (`11-polish:41-pixel-hashes`).
- **Consequence.** Nothing can say that two backends draw the same
  thing, which is the question every new backend raises.
- **Resolution.** `17-draw:03`, `17-draw:04`.

#### F-28 — `zui_app` fixes the renderer in ways a choice at run time cannot use

- **Grounding.** `contextConfig` copies one renderer type's declarations
  into the context (`core/zui_app/zui_app.zig:32`). A renderer's `init`
  takes a surface and optionally the text, with no allocator, `Io` or
  preference (`:647`, `:1231`). `zui_render_thread` is a comptime
  constant (`:750`). Lowering is decided at comptime alone (SPEC.md
  §13.3). A host holds four windows in fixed slots, the owner's choice
  over a comptime parameter (`roadmap/decisions.md`).
- **Consequence.** A renderer that starts Vulkan and falls back to
  OpenGL must hide inside one type declaring what both can do, and what
  a device lacks cannot be lowered or reported.
- **Resolution.** `18-gpu:01`, `19-present:02`, `21-windowing:01`.

#### F-29 — The module boundary pushes vocabulary into the core

- **Grounding.** A module imports only its own directory and `zui`
  (SPEC.md §3.3). Because of it, motion moved into the core, the design
  vocabulary and the icon names live there, `zui_design` carries its own
  OKLab conversions beside `zui_color`'s, and `zui_widgets_data` takes
  its `Widgets` as `anytype` (`roadmap/decisions.md`; SPEC.md §19.2.1).
- **Consequence.** "A module before core" is being paid for with
  exceptions to it, and the new layers will want to share more, not
  less.
- **Resolution.** `15-charter:03`.

#### F-30 — Declaration cannot ask the host for anything

- **Grounding.** A service is called only between frames, so a click
  sets a flag for `zuiLoader` to act on
  (`core/zui_app/zui_app.zig:189`). A request is named at comptime, so
  two instances of one request cannot be told apart, and a full sink
  drops its answer silently (`core/src/services.zig:12`, `:174`).
- **Consequence.** The simplest uses, copy this text or open this link,
  need plumbing in every application.
- **Resolution.** `20-input:03`.

#### F-31 — The queue builds on layers about to change

- **Grounding.** ROADMAP.md's next rows are rich text and reordering,
  pickers, views, pixel hashes and text editing with IME. Rich text and
  text editing sit on the text contract and the input vocabulary that
  F-11 to F-16 replace; pixel hashes sit on rasterizers that F-27
  replaces with one reference.
- **Consequence.** Work done now would be redone, against the roadmap's
  own rule to fix the foundation first.
- **Resolution.** `15-charter:02`.

#### F-32 — Scope that does not exist yet

- **Grounding.** There is no audio anywhere. There are no mobile hosts.
  macOS is set aside for want of hardware (`roadmap/14-macos.md`), and
  Metal with it. None of this was audited, since there is no code.
- **Consequence.** "Apps, games and websites on every platform" has
  three absent parts, and Metal's model should shape the GPU contract
  before it is fixed.
- **Resolution.** `25-audio:01`, `24-mobile`, `14-macos:05`,
  `18-gpu:01`.

## 6. Decisions

What is recorded today, in SPEC.md or `roadmap/decisions.md`, and what
replaces it. `15-charter:01-scope-in-spec` records each under *Made*.

| # | Recorded today | Replaced by | Why | Item |
|---|---|---|---|---|
| D-01 | Principle 1, "layout and interaction, not rendering", and the non-goals: no rasterization, GPU, windows or OS services (SPEC.md §1) | zui owns its windowing, its GPU backends, its drawing and its text; the core stays pure behind the same frame boundary | the owner's direction | `15-charter:01` |
| D-02 | Font loading, shaping and rasterization are non-goals; "commands carry the text and its style, not glyphs"; a glyph's advance may not depend on its neighbours (`roadmap/12-font-system.md`) | zui shapes and rasterizes; a command carries its shaped run and its bytes; measurement is additive at break opportunities only | F-11, F-12 | `12-font-system:01` |
| D-03 | A renderer is one `zuiSubmit` per library | one drawing stage, with a renderer per output family over a GPU contract | F-01 to F-03 | `17-draw:02`, `18-gpu:01` |
| D-04 | Lowering is decided at comptime only (SPEC.md §13.3) | comptime for what a renderer can ever draw, run time for what this device cannot, both listed in `Diagnostics` | F-28 | `17-draw:02`, `18-gpu:01` |
| D-05 | `Surface` is native handles; `library` surfaces and adapter hosts for libraries that own their window | a surface is an id, a size and a present path; adapters go with their libraries; the stepped host stays, with an embedder's target as its surface | F-09 | `19-present:01` |
| D-06 | "One breaking release": the record and the contracts change once, in stages 2 and 3 | a second, planned and landed as one change | F-15 to F-20 | `20-input:01` |
| D-07 | A host holds four windows in fixed slots (the owner's choice, `10-reach:05-many-windows`) | `HostWith(.{ .max_windows })`, the option declined then | popups are surfaces; pay only for what is declared | `21-windowing:01` |
| D-08 | A module imports only its own directory and `zui` (SPEC.md §3.3) | a module may also import the modules beneath it, as a graph the build checks | F-29 | `15-charter:03` |
| D-09 | A service is called only between frames, by a name fixed at comptime (`10-reach:03-services`) | sinks stay, for replay; declaration may record a request in the frame, with an id made at run time | F-30 | `20-input:03` |
| D-10 | Time is one instant, the host's clock when polled (`02-frame-record:04-record-parameters`) | that instant, and the instant the frame is expected on screen | F-07 | `19-present:01` |
| D-11 | Each host paces as it can; Wayland infers a drawn frame from `zuiApply` | a frame clock for each surface, in the host contract | F-07, F-08 | `19-present:01` |
| D-12 | Physical keys: the opaque scancode, an enum only when a binding needs one (SPEC.md §22, open) | a physical key enum beside the logical key, now | F-16; games | `20-input:01` |
| D-13 | The browser runs the tour two ways, a thin client and a host in a worker | the host alone; the client's decoder remains as `zui_wire`'s test | F-26 | `22-web:01` |
| D-14 | The raylib adapter proves the host and renderer contracts | retired, its proof made; "prove each contract twice" stays and is applied to the GPU and present contracts | F-03 | `17-draw:05` |
| D-15 | A rasterizer the test card's hashes do not know is reported and passes; approved images are rebuilt from a commit (`11-polish:41-pixel-hashes`) | the CPU reference's pixels are exact on every machine and are the approved images; a GPU backend is compared with them | F-27 | `17-draw:03`, `17-draw:04` |
| D-16 | The queue continues with stage 11's components | rich text and text editing wait for the text and input contracts; the pixel-hash items are redone on the reference | F-31 | `15-charter:02` |
| D-17 | macOS is set aside until there is hardware | unchanged; the GPU contract is written with Metal's model in view, and CI's macOS runners compile it | F-32 | `18-gpu:01`, `14-macos:05` |
| D-18 | X11 beside Wayland, through xcb | X11 stays, on zui's own wire | F-10 | `21-windowing:05` |

## 7. The work

### 7.1 Order and dependencies

Seven waves, numbered from 0. An item may start when everything it
depends on is done, so items of one wave that do not depend on one
another can be worked in parallel. The map shows the groups; §7.2 gives
each item's own dependencies.

| Wave | What it achieves | Items |
|---|---|---|
| 0. Ground | the documents say where zui is going; standing defects are fixed | `15-charter` 01, 02, 03; `16-defects` 01, 02, 03, 04, 05 |
| 1. The oracle | one drawing stage and an exact CPU reference; sokol_gl and raylib gone; stb_truetype gone | `17-draw` 01, 02, 03, 04, 05; `12-font-system` 02 |
| 2. The GPU | zui's own backends on Windows, Linux and the web; sokol gone; the present contract written | `17-draw` 06; `18-gpu` 01, 02, 03, 04, 05, 08; `19-present` 01, 02 |
| 3. Time | every host keeps time and owns its commit; loss and resize are handled; Vulkan and WebGPU | `18-gpu` 06, 07; `19-present` 03, 04, 05, 06 |
| 4. The second breaking change | the record, the requests and the hosts speak the larger vocabulary; popups, touch and game input | `20-input` 01, 02, 03, 04; `21-windowing` 01, 02, 03, 09 |
| 5. Text | shaped runs, zui's own shaper and atlas, every script; then `11-polish:06-text-editing` and `11-polish:31-rich-text-and-reordering` resume | `12-font-system` 01, 03, 04, 05, 06 |
| 6. The wire and the reach | Linux on zui's own wire; the terminal's cells; the web; accessibility; mobile; audio; Metal | `17-draw` 07; `21-windowing` 04, 05, 06, 07, 08; `22-web` 01, 02, 03, 04; `23-accessibility` 01, 02, 03, 04; `24-mobile` 01, 02; `25-audio` 01; `14-macos` 05 |

```
 any time:  16-defects    12-font-system:02 (zui's own face)    25-audio

 15-charter
     │
     ▼
  17-draw ───────────────┬────────────────────────────────┐
  the stage and          │                                │
  the reference          ▼                                ▼
     │                18-gpu ────────► 22-web        12-font-system
     │                the contract,    24-mobile     runs, the atlas,
     │                the backends     14-macos:05   shaping
     │                   │                                ▲
     │                   ▼                                │
     │              19-present ───► 20-input ─────────────┤
     │              surfaces and    the second            │
     │              the clock       breaking change       ▼
     │                   │              │          11-polish:06, :31
     │                   ▼              ▼
     └───────────► 21-windowing    23-accessibility
                   its own wire, popups,
                   touch, cells
```

Three orderings carry the plan:

- **`17-draw` before `18-gpu`.** The drawing stage decides what a
  backend must do, and the reference decides whether it did it. Written
  the other way round, each backend would be shaped by a renderer about
  to be replaced.
- **`19-present:01` beside `18-gpu:01`.** The swapchain is the one thing
  both contracts describe, so they are written together.
- **`20-input:01` before any host grows.** Popups, touch, gamepads and
  mobile hosts all need the larger vocabulary; adding them first would
  freeze the smaller one.

### 7.2 The list

Check an item when every box in its entry is checked. "After" names what
it depends on, by group and number.

**Wave 0: ground**

- [ ] `15-charter:01-scope-in-spec`
- [ ] `15-charter:02-enter-the-roadmap`, after `15-charter:01`
- [ ] `15-charter:03-module-graph`, after `15-charter:01`
- [ ] `16-defects:01-core-limits`
- [ ] `16-defects:02-windows-host`
- [ ] `16-defects:03-linux-host`
- [ ] `16-defects:04-terminal-host`
- [ ] `16-defects:05-glyph-atlas`

**Wave 1: the oracle**

- [ ] `17-draw:01-primitives-in-spec`, after `15-charter:01`
- [ ] `17-draw:02-scene-builder`, after `17-draw:01`
- [ ] `17-draw:03-cpu-reference`, after `17-draw:02`
- [ ] `17-draw:04-conformance-on-the-reference`, after `17-draw:03`
- [ ] `17-draw:05-renderers-on-zui-draw`, after `17-draw:04`
- [ ] `12-font-system:02-own-face`

**Wave 2: the GPU**

- [ ] `17-draw:06-effects`, after `17-draw:05`, `18-gpu:01`
- [ ] `18-gpu:01-contract`, after `17-draw:02`
- [ ] `18-gpu:02-shaders`, after `18-gpu:01`, `17-draw:03`
- [ ] `18-gpu:03-direct3d`, after `18-gpu:02`, `17-draw:04`
- [ ] `18-gpu:04-opengl`, after `18-gpu:02`, `17-draw:04`
- [ ] `18-gpu:05-webgl2`, after `18-gpu:04`
- [ ] `18-gpu:08-retire-sokol`, after `18-gpu:03`, `18-gpu:04`,
  `18-gpu:05`, `19-present:01`
- [ ] `19-present:01-contract`, after `18-gpu:01`
- [ ] `19-present:02-the-app-loop`, after `19-present:01`

**Wave 3: time**

- [ ] `18-gpu:06-vulkan`, after `18-gpu:03`, `19-present:02`
- [ ] `18-gpu:07-webgpu`, after `18-gpu:05`
- [ ] `19-present:03-hosts-keep-time`, after `19-present:02`,
  `18-gpu:03`, `18-gpu:04`
- [ ] `19-present:04-loss-and-resize`, after `19-present:03`
- [ ] `19-present:05-damage`, after `19-present:03`
- [ ] `19-present:06-units-for-cells`, after `19-present:01`

**Wave 4: the second breaking change**

- [ ] `20-input:01-contract`, after `19-present:01`
- [ ] `20-input:02-core-and-modules-adopt`, after `20-input:01`
- [ ] `20-input:03-requests-in-the-frame`, after `20-input:02`
- [ ] `20-input:04-hosts-adopt`, after `20-input:02`
- [ ] `21-windowing:01-window-operations`, after `20-input:04`
- [ ] `21-windowing:02-popup-surfaces`, after `21-windowing:01`,
  `19-present:03`
- [ ] `21-windowing:03-native-touch-and-pen`, after `20-input:04`
- [ ] `21-windowing:09-games-input`, after `20-input:04`

**Wave 5: text**

- [ ] `12-font-system:01-contract`, after `17-draw:02`, `20-input:01`
- [ ] `12-font-system:03-runs-and-atlas`, after `12-font-system:01`,
  `12-font-system:02`, `17-draw:05`
- [ ] `12-font-system:04-shaping`, after `12-font-system:03`
- [ ] `12-font-system:05-bidirectional-and-complex`, after
  `12-font-system:04`
- [ ] `12-font-system:06-fallback-and-system-fonts`, after
  `12-font-system:03`

**Wave 6: the wire and the reach**

- [ ] `17-draw:07-vocabulary`, after `17-draw:06`, `18-gpu:08`
- [ ] `21-windowing:04-wayland-on-its-own-wire`, after `17-draw:03`,
  `19-present:03`, `18-gpu:06`
- [ ] `21-windowing:05-x11-on-its-own-wire`, after `21-windowing:04`
- [ ] `21-windowing:06-link-nothing`, after `21-windowing:05`,
  `18-gpu:04`, `18-gpu:06`
- [ ] `21-windowing:07-terminal-cells`, after `19-present:06`,
  `12-font-system:04`, `16-defects:04`
- [ ] `21-windowing:08-data-transfer`, after `20-input:03`
- [ ] `22-web:01-one-way-to-run`, after `18-gpu:05`, `20-input:04`
- [ ] `22-web:02-single-threaded`, after `22-web:01`
- [ ] `22-web:03-text-and-keys`, after `22-web:01`
- [ ] `22-web:04-location-and-documents`, after `22-web:01`,
  `23-accessibility:03`
- [ ] `23-accessibility:01-semantics`, after `20-input:02`
- [ ] `23-accessibility:02-linux`, after `23-accessibility:01`
- [ ] `23-accessibility:03-web`, after `23-accessibility:01`,
  `22-web:01`
- [ ] `23-accessibility:04-windows`, after `23-accessibility:01`
- [ ] `24-mobile:01-android`, after `18-gpu:06`, `19-present:04`,
  `21-windowing:03`
- [ ] `24-mobile:02-ios`, after `14-macos:05`, `21-windowing:03`
- [ ] `25-audio:01-audio`, after `15-charter:01`
- [ ] `14-macos:05-metal`, after `18-gpu:02`, `14-macos:01`

### 7.3 `15-charter` — Scope and documents

The documents are changed before the code, because SPEC.md is the
contract and today it rules this work out.

#### `15-charter:01-scope-in-spec` — The new scope, in the spec

- **Goal.** SPEC.md and ARCHITECTURE.md state that zui owns its
  windowing, its GPU backends, its drawing and its text, and name the
  layers of §3.2.
- **Grounding.** F-01, F-32; D-01 to D-18.
- **Strategy.** Rewrite SPEC.md's principle 1 and the non-goals' rows
  for rendering, windows and fonts, keeping the rule that the core
  produces data and draws nothing. Add the GPU and draw layers to §3.1
  and the new packages to §3.2. Add the stages of this plan to §21.
  Record every row of §6 in `roadmap/decisions.md`. The contracts
  themselves are written by the first item of each group, not here.
- **Depends on.** nothing
- **Done when.**
  - [ ] SPEC.md §1, the non-goals, §3 and §21 state the scope, the
    layers and the stages of this report
  - [ ] ARCHITECTURE.md §1, §4, §6 and §8 map them, and §7 lists each
    difference the new spec opens, with its item
  - [ ] `roadmap/decisions.md` records D-01 to D-18 under *Made*, and
    SPEC.md §22's physical-keys question is closed
  - [ ] README.md's status and its packages table agree

#### `15-charter:02-enter-the-roadmap` — This plan, in the roadmap

- **Goal.** The groups and items of §7 are the roadmap's, and the queue
  is in wave order.
- **Grounding.** F-25, F-31; D-16.
- **Strategy.** One file in `roadmap/` for each new group, each item
  entered with its Grounding, Plan and Done when from this report. Order
  ROADMAP.md's queue by §7.1. Hold
  `11-polish:31-rich-text-and-reordering` and
  `11-polish:06-text-editing` for the contracts they wait on, and redo
  `11-polish:41-pixel-hashes`, `:43` and `:44` on the CPU reference
  (§8). Give every "not yet queued" row of ARCHITECTURE.md §7 an item or
  a reason.
- **Depends on.** `15-charter:01-scope-in-spec`
- **Done when.**
  - [ ] each group of §7 has its file, and ROADMAP.md's table of files
    lists it
  - [ ] the queue's first open row is the first open item of wave 0
  - [ ] each held row names the item it waits on
  - [ ] ARCHITECTURE.md §7 has no row marked "not yet queued"
  - [ ] CLAUDE.md's "Where things go" has a row for each new kind of
    change

#### `15-charter:03-module-graph` — Modules that may build on modules

- **Goal.** A module may import the modules beneath it, so vocabulary
  stops moving into the core for want of a place to share it.
- **Grounding.** F-29; D-08.
- **Strategy.** Declare each module's allowed imports in
  `core/build.zig` as a graph with no cycles, and let the compiler keep
  it as it keeps today's boundary. Amend SPEC.md §3.3. Then undo what
  the old rule forced, each where the counts allow.
- **Depends on.** `15-charter:01-scope-in-spec`
- **Done when.**
  - [ ] an import outside a module's declared graph fails the build,
    pinned by a test
  - [ ] `zui_design` takes its color math from `zui_color`
  - [ ] `zui_widgets_data` names the `Widgets` type it draws through
  - [ ] motion, the design vocabulary and the icon names are each moved
    out of the core, or their staying is recorded with its instruction
    counts

### 7.4 `16-defects` — Standing defects

Wrong today whatever else is decided. None depends on anything, and each
is small enough for one sitting.

#### `16-defects:01-core-limits` — The limits the core does not yet keep

- **Goal.** Every limit keeps what fits and never corrupts, as SPEC.md
  §17.2 says.
- **Grounding.** F-25.
- **Strategy.** Keep room in the command buffer for the clip ends still
  open. Arbitrate a declined pointer for zoom as it is for a pan.
- **Depends on.** nothing
- **Done when.**
  - [ ] a frame past `max_render_commands` sweeps clean, and the tour's
    Break It no longer caps its load
  - [ ] a pinch that starts on an element with a custom recognizer zooms
    once the recognizer declines
  - [ ] both rows leave ARCHITECTURE.md §7

#### `16-defects:02-windows-host` — The Windows host

- **Goal.** No event is stranded, lost or doubled, and the host reports
  every setting the OS has.
- **Grounding.** F-19, F-22.
- **Strategy.** Give input arrival a meaning that survives polling one
  window at a time. Follow capture as the OS moves it. Coalesce moves in
  the inbox and never drop a release. Handle system-key characters and
  the end of a session in order. Report text scale, locale and reading
  direction.
- **Depends on.** nothing
- **Done when.**
  - [ ] the host suite posts an event to one window between the polls of
    two, and the next wait ends
  - [ ] a release lost to another window arrives as `pointer_cancel`,
    and the next press captures
  - [ ] a flood of moves past the inbox's size keeps every press and
    release
  - [ ] `text_scale`, `locale` and `direction` arrive in the environment
    and follow a change

#### `16-defects:03-linux-host` — The Linux host

- **Goal.** A window is usable on every compositor the host connects to.
- **Grounding.** F-23.
- **Strategy.** Where the compositor decorates nothing, give a
  native-title-bar window a title bar of the host's or the application's
  drawing through the chrome regions that exist. Show a cursor without
  the cursor-shape protocol. End a window on a protocol error. Convert
  wheel deltas as positions are. Keep presses and releases as
  `16-defects:02` does.
- **Depends on.** nothing
- **Done when.**
  - [ ] a `.native` window on a compositor without xdg-decoration can be
    moved, resized and closed, checked on one that behaves so
  - [ ] the pointer shows a cursor on a compositor without
    cursor-shape-v1
  - [ ] a protocol error closes the window and does not spin
  - [ ] the wheel scrolls the same distance at any zoom

#### `16-defects:04-terminal-host` — The terminal host

- **Goal.** The terminal is left as it was found however the process
  ends, and its keys are the application's.
- **Grounding.** F-24.
- **Strategy.** Restore the terminal from a signal handler and a panic
  hook. Deliver a resize through the wake the host already has. Report
  Ctrl+C as a key and a terminate request, and let the application
  decide. Bracket paste. Filter C1 controls. Decode every mouse button.
- **Depends on.** nothing
- **Done when.**
  - [ ] after `SIGTERM`, `SIGHUP` or a panic the terminal echoes, wraps
    and shows its cursor, checked under `script`
  - [ ] an idle terminal application makes no periodic wake, and a
    resize redraws at once
  - [ ] an application receives Ctrl+C and Ctrl+Q as keys
  - [ ] pasted text arrives as text, newlines included

#### `16-defects:05-glyph-atlas` — The glyph atlas, until it is replaced

- **Goal.** One glyph that cannot be placed costs only itself.
- **Grounding.** F-04, F-13.
- **Strategy.** Skip and count a glyph too large for the atlas. Stop
  wiping the atlas when the retry cannot succeed. Make a failed atlas an
  error at `init`. `12-font-system:03` replaces the atlas; this is the
  fix until then.
- **Depends on.** nothing
- **Done when.**
  - [ ] a frame with one oversize glyph draws every other glyph and
    rasterizes nothing again in the next frame
  - [ ] a frame needing more glyphs than fit reports it once and keeps
    what fit
  - [ ] a renderer whose atlas cannot be made fails at `init`

### 7.5 `17-draw` — The drawing stage and the reference

One place turns a frame's commands into what an output executes, and a
CPU renderer says what the right pixels are. Nothing here needs a
platform.

#### `17-draw:01-primitives-in-spec` — The primitives and their mathematics, in the spec

- **Goal.** SPEC.md defines the primitive a GPU or the CPU executes, and
  the coverage of every shape as a function of a point, so that
  "correct" has a definition.
- **Grounding.** F-02, F-05.
- **Strategy.** One small record for each kind: a rectangle with its
  radii, shape, border, fill and clip; a glyph; an image; a shadow.
  Coverage is computed from the shape at each pixel, so edges are smooth
  without multisampling and nothing is tessellated. Batches and layers
  say what is drawn together and in what order. One blending model
  serves SDR and HDR.
- **Depends on.** `15-charter:01-scope-in-spec`
- **Done when.**
  - [ ] SPEC.md has the primitive format, the batch and layer rules, and
    each shape's coverage: round, continuous and chamfered corners,
    borders, shadows, gradients, images
  - [ ] the one blending model is stated, with what changes on screen
    from today
  - [ ] budgets for building a frame's primitives are set in SPEC.md
    §20.2
- **To settle.** Blending in the target's encoding or in linear light;
  default: one model that matches today's SDR appearance, measured
  against the tour. Whether a clip is carried by each primitive or by
  its batch; default: by the primitive, so a clip never ends a batch.

#### `17-draw:02-scene-builder` — The scene builder

- **Goal.** `zui_draw` turns any frame's commands into primitives and
  batches, in pure Zig, for every output that draws pixels.
- **Grounding.** F-01 to F-04, F-28; D-03, D-04.
- **Strategy.** Start from `renderers/webgl/src/draw_list.zig`, which is
  already free of any backend, and change what it emits from triangles
  to primitives. It keeps the generated command union and its exhaustive
  `switch`, so it is the one consumer of commands for pixels. Its memory
  is fixed at `init`; a shape that does not fit is left out whole and
  counted. It takes what the device cannot do as a value at run time,
  lowers for it, and reports each lowering.
- **Depends on.** `17-draw:01-primitives-in-spec`
- **Done when.**
  - [ ] `zui_draw` builds for `wasm32-freestanding` and every target the
    core does, and allocates nothing after `init`
  - [ ] every command the core can emit becomes primitives, checked on
    the test card and every screen of the tour
  - [ ] an overflow and a run-time lowering each appear in the frame's
    diagnostics by name
  - [ ] a benchmark scenario and instruction counts for building a
    frame's primitives are in CI, within the budgets `17-draw:01` set

#### `17-draw:03-cpu-reference` — The CPU reference renderer

- **Goal.** A renderer in Zig that executes the primitives into pixels,
  exactly the same on every machine.
- **Grounding.** F-27; D-15.
- **Strategy.** Evaluate `17-draw:01`'s coverage directly, in SDR and in
  half floats. It is the renderer for `offscreen` surfaces, for tests,
  and later for a window when no GPU starts. It is written for exactness
  first; its speed is measured and improved only where a target depends
  on it.
- **Depends on.** `17-draw:02-scene-builder`
- **Done when.**
  - [ ] it passes the renderer conformance suite
  - [ ] its pixels are identical in every optimize mode and on x86-64,
    aarch64, 32-bit x86 and `wasm32`, checked in CI
  - [ ] the test card's scenes have committed pixel snapshots from it,
    compared exactly
  - [ ] its time for the tour's frames is recorded

#### `17-draw:04-conformance-on-the-reference` — Conformance against the reference

- **Goal.** The renderer suite says how far a backend's pixels are from
  the reference's, closely enough to hold quality.
- **Grounding.** F-27.
- **Strategy.** A backend draws the suite's scenes and the reference
  draws them too; the suite compares them at several scales, fractional
  ones included, with text compared as drawn and not by its presence.
  The tolerance is small and stated for each kind of primitive. The
  web's pixel check takes the reference in place of sokol on the
  machine's rasterizer.
- **Depends on.** `17-draw:03-cpu-reference`
- **Done when.**
  - [ ] the suite compares with the reference at scales of 1, 1.25, 1.5
    and 2
  - [ ] a mutation of each primitive's drawing fails it
  - [ ] `test-draw` compares with the reference, and the llvmpipe
    allowance is gone
  - [ ] `11-polish:41-pixel-hashes` is rewritten on it or retired

#### `17-draw:05-renderers-on-zui-draw` — The renderers on the drawing stage

- **Goal.** Every pixel on every target comes through `zui_draw`; the
  copies, sokol_gl and raylib are gone.
- **Grounding.** F-02, F-03; D-14.
- **Strategy.** A bridge, not the destination. The sokol renderer draws
  the primitives through sokol_gfx alone, and the page's drawer draws
  the same primitives through WebGL 2. The raylib renderer and its
  adapter host are removed with their package, CI legs and documents.
  Every target keeps running.
- **Depends on.** `17-draw:04-conformance-on-the-reference`
- **Done when.**
  - [ ] no file calls sokol_gl, and `renderers/raylib/` is gone
  - [ ] one outline, one gradient, one shadow and one set of blur taps
    exist in the repository
  - [ ] the tour and the test card run on Windows, Wayland, X11 and the
    web, and pass `17-draw:04`'s suite
  - [ ] bytes uploaded and draw calls for the tour's frames are measured
    before and after

#### `17-draw:06-effects` — Effects on the new pipeline

- **Goal.** Blur, shadow, gradient and materials cost what they should
  and look the same in SDR and HDR.
- **Grounding.** F-05.
- **Strategy.** A shadow is evaluated in closed form, not drawn as
  rings. A backdrop blur works on a reduced copy of what lies beneath
  it, in a few passes. A gradient is evaluated at each pixel. A material
  is a shader the application supplies through the GPU contract, with
  the same clip and coverage as any shape.
- **Depends on.** `17-draw:05-renderers-on-zui-draw`,
  `18-gpu:01-contract`
- **Done when.**
  - [ ] each effect matches the reference within `17-draw:04`'s
    tolerance on every backend
  - [ ] a blur's cost no longer grows with the square of its radius,
    shown by measurement
  - [ ] one frame looks the same on an SDR and an HDR target, but for
    its brightness above SDR white

#### `17-draw:07-vocabulary` — A larger vocabulary

- **Goal.** The commands can express what the components' approved
  designs draw.
- **Grounding.** F-06.
- **Strategy.** Each addition is an optional command or field with its
  lowering, so no renderer breaks: opacity and blending for a group;
  clips with rounded corners and under rotation; gradients with more
  stops and radial ones; a source rectangle and a fit for images; filled
  and stroked paths, which the text rasterizer also fills, so an icon
  need not be a font glyph.
- **Depends on.** `17-draw:06-effects`, `18-gpu:08-retire-sokol`
- **Done when.**
  - [ ] each addition is in SPEC.md §13 with its lowering, and drawn by
    the reference and every backend
  - [ ] an overlay fades in, and the rows of ARCHITECTURE.md §7 that
    wait on opacity are closed
  - [ ] an icon is drawn from a path with no icon font loaded

### 7.6 `18-gpu` — The GPU contract and zui's own backends

The contract is only as wide as the drawing stage needs. Each backend is
small because the stage has already done the work.

#### `18-gpu:01-contract` — The GPU contract

- **Goal.** `zui_gpu`: what a backend provides, checked at comptime,
  with nothing a general-purpose graphics library would add.
- **Grounding.** F-01, F-04, F-28, F-32; D-03, D-04, D-17.
- **Strategy.** A device; a swapchain for each surface; buffers;
  textures that update in part and can be drawn into; a fixed list of
  pipelines made at `init`; passes; scissor; read-back, which
  conformance needs; a report of what this device can do; a signal that
  the device was lost. A renderer names a set of backends at comptime,
  only those compile, and the first that starts at run time is used.
  Images and materials become zui's handles. The contract is written
  with Metal's and WebGPU's models beside Direct3D's and Vulkan's, so
  none has to be bent to fit later.
- **Depends on.** `17-draw:02-scene-builder`
- **Done when.**
  - [ ] the contract is in SPEC.md §16, with `zui.checkGpu`, exact
    messages and a compile-error case for each
  - [ ] a recording backend passes a conformance suite for the contract,
    with no GPU
  - [ ] a renderer built with two backends starts the second when the
    first fails, shown by a test
  - [ ] an application makes an image and a material without naming any
    backend's types
- **To settle.** Direct3D 11 or 12 as the Windows backend; default: 12,
  with today's Direct3D 11 code as the bridge until it passes.

#### `18-gpu:02-shaders` — The shaders

- **Goal.** One small set of shaders, in every language a backend needs,
  known to agree.
- **Grounding.** F-05.
- **Strategy.** The set is fixed by `17-draw:01`: the primitives, the
  blur's passes, the material hook, the present. Each language's version
  is checked against the reference's pixels, so agreement is tested, not
  assumed. Nothing is compiled while frames are drawn.
- **Depends on.** `18-gpu:01-contract`, `17-draw:03-cpu-reference`
- **Done when.**
  - [ ] every shader exists for HLSL, GLSL and GLSL ES, SPIR-V, WGSL and
    Metal's language
  - [ ] each is checked against the reference by the backend that uses
    it, and the ones with no backend yet are at least compiled in CI
  - [ ] sokol-shdc and its generated files are gone
- **To settle.** How each language is produced; default: written by hand
  from the spec's mathematics, since the set is small. Alternatives to
  weigh: generating them from one description at comptime, and Zig's own
  SPIR-V backend.

#### `18-gpu:03-direct3d` — Direct3D

- **Goal.** Windows draws through zui's own backend.
- **Grounding.** F-01, F-04.
- **Strategy.** Port `renderers/sokol/src/composition.c` into Zig as the
  backend's swapchain: composition with alpha for system materials, and
  scRGB for HDR. Handle a failed resize and a removed device as the
  contract says.
- **Depends on.** `18-gpu:02-shaders`,
  `17-draw:04-conformance-on-the-reference`
- **Done when.**
  - [ ] the backend passes `17-draw:04`'s suite, in SDR and in scRGB
  - [ ] the tour and the test card run on the Windows host with no sokol
    in the build
  - [ ] `composition.c` is gone, and the repository's only C is what
    `12-font-system:02` removes

#### `18-gpu:04-opengl` — OpenGL and OpenGL ES

- **Goal.** The floor: a backend that runs wherever a GPU does.
- **Grounding.** F-05, F-10.
- **Strategy.** OpenGL 3.3 and OpenGL ES 3, through EGL loaded at run
  time. It is what Linux uses until Vulkan passes, and what a machine
  falls back to when Vulkan does not start.
- **Depends on.** `18-gpu:02-shaders`,
  `17-draw:04-conformance-on-the-reference`
- **Done when.**
  - [ ] the backend passes `17-draw:04`'s suite on Wayland and X11
  - [ ] it starts on OpenGL 3.3 and on OpenGL ES 3, each checked
  - [ ] a machine without EGL starts the CPU renderer and says so

#### `18-gpu:05-webgl2` — WebGL 2

- **Goal.** The page executes the same primitives with the same shaders
  as OpenGL ES.
- **Grounding.** F-03, F-26.
- **Strategy.** The page's JavaScript becomes a thin executor of
  batches. The layout of every record it reads is generated from Zig,
  not copied by hand. It draws images.
- **Depends on.** `18-gpu:04-opengl`
- **Done when.**
  - [ ] the page's drawer passes `17-draw:04`'s suite in a browser
  - [ ] no constant is written twice, in Zig and in JavaScript
  - [ ] an image declared in a frame is drawn on the page

#### `18-gpu:06-vulkan` — Vulkan

- **Goal.** The first choice on Linux and Android, and a choice on
  Windows.
- **Grounding.** F-10.
- **Strategy.** Loaded at run time. Its swapchain is the window system's
  where zui still uses one, and images zui allocates and hands to the
  host once `21-windowing:04` lands.
- **Depends on.** `18-gpu:03-direct3d`, `19-present:02-the-app-loop`
- **Done when.**
  - [ ] the backend passes `17-draw:04`'s suite on Linux and Windows
  - [ ] with Vulkan made to fail, the same binary starts OpenGL, and
    with both, the CPU renderer
  - [ ] a lost device is recovered through `19-present:04`

#### `18-gpu:07-webgpu` — WebGPU

- **Goal.** The page uses WebGPU where the browser has it.
- **Grounding.** F-26.
- **Strategy.** A second executor on the page, chosen at run time, with
  WebGL 2 as its fallback.
- **Depends on.** `18-gpu:05-webgl2`
- **Done when.**
  - [ ] the page passes `17-draw:04`'s suite through WebGPU
  - [ ] a browser without WebGPU draws through WebGL 2 with no change to
    the application

#### `18-gpu:08-retire-sokol` — sokol, retired

- **Goal.** No sokol anywhere in the repository.
- **Grounding.** F-01, F-09; D-05.
- **Strategy.** Remove `renderers/sokol/`, its dependency, its CI legs
  and its documents, and the `library` surface with the last harness
  that used it. Look again at the Linux link workaround, LLVM and LLD
  for the system's `crt1.o`, in each package that carried it for sokol.
- **Depends on.** `18-gpu:03-direct3d`, `18-gpu:04-opengl`,
  `18-gpu:05-webgl2`, `19-present:01-contract`
- **Done when.**
  - [ ] `renderers/sokol/` and every mention of sokol in a
    `build.zig.zon` are gone
  - [ ] `zui.Surface` has no `library`
  - [ ] an empty-cache build of every package fetches nothing of sokol's
  - [ ] README.md, ARCHITECTURE.md §8 and `docs/development.md` describe
    the renderers that exist

### 7.7 `19-present` — Surfaces, presentation and time

Who shows a frame, when, and what happens when the surface changes under
it.

#### `19-present:01-contract` — The present contract

- **Goal.** SPEC.md says what a surface is, who commits a frame to it,
  and how a frame is timed.
- **Grounding.** F-07, F-08, F-09; D-05, D-10, D-11.
- **Strategy.** A surface is a window's id, its size in pixels, its
  scale, its format and a present path: a handle for the GPU's own
  window integration, buffers the host presents, cells, the wire, or an
  embedder's target. Each surface has a frame clock: the host says when
  a frame was shown and when the next one can be, the record carries the
  instant its frame is expected on screen, and `NextFrame` gains "at the
  next display frame". A redraw request is an event. A resize is
  acknowledged by the frame drawn for it. The swapchain half is written
  with `18-gpu:01`.
- **Depends on.** `18-gpu:01-contract`
- **Done when.**
  - [ ] SPEC.md §6.2, §6.6 and §16.3 to §16.4 state the surface, the
    frame clock, the predicted instant, redraw and resize
  - [ ] `checkHost` and `checkHostAndRenderer` check present paths, with
    their messages and compile-error cases
  - [ ] the host suites have checks for pacing, written to fail on
    today's hosts
- **To settle.** Whether motion reads the predicted instant in place of
  `now` or beside it; default: animation reads the predicted instant,
  timers and gestures keep `now`.

#### `19-present:02-the-app-loop` — The application loop

- **Goal.** `zui_app` runs frames by the clock, per surface, and
  survives what a renderer reports.
- **Grounding.** F-08, F-28.
- **Strategy.** A step asks each surface's clock whether a frame is due.
  The host is told a frame was shown when it was, not before it is
  submitted. A renderer is started with an allocator, an `Io` and its
  preferences, is told which window it draws, and can start before any
  surface exists. Waits on a render thread are bounded. A renderer's
  error suspends its surfaces and is retried; it does not end the run.
- **Depends on.** `19-present:01-contract`
- **Done when.**
  - [ ] `zui_app`'s tests cover a frame clock for each window, on a
    scripted host
  - [ ] with a render thread, the host learns of a frame after it is
    presented
  - [ ] a renderer that fails a frame is restarted and the application
    lives on
  - [ ] no wait on the render thread is unbounded

#### `19-present:03-hosts-keep-time` — Every host keeps time

- **Goal.** Each host implements the frame clock with the best its
  platform has, and owns its commit.
- **Grounding.** F-07, F-08.
- **Strategy.** Windows from the compositor's own clock or a waitable
  swapchain; Wayland from frame callbacks and presentation feedback, for
  each surface; X11 from the Present extension; the web from the
  animation frame's timestamp; the terminal at a fixed rate inside
  synchronized output.
- **Depends on.** `19-present:02-the-app-loop`, `18-gpu:03-direct3d`,
  `18-gpu:04-opengl`
- **Done when.**
  - [ ] every host passes the pacing checks of `19-present:01`
  - [ ] an animation draws one frame for each display refresh and no
    more, on each host
  - [ ] two windows on displays of different rates each run at their own
  - [ ] a hidden or covered window draws nothing, and an idle
    application still uses no CPU
  - [ ] the jitter of an animation's frames is measured on each host,
    before and after

#### `19-present:04-loss-and-resize` — Loss and resize

- **Goal.** A lost device, a lost surface and a resize are ordinary
  events.
- **Grounding.** F-04, F-08.
- **Strategy.** A lost device takes the path a suspended surface already
  has, on every host and not only a pushed one. A resize shows no frame
  of the wrong size: the host and the swapchain agree on the size a
  frame was drawn for.
- **Depends on.** `19-present:03-hosts-keep-time`
- **Done when.**
  - [ ] a device removed under a running application is recovered with
    its state intact, on each backend that can simulate it
  - [ ] a window dragged by its edge shows no stretched or cut frame, on
    each host
  - [ ] the conformance suites cover both

#### `19-present:05-damage` — Damage

- **Goal.** A frame that changes little draws and presents little.
- **Grounding.** F-08.
- **Strategy.** The drawing stage compares a frame's layers with the
  last one's and gives the region that changed; a backend redraws and
  presents that region where its swapchain allows.
- **Depends on.** `19-present:03-hosts-keep-time`
- **Done when.**
  - [ ] a blinking caret redraws its own rectangle, shown by a count of
    pixels drawn
  - [ ] an unchanged frame is not presented again
  - [ ] the cost of finding the damage is within a budget set here

#### `19-present:06-units-for-cells` — Units a terminal can snap to

- **Goal.** The core snaps to whatever a surface can address, a pixel or
  a cell.
- **Grounding.** F-21.
- **Strategy.** The record's scale becomes one for each axis, so a
  terminal's surface declares its cell as the step. Emission then snaps
  to cells as it snaps to pixels, and its rule that a line is at least
  one step wide gives a divider one cell. The cell size has one source.
- **Depends on.** `19-present:01-contract`
- **Done when.**
  - [ ] a one-unit divider and a thin scrollbar show in the terminal's
    test card
  - [ ] the terminal package holds no mapping of its own from units to
    cells
  - [ ] the box tree's instruction counts do not grow past CI's gate

### 7.8 `20-input` — The second breaking change

Everything that changes the record, the events, the requests and the
wire, designed once and landed together.

#### `20-input:01-contract` — The larger vocabulary, in the spec

- **Goal.** SPEC.md §7 and §13 describe every input a host can report
  and everything a frame can ask of a host, for desktop, web, mobile and
  games.
- **Grounding.** F-15, F-16, F-18, F-19, F-20; D-06, D-12.
- **Strategy.** One design, reviewed whole. Events: modifiers and every
  button on a pointer; the wheel's unit, phase and modifiers;
  composition; a text-input session in which the application publishes
  the text around the caret and what the field is for, and the host
  sends edits; a physical key beside the logical one; gamepads; redraw;
  foreground and background. Environment: insets, what the on-screen
  keyboard covers, how the user points. Requests: window operations,
  popup surfaces, pointer lock, the text-input session. Semantics: the
  roles, text and live regions `23-accessibility` needs, sent as
  changes. The wire's version changes once.
- **Depends on.** `19-present:01-contract`
- **Done when.**
  - [ ] SPEC.md states every event, environment field, request and
    semantic node, each with the platform facility it maps to on
    Windows, Wayland, X11, the web, Android and iOS
  - [ ] nothing in the design needs a later change to the record's shape
    for mobile or games
  - [ ] the notes say what an application and a host change to move to
    it

#### `20-input:02-core-and-modules-adopt` — The core, the modules and the wire adopt it

- **Goal.** The engine applies and answers the new record; the modules
  use it.
- **Grounding.** F-15, F-16.
- **Strategy.** The core applies the new events and emits the new
  requests. `zui_wire` encodes them, `zui_testing`'s driver makes them,
  and the widgets use what was missing: a click with a modifier, text
  shown while it is composed, a text field's session.
- **Depends on.** `20-input:01-contract`
- **Done when.**
  - [ ] every suite passes on the new record, and a recorded session
    replays to the same commands
  - [ ] a table adds to its selection with a modified click, and selects
    a range
  - [ ] a text field draws the text being composed
  - [ ] the instruction counts of a frame without the new events do not
    grow past CI's gate

#### `20-input:03-requests-in-the-frame` — Requests declaration can make

- **Goal.** Declaration can ask for a service without doing work, and
  tell two requests apart.
- **Grounding.** F-30; D-09.
- **Strategy.** A request recorded in the frame, as demand already is,
  which the host carries out after the frame. Its id is made at run
  time. Its answer still arrives through a sink, so a replay sees the
  answer and repeats no work.
- **Depends on.** `20-input:02-core-and-modules-adopt`
- **Done when.**
  - [ ] a button copies text and opens a link from declaration, with no
    loader
  - [ ] two requests of one kind in flight get their own answers
  - [ ] a replayed session carries out no request
  - [ ] an answer a full sink refuses is reported

#### `20-input:04-hosts-adopt` — The hosts report it

- **Goal.** Each existing host sends everything of the new vocabulary
  its platform already gives it.
- **Grounding.** F-15, F-16, F-19.
- **Strategy.** Modifiers, buttons, the wheel's unit and phase, physical
  keys, composition and the text-input session, on Windows, Wayland,
  X11, the web and the terminal. What needs a new protocol or device,
  touch and gamepads, is `21-windowing`'s.
- **Depends on.** `20-input:02-core-and-modules-adopt`
- **Done when.**
  - [ ] each host's conformance checks every event it can report
  - [ ] text composed in an IME is shown at the caret on Windows,
    Wayland, X11 and the web
  - [ ] `11-polish:06-text-editing` can resume

### 7.9 `21-windowing` — Windowing, complete and zui's own

What a window system offers that zui does not yet use, and then the wire
itself.

#### `21-windowing:01-window-operations` — Window operations

- **Goal.** An application changes its windows after they open, and a
  host holds as many as were declared.
- **Grounding.** F-18, F-28; D-07.
- **Strategy.** Title, size and its limits, fullscreen, minimize,
  maximize, the icon and the application's id, as requests. A host's
  window count is a comptime parameter.
- **Depends on.** `20-input:04-hosts-adopt`
- **Done when.**
  - [ ] each operation works on Windows, Wayland and X11, and answers
    "unavailable" where a platform has none
  - [ ] a host built for one window holds no storage for more

#### `21-windowing:02-popup-surfaces` — Popup surfaces

- **Goal.** A menu, a tooltip or a dropdown can leave its window.
- **Grounding.** F-18.
- **Strategy.** A floating element anchored to another already describes
  a popup. Where the host can, it becomes a surface of its own, anchored
  by the same rules the window system uses; where it cannot, as in a
  browser or a terminal, it stays a layer in the window. The
  application's code is the same either way.
- **Depends on.** `21-windowing:01-window-operations`,
  `19-present:03-hosts-keep-time`
- **Done when.**
  - [ ] a menu at a window's edge extends past it on Windows, Wayland
    and X11
  - [ ] the same menu is drawn inside the surface on the web and the
    terminal
  - [ ] focus, dismissal and semantics behave the same in both

#### `21-windowing:03-native-touch-and-pen` — Touch and pen on native hosts

- **Goal.** The gestures built in stage 7 can be reached on Windows and
  Linux.
- **Grounding.** F-17.
- **Strategy.** Pointer messages on Windows; the seat's touch and the
  tablet protocol on Wayland; the input extension on X11. Each reports
  contacts as the web host already does.
- **Depends on.** `20-input:04-hosts-adopt`
- **Done when.**
  - [ ] a pan, a pinch and a long press work on a touch screen on
    Windows and on Wayland
  - [ ] a pen reports pressure and tilt
  - [ ] the host suite injects contacts on each

#### `21-windowing:04-wayland-on-its-own-wire` — Wayland on zui's own wire

- **Goal.** The Wayland host speaks the protocol itself and presents its
  own buffers.
- **Grounding.** F-08, F-09, F-10.
- **Strategy.** A wire client as the D-Bus one is: the socket,
  descriptors passed with messages, objects by id, and marshalling made
  at comptime from the signature tables that are already written.
  Presentation is the host's: shared memory for the CPU renderer first,
  which proves the client with no GPU, then buffers the GPU backend
  allocates and shares with the compositor. The host then owns commit,
  scale and the frame callback in one place.
- **Depends on.** `17-draw:03-cpu-reference`,
  `19-present:03-hosts-keep-time`, `18-gpu:06-vulkan`
- **Done when.**
  - [ ] the host passes its conformance suite with no libwayland-client
    and no wayland-egl in the build
  - [ ] the tour runs on the CPU renderer through shared memory, and on
    the GPU through shared buffers
  - [ ] nothing is allocated for a frame, inside or outside Zig
  - [ ] pacing still passes `19-present:03`'s checks
- **To settle.** How the GPU's buffers are allocated and shared;
  default: by the Vulkan backend, with OpenGL presenting through shared
  memory until its own path is written.

#### `21-windowing:05-x11-on-its-own-wire` — X11 on zui's own wire

- **Goal.** The X11 host speaks the protocol itself.
- **Grounding.** F-10; D-18.
- **Strategy.** The same shape as `21-windowing:04`: connection and
  authorization, requests and replies without a blocking round trip on
  the UI thread, and presentation through the shared-memory and Present
  extensions.
- **Depends on.** `21-windowing:04-wayland-on-its-own-wire`
- **Done when.**
  - [ ] the host passes its conformance suite with no xcb and no Xlib in
    the build
  - [ ] no request blocks the UI thread waiting for its reply
  - [ ] the duplicated window bookkeeping of the two Linux hosts is one

#### `21-windowing:06-link-nothing` — Nothing linked but the system's loader

- **Goal.** A Linux build of zui links libc and nothing else, and finds
  the rest when it runs.
- **Grounding.** F-10.
- **Strategy.** xkbcommon, EGL and Vulkan are loaded at run time, each
  with what happens when it is absent: a built-in keymap, the next
  backend, the CPU renderer.
- **Depends on.** `21-windowing:05-x11-on-its-own-wire`,
  `18-gpu:04-opengl`, `18-gpu:06-vulkan`
- **Done when.**
  - [ ] `hosts/native/build.zig` names no system library but libc on
    Linux
  - [ ] the Linux host and its targets cross-compile from Windows with
    no sysroot
  - [ ] on a machine with none of the three libraries, a window opens
    and types
  - [ ] the Linux link workaround is removed, or its remaining cause
    recorded
- **To settle.** Writing zui's own keymap compiler; default: not yet,
  since xkbcommon is the system's as a driver is.

#### `21-windowing:07-terminal-cells` — The terminal's cells

- **Goal.** A terminal draws text of any script in the right columns,
  with the attributes and colors it has.
- **Grounding.** F-21.
- **Strategy.** A cell holds a grapheme cluster, its width, its
  attributes and a link. The host learns what the terminal can do by
  asking it, and colors are lowered to what it has. Partial blocks draw
  what is thinner than a cell. The decoder reads the fuller keyboard and
  mouse protocols where they are offered.
- **Depends on.** `19-present:06-units-for-cells`,
  `12-font-system:04-shaping`, `16-defects:04-terminal-host`
- **Done when.**
  - [ ] a row with wide characters, emoji and combining marks stays
    aligned, in the snapshots
  - [ ] the tour is legible in 16 colors, in 256 and in true color
  - [ ] bold, italic, underline and a link are drawn where a style asks
  - [ ] a key's release and its full modifiers arrive on a terminal that
    reports them

#### `21-windowing:08-data-transfer` — Data in and out

- **Goal.** The clipboard and drags carry more than text, in both
  directions, and files arrive as what the platform grants.
- **Grounding.** F-19.
- **Strategy.** Formats beyond text on the clipboard; a drag that leaves
  the window; a file as a grant the host gives, which is a path on a
  desktop and a handle in a sandbox.
- **Depends on.** `20-input:03-requests-in-the-frame`
- **Done when.**
  - [ ] an image is copied and pasted between a zui application and
    another, on Windows, Wayland and X11
  - [ ] a drag begun in a zui window drops into another application
  - [ ] the same code opens a chosen file on a desktop and in a browser

#### `21-windowing:09-games-input` — Input for games

- **Goal.** A game reads devices as devices.
- **Grounding.** F-16.
- **Strategy.** Gamepads as events, with rumble as a request; pointer
  lock, relative motion and a hidden cursor; keys by physical position.
- **Depends on.** `20-input:04-hosts-adopt`
- **Done when.**
  - [ ] a gamepad's sticks, triggers and buttons arrive on Windows,
    Linux and the web, and still navigate the widgets
  - [ ] a locked pointer reports motion without limit and is released on
    Escape or loss of focus
  - [ ] a binding by physical key holds across keyboard layouts

### 7.10 `12-font-system` — Text

The group exists in the roadmap with no items. These are its items.

#### `12-font-system:01-contract` — The text contract

- **Goal.** SPEC.md §9 lets text be shaped once and drawn from the
  result.
- **Grounding.** F-11, F-12; D-02.
- **Strategy.** The contract measures as now and also shapes: a run of
  glyphs with their faces, positions and the bytes each came from. The
  core caches the run beside the string it already caches, and the
  command carries it with its bytes, which cells, semantics and the wire
  still read. Measurement stays additive between break opportunities and
  nowhere else. Carets and hit tests are questions asked of a run. The
  suite's rules that forbid shaping are replaced by ones that hold
  measuring and drawing to the same run.
- **Depends on.** `17-draw:02-scene-builder`, `20-input:01-contract`
- **Done when.**
  - [ ] SPEC.md §9.4 and §13.1 state the contract, the run and what the
    command carries
  - [ ] `roadmap/12-font-system.md`'s rules are rewritten to match
  - [ ] the font systems' conformance suite is rewritten on the new
    rules, to fail on today's pen
- **To settle.** Whether the wire sends runs or bytes; default: bytes,
  shaped again where they are drawn, guarded by the fingerprint as now.

#### `12-font-system:02-own-face` — zui's own face

- **Goal.** Font files are parsed and rasterized in Zig, and no input
  can read out of bounds.
- **Grounding.** F-14.
- **Strategy.** A parser for the tables in use and a rasterizer that
  fills outlines by exact coverage, behind the five methods
  `text/truetype/src/face.zig` already gives. It depends on nothing else
  here, so it can start at once.
- **Depends on.** nothing
- **Done when.**
  - [ ] the bundled faces measure and rasterize as before, within a
    stated tolerance
  - [ ] a corpus of malformed fonts is refused without a fault, under a
    fuzzer in CI
  - [ ] every face of a collection loads
  - [ ] stb_truetype and the repository's last C file are gone

#### `12-font-system:03-runs-and-atlas` — Runs in the command, and a new atlas

- **Goal.** A line is laid out once, when it is measured, and drawn from
  that.
- **Grounding.** F-11, F-13.
- **Strategy.** The run cache, and commands that carry runs. An atlas
  keyed by face, glyph, size and a fraction of a pixel, with eviction,
  uploads of only what changed, one byte for a texel of coverage and a
  page for color. Renderers place glyphs and lay nothing out.
- **Depends on.** `12-font-system:01-contract`,
  `12-font-system:02-own-face`, `17-draw:05-renderers-on-zui-draw`
- **Done when.**
  - [ ] no renderer walks codepoints, and warm text draws with no call
    into the text contract
  - [ ] glyphs sit at fractions of a pixel, and spacing at a scale of 1
    is even, in the reference's snapshots
  - [ ] a full atlas evicts what is least used and never wipes
  - [ ] the renderer's cost for 1,000 warm lines is measured against
    today's

#### `12-font-system:04-shaping` — Shaping

- **Goal.** Text in Latin, Greek and Cyrillic is set as its fonts
  intend, and every script breaks into lines.
- **Grounding.** F-12.
- **Strategy.** Kerning, ligatures and mark placement from the fonts'
  own tables. Grapheme clusters and line-break opportunities from
  Unicode's rules, as the default segmentation.
- **Depends on.** `12-font-system:03-runs-and-atlas`
- **Done when.**
  - [ ] kerned pairs and ligatures are drawn, in the reference's
    snapshots
  - [ ] a caret moves by grapheme cluster
  - [ ] CJK and Thai text wraps
  - [ ] Unicode's conformance files for segmentation and line breaking
    pass

#### `12-font-system:05-bidirectional-and-complex` — Bidirectional and complex scripts

- **Goal.** Arabic, Hebrew and the Indic scripts are shaped and ordered
  correctly.
- **Grounding.** F-12.
- **Strategy.** Unicode's bidirectional algorithm, giving runs in visual
  order for each line, and the shaping the complex scripts' tables ask
  for.
- **Depends on.** `12-font-system:04-shaping`
- **Done when.**
  - [ ] Unicode's bidirectional conformance file passes
  - [ ] mixed Arabic and Latin lines draw, wrap, select and place a
    caret correctly
  - [ ] shaping agrees with a reference shaper over a corpus for each
    script claimed

#### `12-font-system:06-fallback-and-system-fonts` — Fallback and the system's fonts

- **Goal.** A character no named font has is still drawn, and an
  application can use what is installed.
- **Grounding.** F-12, F-14.
- **Strategy.** A chain of faces for each style, tried for each cluster.
  The system's fonts found by the host, as a service. Color glyphs. No
  fixed count of fonts.
- **Depends on.** `12-font-system:03-runs-and-atlas`
- **Done when.**
  - [ ] text mixing scripts and emoji draws with no missing-glyph box
    where any installed font has the glyph
  - [ ] an application lists and loads the system's fonts on Windows and
    Linux
  - [ ] color emoji are drawn by every backend and the reference

### 7.11 `22-web` — The web

One way to run in a browser, on any page, with text entry that works and
an address.

#### `22-web:01-one-way-to-run` — One way to run

- **Goal.** The web host is the one way an application runs in a
  browser, and any application can use it.
- **Grounding.** F-26; D-13.
- **Strategy.** Remove the thin client as a way to run, keeping its
  decoder as a test of `zui_wire`. The package exports its module. Fonts
  are fetched, not embedded, unless the application embeds them.
- **Depends on.** `18-gpu:05-webgl2`, `20-input:04-hosts-adopt`
- **Done when.**
  - [ ] the template project runs in a browser through `zui_web` as a
    dependency
  - [ ] one page and one worker script serve every application
  - [ ] the published tour's download is measured before and after

#### `22-web:02-single-threaded` — A single-threaded build

- **Goal.** A zui page loads anywhere, with no special headers.
- **Grounding.** F-26.
- **Strategy.** The host runs on one thread by default, its tasks taking
  turns as they already do. Shared memory and workers become an option
  for an application that wants parallel work and can serve the page
  isolated.
- **Depends on.** `22-web:01-one-way-to-run`
- **Done when.**
  - [ ] the tour runs from a plain static server with no service worker
  - [ ] its frames are the same as the threaded build's
  - [ ] an application that asks for threads gets them where the page is
    isolated, and a clear error where it is not

#### `22-web:03-text-and-keys` — Text and keys

- **Goal.** Typing works on a phone and a desktop, and the browser keeps
  its own keys.
- **Grounding.** F-15, F-26.
- **Strategy.** The text-input session of `20-input:01` on the browser's
  own facility for editable regions, with a hidden field where a browser
  lacks it. Only the keys a frame used are cancelled. Clipboard and
  opening a link happen inside the user's gesture. The canvas takes its
  size in device pixels from the browser.
- **Depends on.** `22-web:01-one-way-to-run`
- **Done when.**
  - [ ] a text field takes typing, correction and deletion from
    Android's and iOS's keyboards, checked on a device or an emulator
  - [ ] Tab leaves the canvas at its last control, and the browser's
    shortcuts work
  - [ ] copy, paste and a link work in Safari, Firefox and Chromium

#### `22-web:04-location-and-documents` — An address, and a document

- **Goal.** A zui page has a URL the application can read and change,
  and a crawler or a reader finds content.
- **Grounding.** F-26.
- **Strategy.** The location and the back button are events; changing
  the location is a request. At build time the application's semantic
  tree for a location is written as static HTML, which the page shows
  until the application starts and which `23-accessibility:03`'s mirror
  then replaces.
- **Depends on.** `22-web:01-one-way-to-run`, `23-accessibility:03-web`
- **Done when.**
  - [ ] back and forward move through an application's states, and a
    copied URL opens the same state
  - [ ] with scripts off, the page shows its headings, text and links
  - [ ] the same mechanism opens a deep link on a desktop host

### 7.12 `23-accessibility` — Accessibility on every host

#### `23-accessibility:01-semantics` — Semantics that say enough

- **Goal.** A frame's semantics describe every control zui ships,
  cheaply.
- **Grounding.** F-20.
- **Strategy.** Implement what `20-input:01` specified: the missing
  roles, text with its caret and selection, live regions and relations.
  A host is given what changed, and nothing while no assistive
  technology listens.
- **Depends on.** `20-input:02-core-and-modules-adopt`
- **Done when.**
  - [ ] every widget reports its true role, and the rows of
    ARCHITECTURE.md §7 about nearest roles are closed
  - [ ] a frame with unchanged semantics hands a host nothing
  - [ ] with no client attached, semantics cost no more instructions
    than with the feature off, within CI's gate

#### `23-accessibility:02-linux` — Linux

- **Goal.** A screen reader on Linux reads and works a zui application.
- **Grounding.** F-20.
- **Strategy.** A bridge to the desktop's accessibility bus on the
  host's own D-Bus client.
- **Depends on.** `23-accessibility:01-semantics`
- **Done when.**
  - [ ] the accessibility example is read and operated by Orca
  - [ ] a client out of process toggles, sets, expands, selects, scrolls
    and invokes, as the Windows suite does

#### `23-accessibility:03-web` — The web

- **Goal.** A zui page is a page to assistive technology.
- **Grounding.** F-20, F-26.
- **Strategy.** A mirror of the semantic tree in the document, kept in
  step by changes, over the canvas: roles, names, states, links and form
  fields. Its actions come back as action events.
- **Depends on.** `23-accessibility:01-semantics`,
  `22-web:01-one-way-to-run`
- **Done when.**
  - [ ] a browser's accessibility tree shows every control of the
    accessibility example
  - [ ] a screen reader operates it in Chromium, Firefox and Safari
  - [ ] a link in the mirror opens in a new tab as any link does

#### `23-accessibility:04-windows` — Windows, completed

- **Goal.** The Windows bridge covers text, tables, trees and
  announcements.
- **Grounding.** F-20.
- **Strategy.** The text, grid, table and tree patterns, live regions,
  setting a value, and a lookup that does not scan.
- **Depends on.** `23-accessibility:01-semantics`
- **Done when.**
  - [ ] Narrator reads a text field by character, word and line, and
    announces a toast
  - [ ] a table and a tree are navigated as such
  - [ ] the bridge's cost for a frame is measured, with and without a
    client

### 7.13 `24-mobile` — Mobile hosts

Not audited, since there is no code. The contracts of `19-present` and
`20-input` are written so that these need no change to them.

#### `24-mobile:01-android` — Android

- **Goal.** The tour runs on Android unchanged.
- **Grounding.** F-19, F-32.
- **Strategy.** A pushed host on the platform's loop, drawing through
  Vulkan or OpenGL ES. Its surface comes and goes with the application's
  lifecycle. Text entry is the text-input session; insets, the on-screen
  keyboard and the back button arrive as the vocabulary says.
- **Depends on.** `18-gpu:06-vulkan`, `19-present:04-loss-and-resize`,
  `21-windowing:03-native-touch-and-pen`
- **Done when.**
  - [ ] the host passes the pushed host's suite on an emulator in CI
  - [ ] the tour survives being sent to the background and brought back,
    with its state
  - [ ] a text field takes the system keyboard's typing and correction

#### `24-mobile:02-ios` — iOS

- **Goal.** The tour runs on iOS unchanged.
- **Grounding.** F-32.
- **Strategy.** As Android, on UIKit and Metal. It waits for the
  hardware macOS waits for.
- **Depends on.** `14-macos:05-metal`,
  `21-windowing:03-native-touch-and-pen`
- **Done when.**
  - [ ] the host passes the pushed host's suite on a simulator
  - [ ] the tour runs on a device

### 7.14 `25-audio` — Audio

Not audited, since there is no code. It is in the plan because a
framework for games and applications needs it and nothing else here
provides it.

#### `25-audio:01-audio` — Audio

- **Goal.** An application plays and mixes sound through a contract of
  zui's, on every host.
- **Grounding.** F-32.
- **Strategy.** A contract as the others are: an output device that asks
  for buffers on its own thread, and a mixer as a module on the public
  API. A backend for each platform's own audio API, with none linked
  that is not the system's. It is independent of everything but the
  charter, so it can be planned whenever it is wanted.
- **Depends on.** `15-charter:01-scope-in-spec`
- **Done when.**
  - [ ] the contract is in SPEC.md with its checks and its conformance
    suite
  - [ ] a sample plays a sound in response to a click on Windows, Linux
    and the web
  - [ ] nothing on the audio thread allocates or waits
- **To settle.** How far it goes: playback and mixing first; capture,
  spatial sound and streaming decoders only when an application needs
  them.

### 7.15 `14-macos` — One item more

#### `14-macos:05-metal` — Metal

- **Goal.** macOS, and later iOS, draw through zui's own Metal backend.
- **Grounding.** F-32; D-17.
- **Strategy.** A backend as the others are. Until there is hardware,
  its shaders are compiled and its code type-checked on CI's macOS
  runners, so the contract is held to Metal's model from the start.
- **Depends on.** `18-gpu:02-shaders`, `14-macos:01-macos-host`
- **Done when.**
  - [ ] the backend builds on CI's macOS runners from `18-gpu:02` onward
  - [ ] it passes `17-draw:04`'s suite on a Mac
  - [ ] the macOS host of `14-macos:01-macos-host` draws the tour
    through it

## 8. The current queue

What becomes of ROADMAP.md's open rows. `15-charter:02` makes these
changes.

| Row | Becomes | Why |
|---|---|---|
| `11-polish:31-rich-text-and-reordering` | waits on `12-font-system:03` | it draws styled runs, which the text contract is about to define |
| `11-polish:06-text-editing` | waits on `20-input:04` and `12-font-system:03` | it needs composition, the text-input session and carets asked of a run |
| `11-polish:41-pixel-hashes`, `:43-test-card-review` | redone on `17-draw:03` | the reference's pixels are exact, so nothing is approved for each rasterizer |
| `11-polish:44-test-card-on-the-web` | folded into `18-gpu:05` | the page is checked against the reference there |
| `11-polish:42-scripted-input` | continues, then follows `20-input:02` | its scripts are records, whose shape changes once |
| `11-polish:33-pickers`, `:34-zui-widgets-views` | continue | they sit on the public API and move with it |
| `11-polish:22-appearance-review`, `:23-design-workbench` | continue; their images come from `17-draw:03` once it exists | the review's report shows an image of each permutation |
| `11-polish:10-samples`, `:12-developer-experience-audit` | after wave 2 | a sample should name the renderers and hosts that will remain |
| `10-reach:01-linux-host`'s remainder | split between `16-defects:03`, `20-input:04` and `23-accessibility:02` | each part now has an owner |

## 9. What is not known

- **Nothing was run.** Every figure marked *est.*, and every "by the
  code", is a reading. Each item's first step is to confirm its ground,
  and to measure where its finding claims a cost.
- **F-23's missing title bar** was read from the code and not seen on a
  compositor.
- **The budgets** for building primitives, for the CPU reference and for
  each backend do not exist yet. `17-draw:01` and `18-gpu:01` set them,
  and until then "faster" has only today's renderer to be compared with.
- **Sharing GPU buffers with a compositor** (`21-windowing:04`) is the
  least certain technique in the plan. Its first slice, shared memory
  with the CPU renderer, does not depend on it.
- **Loading drivers at run time** keeps libc on Linux, since the
  vendors' drivers need its loader. A build with no libc at all is not a
  goal.
- **macOS and iOS** cannot be checked here. Their items are written so
  that the contracts are held to their models by CI, and nothing more is
  claimed.
- **Mobile and audio** were not audited because there is nothing to
  audit; their items are the plan's most likely to change when taken.
- **The size of the text work.** A shaper for every script is the
  largest single piece in this report. `12-font-system:04` and `:05` are
  split so that each script claimed is checked against a reference
  before the next is begun.

# Roadmap and rollout plan

SPEC.md is the contract for the core: what zui does, and, marked
*Planned for 0.x*, what it has committed to do. ARCHITECTURE.md is the map
of everything around the core: hosts, renderers, modules, and how they
connect. This file is the plan for building both: what ships in each
release, in what order, and how each item is judged. The commits of the
declaration work after 0.5 record its measurements.

The items come from four sources: a comparison with
[Clay](https://github.com/nicbarker/clay) at `e6cc369` (v0.14) made
against zui at `508e10c`, the owner's notes, the architecture they led
to, and a review of input on 2026-11-02, from which I3–I5 and G6 came.
Each item says:
- **Grounding:** what we know, with the code that shows it.
- **Plan:** what to change.
- **Done when:** the test or measurement that decides it.
- **Spec:** the sections it changes.

## Where we are

| Release | Scope | Status |
|---|---|---|
| 0.1 | layout core, text wrapping, measurement cache, render commands | shipped |
| 0.2 | input, focus, clipping, scrolling, floating, state | shipped |
| 0.3 | task pools, `needsFrame`, frames held by a render thread | shipped |
| 0.4 | `zui_widgets`, `zui_reflect`, `zui_testing` | shipped |
| 0.5 | layout performance, parallel measurement, benchmarks | shipped |
| after 0.5 | declaration work: −42% to −56% | on `main` (no release is tagged yet) |
| 0.6 | measure and audit: regression checks, the async audit, the frame boundary, the input format, startup and trace profiling | **next** |
| 0.7 | the contracts: renderer, host, surface, conformance, `zui_app`; input as an ordered event log; the raylib adapter | planned (the breaking release) |
| 0.8 | the first native host: Windows | planned |
| 0.9 | feeds and the wire format | planned |
| 0.10 | text, layout and gestures | planned |
| 0.11 | effects and HDR | planned |
| 0.12 | seeing the UI: inspector, semantics, safety sweeps, web demo | planned |
| 0.13 | more hosts and services: macOS, Linux, web; notifications, dialogs, decorations, windows | planned |
| 0.14 | motion | planned |
| 0.15 | text editing | planned |
| alongside | modules (K) and developer experience (D) | any release, once unblocked |
| later | docking, grid, layout islands, static subtrees, SIMD | only with a measured or demonstrated need |

Measured on the reference machine (i9-10900K) at `508e10c`:

| Scenario | Declaration | `endFrame` | §6.5 target |
|---|---|---|---|
| 4,096 boxes, depth 8 | 51.8 µs | 100.0 µs | 100 µs (no headroom) |
| 1,000 texts, warm cache | 13.9 µs | 184.2 µs | 250 µs |
| 4,000 children of one parent | 54.5 µs | 67.9 µs | |

## Picking up from here

The plan was settled on 2026-11-01. No code for 0.6 or later exists yet.
To start:

1. **Record a baseline.** The numbers above are from `508e10c`. On the
   machine you will measure on, run
   `zig build bench -- --json baseline.json` at the current `main` and
   keep the file; every 0.6 item is judged against it.
2. **Work through 0.6 in this order:**
   - R2, so later items can be compared locally;
   - P1, so startup has numbers before anything changes it;
   - A2, which is small and concrete, starting at `src/tasks.zig:118`
     and `:147`;
   - A1, whose review may add items to 0.6 or 0.7;
   - R1, then P2 and I3, which are both judged by R1's counts.
3. **Follow "Spec first, then code"** below. R1 is already specified in
   SPEC.md §16, A2 in the §10.3 note, and I3's event log in the §5.1
   note; the rest need their designs in SPEC.md before code.

Things to know when resuming:
- **ARCHITECTURE.md §3 is sketches, not code.** No `zui.Surface`,
  `RendererCapabilities`, `Feed` or `zui_app` exists yet. The names may
  change when 0.7 builds them, and the doc is updated in the same commit.
- **The other repos are untouched.** zui-raylib, zui-sokol and
  zui-terminal keep today's `Platform` until 0.7. `zui-host` does not
  exist yet; it is created with H2 in 0.8.
- **No release is tagged.** 0.1 to 0.5 and the declaration work are on
  `main`.
- **Item IDs are stable.** A letter names a series (R regression checks,
  A async, P profiling, C contracts, T text, S scale, H hosts, F feeds and
  the wire, L layout, I interaction, G graphics, V visibility, M motion,
  E editing, K modules, D developer experience). A new item takes the next
  number in its series, and numbers are never reused, so a gap such as G4
  is an item that was merged into another.
- **The open decisions** below are each planned with their first option.
  Revisit one when its item's release starts, not before.

## How releases ship

- **Measure, then build on the contracts, then prove them twice.** 0.6
  gives every later change a trustworthy measure. 0.7 defines the
  contracts and proves them with an adapter; 0.8 proves them again with a
  native host, because a contract with one implementation is not yet a
  contract.
- **One breaking release.** 0.7 changes `measureText` (T3), how scale
  reaches layout (S1), and input from sampled state to an event log (I4),
  and moves backends onto the contracts. Every
  backend, `zui_testing` and `bench/` are updated in the same week, and
  the release notes say what to change.
- **After 0.7, new commands do not break renderers.** Optional commands
  are lowered by the core for renderers that cannot draw them
  (ARCHITECTURE.md §3.2), which is why effects (0.11) can come after the
  breaking release.
- **New optional modules before new core.** If a feature can be built on
  the public API, it is, and the core only gains what a module proves it
  cannot do without.
- **Items may land early.** An item whose prerequisites have shipped can
  land in an earlier release than listed; T1 and T2, for example, need
  only 0.6.
- **Spec first, then code.** When a release starts, its items' designs
  land in SPEC.md (or ARCHITECTURE.md) marked *Planned for 0.x*, and the
  marker comes off in the commit that ships each one.

---

## 0.6: measure and audit

### R1. Instruction counts in CI

Specified in SPEC.md §16: Callgrind, a fixed `-Dcpu`, a fixed number of
frames per scenario; fail on more than 2% growth over the parent commit.

**Done when:** the counts repeat exactly between runners.

### R2. `zig build bench-compare -- <ref>`

Builds both commits, alternates them locally, and reports the median
ratio and its spread.

**Done when:** it catches the `depth: u16` store-forwarding stall fixed
in `946405e`, which leaves the instruction count unchanged: a 16-bit
store followed by a 32-bit reload cost the box tree's declaration 27%.

### A1. The async and parallel audit

**Grounding.** zui runs work on other threads in three places: tasks
(§10.3), parallel measurement (§10.5) and frames released from a render
thread (§10.2). Hosts, feeds and signals will add more. Canceling a task
waits on the UI thread until the task reaches a cancelation point.

**Plan.** A written review, kept in the repo, answering for each place:
who owns the thread, what crosses it, where it can block the UI thread,
and how it behaves with each kind of `Io` (threaded, evented,
single-threaded). Each problem found becomes an item.

**Done when:** the review is merged, and every problem it found is an item
here or fixed.

**Spec.** §10, as the review finds.

### A2. Apply task completions at `beginFrame`

**Grounding.** SPEC.md §5 says `beginFrame` drains the completion queue,
but each pool drains at every `request` (`src/tasks.zig:118`, `:147`).
Two requests to one pool in one frame can therefore see different states,
and completions are not part of the frame record (ARCHITECTURE.md §2).

**Plan.** Registered pools drain in `beginFrame`; `request` and `get`
only read.

**Done when:** a test completes a task between two requests in one frame
and both see the same state, and the existing task tests pass.

**Spec.** §5, §10.3.

### P1. Startup benchmarks

**Grounding.** `zig build bench` measures steady frames only. Nothing
measures `init` (one allocation of 4.29 MiB at the default config, §4.2),
the first frame (every text cold) or a cold start of the demo.

**Plan.** Add `init`, `initBuffer` and first-frame scenarios to
`bench/`, and measure the demo's time from process start to its first
presented frame.

**Done when:** the scenarios are in `--json` and `--compare`.

**Spec.** §14.3.

### P2. Trace zones

**Grounding.** The profiles of the declaration work needed hand-matched
`perf` samples and temporary `never_inline` calls to see per-function
costs.

**Plan.** `-Dzui-trace` adds a zone per layout pass, per emission and
per `beginFrame` step, for a profiler such as Tracy, and is not analyzed
at all when off. A short guide in the repo covers profiling with minimal
noise: pinned cores, fixed frequency, alternating runs.

**Done when:** a trace of the demo shows every pass, and an off build's
instruction counts (R1) are unchanged.

**Spec.** §3 build options, §14.3.

### I3. The input format, settled before the host contract

**Grounding.**
- `Input.buttons` is the state at poll time (`src/context.zig:902`), so a
  press and release between two polls is never a click. zui sleeps until
  input arrives, which makes that likely, and a touch tap usually
  vanishes.
- There is one pointer: one `press_target` and one `hover_chain`
  (`src/interaction.zig:181`).
- `Key` has no letters (`src/interaction.zig:8`), so Ctrl+S or Ctrl+C
  cannot be expressed, and modifiers are sampled once per frame rather
  than per key.
- C2's `poll(record)` and F3's encoding freeze whatever the frame record
  is. Changing it after 0.8 would break every host and the wire format.

A prototype that modeled all inbound data as routed values handled by a
comptime registry of state "machines" was weighed against this. Its
event stream and central arbitration are kept (I4, I5). The registry, a
message bus between elements, and a single manipulation kind are not:
they duplicate the state table, keep modules from shipping their own
gestures, and route a gesture by kind where it must be routed by motion
component (I5).

**Plan.** Specify the event log (SPEC.md §5.1's note) and the
per-pointer table, then rebuild today's `resolveInput` over the log
behind the current API, with `max_pointers = 1`.

**Done when:**
- the interaction, widget and `zui_testing` tests pass unchanged;
- R1's counts on the mouse-only scenarios are no higher than today's;
- an idle application still sleeps;
- a press and release inside one frame is a click;
- 133 moves in one frame (an 8 kHz mouse at 60 Hz) cost at most one
  hover hit test per pointer.

**Spec.** §5.1, §7.4.

---

## 0.7: the contracts

ARCHITECTURE.md §3 has the designs.

### C1. The renderer contract, and lowering

**Plan.** `zui.RendererCapabilities` and `accepted_surfaces`; `submit`
and `measureText` on the renderer. Emission lowers optional commands the
renderer did not declare. zui-raylib, zui-sokol and zui-terminal become
renderers.

**Done when:** each backend passes C3's renderer suite, and lowering is
tested for each optional command as it is added.

**Spec.** §7.5, §8; ARCHITECTURE.md §3.2.

### C2. The host contract, the surface and host events

**Plan.** `poll`, `wake`, `waitUntil`, `surface`, `scale`; `zui.Surface`;
the host-event vocabulary in the frame record: system theme, scale,
locale, power, network, lifecycle (interrupt, terminate request, hang-up,
session ending, suspend, resume) and dropped files.

**Done when:** the raylib adapter (H1) passes C3's host suite.

**Spec.** §5, §5.1; ARCHITECTURE.md §2, §3.3, §3.4.

### C3. Conformance suites

**Plan.** `zui_testing.expectRendererConforms` and `expectHostConforms`
(ARCHITECTURE.md §5), and a CI recipe the backends copy.

**Done when:** every backend's CI runs them.

**Spec.** §14.2.

### C4. `zui_app`: the runner, and `Platform` from host and renderer

**Plan.** `zui_app.Platform(Host, Renderer)` builds today's `Platform`,
so `Context` does not change. `zui_app.run` is the standard loop: poll,
apply the frame record, declare, end the frame, submit, release, wait
until the deadline. It reports capabilities and fallbacks in effect.

**Done when:** the demo runs on `zui_app` with less code than today.

**Spec.** §3; ARCHITECTURE.md §3.1.

### T3. Letter spacing, through a measurement key

**Grounding.** `measureText(text, font, size)` (§8.1) cannot express
letter spacing per text, and the additive-measurement rule means a
backend cannot add it after the fact. Clay has `letterSpacing`.

**Plan.** `TextStyle.letter_spacing: f32 = 0`, and `MeasureKey { font,
size, letter_spacing }` passed to the renderer and used as the cache key.
Text commands carry the spacing.

**Done when:** a golden test lays out spaced text, and every renderer
draws it.

**Spec.** §7.3, §8.1, §8.3.

### S1. Display scale and zoom

**Grounding.** `Platform.scale` only snaps command bounds to pixels
(`src/emission.zig:32`). Nothing lets an application zoom its UI, and a
display-scale change has no event.

**Plan.** Two separate factors: the display scale, from the host per
window (with a host event when it changes), and the application's zoom,
among `Input`'s frame parameters. Layout stays in logical units; text is measured at size ×
zoom, so zoom is part of the measurement key; hit testing and snapping
use both.

**Done when:** golden tests at three zoom levels, and moving the demo
between monitors of different scale relayouts it.

**Spec.** §5.1, §8.1, §8.3.

### I4. Input as an ordered event log

**Grounding.** I3.

**Plan.**
- `Input` keeps the frame's parameters (`viewport`, `dt_seconds`) and
  gains `events`, in arrival order: pointer down, move, up, cancel and
  leave, each with a pointer id, pointer kind, button, pressure, tilt and
  the host's timestamp; wheel with a position and a precise/line flag;
  key down and up with repeat and per-event modifiers; text; and the OS's
  own pinch and rotate. The sampled fields go.
- `Key` covers letters, digits, punctuation and function keys, and
  `ui.chordPressed(.{ .key = .s, .modifiers = .{ .control = true } })`
  matches the modifiers as they were at that key.
- A per-pointer table, sized by `Config.max_pointers` (default 10),
  replaces `press_target` and `hover_chain`. Touch never hovers.
- Moves are coalesced per pointer: only the last move before another
  event of that pointer is hit-tested, and the rest are kept as history
  for velocity.
- `zui.InputSampler` turns successive sampled states into events, for
  backends such as raylib that only offer state.
- `zui_testing.Driver` emits events, so `click` can run in one frame, and
  gains `tap`, `pinch` and multi-pointer `drag`.
- `Config.max_events_per_frame` replaces `zui.max_keys_per_frame`.

**Done when:** I3's checks still hold on the new `Input`, H1 passes C3
through `InputSampler`, and a test presses two buttons with two pointers
at once.

**Spec.** §5.1, §7.4, §13.2, §14.2; ARCHITECTURE.md §2, §3.3.

### H1. The raylib adapter host

**Plan.** zui-raylib implements the host contract with
`.windows = .one` and no system material, and its renderer accepts the
adapter's surface.

**Done when:** it passes C3's host suite, and the demo runs on it through
`zui_app`.

---

## 0.8: the first native host

### H2. The Windows host

**Grounding.** The owner develops on Windows, and Windows has every
system feature planned (materials, signals, scale changes, file drop),
so it tests the contract hardest.

**Plan.** In `zui-host/windows`: Win32 windows and the event loop,
`win32` surfaces, per-monitor scale, lifecycle events from console
control events and `WM_QUERYENDSESSION`, the clipboard, dropped files,
frame pacing to the deadline, and the system material (H8). zui-sokol's
renderer accepts its surface, through sokol_gfx without sokol_app.

**Done when:** the demo runs on it unchanged from H1, it passes C3, and
it idles at 0% CPU.

**Spec.** ARCHITECTURE.md only.

### H8. The desktop showing through the window

**Grounding.** The owner's "slate": on Windows 11 the desktop shows
faintly through a window, blurred. Windows offers Mica and Acrylic
(`DwmSetWindowAttribute`), macOS vibrancy (`NSVisualEffectView`), KDE a
blur protocol; GNOME and browsers offer nothing comparable.

**Plan.** `HostCapabilities.system_material`, and a material per window.
The renderer clears to transparent, and elements without a background
let it show. Where the host has none, the root draws the theme's solid
background instead (the fallback, ARCHITECTURE.md §4).

**Done when:** the Windows host shows Mica on Windows 11 and the solid
fallback on Windows 10, with the same application code.

**Spec.** §7.5 (the root background), ARCHITECTURE.md §3.3.

---

## 0.9: feeds and the wire format

### F1. Feeds

**Plan.** `zui.Feed(T, options)` as ARCHITECTURE.md §3.5 describes, and
`TaskPool` rebuilt as a feed that delivers once, with its API unchanged.

**Done when:** the task tests pass unchanged on the new `TaskPool`, and
feed tests cover both deliveries, both drop policies, waking and
unmounting.

**Spec.** §10.3, §10.4 (the queue pattern becomes feeds).

### F2. The relay tap

**Plan.** `ui.relay(listener)`: each listener receives the frame record
after `beginFrame` applies it, without allocating. A listener that is
slower than the frame rate is the listener's problem to buffer.

**Done when:** a test relays a session into a buffer and gets back
exactly the records it applied.

**Spec.** §5.

### F3. `zui_wire`

**Plan.** As ARCHITECTURE.md §3.6: versioned encoding of frame records
and commands, deltas between frames, serialization of application
payloads, and font fingerprints.

**Done when:** round trips are tested for every record and command kind,
and a delta stream of the demo is measured against full frames.

**Spec.** ARCHITECTURE.md §3.6.

### F4. Replay in `zui_testing`

**Plan.** `Driver.replay(records)` drives an application from relayed
records; snapshots can be stored in the wire format.

**Done when:** a recorded demo session replays to identical commands.

**Spec.** §14.2.

### F5. Rendering somewhere else

**Plan.** A wire renderer that streams commands out, and a wire host
that feeds relayed records in, so a remote client is just a host plus a
renderer. The browser demo (V4) is the first client.

**Done when:** the demo runs in one process and draws in another,
with input going back.

### F6. Watching files

**Plan.** A feed of file changes, from the host, which `zui_debug` uses
to reload themes and assets while the application runs.

**Done when:** editing a theme file restyles the running demo.

---

## 0.10: text and layout

### T1. A single-line fast path in wrapping

**Grounding.** `text.wrapLines` (`src/text.zig:276`) walks every word of
every text element, even a label whose unwrapped width already fits.
Clay emits one line without walking the words when the text has no
newline and its preferred width fits.

**Plan.** Record in `Metrics` whether the text has a paragraph break. In
`wrapLines`, with `.words` or `.newlines` and no break, if
`preferred_width <= max_width + tolerance`, emit one line.

**Done when:** the golden and randomized tests pass unchanged, and the
warm 1,000-text `endFrame` is faster by 0.6's measure.

**Spec.** §8.2.

### T2. Look up whole strings before words

**Grounding.** A warm text element costs one cache probe per word per
frame (`text.measureMetrics`, `src/text.zig:161`); 1,000 texts take
184 µs in `endFrame`, against 100 µs for 4,096 boxes. Clay keys its cache
by the whole string and pays one probe per element. zui's per-word cache
is better for text that changes every frame (`"Frame 1234"`), because
only the new words are measured, so it stays.

**Plan.** A second, smaller table keyed by the whole string and the
measurement key, holding only `Metrics`. A hit with T1's fast path needs
no per-word work at all; a text that must wrap falls back to the word
cache for its run widths.

**Done when:** warm 1,000-text `endFrame` improves by 0.6's measure, and
a frame that changes every string is no slower. A profile (P2) checks
first that per-word probes are the main cost; if not, T2 is dropped.

**Spec.** §8.3, §4.2's memory figures.

### L1. A grow basis: equal columns

**Grounding.** Two `.grow` siblings holding "a" and "abcdefghijklmnop" in
300 px come out 90 / 210, as with CSS `flex-basis: auto` (§6.1). Clay
gives 150 / 150. zui has no way to ask for equal columns.

**Plan.** `Sizing.basis: enum { content, zero } = .content`, with
`.growEqual` and `growEqualWeighted(w)`. A zero-basis child starts from
its minimum before free space is shared, keeping weights, which Clay
lacks.

**Done when:** golden tests for both bases, and the weight invariant
holds for each.

**Spec.** §6.1, §6.2.

### L2. Aspect ratio, and the natural size of images and custom leaves

**Grounding.** An image has no size of its own; the application must
give it `fixed` sizing. Clay has `aspectRatio`.

**Plan.**
- `Layout.aspect_ratio: ?f32` (width / height). After the width pass, an
  aspect-ratio element's height becomes effectively fixed before the
  height pass. That derives height from width only: widths are settled
  before heights (§6.2), so a width derived from a `grow` height would
  need another width pass, and is left out until something needs it.
- Optional `imageSize(handle)` and `measureCustom(data)` on the renderer
  (§15). An image that arrives later reports its size through a feed
  (F1).

**Done when:** golden tests cover aspect ratio under every rule on the
other axis, and a `fit` image takes its natural size.

**Spec.** §6.1, §6.2, §8.1, §15.

### L3. Dividers, and decorated images

**Grounding.** Clay draws borders between children. zui's image command
carries only the handle (`src/emission.zig:152`).

**Plan.** `Border.between_children: f32 = 0`; image commands carry
`corner_radius` and `tint: Color = .white`.

**Done when:** snapshot tests for both; renderers draw them (the defaults
mean renderers that ignore them still draw correctly).

**Spec.** §7.1, §7.5.

### L4. Floating options

**Grounding.**
- Every floating element gets a hit region (`src/emission.zig:157`), so
  a tooltip blocks what is under it. Clay can pass the pointer through.
- Floating elements always escape their ancestors' clip. Clay can clip
  to the attached parent.
- A target declared after the floating element falls back to the parent
  (`src/layout.zig:421`).

**Plan.** `Floating.capture: bool = true`; `Floating.clip: enum { none,
target } = .none`; later targets placed after pass 6 by shifting the
floating subtree (`index..subtree_end`, which is contiguous).

**Done when:** interaction, layer and golden tests for each.

**Spec.** §6.4.

### L5. What `percent` and `grow` mean

**Status.** Done: SPEC.md §6.1 describes both, with the probe numbers.

### L6. Right-to-left layout

**Grounding.** Every direction today is left-to-right or top-to-bottom.
Right-to-left languages need rows, alignment, padding and text alignment
mirrored.

**Plan.** `Direction.right_to_left`, and `Layout.mirrored` applied to a
subtree, resolving `start` and `end` (padding, alignment, anchors) by
direction. Bidirectional text itself stays with the renderer's shaping.

**Done when:** golden tests mirror every alignment and anchor.

**Spec.** §6.1, §6.4, §7.3.

### L7. Responsive layout: wrap and breakpoints

**Grounding.** The owner's "size-based layout shifts and reordering".
Reordering is already plain code in immediate mode: branch on
`ui.viewport()` or the previous frame's `rectOf(parent)`. Wrapping rows
are a non-goal for v1 (§1).

**Plan.** Flex wrap in the core (a wrap pass between distribute and
position, for parents that opt in), and breakpoint helpers in a module.
Lifts the §1 non-goal.

**Done when:** golden tests for wrapping under each alignment, and no
change to the §6.5 scenarios beyond noise.

**Spec.** §1, §6.1, §6.2.

### I1. Drag and drop between elements

**Plan.** Typed drag sources and drop targets as interaction state:
`ui.dragging(id)`, `ui.dropped(target_id, T)`, with the payload in the
state table. A drag source declares `.gestures.drag`, so I5 decides
between dragging, scrolling and clicking. Files from the OS are a host
event (H6), not this.

**Done when:** `zui_testing.Driver.drag` moves an item between two lists,
including out of a list that scrolls by dragging.

**Spec.** §7.4.

### I2. A deadline for the next frame

**Grounding.** `needsFrame` (§10.3) is yes or no. A blinking caret or an
animation needs "a frame within 16 ms", and a frame-rate cap needs to
know it.

**Plan.** `ui.nextFrameDeadline() ?Instant`, the earliest of every
`requestFrameBy`, a running glide (I5), and a pending long press or
double tap; `zui_app` passes it to `host.waitUntil`.

**Done when:** the demo's caret blinks while the process otherwise idles.

**Spec.** §10.3.

### I5. Gestures: capabilities, arbitration and custom recognizers

**Grounding.**
- The slider drags with `pressed` and `pointerLocal`
  (`zui_widgets/zui_widgets.zig:268`), M3 planned drag-to-scroll, and I1
  plans drag and drop. Nested, all three want the same pointer, and
  nothing decides between them.
- Routing a gesture by kind alone fails: a vertical drag on a horizontal
  carousel inside a vertical list goes to the carousel, and a pinch that
  starts on a list inside a map goes to the list. The input prototype's
  scene could not show this, because its map accepts both axes.

**Plan.**
- Elements declare what they accept, as a packed set stored in their hit
  region the way scrolling is today:
  `.gestures = .{ .pan = .vertical, .zoom = true, .drag = true, .long_press = true, .double_tap = true, .custom = true }`.
  A scroll container accepts pan on its scrolled axes by default.
- **One rule decides.** When a pointer passes the touch slop, its axis is
  locked, and the pointer goes to the innermost region that accepts that
  component and still has room to move (from `max_scroll`), which also
  gives scroll chaining. With two pointers, scale and rotation go to the
  innermost region that accepts zoom. A release that nothing claimed is a
  tap.
- **Delays are opt-in.** Only an element with `.double_tap` delays its
  single tap until the double-tap window passes, so "this gesture waits
  for that one to fail" is local and static, never a graph.
- **Intents are queries that merge devices:**
  `ui.manipulation(id) ?Manipulation` (translation, scale, rotation and
  pivot, summed over the frame), `contextRequested` (right click, long
  press, the menu key), `dismissed` (Escape, back, gamepad B), and
  `adjusted` and `navigated` (arrows, D-pad, dial). `clicked` stays the
  activation query.
- **Momentum** is core state in the state table, keyed by the element,
  so it ends when the element is no longer declared, and it sets I2's
  deadline.
- **Custom gestures are code in declaration, not registered machines.**
  `ui.pointerEvents(id)` returns the frame's events of pointers pressed
  on or claimed by `id`. A recognizer keeps its state in `state(id, T)`,
  so it can read application state, and a module can ship one as a plain
  function. An element with `.custom` keeps its ancestors from taking the
  pointer until it calls `ui.claim(pointer)` or `ui.decline(pointer)`.
  That decision lands at the next `beginFrame`, a frame later than a
  built-in claim; no events are lost meanwhile.

**Done when:** interaction tests cover a button in a list in a zoomable
map, a carousel in a vertical list, a pinch that starts on the list, a
slider in a drag-scrolled list, a long press, a double tap next to a
single tap, a flick within one frame, and a lasso written as a module
function competing with the map's pan.

**Spec.** §6.3, §7.1, §7.4, §9.

---

## 0.11: effects

### G1. Gradients, shadows and glow

**Plan.** Optional commands: linear and radial gradients (interpolated
in OKLab, K1), box shadows, glow. Lowered per ARCHITECTURE.md §3.2.

**Done when:** snapshot and lowering tests, and one renderer draws each.

**Spec.** §7.1, §7.5.

### G2. Backdrop blur

**Grounding.** A blur of zui's own content behind a panel, distinct from
the desktop showing through the window (H8).

**Plan.** An optional command with a fallback tint, lowered to a
rectangle in that tint.

**Done when:** one renderer blurs, the others draw the tint.

**Spec.** §7.5.

### G3. Transforms

**Plan.** Scale, rotate, mirror and skew, applied when painting only, as
in CSS: layout ignores them, and hit testing inverts them.

**Done when:** an interaction test clicks a rotated button, and lowering
draws it unrotated.

**Spec.** §6, §7.4, §7.5.

### G5. Shaders

**Plan.** The renderer's own typed `MaterialHandle`, like `ImageHandle`,
carried by elements and commands. zui does not know any shading
language.

**Done when:** one renderer draws a material from the demo.

**Spec.** §4.1, §7.5.

### G6. HDR and wide gamut

**Grounding.** Colors are RGBA8 (SPEC.md §12), so nothing can be brighter
than SDR white or outside sRGB.

**Plan.**
- `Config.Color: type = zui.Color`, which may be `zui.ExtendedColor`
  (4×f16, linear scRGB, where 1.0 is SDR white), following `ImageHandle`.
  An SDR application keeps 4-byte colors.
- `RendererCapabilities.extended_color`. Without it, emission clamps
  extended colors to `Color`, as one more lowering row. Tone mapping to
  the display belongs to the renderer, because only it knows the display;
  over the wire (F5), the core cannot.
- The display's headroom above SDR white is a host event per window
  (C2), for applications that want it.
- The output format (an FP16 swapchain, HDR10) is negotiated between host
  and renderer through `Surface`; without support on both sides it is SDR.
- Wide gamut (P3, Rec.2020) is values outside 0 to 1, converted by
  `zui_color` (K1); themes written as sRGB hex convert at comptime.

**Done when:** a golden test lays out with `ExtendedColor`, lowering
clamps it for an SDR renderer, and the Windows host shows HDR white
brighter than SDR white on an HDR display.

**Spec.** §4.1, §7.5, §12; ARCHITECTURE.md §3.2, §3.3.

---

## 0.12: seeing the UI

### V1. `zui_debug`: an inspector

**Grounding.** Clay's `Clay_SetDebugModeEnabled(true)` shows the element
tree and each element's config. SPEC.md once promised
`ui.debugOverlay()`, which was never written.

**Plan.** An optional module over a read-only `Frame.inspect(index)` and
`Frame.elementCount()`: a collapsible tree, the hovered element
highlighted, its config, the frame's diagnostics, the capabilities and
fallbacks in effect (C4), and a performance overlay. Over the wire (F5)
it can run in another process.

**Done when:** `zui_testing` drives it over the Documents view, and the
demo toggles it with a key.

**Spec.** §3, §15.

### V2. The semantics list

**Grounding.** §7.6 specifies `.semantics` and `Frame.semantics()`; none
of it exists. Clay's only accessibility story is the browser's DOM.

**Plan.** As §7.6. Window-chrome roles (title bar, resize edge) for H7
travel in the same list. Accessibility actions (UI Automation's Invoke,
RangeValue and Scroll) arrive as I4 events naming an element id, and
answer through the same queries as other input: Invoke is `clicked`,
RangeValue is `adjusted`, Scroll is `manipulation`. An element's I5
gestures are the actions the list reports it supports.

**Done when:** a widget test checks the list for each control, and the
Windows host bridges it to UI Automation.

**Spec.** §7.6.

### V3. `-Dzui-safety`

**Grounding.** §3 lists the option; `build.zig` has only `-Dzui-debug`.

**Plan.** The invariant checks that read only a `Frame` move into the
core behind the option, run at the end of `endFrame`.

**Done when:** the randomized tests run through it, and a debug demo runs
with it on.

**Spec.** §3, §14.1.

### V4. A demo you can open in a browser

**Plan.** The web host (H5) and a canvas or WebGL renderer, or the demo
streaming over the wire (F5) to a thin browser client, published from CI.

**Done when:** the demo runs at its native frame rate in a browser.

---

## 0.13: more hosts and services

- **H3. macOS** (Cocoa; vibrancy for H8).
- **H4. Linux** (Wayland, then X11; KDE blur for H8 where offered).
- **H5. Web** (a canvas surface; no system material).
- **H6. Services:** notifications, file dialogs, opening URLs, and native
  menus, each an optional host declaration (ARCHITECTURE.md §4).
- **H7. Native and custom window decorations:** native frames by default;
  a custom title bar uses window-chrome regions (V2) so the OS still
  moves, resizes and snaps the window.
- **H9. More than one window:** one `Context` per window, created through
  the host; a documented pattern for state shared between windows (one UI
  thread, or feeds between them).

**Done when (each):** the host passes C3, and the demo runs on it
unchanged.

---

## 0.14: motion

### M1. `zui_motion`: enter animations and tweens

**Grounding.** §1 lists an animation system as a non-goal because easing
policies vary. Clay's transitions show that a small, policy-free
mechanism is useful.

**Plan.** An optional module over `state(id, T)` and `dt_seconds`:
`motion.value(ui, id, target, .{ .duration = 0.15, .ease = easeOut })`,
which requests frames by deadline (I2) while it moves.

**Done when:** `zui_testing` runs a tween with a fixed `dt`, and an idle
application still sleeps.

**Spec.** §1, §15.

### M2. Exit animations

**Grounding.** An element that stops being declared is gone, and its
state is freed two frames later (§9). Clay keeps exiting elements.

**Plan.** Opt-in `.exit_seconds`: the subtree's last commands keep being
emitted as a ghost that takes no space and cannot be hit, from a
fixed-size buffer in `Context` with its own `Config` limit.

**Done when:** a layer test shows a ghost for exactly its duration, and a
full buffer is reported like other limits.

**Spec.** §5, §9, §13.2.

### M3. Drag and momentum scrolling

**Status.** Merged into I5, in 0.10: dragging to scroll is a pan gesture,
and momentum is core state that I5's arbitration starts and stops.

---

## 0.15: text editing

### E1. The rest of the text field

**Grounding.** §15.1: "Not in 0.4: selection, the clipboard, word
movement, IME composition and multiple lines." Clay has no text input.

**Plan.** Selection, word movement, the clipboard (through the host, H2,
with its shortcuts as I4 chords), multiple lines, then IME composition as
I4 events to the focused element.

**Done when:** each has `zui_testing` tests, and IME works on Windows.

**Spec.** §5.1, §15.1.

---

## Alongside: modules

These depend only on the public API, so they can land in any release.

- **K1. `zui_color`:** HSL, OKLCH and OKLab conversions, mixing and
  palettes, all usable at comptime. CMYK is for print and stays out,
  apart from one conversion if asked for.
- **K2. Base themes:** dark, light and high-contrast themes for
  `zui_widgets`, switching on the host's system-theme event (C2).
- **K3. `zui_icons`:** names to codepoints in an icon font; glyphs drawn
  by the renderer.
- **K4. `zui-themes`:** theme packs for the OS design languages (Windows,
  macOS, GNOME, KDE), each a module of themes and widget skins.

## Alongside: developer experience

- **D1. `zui-examples` and a template project** that a new application
  starts from.
- **D2. Sample applications for specific uses:** a settings screen
  (`zui_reflect`, saved as ZON), a data feed, a multi-window tool, a
  remote session.
- **D3. A developer-experience audit:** a new user builds each sample from
  the docs alone, and every place they get stuck becomes an item.
- **D4. Profiling guide:** with P2's trace zones, how to see exactly what
  a frame does.

## Later

- **Docking and tear-off panels,** once H9 has more than one window.
- **A grid layout,** if L7's wrapping is not enough.
- **Layout islands and static subtrees** (SPEC.md §16). A static subtree
  could be pre-recorded element records copied in with one `@memcpy` and
  laid out normally, which keeps text working; it waits for an
  application with enough static structure.
- **Packing the per-element fields declaration writes** into one record,
  partly departing from §4.3's structure of arrays. Since the `depth`
  fix, no instruction in the box tree's declaration has more than 4% of
  its samples, so there is no hot spot for it yet.

- **P3. SIMD candidates:** each measured by R1 and R2 before it ships.

## Not taken from Clay

These are deliberate, and each is a reason to choose zui:
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
| The frame boundary | the cornerstone: everything inbound at `beginFrame`, everything outbound from `endFrame` (A2) |
| Feeds | the general mechanism for outside data; `TaskPool` is a feed that delivers once (F1) |
| Where the contracts live | in the `zui` repo, beside `Platform` (C1, C2) |
| Native hosts | one `zui-host` repo, one directory per OS |
| Who orchestrates | the host, through one contract; adapters for libraries that own their window (H1) |
| Input recording | relayed, not recorded: a recorder is one listener on the tap (F2) |
| Signals | lifecycle events; uncatchable signals are not representable (C2) |
| The input format | an ordered event log with host timestamps, not sampled state, in the 0.7 breaking release (I3, I4) |
| Pointers | many, in a comptime-sized table; a mouse is one pointer (I4) |
| Gesture arbitration | elements declare what they accept; the core decides with one rule, by motion component (I5) |
| Custom gestures | code in declaration over `pointerEvents` and `state`, not a comptime registry of machines (I5) |
| Tasks and feeds | stay deliveries of their own in the frame record, not routed input values (A2, F1) |

### Open

Each is planned with the first option.

1. **V1, inspector in a module or in the core?** Planned: a module, over
   `Frame.inspect`.
2. **T3, letter spacing by `MeasureKey` (breaking) or by encoding it in
   `FontId`?** Planned: `MeasureKey`, in the 0.7 breaking release.
3. **M1, reword the animation non-goal to "not in the core"?** Planned:
   yes.
4. **V3, `-Dzui-safety`: build it or delete it from the spec?** Planned:
   build it.
5. **V4, a web renderer, or a thin client over the wire?** Planned: the
   wire client first, because F5 builds it anyway.
6. **H2, sokol_gfx as the first renderer on a native surface?** Planned:
   yes; it already backs zui-sokol.
7. **I5, a custom recognizer's claim lands a frame late: accept that, or
   let `.custom` elements declare a claim condition the core evaluates?**
   Planned: accept it, until a recognizer shows that it matters.
8. **I4, physical key codes as well as logical keys?** Planned: logical
   only, adding physical when a game-style key binding needs it.


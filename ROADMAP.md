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
| stage 4 | the Windows host (H2), with dropped files and lifecycle events in the record; the system material (H8); `zui_app` with the application's own text contract (C9) | done; zui-sokol's tour runs on it unchanged, through `zui_app`, and idles at 0% CPU, and the same code shows Mica or a solid background |
| stage 5 | relay (F2); `zui_wire` (F3); replay in `zui_testing` (F4); the wire host, renderer and client (F5); file watching as a source (F6) | done; editing a theme file restyles a running window on the Windows host within 4 ms; a recorded session of zui-sokol's tour replays to identical commands without starting any work, zui-sokol's tour goes over the wire at a hundredth of its frames' whole size, but for the screen that moves every box, and it runs in one process and draws in another on the Windows host, its keys going back |
| stage 6 | the single-line fast path (T1), the whole-string cache (T2), static styles (L8), the box tree's layout and emission (P4) and declaration (P5), line-break segmentation (T4), the grow basis (L1), aspect ratio and natural sizes (L2), dividers and decorated images (L3), floating options (L4), right-to-left layout (L6), wrap (L7); the backends drawing images' tint and corner radius (C10) | done; the box tree's and warm text's budgets met: the box tree declares in 48.9 µs and lays out and emits in 89.2 µs, warm text in 90.5 µs; a box tree of static styles declares in 28.0 µs; zui-raylib and zui-sokol draw tinted, rounded images and pass the renderer suite that checks them |
| stage 7 | gestures (I5): arbitration by motion component, zoom, long press, double tap, momentum, the intents and custom recognizers; drag and drop between elements (I1) | done: a carousel in a list, a pinch starting on a list inside a map, a lasso module against a map's pan, and `zui_testing.Driver.drag` moving an item between two lists, out of one that scrolls by dragging |

No release is tagged; everything is on `main`. From here, work is
tracked by stage rather than by release number. Each stage may be tagged
when it is done.

Measured on the reference machine (i9-10900K), the fastest frame after
P5, against the budgets of SPEC.md §20.2:

| Scenario | Declaration | `endFrame` | Budget |
|---|---|---|---|
| 4,096 boxes, depth 8 | 48.9 µs | 89.2 µs | layout and emission < 100 µs, declaration < 55 µs: both met |
| 1,000 texts, warm caches | 15.2 µs | 90.5 µs | < 120 µs: met |
| 4,096 boxes of static styles | 28.0 µs | 88.2 µs | |
| 4,000 children of one parent | 54.0 µs | 65.8 µs | |

These are the fastest of five settled runs of `zig build bench --
--check-targets`, whose fastest box-tree frames were 48.9 to 50.2 µs for
declaration and 89.2 to 93.5 µs for layout and emission; warm text's
row is from L7's runs, after it had drifted to 101.7 µs over L2 to L6 on
the same instructions. The first run
after a build is often slower here (68.6 µs once), so judge by a run that
is not the first. The machine runs slower than when `a6d8e34` was
measured at 101.2 µs and 52.2 µs: `afacf87`, before P4, took 111.0 µs
and 68.5 µs here.

## The queue

Work is taken from the top. The first row whose status is not
`waiting` is the next item, and CLAUDE.md says how to take it on. An item
too large for one sitting lands in slices, each a commit with every check
green, and its **Status** line below says which slice is next.

| Item | Stage | Where | Waits for | Status |
|---|---|---|---|---|
| P8. One hit test per press | audit | `src/context.zig` | | next |
| P9. Wrapped lines kept with the string cache | audit | `src/text.zig`, `src/layout.zig` | | |
| P10. Cache probes over keys alone | audit | `src/text.zig`, `src/layout.zig` | | |
| P11. Flat child lists | audit | `src/context.zig`, `src/layout.zig` | | |
| G1. Gradients, shadows and glow | 8 | `src/style.zig`, `src/emission.zig`, `zui_testing/` | | |
| G2. Backdrop blur | 8 | `src/style.zig`, `src/emission.zig`, `zui_testing/` | G1 | |
| G3. Transforms | 8 | `src/style.zig`, `src/emission.zig`, `src/interaction.zig`, `zui_testing/` | G1 | |
| G5. Materials | 8 | `src/context.zig`, `src/emission.zig`, `zui_testing/`, a renderer | G1 | |
| G6. HDR and wide gamut | 8 | `src/context.zig`, `src/commands.zig`, `../zui-host` | G1 | |
| V1. `zui_debug` | 9 | `zui_debug/`, `src/context.zig`, `../zui-raylib` | G1 | |
| V2. Semantics and accessibility actions | 9 | `src/context.zig`, `zui_widgets/`, `../zui-host` | | |
| V3. Safety sweeps | 9 | `src/context.zig`, `src/tests/` | | |
| V4. The demo in a browser | 9 | `../zui-web`, `zui_wire/` | | |

After the queue come stages 10 and 11 in the order of SPEC.md §21. They join the queue as it runs short.

Statuses: `next` (the first open row), `in progress` (a slice has
landed), `waiting on <what>` (blocked by something the next session cannot
do: a decision, CI, a push), or empty (not started). A finished item's
row is removed, and the item moves to *Done*. An item whose remaining
work is waiting on CI or another repository counts as done for the rows
that wait for it, as long as what they need from it has landed.

Things to know:
- **Judge each item against a commit, not a file.** On the machine you
  measure on, `zig build bench-compare -- a6d8e34` compares the working
  tree with the last commit before 0.6. Startup times (P1) are new after
  `a6d8e34`, so compare those against `30b4f73` or later.
- **The spec is already written.** Every item implements sections of
  SPEC.md that exist; an item that finds the spec wrong changes it in the
  same commit, with the reason.
- **The code has the spec's shape where the feature exists.** What is
  still missing is listed in ARCHITECTURE.md §7 with the item that adds
  it. With `TaskPool` deleted, outside data reaches a frame only through
  sources: `zui_async`'s (A4) or the application's own (A3).
- **A core change reaches the backends by a pin.** zui-raylib,
  zui-sokol and zui-terminal pin zui by commit; develop them against this
  checkout with `--fork=../zui`, push zui, then move each pin with
  `zig fetch --save=zui`. The demo's `--measure-idle` and
  `-Dzui-tracy=true` check the idle budget and the trace there.
- **`bench --check-targets` checks §20.2's budgets,** including
  declaration for the box tree. Times vary by machine; instruction counts
  (`zig build counts`, R1) do not, and CI fails on more than 2% growth
  over the parent commit. They need Valgrind, so on Windows take them in
  a Linux container.
- **Item IDs are stable.** A letter names a series (R regression checks,
  A async, P profiling, C contracts, T text, S scale, H hosts, F the frame
  record and the wire, L layout, I interaction, G graphics, V visibility,
  M motion, E editing, K modules, D developer experience). A new item
  takes the next number in its series, and numbers are never reused, so a
  gap is an item that was merged or retired.

## How stages ship

- **Measure first.** Stage 1 gives every later change a trustworthy
  measure.
- **One breaking change, made once.** Stage 2 changes the shape of
  `Context`, the frame record, input and outside data together, and
  stage 3 adds the contracts on top, before any native host or wire
  format can freeze the old shapes. Every backend, `zui_testing` and
  `bench/` are updated in the same week, and the notes say what to
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

### I1. Drag and drop between elements

**Grounding.** I5 arbitrates every pointer by motion component past the
touch slop (`src/context.zig`, `pan` and `panOwner`), and `Gestures` had
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
  (`zui_widgets/zui_widgets.zig:290`); drag-to-scroll and drag and drop
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
`corner_radius`, but zui-raylib draws an image with its handle and bounds
alone (`src/root.zig:541`, `drawTexture(image.handle, bounds)`), and so
does zui-sokol (`src/renderer.zig:185`); zui-terminal has no images. The
renderer suite's reference scene declares an untinted, square image.

**Plan.** Each backend multiplies the tint into the image and rounds its
corners; the renderer suite's reference scene declares a tinted image
with a corner radius and checks a pixel inside it and one in a corner.
Then each backend's pin moves past L3.

**Done when:** zui-raylib and zui-sokol pass the extended renderer suite
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

zui-sokol sets the tint as the vertex color, which sokol_gl multiplies
into each texel, and draws a rounded image as a fan of textured triangles
from its center over the outline its rounded rectangles already trace,
each corner with its own radius. raylib multiplies a texture by a tint
too, but cannot round one, so zui-raylib draws a rounded image the same
way through rlgl, wound counter-clockwise on screen as raylib's culling
wants, with each corner's own radius, though its rectangles round all
four corners by the largest. A square image is drawn as before, one
quad, with the tint.

Both backends' pins move to this commit, from `cd3ddd6` (zui-raylib) and
`ad90c3a` (zui-sokol), with no change to their code beyond drawing
images; zui-terminal, which has no images, moves from `0268dbd`, and
zui-host to this commit and the new zui-sokol. Run against the zui
worktree with `--fork`, zui-raylib's renderer and host suites and
zui-sokol's renderer suite pass on Windows, and zui-raylib's old drawing
fails the extended suite with the message above; their CI runs the suites
on Linux under `xvfb-run`. zui core is unchanged, so its instruction
counts and times are too.

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
zui-raylib and zui-sokol draw images without them until C10.

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

zui-host (`39e3971`, pinning zui at `ad90c3a` and zui-sokol at
`68b29d1`, which moved only its zui pin) watches up to four directories
with their subdirectories: a thread per directory issues each overlapped
`ReadDirectoryChangesW` and publishes each change, waking the window for
the first since the last frame; `watch` returns once the first read is
pending, so no change after it is missed. Tests against a hidden window
see files added, written, renamed, added in a new subdirectory and
removed, each within 2 s, and a missing directory and a fifth watch
fail.

The demo is zui-host's `zig build theme`: a window in the colors of a
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

What remains: `zui_debug` (V1) reloads its own themes and assets this
way; the demo is a zui-host example rather than zui-sokol's tour, whose
working tree another session is changing.

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

The demo: zui-host's `zig build remote -- --check tour.bmp` starts
zui-sokol's tour, unchanged, in a second process on the wire host and
renderer, listening on a loopback port it prints, and draws it in a
window of the Windows host with zui-sokol's renderer through a client.
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

The demo: in zui-sokol's tour at `ed00845`, declared headlessly with
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

`zui_wire/tests.zig` round-trips every `Event` and `EnvironmentChange`
kind, every delivery of `zui_async` and one holding a pointer that sends
a number instead, and every command kind whole and as changes; checks
that a key frame lets a reader join, that a message beyond the decoder's
capacity fails, that other fonts and other versions are rejected; and
encodes a live session whose decoded frames are the frames drawn and
whose decoded records replay to the same commands. Compile-error tests
pin a delivery and an `ImageHandle` holding a pointer, `zuiSerialize`
without `zuiDeserialize`, and a wrong `zuiFingerprint`; `zig build check`
encodes and decodes a record and a frame on every target.

Measured on zui-sokol's tour at `ed00845`, declared headlessly as its
`test-tour` does, with real fonts: 120 frames on each of its ten screens
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
  semantics stay with the context; the inspector over the wire (V1) adds
  what it needs then.
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

`src/tests/relay.zig` relays a four-frame session (a click with typed
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
with a renderer that measures. zui-sokol's tour measures with
`zui_sokol.Text`, a separate type its renderer holds a pointer to, so
H2 ran it on zui-host under a hand-written loop.

**Plan.** Let the application name its text contract, keeping "the
renderer measures" as the default, with exact, pinned compile errors.

**Done when:** zui-host's `tour` step runs zui-sokol's tour through
`zui_app.run`, `zui_app`'s tests cover both cases, and zui-raylib's demo
builds unchanged.

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
  when their `init` is called. zui-host's `Host.init` reads
  `forced_scale` and `system_material_unavailable` from itself, which
  under `zui_app` had been undefined.

zui-host (`34ce8cb`, pinning zui at `b2b3574` and zui-sokol at
`ed00845`, which moved only its zui pin so the two agree) runs the tour
with `examples/tour.zig` now `zui_app.run(TourOnHost, ...)`:
`TourOnHost` names the host, the renderer and `zui_sokol.Text`, and
passes each step to the tour's own `App`; a small `SokolRenderer`
opens zui-sokol's renderer with `initForSurface` and times each submit
for the tour's strip, since zui-sokol's `Renderer.init` predates
`zui_app` and its working tree is being changed by another session. The
tour visits every screen (`--frames 300 --cycle 30`, diagnostics ok), its
screenshot shows the dark theme `zuiRecord` applied, and in ReleaseSafe
on the reference machine Layout Lab idles at 0.0, 31.3, 15.6 and 0.0 ms
of CPU over 10 s with 0 frames and 0 wakes; Welcome at 0.0 ms with its
11 heartbeat frames. zui-raylib's demo, tests and suites build and pass
against this commit unchanged. Nothing in the core changed, so there is
nothing to count.

Decided here:
- **The text contract under `zui_app`** is the renderer by default, or
  the application's `pub const Text`, which `zui_app` owns.
- **The application's part of the record** is `zuiRecord`, after the
  host's poll: the zoom is the application's (SPEC.md §16.3), and the
  host converted this poll's events at the zoom then on screen.

What remains: zui-sokol's `Renderer` could take `zui_app`'s
`init(self, surface, text)` itself, which would retire zui-host's
`SokolRenderer`; that waits for zui-sokol's working tree to settle.

### H8. The desktop showing through the window

`zui.SystemMaterial` (`none`, `window`, `transient`) in
`WindowOptions.material`, passed by `zui_app.Options.material`, and
`Environment.system_material`, the host's answer on this machine, an
environment change like every other (`50430d8`). zui-host's Windows host
(`5c33514`) declares `system_material`: it asks DWM for the backdrop
(`DWMWA_SYSTEMBACKDROP_TYPE`, Mica or Acrylic), extends the frame over the
client area and paints it black, which is transparent there, and reports
`system_material` (the backdrop taken and transparency effects on) and
`reduced_transparency`, again when the settings change.
`Host.system_material_unavailable` makes it behave as Windows 10, which
refuses the attribute.

The renderer clears to transparent and must keep its alpha. Windows
ignores the alpha of an OpenGL window and of a Direct3D swapchain made for
a window: over Acrylic's #545454, an opaque #2d2d2d card showed #818181,
the backdrop added under every pixel. So zui-sokol's renderer (`b138784`)
now draws into a `win32` window with D3D11, its default backend, through a
swapchain DirectComposition composes into the window with premultiplied
alpha, and its sokol_gl pipeline writes alpha, which sokol_gl does not by
default. sokol_debugtext writes 0 between a glyph's strokes, which let the
backdrop through each glyph's cell over a card, so when the surface
composes alpha every rectangle and border is drawn again into the alpha
channel after the text, with MAX blending.

`zig build material` in zui-host declares a root without a background
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
  DirectComposition on Windows; zui-sokol's OpenGL path stays for
  `-Dgl=true` and its renderer suite, and does not show the material.

What remains, and where it went:
- **Windows 10 was not seen:** the fallback there is the path forced by
  `system_material_unavailable`, where the attribute's refusal is the only
  difference; this machine is Windows 11.
- **A light theme and a second monitor** were not seen either; the
  machine is in dark mode.

### H2. The Windows host

[zui-host](https://github.com/AaronJClausen/zui-host) (`dc57eae`,
pinning zui at `d9d279e` and zui-sokol at `78ba9ad`), created here, one
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

zui gained what such a host reports and the record could not carry
(`d9d279e`): `Event.files_dropped` (`zui.FilesDropped`, paths copied
whole into the new `limits.max_dropped_path_bytes`, `ui.filesDropped()`,
`RecordBuilder.appendFilesDropped`) and `Event.lifecycle`
(`zui.Lifecycle`, `ui.lifecycle()`). `zig build counts` against `638080d`,
in a local Docker container: declaration +1 instruction in every
scenario, `endFrame` unchanged.

zui-sokol's renderer (`88d400d`, `78ba9ad`) draws into a `win32` surface
when built with OpenGL (`-Dgl=true`): `Renderer.initForSurface` makes the
window's OpenGL 4.3 core context through WGL and sets sokol_gfx up on it
without sokol_app, and `zuiSubmit` presents with vsync. A D3D11 build does
not declare the surface, so pairing it with the host fails to compile.

It passes C3: `expectHostConforms` against a hidden window, with a
harness that sends the messages Windows would, and ten more tests (DPI
changes, text, the wheel, dropped files, the session ending, Ctrl+C, the
clipboard, requests). The demo is zui-sokol's tour, whose application
zui-sokol exports as `zui_sokol_tour` and zui-host runs unchanged under
its own six-line loop; under sokol_app it runs as before (`test-tour`
passes). Measured on the reference machine in ReleaseSafe with
`--measure-idle` on the Layout Lab screen (heartbeat off): 15.6, 15.6,
31.3 and 62.5 ms of CPU over 10 s, 0 or 1 frames and 0 wakes; the Welcome
screen, which animates once a second, 15.6 ms and 10 frames. A screenshot
through the compositor (`--screenshot`) shows the tour drawn. zui-host's
CI checks the format, runs the tests and the host suite on GitHub's
Windows runner in Debug and ReleaseSafe, and cross-compiles from Linux for
x86-64 and ARM64 Windows, which found a function-pointer alignment that
only ARM64 enforces in zui-sokol's WGL code (`78ba9ad`).

Decided here:
- **The demo for a native host is zui-sokol's tour,** not zui-raylib's
  demo: raylib owns its window and cannot draw into another, so the
  application that runs unchanged across hosts is the one whose renderer
  can. The tour runs under a loop written by hand, not `zui_app`, because
  `zui_app` gives the context the renderer as its text contract and
  zui-sokol's text contract is a separate `Text`.
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

zui-raylib (`2fe41eb`, pinning zui at `cd3ddd6`) has `zui_raylib.Host`,
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
`src/conformance.zig` runs `expectHostConforms` beside the renderer
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
tests of `src/tests/hosts.zig` moved into the suite. `zig build check`
instantiates both suites on every target.

Each backend has `src/conformance.zig` and a `conformance` step, which
its CI runs (README.md's *Conformance suites* is the recipe):
- **zui-terminal** reads each pixel as the cell covering it, and passes
  with no tolerance; its `test` step runs the suite too;
- **zui-raylib** draws into a render texture of a hidden window and reads
  it back with `LoadImageFromTexture`; on Linux CI under Xvfb;
- **zui-sokol** runs the suite in a sokol_app window's first frame,
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

A test host in `src/tests/hosts.zig` runs the loop of SPEC.md §6.1 with a
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

zui-raylib, zui-sokol and zui-terminal are renderers: each has a
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

zui-raylib (`67d1cc1`), zui-sokol (`cb9d03e`) and zui-terminal
(`039b7fe`) pin zui at `2df48f7` and build without `--fork`; each
one's CI passes on Linux, Windows and macOS. In each:
- `Platform` is `Text`, the text contract, set by the backend's
  `config()`: `zuiMeasure` with a `MeasureKey`, counting the letter
  spacing after every glyph, and text commands drawn with their spacing
  (per glyph in sokol_debugtext, to the nearest cell in a terminal);
- the loop builds a `FrameRecord`, takes `endFrame()`'s frame, and waits
  as `nextFrame` says;
- the frame's cursor request is applied where the library has cursors
  (raylib, sokol_app), and focus changes are `window_focused` events.

The demo's thumbnails are a `zui_async.KeyedLoads` source: declaration
asks for the keys of the rows near the visible area, the loader starts
each load as its own task on the application's `Io` after `endFrame`, and
keys unread for 30 frames are abandoned (34 of 98 in a scripted fast
scroll). Measured in zui-raylib:
- **0% CPU idle.** `--measure-idle` has the demo read its own CPU time
  at two frames it requests 10 s apart. On Windows (i9-10900K,
  ReleaseSafe): 0.0 ms in the thumbnail grid and the settings view,
  31–47 ms in the documents view, with 1 frame (the measurement's own)
  and 0 wakes in each window; Windows counts CPU in 15.6 ms ticks. On
  CI's Linux runner, under Xvfb: 24.0 ms for the grid, 1 frame, 0 wakes.
- **One wake for 100 loads.** A test in `examples/thumbnails.zig` asks
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
recording tracer in `src/tests/support.zig`, and a test that one frame
produces every zone, each nested in `begin_frame` or `end_frame`;
`zui_tracy`, with Tracy as a lazy dependency linked by
`-Dzui-tracy=true`, tested with Tracy's client on all three systems (in a
MinGW build Tracy's callstacks are off: with them the process exits with
code 9 after Tracy shuts down); the profiling guide, in README.md's
*Profiling*.

`zig build counts` without a tracer was identical to the instruction in
every scenario, against `994a631`, in a local Docker container.

The trace of the demo was captured headlessly: zui-raylib's demo built
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
loads causing one wake, were done in zui-raylib by C8.

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

`zig build counts` runs each single-threaded scenario of `bench/` in a
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
itself calls nothing faster or slower.

### P1. Startup benchmarks

`init`, `initBuffer` and first-frame scenarios, in `--json` and
`--compare`. With the library at `a6d8e34`, the fastest samples were:

| Scenario | Fastest |
|---|---|
| `init`, default config (4.63 MiB) | 74.6 µs |
| `initBuffer`, default config | 10.0 µs |
| first frame, Documents view | 30.3 µs (steady: 9.9 µs) |
| first frame, 1,000 texts | 230.0 µs |

The demo's cold start moved to C4, because the demo lives in zui-raylib.

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

**Status.** Done in this repository.

**Spec.** §4, §5, §9.4, §16.1.

### S1. The frame record's parameters: time, scale and zoom

**Grounding.** `Platform.scale` only snaps command bounds
(`src/emission.zig:32`). Nothing lets an application zoom its UI. Time
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
- `Input.buttons` is the state at poll time (`src/context.zig:902`), so a
  press and release between two polls is never a click. zui sleeps until
  input arrives, which makes that likely, and a touch tap usually
  vanishes.
- There is one pointer: one `press_target` and one `hover_chain`
  (`src/interaction.zig:181`).
- `Key` has no letters (`src/interaction.zig:8`), so Ctrl+S cannot be
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

**Done when:** nothing in this repository or the backends names a task
pool.

**Status.** Done; the backends and the demo's loads moved off it in C8.

---

## Stage 3: the contracts

Done: C1, C2, C3, C7, C4 and H1 are in *Done*. Lowering comes with
stage 8's commands; zui-sokol and zui-terminal remain renderers without
a host of their own, and zui-sokol's renderer gains a native surface
with H2.

---

## Stage 4: a native host

Done: H2 and H8 are in *Done*.

---

## Stage 5: the wire

F1, feeds, is retired: sources (A3) are the mechanism for outside data.
Done: F2, F3, F4, F5 and F6 are in *Done*.

---

## Stage 6: text and layout

Done: T1, T2, L8, P4, P5, T4, L1, L2, L3, L4, L6, L7 and C10 are in
*Done*.

---

## Stage 7: gestures

Done: I5 and I1 are in *Done*.

---

## The data-oriented design audit

`DOD-AUDIT-2026-11-09-5b032b7.md` found the costs next to the layout
sweeps, in paths no benchmark ran until `db4ea4d` added scenes for them:
floating layers, ids on every element, and a pointer pressing. The owner
put its findings ahead of stage 8. P6, the layer sort, and P7, the id →
rect table, are in *Done*. Its
finding 7, render commands that copy their text style, is not taken: it
changes every renderer, and no profile shows renderer bandwidth.

Each item is judged by `bench-compare` against its parent, with turbo
off, and by `counts`; one that costs more elsewhere than it saves in its
scene does not ship.

### P8. One hit test per press

**Grounding.** One primary `pointer_down` (`src/context.zig:1354-1369`)
runs `Results.topmostAt` (`src/interaction.zig:209`) in `refreshHover`,
`longPressOwner` and `recognizerAt`, and `startZoom` a fourth time when
another contact is down, each at the same point over the same results.

**Plan.** Hit-test once per press and hand the region to each.

**Done when:** `4096 interactive, pressed` runs fewer instructions in its
declaration by `counts`, and no scenario is slower.

### P9. Wrapped lines kept with the string cache

**Grounding.** `wrapTexts` (`src/layout.zig:650`) wraps every text wider
than its box from its bytes every frame (`wrapLines`, `src/text.zig:597`),
though a warm hit in the string cache already proves the text unchanged.
The warm text wall's `endFrame` is about 50 µs more than the single-line
wall's, which also counts emitting the extra lines.

**Plan.** First measure the `.wrap_text` zone in the warm text wall; if
it is under about 10 µs, retire this item. Otherwise keep the line breaks
of texts with few lines, and the width they were wrapped at, beside the
cached string, and copy them on a hit at the same width.

**Done when:** warm text is faster by `bench-compare`, cold text no
slower, and the string cache's growth is recorded against SPEC.md
§20.2's memory.

### P10. Cache probes over keys alone

**Grounding.** `LruTable` (`src/text.zig:184`) keeps each key with its
value, so a probe window of 8 steps over 104-byte string entries can touch
8 cache lines, and `measureTexts` (`src/layout.zig:38`) resolves one text
at a time.

**Plan.** Only after a profile of `1000 new strings` and the cold text
wall points at the probes: keys and ages in arrays of their own, and the
next texts' keys prefetched.

**Done when:** the cold scenes are faster by `bench-compare`, warm text
no slower; or retired with the profile that shows the probes are not the
cost.

### P11. Flat child lists

**Grounding.** `Frame.Children.next` (`src/context.zig:487`) and
`FlowChildren` (`src/layout.zig:76`) step to each sibling through
`subtree_end`, one dependent load at a time.

**Plan.** Only after `perf` attributes cycles of `4000 children of one
parent` to these walks: child indices in one array, built after
declaration from `child_counts` and a prefix sum. P4 recorded that
reshaping these passes cost 3% to 17% before.

**Done when:** the wide tree is faster by `bench-compare` and the box tree
no slower; or retired with the profile.

---

## Stage 8: effects

- **G1. Gradients, shadows and glow,** as optional commands, interpolated
  in OKLab.
- **G2. Backdrop blur** of zui's own content, lowered to a tint.
- **G3. Transforms,** applied when painting only; hit testing inverts
  them.
- **G5. Materials,** the renderer's own typed `MaterialHandle`.
- **G6. HDR and wide gamut:** `Config.Color = zui.ExtendedColor`, clamped
  for renderers without `zui_extended_color`; headroom from the
  environment; the output format negotiated through `Surface`.

C1 generated the optional commands' variants; each item here adds the
declaration that produces its command and the lowering for renderers that
do not declare it, and the first adds `Diagnostics.lowered`.

**Done when (each):** snapshot and lowering tests; the renderer suite's
reference scene declares it, and one renderer that declares the command
passes the suite; for G3, an interaction test clicks a rotated button; for G6, the
Windows host shows HDR white brighter than SDR white.

**Spec.** §13.1, §13.3, §16.4, §18.

---

## Stage 9: seeing the UI

### V1. `zui_debug`

**Plan.** An inspector over `Frame.inspect`: the element tree, the
hovered element and its configs, diagnostics, lowerings and fallbacks,
and a performance overlay from the tracer. Its themes and assets reload
when their files change, through the host's file watch (F6): a
`Stream(zui.FileChange)` among its sources, read by the loader into a
source of the parsed theme, as zui-host's `theme` example does.

**Done when:** `zui_testing` drives it over the Documents view, and the
demo toggles it with a key.

**Spec.** §19.7.

### V2. Semantics and accessibility actions

**Plan.** `Element.semantics`, and `Frame.semantics()` filled with each
node's role, label, value, state and actions, behind
`features.semantics`, which C7 added with `semantics()` gated and empty;
actions arrive as events and answer through the intent queries.

**Done when:** a widget test checks the list for each control, the
Windows host bridges it to UI Automation, and with the feature off, R1
counts are unchanged.

**Spec.** §13.5.

### V3. Safety sweeps

**Plan.** The invariant checks that read only a `Frame`, at the end of
`endFrame`, behind `features.safety_sweeps`, which C7 added.

**Done when:** the randomized tests run through it, a debug demo runs
with it on, and with the feature off, R1 counts are unchanged.

**Spec.** §20.1.

### V4. The demo in a browser

**Plan.** The demo streaming over the wire (F5) to a thin browser client,
published from CI.

**Done when:** the demo runs at its native frame rate in a browser.

---

## Stage 10: reach

- **H3. macOS** (Cocoa; vibrancy for H8).
- **H4. Linux** (Wayland, then X11; KDE blur where offered).
- **H5. Web** (a canvas surface; `tryBeginFrame`, since it cannot block).
- **H6. Services:** clipboard, notifications, file dialogs, opening URLs,
  native menus, each an optional host declaration.
- **H7. Window decorations:** native by default; a custom title bar uses
  chrome regions so the OS still moves, resizes and snaps the window.
- **H9. Many windows:** one `Context` per window, with sources published
  into each.

**Done when (each):** the host passes C3, and the demo runs on it
unchanged.

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
- **K4. `zui-themes`:** skins for Windows, macOS, GNOME and KDE.
- **K5. The skin contract:** `Widgets(Ui, Skin)` and `zuiStyle`, so a
  theme pack restyles every widget without forking it.
- **D1. `zui-examples`** and a template project.
- **D2. Samples:** a settings screen with `zui_reflect` and ZON, a data
  feed, a multi-window tool, a remote session.
- **D3. A developer-experience audit:** a new user builds each sample from
  the docs alone, and every place they get stuck becomes an item.
- **D4. A profiling guide** over P2's tracer.

**Done when (each):** `zui_testing` coverage; IME works on Windows.

**Spec.** §19.2, §19.8, §19.9.

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
| Dividers (L3) | `Border.between_children`, emitted as `rectangle` commands in the border's color, so no renderer breaks; centered in the gap, spanning the element inside its widths; inside the element's clip, after its children and before its border; a border of zero widths emits no `border` command |
| Images' tint and corner radius (L3) | declared on `Ui.Image` and carried by the `image` command with defaults (white, square), so existing renderers and their tests still compile; drawing them is the backends' (C10) |
| Drawing images' tint and corner radius (C10) | the tint multiplies the texels as the vertex color; a rounded image is a fan of textured triangles from its center, each corner with its own radius, in zui-raylib too, whose rectangles keep raylib's one radius; the renderer suite checks the tinted color at the image's center and the background just inside two of its corners |
| Natural sizes (L2) | `Ui.Image` is the declaration's type, apart from the `image` command; a natural size is the content inside the padding, may shrink in a narrower parent, and gives the height its proportions unless the height has a rule of its own |
| A grow basis (L1) | a rule, `grow_from_min`, not a `basis` field, which would cost declaration; never narrower than the content's minimum, the rest shared by weight |
| Config references (L8) | pointers in element storage, the default layout one constant; an element's own `layout` or `decoration` replaces the style's whole |
| Budgets | as in SPEC.md §20.2, including warm text < 120 µs and declaration < 55 µs |
| Where the contracts live | in the `zui` repo |
| Native hosts | one `zui-host` repo, one directory per OS |
| Who orchestrates | the host, through one contract; adapters for libraries that own their window (H1) |
| Signals | lifecycle events; uncatchable signals are not representable |
| Input | an ordered event log with host instants, many pointers (I4) |
| Gesture arbitration | elements declare what they accept; one rule, by motion component (I5) |
| A custom recognizer's decision lands a frame late (I5, open decision 1) | accepted: `claim` and `decline` apply at the next `beginFrame`, and a declined pointer is arbitrated over all its motion since the press, so nothing is lost; the lasso against a map's pan passes with it |
| Custom recognizers (I5) | an element with `custom` holds each pointer pressed on it from every built-in gesture until it decides; `pointerEvents(id)` is an iterator, `zui.PointerEvents`, over the frame's events of the pointers it holds; a claimed pointer takes the press from what it pressed and is never a tap; one released undecided is a tap; the lasso is `zui_widgets.Widgets.lasso`, a pen drawing and every other pointer declined |
| Momentum (I5) | a pan released faster than 50 units a second over its last 0.1 s coasts on its axes, slowing exponentially with a time constant of 0.325 s, moved to each record's `now` before its events through the pan's path; it stops below 10 units a second, at a scroll container's end, under a press, or when its element was not declared; it asks for frames 1/120 s apart; at most `max_input_contacts` elements coast, and a fling beyond them is reported on that limit |
| Long press and double tap (I5) | timed from the events' instants against the record's `now`, setting the next frame's deadline: a long press after 0.5 s held within the slop, which is not a tap; a double tap within 0.3 s of the first tap's release, whose single tap is clicked only when that window passes; `doubleTapped(id)`, which SPEC.md lacked; `navigated` returns `zui.NavigationDirection`, since `Direction` has no up or left; `dismissed` while the element or one in its focus scope is focused; `contextRequested`, `dismissed`, `adjusted` and `navigated` need no feature, `doubleTapped` needs `features.gestures` |
| Zoom (I5) | a second pointer pressed while another is down, both inside an element that accepts zoom, makes the pair zoom the innermost such element, taking both pointers from what they pressed or panned; `scale`, `rotation` (clockwise) and the centroid's `translation` are summed over the frame, `pivot` is where the centroid ended; the pointer left when one lifts pans the element if it pans |
| Pans (I5) | past a touch slop of 8 layout units from the press, the axis locks to the larger component and the innermost region under the press that pans on it with room to move takes the pointer until it lifts, both axes if it pans on both; any other element it pressed loses the press; a scroll container pans on its scrolled axes with touch and pen only, since the mouse has the wheel, unless it declares `pan`, which takes every pointer; declaring a gesture makes an element interactive; `Element.gestures` is ignored without `features.gestures` rather than failing to compile, so widgets declare gestures for every context; `manipulation` reports pans and the wheel, scroll containers included, `translation` moving content with the pointer |
| Drag and drop (I1) | a source declares `Gestures.drag` and takes a pointer past the slop on the axes no region around it pans on for that pointer, after any region inside it that pans; `startDrag` gives the payload, in the state table under the source as `DragPayload(T)`, or starts the drag with a pointer still pressed on the source, which is how a long press or a recognizer lifts it; the payload is kept while the drag lasts, the source may go undeclared; a target is any element with a hit region the hit test at the pointer passes through; `draggedOver`, which SPEC.md lacked, shows a drop target before the release; a drag released in its starting record, before it had a payload, or cancelled, drops nothing |
| Custom gestures | code in declaration over `pointerEvents` and `state`, not a registry |
| Comparing two commits | each commit's own benchmarks, alternated, judged by the middle half beyond 2% (R2) |
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
| Reading pixels back (C3) | optional: without `pixel` the renderer suite checks only that each frame draws without an error; every backend today reads back, zui-sokol through OpenGL's `glReadPixels`, so its suite renders with OpenGL on every system |
| A lost wake in the host suite (C3) | bounded: after `lost_wake_ns` the suite wakes the host every 50 ms until the wait ends, and fails |
| Warm benchmark scenes (T2) | sized to hold every string (`string_cache_entries = 2048` for 1,000 texts): 1,000 strings in 1,024 entries overflow eight-entry probe windows, and about a fifth of them missed every frame |
| How `zui_app` knows the host and renderer (C4) | the application declares `pub const Host` and `pub const Renderer`, plain names like a renderer's payload types; `Ui` is read from `zuiDeclare`'s parameter |
| How `zui_app` opens them (C4) | the host's `init(self, io, zui.WindowOptions) !void` and `deinit`; the renderer's optional `init(self, surface) !void`; `zui.WindowOptions` is core vocabulary, since every host opens windows with it and H9 will open many |
| When a renderer may submit on another thread (C4) | when it declares `zui_render_thread = true`; raylib and OpenGL-bound renderers leave it out, and `zui_app` reports why it submits on the UI thread |
| How `zui_app` reports (C4) | `Options.notify`, a plain function given each notice once, logging through `std.log` by default; tests record them |
| The application's text contract under `zui_app` (C4, C9) | the renderer, through `contextConfig`, or the application's `pub const Text`, which `zui_app` makes and passes to the context and the renderer's `init`; any other `Text` is a compile error |
| The application's part of the record (C9) | `zuiRecord(app, record)`, after the host's poll and before `beginFrame`: the zoom, and events the application makes itself |
| What `init` finds under `zui_app` (C9) | each field with a default holds it, so a host's settings made on its type (`forced_scale`) survive; the rest is undefined |
| How the raylib host waits (H1) | in GLFW, past raylib: `glfwWaitEventsTimeout` until an instant, `glfwWaitEvents` on event, and callbacks in front of raylib's to tell input from a spurious OS event; raylib's `EndDrawing` only presents and polls |
| How a host harness posts events raylib cannot inject (H1) | `Host.script(sample)`, input for one poll instead of raylib's; the demo's screenshots use it too |
| The raylib renderer's text contract (H1) | the renderer itself, as SPEC.md §16.1 expects of most renderers, so `zui_app.contextConfig` gives it to the context |
| The first renderer on a native surface (H2) | sokol_gfx, with OpenGL through WGL: zui-sokol's renderer makes the window's context itself, without sokol_app |
| The demo on a native host (H2) | zui-sokol's tour, unchanged, through `zui_app` since C9; raylib cannot draw into a window it does not own |
| A native host's loop (H2) | the Windows host runs its message loop on a thread of its own, so modal move and resize loops never stop frames |
| Whether a system material shows (H8) | `Environment.system_material`, reported by the host, so it is in the record and replays |
| A renderer over a system material (H8) | composes with alpha: zui-sokol draws a native window through a DirectComposition swapchain, since Windows ignores an OpenGL or window swapchain's alpha |
| A terminate request (H2) | delivered in one record; the host's next `zuiPoll` returns false |
| The clipboard service before H6 (H2) | `zuiClipboard`, a type with `read(host, buffer)` and `write(host, text)` |
| What a relay listener gets (F2) | the record as applied: the events kept, and deliveries from `zuiDelivery`, filled in the reservation, or a replay's own |
| A frame on the wire (F3) | number, parameters, host requests and commands, as changes from the last frame written; hit regions and semantics stay with the context |
| A wire message beyond the decoder's capacity (F3) | `error.CapacityExceeded`, since a delta cannot be applied in part |
| Serializing a payload with pointers (F3) | `zuiSerialize(self, serializer)` and `zuiDeserialize(deserializer)`, taking the wire's types as `anytype`, so a source never imports `zui_wire` |
| Replay in tests (F4) | `Recording(Ui)`, a relay listener, and `Driver.replay(app, declare, record)`, one frame per record |
| What the loader changes between frames (F4) | delivered by the source when relayed, so a replay without a loader shows it: `KeyedLoads` relays the keys loading and the abandoned loads that finished |
| How a remote client joins (F5) | `zui_wire.Host` and `Renderer` where the application runs, over a stream the application attaches; `zui_wire.Client` over any host and renderer where it draws; a `wire` surface kind between the two halves |
| Time on the wire (F5) | the client's host's clock, counted on by the wire host between records, so records are sent only for events or a new viewport or scale |
| Watching files (F6) | `zuiFileWatch.watch(host, directory, sink)` until `deinit`, subdirectories included; the host publishes `zui.FileChange`s into a `zui.FileChangeSink` made from a source the application chooses, and the loader reads the files |

### Open

Each is planned with its first option. SPEC.md §22 has those that change
the spec.

1. **Physical keys.** Planned: logical keys plus the opaque scancode.
2. **V4, a web renderer or a thin client over the wire?** Planned: the
   wire client first, since F5 builds it anyway.

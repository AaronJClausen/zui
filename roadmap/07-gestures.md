# 07-gestures: Gestures

Stage 7 of SPEC.md §21: intents, gesture arbitration, momentum, custom
recognizers, drag and drop.

**Done when:** the nested-gesture scenes: a carousel in a list, a pinch
starting on a list inside a map, a lasso module against a map's pan.

**Status.** Done.

## Items

| Item | Status |
|---|---|
| `07-gestures:01-gesture-arbitration` Gestures: arbitration, intents, momentum, custom recognizers | done |
| `07-gestures:02-drag-and-drop` Drag and drop between elements | done |

---

## 07-gestures:01-gesture-arbitration — Gestures: arbitration, intents, momentum, custom recognizers

**Grounding.**

- The slider drags with `pressed` and `pointerLocal`
  (`core/zui_widgets/zui_widgets.zig:290`); drag-to-scroll and drag and
  drop want the same pointer, and nothing decides between them.
- Routing by gesture kind fails: a vertical drag on a horizontal
  carousel inside a vertical list goes to the carousel, and a pinch that
  starts on a list inside a map goes to the list.

**Plan.** As SPEC.md §11.3–§11.4: accepted gestures in hit regions, one
rule by motion component, opt-in delays, intents, momentum in the state
table, and custom recognizers over `pointerEvents`, `claim` and
`decline`. All of it behind `features.gestures`, which
`03-contracts:04-features` added with `manipulation`, gated and null
until this item fills it; each new gesture query is gated the same way,
and `Element.gestures` is ignored without it, so that widgets declare
gestures for every context.

**Done when:** interaction tests cover a button in a list in a zoomable
map, a carousel in a vertical list, a pinch that starts on the list, a
slider in a drag-scrolled list, a long press, a double tap next to a
single tap, a flick within one frame, and a lasso written as a module
function against the map's pan; and with the feature off,
`01-measure:03-instruction-counts-in-ci` counts are unchanged.

**Spec.** §11.3, §11.4.

**Status.** Done, in five slices, each with its tests and with
`01-measure:03-instruction-counts-in-ci` counts unchanged with the
feature off:

1. *Pans* (done): `zui.Gestures` with `pan`, stored in hit regions; the
   one rule by motion component past the touch slop, with scroll
   chaining; scroll containers that pan by touch and pen; presses
   cancelled by a pan; `manipulation`'s translation from pans and the
   wheel; the slider keeping a horizontal drag.
2. *Zoom* (done): `zoom`, two-pointer scale, rotation and pivot to the
   innermost region that accepts it, and `Driver.pinch` (from
   `02-frame-record:05-input-event-log`): a button in a list in a
   zoomable map, a pinch that starts on the list.
3. *Timers and intents* (done): `long_press` and `double_tap` with their
   deadlines in `nextFrame` (from `02-frame-record:08-next-frame`),
   `contextRequested`, a double-tap query, `dismissed`, `adjusted`,
   `navigated`: a long press, a double tap next to a single tap.
4. *Momentum* (done): velocity from the events' instants, momentum in
   the state table under the element, its deadline in `nextFrame`: a
   flick within one frame.
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
each panning their own, and `zui_testing.Driver.pinch`, which
`02-frame-record:05-input-event-log` left waiting. `zig build counts`
against `397ce28`: the same as slice 1, with the feature off and on,
since only input changed.

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
feature off, unchanged from slice 1; with it on, every declaration
within +8 instructions but the documents view's, +0.40% (33,453), and
every `endFrame` as in slice 1. `zig build bench -- --check-targets`
meets every budget over three runs: the box tree declares in 50.3 to
51.1 µs and lays out and emits in 91.9 to 93.9 µs, warm text in 94.4 to
95.5 µs.

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
`397ce28`: with the feature off, unchanged; with it on, every
declaration within +16 instructions but the documents view's, +0.42%
(33,461), and every `endFrame` as in slice 1.
`zig build bench -- --check-targets`, over four runs, met every budget
in the last three: the box tree declares in 51.0 to 51.3 µs and lays out
and emits in 91.1 to 92.0 µs, warm text in 98.2 to 98.4 µs; the first,
right after the build, ran every scenario slower alike and missed the
declaration budget at 68.8 µs, as first runs here often do.

Slice 5: an element that declares `custom` holds every pointer pressed
on it: no pan, zoom or long press of its own or its ancestors' starts
while it is undecided, and `ui.pointerEvents(id)` returns the frame's
events of those pointers, in order, through a `zui.PointerEvents`
iterator. `ui.claim(pointer)` makes the pointer the recognizer's alone
from the next `beginFrame`, taking its press from whatever it pressed;
`ui.decline(pointer)` gives it back, and that `beginFrame` arbitrates it
over all its motion since the press, so nothing moved meanwhile is lost.
A pointer released undecided is a tap. Open decision 1, that a decision
lands a frame late, is taken as planned: the lasso scene passes with it,
the finger's pan arriving whole one frame after its press. The lasso is
`zui_widgets`' `lasso(ui, id, &path)`, written on the public API alone:
a pen pressed on the element draws a `zui_widgets.Lasso` path in the
application's memory, and every other pointer is declined, so fingers
pan and zoom the map. `pointerEvents` without the feature fails with
`"zui: pointerEvents() needs Config.features.gestures = true"`. Tests: a
lasso drawn by a pen over a map that does not move, then a finger that
pans the map by its whole motion; in the core, a recognizer holding a
list off until it declines and the list then scrolling by everything the
pointer moved, a claimed pointer taking a button's press and never
scrolling the list, and a pointer released undecided tapping. Looking at
every contact at each `beginFrame` cost depth 64's declaration 0.79%, so
a flag says whether a decision is waiting. `zig build counts` against
`397ce28`: with the feature off, every scenario within ±2 instructions,
as for every slice; with it on, every declaration within +19
instructions but the documents view's, +0.43% (33,320 to 33,464), every
`endFrame` within +2 but the documents view's, +0.49% (61,189 to
61,489). `zig build bench -- --check-targets` meets every budget over
four runs: the box tree declares in 51.1 to 52.4 µs and lays out and
emits in 92.5 to 93.6 µs, warm text in 91.1 to 92.6 µs.

The whole item, by `zig build bench-compare -- 397ce28` (10 rounds):
layout and emission unchanged or faster (the box tree's −1.8%,
single-line text's −3.7%); declarations slower where they include
`beginFrame` and little else: warm and cold text's +5.6% and +5.2% (15.3
to 16.1 µs) on 19 more instructions of 106,521, the box tree's +1.9% on
102 fewer than slice 3 had, the documents view's +3.0%; the documents
view's first frame +4.2%. Instruction counts, which do not move with
code placement, are within +0.02% for every declaration but the
documents view's, so this is where `beginFrame`'s code now lands, as
`06-text-and-layout:06-line-break-segmentation` and
`06-text-and-layout:10-floating-options` found for warm text, not work
added.

## 07-gestures:02-drag-and-drop — Drag and drop between elements

**Grounding.** `07-gestures:01-gesture-arbitration` arbitrates every
pointer by motion component past the touch slop (`core/src/context.zig`,
`pan` and `panOwner`), and `Gestures` had two spare bits; SPEC.md §11.5
named `dragging`, `dropped` and `startDrag` and the payload's place in
the state table, but no element could declare `drag`.

**Plan.** `dragging`, `dropped` and `startDrag`, with typed payloads in
the state table, arbitrated by `07-gestures:01-gesture-arbitration`.

**Done when:** `zui_testing.Driver.drag` moves an item between two
lists, including out of a list that scrolls by dragging.

**Spec.** §11.5.

**Status.** Done, in one commit. `Gestures.drag` makes an element a drag
source: past the touch slop it takes the pointer on the axes no region
around it pans on for that pointer, after any region inside it that pans
on the axis, so a card in a list that scrolls vertically drags sideways
and scrolls the list vertically, and with the mouse, which scrolls a
list with its wheel, drags on both axes. The source is then neither
pressed by another element, clicked, scrolled nor zoomed.
`ui.dragging(id)` returns a `zui.Drag`: the pointer, its position and
its translation from the press. `ui.startDrag(id, payload)` keeps the
payload in the state table under the source as a type of its own,
`DragPayload(T)`, so it never shares a slot with the application's state
of `T`; called on a source whose press is still down but that nothing
drags, it starts the drag there, taking the pointer from any pan, zoom
or recognizer, which lifts a card after a long press. While a drag
lasts, `beginFrame` touches its payload's slot through
`StateTable.touch`, behind a flag, so the source may go undeclared.
`ui.dropped(id, Payload)` and `ui.draggedOver(id, Payload)` answer for
every region the hit test at the pointer passes through, and only for
the payload's own type. `draggedOver` was added to SPEC.md §11.5, since
a target needs to show it would take a drag before the release and touch
has no hover. The four need `features.gestures`, and `dropped` without
it fails with `"zui: dropped() needs Config.features.gestures = true"`;
a payload above 64 bytes fails with the state table's message, naming
the payload's type.

Tests: in the core, a card dragged sideways out of a list that scrolls
by touch, over the other list (`draggedOver`) and dropped on it; a
vertical drag on a card scrolling its list, and a tap clicking one; the
mouse dragging a card on either axis; a drop yielding its payload to the
list and the card under it and null to other types and lists; a drag
released in the record that started it and a cancelled one dropping
nothing; a payload given once outliving ten frames in which its source
is not declared; a long press and `startDrag` lifting a card that then
drags along its list. In `zui_testing`, `Driver.drag` scrolling a list
that declares `.pan = .vertical`, then moving an item out of it into a
second list and another back, the dragged item drawn as a floating
element with `capture = false`.

`zig build counts` against `8d75b8d`, in a local Docker container: with
the feature off, every scenario within −4 to 0 instructions; with it on,
as the benchmarks run, every declaration within +2 and every `endFrame`
unchanged. `zig build bench -- --check-targets`, over four runs, met
every budget in the last three: the box tree declares in 51.6 to 52.1 µs
and lays out and emits in 92.2 to 92.8 µs, warm text in 90.9 to 97.3 µs;
the first, right after the build, missed the declaration budget at 68.0
µs, as first runs here often do. The 32-bit tests (`-Dtarget=x86-linux`)
pass in the Linux container.

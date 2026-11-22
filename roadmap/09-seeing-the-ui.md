# 09-seeing-the-ui: Seeing the UI

Stage 9 of SPEC.md §21: `zui_debug`, semantics with accessibility
actions, safety sweeps, the demo in a browser.

**Done when:** the Windows host bridges semantics to UI Automation.

**Status.** Done.

## Items

| Item | Status |
|---|---|
| `09-seeing-the-ui:01-zui-debug` `zui_debug` | done |
| `09-seeing-the-ui:02-semantics-and-accessibility` Semantics and accessibility actions | done |
| `09-seeing-the-ui:03-safety-sweeps` Safety sweeps | done |
| `09-seeing-the-ui:04-demo-in-browser` The demo in a browser | done |

---

## 09-seeing-the-ui:01-zui-debug — `zui_debug`

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
read from a ZON file when the host's file watch says it changed, with no
allocation, through a `Stream(zui.FileChange)` and a `Latest` of the
theme among the context's sources, so a replay restyles without reading
a file (`389e497`). `zui_app`'s optional `zuiObserve(app, ui, frame)`
hook hands the application each frame on the UI thread before it is
submitted, and `zui_testing`'s driver runs the inspector over the
Documents view of `core/bench/scenes.zig`: a row per element, and the
sixth document under the pointer with its rectangle, flags and hovered
background (`676799c`).

The raylib renderer's tour (`6a12de7`) toggles the panel with F12, or
opens it with `--zui-debug`, observing frames only while it is open; its
tracer is `ZoneTimer(zui_tracy.Tracer)`, and its fallbacks list the
`Report` `zui_app` started with. Its theme does not reload there, since
raylib's host has no file watch. The tour's headless test opened the
panel with F12 over the Classic screen and checked it lists the frame's
elements with every limit held.

Measured: `core/src/` gained only `Frame.inspect`, which no frame calls,
so no hot path or instruction count moved. The hidden demo drew 480
frames across every screen with the panel open, every limit held; the
panel lists a row per element, so a Box Storm raised to 14,000 boxes
would exceed `max_elements` with it open and say so in its diagnostics.
The idle budget was not measured again, since the machine was not in
benchmarking mode; a closed panel adds one branch per frame.

## 09-seeing-the-ui:02-semantics-and-accessibility — Semantics and accessibility actions

**Grounding.** `Frame.semantics()` lists each node in tree order
(`core/src/context.zig:552-558`), in a slot beside its frame
(`:739-749`) that is emptied when the frame is released (`:731`). A node
has a `u64` id, the index of the node around it, a role, a label, a
value, untransformed bounds in layout units, a state and its actions
(`core/src/semantics.zig:120-134`). Parents always come earlier in the
list (`context.zig:1505-1516`), so any prefix of it is a whole tree. An
`action` event (`core/src/input.zig:240-242`) is answered by
`applyAction` (`context.zig:1822-1837`); a disabled element takes none.
`zui_app` hands the list to a host that declares `zuiSemantics`, on the
UI thread, after `zuiObserve` and before submission
(`core/zui_app/zui_app.zig:408`), and opens the window with room sized
from `Config.limits` (`:371-373`). `checkHost` checks the call's
signature from a table that `10-reach:04-window-decorations`'s chrome
regions can join (`core/src/contracts.zig:22`, `:124`). The Windows host
keeps one `accessibility.Bridge` per window
(`hosts/native/windows/host.zig:87`); `zuiSemantics` publishes into it
(`:336`), the window thread answers `WM_GETOBJECT` (`:580`), raises
events (`:576`) and disconnects at `WM_DESTROY` (`:482`), and runs in a
single-threaded apartment (`:389`). The bridge's snapshots, elements and
root are in `windows/accessibility.zig` (`Bridge` at `:28`, `publish` at
`:77`, `Element` at `:644`, `Root` at `:1117`); patterns are offered in
`patternProvider` (`:811`) and properties in `propertyValue` (`:832`), a
request is delivered by `request` (`:795`), and `announceChanges`
(`:141`) compares each node with its last `Summaries` (`:512`).

**Plan.** `Element.semantics`, and `Frame.semantics()` filled with each
node's role, label, value, state and actions, behind
`features.semantics`, which `03-contracts:04-features` added with
`semantics()` gated and empty; actions arrive as events and answer
through the intent queries. The host receives each frame's list through
an optional call, `zuiSemantics(window, nodes) SemanticsDropped`, which
`zui_app` makes on the UI thread between `endFrame` and submission, so a
render thread and `release` never race it. The host copies the list into
two snapshots it took room for in `init`, sized by
`WindowOptions.semantics`, and swaps them under a lock; UI Automation
reads the front through providers written as hand-made COM vtables, and
a request comes back as an `action` event through the host's inbox. In
slices:

1. **The contract, the tree and `invoke`** (core and `hosts/native/`):
   the contract and its compile error, `zui_app`'s call, notice and
   report, the host suite's `invoke` step, and on Windows the fragment
   root, an element per node with its name, control type, AutomationId
   (the id in hex), runtime id (`[UiaAppendRuntimeId, low, high]`),
   bounds in screen pixels and place in the tree,
   `ElementProviderFromPoint`, `GetFocus`, `Invoke` and `SetFocus` as
   actions, and focus-changed and structure-changed events raised on the
   window thread only while a client listens; `examples/accessible.zig`
   for Narrator.
2. **The control patterns and property events** (`hosts/native/`):
   `IToggleProvider` for checkboxes and toggles through `invoke`;
   `IExpandCollapseProvider` for a node whose `state.expanded` is set,
   through `invoke` when the state differs; `IRangeValueProvider` for
   sliders and progress bars, `SetValue` becoming `adjust` by
   `round((new − value) / step)`, and by ±1 toward the target when
   `step` is 0; `IValueProvider`, read-only, for text fields and combo
   boxes; `ISelectionItemProvider` for options and radios and
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
Accessibility Insights by a person; and with the feature off,
`01-measure:03-instruction-counts-in-ci` counts are unchanged.

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
declares a role, label, value, state and extra actions;
`Frame.semantics()` lists each such element in tree order with its id,
bounds, the index of the node around it, its state (with `disabled` and
`focused` filled in) and its actions (with `invoke`, `focus`, `scroll`
and `show_menu` taken from its flags and gestures). Labels and text
values are copied into the frame's text bytes, counted against
`max_text_bytes` and cut at a character when they do not fit. The list
lives in a slot beside each frame, not in `Frame`: any field added to
`Frame`, even a zero-size one, reordered its arrays and moved
`01-measure:03-instruction-counts-in-ci` counts by −0.33% to +0.49% with
the feature off. `Event.action` carries an `ActionEvent`, answered by
`clicked`, `focused`, `adjusted`, `manipulation` and a scroll,
`contextRequested` and `dismissed`; a disabled element takes none, and
without the feature the event is dropped. Every control in `zui_widgets`
declares its semantics (button, checkbox, disclosure, slider with its
range and `adjust`, text field, dropdown with its list and options), the
slider steps through `adjusted`, the dropdown's list closes on
`dismiss`, and `zui_reflect` names each control after its field.
`zui_testing.Driver.action` sends one. Measured against `8911fb2` with
`zig build counts`: with the feature off every scenario is identical to
the instruction; with it on and nothing declared, declaration moves
−1.28% to +0.52% and `endFrame` adds 2 to 7 instructions.

Slice 1 is done, in core and in `hosts/native/`. Core gains
`zuiSemantics`, `SemanticsCapacity`, `SemanticsDropped` and
`WindowOptions.semantics`, the compile error
`host_semantics_wrong_signature`, `zui_app`'s call with
`Notice.semantics_dropped` and `Report.accessibility`, and the host
suite's `invoke` step, which `QueueHost` passes and
`QueueHost(.drops_actions)` fails. The Windows host passes the suite
with the step answered through UI Automation's client in-process against
a window that is never shown (UI Automation exposes it), and four tests
of its own: the tree reads back with names, control types,
AutomationIds, parent and siblings through the raw view, and bounds in
screen pixels at a scale of 2; `SetFocus` arrives as a `focus` action
and a disabled element offers no Invoke pattern; a window opened without
room leaves `WM_GETOBJECT` to Windows; and a list past the room is cut
from the end and reported. Out of process, Windows PowerShell's UI
Automation client read `zig build accessible`'s Save button, label,
checkbox, slider and text field with their roles and bounds, invoked
Save (the label then read "Saved 1 times") and moved focus to the
checkbox.

Slice 2 is done, in `hosts/native/` alone. Each element offers the
pattern that stands for what it does: Toggle for a node that says
whether it is checked (not a radio or option), ExpandCollapse for one
that says whether it is expanded, RangeValue for a range, Value for
text, SelectionItem for an option or a radio and Selection for a list
box, and Invoke only where none of those stands for the click, so a
checkbox, an option and a combo box no longer offer it. Toggle, Expand,
Collapse, Select and AddToSelection become `invoke` when the node is not
already as asked; a range's SetValue becomes `adjust` by whole steps, or
by one toward the target when the range has no step, and a target
outside the range fails; RemoveFromSelection fails on the selected
option, since one is always chosen. A text field's Value reads as
editable while it is enabled, which it is from the keyboard, and its
SetValue fails with UIA_E_INVALIDOPERATION, since zui has no action that
replaces text; a combo box's Value is read-only. While a client listens,
the window thread compares each node with a summary of what it last
announced (a hash of its name and text, its range value, and its
checked, expanded, selected and disabled state, in two buffers allocated
in `init`) and raises property-changed events for name, value, range
value, toggle state, expand state, selection and enabled, and the
element-selected event. Three tests drive a window of `zui_widgets`
controls through UI Automation's client: each control's pattern and
state; Toggle, SetValue (0.5 to 0.8 at a step of 0.1), Expand and Select
each arriving as the action that answers it and the next frame showing
it, with the list's Selection naming the chosen option; and a
property-changed handler, added from the test's thread, hearing the
checkbox turn off. With no pattern code in zui,
`01-measure:03-instruction-counts-in-ci` counts cannot move.

Slice 3 is done, in core, the tour and `hosts/native/`. Core's
`SemanticNode` gains `scroll: ?SemanticScroll` (offset, content and
viewport sizes and the axes it scrolls on, filled after layout from the
element's scroll state, so it is the clamped offset the frame drew) and
`level`, which `Semantics.level` declares for a heading. The Windows
host's elements add the Scroll pattern (a small step is a wheel notch,
40 layout units, and a large one the view's size; `SetScrollPercent` is
a place in the content; an axis that does not move fails, and a
percentage reads `UIA_ScrollPatternNoScroll` on it),
`IRawElementProviderSimple2`'s `ShowContextMenu` as `show_menu`, the
Window pattern's `Close` on a dialog as `dismiss`, and the heading level
as `HeadingLevel1` to `HeadingLevel9`; scroll percentages join the
property-changed events. A slider, a text field and a progress bar no
longer offer Invoke beside their own pattern. A dropdown's open list
closes by its combo box's Collapse, which slice 2 already made an
`invoke`. The tour turns `features.semantics` on
(`apps/tour/src/kit.zig`). Two more conformance tests drive a real
scroll container through UI Automation (a notch, then 100%, and a
refused horizontal step), and a dialog's Close, a button's
ShowContextMenu and a heading's level. Out of process, Windows
PowerShell's UI Automation client read `zig build accessible`'s heading
(Level1), button, label, checkbox, slider, text field, dropdown and
scroll pane each with only its own patterns; toggled the checkbox off,
set the slider to 0.8, expanded the dropdown and selected High (its
value then read High, collapsed), scrolled the log by a notch and to
100%, and invoked Save. Measured: the zui-counts executable's `.text`
and `.rodata` are byte-identical to `7711b15`'s, so
`01-measure:03-instruction-counts-in-ci` counts are unchanged with the
feature off; Box Storm's frame, timed headlessly over 400 frames in
ReleaseFast with Turbo Boost on, took a median of 198 and 197 µs with
semantics off and 195, 198 and 197 µs with it on, within the runs'
spread; the tour on the Windows host with the bridge drew 300 frames
across every screen with diagnostics ok and idled at 0.0 ms of CPU over
10 s. A person's check with Narrator and Accessibility Insights on
`zig build accessible` and the tour has not been made; the automated
checks cover what it would see.

## 09-seeing-the-ui:03-safety-sweeps — Safety sweeps

**Plan.** The invariant checks that read only a `Frame`, at the end of
`endFrame`, behind `features.safety_sweeps`, which
`03-contracts:04-features` added. **Done when:** the randomized tests
run through it, a debug demo runs with it on, and with the feature off,
`01-measure:03-instruction-counts-in-ci` counts are unchanged.

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
feature on by default, and its run with
`--hidden --frames 900 --cycle 40` drew 900 frames across every screen,
every limit held, with no failure. The raylib, sokol and terminal
renderers' tests pass.

Measured against `4f9d316` with `zig build counts`: with the feature off
(its ReleaseFast default) every scenario is identical to the
instruction. With it on, declaration, whose code did not change, moves
−0.10% to +0.74% as the code lands elsewhere, and `endFrame` grows by
about 220 instructions an element: +71.9% for the 4,096-box tree, +58.4%
for 4,000 children of one parent, +45.5% for the interactive boxes,
+23.1% for warm text and +6.5% for cold text.

## 09-seeing-the-ui:04-demo-in-browser — The demo in a browser

**Plan.** The demo streaming over the wire
(`05-wire:04-rendering-elsewhere`) to a thin browser client, published
from CI. **Done when:** the demo runs at its native frame rate in a
browser.

The owner opened the published page in a desktop browser: the tour keeps
the display's frame rate, the mouse, the wheel and its shortcuts drive
it, and its gradients, shadows, blurs and materials look right. They
found two defects, fixed before `09-seeing-the-ui:04-demo-in-browser`
closed:

- **Timings read 0 µs.** The tour's strip and frame inspector read 0 µs
  for every timing, their bars at 0: the web host's `TourSession` never
  recorded the tour's `Perf` samples, which the native host takes around
  `beginFrame`, the declaration and `endFrame`, and had it, the worker's
  `SteppedIo` reads the page's one instant for the whole frame. The
  session now times each frame on a stopwatch of its own, the worker's
  `performance.now()` imported by the module, and records what the
  native host records, with the page's time to draw the frame before as
  its submit time. `test-demo` still compares every frame byte for byte
  with the native run: real timings differ from run to run and move the
  strip's text and bars, so no mask could compare them, and both runs
  time frames on a steady stopwatch instead, 1 µs a reading. `test-site`
  now fails unless the page times its frames above 0 µs: it failed
  before the fix (no frame above 0 µs within 10 s), and after it the
  newest frame was declared in 745 µs, at 37 frames a second in headless
  Chromium.
- **Only text was smoothed.** The sokol renderer has no coverage of its
  own for shapes; its demo window smooths every edge with
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
  two edges, each moving a sample). Text is left out there, since where
  a glyph's quad covers part of a pixel a GPU may sample the glyph
  anywhere in the pixel, and SwiftShader and NVIDIA's driver choose
  differently. With four samples, the unsmoothed page failed every
  frame, 338 to 2,374 pixels a frame matching nothing; the smoothed one
  passes every frame, at most 2 pixels a frame matching nothing. Its run
  in CI, its reference drawn by llvmpipe, is to be confirmed.

After `09-seeing-the-ui:04-demo-in-browser` closed, the owner found the
page never slept: it stepped the tour and drew a frame at every
`requestAnimationFrame`, and the worker asked `ui.nextFrame()` only to
label those frames "requested". The page (`22c4330`) now sleeps as
native hosts do. Each answer from the worker carries when to step the
tour again: its `nextFrame`, or sooner when one of its tasks' sleeps
ends, since under `SteppedIo` tasks run only while a frame waits for
them, and while a Gallery tile loads or a Mission Control producer
sleeps, `nextFrame` says `.on_event`. The page asks for an animation
frame at once, sets a timer for a deadline, or waits for the canvas's
input, a resize or a change of `devicePixelRatio`. A step declares a
frame only when one is due, for the reasons the native tour declares
one, and `test-demo`'s byte-for-byte run still declares one every tick.
`test-site` now checks that the idle page draws only the tour's
heartbeat while the display runs on, that input wakes it and is drawn,
that Mission Control's producers keep drawing and every Gallery tile
loads without input, and that the page then sleeps again. Idle on
Welcome in headless Chromium, the page drew 19 frames a second before,
every animation frame it had (drawing each held SwiftShader there), and
1 after, the tour's heartbeat, while the display ran at 60. Box Storm,
Typography, Light and Depth, Transforms and Materials animate and still
ask for every frame, as natively, where the native tour declares all 300
of 300 display frames on each, against 4 on Welcome.

Later, CI's `test-draw` failed frames 156 (49 unmatched pixels) and 228
(2) once the tour's screens put a fade at alpha 1/255 over muted labels
and stacked text dozens of lines deep. Mesa's llvmpipe, which draws the
reference where CI has no GPU, rounds `src * alpha` and
`dst * (1 - alpha)` separately in each 8-bit blend, a step below a GPU
for each translucent layer: on llvmpipe here, the label "Email" came out
`7f8391` where NVIDIA and Chromium drew `7f8694`, digit for digit the
two roundings' sum. The reference now names the renderer that drew it,
and against llvmpipe `test-draw` lets a color differ by 5 instead of 2
(`roadmap/decisions.md`). Frame 156 needs 4 and frame 228 5; on NVIDIA
the tolerance stays 2 and every frame passes.

It landed in five slices, in `hosts/web/` unless one says otherwise:

1. **The client's decoder in WebAssembly.** The web host's
   `FrameStream(Ui)` holds what has arrived of a stream and decodes each
   frame once it is whole, and `src/browser.zig` exports it for the page
   as `zui-web.wasm` (19 KB in ReleaseSmall, 12 MiB of memory reserved
   by `zuiWebInit`). `DemoUi` declares the tour's commands, colors and
   payload types field for field, so the browser decodes the tour
   without sokol. `zig build test-demo` declares the tour's thirteen
   screens headlessly for 24 frames each, the mouse crossing each,
   writes them as the wire renderer does (2,619,982 bytes, every command
   kind but `image`, which the tour never draws), feeds them under Node
   to the client built for `wasm32-freestanding` in pieces of 1 to
   16,384 bytes, and checks that each of the 312 frames, written whole
   again in the browser, hashes as the frame drawn did; a flipped bit in
   the stream or in the expected hashes fails it. CI runs it on Linux.
   In core, a test pins the decoder reading again a message cut short at
   any byte.
2. **Drawing,** in parts. The client lays each frame's commands out as
   triangles in the sokol renderer's geometry (`DrawList`: rounded
   corners in eight segments, borders inside their bounds, gradients in
   bands of OKLab color, shadows faded in six rings, transforms applied
   to each vertex, a batch per clip scissored as sokol_gfx truncates
   it), and `web/frame_drawer.mjs` draws them through WebGL 2, one draw
   call per batch (Decisions, Made: how the browser draws). The client
   is now 37 KB in ReleaseSmall and reserves 20 MiB, 8 of them for the
   vertices. `zig build test-draw` draws the middle frame of each of the
   tour's thirteen screens with the sokol renderer into an `.sdr`
   offscreen image, through OpenGL in a sokol_app window, and with the
   client in headless Chromium on SwiftShader, keeping in both only the
   commands the client draws, and compares them pixel by pixel. A pixel
   matches when its colors are within 2 of the reference's, or of a
   neighbor's, since two rasterizers may put an edge a pixel apart.
   - **Shapes:** rectangles, borders, clips, gradients, shadows and
     transforms. Every pixel of the 13 frames matches: 1 to 12,638 of
     each frame's 1,296,000 pixels differ at all, and 1 to 209 by more
     than 2 (at most 231), each on the edge of a rounded corner or a
     fan's triangle and matching a neighbor. The reference reads back
     the same bytes on every run. Drawing the shadows with five rings
     instead of six fails it. CI runs it on Linux under Xvfb with Google
     Chrome; its first run there is to be confirmed.
   - **Text.** The page hands the client the stream's fonts: the
     TrueType ones, which follow the ids of sokol's six built-in bitmap
     fonts in the order the host added them, and those six.
     stb_truetype, at the sokol renderer's commit, is compiled into the
     client without a C library, allocating from a scratch reserved at
     init, and rasterizes into a 1024² RG8 atlas packed as the sokol
     renderer packs its RGBA one, so a glyph sampled at its edge blends
     with the same neighbors; bitmap glyphs are an
     `01-measure:10-simulated-misses` texture sampled at the nearest
     texel. A vertex grows from 12 bytes to 56: an atlas glyph carries
     the map from a pixel's position to its texture coordinates, and its
     texel bounds, and the page finds both pixel by pixel, since
     SwiftShader snaps vertices to a sixteenth of a pixel and
     coordinates interpolated across a turned glyph differed from the
     reference by up to 31 at 237 pixels of the Transforms screen. The
     client is 63 KB in ReleaseSmall and reserves 35 MiB, 14 of them for
     2^18 vertices (6.7 times the busiest compared frame's 38,790).
     `test-draw` compares the text too, its reference drawn with the
     tour's fonts and failing if the sokol renderer's glyph atlas
     overflowed, and a frame passes with at most one pixel matching
     nothing within 1 (`maxUnmatchedPixelsPerFrame`; Decisions, Made: a
     pixel on a glyph's edge). In Debug and ReleaseSafe alike, 1 to
     12,717 of each frame's 1,296,000 pixels differ at all, 1 to 2,872
     by more than 2 (at most 231), and every frame has no unmatched
     pixel but frame 252, on the Transforms screen, which has one: its
     centre 0.0002 texels inside a glyph's right edge, drawn by the
     client (75, 75, 85) and left as the button's background (35, 35,
     50\) by the sokol renderer's OpenGL capture. Handing the client the
     Bold and Regular fonts swapped fails all 13 frames (13,480 to
     61,256 unmatched pixels), and moving every TrueType glyph a pixel
     right fails frames 204 and 252 (7 and 2,327); the neighbor rule
     absorbs the shift elsewhere. CI's first `test-draw` with text, its
     reference drawn by Mesa under Xvfb rather than this machine's
     NVIDIA driver, is to be confirmed.
   - **Backdrop blurs and materials.** A blur starts a batch, and before
     it the page copies the canvas into a texture and runs the sokol
     renderer's two passes: each Gaussian tap, split into the coarse and
     fine weights its 8-bit vertex colors add, is an instance of a quad
     over the blur's whole pixels, adding its linearly filtered sample
     into a float target along x, then from that into another along y,
     the sample clamped per pixel to the region's edge pixels, which is
     what the sokol renderer's three quads per tap draw. The batch's fan
     then takes the blurred texel at each pixel, under the tint. A
     material is a batch of its own, its uniforms the sokol renderer's,
     its pattern found at each vertex's place in the element by the
     sokol renderer's material shader ported to GLSL ES. The targets are
     RGBA32F where WebGL can render, blend and filter it, else RGBA16F;
     without `EXT_color_buffer_float` a blur is its tint alone; past 16
     blurs or 256 materials a frame draws the tint or the fallback,
     counted, as the sokol renderer does. The client is 66 KB in
     ReleaseSmall and still reserves 35 MiB. `test-draw` now keeps every
     command but `image`, which the tour never draws. In Debug and
     ReleaseSafe alike, 1 to 16,682 of each frame's 1,296,000 pixels
     differ at all and 1 to 2,872 by more than 2 (at most 231), each
     matching a neighbor, and frame 252 keeps its one unmatched pixel;
     inside the frosted pane on Light & Depth (frame 228) and the
     material cards on Materials (frame 276) no pixel differs by more
     than 1. Blurring with a radius of 8 instead of 10 fails frame 228
     (550 unmatched pixels), and turning every material's phase by 0.02
     more fails frame 276 (48,254). The check's removal of Chromium's
     profile now retries, since a child process could still be writing
     to it. CI's first `test-draw` with blurs failed frame 228 (17,654
     unmatched pixels): Mesa's llvmpipe, drawing the reference under
     Xvfb, rounds each tap's addition to an RGBA16F target differently
     and summed the pane 2 to 6 color steps darker than NVIDIA. The
     sokol renderer (`05724a9`) now sums blurs in RGBA32F where the GPU
     can, and RGBA16F otherwise, and so does the client; `test-draw`
     fails if either side cannot sum in RGBA32F, and reports each
     failing frame's numbers and uploads its images from CI. Against
     references drawn by NVIDIA and by llvmpipe alike, no pixel inside
     the pane differs by more than 1, and every frame but 252 (its one
     pixel) has none unmatched; 1 to 13,740 of each frame's pixels
     differ at all on NVIDIA, 5,516 to 22,905 on llvmpipe. Its run in CI
     is to be confirmed.
3. **Input.** `web/input_recorder.mjs` turns a canvas's pointer, wheel,
   key and text events, its size and `devicePixelRatio` into calls the
   client makes records of: the web host's `RecordStream(Ui)` fills a
   `RecordBuilder` and writes, through `zui_wire`'s `Encoder`, the
   stream's header and then a record only when it holds events or the
   viewport or scale changed, as `05-wire:04-rendering-elsewhere`'s
   client sends. Its message buffer is reserved at init for every event
   the builder holds at twice its size in memory, which a test fills
   with the largest events. A key is the one `KeyboardEvent.key` names,
   or for a digit or a mark the one its `code` places, so Ctrl+2 is
   Ctrl+2 on any layout, and a key that types a character without Ctrl
   or Meta sends it as text; a wheel's lines are 40/3 units, a notch of
   three as far as the Windows host scrolls. The newest frame's cursor
   is set on the canvas by its CSS name. The tour has sources, so its
   records end with their deliveries, which a live record writes as none
   whatever the sources: `DemoUi` declares one that delivers nothing,
   without which the tour's host read past the end of the browser's
   records. `zig build test-input` gives the page a mouse move and a
   click on the rail, Ctrl+3, Ctrl+PageDown, two typed keys, the wheel,
   a touch and a resize through headless Chromium's DevTools protocol,
   runs the tour on the 9 records (429 bytes) the client wrote, checks
   each against what the page was given and that the tour moved to
   Mission Control, Box Storm and the Gallery and asked for the pointer
   cursor over the rail, and sends its frames back to the page, which
   must show that cursor. Dropping `ctrlKey` from the page's modifiers
   fails record 3, positions in device pixels fail record 1, and not
   setting the cursor fails frame 0. The client is 75 KB in ReleaseSmall
   and still reserves 35 MiB. The IME's text input area, and composed
   text, wait for `11-polish:06-text-editing`; CI's first `test-input`
   is to be confirmed.
4. **The demo behind the page, in a Web Worker** (Decisions, Made): the
   tour built for `wasm32-freestanding`, its frames posted to the page
   as wire bytes and the page's records posted back. In parts:
   - **The tour without sokol** (in the sokol renderer, `ef05a67`). A
     module of the sokol renderer's that does not import sokol holds
     `Text`, `truetype`, `Material`, `Image`, the commands the renderer
     draws and `config`; `zui_sokol` re-exports them, and its `config`
     checks the renderer. `Image` is now the ids of a sokol_gfx view and
     sampler, field for field what the web host's `DemoUi` decodes, and
     `zui_sokol.imageOf` makes one from sokol's handles. The tour
     declares its `Ui` through that module, so the tour imports no
     sokol, and given a freestanding target the sokol renderer's build
     makes only those two modules. Without a C library stb_truetype
     allocates nothing: it measures, and would rasterize no glyph. The
     sokol renderer's `zig build check` compiles and links the tour
     declaring a frame for `wasm32-freestanding` on `std.Io.failing`
     (7.5 MB in Debug, importing nothing from the page); run once by
     hand under Node, it declared the frame. The tour's frames are
     unchanged: the web host's `test-demo` writes the same stream byte
     for byte, its reference for `test-draw` is the same, and
     `test-input` passes.
   - **The worker** (on the tour at `5242889`). `zig build` writes
     `zui-web-tour.wasm`, the tour built for `wasm32-freestanding` with
     atomics and bulk memory, on memory it imports shared: 793 KB in
     ReleaseSmall, 8.0 MB in Debug, and about 49 MiB once `zuiTourInit`
     reserves it (the tour, 16 thread stacks of 256 KiB and 4 MiB for a
     frame's bytes). The web host's `TourSession` runs the tour as a
     loop that owns its clock: each frame it steps the tour's `Io` to
     the page's instant, takes the records that arrived whole, declares
     the frame and writes it through `zui_wire`'s `Encoder`, and
     `web/tour_worker.mjs` posts those bytes to the page. The tour's
     tasks run on an `Io` of the worker's own, `SteppedIo` (Decisions,
     Made: how the tour's tasks run in the worker): its clocks read the
     page's instant, and its tasks take turns on 16 threads, each a
     worker on the tour's memory (`web/tour_thread.mjs`, setting its own
     stack pointer and thread-local storage), one at a time and only
     while the frame waits for them; a task runs as it starts until it
     first waits, and waits for a thread while all 16 are taken.
     `test-demo` now also runs the tour in that worker under Node, on
     the records the client wrote of the mouse crossing each of the
     thirteen screens and Ctrl+PageDown between them, 312 frames at 60
     Hz on the page's clock, and runs it natively on the same ticks
     (`tools/tour_frames.zig`, the same `SteppedIo` on 16 native
     threads): every frame is the same bytes (2,628,746 in all), the
     tour started and finished 66 tasks and was refused none on both,
     and the client decodes every frame. In the worker the 312 frames
     take 0.9 s in Debug and 0.1 to 0.2 s in ReleaseSafe, ReleaseFast
     and ReleaseSmall, starting the threads included; three runs of each
     agree. A worker refusing every task, as `std.Io.failing` does,
     fails it (no task finished), and so does a worker on 4 threads
     (frame 76 differs), and at the tour of `ef05a67`, where the
     Gallery's tiles depended on the pointer width, frame 88 differs. By
     hand, in headless Chromium serving the page cross-origin isolated,
     the worker drew 312 frames in 115 ms in ReleaseSmall, after 28 ms
     starting its threads, and ran the same 66 tasks; served without
     those headers, the page cannot post shared memory to its worker, so
     slice 5 must serve it isolated, which GitHub Pages cannot set
     headers for: a service worker that adds them, or another host.
5. **Published from CI.** The page, `web/index.html`, starts the tour's
   worker, and on each of the display's frames sends it the page's clock
   and the record the canvas's input made, draws the frame it answers
   with, and shows its cursor (`web/tour_page.mjs`). It stays on GitHub
   Pages, made cross-origin isolated by a service worker of its own
   (Decisions, Made: how the published page is isolated):
   `web/isolation_service_worker.js` serves the page and everything it
   loads again with `Cross-Origin-Opener-Policy: same-origin` and
   `Cross-Origin-Embedder-Policy: require-corp`, and the page registers
   it and reloads once, and says so rather than reload again if it is
   still not isolated. `zig build site` writes the page, the client, the
   tour's worker, sokol's built-in bitmap fonts and the tour's TrueType
   fonts with their license to `zig-out/site`, 1.0 MB in ReleaseSmall
   (the client 77 KB, the tour 793 KB); the Pages workflow builds it in
   ReleaseSmall on each push to `main`, runs `test-site` on it and
   publishes it. `zig build test-site` serves the site as GitHub Pages
   does, without the isolation headers, opens it in headless Chromium
   and checks that the page is isolated, through its own service worker,
   after one reload, draws the worker's frames (49 of headless
   Chromium's 55 animation frames a second, on SwiftShader at 1600 by
   1000 pixels, the worker answering in 0.5 ms and the page drawing in
   0.7 ms at the median, in ReleaseSmall), and that its input reaches
   the tour: the mouse over the rail turns the canvas's cursor to the
   pointer, and a click on Mission Control's entry starts its two
   producers' tasks. A service worker that leaves out
   `Cross-Origin-Embedder-Policy` fails it (the page says it is not
   isolated), and so does a page that sends only its first record, draws
   nothing, or shows no cursor. CI runs it too.

# 02-frame-record: The frame record

Stage 2 of SPEC.md §21, the breaking change, made once:
`Context(config)` with the text contract; `FrameRecord` with `now`,
scale and zoom; input as events with the pointer table; the environment;
`endFrame` that always returns a frame; `NextFrame`; sources in the
core, `Status`, `Waker`; `zui_async`; `MeasureKey` with letter spacing;
`TaskPool` deleted.

**Done when:** the interaction, widget and testing suites pass on
events; a click inside one frame is kept; the demo's thumbnail grid runs
on `KeyedLoads` with no UI-thread wait and idles at 0% CPU; 100 loads
between two frames cause one wake.

**Status.** Done. `02-frame-record:01-async-audit` and
`02-frame-record:02-completions-at-begin-frame` landed in release 0.6
and shaped the sources. What remains of an item here waits for a later
stage, as its **Status** says.

## Items

| Item | Status |
|---|---|
| `02-frame-record:01-async-audit` The async and parallel audit | done |
| `02-frame-record:02-completions-at-begin-frame` Task completions at `beginFrame` | done |
| `02-frame-record:03-context-config` `Context(config)` and the text contract | done |
| `02-frame-record:04-record-parameters` The frame record's parameters: time, scale and zoom | done |
| `02-frame-record:05-input-event-log` Input as an ordered event log | done |
| `02-frame-record:06-end-frame-always-returns` `endFrame` always returns a frame | done |
| `02-frame-record:07-delete-task-pool` Delete `TaskPool` | done |
| `02-frame-record:08-next-frame` `nextFrame()` | done |
| `02-frame-record:09-letter-spacing` Letter spacing, through a measurement key | done |
| `02-frame-record:10-environment-and-host-requests` The environment and host requests | done |
| `02-frame-record:11-sources-in-core` Sources in the core | done |
| `02-frame-record:12-zui-async` `zui_async` | done |
| `02-frame-record:13-backends-on-stage-2-api` The backends on the stage-2 API | done |

---

## 02-frame-record:01-async-audit — The async and parallel audit

Done as a design: sources, demand and the loader replace task pools, and
are SPEC.md §14 and §15. The working document was folded into SPEC.md
and deleted. Its two lessons stay:

- **A bounded queue whose bound relies on how often it is drained** is a
  hang waiting to happen. `KeyedLoads` sizes its completion ring by
  claims, so it cannot overflow however rarely it is drained.
- **A cancel that waits on the UI thread** is never acceptable. zui no
  longer cancels anything; an abandon flag is read by the producer at
  its own pace.

## 02-frame-record:02-completions-at-begin-frame — Task completions at `beginFrame`

`beginFrame` applies each pool's completions; `request` only reads. The
code is deleted with `TaskPool` in stage 2
(`02-frame-record:07-delete-task-pool`), but what it showed shapes the
sources: completions belong to the frame record, and with an inline `Io`
a result is ready one frame later, not during the request.

## 02-frame-record:03-context-config — `Context(config)` and the text contract

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

**Done when:** every test, widget and benchmark builds on
`Context(config)`; compile-error tests pin each contract message.

**Status.** Done in the core.

**Spec.** §4, §5, §9.4, §16.1.

## 02-frame-record:04-record-parameters — The frame record's parameters: time, scale and zoom

**Grounding.** `Platform.scale` only snaps command bounds
(`core/src/emission.zig:32`). Nothing lets an application zoom its UI.
Time arrives as `dt_seconds`, so deadlines and velocities cannot be
expressed in the host's clock.

**Plan.** `FrameRecord.params = .{ now, viewport, scale, zoom }`.
`ui.dt()` is derived from two records. Layout stays in logical units;
text is measured at `size × zoom`; snapping uses `scale × zoom`.

**Done when:** golden tests at three zoom levels, and a replayed record
reproduces the frame exactly with any scale.

**Status.** Done but for replay, which waits for `05-wire:01-relay` and
`05-wire:03-replay-in-testing`.

**Spec.** §6.2.

## 02-frame-record:05-input-event-log — Input as an ordered event log

**Grounding.**

- `Input.buttons` is the state at poll time
  (`core/src/context.zig:902`), so a press and release between two polls
  is never a click. zui sleeps until input arrives, which makes that
  likely, and a touch tap usually vanishes.
- There is one pointer: one `press_target` and one `hover_chain`
  (`core/src/interaction.zig:181`).
- `Key` has no letters (`core/src/interaction.zig:8`), so Ctrl+S cannot
  be expressed, and modifiers are sampled once per frame rather than per
  key.

An item that was to settle this format before the host contract is
merged here: the format is SPEC.md §7.

**Plan.** `FrameRecord.events` as SPEC.md §7.1; a pointer table of
`max_input_contacts`; moves coalesced per pointer; `Key` with letters,
digits, punctuation and function keys, plus the opaque scancode;
`chordPressed`; `zui.InputSampler` for backends that report only state;
`zui_testing.Driver` emitting events, with `tap`, `pinch` and
multi-pointer `drag`. First rebuild `resolveInput` over the log with
`max_input_contacts = 1` behind today's queries, then widen.

**Done when:**

- the interaction, widget and `zui_testing` tests pass on events;
- a press and release inside one frame is a click;
- 133 moves in one frame cost at most one hover hit test per pointer;
- two pointers press two buttons at once;
- `01-measure:03-instruction-counts-in-ci`'s counts on the mouse-only
  scenarios are no higher than before.

**Status.** Done (`pinch` came with
`07-gestures:01-gesture-arbitration`) but for
`01-measure:03-instruction-counts-in-ci`'s counts: `zig build counts`
has no scenario with input yet, and commits from before
`02-frame-record:05-input-event-log` cannot be counted by today's
scenarios, so the mouse-only check becomes a counted input scenario that
later changes must not grow. Every hovering pointer is hit-tested once a
frame even without a move, so hover follows a layout that moved under a
still mouse. A lifted touch stays readable until the next frame, so the
frame that sees a tap can ask where it was.

## 02-frame-record:06-end-frame-always-returns — `endFrame` always returns a frame

**Plan.** `endFrame() *const Frame`; the part that fit is laid out, and
`frame.diagnostics` names the limit, by how much, the peak and the first
id. `diagnostics.check()` returns `error.CapacityExceeded`. `lastFrame`
goes. `tryBeginFrame` for hosts that cannot block.

**Done when:** the memory tests pass with the new reporting, and a frame
over every limit still draws what fit.

**Status.** Done.

**Spec.** §6.3, §6.5, §17.

## 02-frame-record:07-delete-task-pool — Delete `TaskPool`

**Plan.** Remove `src/tasks.zig`, its tests and every reference; the
demo's loads move to `02-frame-record:12-zui-async`'s sources.

**Done when:** nothing in the core or the renderers names a task pool.

**Status.** Done; the backends and the demo's loads moved off it in
`02-frame-record:13-backends-on-stage-2-api`.

## 02-frame-record:08-next-frame — `nextFrame()`

**Grounding.** `needsFrame` is yes or no. A blinking caret needs "a
frame at this instant", and a frame-rate cap needs to know it.

**Plan.** `NextFrame = union { immediately, at: Instant, on_event }`,
from requested frames, pending sources, `requestFrameAt`, momentum and
gesture timers. `needsFrame` goes.

**Done when:** a test's caret blinks with frames only at its instants,
and an idle context reports `.on_event`.

**Status.** `requestFrame`, `requestFrameAt` and pending sources
(`02-frame-record:11-sources-in-core`) are done; so are long-press and
double-tap timers and momentum (`07-gestures:01-gesture-arbitration`).

**Spec.** §6.6.

## 02-frame-record:09-letter-spacing — Letter spacing, through a measurement key

`TextStyle.letter_spacing`, and
`MeasureKey { font, size, letter_spacing }` passed to `zuiMeasure` and
used as both the cache key and the hash seed, with size and spacing
multiplied by zoom. Text commands carry the spacing in their style. Both
`FixedMetricsText` contracts (the core's test one and `zui_testing`'s)
now add the spacing after every byte, as SPEC.md §9.4 asks of every
contract, so golden tests lay out spaced text: it widens every character
including the last, wraps sooner, is aligned by its spaced width, and
lays out identically at zooms of 0.5, 1 and 2. Nothing on a hot path
changed, so there is nothing to measure. Drawing the spacing belongs to
the renderers, which `02-frame-record:13-backends-on-stage-2-api` did.

## 02-frame-record:10-environment-and-host-requests — The environment and host requests

`zui.Environment`, kept by the core and changed one field at a time by
`environment` events, which apply before the declaration of the frame
that carries them; `ui.environment()`. `Frame.requests()` returns
`HostRequests`: the cursor of the innermost element under the hovering
pointer that sets `Element.cursor`, and the caret rectangle an editable
asks for with `ui.requestTextInput(editable, caret)` while it is
focused. `zui_widgets` gains `dark_theme`, used while the environment is
dark, and its controls ask for the pointer, or the I-beam over a text
field, which also requests text input at its caret.

Decided here: `EnvironmentChange` is a union with one variant per field,
so applying one is an `inline else`; `Locale` is a BCP 47 tag of up to
23 bytes held inline, so the event stays plain data; the reading
direction is its own `ReadingDirection`, since `Layout.Direction` also
flows top to bottom.

`zig build counts` against `1447ed1`, in a local Docker container: every
scenario within 1% (declaration of the box tree −0.07%, its `endFrame`
+0.06%), as an `Element.cursor` left null is compiled away at each
declaration.

## 02-frame-record:11-sources-in-core — Sources in the core

`Config.Sources`, checked at instantiation: a struct whose every field
implements the source contract, with each missing or misspelled
declaration and each wrong signature a compile error naming the field
(`AppSources.quotes`). `beginFrame(record, sources)` swaps each field in
order, or injects `record.deliveries`, in a `swap_sources` zone, and
adds each source's `zuiRefusedCount` to the diagnostics
(`refused_publishes`, `first_refusing_source`). `ui.source(.field)`
returns the field's `View` and records the frame's demand, which
`framesSinceRead` reports; `endFrame` calls each `zuiEndFrame`;
`nextFrame(sources)` is immediate while a source's `zuiPending` is true.
`Ui.FrameRecord`, `Ui.Deliveries` and `Ui.SourceField` are derived from
`Sources`; with `Sources = void` none of this exists and no parameter
changes. The vocabulary is core: `zui.Status`, `StatusWithProgress`
(with `fromResult`), `Waker` (with `wakeIf`), `Wake` and `EndFrameInfo`.
Eleven compile-error tests pin the messages of SPEC.md §14.9.

Decided here, and written into SPEC.md:

- **`nextFrame` takes the sources,** as `beginFrame` does, because zui
  keeps no pointer into them between frames and the loader's publishes,
  made after `endFrame`, must count.
- **`ui.source` outside a frame panics in every build,** for the same
  reason: there is no last view to read.
- **A read is one store** of the frame's number into a per-source
  counter, so `endFrame` settles nothing for the core's own demand.
- **`.failed` carries `Result`'s whole error set:** Zig 0.16 cannot
  build an error set without `Canceled` at comptime. It exists only when
  there is an error besides `Canceled`, and `fromResult` never puts
  `Canceled` in it.
- **"Two contexts swapping one source" is asserted by the source,** as
  the core keeps nothing in it; that assertion and the producer-side
  ones are `zui_async`'s (`02-frame-record:12-zui-async`).

`zig build counts` against `66f4ca7`, in a local Docker container, with
a new scenario, depth 64 reading ten sources that receive nothing: its
declaration takes 80 instructions more than depth 64 alone (16,083
against 16,003), about 8 per source, almost all the test source's own
swap and the reads; its `endFrame` takes 1 more (24,882 against 24,881).
Scenarios without sources moved by 6 instructions in declaration (+0.04%
at most), from the two diagnostics fields `beginFrame` resets. That is
how SPEC.md §20.2's "no more instructions than with none" is met: what
remains is each source's own swap. The scenario is deliberately depth
64: a second instantiation of the documents view made LLVM outline its
label formatting, which raised that scenario's declaration by 5.8%.

## 02-frame-record:12-zui-async — `zui_async`

`zui_async`, the default sources of SPEC.md §19.1, each memory fixed at
comptime in the application's own struct:

- `Latest(T)`: a triple buffer and one atomic byte;
- `Stream(T, .{ .capacity, .producers })`: a ring with a sequence per
  slot, claimed by compare-and-swap for `.many` and a plain store for
  `.one`, refusing the newest item when full;
- `Task(Result, .{ .Progress })`: a `Latest` of its status, one run at a
  time through `begin`, `progress`, `finish`, `abandon` and `clear`, and
  `publishing(f)` to finish a run with a plain function's result;
- `KeyedLoads(Key, Result, .{ .capacity, .unread_frames_before_release, .owns_resources, .Progress })`:
  keys moved from wanted to loading by `toStart`, completions through a
  ring with a place per slot, release after
  `max(unread_frames_before_release, frames_in_flight)` unread frames,
  and with `owns_resources` everything handed back by `toRelease`.

Safe builds assert what SPEC.md §14.9 gives the sources: one reader (the
frame numbers `zuiEndFrame` sees only increase), one producer for
`Latest` and `Stream(.one)`, and a run or load finished once. Every
publish reports `Wake`, so 100 loads finishing between two frames cause
one wake, which a test proves with 100 producers on threads.

`zui_testing` gains `expectSourceConforms(Source, harness, .{ .io })`
(and `findSourceViolation`): producers publish items through a harness
while the reader swaps at random intervals, and every frame checks the
delivery against the view and injects it into a replica. It fails on a
lost, repeated, reordered or unreported item, a lost wake, or more wakes
than swaps. All four sources pass it on `std.testing.io` with threads
and on `Io.Threaded.init_single_threaded`, where every producer runs
inline and refuses rather than waits; and under ThreadSanitizer
(`-Dzui-sanitize-thread=true`, through LLVM), locally in a Linux
container and in CI. Weakening `Latest`'s exchanges to `.monotonic`
makes ThreadSanitizer report races, so the suite reaches them. `Driver`
takes the application's `.sources` and gains `frameDelivering`.

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
data `01-measure:03-instruction-counts-in-ci` describes. A new scenario,
depth 64 reading ten idle `zui_async` sources (four `Latest`, two
`Stream`, two `Task`, two `KeyedLoads` with one key read each frame),
takes 16,346 instructions in declaration against 16,003 for depth 64
alone (about 34 per source: the swaps, a `KeyedLoads` key hashed and
probed), and 24,915 in `endFrame` against 24,881. `KeyedLoads` walks its
slots only once a key could have gone unread long enough; before that
change the scenario's `endFrame` took 25,955.

The demo's thumbnail grid on `KeyedLoads`, idling at 0% CPU, and its 100
loads causing one wake, were done in the raylib renderer by
`02-frame-record:13-backends-on-stage-2-api`.

## 02-frame-record:13-backends-on-stage-2-api — The backends on the stage-2 API

The raylib renderer (`66c3d77`), the sokol renderer (`e8ce40f`) and the
terminal renderer (`d7930bb`) move to the API of `2df48f7`, and each
one's CI passes on Linux, Windows and macOS. In each:

- `Platform` is `Text`, the text contract, set by the backend's
  `config()`: `zuiMeasure` with a `MeasureKey`, counting the letter
  spacing after every glyph, and text commands drawn with their spacing
  (per glyph in sokol's built-in bitmap text, to the nearest cell in a
  terminal);
- the loop builds a `FrameRecord`, takes `endFrame()`'s frame, and waits
  as `nextFrame` says;
- the frame's cursor request is applied where the library has cursors
  (raylib, sokol_app), and focus changes are `window_focused` events.

The demo's thumbnails are a `zui_async.KeyedLoads` source: declaration
asks for the keys of the rows near the visible area, the loader starts
each load as its own task on the application's `Io` after `endFrame`,
and keys unread for 30 frames are abandoned (34 of 98 in a scripted fast
scroll). Measured in the raylib renderer's demo:

- **0% CPU idle.** `--measure-idle` has the demo read its own CPU time
  at two frames it requests 10 s apart. On Windows (i9-10900K,
  ReleaseSafe): 0.0 ms in the thumbnail grid and the settings view,
  31–47 ms in the documents view, with 1 frame (the measurement's own)
  and 0 wakes in each window; Windows counts CPU in 15.6 ms ticks. On
  CI's Linux runner, under Xvfb: 24.0 ms for the grid, 1 frame, 0 wakes.
- **One wake for 100 loads.** A test of the demo's thumbnails asks for
  100 thumbnails in one frame, finishes them on 100 tasks before the
  next, and counts 1 wake; the next frame shows all 100 and `nextFrame`
  is `.on_event` again.

Decided here:

- **Backends that see events send events.** sokol_app and the terminal
  report events, so their collectors emit them in order and a click
  inside one frame is kept; only raylib, which reports state, goes
  through `zui.InputSampler`.
- **A deadline wakes raylib through a timer.** raylib's `EndDrawing` can
  wait for events but not for a time, so `FramePacer` turns `.at` into
  event waiting plus a task that posts an empty event at the instant,
  sleeping until the instant has truly passed: a wake just before it
  asked for the same instant again and slept for good.
- **sokol_app cannot sleep,** since it presents at every refresh, so its
  demo declares a zui frame only when `nextFrame` or input calls for one
  and redraws the frame it holds otherwise: 2 zui frames in 121 drawn.
- **Idle is measured by the process itself,** between two frames it asks
  for with `requestFrameAt`, so a run ends on its own and the same check
  runs in CI.

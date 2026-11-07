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
| stage 1, in part | instruction counts in CI (R1) | on `main` |
| stage 2, in part | the code brought to the spec's shape: C5, S1, I4, C6, A5 and `nextFrame` (I2) | on `main`; the other repos still need the same change (C8) |

No release is tagged; everything is on `main`. From here, work is
tracked by stage rather than by release number. Each stage may be tagged
when it is done.

Measured on the reference machine (i9-10900K) at `a6d8e34`, against the
budgets of SPEC.md §20.2:

| Scenario | Declaration | `endFrame` | Budget |
|---|---|---|---|
| 4,096 boxes, depth 8 | 52.2 µs | 101.2 µs | declaration < 55 µs (met); layout and emission < 100 µs (missed by 1.2 µs) |
| 1,000 texts, warm caches | 14.1 µs | 184.2 µs | < 120 µs (missed; T1 and T2 are the plan) |
| 4,000 children of one parent | 52.9 µs | 65.8 µs | |

## The queue

Work is taken from the top. The first row whose status is not
`waiting` is the next item, and CLAUDE.md says how to take it on. An item
too large for one sitting lands in slices, each a commit with every check
green, and its **Status** line below says which slice is next.

| Item | Stage | Where | Waits for | Status |
|---|---|---|---|---|
| P2. The tracer contract | 1 | `src/` (`Features.Tracer`), a recording test tracer; the Tracy binding in a `zui_tracy` module | | next |
| T3. Letter spacing: the golden test | 2 | `src/tests/golden.zig` with a spacing test contract | | in progress: key, style and cache done |
| I6. The environment and host requests | 2 | `src/input.zig`, `src/context.zig`, `src/tests/interaction.zig`, `zui_widgets/` | | |
| A3. Sources in the core | 2 | a new `src/sources.zig`, `src/context.zig`, `src/contracts.zig`, `tests/compile_errors/` | | |
| A4. `zui_async` | 2 | a new `zui_async/` module; `expectSourceConforms` in `zui_testing/` | A3 | |
| C8. The backends on the stage-2 API | 2 | `../zui-raylib`, `../zui-sokol`, `../zui-terminal` | A4, T3 | |
| T1. The single-line fast path | 6, early | `src/text.zig` | | |
| T2. The whole-string cache | 6, early | `src/text.zig`, `Limits.string_cache_entries` | T1, P2 | |
| P4. The box tree's layout and emission within budget | 6, early | `src/layout.zig`, `src/emission.zig` | P2 | |
| C1. The renderer contract, generated commands, lowering | 3 | `src/commands.zig`, `src/emission.zig`, `src/contracts.zig` | C8 | |
| C2. The host contract and the surface | 3 | `src/contracts.zig`, a new `src/surface.zig` | C1 | |
| C3. Conformance suites | 3 | `zui_testing/` | C1, C2 | |
| C7. `Features` | 3 | `src/context.zig` | P2 | |
| C4. `zui_app` | 3 | a new `zui_app/` module | C3 | |
| H1. The raylib adapter host | 3 | `../zui-raylib` | C4 | |

After the queue come stage 4 (H2, H8, in `../zui-host`) and then stages
5 to 11 in the order of SPEC.md §21. They join the queue as it runs short.

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
  it. With `TaskPool` deleted, nothing brings outside data into a frame
  until A3 and A4.
- **Stage 2 ends in the other repos.** Its *Done when* in SPEC.md §21
  (the demo's thumbnail grid on `KeyedLoads`, idling at 0% CPU) can only
  be met in zui-raylib, which is C8.
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

## Stage 1: measure

### P2. The tracer contract

**Grounding.** The profiles of the declaration work needed hand-matched
`perf` samples and temporary `never_inline` calls to see per-function
costs.

**Plan.** `Features.Tracer`: a zone per layout pass, per emission step
and per `beginFrame` step, through `zuiBegin` and `zuiEnd`, and nothing
analyzed when it is `void`. A Tracy binding as the first tracer, and a
short guide to profiling with minimal noise: pinned cores, fixed
frequency, alternating runs.

**Done when:** a trace of the demo shows every pass, and a build without a
tracer has unchanged `zig build counts`.

**Slices.** `Features` exists only as this item adds it, with `Tracer`
alone (C7 adds the rest). First the contract, its compile-error tests and
a test tracer that records zones, so a test asserts every pass is a zone;
then the Tracy binding; then the trace of the demo, which needs C8.

**Spec.** §4, §16.5.

---

## Stage 2: the frame record

The breaking change, made once. Everything in this stage lands before
stage 3 adds the host and renderer contracts.

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

### T3. Letter spacing, through a measurement key

**Grounding.** `measureText(text, font, size)` cannot express letter
spacing per text, and the additive-measurement rule means a backend
cannot add it afterwards.

**Plan.** `TextStyle.letter_spacing`, and `MeasureKey { font, size,
letter_spacing }` passed to `zuiMeasure` and used as the cache key, with
`size` already multiplied by zoom. Text commands carry the spacing.

**Done when:** a golden test lays out spaced text, and every renderer
draws it.

**Status.** The key, the style field and the cache are done; the golden
test needs a test contract that applies spacing, and the renderers draw
nothing yet (C8).

**Spec.** §9.1, §9.4.

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

**Status.** Done but for `pinch`, which waits for gestures (I5), and R1's
counts: `zig build counts` has no scenario with input yet, and commits
from before I4 cannot be counted by today's scenarios, so the mouse-only
check becomes a counted input scenario that later changes must not grow. Every hovering pointer is hit-tested once a
frame even without a move, so hover follows a layout that moved under a
still mouse. A lifted touch stays readable until the next frame, so the
frame that sees a tap can ask where it was.

### I6. The environment and host requests

**Plan.** `Environment`, kept by the core and updated by
`environment` events; `ui.environment()`. `HostRequests` in the frame:
the hot element's cursor and the focused editable's IME area.

**Done when:** a test changes the theme by event and a widget follows it;
the cursor request follows hover.

**Spec.** §7.2, §7.3.

### I2. `nextFrame()`

**Grounding.** `needsFrame` is yes or no. A blinking caret needs "a frame
at this instant", and a frame-rate cap needs to know it.

**Plan.** `NextFrame = union { immediately, at: Instant, on_event }`,
from requested frames, pending sources, `requestFrameAt`, momentum and
gesture timers. `needsFrame` goes.

**Done when:** a test's caret blinks with frames only at its instants,
and an idle context reports `.on_event`.

**Status.** `requestFrame` and `requestFrameAt` are done; pending sources,
momentum and gesture timers join it with A3 and I5.

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

### A3. Sources in the core

**Plan.** `Config.Sources`; the contract checked at instantiation;
`beginFrame` swapping each field in order or injecting
`record.deliveries`; `ui.source(.field)` recording demand;
`framesSinceRead`; refusals in diagnostics; `zui.Status`,
`StatusWithProgress`, `Waker`, `Wake`.

**Done when:** a frame with ten idle sources costs no more instructions
than one with none; every check of SPEC.md §14.9 has its compile-error or
safety test.

**Spec.** §14.

### A4. `zui_async`

**Plan.** `Latest`, `Stream`, `Task` and `KeyedLoads` as SPEC.md §19.1,
and `expectSourceConforms` in `zui_testing`, run against each.

**Done when:** each passes the conformance suite under ThreadSanitizer
and on a single-threaded `Io`; the demo's thumbnail grid runs on
`KeyedLoads` with no wait on the UI thread, idles at 0% CPU, and 100
loads finishing between two frames cause one wake.

**Spec.** §19.1, §19.4.

### A5. Delete `TaskPool`

**Plan.** Remove `src/tasks.zig`, its tests and every reference; the
demo's loads move to A4's sources.

**Done when:** nothing in this repository or the backends names a task
pool.

**Status.** Done in this repository; the demo's loads wait for A4, and
the backends for C8.

### C8. The backends on the stage-2 API

**Grounding.** zui-raylib, zui-sokol and zui-terminal pin zui at
`c41b571`, before stage 2. They still declare a `Platform` with
`measureText(text, font, size)`, `scale` and `wake`
(`../zui-raylib/src/root.zig:31`), read `zui.Input`, and zui-raylib's
demo loads through `TaskPool` (`../zui-raylib/examples/demo.zig`).

**Plan.** In each repository, on top of the zui commit that finishes A4:
- `Platform` becomes a text contract: `zuiMeasure` with a `MeasureKey`,
  counting letter spacing after every glyph, and text commands drawn with
  their spacing (T3);
- the loop builds a `FrameRecord` through `zui.InputSampler`, takes
  `endFrame() *const Frame`, and sleeps on `nextFrame()`;
- zui-raylib's demo moves its loads to `zui_async`, with the thumbnail
  grid on `KeyedLoads`.

Develop against this checkout with `zig build test --fork=../zui`; the
pin moves once the zui commit is pushed.

**Done when:** each backend's tests and demo build on zui's `main`, and
stage 2's own test (SPEC.md §21) holds in zui-raylib's demo: the
thumbnail grid runs on `KeyedLoads` with no wait on the UI thread, idles
at 0% CPU, and 100 loads finishing between two frames cause one wake.

**Spec.** §9.4, §6, §19.1, §21.

---

## Stage 3: the contracts

### C1. The renderer contract, the generated commands, lowering

**Plan.** `zuiSubmit`, `zui_surfaces`, `zui_commands`,
`zui_extended_color`; `Config.commands` generating `RenderCommand` with
`@Union`; emission lowering what the renderer did not declare, listed in
the diagnostics. zui-raylib, zui-sokol and zui-terminal become renderers.

**Done when:** each backend passes C3's renderer suite, and a renderer
that declares nothing optional compiles a `switch` over the base commands
only.

**Spec.** §13.1, §13.3, §16.2.

### C2. The host contract and the surface

**Plan.** `zuiPoll`, `zuiWaker`, `zuiWait`, `zuiSurface`, `zuiApply`;
`zui.Surface`; `RecordBuilder`; sticky wakes.

**Done when:** the raylib adapter (H1) passes C3's host suite.

**Spec.** §16.3, §16.4.

### C3. Conformance suites

**Plan.** `expectRendererConforms` and `expectHostConforms`, and a CI
recipe the backends copy.

**Done when:** every backend's CI runs them.

**Spec.** §19.4.

### C4. `zui_app`

**Plan.** `contextConfig(Renderer, overrides)` and `run(App, init,
options)`: the loop of SPEC.md §6.1, a render thread when the renderer
allows, host requests applied, pacing to `nextFrame`, capabilities and
fallbacks reported.

**Done when:** the demo runs on `zui_app` with less code than today, and
its time from process start to its first presented frame is measured
(from P1).

**Spec.** §6.1, §19.5.

### C7. `Features`

**Plan.** `Features.semantics`, `gestures`, `flex_wrap` and
`safety_sweeps`, each removing its code, memory and API when off; calling
an API whose feature is off is a compile error naming the field.

**Done when:** R1 shows a build with every feature off is no larger or
slower than today's.

**Spec.** §4, §4.1.

### H1. The raylib adapter host

**Plan.** zui-raylib implements the host contract with one window and no
system material, through `InputSampler`.

**Done when:** it passes C3's host suite, and the demo runs on it through
`zui_app`.

---

## Stage 4: a native host

### H2. The Windows host

**Grounding.** The owner develops on Windows, and Windows has every
system feature planned (materials, signals, scale changes, file drop), so
it tests the contract hardest.

**Plan.** In `zui-host/windows`: Win32 windows and the event loop,
`win32` surfaces, per-monitor scale, lifecycle events from console
control events and `WM_QUERYENDSESSION`, the clipboard, dropped files,
pacing to `nextFrame`, cursor and IME requests. zui-sokol's renderer
accepts its surface, through sokol_gfx without sokol_app.

**Done when:** the demo runs on it unchanged from H1, it passes C3, and it
idles at 0% CPU.

### H8. The desktop showing through the window

**Grounding.** Windows offers Mica and Acrylic (`DwmSetWindowAttribute`),
macOS vibrancy (`NSVisualEffectView`), KDE a blur protocol; GNOME and
browsers offer nothing comparable.

**Plan.** `HostCapabilities.system_material` and a material per window.
The renderer clears to transparent, and elements without a background let
it show; without one, the root draws the theme's solid background.

**Done when:** the Windows host shows Mica on Windows 11 and the solid
fallback on Windows 10, with the same application code.

---

## Stage 5: the wire

F1, feeds, is retired: sources (A3) are the mechanism for outside data.

### F2. Relay

**Plan.** `relayTo(listener)`: each applied record, with deliveries from
`zuiDelivery`, without allocating when no listener is attached.

**Done when:** a test relays a session into a buffer and gets back
exactly the records applied.

**Spec.** §6.8.

### F3. `zui_wire`

**Plan.** A versioned encoding of records and frames, as deltas; payloads
serialized when plain data and otherwise through `zuiSerialize`; the text
contract's fingerprint.

**Done when:** round trips are tested for every event, delivery and
command kind, and a delta stream of the demo is measured against full
frames.

**Spec.** §19.6.

### F4. Replay in `zui_testing`

**Done when:** a recorded demo session replays to identical commands
without starting any work.

**Spec.** §6.8, §19.4.

### F5. Rendering somewhere else

**Plan.** A wire renderer and a wire host, so a remote client is a host
plus a renderer. The browser demo (V4) is the first client.

**Done when:** the demo runs in one process and draws in another, with
input going back.

### F6. Watching files

**Plan.** A source of file changes from the host (`zuiFileWatch`), which
`zui_debug` uses to reload themes and assets.

**Done when:** editing a theme file restyles the running demo.

---

## Stage 6: text and layout

### T1. The single-line fast path

**Grounding.** `text.wrapLines` (`src/text.zig:276`) walks every word of
every text, even a label whose unwrapped width already fits.

**Plan.** Record whether a text has a paragraph break; with none, and an
unwrapped width that fits, emit one line.

**Done when:** the golden and randomized tests pass unchanged, and warm
text is faster by R1 and R2.

**Spec.** §9.2.

### T2. The whole-string cache

**Grounding.** A warm text costs one probe per word per frame
(`src/text.zig:161`): 1,000 texts take 184 µs against a 120 µs budget.
The per-word cache stays, because text that changes every frame measures
only its new words.

**Plan.** A second table keyed by the whole string and `MeasureKey`,
holding the metrics. A hit with T1's fast path does no per-word work.

**Done when:** warm 1,000 texts meet §20.2's budget, and a frame that
changes every string is no slower. A profile (P2) first confirms per-word
probes are the main cost.

**Spec.** §9.3.

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

**Spec.** §8.2, §20.2.

### T4. Line-break segmentation

**Grounding.** Breaking only at ASCII spaces cannot wrap CJK or Thai.

**Plan.** The optional `zuiSegment` on the text contract, writing break
opportunities into a `BreakSink`; ASCII spaces and newlines without it.

**Done when:** a golden test wraps CJK text with a segmenting test
contract, and texts without it are no slower.

**Spec.** §9.2, §9.4.

### L1. A grow basis

**Grounding.** Two `.grow` siblings holding "a" and "abcdefghijklmnop" in
300 px come out 90 / 210, as with CSS `flex-basis: auto`. There is no way
to ask for equal columns.

**Plan.** `Sizing.basis`, and `Sizing.grow_equal`.

**Done when:** golden tests for both bases, with the weight invariant.

**Spec.** §8.1.

### L2. Aspect ratio and natural sizes

**Plan.** `Layout.aspect_ratio`, deriving height from the settled width;
`Image.natural_size` for `fit` images.

**Done when:** golden tests cover aspect ratio under every rule on the
other axis, and a `fit` image takes its natural size.

**Spec.** §8.1, §10.1.

### L3. Dividers and decorated images

**Plan.** `Border.between_children`; image commands with `corner_radius`
and `tint`.

**Done when:** snapshot tests for both.

**Spec.** §10.1, §13.1.

### L4. Floating options

**Grounding.** Every floating element gets a hit region
(`src/emission.zig:157`), so a tooltip blocks what is under it; floating
elements always escape their ancestors' clip; a target declared after
the floating element falls back to the parent (`src/layout.zig:421`).

**Plan.** `Floating.capture`, `Floating.clip`, and later targets placed
after pass 6 by shifting the contiguous subtree.

**Done when:** interaction, layer and golden tests for each.

**Spec.** §8.4.

### L6. Right-to-left layout

**Plan.** `Direction.right_to_left`, `Layout.mirrored`, and logical
padding, alignment and anchors, following the environment's direction.

**Done when:** golden tests mirror every alignment and anchor.

**Spec.** §8.1.

### L7. Wrap

**Plan.** A wrap pass between distribution and positioning, for parents
that opt in, compiled out without `features.flex_wrap`. Breakpoints are
plain code over `ui.viewport()` or `rectOf`.

**Done when:** golden tests for wrapping under each alignment, and no
change to the budget scenarios with the feature off.

**Spec.** §8.1, §8.2.

### L8. Static styles

**Plan.** `zui.static` and `Static(T)`; config references in element
storage as pointers into the frame arena or static memory; fields on the
element overriding the style's.

**Done when:** the box tree's declaration stays within its 55 µs budget
with references, and declaring an element with a static style copies no
config (R1).

**Spec.** §10.3.

---

## Stage 7: gestures

### I5. Gestures: arbitration, intents, momentum, custom recognizers

**Grounding.**
- The slider drags with `pressed` and `pointerLocal`
  (`zui_widgets/zui_widgets.zig:268`); drag-to-scroll and drag and drop
  want the same pointer, and nothing decides between them.
- Routing by gesture kind fails: a vertical drag on a horizontal carousel
  inside a vertical list goes to the carousel, and a pinch that starts on
  a list inside a map goes to the list.

**Plan.** As SPEC.md §11.3–§11.4: accepted gestures in hit regions, one
rule by motion component, opt-in delays, intents, momentum in the state
table, and custom recognizers over `pointerEvents`, `claim` and
`decline`.

**Done when:** interaction tests cover a button in a list in a zoomable
map, a carousel in a vertical list, a pinch that starts on the list, a
slider in a drag-scrolled list, a long press, a double tap next to a
single tap, a flick within one frame, and a lasso written as a module
function against the map's pan.

**Spec.** §11.3, §11.4.

### I1. Drag and drop between elements

**Plan.** `dragging`, `dropped` and `startDrag`, with typed payloads in
the state table, arbitrated by I5.

**Done when:** `zui_testing.Driver.drag` moves an item between two lists,
including out of a list that scrolls by dragging.

**Spec.** §11.5.

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

**Done when (each):** snapshot and lowering tests, and one renderer draws
it; for G3, an interaction test clicks a rotated button; for G6, the
Windows host shows HDR white brighter than SDR white.

**Spec.** §13.1, §13.3, §16.4, §18.

---

## Stage 9: seeing the UI

### V1. `zui_debug`

**Plan.** An inspector over `Frame.inspect`: the element tree, the
hovered element and its configs, diagnostics, lowerings and fallbacks,
and a performance overlay from the tracer.

**Done when:** `zui_testing` drives it over the Documents view, and the
demo toggles it with a key.

**Spec.** §19.7.

### V2. Semantics and accessibility actions

**Plan.** `Frame.semantics()` with `features.semantics`; actions arrive as
events and answer through the intent queries.

**Done when:** a widget test checks the list for each control, and the
Windows host bridges it to UI Automation.

**Spec.** §13.5.

### V3. Safety sweeps

**Plan.** `features.safety_sweeps`: the invariant checks that read only a
`Frame`, at the end of `endFrame`.

**Done when:** the randomized tests run through it, and a debug demo runs
with it on.

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
- **Packing the per-element fields declaration writes** into one record.
  Since the `depth` fix, no instruction in the box tree's declaration has
  more than 4% of its samples, so there is no hot spot for it yet.
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
| Budgets | as in SPEC.md §20.2, including warm text < 120 µs and declaration < 55 µs |
| Where the contracts live | in the `zui` repo |
| Native hosts | one `zui-host` repo, one directory per OS |
| Who orchestrates | the host, through one contract; adapters for libraries that own their window (H1) |
| Signals | lifecycle events; uncatchable signals are not representable |
| Input | an ordered event log with host instants, many pointers (I4) |
| Gesture arbitration | elements declare what they accept; one rule, by motion component (I5) |
| Custom gestures | code in declaration over `pointerEvents` and `state`, not a registry |
| Comparing two commits | each commit's own benchmarks, alternated, judged by the middle half beyond 2% (R2) |
| The inspector | a module over `Frame.inspect` (V1) |
| Animation | not in the core; `zui_motion` (M1) |
| Safety checks | built, as `features.safety_sweeps` (V3) |
| Instruction counts | Callgrind on a fixed CPU model and fixed frames, in a fresh process per scenario and phase; CI fails on 2% growth over the parent (R1) |
| Where the Tracy binding lives (P2) | a `zui_tracy` module in this repository, with Tracy as a lazy dependency, so every backend's demo can trace and applications that do not import it never fetch it |

### Open

Each is planned with its first option. SPEC.md §22 has those that change
the spec.

1. **`Task` restarts:** one run at a time, or generation-tagged runs?
   Planned: one at a time.
2. **`unread_frames_before_release`'s default.** Planned: 30 frames.
3. **A custom recognizer's claim lands a frame late.** Planned: accept it.
4. **Physical keys.** Planned: logical keys plus the opaque scancode.
5. **V4, a web renderer or a thin client over the wire?** Planned: the
   wire client first, since F5 builds it anyway.
6. **H2, sokol_gfx as the first renderer on a native surface?** Planned:
   yes; it already backs zui-sokol.

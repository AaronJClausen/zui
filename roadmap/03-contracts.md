# 03-contracts: The contracts

Stage 3 of SPEC.md §21: the renderer, host and surface contracts; the
generated command union and lowering; `zui_app`; conformance suites; the
raylib adapter.

**Done when:** every backend passes its suite and runs the demo through
`zui_app`.

**Status.** Done. Lowering came with stage 8's commands; the sokol and
terminal renderers remain without a host of their own, and the sokol
renderer gained a native surface with `04-native-host:01-windows-host`.

## Items

| Item | Status |
|---|---|
| `03-contracts:01-renderer-contract` The renderer contract and the generated commands | done |
| `03-contracts:02-host-contract` The host contract | done |
| `03-contracts:03-conformance-suites` Conformance suites | done |
| `03-contracts:04-features` `Features` | done |
| `03-contracts:05-zui-app` `zui_app` | done |
| `03-contracts:06-raylib-adapter-host` The raylib adapter host | done |

---

## 03-contracts:01-renderer-contract — The renderer contract and the generated commands

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
which the renderer contract names, landed here rather than in `03-contracts:02-host-contract`. A frame
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
  command's declaration (`08-effects:01-gradients-shadows-glow`, `08-effects:02-backdrop-blur`, `08-effects:04-transforms`, `08-effects:05-materials`, `08-effects:06-hdr-and-wide-gamut`).
- **The renderer suite.** "Each backend passes `03-contracts:03-conformance-suites`'s renderer suite" is
  `03-contracts:03-conformance-suites`'s: its plan now includes running `expectRendererConforms` in the
  three backends' CI.

## 03-contracts:02-host-contract — The host contract

`zui.checkHost(Host)`: `zuiPoll`, `zuiWaker`, `zuiWait`, `zuiSurface`,
`zuiApply` and `zui_surfaces` required; `zui_capabilities`
(`zui.HostCapabilities`: one window or many, a system material) and the
services (`zuiClipboard` and the rest, each a type until `10-reach:03-services` defines them)
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
- **A host suite and a real host.** "The raylib adapter (`03-contracts:06-raylib-adapter-host`) passes `03-contracts:03-conformance-suites`'s
  host suite" is `03-contracts:06-raylib-adapter-host`'s *Done when*; `03-contracts:03-conformance-suites`'s plan now builds
  `expectHostConforms` from this test host's checks.

## 03-contracts:03-conformance-suites — Conformance suites

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

The host suite generalizes `03-contracts:02-host-contract`'s test host's checks: a poll keeps the
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
its CI runs (`docs/development.md`'s *Conformance suites* is the recipe):
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
- **The host suite against a real host** is `03-contracts:06-raylib-adapter-host`'s: the raylib adapter
  runs `expectHostConforms` in its `conformance` step.
- **Optional commands** are drawn by no scene yet, since no declaration
  produces one; each stage-8 item adds its command to the reference scene
  with the declaration (*Done when* of stage 8).

## 03-contracts:04-features — `Features`

`Features.semantics` (off), `gestures` (on), `flex_wrap` (off) and
`safety_sweeps` (on in safe builds), as SPEC.md §4 gives them, and the
machinery that makes calling an API whose feature is off a compile error
naming the field: each gated API calls `requireFeature(.field, "api()")`
at comptime, and the field comes from `std.meta.FieldEnum(Features)`, so
a message can never name a field that does not exist. Two gated entry
points pin it, each with its compile-error test:
- `Frame.semantics()`, a `[]const zui.SemanticNode` that is empty until
  `09-seeing-the-ui:02-semantics-and-accessibility` declares semantics: "zui: semantics() needs Config.features.semantics = true";
- `ui.manipulation(id)`, a `?zui.Manipulation` that is null until `07-gestures:01-gesture-arbitration`
  recognizes gestures: "zui: manipulation() needs Config.features.gestures = true".

`flex_wrap` and `safety_sweeps` gate nothing yet: their code comes with
`06-text-and-layout:12-wrap` and `09-seeing-the-ui:03-safety-sweeps`. `zig build check` instantiates both stubs with their features on.

Against `0268dbd`, `zig build counts` in a local Docker container: every
scenario identical to the instruction, with today's defaults and with
every feature off (`counts.zig`'s `Config` given `.features` all false
for the run). No feature adds memory to the reservation.

Decided here: `03-contracts:04-features` is the mechanism, and each feature's item gates its
real code behind its field; `09-seeing-the-ui:02-semantics-and-accessibility`, `07-gestures:01-gesture-arbitration`, `06-text-and-layout:12-wrap` and `09-seeing-the-ui:03-safety-sweeps` now say so, and each one's
*Done when* includes `01-measure:03-instruction-counts-in-ci` counts unchanged with its feature off.

## 03-contracts:05-zui-app — `zui_app`

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

The demo runs on it, through `03-contracts:06-raylib-adapter-host`'s host. Its application and loop went
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

## 03-contracts:06-raylib-adapter-host — The raylib adapter host

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

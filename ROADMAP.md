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
| stage 6, early | the single-line fast path (T1), the whole-string cache (T2), the box tree's layout passes (P4, in part), static styles (L8) | done; a box tree of static styles declares in 34.5 µs; warm text and the box tree's layout and emission within their budgets; the box tree's declaration is not (P5) |

No release is tagged; everything is on `main`. From here, work is
tracked by stage rather than by release number. Each stage may be tagged
when it is done.

Measured on the reference machine (i9-10900K), the fastest frame, at
`a6d8e34` but where an item is named, against the budgets of SPEC.md
§20.2:

| Scenario | Declaration | `endFrame` | Budget |
|---|---|---|---|
| 4,096 boxes, depth 8, after P4 | 58.6 µs | 93.4 µs | layout and emission < 100 µs (met; 101.2 µs at `a6d8e34`); declaration < 55 µs (missed; 52.2 µs at `a6d8e34`) |
| 1,000 texts, warm caches, after P4 | 16.9 µs | 91.9 µs | < 120 µs (met; 184.2 µs at `a6d8e34`) |
| 4,000 children of one parent | 52.9 µs | 65.8 µs | |

The P4 rows are the fastest of four runs of `zig build bench --
--check-targets`, whose fastest box-tree frames were 93.4 to 97.9 µs for
layout and emission and 58.6 to 69.5 µs for declaration. The machine runs
slower than when `a6d8e34` was measured: in the same session `afacf87`,
before P4, took 111.0 µs and 68.5 µs (`bench-compare`), where `a6d8e34`
had taken 101.2 µs and 52.2 µs.

## The queue

Work is taken from the top. The first row whose status is not
`waiting` is the next item, and CLAUDE.md says how to take it on. An item
too large for one sitting lands in slices, each a commit with every check
green, and its **Status** line below says which slice is next.

| Item | Stage | Where | Waits for | Status |
|---|---|---|---|---|
| P4. The box tree's layout and emission within budget | 6, early | `src/layout.zig`, `src/emission.zig` | | waiting on P5 |
| P5. The box tree's declaration within budget | 6, early | `src/context.zig` | L8 | |
| T4. Line-break segmentation | 6 | `src/text.zig` | | |
| L1. A grow basis | 6 | `src/layout.zig` | | |
| L2. Aspect ratio and natural sizes | 6 | `src/layout.zig` | | |
| L3. Dividers and decorated images | 6 | `src/emission.zig` | | |
| L4. Floating options | 6 | `src/layout.zig`, `src/emission.zig` | | |
| L6. Right-to-left layout | 6 | `src/layout.zig` | | |
| L7. Wrap | 6 | `src/layout.zig` | | |

After the queue come stages 7 to 11 in the order of SPEC.md §21. They join the queue as it runs short.

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

What remains: the copying box tree's declaration budget is P5's.

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

**Status.** Done but for `pinch`, which waits for gestures (I5), and R1's
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
done; momentum and gesture timers join it with I5.

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

**Status.** Layout and emission are within budget; declaration is not,
and moved to P5. Measured first at `afacf87` on the reference machine:
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

### P5. The box tree's declaration within budget

**Grounding.** After P4 the box tree's declaration is 58.6 µs at best
against 55 µs, and 588,146 instructions, 143 a box, of which the scene's
own switch is about 35. What is left:
- **Bytes written.** An `open` stores about 100 bytes into 15 arrays, 56
  of them the layout copy in 12 stores, and timing follows the stores
  more than the instructions: zeroing the two 8-byte sizes in declaration
  costs 8% of it. One frame in flight instead of two changed nothing, so
  it is the stores themselves, not the frames' cache footprint.
- **The element's flags.** Zig writes the `Element`'s `bool` fields as
  `i1` and reads them as `i8`, so LLVM cannot keep them in registers: every
  `open` stores six bytes to the stack and reloads and masks them, about
  30 instructions, even when every field is a default.
- **The machine.** `afacf87` declared the box tree in 68.5 µs here, where
  `a6d8e34` took 52.2 µs when the budget was last met; measure on a quiet
  machine at a fixed frequency first.
- **After L8** the box tree's declaration is 574,326 instructions and
  57.7 µs at best; the same tree with static styles declares in 445,291
  and 34.5 µs, so what is left is the per-element stores, not the copy
  of each layout. The two config references are now 8 bytes each.

**Plan.** With L8's config references in place, pack the per-element
fields declaration writes (parent, counts, kind, content index, flags,
config references) into one record, so an `open` writes two or three
streams instead of 15; then store the flags without reloading the
element's fields, through a different `Element` shape if the compiler
cannot be led to it, which SPEC.md §10.1 would record.

**Done when:** `zig build bench -- --check-targets` meets the declaration
budget on the reference machine, and no scenario is slower by
`bench-compare`.

**Spec.** §5.1, §10.1, §20.2.

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
that opt in, compiled out without `features.flex_wrap`, which C7 added.
Breakpoints are plain code over `ui.viewport()` or `rectOf`. Setting
`Layout.wrap` with the feature off must fail as a gated API does, naming
the field; a field's value is not always known at compile time, so this
item decides how (SPEC.md §8.1 records it).

**Done when:** golden tests for wrapping under each alignment, and with
the feature off, R1 counts are unchanged.

**Spec.** §8.1, §8.2.

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
`decline`. All of it behind `features.gestures`, which C7 added with
`manipulation`, gated and null until this item fills it; each new query
and `Element.gestures` are gated the same way.

**Done when:** interaction tests cover a button in a list in a zoomable
map, a carousel in a vertical list, a pinch that starts on the list, a
slider in a drag-scrolled list, a long press, a double tap next to a
single tap, a flick within one frame, and a lasso written as a module
function against the map's pan; and with the feature off, R1 counts are
unchanged.

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
| Config references (L8) | pointers in element storage, the default layout one constant; an element's own `layout` or `decoration` replaces the style's whole |
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

1. **A custom recognizer's claim lands a frame late.** Planned: accept it.
2. **Physical keys.** Planned: logical keys plus the opaque scancode.
3. **V4, a web renderer or a thin client over the wire?** Planned: the
   wire client first, since F5 builds it anyway.

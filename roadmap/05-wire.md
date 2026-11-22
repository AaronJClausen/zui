# 05-wire: The wire

Stage 5 of SPEC.md §21: relay, replay, `zui_wire`, wire host and
renderer, file watching as a source.

**Done when:** a session replays to identical commands; the demo draws
in another process.

**Status.** Done. Feeds, planned here first, are retired: sources
(`02-frame-record:11-sources-in-core`) are the mechanism for outside
data.

## Items

| Item | Status |
|---|---|
| `05-wire:01-relay` Relay | done |
| `05-wire:02-zui-wire` `zui_wire` | done |
| `05-wire:03-replay-in-testing` Replay in `zui_testing` | done |
| `05-wire:04-rendering-elsewhere` Rendering somewhere else | done |
| `05-wire:05-watching-files` Watching files | done |
| `05-wire:06-wire-payload-types` The wire's renderer declares its context's payload types | done |

---

## 05-wire:01-relay — Relay

**Plan.** `relayTo(listener)`: each applied record, with deliveries from
`zuiDelivery`, without allocating when no listener is attached, in a
`relay` trace zone. **Done when:** a test relays a session into a buffer
and gets back exactly the records applied. **Spec.** §6.8.

`ui.relayTo(listener)` takes a `?Ui.Relay`, `zui.Relay(Ui.FrameRecord)`:
a context pointer and a function, as `Waker` is. At the end of
`beginFrame`, after the sources swap and inside the new `relay` zone,
the listener gets the record as applied: its parameters, the events zui
kept (the first `max_events_per_frame`), and the deliveries, which a
live frame fills from each source's `zuiDelivery` into
`relayed_deliveries` in the context's reservation, and a replayed one
passes through. `relayTo(null)` detaches it.

`core/src/tests/relay.zig` relays a four-frame session (a click with
typed text, a published value, six events where four are kept) into a
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
declaration budget, as before
(`06-text-and-layout:05-box-tree-declaration-budget`).

Decided here:

- **What is relayed** is the record as applied: the events zui kept, so
  a replay of it applies exactly those, and a text event whole, since
  zui cuts it the same way again.
- **Where the relayed deliveries live:** in the reservation, as SPEC.md
  §5 lists "the relay buffer", since a `Delivery` can hold a stream's
  whole capacity and does not belong on the stack.

## 05-wire:02-zui-wire — `zui_wire`

**Plan.** A versioned encoding of records and frames, as deltas;
payloads serialized when plain data and otherwise through
`zuiSerialize`; the text contract's fingerprint. **Done when:** round
trips are tested for every event, delivery and command kind, and a delta
stream of the demo is measured against full frames. **Spec.** §19.6.

A new module, `zui_wire`: `writeHeader` and `readHeader` (magic,
version, the fonts' fingerprint), `Encoder(Ui)` with `writeRecord`,
`writeFrame` and `writeKeyFrame`, and `Decoder(Ui)`, whose `next` gives
a record that `beginFrame` takes or a frame a renderer takes. Values are
written by one comptime codec: integers as LEB128, floats by their bits,
unions by tag, slices by length, errors by name, and a type with
`zuiSerialize` by itself. A record's parameters are written as changes
from the last record's; a frame's commands as runs kept, skipped,
inserted or changed in the fields that differ, against the last frame
written, resynchronized by element id and kind within 32 commands.
`zui_async`'s `Stream` and `KeyedLoads` deliveries serialize only the
items taken. The text contract's `zuiFingerprint` is checked for its
signature (`fn (*const Text) u64`).

`core/zui_wire/tests.zig` round-trips every `Event` and
`EnvironmentChange` kind, every delivery of `zui_async` and one holding
a pointer that sends a number instead, and every command kind whole and
as changes; checks that a key frame lets a reader join, that a message
beyond the decoder's capacity fails, that other fonts and other versions
are rejected; and encodes a live session whose decoded frames are the
frames drawn and whose decoded records replay to the same commands.
Compile-error tests pin a delivery and an `ImageHandle` holding a
pointer, `zuiSerialize` without `zuiDeserialize`, and a wrong
`zuiFingerprint`; `zig build check` encodes and decodes a record and a
frame on every target.

Measured on the sokol renderer's tour at `9b616d5`, declared headlessly
as its tour test does, with real fonts: 120 frames on each of its ten
screens at 1440×900, the mouse crossing each screen, every frame written
whole by one encoder and as changes by another, and each decoded frame
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
  semantics stay with the context; the inspector over the wire, which
  `09-seeing-the-ui:01-zui-debug` left unqueued, adds what it needs
  then.
- **A message that does not fit the decoder** fails with
  `error.CapacityExceeded` rather than keeping what fits, since a delta
  applied in part would corrupt every frame after it.
- **How `zuiSerialize` is reached:** `serializer.write(value)` and
  `deserializer.read(T)`, taken as `anytype`, so a source that declares
  them, as `zui_async`'s do, never imports `zui_wire`. Slices are
  allowed inside it, and in zui's own vocabulary (typed text, dropped
  paths, command text), but not in a payload that serializes
  automatically, since a decoded slice lives only until the next
  message.
- **The fingerprint** is checked only when both sides declare one.

## 05-wire:03-replay-in-testing — Replay in `zui_testing`

**Done when:** a recorded demo session replays to identical commands
without starting any work. **Spec.** §6.8, §19.4.

`zui_testing.Recording(Ui)` is a relay listener that keeps each applied
record, its typed text, dropped paths and deliveries copied into memory
reserved by `init`; a record that does not fit is dropped whole and
counted. `Driver.replay(app, declare, record)` runs one frame from a
record, as `beginFrame` replays it, with no loader between frames.

Replaying the tour showed that `KeyedLoads` did not replay exactly: its
delivery held only the loads completed at a swap, but a key's `.running`
status and progress come from the loader's `toStart` and the producers
between frames, so a replay showed loading tiles as idle. Its delivery
now also carries, when relayed, the keys loading with the progress the
frame saw and the abandoned loads that finished; its `zuiInject` starts
those loads, hands back the abandoned ones, and frees what the live
loader released through `toRelease` before the frame. The live swap pays
one store per abandoned load that finishes; the rest is in
`zuiDelivery`, which runs only with a listener.

Tests: `zui_testing` records three frames of two sources and typed text
and replays them in a fresh context whose sources hold other values; a
recording drops a record too large for it whole; and `zui_async`'s
gallery session, a grid of tiles loaded by key with loads that finish a
frame later, a battery level and a log, replays to the same commands
with no load started.

The demo: in the sokol renderer's tour at `9b616d5`, declared headlessly
with real fonts and its real loaders (tiles loaded on threads,
telemetry), 30 frames on each of its ten screens recorded with
`Recording`, then replayed into a fresh context and a fresh application
whose loaders never run: 300 of 300 frames identical, compared through
`zui_wire.writeKeyFrame`'s bytes, with no wake during the replay, once
the gallery's legend is left out. That legend shows counts its loads
keep in atomics outside its sources (`started`, `completed`, `glitched`,
`abandoned`), which no record carries, so with it 29 gallery frames
differ in those numbers: the application's side of §6.8, which SPEC.md
now names. The tour's relayed records grew from 40 to 79 bytes a frame
on the wire with the keys loading.

Decided here:

- **Replay is a `Driver` method** taking one record, so a test can
  inspect each replayed frame, and `Recording` is the listener that
  keeps them; the spec's `replay(records)` is that loop.
- **A source delivers what its loader changes between frames,** when
  relayed, since a replay runs no loader; `KeyedLoads` is the one
  default source whose view the loader changes.

## 05-wire:04-rendering-elsewhere — Rendering somewhere else

**Plan.** A wire renderer and a wire host, so a remote client is a host
plus a renderer. **Done when:** the demo runs in one process and draws
in another, with input going back. **Spec.** §16.4, §19.6.

`zui_wire.Host(Ui)` takes one end of a `std.Io.net` stream with
`attach`, reads the client's header and first record, then reads records
on a task of the `Io`; a poll gives what arrived since the last one (the
newest viewport and scale, every event in order) in the client's clock,
counted on from the last record between records, so `.at` waits and
wakes need nothing from the client. The connection ending closes the
window. It gives a new `wire` surface, the core's only change, into
which `zui_wire.Renderer(Ui)` writes each frame as changes, after a
header with the application's fonts' fingerprint, from `zui_app`'s
render thread. `zui_wire.Client(Ui)` is the other end, over any host and
renderer: it sends a record when it holds events or the viewport or
scale changed, presents the newest frame that came back and applies its
host requests, reading frames on a task that wakes its host; closing it
stops sending first and reads until the application has closed its end,
so the application never writes into a closed connection.

Tests, over loopback TCP: the wire host passes zui's host suite; an
application run by `zui_app` on the wire host and renderer is drawn by a
client on another thread, two clicks going back and the button's cursor
coming back; a client refuses a stream measured with other fonts; the
host closes on bytes that are not a record and reports `Malformed`. They
pass in the three modes on Windows, and on Linux and x86-linux in
Docker. `zig build check` instantiates the three for every target with a
network.

The demo: the native hosts' `zig build remote -- --check tour.bmp`
starts the tour, unchanged, in a second process on the wire host and
renderer, listening on a loopback port it prints, and draws it in a
window of the Windows host with the sokol renderer through a client. It
presses Ctrl+2, Ctrl+4 and Ctrl+9 and waits for frames showing each
screen's tagline, saves the window, and closes it, after which the
tour's process exits with 0. In five runs in a row on the reference
machine, each run took under a second; the welcome screen's first frame
arrived 3 to 5 ms after the client connected, and each screen came back
within the script's 50 ms polling interval of its key.

Decided here:

- **Who makes the connection:** the application, which hands the wire
  host a stream with `attach` (under `zui_app`, in its `init`), since a
  host's `init` takes only the `Io` and the window's options.
- **Whose clock a record carries:** the client's host's; the wire host
  counts on from the last record, so the client sends only records with
  events or a new viewport or scale, never one for time alone.
- **Where host requests go:** with the frame, which already carries
  them, for the client to apply to its own host; the wire host's
  `zuiApply` does nothing.
- **What a client skips:** frames that arrive faster than it presents
  them; each is decoded, since frames are changes, and only the newest
  is drawn.

## 05-wire:05-watching-files — Watching files

**Plan.** A source of file changes from the host (`zuiFileWatch`), which
`zui_debug` uses to reload themes and assets. **Done when:** editing a
theme file restyles the running demo. **Spec.** §16.3.

zui (`ad90c3a`) gained the vocabulary: `zui.FileChange`, plain data with
its path inline (255 bytes, relative, `/`-separated), so a source of
them relays, replays and goes over the wire; `.rescan` for changes the
OS lost or a path that does not fit; `zui.FileChangeSink`, a pointer and
a function as `Waker` is, which `.of(&source)` makes from any source
whose `publish` returns `Wake` or `error{Full}!Wake`; and
`zui.FileWatchError`. `checkHost` checks
`zuiFileWatch.watch(host, directory, sink) zui.FileWatchError!void`,
pinned by a compile-error test. Tests: a test host's watch publishes
into a source and wakes once; a too-long path is a `.rescan`; a
`zui_async.Stream` of changes reaches a frame and reports a refusal; a
delivery of changes round-trips through `zui_wire`; `zig build check`
watches on every target. Nothing on a hot path changed.

The Windows host (`0e9690f`) watches up to four directories with their
subdirectories: a thread per directory issues each overlapped
`ReadDirectoryChangesW` and publishes each change, waking the window for
the first since the last frame; `watch` returns once the first read is
pending, so no change after it is missed. Tests against a hidden window
see files added, written, renamed, added in a new subdirectory and
removed, each within 2 s, and a missing directory and a fifth watch
fail.

The demo is the native hosts' `zig build theme`: a window in the colors
of a ZON theme, whose application declares a `Stream(zui.FileChange)`
and a `Latest(Theme)` among its sources; declaration sees the theme's
file among the changes, and the loader reads and parses it into the
`Latest`, so a replay restyles as the live run did. `-- --check` writes
a dark theme, waits for a frame drawing it, writes a light one over it,
and fails unless a frame draws the light background within 10 s. In
three runs on the reference machine each restyled in the second frame
after the first, 2.4 to 3.6 ms after the write.

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

Since then, `zui_debug` (`09-seeing-the-ui:01-zui-debug`) reloads its
theme this way (`389e497`). The demo is an example of the native hosts'
rather than the sokol renderer's tour, which was changing under another
item at the time.

## 05-wire:06-wire-payload-types — The wire's renderer declares its context's payload types

**Plan.** `zui_wire.Renderer(Ui)` declares `Ui`'s `ImageHandle`,
`CustomData`, `MaterialHandle` and `FontId`. **Done when:**
`zui.checkRenderer` accepts `zui_wire.Renderer` of the tests'
every-command context, and `zui_app.contextConfig` of it gives back that
context's payload types.

The renderer declared `zui_commands` from `Ui` but none of its payload
types, so for a `Ui` with `.material` among its commands
`zui.checkRenderer` failed ("… .zui_commands includes .material but …
.MaterialHandle is void"), and `zui_app.contextConfig` of it lost a
`Ui`'s images, custom payloads and materials. It now takes each from
`Ui.RenderCommand`: the image's and the material's handle types, the
`custom` payload's type when there is one, and `Ui.FontId`. The plan
said to declare each only when it is not `void`, but Zig cannot declare
conditionally, and a `void` declaration is what `checkRenderer` and
`contextConfig` already take for an absent one. A test checks the
renderer of the every-command context and that `zui.Context` of
`contextConfig` of it is that context again; it fails to compile without
the change with the message above.

The native hosts' `remote` example, `zui.checkRenderer` of
`zui_wire.Renderer(tour.kit.Ui)`, failed the same way against the tour
of `5242889`, which has a Materials screen; with this commit it compiles
(`zig build check -Dtarget=x86_64-windows`), and needs no change of its
own. Nothing on a hot path changed. The sokol renderer (`374702f`) and
the native hosts (`b10af14`) build on this commit, and the hosts' check
for x86_64 and aarch64 Windows compiles the `remote` example.

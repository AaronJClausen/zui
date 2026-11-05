# Async: sources in, demand out

This is the design contract for how data produced outside a frame reaches
declaration in zui, and how the UI tells that work whether anyone is
still looking. It covers the core's part (the source contract, the
frame-boundary swap, demand, the shared status vocabulary) and the
optional `zui_async` module (the default sources). SPEC.md §10.1's
threading contract, §10.2's frames in flight and §10.5's parallel
measurement are unchanged by it.

The whole model fits in one sentence: **sources are swapped in at
`beginFrame`, and demand comes out of `endFrame`.** It is the same shape
as input and hit regions, so it adds a boundary rule to nothing.

---

## 1. Principles

1. **zui owns no one's work and no one's compute.** It starts nothing,
   cancels nothing, and never runs application code on another thread.
   Work belongs to whoever started it, on the `Io` they chose.
2. **Nothing on the UI thread waits for async work.** Not in
   `beginFrame`, not in declaration, not in `endFrame`. The only wait in
   a frame is still the render thread's backpressure (SPEC.md §10.2).
3. **Declaration never starts work; it expresses demand.** Reading a
   source records that it was read. Work is started between frames, by
   the application's own code, from that demand. This is what keeps
   replay free of real I/O and keeps an inline `Io` from blocking
   declaration.
4. **Everything inbound is applied at `beginFrame`** (SPEC.md principle
   8). Sources are swapped there, so declaration never sees data change
   under it, and every delivery is part of the frame record.
5. **The handoff calls no `Io`.** Publishing is plain atomics over memory
   reserved up front, so it behaves the same on every producer (§7).
6. **Registration is comptime.** The application names its sources as
   fields of one struct type. There is no run-time registry, no stored
   pointer into application memory between frames, and no source that
   can be forgotten.
7. **The core holds the contract and the vocabulary; the module holds
   the data structures.** Anything that implements the contract is a
   source, so the defaults in `zui_async` are never the only option.

### What this deliberately is not

- **Not a task runner.** zui never calls `io.async`, `io.concurrent` or
  `Future.cancel` for application work.
- **Not a cancelation mechanism.** The UI can *request* abandonment
  through a flag the producer reads; only the producer decides to stop.
- **Not reactive.** There are no operators, no derived sources and no
  callbacks into the UI. A source delivers values to a frame, and
  declaration decides what they mean.
- **Not ownership.** zui never frees, releases or retires a value a
  producer made. The application does, on the UI thread, when a source
  tells it a value is no longer needed (§6.4).

---

## 2. Terms

| Term | Meaning |
|---|---|
| **Source** | a value, owned by the application, that producers publish into and the UI reads from. A field of the application's `Sources` struct. |
| **Producer** | code that publishes into a source, on any thread or `Io`, including the UI thread itself. |
| **Swap** | what `beginFrame` does to each source: take what producers published since the last swap and make it readable for the frame. |
| **Delivery** | what one source received in one swap, as a plain value. A frame's deliveries are part of its frame record. |
| **View** | the read-only handle declaration gets from `ui.source(.field)`. The only way to read a source. |
| **Demand** | what the frame read: one bit per source, plus the keys asked of keyed sources. Produced at `endFrame`. |
| **Loader** | the application's code that runs between frames, reads demand, and starts or releases work. |
| **Wake** | `Platform.wake` (later the host's `wake`), called by a producer so a sleeping loop runs a frame. |

---

## 3. The frame

```
                 producers (any thread, any Io)
                     │ publish / push / finish
                     ▼
 ┌───────────── Sources (application memory) ─────────────┐
 │                                                        │
 │   beginFrame ── swap every source ──▶ deliveries       │
 │       │                              (frame record)    │
 │   declaration ── ui.source(.x) ──▶ view, marks demand  │
 │       │                                                │
 │   endFrame ──▶ commands, hit regions, … , demand       │
 └────────────────────────────────────────────────────────┘
                     │
                  loader (UI thread, between frames)
                     │ reads demand; starts, abandons, releases
                     ▼
                 producers
```

### 3.1 The loop

```zig
while (backend.pollEvents(ui.needsFrame())) |input| {
    ui.beginFrame(input, &app.sources);
    declare(&ui, &app);
    const frame = ui.endFrame() catch ui.lastFrame();
    backend.render(frame.commands());
    ui.release(frame);

    app.runLoader(&ui, io, &renderer);
}
```

The loader runs after `endFrame`, so it sees the demand of the frame
just declared, and before the wait, so work it starts can wake the next
one. `zui_app.run` (ARCHITECTURE.md §3.1) calls an application's
`zuiLoader` declaration at that point when it has one.

### 3.2 `beginFrame`

After resolving input (SPEC.md §5), `beginFrame` calls `zuiSwap` on each
field of `Sources`, in field order, in an `inline for`. Each swap is a
few instructions when nothing was published (one atomic load). It then
clears the frame's demand bits.

The `sources` pointer must stay valid until `endFrame` returns. zui does
not keep it past that.

### 3.3 Declaration

`ui.source(.field)` sets the field's demand bit and returns the source's
`View`. Every read of every source in the frame sees the same data: what
the swap made readable. Calling `ui.source` outside a frame panics in
safe builds.

### 3.4 `endFrame`

After emission, `endFrame`:
1. records, for each source whose bit is set, that it was read in this
   frame (for `framesSinceRead`, §5);
2. calls `zuiEndFrame` on each source that declares it, with the frame
   number and `frames_in_flight`, so keyed sources can settle their
   demand (§6.4).

### 3.5 `needsFrame`

`ui.needsFrame()` is also true when any source that declares
`zuiPending` reports something published but not yet swapped. That
covers a publish that lands after a frame's swap but before the loop
decides whether to sleep.

---

## 4. The core's API

### 4.1 Configuration

```zig
pub const Config = struct {
    // ...
    /// The application's sources: a struct whose every field is a source (§4.4).
    Sources: type = void,
};
```

When `Sources` is `void`, nothing in this document generates any code.

### 4.2 Frame functions

```zig
// With Sources = void:
pub fn beginFrame(self: *Self, input: Input) void
// Otherwise:
pub fn beginFrame(self: *Self, input: Input, sources: *config.Sources) void
pub fn beginFrameInjecting(self: *Self, input: Input, sources: *config.Sources, deliveries: *const Deliveries) void
```

`beginFrame` is chosen at comptime
(`pub const beginFrame = if (config.Sources == void) ... else ...;`), as
`custom` exists only when `CustomData` is set. `beginFrameInjecting`
calls `zuiInject` with the recorded delivery instead of `zuiSwap`, for
replay and tests (§9).

### 4.3 Reading and demand

```zig
pub const SourceField = std.meta.FieldEnum(config.Sources);
pub const Deliveries = zui.Deliveries(config.Sources);

pub fn source(self: *Self, comptime field: SourceField) SourceView(field)
pub fn framesSinceRead(self: *const Self, comptime field: SourceField) u64
```

- **`source`** marks the field's demand bit and returns its `View`.
- **`framesSinceRead`** is 0 when the last completed frame read the
  source, 1 when the one before did, and so on; `maxInt(u64)` when no
  frame has. It is counted in frames, not time: an idle UI draws no
  frames, so the count holds still while nothing is shown changing, and
  a sleeping application never looks as if no one were watching.
- **`Deliveries`** is a struct built with `@Struct`, with one field per
  source, named as in `Sources`, whose type is that source's `Delivery`.

### 4.4 The source contract

A source is a struct with these declarations. The check runs when
`Context` is instantiated, the way `Platform`'s does (SPEC.md §8.1).

```zig
const MySource = struct {
    /// Required. What one swap received, as a plain value.
    pub const Delivery = ...;
    /// Required. The read-only handle declaration gets.
    pub const View = ...;

    /// Required. UI thread, in beginFrame: make what was published readable.
    pub fn zuiSwap(self: *MySource) void { ... }
    /// Required. UI thread, in declaration: the frame's view of the source.
    pub fn zuiView(self: *MySource) View { ... }
    /// Required. UI thread, after a swap: what that swap received, for the relay tap.
    pub fn zuiDelivery(self: *const MySource, delivery: *Delivery) void { ... }
    /// Required. UI thread, in place of zuiSwap: make a recorded delivery readable.
    pub fn zuiInject(self: *MySource, delivery: *const Delivery) void { ... }

    /// Optional. Any thread: whether something is published and not yet swapped.
    pub fn zuiPending(self: *const MySource) bool { ... }
    /// Optional. UI thread, in endFrame: settle this frame's demand.
    pub fn zuiEndFrame(self: *MySource, info: zui.EndFrameInfo) void { ... }
    /// Optional. UI thread, after zuiSwap: publishes refused since the last swap.
    pub fn zuiRefusedCount(self: *MySource) u32 { ... }
};

pub const EndFrameInfo = struct {
    frame_number: u64,
    frames_in_flight: u8,
};
```

The defaults when an optional declaration is missing:

| Declaration | Without it |
|---|---|
| `zuiPending` | the source never makes `needsFrame` true; its producers' wakes still end a wait |
| `zuiEndFrame` | nothing is called at `endFrame` |
| `zuiRefusedCount` | refusals are not reported |

The checks, each with an exact message pinned by a compile-error test:
- `Sources` must be a struct:
  `"zui: Config.Sources must be a struct of sources, got u32"`;
- every field must be a source:
  ``"zui: field `cache` of AppSources is not a zui source: missing `zuiSwap`"``;
- unknown `pub` declarations starting with `zui` are rejected, so a
  misspelled optional one is never silently ignored:
  ``"zui: field `quotes` of AppSources declares unknown `zuiPendng`"``;
- each declaration must have the signature above, reported by name.

### 4.5 Reporting refusals

After each swap, `beginFrame` adds `zuiRefusedCount` into the frame's
diagnostics, as SPEC.md §13.2's other limits are reported: the part that
fit is kept, `endFrame` returns `error.CapacityExceeded`, and
`ui.diagnostics()` names the source field and how many publishes it
refused, so the message says what to raise:
``"zui: source `quotes` refused 12 items; raise its capacity"``.

### 4.6 The status vocabulary

```zig
pub fn Status(comptime Result: type) type
pub fn StatusWithProgress(comptime Result: type, comptime Progress: type) type
```

`Status(Result)` is `StatusWithProgress(Result, void)`. The union is
generated from `Result`:

| Tag | Payload | When |
|---|---|---|
| `.idle` | none | nothing has been started |
| `.running` | `Progress` | started, not finished |
| `.ready` | the payload of `Result` | finished with a value |
| `.failed` | the error set of `Result` | finished with an error; **only when `Result` is an error union**, so an infallible status has no `.failed` prong |
| `.canceled` | none | the producer gave up, with `error.Canceled` |

`Status` is plain data in the core, so a widget module can take one
without knowing where it came from:

```zig
widgets.asyncImage(ui, .indexed("thumbnail", index), thumbnails.get(path_hash));
```

`error.Canceled` is removed from `.failed`'s error set, since it has a
tag of its own.

---

## 5. Interest

Demand is the one way the UI tells producers who is looking, and it is
plain data on the UI thread:
- **For any source,** `ui.framesSinceRead(.field)` after `endFrame`.
- **For keyed sources,** the keys asked of the view this frame, which
  the source settles in `zuiEndFrame` (§6.4).

The loader turns demand into whatever the producer needs, by the
application's own policy. For a producer that wants to stop mid-work,
`zui_async`'s task and keyed sources carry an **abandon request**: an
atomic flag the UI sets and the producer reads at its own pace. It is
written only when demand changes, never every frame, and nothing waits
on it.

A one-frame flicker (a tab switch, a loading screen in place of the
content, a section collapsed and reopened) costs nothing: the policy
decides how many unread frames mean "gone", not the first frame that
did not read.

---

## 6. `zui_async`: the default sources

An optional module, built only on the public API (SPEC.md §3). Every
type here implements §4.4.

| Source | For | Producers | Delivery |
|---|---|---|---|
| `Latest(T)` | only the newest value matters: a battery state, a sync status, a progress figure | one | `?T`: the value, if a new one was swapped |
| `Stream(T, options)` | each item, in order: messages, log lines, quotes | one or many | the items swapped this frame |
| `Task(Result, options)` | one piece of work with a status: a fetch, an export | one run at a time | `?Status`: the status, if it changed |
| `KeyedLoads(Key, Result, options)` | many keyed pieces of work driven by demand: thumbnails, rows of a remote table, search results per query | many | the keys that completed this frame, with their status |

### 6.1 `Latest(T)`: a triple buffer

Three copies of `T` and one atomic byte. The byte holds the index of the
middle buffer and a *fresh* bit.

- **Publish:** the producer writes its own back buffer, then exchanges
  it with the middle buffer and sets the fresh bit, in one atomic
  `swap` (`acq_rel`). It never waits.
- **Swap:** `zuiSwap` loads the byte (`acquire`). If the fresh bit is
  clear, it does nothing. Otherwise it exchanges the front buffer with
  the middle one and clears the bit, in one atomic `swap`.
- **Read:** the view reads the front buffer in place, all frame. No one
  else touches it until the next swap, so there is no copy out and no
  lock.

```zig
pub fn Latest(comptime T: type) type

pub fn publish(self: *@This(), value: T) Wake
pub fn publishAndWake(self: *@This(), value: T, waker: Waker) void

// View:
pub fn get(view: View) ?*const T       // null until the first publish
pub fn changed(view: View) bool        // a new value was swapped this frame
```

The rules:
- **One producer.** Safe builds record the publishing thread on the
  first publish and assert it never changes.
- **Values are overwritten unseen.** Two publishes between swaps lose
  the first. A `Latest` therefore holds plain data or handles whose
  lifetime the producer does not end. A value that owns a resource goes
  through a `Stream`, a `Task` or `KeyedLoads`, which never overwrite
  what the UI has not seen.
- **Large data by handle.** Every publish copies `T` once, so a large
  result is published as a pointer to immutable data the producer owns
  (§8.3).

### 6.2 `Stream(T, options)`: a bounded ring

```zig
pub const StreamOptions = struct {
    /// Power of two. Includes the items the current frame is reading.
    capacity: u32,
    producers: enum { one, many } = .one,
};

pub fn Stream(comptime T: type, comptime options: StreamOptions) type

pub fn push(self: *@This(), item: T) error{Full}!Wake
pub fn pushAndWake(self: *@This(), item: T, waker: Waker) error{Full}!void

// View:
pub fn items(view: View) Items          // iterator, in push order
pub fn count(view: View) u32
```

- **`.producers = .many`** is a bounded queue with a sequence number per
  slot. A producer claims a position with a compare-and-swap on the head
  (it may retry, which is lock-free, not wait-free), writes the item,
  then stores the slot's sequence (`release`). The item is written while
  the slot is exclusively the producer's, so there is no data race.
- **`.producers = .one`** compiles to the same layout with a plain store
  of the head and no compare-and-swap. The option is comptime because it
  changes the generated code (SPEC.md principle 5).
- **Swap:** `zuiSwap` first releases the slots the previous frame read
  (storing their sequences one lap ahead), then walks forward from the
  tail while each slot's sequence (`acquire`) says it is written. It
  stops at the first slot that is claimed but not yet written, without
  waiting; that item and those after it arrive next frame.
- **Read in place.** The frame's items stay in their slots until the
  next swap, so the view reads them without copying. They may wrap past
  the end of the ring, which is why `items` is an iterator.
- **When full, the newest is refused.** `push` returns `error.Full` and
  the item stays the producer's, so nothing it owns leaks. The refusal
  is counted, and reported at the next swap (§4.5).

Refusing the newest is the only full policy. Dropping the oldest would
mean the producer advancing the consumer's tail, which races with the
consumer reading it; the safe way to do that is to copy the item out and
retry if a write overlapped, which is formally a data race in Zig's
memory model and is reported by ThreadSanitizer. Code that only wants
the newest value wants a `Latest`.

### 6.3 `Task(Result, options)`: one piece of work, with a status

```zig
pub const TaskOptions = struct {
    Progress: type = void,
};

pub fn Task(comptime Result: type, comptime options: TaskOptions) type

// UI thread:
pub fn begin(self: *@This(), waker: Waker) error{RunOutstanding}!Run
pub fn requestAbandon(self: *@This()) void
pub fn isIdle(self: *const @This()) bool   // never begun, or cleared

// Producer, through the Run:
pub fn progress(run: Run, value: options.Progress) void
pub fn finish(run: Run, result: Result) void
pub fn abandonRequested(run: Run) bool

// View:
pub fn status(view: View) StatusWithProgress(Result, options.Progress)
pub fn changed(view: View) bool
```

A `Task` is a `Latest` of its status, with the run's bookkeeping:
- **`begin`** is called by the loader, on the UI thread. It publishes
  `.running` and returns the `Run` the producer publishes through.
- **One run at a time.** `begin` returns `error.RunOutstanding` until the
  previous run's final status has been swapped, which keeps the triple
  buffer single-producer. Work that is restarted before it finishes,
  such as a search that changes with every key, is keyed work: one key
  per query, in `KeyedLoads`.
- **`finish`** publishes `.ready`, `.failed` or, for `error.Canceled`,
  `.canceled`, and wakes when the source was not already fresh. A `Run`
  is finished exactly once; safe builds assert it.
- **`progress`** publishes `.running` with a new value as often as the
  producer likes. Each frame sees the newest.
- **`requestAbandon`** sets the run's abandon flag. The producer reads it
  with `abandonRequested`, alongside its `Io`'s own cancelation points.

`zui_async.publishing(function)` wraps a function returning `Result` into
one taking a `Run` first, which calls `finish` with what the function
returned, so plain functions need no changes:

```zig
app.work.async(io, zui_async.publishing(fetchPrices), .{ run, io, url });
```

A result that owns resources is released by the application when it
replaces or clears the task (`task.clear()`, UI thread, which returns
the last `.ready` value if there was one). Clearing waits
`frames_in_flight` frames after the value was last read before it hands
the value back, for the reason in §6.4.

### 6.4 `KeyedLoads(Key, Result, options)`: work driven by demand

The thumbnail grid as a library: declaration asks for keys, the loader
starts what was asked for and releases what has not been asked for in a
while, and workers finish loads on any thread.

```zig
pub const KeyedLoadsOptions = struct {
    /// Most keys held at once, wanted, loading or ready.
    capacity: u32,
    /// Unread frames before a key is let go: a ready value is released, a load is asked to abandon.
    unread_frames_before_release: u32 = 30,
    /// Whether ready values must be handed back to the application to release.
    owns_resources: bool = false,
    /// Must fit in 64 bits, as it is published through one atomic.
    Progress: type = void,
};

pub fn KeyedLoads(comptime Key: type, comptime Result: type, comptime options: KeyedLoadsOptions) type

// View (declaration):
pub fn get(view: View, key: Key) StatusWithProgress(Result, options.Progress)

// Loader (UI thread, between frames):
pub fn toStart(self: *@This(), waker: Waker) StartIterator   // yields Load
pub fn toRelease(self: *@This()) ReleaseIterator             // only when owns_resources

// Producer, through the Load:
pub fn key(load: Load) Key
pub fn progress(load: Load, value: options.Progress) void
pub fn finish(load: Load, result: Result) void
pub fn abandonRequested(load: Load) bool
```

How a key moves:

| State | Entered when | `get` returns | Left when |
|---|---|---|---|
| wanted | `get` asked for a key not held | `.idle` | the loader takes it from `toStart` |
| loading | the loader took it | `.running` | the producer finishes; or unread too long, which sets its abandon flag and marks it *abandoned* |
| ready | its completion was swapped | `.ready` or `.failed` | unread too long |
| releasing | let go while ready, or an abandoned load finished | not held: `get` would want it again | the application takes it from `toRelease`, or at once without `owns_resources` |

The rules:
- **`get` never starts work.** A key not held is marked wanted, in
  memory only the UI thread touches. Without a free slot it stays
  `.idle` and counts as refused (§4.5).
- **Completions cannot overflow.** `finish` stores the result in the
  load's slot, which the producer owns while it is loading, then pushes
  `{slot, generation}` onto a many-producer ring of `capacity` entries.
  Each slot completes at most once per claim, so the ring is never full,
  however rarely it is drained. Its bound comes from its claims, not
  from how often something empties it.
- **Generations.** A slot's generation advances whenever it is claimed,
  and a completion carries the generation it was started with, so an
  abandoned load can never complete the next load in its slot.
- **An abandoned load still finishes.** Its slot stays claimed until the
  producer calls `finish`, and its result goes to `toRelease` (or is
  dropped without `owns_resources`), never to `get`. A producer that
  never finishes holds its slot forever.
- **Releasing waits for the render thread.** A value read in frame N may
  be referenced by that frame's commands until the frame is released
  (SPEC.md §10.2). `zuiEndFrame` therefore never lets a value go before
  `max(unread_frames_before_release, frames_in_flight)` unread frames,
  so a texture is never freed under a frame in flight. This is computed,
  not configured, so it cannot be set wrong.
- **`toRelease` exists only with `owns_resources = true`.** Without it,
  calling it is a compile error naming the option, and released slots
  free themselves at `endFrame`. With it, a slot is not reused until the
  application has taken its value, so forgetting `toRelease` shows up as
  a full source in the diagnostics, not as a leak.
- **`Progress` must fit in 64 bits:**
  ``"zui_async: KeyedLoads Progress must fit in 64 bits, got Report (48 bytes); publish an index instead"``.

### 6.5 Waking

```zig
pub const Wake = enum { needed, already_pending };

pub const Waker = struct {
    pub fn of(platform: anytype) Waker  // comptime-generated thunk over Platform.wake
    pub fn wake(self: Waker) void
};
```

Every publish reports whether it moved the source from swapped to fresh.
Only that publish needs to wake the loop; later ones before the next
swap find the wake already pending. A hundred thumbnails finishing in
one frame cost one wake, not a hundred. `Run` and `Load` carry the
`Waker` the loader gave them, so producers of tasks and keyed loads
never see it.

A `Waker` is a context pointer and a function pointer: it is called at
most once per source per frame, never in a hot loop, so it costs nothing
to keep producers free of the `Platform` type.

The host's `wake` must be **sticky**: a wake that arrives while the loop
is not waiting ends its next wait. Otherwise a publish between
`needsFrame` and the wait is lost until the next input. `zui_testing`'s
host suite checks it (ARCHITECTURE.md §5).

---

## 7. Every `Io`, every thread

Publishing calls no `Io` function: no `Io.Queue`, no `Io.Mutex`, no
`Future`. A source therefore behaves the same whatever its producer runs
on:

| Producer runs on | What happens |
|---|---|
| a `std.Io.Threaded` pool | publishes from pool threads; `.producers = .many` where several share a source |
| an evented `Io`'s fibers | a publish never yields, so it is safe from any fiber |
| a single-threaded `Io` | work started in the loader runs inline there, between frames, and publishes before returning; the next swap shows it. Declaration is never blocked, because declaration starts nothing. |
| a raw OS thread, a C library's callback, a GPU readback | publishes with atomics and wakes; nothing else is required |

**A producer that may run on the UI thread must never wait for space.**
With a single-threaded `Io`, a producer that spins on a full `Stream`
would spin forever, because the swap that frees space runs on the same
thread. It handles `error.Full` instead: drop the item, or keep it and
try again later.

**The application joins its own work.** Shutting down is the
application's: it waits for or cancels its work on its own `Io` (an
`Io.Group`, for example) before the sources go away, outside any frame.

---

## 8. Limits zui cannot remove

These are documented, and checked where a check is possible.

### 8.1 A source outlives its producers

Freeing a source under a running producer cannot be made safe without
reference counting. Sources live in application memory, typically one
`Sources` struct beside the `Context`, and the application joins its
work before freeing them.

### 8.2 One reader

Each source is swapped by one `Context`. Two windows with two contexts
each have their own sources; data shared between windows is published
into each, or shared through the application. Safe builds record the
swapping `Context` on the first swap and assert it never changes.

### 8.3 Large data travels by handle

A swap is a pointer exchange, but a publish copies its value once. A
large result (a catalog, a decoded image) is published as a pointer or
handle to immutable data the producer owns, and released through
`Task.clear` or `KeyedLoads.toRelease`.

### 8.4 Pointers mean nothing in another process

A `Delivery` that holds a pointer replays within one process, but not
over the wire (F5). `zui_wire` requires every `Delivery` to be plain
data or to declare `zuiSerialize` and `zuiDeserialize`, checked at
comptime when it is instantiated:
``"zui_wire: delivery of source `catalog` holds a pointer (*const Catalog); declare zuiSerialize on it to send it"``.

### 8.5 Single-producer sources

`Latest` and `Task` have one writer at a time, and `Stream` with
`.producers = .one` too. Safe builds record the producing thread and
assert it never changes. Several producers each get a source, or share a
`.producers = .many` stream.

---

## 9. Relay, replay and tests

### 9.1 The frame record

A frame record is the frame's `Input` and its `Deliveries`. When a relay
listener is attached (ROADMAP.md F2), `beginFrame` fills each field with
that source's `zuiDelivery` after its swap; with no listener, nothing
is copied. The record is complete by construction: every delivery
happens at the swap, and the swap happens in `beginFrame`.

### 9.2 Replay

`beginFrameInjecting(input, sources, deliveries)` makes each recorded
delivery readable through `zuiInject`, in place of `zuiSwap`. Replay
drives declaration only, never the application's loop, so no loader
runs and no producer starts: a replay does no real I/O, because
declaration starts nothing (principle 3). Declaration then reads exactly
what it read when the session was recorded.

### 9.3 Tests

The same path lets a test set any state of a source without threads:

```zig
var driver: zui_testing.Driver(Ui) = .{ .ui = &ui, .sources = &app.sources };

_ = try driver.frameDelivering(&app, App.declare, .{ .catalog = .{ .ready = &test_catalog } });
try std.testing.expect(ui.rectOf(.indexed("thumbnail", 0)) != null);
```

`Driver.frameDelivering` takes a `Deliveries` with defaults, so a test
names only the sources it sets. Demand is checked through
`ui.framesSinceRead` and each keyed source's wanted keys.

The primitives themselves are tested under stress on a threaded `Io`
with `-fsanitize-thread`, with many producers against a reader that
swaps at random intervals, and on a single-threaded `Io` where every
producer runs inline.

---

## 10. A complete example

```zig
const zui = @import("zui");
const zui_async = @import("zui_async");

const ThumbnailLoads = zui_async.KeyedLoads(u64, DecodeError!Texture, .{
    .capacity = 128,
    .owns_resources = true,
});

const AppSources = struct {
    catalog: zui_async.Task(FetchError!*const Catalog, .{ .Progress = f32 }) = .{},
    quotes: zui_async.Stream(Quote, .{ .capacity = 64, .producers = .many }) = .{},
    battery: zui_async.Latest(BatteryState) = .{},
    thumbnails: ThumbnailLoads = .{},
};

const Ui = zui.Context(.{ .Sources = AppSources, .ImageHandle = Texture }, Backend.Platform);

const App = struct {
    sources: AppSources = .{},
    work: std.Io.Group = .init,
    waker: zui_async.Waker,
    catalog_url: []const u8,

    fn runLoader(app: *App, ui: *const Ui, io: std.Io, renderer: *Renderer) void {
        if (ui.framesSinceRead(.catalog) == 0 and app.sources.catalog.isIdle()) {
            if (app.sources.catalog.begin(app.waker)) |run| {
                app.work.async(io, fetchCatalog, .{ run, io, app.catalog_url });
            } else |_| {}
        }

        var to_start = app.sources.thumbnails.toStart(app.waker);
        while (to_start.next()) |load| app.work.async(io, loadThumbnail, .{ load, io });

        var to_release = app.sources.thumbnails.toRelease();
        while (to_release.next()) |released| {
            if (released) |texture| renderer.unload(texture) else |_| {}
        }
    }
};

fn loadThumbnail(load: ThumbnailLoads.Load, io: std.Io) void {
    load.finish(decodeThumbnail(io, load.key(), load));
}

fn declare(ui: *Ui, app: *App) void {
    switch (ui.source(.catalog).status()) {
        .idle, .canceled => widgets.label(ui, "Catalog not loaded"),
        .running => |fraction| widgets.progressBar(ui, .of("catalog_progress"), fraction),
        .ready => |catalog| catalogGrid(ui, catalog),
        .failed => |err| errorBanner(ui, err),
    }

    for (ui.source(.quotes).items()) |quote| tickerRow(ui, quote);

    if (ui.source(.battery).get()) |battery| batteryIcon(ui, battery.*);
}

fn catalogGrid(ui: *Ui, catalog: *const Catalog) void {
    const thumbnails = ui.source(.thumbnails);
    for (catalog.visibleItems(ui), 0..) |item, index| {
        widgets.asyncImage(ui, .indexed("thumbnail", index), thumbnails.get(item.path_hash));
    }
}
```

What the example shows:
- **Declaration only reads.** The catalog is fetched because declaration
  read its status, and thumbnails are loaded because declaration asked
  for their keys; the loader started both, between frames.
- **Scrolling the grid** stops asking for keys that scrolled away. After
  30 unread frames (or `frames_in_flight`, if larger) their textures
  come back through `toRelease`, and loads still running are asked to
  abandon. Scrolling back within those 30 frames finds them ready.
- **The quote feed** has several producers pushing into one stream.
- **The battery** publishes only its newest state.

---

## 11. Costs

| Where | Cost |
|---|---|
| `beginFrame` | one atomic load per source when nothing was published; a buffer exchange or a walk over the new items when something was. Unrolled at comptime, with no list or function pointer. |
| declaration | `ui.source` sets one bit; views read in place, with no copy and no atomic, apart from `KeyedLoads.get`'s lookup in UI-thread memory |
| `endFrame` | one store per source read; `zuiEndFrame` per keyed source, linear in its capacity |
| a publish | one copy of the value and one atomic `swap`; `.producers = .many` adds a compare-and-swap |
| wakes | at most one per source per frame |
| relay | one `zuiDelivery` per source per frame, only while a listener is attached |
| memory | fixed at comptime, in the application's own struct: `Latest(T)` is three `T`s; `Stream` is `capacity` items and sequences; `KeyedLoads` is `capacity` slots and a completion ring of `capacity` |
| code | one instantiation per source type; with `Sources = void`, none |

Producer-side and reader-side atomics sit on separate cache lines
(`align(std.atomic.cache_line)`), so a producer publishing on another
core does not slow the reader's loads down, and the reader writes
nothing a producer reads every frame.

---

## 12. What is checked, and when

| Mistake | Caught |
|---|---|
| a field of `Sources` that is not a source | compile error naming the field and the missing declaration |
| a misspelled optional source declaration | compile error naming the field and the declaration |
| reading a source that is not in `Sources` | impossible: views come only from `ui.source(.field)`, and `field` is a `FieldEnum` |
| a source that is never swapped | impossible: every field of `Sources` is swapped |
| a `Status` prong missing, or a `.failed` prong on an infallible result | compile error from the exhaustive `switch` |
| `toRelease` without `owns_resources` | compile error naming the option |
| a `KeyedLoads` `Progress` over 64 bits | compile error with the type's size |
| a delivery with a pointer sent over the wire | compile error when `zui_wire` is instantiated |
| a texture released under a frame in flight | impossible: release waits at least `frames_in_flight` unread frames |
| two producers on a single-producer source | safe-build assertion |
| two contexts swapping one source | safe-build assertion |
| a `Run` or `Load` finished twice | safe-build assertion |
| `ui.source` outside a frame | safe-build panic |
| a full source | reported in the frame's diagnostics with the field name (§4.5) |
| forgetting `toRelease` | reported as a full source, not leaked |

---

## 13. Rollout

1. **0.6:** this document lands in SPEC.md §10 and ARCHITECTURE.md
   §2–§3.5. `zui_async` (`Latest`, `Stream`, `Task`, `KeyedLoads`,
   `Waker`) and `zui.Status` ship, with the stress tests. Until the
   contract reaches `beginFrame`, applications call `zuiSwap` and
   `zuiEndFrame` on their sources themselves at the frame boundary.
2. **0.7, the breaking release:** `Config.Sources`, the `beginFrame`
   parameter, `ui.source`, `framesSinceRead`, `needsFrame` over
   `zuiPending`, refusals in the diagnostics, and `zui_app` calling
   `zuiLoader`. `beginFrame` changes in this release anyway, for input
   as an event log (ROADMAP.md I4). zui-raylib's demo moves its
   thumbnail grid onto `KeyedLoads`.
3. **0.9:** the relay tap and replay carry `Deliveries`
   (ROADMAP.md F2, F4), `zui_wire` serializes them with the check in
   §8.4 (F3), and `Driver.frameDelivering` ships in `zui_testing`. File
   watching (F6) is a source.

**Done when:**
- the stress tests pass under ThreadSanitizer, with many producers;
- a test on a single-threaded `Io` loads a grid with every load inline;
- the demo's grid scrolls with no UI-thread wait, and an idle demo
  still uses 0% CPU;
- a hundred loads finishing between two frames cause one wake;
- a frame with ten idle sources costs no more than without them, by
  R1's instruction counts;
- a recorded session with deliveries replays to identical commands
  without starting any work.

---

## 14. Open questions

1. **`unread_frames_before_release`'s default:** 30 frames (half a
   second at 60 Hz), or `state_ttl_frames`'s 2? Planned: 30, since
   reloading a thumbnail costs far more than keeping it.
2. **`Task` restarts:** one run at a time, with restarts going through
   `KeyedLoads`, or runs tagged with a generation so a new one may begin
   while an old one is still finishing? Planned: one at a time, since
   generations would need several writers on one triple buffer.
3. **`zuiLoader` in `zui_app`:** a declaration on the application, as
   above, or a function passed to `run`? Planned: the declaration,
   checked like the others.
4. **The 0.6 interim:** ship `zui_async` with manual swaps in 0.6, or
   wait and ship everything in 0.7? Planned: 0.6, so the demo's grid
   proves `KeyedLoads` before the contract freezes.

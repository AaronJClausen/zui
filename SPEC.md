# zui: specification

zui is an immediate-mode UI engine for Zig 0.16. Each frame, the
application declares its UI as nested function calls. zui lays it out,
resolves interaction, and returns a frame of plain data: render commands,
hit regions, semantics and requests to the host. Drawing, windowing,
fonts, threads and the application's own work all belong to someone else,
and zui reaches each of them only through a contract checked at compile
time.

The whole system fits in one line:

```
Frame = endFrame(declare(beginFrame(state, FrameRecord, Sources)))
```

A **frame record** comes in: time, the viewport, events, and whatever
outside data the application's sources received. A **frame** goes out:
everything a renderer, a host, an accessibility bridge and the
application's loader need. Between the two, declaration reads only what
came in, and nothing changes under it. Every feature in this document is
either part of one of those two values, or part of the state that carries
from one frame to the next.

This document is the contract. Where it states a number, it is a
**budget** the implementation is measured against (§20). §21 orders the
work; ROADMAP.md says what exists today and where each stage stands, and
ARCHITECTURE.md maps where each feature lives across the layers and
repositories.

---

## 1. Principles

1. **Layout and interaction, not rendering.** zui produces data that
   describes what to draw and what was hit. It works with any renderer,
   host or toolkit, including ones that do not exist yet.
2. **One frame boundary.** Everything from outside a frame is applied at
   `beginFrame`, and everything leaving it is produced by `endFrame`.
   Declaration never sees data change under it, so any frame can be
   recorded, relayed, replayed or computed in another process.
3. **Determinism by construction.** A frame is a function of the previous
   frame's persistent state and the frame record. zui reads no clock, no
   environment and no callback during a frame that the record did not
   carry. The application's side of this is documented in §6.8.
4. **Memory fixed at compile time.** All of zui's memory is one
   reservation whose size is a comptime constant. A frame allocates
   nothing, and exceeding a limit is defined, reported behavior, never
   corruption.
5. **Linear time, data-oriented.** Every pass is O(n) in elements and
   text wrapping O(n) in bytes. Elements live in structure-of-arrays in
   declaration order, and no pass recurses.
6. **Plain data in, plain data out.** Configuration is structs with
   defaults. Output is slices of tagged unions. There are no callbacks in
   the hot path, no inheritance and no style cascade.
7. **Comptime proves, precomputes and prunes.** Comptime is used where it
   turns a run-time mistake into a compile error, moves work out of the
   frame, or removes code the application did not ask for. It is not used
   to specialize the layout engine per tree, because that multiplies code
   size for no measured gain.
8. **Contracts, never implementations.** Every dependency on the outside
   world is a comptime contract defined in the core: text, renderers,
   hosts, sources, tracers. The core names no concrete backend. Every
   default zui ships is a module built on the public API, replaceable by
   the application's own.
9. **zui owns no application work.** It starts nothing, cancels nothing,
   and never runs application code on another thread. Outside data
   arrives through sources; what the UI wants goes out as demand.
10. **Pay only for what you declare.** A feature that is off, a payload
    type that is `void` or a source struct that is empty generates no
    code, no memory and no per-frame cost.
11. **Nothing is silent.** Exceeded limits, refused publishes, lowered
    commands and fallbacks in effect are all reported, by name, in terms
    of the `Config` field or contract declaration that changes them.

### Non-goals

| Not in zui | Why | Where it goes instead |
|---|---|---|
| rasterization, GPU, windows, OS services | platform-specific; owning them ties zui to one stack | renderers and hosts, behind contracts (§16) |
| font loading, shaping, glyph rasterization | large, and every platform already has them | the text contract (§9.4) |
| a retained widget tree | immediate mode is the model | the keyed state table (§12) |
| a style cascade | it costs time per element and hides where values come from | themes and skins as plain structs (§18) |
| a task runner or scheduler | work belongs to the application and its `Io` | sources and demand (§14) |
| reactive data flow | operators and derived streams hide when values change | sources deliver plain values to a frame (§14) |
| localization (numbers, dates, plurals) | a library of its own | the application |

---

## 2. Glossary

| Term | Meaning |
|---|---|
| **Context** | owns all of zui's memory for one independent surface (a window, an offscreen panel). Not thread-safe. |
| **Frame record** | everything inbound for one frame: parameters, events and source deliveries (§6.2). |
| **Frame** | everything outbound from one frame: commands, hit regions, semantics, host requests, diagnostics (§6.5). Immutable after `endFrame`. |
| **Declaration** | the application's calls between `beginFrame` and `endFrame`. |
| **Element** | a node declared with `open`/`close`, or a leaf such as `text`. |
| **Id** | a 64-bit hash naming an element across frames. Required for anything interactive or stateful. |
| **Contract** | a set of `zui`-prefixed declarations a type provides to play a role: text, renderer, host, source, tracer, skin (§16). |
| **Source** | application memory that producers publish into from any thread, swapped into the frame at `beginFrame` (§14). |
| **Demand** | what declaration read from sources, reported after `endFrame` (§14.5). |
| **Loader** | application code that runs between frames, reads demand, and starts or releases work. |
| **State slot** | per-id, per-type memory that survives across frames while its element is declared (§12). |
| **Lowering** | replacing a command the renderer did not declare with one it can draw (§13.3). |

---

## 3. System shape

### 3.1 Layers

| Layer | Holds | Bound |
|---|---|---|
| **Core** (`zui`) | layout, interaction, state, the frame boundary, sources and demand, the shared vocabulary, every contract and its checks | no OS calls, no drawing, no threads of its own beyond `Io` it is given; identical behavior on every target |
| **Modules** (`zui_*`, this repo) | defaults built on the public API: async sources, widgets, reflection, testing, tracing, the app runner, wire, debug, motion, color, icons | the public API only, enforced by the module boundary (§3.3) |
| **Renderers** | drawing, fonts, text measurement, images, materials | implement the renderer and text contracts; never import a host |
| **Hosts** | windows, the event loop, OS events and services, frame pacing | implement the host contract; never import a renderer |
| **Theme packs** | design languages as skins | data only |

```
                          application
                               │
                    zui_app (optional runner)
              ┌────────────────┼─────────────────┐
            host               │              renderer
   (native, adapter, wire)     │      (sokol, raylib, web, wire)
              └───────┬────────┴────────┬────────┘
                      │                 │
        modules: async, widgets,     zui_wire
        motion, debug, color, ...       │
                      └────────┬────────┘
                               │
                           zui core
           (engine, vocabulary, contracts and their checks)
```

- **The core depends on nothing,** and owns the vocabulary every layer
  speaks: `FrameRecord`, `Event`, `RenderCommand`, `Color`, `Rect`,
  `Instant`, `Surface`, `Waker`, `Status`, the capability sets. A
  renderer that imports `zui` only for those types pays nothing for the
  engine, because Zig analyzes only what is used.
- **Hosts and renderers meet at one type,** `zui.Surface` (§16.4).
- **The application, or `zui_app`, is the composition root.** It is the
  only place that names a concrete host and renderer.

### 3.2 Repositories

| Repository | Holds |
|---|---|
| `zui` | the core, the contracts, and the modules |
| `zui-host` | native hosts, one directory per OS |
| `zui-raylib`, `zui-sokol`, `zui-terminal`, `zui-web` | renderers; `zui-raylib` also ships an adapter host |
| `zui-themes` | skins for OS design languages |
| `zui-examples` | samples and the template project |

### 3.3 The module boundary

Each module's root file is named after it (`zui_widgets/zui_widgets.zig`),
because Zig names types after their file and users read those names in
compile errors. A module can import only files in its own directory, so
modules reach zui only through `@import("zui")`: **the compiler keeps
them on the public API.** Anything a module does, application code can do,
and any module can be replaced by the application's own. A module may also
import its own build options (`zui_tracy_options`) and a third-party
library it binds, never another part of zui.

### 3.4 Build options

| Option | Default | Effect |
|---|---|---|
| `-Dzui-debug=bool` | `false` | `Id.of` keeps its name, so panics and diagnostics name elements. Off, those paths are never analyzed. It is a build option, not a `Config` field, because ids are created outside any `Context`. |

Everything else is per-`Context` configuration (§4).

### 3.5 Targets

The core builds for every target Zig does, including 32-bit, big-endian,
`wasm32-freestanding` and freestanding embedded. It uses no OS API, keeps
no global state, never assumes `usize` is 64 bits, and can run with
`frames_in_flight = 1` on an `Io` that has no threads (§15). CI builds a
full frame for each of these classes.

---

## 4. Configuration

```zig
pub fn Context(comptime config: Config) type

pub const Config = struct {
    limits: Limits = .{},

    /// The text contract (§9.4). `void` removes `text` from the API.
    Text: type = void,
    /// The application's sources (§14). `void` generates nothing.
    Sources: type = void,
    /// Optional commands the renderer draws; the rest are lowered (§13.3).
    commands: CommandSet = .initEmpty(),

    ImageHandle: type = void,     // the renderer's image, e.g. a texture id; `void` removes `image`
    CustomData: type = void,      // what a self-drawn element carries, e.g. a 3D viewport's camera
    MaterialHandle: type = void,  // the renderer's shader or material
    FontId: type = u16,           // the renderer's font identifier, passed back in `MeasureKey`
    Color: type = zui.Color,      // `zui.Color` (RGBA8) or `zui.ExtendedColor` (HDR)

    features: Features = .{},
    /// Frames alive at once: one being declared plus those a renderer holds.
    frames_in_flight: u8 = 2,
};

pub const Limits = struct {
    max_elements: u32 = 4096,               // declared per frame
    max_depth: u16 = 64,                    // nesting of `open` inside `open`
    max_text_bytes: u32 = 64 * 1024,        // UTF-8 bytes of all `text` content per frame
    max_render_commands: u32 = 8192,        // per frame
    state_slots: u32 = 1024,                // persistent `(id, type)` entries (§12); a power of two
    state_frames_until_eviction: u8 = 2,    // counted from the last frame its element was declared
    measure_cache_entries: u32 = 4096,      // the segment cache (§9.3); a power of two
    string_cache_entries: u32 = 1024,       // the whole-string cache (§9.3); a power of two
    max_input_contacts: u8 = 10,            // e.g. fingers, pens and mice touching or hovering at once
    max_events_per_frame: u16 = 256,        // input events kept from one record
    max_text_input_bytes: u16 = 256,        // typed and IME-committed text kept from one record
    parallel_measure_threshold: u32 = 256,  // cache misses in one frame before measuring in parallel
    parallel_measure_capacity: u32 = 4096,  // distinct misses one cold frame can batch
    exit_ghost_commands: u32 = 0,           // commands kept for exit animations; 0 compiles them out
};

pub const Features = struct {
    semantics: bool = false,                          // the accessibility tree (§13.5)
    gestures: bool = true,                            // pan, zoom, drag, long press, double tap (§11.4)
    flex_wrap: bool = false,                          // `Layout.wrap` (§8.1)
    safety_sweeps: bool = std.debug.runtime_safety,   // invariant checks at the end of `endFrame` (§20.1)
    /// The tracer contract (§16.5). `void` compiles tracing out.
    Tracer: type = void,
};
```

### 4.1 What comptime derives from `Config`

| Derived | From | Effect |
|---|---|---|
| element index type | `max_elements` | the smallest whole-byte unsigned integer that holds it (`u16` by default) |
| memory plan | every limit, every payload type | the offset of every array in the reservation, and `required_bytes`, as constants (§5) |
| `RenderCommand` | `commands`, `ImageHandle`, `CustomData`, `MaterialHandle`, `Color` | a union with exactly the variants this renderer draws (§13.1) |
| `FrameRecord`, `Deliveries`, `SourceField` | `Sources` | one delivery field per source, and a `FieldEnum` for `ui.source` (§14) |
| API surface | payload types, `Text`, features | `image`, `custom`, `text`, `semantics` and the gesture queries exist only when their type or feature is set; calling one that does not is a compile error naming the field to set |
| contract checks | `Text`, `Sources`, `Tracer` | run once, at instantiation, with exact messages (§16.1) |

### 4.2 Validation

Every check is a `@compileError` with an exact message, pinned by a
compile-error test:
- `"zui: limits.state_slots must be a power of two, got 1000"` (also
  `measure_cache_entries`, `string_cache_entries`);
- `"zui: frames_in_flight must be at least 1"`;
- `"zui: Color must be zui.Color or zui.ExtendedColor, got [4]u8"`;
- `"zui: commands includes .material but MaterialHandle is void"`;
- every contract violation, in the form of §16.1.

Limit names in diagnostics come from `std.meta.FieldEnum(Limits)`, so a
message can never name a field that does not exist.

---

## 5. Memory

```zig
pub fn init(gpa: Allocator, io: Io, text: *config.Text) Allocator.Error!Self
pub fn initBuffer(buffer: []align(cache_line) u8, io: Io, text: *config.Text) error{BufferTooSmall}!Self
pub fn deinit(self: *Self, gpa: Allocator) void
pub const required_bytes: usize   // the size of the one reservation; what `initBuffer` needs
```

When `Text` is `void`, the `text` parameter is absent.

- **One reservation.** `init` makes exactly one allocation, of
  `required_bytes`, and `initBuffer` makes none, so a UI can live in a
  static buffer. The memory plan is a comptime table of offsets, so
  carving the buffer is a handful of constant additions.
- **What it holds:** `frames_in_flight` frame arenas, the state table,
  the measurement caches, the previous frame's interaction results, the
  pointer table, the relay buffer, and scratch stacks.
- **What `io` is for:** only zui's own work: waiting for a frame a
  renderer holds (§15.2) and measuring cold text in parallel (§15.3). An
  application with `frames_in_flight = 1` and no thread-safe text passes
  any `Io`, and nothing is called on it.
- **A frame touches only what it uses.** Arenas are reserved for the
  worst case, and reset in O(1) by resetting counters. The cost of a
  frame is proportional to what was declared, not to the limits.

### 5.1 Element storage

Per-frame elements are stored as structure-of-arrays in declaration
(pre-) order, so each pass streams only the fields it needs and the tree
needs no child or sibling links:

| Array | Type | Used by |
|---|---|---|
| `id` | `u64` | interaction, state, duplicate detection |
| `parent` | `ElementIndex` | every pass |
| `subtree_end` | `ElementIndex` | walking children, emission |
| `flow_child_count` | `ElementIndex` | sizing |
| `layout`, `decoration` | config reference (§10.3) | sizing, positioning, emission |
| `content` | tagged reference: none, text, image, custom | text, emission |
| `flags` | `packed struct(u16)` | every pass |
| `size`, `min_size`, `position`, `content_size` | `[2]f32` each | layout, hit testing |

A parent's first child is the next element, and each child's next
sibling is `subtree_end[child]`:

```zig
var child = parent + 1;
while (child < frame.subtree_end[parent]) : (child = frame.subtree_end[child]) {
    visit(child);
}
```

Configs are stored once per kind and referenced, so an element without a
decoration costs no decoration memory.

---

## 6. The frame boundary

### 6.1 The loop

With `zui_app` (§19.5), the loop is one call:

```zig
pub fn main(init: std.process.Init) !void {
    try zui_app.run(App, init, .{ .title = "zui demo", .size = .{ 1280, 720 } });
}
```

Written by hand, it is the same six steps, in this order:

```zig
while (host.zuiPoll(window, &record)) {
    ui.beginFrame(&record, &app.sources);
    app.declare(&ui);
    const frame = ui.endFrame();
    try renderer.zuiSubmit(surface, frame);
    ui.release(frame);              // or from the render thread
    app.load(&ui, io);              // the loader: demand → work
    host.zuiWait(ui.nextFrame(&app.sources));
}
```

The loader runs after `endFrame`, so it sees the demand of the frame just
declared, and before the wait, so work it starts can wake the next one.

### 6.2 The frame record

```zig
pub const FrameRecord = struct {   // a Context's is `Ui.FrameRecord`; `zui.FrameRecord` when Sources is void
    params: FrameParams,
    /// In arrival order. Valid until beginFrame returns.
    events: []const Event = &.{},
    /// Set to replay: each source takes its recorded delivery instead of swapping.
    deliveries: ?*const Deliveries = null,   // present only when Sources != void
};

pub const FrameParams = struct {
    now: Instant,              // the host's monotonic clock
    viewport: [2]f32,          // width and height, in layout units
    scale: f32 = 1,            // physical pixels per layout unit, from the display
    zoom: f32 = 1,             // the application's zoom, multiplied into layout
};
```

- **Time is an instant, not a delta.** `ui.dt()` is derived from two
  records' `now`. Deadlines (§6.6), velocities and gesture timers are in
  the same clock, so replay reproduces them exactly.
- **Scale and zoom are parameters,** not callbacks, so a recorded frame
  carries everything its pixels depended on. Layout is in logical units;
  text is measured at `size × zoom`; snapping uses `scale × zoom`.
- **The record is borrowed.** zui copies what it keeps (at most
  `max_events_per_frame` events and `max_text_input_bytes` of text);
  overflow is dropped and reported (§17.2).

### 6.3 `beginFrame`

```zig
pub fn beginFrame(self: *Self, record: *const FrameRecord, sources: *config.Sources) void
pub fn tryBeginFrame(self: *Self, record: *const FrameRecord, sources: *config.Sources) error{NoFreeFrame}!void
```

With `Sources = void`, the `sources` parameter is absent; the variant is
chosen at comptime.

In order:
1. **Take a frame arena.** `beginFrame` waits for one if a renderer holds
   all of them (§15.2), which is zui's only wait. `tryBeginFrame` returns
   `error.NoFreeFrame` instead, for hosts that cannot block.
2. **Advance the state table's generation** and evict slots past their
   TTL (§12).
3. **Apply events in arrival order** (§7): environment changes, then
   pointer, key, text and action events against the previous frame's hit
   regions.
4. **Swap each source,** in `Sources` field order, in an `inline for`; or,
   when `record.deliveries` is set, inject each recorded delivery
   instead (§14.3). Refusals are added to the diagnostics.
5. **Relay.** If a relay listener is attached, it receives the applied
   record, with deliveries filled in (§6.8).

### 6.4 Declaration

The application calls the declaration API (§10). Declaration only
appends to arrays and reads: the previous frame's interaction results,
the current frame's swapped sources, and the state table. No layout
runs, and nothing it reads changes until the next `beginFrame`.

### 6.5 `endFrame` and the frame

```zig
pub fn endFrame(self: *Self) *const Frame
pub fn release(self: *Self, frame: *const Frame) void
```

`endFrame` checks the tree's balance, runs layout (§8), emits (§13),
settles source demand (§14.5), and returns the frame. **It always
returns a usable frame.** If a limit was exceeded, the part that fit was
laid out, and `frame.diagnostics` says what to raise; an application that
wants an error writes `try frame.diagnostics.check()`.

```zig
pub const Frame = struct {
    pub fn commands(self: *const Frame) []const RenderCommand
    pub fn hitRegions(self: *const Frame) []const HitRegion
    pub fn semantics(self: *const Frame) []const SemanticNode     // features.semantics
    pub fn chromeRegions(self: *const Frame) []const ChromeRegion // title bar, resize edges
    pub fn requests(self: *const Frame) HostRequests              // cursor, IME area, text input
    pub fn inspect(self: *const Frame, index: ElementIndex) ElementView   // by declaration order, for inspectors
    pub fn elementCount(self: *const Frame) ElementIndex
    diagnostics: Diagnostics,
    number: u64,                // frames since `init`, from 0
    params: FrameParams,        // the record's: what a renderer needs to draw at the right size and scale
};
```

Everything a frame references lives in its arena and stays valid until
`release`, which is a single atomic store and callable from any thread.

### 6.6 When the next frame is needed

```zig
pub const NextFrame = union(enum) {
    immediately,
    at: Instant,
    on_event,      // sleep until input or a `Waker` wakes the host
};
pub fn nextFrame(self: *const Self, sources: *const config.Sources) NextFrame   // `sources` absent when Sources is void
pub fn requestFrame(self: *Self) void
pub fn requestFrameAt(self: *Self, instant: Instant) void   // e.g. the caret's next blink
```

`nextFrame` is `.immediately` when a source has something not yet
swapped (§14.4) or a frame was requested; otherwise `.at` the earliest of
every `requestFrameAt`, running momentum, and pending long-press and
double-tap timers; otherwise `.on_event`. The host sleeps accordingly, so
an idle UI uses no CPU and a blinking caret costs one frame per blink.

`nextFrame` takes the sources, as `beginFrame` does, because zui holds
no pointer into them between frames (§14.1), and it is called after the
loader, whose publishes must count.

### 6.7 One frame of latency

Interaction queries answer for the **previous** frame's layout, because a
click is resolved against what was on screen when the user clicked.
Declaration therefore never waits for layout, and styles can depend on
interaction before the element is declared.

### 6.8 Relay, replay and determinism

```zig
pub fn relayTo(self: *Self, listener: ?zui.Relay(FrameRecord)) void
```

- **Relay.** A listener receives each applied record during
  `beginFrame`, including the deliveries each source reported through
  `zuiDelivery`. The record is valid only during the call; a listener
  copies what it keeps, and a slow listener buffers on its own side. With
  no listener, nothing is copied.
- **Replay.** Feeding recorded records back, with `deliveries` set,
  drives declaration to the same commands. No loader runs during replay,
  and declaration starts no work (§14.1), so replay does no real I/O.
- **The application's side.** Replay is exact if declaration reads the
  outside world only through the record and its sources: no clock, random
  number or file read that bypasses them. This is documented, not
  enforced. Text measurement is the one outside call during a frame; it
  is deterministic for a given set of fonts, which the wire format
  fingerprints (§19.6).

---

## 7. Input and environment

### 7.1 Events

```zig
pub const Event = union(enum) {
    pointer_down: PointerButton,
    pointer_up: PointerButton,
    pointer_move: PointerMove,      // with coalesced history
    pointer_cancel: PointerId,      // the OS took the pointer
    pointer_leave: PointerId,       // a hovering pointer left the surface
    wheel: Wheel,                   // position, delta, precise or in lines
    key_down: KeyEvent,
    key_up: KeyEvent,
    text: []const u8,               // committed UTF-8
    composition: Composition,       // IME preedit text and caret
    os_gesture: OsGesture,          // pinch, rotate, swipe the OS recognized
    action: AccessibilityAction,    // invoke, set value, scroll, focus, naming an element id
    environment: EnvironmentChange,
    files_dropped: FilesDropped,
    lifecycle: Lifecycle,           // suspend, resume, terminate request, low memory
};

pub const Pointer = struct {
    id: PointerId,
    kind: enum { mouse, touch, pen },
    position: [2]f32,               // layout units, from the surface's top-left
    at: Instant,                    // when the host received it, not when zui applied it
    pressure: f32 = 1,              // 0 to 1; 1 for devices without pressure
    tilt: [2]f32 = .{ 0, 0 },       // a pen's tilt from vertical, in radians, on x and y
};

pub const KeyEvent = struct {
    key: Key,                       // logical: letters, digits, punctuation, navigation, function keys
    modifiers: Modifiers,           // as held at this event
    repeat: bool = false,
    scancode: u32 = 0,              // the host's physical code, opaque, for game-style bindings
    at: Instant,                    // when the host received it
};
```

The rules:
- **Events apply in order.** A press and release in one frame is a
  click; "release, then a new touch" is handled in that order.
- **Moves coalesce per pointer.** Only the last move before another event
  of the same pointer is hit-tested; earlier ones are history, for
  velocity. A mouse reporting at 8 kHz costs one hover hit test per
  pointer per frame.
- **Velocity uses the events' instants,** never a clock read in the
  frame.
- **Touch never hovers.** Mouse and pen hover while over the surface.
- **The pointer table** has `max_input_contacts` slots. A contact beyond
  it is ignored until a slot frees, as digitizers do.
- **Sampled input** (a library that reports only current state) goes
  through `zui.InputSampler`, which turns successive states into events.

### 7.2 Environment

```zig
pub const Environment = struct {
    theme: Theme = .light,                          // enum { light, dark }
    contrast: Contrast = .normal,                   // enum { normal, high }
    reduced_motion: bool = false,
    reduced_transparency: bool = false,
    text_scale: f32 = 1,            // the user's text size preference, e.g. 1.25; applied by skins, not by layout
    locale: Locale = .default,      // a BCP 47 tag of up to 23 bytes, e.g. "fr-CA"; zui only reports it
    direction: ReadingDirection = .left_to_right,   // the language's, which `mirrored = null` follows
    hdr_headroom: f32 = 1,          // display peak over SDR white, e.g. 4; 1 is an SDR display
    power: Power = .plugged,                        // enum { plugged, battery, saver }
    window_focused: bool = true,    // the OS window has keyboard focus, not an element
};

/// One field's new value: `.{ .environment = .{ .theme = .dark } }`.
pub const EnvironmentChange = union(enum) { theme: Environment.Theme, contrast: Environment.Contrast, ... };

pub fn environment(self: *const Self) *const Environment
```

The environment is state the core keeps; `EnvironmentChange` events
update it, one field each, so a record carries only what changed, and the
change applies before the declaration of the frame that carries it.
Skins, motion and widgets read it, which is how a theme follows the
system's dark mode and an animation honors reduced motion.
`ReadingDirection` holds only left to right and right to left, so it is
not `Layout`'s `Direction`, which also flows top to bottom.

### 7.3 Host requests

Some outputs are for the host, not the renderer. They are part of the
frame, so they replay and relay like commands:

```zig
pub const HostRequests = struct {
    cursor: Cursor = .default,          // of the hot element
    text_input: ?TextInputArea = null,  // focused editable's caret rect: where the IME window goes
};
pub const Cursor = enum { default, pointer, text, crosshair, move, grab, grabbing, not_allowed, wait, progress, help,
    resize_horizontal, resize_vertical, resize_nwse, resize_nesw };
pub const TextInputArea = struct { caret: Rect };

pub fn requestTextInput(self: *Self, editable: Id, caret: Id) void   // ui.requestTextInput(id, id.child("caret"))
```

- **The cursor** is that of the innermost element under the hovering
  pointer (the mouse or a pen) that sets `Element.cursor`, so a button
  inside a draggable panel shows the button's. Only interactive elements
  are hit-tested, so a cursor elsewhere has no effect. Touch never hovers
  and never sets one.
- **Text input** is requested by the editable each frame, naming the
  element it draws as its caret; when `editable` is focused, the frame
  carries that element's rectangle as laid out in this frame. A frame
  without a request tells the host to hide its text input.

---

## 8. Layout

### 8.1 The model

Every element is a box with a direction, padding, a gap between its
children, alignment on both axes, and a sizing rule per axis.

```zig
pub const Layout = struct {
    direction: Direction = .left_to_right,   // how children flow: .left_to_right, .right_to_left, .top_to_bottom
    sizing: Sizing2 = .{},
    padding: Edges = .{},                    // logical: start/end resolve by direction
    child_gap: f32 = 0,                      // between adjacent children, not around them
    child_alignment: Alignment2 = .{},       // where the children as a group sit, on each axis
    aspect_ratio: ?f32 = null,               // width / height
    wrap: bool = false,                      // features.flex_wrap
    mirrored: ?bool = null,                  // null: follow the environment's direction
};

pub const Sizing = struct {
    rule: enum(u32) { fit, grow, fixed, percent } = .fit,   // four bytes: no padding to copy
    /// fixed: the size. percent: fraction of the parent's content box. grow: the weight.
    amount: f32 = 0,
    basis: enum(u8) { content, zero } = .content,   // grow only: start from the content's size, or from `min`
    min: f32 = 0,                                   // layout units, for every rule
    max: f32 = std.math.inf(f32),

    pub const fit: Sizing = .{};
    pub const grow: Sizing = .{ .rule = .grow, .amount = 1 };
    pub const grow_equal: Sizing = .{ .rule = .grow, .amount = 1, .basis = .zero };
    pub fn fixed(size: f32) Sizing
    pub fn percent(fraction: f32) Sizing
    pub fn growWeighted(weight: f32) Sizing   // 2: twice the free space of a `.grow` sibling
    pub fn fitBetween(min: f32, max: f32) Sizing
};
```

`Sizing` is a struct with declarations rather than a union so that decl
literals stay short: `.sizing = .{ .width = .grow, .height = .fixed(48) }`.

The meanings, which follow CSS where CSS has an answer:
- **`fit`** is the size of the content, clamped to `min` and `max`.
- **`grow`** with a content basis starts from its content and shares free
  space by weight, as `flex-basis: auto`. With a zero basis it starts
  from its minimum, which gives equal columns while keeping weights.
- **`percent`** is a fraction of the parent's content box, not counting
  gaps. It contributes nothing to a `fit` parent, whose size would
  otherwise depend on it in a cycle.
- **Shrinking.** When children overflow, the largest shrinkable child
  shrinks first until it matches the next largest, never below its
  minimum. Percent children shrink like the others.
- **Aspect ratio** derives height from the settled width. Deriving width
  from height would need a second width pass and is not supported.
- **Direction** is logical. `right_to_left` mirrors rows, alignment,
  padding and floating anchors; `mirrored` applies it to a subtree.
  Bidirectional text inside a run is the text contract's (§9.4).
- **Wrap** moves children that overflow a row onto new lines, for parents
  that opt in, in a pass between distribution and positioning.

### 8.2 Passes

| # | Pass | Order | Work |
|---|---|---|---|
| 0 | measure text | each text | look up whole strings, then segments, through the caches (§9.3) |
| 1 | fit widths | reverse | each `fit` width from its children, plus padding and gaps; each element adds itself into its parent, so no child list is walked |
| 2 | distribute widths | forward | fixed and percent first, then free space by weight, then shrinking |
| 3 | wrap text, apply aspect ratios | each text / each element | lines from the widths pass 0 recorded, looking up a long cached string's segments only if it wraps; heights from widths |
| 4 | fit heights | reverse | as 1 |
| 5 | distribute heights | forward | as 2 |
| 5½ | wrap rows | forward | only for `wrap` parents, compiled out without `features.flex_wrap` |
| 6 | position | forward | a cursor per parent from its content box, alignment, direction and scroll offset; floating elements from their targets (§8.4) |
| 7 | emit | forward, then by layer | commands, clips, hit regions, semantics (§13) |

Widths settle before heights because wrapping needs the width and the
height depends on the wrap. That is the one ordering constraint, and why
the passes come in pairs. Each pass is its own tight loop: fusing passes
was measured slower, so they stay separate.

### 8.3 Clipping and scrolling

- **`clip`** on either axis clips descendants. `clip_begin` carries a
  rectangle already intersected with every enclosing clip, so a renderer
  needs only a scissor stack. Elements and lines entirely outside the
  active clip are not emitted.
- **`scroll`** makes an element scroll on its axes, and clips them. It
  needs an id, because the offset is kept in the state table as a
  `zui.ScrollState`; without one, safe builds panic and release builds
  clip without scrolling.
- **Scrolled children are not shrunk** along the scrolled axis; they keep
  their size, which is what makes them scrollable.
- **The offset is clamped** to `[0, content − size]` at layout time and
  written back. `ui.scrollOffset(id)` and `ui.setScrollOffset(id, offset)`
  read and set it.
- **Routing.** Wheel and pan go to the innermost scroll container under
  the pointer that accepts that axis and still has room, then outward:
  the same rule as every other gesture (§11.4).

### 8.4 Floating elements

```zig
.floating = .{
    .attach_to = .parent,            // .root, or .{ .element = id }
    .anchor = .top_center,           // this point of the floating element
    .attach_point = .bottom_center,  // goes on this point of the target
    .offset = .{ 0, 4 },             // layout units, after anchoring
    .z = 1,                          // paint layer; higher paints above, the root is 0
    .capture = true,                 // false: the pointer passes through
    .clip = .none,                   // .target: clipped to the attach target's clip
},
```

- **They take no space** in their parent's flow.
- **`grow` and `percent`** resolve against the viewport for `.root`, and
  against the parent otherwise.
- **An element target may be declared later.** Floating subtrees whose
  target comes later are placed after pass 6 by shifting the subtree,
  which is contiguous (`index..subtree_end`).
- **They paint in layer `z`,** sorted stably, so declaration order holds
  within a layer, and they escape their ancestors' clips unless
  `.clip = .target`.
- **They win the hit test** over lower layers when `capture` is true, and
  their tree ancestors still count as hovered, so a menu stays hovered
  while the pointer is over its dropdown.

### 8.5 Layout islands *(later, measured)*

An element sized `fixed` on both axes with no floating descendants
attached outside it cannot affect anything outside it, so passes 1–6 may
run for such islands in parallel. It ships only if a benchmark above
roughly 10k elements shows a win (§20).

---

## 9. Text

### 9.1 Style

```zig
pub const TextStyle = struct {
    font: config.FontId = 0,
    size: f32 = 16,                       // layout units, not points
    letter_spacing: f32 = 0,              // layout units added after each glyph
    line_height: f32 = 0,                 // 0: the font's own
    color: config.Color = .black,
    wrap: enum(u8) { words, newlines, none } = .words,   // at break opportunities; only at newlines; never
    alignment: enum(u8) { start, center, end } = .start, // of each line in the box; start follows direction
};

pub fn MeasureKey(comptime FontId: type) type {   // a Context's is `Ui.MeasureKey`
    return struct {
        font: FontId,
        size: f32,              // already multiplied by zoom
        letter_spacing: f32,    // likewise
    };
}
```

`MeasureKey` is generic because `font` has the renderer's own `FontId`
type, so a text contract names it with that type: `zui.MeasureKey(u16)`.

Text is UTF-8 and is copied into the frame arena, so the caller's buffer
may be reused at once.

### 9.2 Wrapping

1. **Segment** each text into break opportunities: ASCII spaces and
   newlines by default, or the text contract's own segmentation (§9.4),
   which is how CJK, Thai and UAX #14 line breaking work.
2. **Measure** each distinct segment once per cache lifetime.
3. **Lay segments into lines** greedily, adding their widths.

- **The fast path.** A text with no paragraph break whose unwrapped width
  fits its box is emitted as one line without walking its segments.
- **Segments are never broken.** A text's minimum width is its widest
  segment, and no pass makes an element narrower than its minimum, so an
  over-wide segment gets a line of its own and overflows, as in CSS.
- **One command per line,** so renderers never wrap.

### 9.3 Caches

| Cache | Key | Holds | Why both |
|---|---|---|---|
| strings | `(hash(bytes), MeasureKey, zoom, wrap)` | the whole text's metrics (unwrapped width, widest segment, has break) and the widths of up to 16 segments | a warm text costs one probe, not one per word, even when it wraps |
| segments | `(hash(bytes), MeasureKey)` | one segment's size | text that changes every frame (`"Frame 1234"`) measures only its new segments |

Both are open-addressed, sized by `Limits`, persistent across frames, and
evict the least recently used entry in the probe window. Hashing is one
wyhash of the bytes, seeded with the key; a string's key also holds the
zoom and the wrap mode, because its metrics are in layout units and its
segments depend on how it wraps. A string of more than 16 segments is
cached by its metrics alone, and its segments are looked up only if it
wraps. Steady-state frames make almost no calls to the text contract.

### 9.4 The text contract

```zig
const Fonts = struct {
    /// Required. Size of `run` in layout units.
    pub fn zuiMeasure(self: *Fonts, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 { ... }

    /// Optional. Break opportunities in `text`; without it, ASCII spaces and newlines.
    pub fn zuiSegment(self: *Fonts, text: []const u8, breaks: *zui.BreakSink) void { ... }
    /// Optional. `zuiMeasure` may be called from several threads at once (§15.3).
    pub const zui_thread_safe = true;
    /// Optional. Identifies the fonts, so a frame measured elsewhere can be checked (§19.6).
    pub fn zuiFingerprint(self: *const Fonts) u64 { ... }
};
```

**Measurement must be additive over segments:** measuring two adjacent
segments separately must sum to measuring them together. zui caches
segments and wraps by adding, so a contract with letter spacing counts
the spacing after every glyph, including the last. Kerning across a
break opportunity is the one effect this cannot express, and is usually
negligible there. A contract that shapes text returns shaped widths.

---

## 10. Declaration

### 10.1 Elements

```zig
pub fn open(self: *Self, element: Element) void
pub fn close(self: *Self) void
pub fn box(self: *Self, element: Element) void                                        // a leaf
pub fn text(self: *Self, content: []const u8, style: TextStyle) void                  // Text != void
pub fn image(self: *Self, image: Image, element: Element) void                        // ImageHandle != void
pub fn custom(self: *Self, data: config.CustomData, element: Element) void            // CustomData != void

pub const Image = struct {
    handle: config.ImageHandle,
    natural_size: ?[2]f32 = null,       // a `fit` image takes this size
    tint: config.Color = .white,        // multiplied into the pixels; white leaves them unchanged
    corner_radius: CornerRadius = .{},
};
```

```zig
pub const Element = struct {
    id: Id = .none,                     // needed for queries, state, scrolling and focus
    style: ?Static(Style) = null,       // comptime-built, zero-copy (§10.3)
    layout: ?Layout = null,             // overrides style.layout
    decoration: ?Decoration = null,     // background, border, corner radius, material, effects
    clip: Axes = .none,                 // the axes on which descendants are cut off, e.g. .vertical
    scroll: ?Scroll = null,
    floating: ?Floating = null,
    interactive: bool = false,          // takes hover, press and click, and blocks them below it
    focusable: bool = false,            // implies interactive
    focus_scope: bool = false,          // Tab cycles inside this subtree, as in a dialog
    disabled: bool = false,             // no hover, press or focus; queries report `.disabled`
    gestures: Gestures = .{},           // features.gestures (§11.4)
    cursor: ?Cursor = null,             // the pointer's shape while this element is hot
    semantics: ?Semantics = null,       // features.semantics (§13.5)
    exit_seconds: f32 = 0,              // limits.exit_ghost_commands (§19.9)
};
```

Only the config kinds that are set are stored. Nesting follows the code,
with `defer`:

```zig
fn toolbar(ui: *Ui, app: *App) void {
    ui.open(.{ .id = .of("toolbar"), .style = styles.toolbar });
    defer ui.close();

    toolButton(ui, .of("save"), "Save", app);
    toolButton(ui, .of("export"), "Export", app);
}
```

A component is a function that declares elements. zui has no component
type, registry or lifecycle.

### 10.2 Ids

```zig
pub const Id = struct {
    hash: u64,
    pub fn of(comptime name: []const u8) Id                              // .of("save")
    pub fn indexed(comptime name: []const u8, index: usize) Id           // a list row: .indexed("row", i)
    pub fn dynamic(name: []const u8) Id                                  // a run-time name, e.g. a file path
    pub fn child(parent: Id, comptime name: []const u8) Id               // inside a repeated component
    pub fn indexedChild(parent: Id, comptime name: []const u8, index: usize) Id
    pub const none: Id;                                                  // zui assigns an internal id
};

pub fn ids(comptime names: anytype) IdSet(names)
```

- **64-bit FNV-1a, by content.** 32-bit ids collide in practice: at 8,000
  ids a frame the birthday bound is about 1% per frame, against about
  2 × 10⁻¹² at 64 bits.
- **`of` and `indexed` hash at compile time.** At run time `of` is a
  constant and `indexed` one mix.
- **Ids are never mixed with their parent implicitly,** so moving an
  element in the tree never silently resets its state. Repeated
  components use `child` and `indexedChild` explicitly.
- **Elements without an id** get an internal one from their parent and
  sibling index. They cannot be queried or hold state.
- **`zui.ids(.{ "save", "export" })`** returns a struct with one `Id`
  field per name, checked at comptime for duplicates and collisions.
  Across a frame, duplicates are detected at run time (§17.1).

### 10.3 Static styles

```zig
pub const Style = struct {
    layout: Layout = .{},
    decoration: Decoration = .{},
};

pub fn Static(comptime T: type) type   // a pointer to a value in read-only memory
pub fn static(comptime value: anytype) Static(@TypeOf(value))

const styles = struct {
    const toolbar = zui.static(zui.Style{
        .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(40) }, .padding = .all(4), .child_gap = 4 },
        .decoration = .{ .background = theme.panel },
    });
};
```

A `Static(T)` can only be made at comptime, so the value lives in
read-only memory for the life of the program. An element with a static
style stores a reference to it instead of copying it: declaration writes
one pointer, not a whole config, and it is safe under any number of
frames in flight. Fields set on the element itself override the style's.

Config references in element storage are therefore pointers, either into
the frame arena or to static memory. The extra width on 64-bit targets is
paid for by never copying a static config; the box tree's declaration
budget (§20.2) is measured with it.

---

## 11. Interaction

### 11.1 Queries

Every query answers for the previous frame, by id:

```zig
pub fn hovered(self: *const Self, id: Id) bool
pub fn pressed(self: *const Self, id: Id) bool
pub fn clicked(self: *const Self, id: Id) bool
pub fn focused(self: *const Self, id: Id) bool
pub fn widgetState(self: *const Self, id: Id) WidgetState
pub fn rectOf(self: *const Self, id: Id) ?Rect                  // as laid out last frame
pub fn pointerLocal(self: *const Self, id: Id) ?[2]f32          // the primary pointer, from the element's top-left
pub fn requestFocus(self: *Self, id: Id) void

pub fn primaryPointer(self: *const Self) ?Pointer               // the mouse, or the first touch still down
pub fn keyPressed(self: *const Self, key: Key) bool
pub fn chordPressed(self: *const Self, chord: Chord) bool
pub fn keyEvents(self: *const Self) []const KeyEvent            // this frame's, in order
pub fn typedText(self: *const Self) []const u8                  // committed text this frame, for the focused element
pub fn composition(self: *const Self) ?Composition
pub fn dt(self: *const Self) f32                                // seconds between this record's `now` and the last
pub fn now(self: *const Self) Instant
pub fn viewport(self: *const Self) [2]f32
pub fn measureText(self: *Self, content: []const u8, style: TextStyle) [2]f32   // through the caches
```

- **Hover.** The hot element is the topmost interactive element under a
  hovering pointer: highest layer, then last painted. It and each
  interactive ancestor containing the pointer are hovered.
- **Press and click** go to the hot element. A click is a press and a
  release on the same element by the same pointer, and lasts one frame.
  `pressed` is true while any pointer whose press began on the element is
  down.
- **Keyboard and accessibility activation.** Enter or Space on the
  focused element, and an `invoke` action naming the element, also count
  as `clicked`, so everything clickable works without a pointer.
- **`widgetState`** is `.disabled`, `.pressed`, `.hovered`, `.focused` or
  `.idle`, checked in that order. Skins index it with `std.EnumArray`, so
  a new state is a compile error in every skin until it is handled.
- **The answers come from a compact copy** of the previous frame's
  rectangles, hit regions and tab order, kept in the `Context` so they
  survive `frames_in_flight = 1`.

### 11.2 Focus

Pressing a focusable element focuses it; pressing elsewhere clears focus;
an element that stops being declared loses it. Tab and Shift-Tab move in
declaration order among focusable, enabled elements, and a `focus_scope`
keeps focus inside its descendants. `requestFocus` takes effect at the
next `beginFrame`.

### 11.3 Intents

Queries that merge devices into what the user meant:

| Query | From |
|---|---|
| `clicked(id)` | click, tap, Enter/Space, `invoke` action |
| `manipulation(id) ?Manipulation` | drag, pinch, rotate, wheel, momentum, `scroll` action: translation, scale, rotation and pivot, summed over the frame |
| `contextRequested(id)` | right click, long press, the menu key |
| `dismissed(id)` | Escape, back, gamepad B |
| `adjusted(id) ?i32` | arrows on a focused slider, a dial, `set_value` action |
| `navigated(id) ?Direction` | arrows, D-pad |

### 11.4 Gestures

*Compiled out without `features.gestures`.*

Elements declare what they accept, as a packed set stored in their hit
region:

```zig
.gestures = .{
    .pan = .vertical,   // the axes it scrolls or pans on: .horizontal, .vertical, .both
    .zoom = true,       // two-pointer scale and rotation
    .drag = true,       // moves a drag-and-drop payload (§11.5), not the view
    .long_press = true,
    .double_tap = true, // delays this element's single tap
    .custom = true,     // the application's recognizer claims or declines
},
```

A scroll container accepts pan on its scrolled axes by default.

- **One rule decides.** Once a pointer passes the touch slop, its axis
  locks, and the pointer goes to the innermost region that accepts that
  motion component and still has room to move. That rule is also scroll
  chaining. With two pointers, scale and rotation go to the innermost
  region that accepts zoom. A release nothing claimed is a tap.
- **Delays are opt-in and local.** Only an element with `double_tap`
  delays its single tap until the double-tap window passes.
- **Momentum** is state in the state table under the element, so it ends
  when the element is no longer declared, and it sets the next frame's
  deadline (§6.6).
- **Custom recognizers are code in declaration.** `ui.pointerEvents(id)`
  returns the frame's events of pointers pressed on or claimed by `id`.
  A recognizer keeps its state in `state(id, T)`. An element with
  `custom` holds its ancestors off a pointer until it calls
  `ui.claim(pointer)` or `ui.decline(pointer)`; the decision applies at
  the next `beginFrame`, and no events are lost meanwhile. A module ships
  a recognizer as a plain function.

### 11.5 Drag and drop

```zig
pub fn dragging(self: *const Self, source: Id) ?Drag
pub fn dropped(self: *Self, target: Id, comptime Payload: type) ?Payload   // released on `target` this frame
pub fn startDrag(self: *Self, source: Id, payload: anytype) void
```

A drag source declares `.gestures.drag`, so §11.4 decides between
dragging, scrolling and clicking. The payload lives in the state table,
typed, so dropping one type on a target that expects another yields
`null`, never a reinterpretation. Files from the OS are a
`files_dropped` event, not this.

---

## 12. Persistent state

```zig
pub fn state(self: *Self, id: Id, comptime T: type) *T              // zeroed on first use
pub fn stateIfPresent(self: *Self, id: Id, comptime T: type) ?*T   // null instead of creating it
```

- **Keyed by `(id, type)`.** The same id can hold a `ScrollState` and an
  application's `Expanded` flag in separate slots, and asking for another
  type never returns the wrong one.
- **Fixed slots.** `@sizeOf(T) <= 64` and `@alignOf(T) <= 16`, checked at
  comptime; the error says to store an index to the application's own
  storage instead.
- **Eviction.** A slot untouched for `state_frames_until_eviction`
  frames is freed at the next `beginFrame`, with backward-shift deletion,
  so the table accumulates no tombstones. An element that disappears loses its state:
  the immediate-mode equivalent of unmounting.
- **Full table.** `state` returns zeroed scratch memory and the frame
  reports the `state_slots` limit (§17.2). Nothing is corrupted.

Scroll offsets, focus, caret positions, gesture and momentum state,
motion and drag payloads all live here.

---

## 13. Output

### 13.1 Render commands

```zig
pub const RenderCommand = struct {
    bounds: Rect,       // layout units, snapped to physical pixels
    id: u64,            // the declaring element's id hash, for custom renderers and inspectors
    z: i16,             // paint layer, from `floating.z`
    payload: Payload,   // generated from Config
};
```

**Base commands** exist for every renderer: `rectangle`, `border`,
`text` (one per line), `clip_begin`, `clip_end`, plus `image` when
`ImageHandle` is set and `custom` when `CustomData` is set.
**Optional commands** exist only when `Config.commands` includes them:
`gradient`, `shadow`, `backdrop_blur`, `transform_begin`/`transform_end`,
`material`.

`Payload` is a union built with `@Union` from exactly those variants, so
a renderer's exhaustive `switch` covers what it draws and nothing else.
Adding an optional command to zui never breaks an existing renderer;
adding a base command always does, at compile time.

### 13.2 Order and snapping

`Frame.commands()` is in paint order: by layer, then declaration order.
A border is emitted after its element's subtree. Bounds snap to whole
physical pixels using the frame's `scale × zoom`.

### 13.3 Lowering

Emission replaces what the renderer did not declare, so the renderer
never sees it:

| Optional | Lowered to |
|---|---|
| gradient | a rectangle in its mean color, in OKLab |
| shadow, glow | nothing |
| backdrop blur | a rectangle in its fallback tint |
| transform | the untransformed element; its hit region stays untransformed |
| material | the element's fallback background |
| `ExtendedColor` without `.extended_color` | the color clamped to `Color` |

Capabilities are comptime-known, so lowering costs nothing when the
renderer supports everything, and each lowering is listed in the frame's
diagnostics for the inspector.

### 13.4 Hit regions and chrome

Hit regions carry the id, rectangle, clip, layer, flags and accepted
gestures of every interactive or floating-capture element. Chrome
regions mark title bars and resize edges, so a host with a custom title
bar still lets the OS move, resize and snap the window.

### 13.5 Semantics

*With `features.semantics`.*

`.semantics = .{ .role = .button, .label = "Save" }` adds an entry to
`Frame.semantics()`: id, role, label, value, bounds, state and supported
actions, in tree order. A host bridges it to the platform's accessibility
API, and actions come back as `action` events naming the id, answered by
the same queries as other input (§11.3). An element's gestures are the
actions it reports. Without the feature, none of this is compiled.

---

## 14. Sources: data in, demand out

### 14.1 Principles

1. **zui starts nothing, cancels nothing,** and never runs application
   code on another thread. Work belongs to whoever started it, on the
   `Io` they chose.
2. **Nothing on the UI thread waits for outside work.** The only wait in
   a frame is a renderer's backpressure (§15.2).
3. **Declaration never starts work; it expresses demand.** Reading a
   source records that it was read. The loader starts work between
   frames, from that demand. This keeps replay free of I/O and keeps an
   inline `Io` from blocking declaration.
4. **Sources are swapped at `beginFrame`,** so declaration never sees
   them change and every delivery is in the frame record.
5. **The handoff calls no `Io`.** Publishing is plain atomics over memory
   reserved up front, so it behaves the same from a thread pool, a fiber,
   a single-threaded `Io`, an OS thread or a C callback.
6. **Registration is comptime.** Sources are the fields of one struct
   type. There is no run-time registry, no stored pointer into
   application memory between frames, and no source that can be
   forgotten.
7. **The core holds the contract; modules hold the data structures.**
   Anything that implements §14.2 is a source.

### 14.2 The source contract

```zig
const MySource = struct {
    /// Required. What one swap received, as a value: `?T` for `Latest(T)`.
    pub const Delivery = ...;
    /// Required. The read-only handle declaration gets: `.get()`, `.items()`, `.status()`.
    pub const View = ...;

    /// Required. UI thread, in beginFrame: make what was published readable.
    pub fn zuiSwap(self: *MySource) void { ... }
    /// Required. UI thread, in declaration.
    pub fn zuiView(self: *MySource) View { ... }
    /// Required. UI thread, after a swap: what it received, for the relay.
    pub fn zuiDelivery(self: *const MySource, delivery: *Delivery) void { ... }
    /// Required. UI thread, instead of zuiSwap: make a recorded delivery readable.
    pub fn zuiInject(self: *MySource, delivery: *const Delivery) void { ... }

    /// Optional. Any thread: published and not yet swapped.
    pub fn zuiPending(self: *const MySource) bool { ... }
    /// Optional. UI thread, in endFrame: settle this frame's demand.
    pub fn zuiEndFrame(self: *MySource, info: zui.EndFrameInfo) void { ... }
    /// Optional. UI thread, after zuiSwap: publishes refused since the last swap.
    pub fn zuiRefusedCount(self: *MySource) u32 { ... }
};

pub const EndFrameInfo = struct {
    frame_number: u64,
    frames_in_flight: u8,   // a value read this frame may be in use until this many frames pass
};
```

| Optional | Without it |
|---|---|
| `zuiPending` | the source never makes `nextFrame` immediate; its producers' wakes still end a wait |
| `zuiEndFrame` | nothing is called at `endFrame` |
| `zuiRefusedCount` | refusals are not reported |

### 14.3 The core's API

```zig
pub const SourceField = std.meta.FieldEnum(config.Sources);
pub const Deliveries = zui.Deliveries(config.Sources);

pub fn source(self: *Self, comptime field: SourceField) SourceView(field)          // ui.source(.quotes)
pub fn framesSinceRead(self: *const Self, comptime field: SourceField) u64       // frames, not time (§14.5)
```

- **`source`** records the frame's demand for the field and returns its
  `View`. Every read in a frame sees what the swap made readable. Outside
  a frame it panics, in every build: zui holds the sources only from
  `beginFrame` to `endFrame`, so there is no view to read.
- **Without sources** (`Sources = void`), `source` and `framesSinceRead`
  are compile errors naming the field to set, and `beginFrame`,
  `tryBeginFrame` and `nextFrame` take no `sources` parameter.
- **`Deliveries`** is a struct built with `@Struct`, one field per
  source, named as in `Sources`, typed as that source's `Delivery`.
- **Replay** sets `FrameRecord.deliveries`, and `beginFrame` calls
  `zuiInject` instead of `zuiSwap` (§6.3). There is one entry point for
  live and recorded frames.

### 14.4 Waking

```zig
pub const Waker = struct {
    context: *anyopaque,                     // the host's own pointer, passed back to `wakeFn`
    wakeFn: *const fn (*anyopaque) void,
    pub fn wake(self: Waker) void
    pub fn wakeIf(self: Waker, wake_needed: Wake) void   // wakes only for `.needed`: `waker.wakeIf(source.publish(value))`
};
pub const Wake = enum {
    needed,             // this publish made the source fresh: call `wake`
    already_pending,    // an earlier publish since the last swap already did
};
```

`Waker` is core vocabulary: a host makes one (§16.3), and any source can
use it without depending on a module. Every publish reports whether it
moved the source from swapped to fresh; only that publish wakes, so a
hundred loads finishing between two frames cost one wake. A `Waker` is
called at most once per source per frame, so its indirect call costs
nothing that matters, and it keeps producers free of the host's type.

A host's wake must be **sticky**: one that arrives while the loop is not
waiting ends its next wait. Otherwise a publish between `nextFrame` and
the wait is lost. The host conformance suite checks it (§19.4).

### 14.5 Demand

- **Per source:** `framesSinceRead(.field)` is 0 when the last completed
  frame read it (or the frame being declared has), 1 when the one before
  did, and `maxInt(u64)` when none has. It counts frames, not time, so a
  sleeping UI never looks as if no one were watching. A read costs one
  store, of the frame's number into a per-source counter, so a frame
  settles nothing for sources it did not read.
- **Per key:** keyed sources record the keys their view was asked for,
  and settle them in `zuiEndFrame`.
- **Abandoning.** Keyed and task sources carry an atomic abandon flag the
  UI sets when demand lapses and the producer reads at its own pace. It
  is written only when demand changes, and nothing waits on it.
- **Flicker is free.** A policy counts unread frames before letting go,
  so a tab switch or a collapsed section reopened next frame costs
  nothing.

### 14.6 Status

```zig
pub fn Status(comptime Result: type) type
pub fn StatusWithProgress(comptime Result: type, comptime Progress: type) type
```

| Tag | Payload | When |
|---|---|---|
| `.idle` | none | nothing started |
| `.running` | `Progress` | started, not finished |
| `.ready` | the payload of `Result` | finished with a value |
| `.failed` | the error set of `Result` | **only when `Result` is an error union with an error other than `Canceled`** |
| `.canceled` | none | the producer gave up with `error.Canceled` |

`Status` is plain core data, so a widget can take one without knowing
where it came from, and an infallible result has no `.failed` prong to
handle. `Status(R).fromResult(result)` makes `.ready`, `.failed` or
`.canceled` from what the work returned, and always turns
`error.Canceled` into `.canceled`. The `.failed` payload still has
`Canceled` in its type, because Zig cannot build an error set at
comptime, but `fromResult` never puts it there.

### 14.7 Refusals

A full source refuses the newest publish; the item stays the producer's,
so nothing leaks. After each swap, the count from `zuiRefusedCount` is
added to the frame's diagnostics: `refused_publishes` sums every
source's, and `first_refusing_source` names the field whose capacity to
raise (`"quotes"`). A refusal makes `diagnostics.check()` return
`error.CapacityExceeded`, as any exceeded limit does (§17.2).
Drop-oldest is not offered: it would have the producer advance the
reader's tail, which races with the read.

### 14.8 Limits zui cannot remove

- **A source outlives its producers.** The application joins its work on
  its own `Io` (an `Io.Group`) before freeing its sources.
- **One reader.** A source is swapped by one `Context`; safe builds
  assert it in the source, since the core keeps nothing in the source
  to tell two contexts apart. `zui_async`'s sources assert that the
  frame numbers `zuiEndFrame` sees only increase.
- **Large data travels by handle.** A publish copies its value once, so
  a catalog or decoded image is published as a handle to immutable data,
  and handed back for release by the source.
- **A producer that may run on the UI thread never waits for space.** On
  a single-threaded `Io`, the swap that would free space runs on the same
  thread; it handles `error.Full` instead.
- **Pointers mean nothing in another process.** `zui_wire` requires each
  `Delivery` to be plain data or to declare `zuiSerialize` and
  `zuiDeserialize`, checked when it is instantiated (§19.6).

### 14.9 What is checked

| Mistake | Caught |
|---|---|
| `Sources` not a struct, or a field that is not a source | compile error naming the field and the missing declaration |
| a misspelled optional declaration | compile error (§16.1) |
| reading a source not in `Sources` | impossible: `field` is a `FieldEnum` |
| a source never swapped | impossible: every field is swapped |
| a missing `Status` prong, or `.failed` on an infallible result | compile error from the exhaustive switch |
| two contexts swapping one source; two producers on a single-producer source; a run finished twice | safe-build assertion in `zui_async`'s sources |
| a full source; a forgotten release | diagnostics naming the field |

---

## 15. Concurrency

### 15.1 Threading contract

| Object | Contract |
|---|---|
| `Context` | one thread at a time from `beginFrame` through `endFrame`; the thread may change between frames |
| `*const Frame` | immutable after `endFrame`; readable from any thread until `release` |
| `release` | any thread; one atomic store |
| a source | published into from any thread; swapped, read and settled by its one `Context` |
| `Waker.wake` | any thread; sticky |
| the text contract | the UI thread, and also zui's measuring tasks when `zui_thread_safe` |

### 15.2 Frames in flight

With `frames_in_flight = 2`, the UI thread declares frame N+1 while a
render thread submits frame N. `beginFrame` takes the next released
arena, or waits on an `Io.Event` that `release` sets: the only place zui
blocks, and the backpressure that keeps the UI at most
`frames_in_flight` frames ahead. The event is reset before a second check
for a free arena, which closes the race with a `release` between the
check and the wait. Each arena owns everything its frame references, so
the threads share no mutable memory.

### 15.3 Parallel measurement

With `zui_thread_safe` text, text is measured inline until a frame has
made `parallel_measure_threshold` calls. The frame is then evidently cold
(the first frame, a font or zoom change), so zui collects the rest of
the frame's distinct misses, measures them in batches across an
`Io.Group`, stores them in the cache, and continues inline on hits. Warm
frames never pay for the check. A cancelation of the frame's task keeps
the measurements made and passes the cancelation on.

### 15.4 Many contexts

Contexts share nothing, so separate windows, an offscreen panel or a
thumbnail render run their frames concurrently with no code in zui. Each
context has its own sources; data shared between windows is published
into each.

---

## 16. Contracts

### 16.1 How every contract is checked

A type implements a contract by declaring `zui`-prefixed members.
Everything else on the type is its own business, so a contract never
collides with its API, and one type may implement several (a renderer is
usually also the text contract).

**The exceptions are types the application names directly,** which keep
their plain names because they are the implementer's own API as much as
the contract's:

| Contract | Unprefixed declarations | Why |
|---|---|---|
| Source | `Delivery`, `View` | the application writes `Source.View`; the wire format names `Delivery` |
| Renderer | `ImageHandle`, `MaterialHandle`, `CustomData`, `FontId` | they are the renderer's real types, which `contextConfig` copies into `Config` |

These are the only plain names a contract reads. They are checked like
the prefixed ones: a missing required one is a compile error, and an
optional one that is absent takes its documented default (`void` for the
payload types, `u16` for `FontId`).

- **A missing required declaration** is a compile error naming the type,
  the contract and the declaration:
  ``"zui: SokolRenderer does not implement zui.Renderer: missing `zuiSubmit`"``.
- **A wrong signature** is reported by name, with the expected type.
- **An unknown `zui`-prefixed declaration** (one that belongs to no zui
  contract) is a compile error, so a misspelled optional one is never
  silently ignored: ``"zui: AppSources.quotes declares unknown `zuiPendng`"``.
- **Every optional declaration has a documented default.**
- Each message is pinned by a compile-error test.

### 16.2 Renderer

```zig
const SokolRenderer = struct {
    pub const zui_commands: zui.CommandSet = .initMany(&.{ .gradient, .shadow });              // optional commands it draws
    pub const zui_surfaces: zui.SurfaceKinds = .initMany(&.{ .win32, .cocoa, .wayland, .x11 }); // native windows it can draw into
    pub const zui_extended_color = false;                                                      // accepts HDR colors
    pub const ImageHandle = Texture;
    pub const MaterialHandle = void;
    pub const FontId = u16;

    pub fn zuiSubmit(self: *SokolRenderer, surface: zui.Surface, frame: anytype) !void { ... }   // frame: *const Ui.Frame
    pub fn zuiMeasure(self: *SokolRenderer, run: []const u8, key: zui.MeasureKey(FontId)) [2]f32 { ... }
};
```

`frame` is `anytype` because a renderer is not generic over the
`Context` that made the frame. What checks that it draws what the frame
holds is its exhaustive `switch` over each command's payload: a command
the renderer did not declare is a compile error at that `switch`.
`zui.checkRenderer(Renderer)` checks the rest of the contract.

`zui_app.contextConfig(Renderer, .{ ... })` builds a `Config` from a
renderer's declarations (commands, payload types, text), so the
renderer's vocabulary and the core's never disagree.

### 16.3 Host

```zig
const Win32Host = struct {
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .many, .system_material = true }; // material: Mica, vibrancy
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.win32);

    pub fn zuiPoll(self: *Win32Host, window: zui.WindowId, record: *zui.RecordBuilder) bool { ... } // false: the window closed
    pub fn zuiWaker(self: *Win32Host) zui.Waker { ... }
    pub fn zuiWait(self: *Win32Host, next: zui.NextFrame) void { ... }
    pub fn zuiSurface(self: *Win32Host, window: zui.WindowId) zui.Surface { ... }
    pub fn zuiApply(self: *Win32Host, window: zui.WindowId, requests: zui.HostRequests) void { ... } // cursor, IME window

    pub const zuiClipboard = struct { ... };       // optional services
    pub const zuiNotifications = struct { ... };
    pub const zuiFileDialogs = struct { ... };
    pub const zuiOpenUrl = struct { ... };
    pub const zuiMenus = struct { ... };
    pub const zuiFileWatch = struct { ... };       // a source of file changes
};
```

- **Native hosts** own the window and loop, one per OS.
- **Adapter hosts** wrap a library that insists on owning its window
  (raylib), with fewer capabilities, through `InputSampler`.
- **Signal handlers** only set an atomic flag and wake; the lifecycle
  event arrives in the next record. SIGKILL and SIGSTOP cannot be caught,
  so they are not values of `Lifecycle`.
- **Services** are optional nested declarations, reached through
  `zui_app` with `has_*` guards (§16.6).

### 16.4 Surface

`zui.Surface` is a tagged union of native handles: `win32`, `cocoa`,
`wayland`, `x11`, `web`, `offscreen`; plus `terminal`, a character grid
by its size in cells, and `library`, a window that a library such as
raylib or sokol_app creates and draws into itself, which only that
library's adapter host provides. A host and renderer whose
`zui_surfaces` share no kind are a compile error naming both. Output
formats (an FP16 swapchain for HDR) are negotiated through it, and fall
back to SDR unless both sides support them.

### 16.5 Tracer

```zig
const TracyTracer = struct {
    pub fn zuiBegin(comptime zone: zui.TraceZone) Span { ... }   // zone: e.g. .fit_widths, .emit, .swap_sources
    pub fn zuiEnd(span: Span) void { ... }
};
```

With `Features.Tracer` set, every pass, emission step and `beginFrame`
step is a zone. With `void`, no tracing code is analyzed, so an off
build's instruction counts are unchanged.

| Zone | Encloses |
|---|---|
| `begin_frame` | `wait_for_frame`, `evict_state`, `apply_events`, `swap_sources` when `Sources` has a field, `relay` (§6.3) |
| `end_frame` | `measure_text`, `fit_widths`, `distribute_widths`, `wrap_text`, `fit_heights`, `distribute_heights`, `position` (§8.2), then `emit`, and `sort_layers` when a frame has floating layers |

- **`zuiBegin` and `zuiEnd` are plain functions,** with no tracer value,
  because profilers keep their state per thread. Both are called on the
  thread running the frame, and zones nest.
- **`zuiBegin` takes the zone at comptime,** so a binding can make one
  static source location per zone, as Tracy requires.
- **`Span`** is whatever `zuiBegin` returns; `zuiEnd` takes exactly that
  type.
- **`zui_tracy`** is the Tracy binding (§19.10).

### 16.6 When something is missing

| Case | Absence is | Examples |
|---|---|---|
| zui needs it | **a compile error** naming it | `zuiMeasure`; a base command a renderer cannot draw; a host without `zuiPoll` |
| zui uses it implicitly | **a documented fallback** | no material: the fallback background; no blur: the tint; an unhandled lifecycle event: the OS default |
| the application asks for it by name | **a compile error at the call**, unless guarded by `has_*` | notifications on a target without them |
| the target has it, this machine does not | **a returned status** | Mica on Windows 10; notifications the user denied |

`zui_app` reports every fallback in effect at run time, and the inspector
lists them, so none is silent to a developer who looks.

---

## 17. Errors and diagnostics

Declaration functions never return errors. Failures are reported once per
frame, with full context.

### 17.1 Programmer errors

| Condition | Safe builds | Release builds |
|---|---|---|
| unbalanced `open`/`close` | panic naming the unclosed element | closed implicitly; reported |
| `close` without `open` | panic | ignored; reported |
| duplicate id in a frame | panic naming both declarations | the second is non-interactive; reported |
| `scroll` or `focusable` without an id | panic | clips without scrolling / not focusable; reported |
| `ui.source` outside a frame | panic | panic: zui holds no sources between frames (§14.3) |

With `-Dzui-debug`, ids keep their names, so messages read
`zui: duplicate id "save" (0x…) in one frame`.

### 17.2 Limits

Elements, depth, text bytes, commands, state slots, cache entries,
events, pointers, ghost commands and source capacities all fail the same
way:
1. The part that fits is kept. Overflowing elements are dropped, their
   subtrees skipped cheaply with depth still tracked, so `close` pairs up.
2. `frame.diagnostics` records which limit, by how much, the peak needed,
   and the id where it first happened.
3. `frame.diagnostics.check()` returns `error.CapacityExceeded` for
   applications that want to stop; `zui_app` logs it once per limit.

---

## 18. Styling, color and themes

- **`Color`** is RGBA8, with `.rgb(0x3366ff)`, `.rgba`, `.mix`, and
  comptime conversion from hex. **`ExtendedColor`** is 4×f16 linear
  scRGB, where 1.0 is SDR white; values above it are HDR, values outside
  0–1 are wide gamut. `Config.Color` picks one, so an SDR application
  keeps 4-byte colors.
- **A theme is the application's struct.** zui has no theme registry, no
  inheritance and no cascade. Switching theme passes a different value,
  and costs a field read.
- **State-dependent styles** index `std.EnumArray(WidgetState, T)`, so a
  new state is a compile error in every theme until handled.
- **Comptime precomputation:** colors in OKLCH or hex, palettes, and
  whole static styles (§10.3) are computed during the build and live in
  read-only memory.

---

## 19. Modules

Every module is a default built on the public API. Each names what it
rides on, so an application that replaces it knows what to implement.

### 19.1 `zui_async`: the default sources

| Source | For | Producers | Delivery |
|---|---|---|---|
| `Latest(T)` | the newest value only: battery, sync state, progress | one | `?T` if a new one was swapped |
| `Stream(T, .{ .capacity, .producers })` | every item, in order: messages, log lines | one or many | the items swapped this frame |
| `Task(Result, .{ .Progress })` | one piece of work with a status | one run at a time | `?Status` if it changed |
| `KeyedLoads(Key, Result, .{ .capacity, .unread_frames_before_release, .owns_resources, .Progress })` | many keyed loads driven by demand: thumbnails, remote rows, search results per query | many | keys completed this frame, with status |

- **`Latest`** is a triple buffer and one atomic byte (middle index and a
  fresh bit). A publish exchanges the producer's back buffer with the
  middle one; a swap exchanges front and middle if fresh. The view reads
  the front buffer in place. Two publishes between swaps lose the first,
  so `Latest` holds plain data or handles the producer keeps alive.
- **`Stream`** is a bounded ring with a sequence per slot, its capacity a
  power of two. Many producers claim with a compare-and-swap on the head;
  one producer compiles to a plain store. A swap first releases the slots
  the previous frame read, then walks forward while slots are written,
  stopping without waiting at the first claimed but unwritten slot. Items
  are read in place, through an iterator, because they may wrap.
- **`Task`** is a `Latest` of its status plus run bookkeeping. The loader
  calls `begin(waker)` for a `Run`; the producer calls `progress` and
  exactly one `finish`. `begin` refuses while the previous run's final
  status is unswapped, which keeps it single-producer; restartable work
  is keyed. `CatalogTask.publishing(f)` adapts a plain function into one
  that finishes a `Run`, taking `f`'s arguments as one tuple. `clear`
  hands back an owned result once `frames_in_flight` frames have passed
  since it was last read. The loader can `abandon` a run, which the
  producer reads from `run.abandoned()`.
- **`KeyedLoads`** moves keys through *wanted* (`get` asked; `.idle`) →
  *loading* (the loader took it from `toStart`; `.running`) → *ready*
  (`.ready`/`.failed`) → *releasing* (unread too long; handed back by
  `toRelease`). `get` never starts work. Completions go through a ring
  sized by claims, so it can never overflow however rarely it is drained.
  A slot is reused only after its load's completion is swapped, so an
  abandoned load never completes the next one; safe builds keep a
  generation per load to catch one finished twice. An abandoned load
  still finishes, into `toRelease`. A value is never
  released before `max(unread_frames_before_release, frames_in_flight)`
  unread frames, computed rather than configured, so a texture is never
  freed under a frame in flight. `toRelease` exists only with
  `owns_resources`, and a forgotten release shows as a full source, not a
  leak. A key `get` cannot track for lack of space stays `.idle`, and
  the next frame reports the refusal. `Progress` must fit in a `usize`,
  checked at comptime, so a producer reports it with one atomic store on
  every target.
- **Costs:** a swap with nothing published is one atomic load; a publish
  is one copy and one atomic exchange; producer-side and reader-side
  atomics sit on separate cache lines; memory is fixed at comptime in the
  application's own struct.

```zig
// Keyed by a hash of the image's path; with owns_resources, textures come back through toRelease to be freed.
const ThumbnailLoads = zui_async.KeyedLoads(u64, DecodeError!Texture, .{ .capacity = 128, .owns_resources = true });
const CatalogTask = zui_async.Task(FetchError!*const Catalog, .{ .Progress = f32 });

const AppSources = struct {
    catalog: CatalogTask = .{},
    quotes: zui_async.Stream(Quote, .{ .capacity = 64, .producers = .many }) = .{},   // capacity: items published but not yet released
    thumbnails: ThumbnailLoads = .{},
};

fn declare(app: *App, ui: *Ui) void {
    switch (ui.source(.catalog).status()) {
        .idle, .canceled => widgets.label(ui, "Catalog not loaded"),
        .running => |fraction| widgets.progressBar(ui, .of("catalog_progress"), fraction),
        .ready => |catalog| catalogGrid(ui, catalog),
        .failed => |err| errorBanner(ui, err),
    }
    var quotes = ui.source(.quotes).items();
    while (quotes.next()) |quote| tickerRow(ui, quote.*);
}

fn catalogGrid(ui: *Ui, catalog: *const Catalog) void {
    const thumbnails = ui.source(.thumbnails);
    for (catalog.visibleItems(ui), 0..) |item, index| {
        widgets.asyncImage(ui, .indexed("thumbnail", index), thumbnails.get(item.path_hash));
    }
}

pub fn zuiLoader(app: *App, ui: *const Ui, io: std.Io) void {
    if (ui.framesSinceRead(.catalog) == 0 and app.sources.catalog.isIdle()) {
        if (app.sources.catalog.begin(app.waker)) |run| {
            app.work.async(io, CatalogTask.publishing(fetchCatalog), .{ run, .{ io, app.catalog_url } });
        } else |_| {}
    }
    var to_start = app.sources.thumbnails.toStart(app.waker);
    while (to_start.next()) |load| app.work.async(io, loadThumbnail, .{ load, io });
    var to_release = app.sources.thumbnails.toRelease();
    while (to_release.next()) |released| if (released) |texture| app.renderer.unload(texture) else |_| {};
}
```

Scrolling the grid stops asking for keys that scrolled away; after the
release window their textures come back through `toRelease` and running
loads are asked to abandon. Scrolling back within the window finds them
ready.

### 19.2 `zui_widgets`

`Widgets(Ui, Skin)` declares controls into a `*Ui`, styled by any type
that implements the skin contract (`zuiStyle(widget, state) Style`), so
theme packs and applications bring their own look without forking the
widgets. The default skin follows the environment's theme and contrast.

| Widget | Edits | Returns |
|---|---|---|
| `button` | nothing | clicked |
| `checkbox`, `toggle` | `*bool` | toggled |
| `slider` | any integer or float | changed |
| `textField`, `textArea` | `*EditableText` | `.{ changed, submitted }` |
| `dropdown`, `dropdownEnum` | `*usize`, any enum | changed |
| `disclosure` | `*bool` | toggled |
| `progressBar`, `asyncImage`, `label`, `labeledRow` | nothing | nothing |

Every control is focusable, draws the skin's focus ring, reports
semantics when the feature is on, and is operable by keyboard and by
accessibility actions. The slider places its thumb with grow weights, so
it is right on the first frame. Text editing covers selection, word
movement, the clipboard through the host, multiple lines and IME
composition, with the IME area reported in `HostRequests`.

### 19.3 `zui_reflect`

`inspector(widgets, ui, id, &value)` declares an editor per field of a
struct, with options from a **typed** declaration:

```zig
pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
    .max_fps = .{ .label = "Frame cap", .min = 30, .max = 240, .step = 10 },
    .frames_rendered = .{ .hidden = true },
} };
```

`Options(T)` has one field per field of `T`, built with `@Struct`, so a
misspelled field name is a compile error, as are numeric options on a
non-number, `min` above `max`, and a visible field of a type it cannot
edit (the message quotes the `.hidden = true` line that fixes it).

### 19.4 `zui_testing`

- **`FixedMetricsText`**: deterministic metrics (each byte `size / 2`
  wide plus its letter spacing), so tests never depend on fonts.
- **`Driver(Ui)`**: runs complete frames from events, by element id, with
  points as fractions of the element's previous rectangle: `click`,
  `tap`, `drag`, `pinch`, multi-pointer drags, `typeText`, `pressKeys`,
  `action`, and `frameDelivering(.{ .catalog = .{ .ready = &catalog } })`
  to set any source's state without threads. A context with sources
  takes them as `.sources = &app.sources`; in `frameDelivering`, a source
  not named receives nothing, which is `null` for an optional `Delivery`
  and `Delivery.empty` otherwise.
- **`replay(records)`**: drives an application from relayed records.
- **`snapshot` / `expectSnapshot`**: one line per command, for named ids
  only, defaults omitted, identical in debug and release.
- **`checkCommands`**: finite bounds, nondecreasing layers, balanced
  clips and transforms.
- **Conformance suites**, which every implementation runs in its own CI:
  `expectRendererConforms(Renderer)` draws recorded frames and checks clip
  balance, that every declared command is handled, and pixels within a
  tolerance; `expectHostConforms(Host)` checks event order, wake from
  another thread, sticky wake, and that waits honor `NextFrame`;
  `expectSourceConforms(Source, harness, .{ .io })` stresses publish,
  swap, inject and refusal under many producers, on any `Io`, with a
  harness that publishes, since publishing is not part of the contract.

### 19.5 `zui_app`

The composition root as a library: `contextConfig(Renderer, overrides)`,
and `run(App, init, options)`, which owns the loop of §6.1, calls the
application's `zuiDeclare` and optional `zuiLoader`, moves submission to
a render thread when the renderer allows, applies host requests, paces
to `nextFrame`, and reports capabilities and fallbacks. An application
that wants its own loop writes the six lines of §6.1 instead.

### 19.6 `zui_wire`

A versioned, little-endian encoding of both sides of the frame boundary:
records in, frames out, as deltas from the previous frame. Payloads
(`ImageHandle`, `CustomData`, deliveries) serialize automatically when
they are plain data, and otherwise must declare `zuiSerialize` and
`zuiDeserialize`, checked at comptime:
``"zui_wire: delivery of source `catalog` holds a pointer (*const Catalog); declare zuiSerialize on it to send it"``.
A stream carries the text contract's fingerprint, and a renderer whose
fonts differ rejects it rather than drawing overflowing text. A wire
renderer and a wire host make a remote client nothing more than a host
plus a renderer.

### 19.7 `zui_debug`

An inspector over `Frame.inspect`: the element tree, the hovered element
and its configs, the frame's diagnostics, lowerings and fallbacks in
effect, and a performance overlay from the tracer. Over the wire it runs
in another process.

### 19.8 `zui_color`, `zui_icons`

OKLab, OKLCH and HSL conversion, mixing and palettes, all usable at
comptime; icon names to codepoints in an icon font, drawn as text.

### 19.9 `zui_motion`

Tweens over `state(id, T)` and `dt()`, which request frames by deadline
while they move and finish instantly under `reduced_motion`. Exit
animations use the core's ghost buffer: an element with `exit_seconds`
keeps emitting its last commands, taking no space and receiving no hits,
from `limits.exit_ghost_commands` (0 compiles it out).

### 19.10 `zui_tracy`

`zui_tracy.Tracer` traces into the Tracy profiler, and
`zui_tracy.frameMark()` ends a frame in its frame graph. Tracy is a lazy
dependency, fetched and linked only by a build with `-Dzui-tracy=true`.
Without it, `Tracer` is `void`, so an application keeps
`.features = .{ .Tracer = zui_tracy.Tracer }` in its `Config` and pays
nothing until it builds with Tracy.

---

## 20. Verification and budgets

### 20.1 Tests

- **Invariants**, on every test frame: children within their parent's
  clip unless floating; grow siblings proportional to weight except where
  clamped; no negative or NaN size; commands in nondecreasing layer
  order. With `features.safety_sweeps`, the checks that read only a
  `Frame` run at the end of `endFrame` in any build.
- **Randomized trees** of 1–5,000 elements from a seed, through the
  invariants.
- **Golden layouts** with exact rectangles for every sizing rule, basis,
  aspect ratio, alignment, direction, wrap mode and floating option.
- **Allocation discipline:** every test runs with a failing allocator
  after `init`.
- **Compile-error tests** for every message in this document.
- **Sources under ThreadSanitizer,** with many producers against a reader
  that swaps at random intervals, and on a single-threaded `Io` where
  every producer runs inline.
- **Replay:** a recorded session replays to identical commands without
  starting any work.

### 20.2 Budgets

On one 2020-era desktop core (the reference is an i9-10900K):

| Scenario | Budget |
|---|---|
| 4,096 boxes, depth 8: layout and emission | < 100 µs |
| 4,096 boxes, depth 8: declaration | < 55 µs |
| 1,000 texts of ~40 bytes, warm caches: layout and emission | < 120 µs |
| 133 pointer moves in one frame | one hover hit test per pointer |
| a frame with 10 idle sources | no more instructions than with none |
| an idle application | 0% CPU |
| allocations after `init` | 0 |

### 20.3 Measuring

- **`zig build bench`**, always ReleaseFast: the budget scenarios, deep
  and wide trees, a realistic document view, cold text on one thread and
  in parallel, a render thread against one thread, and startup (`init`,
  `initBuffer`, first frames). It fails on any allocation after `init`.
- **`zig build bench-compare -- <base> [<head>]`** alternates two commits
  on one machine and reports the median ratio with its middle half,
  calling a change only when that whole range is beyond 2%.
- **`zig build counts`**, instruction counts under Callgrind for the
  single-threaded scenarios, from an executable always built for one CPU
  model without libc, over a fixed number of frames, so they are the same
  on every machine. CI fails on more than 2% growth over the parent
  commit. Wall-clock times on shared runners are reported, never
  compared.
- **Every feature that claims a speedup ships with its measurement,** and
  a feature whose win is not measured does not ship.

---

## 21. Build order

The order follows the dependencies of the design, not a calendar.

| Stage | Delivers | Done when |
|---|---|---|
| 1. Measure | instruction counts in CI; the tracer contract | counts repeat exactly between runners; an off tracer leaves them unchanged |
| 2. The frame record *(the breaking change, made once)* | `Context(config)` with the text contract; `FrameRecord` with `now`, scale and zoom; input as events with the pointer table; the environment; `endFrame` that always returns a frame; `NextFrame`; sources in the core, `Status`, `Waker`; `zui_async`; `MeasureKey` with letter spacing; `TaskPool` deleted | the interaction, widget and testing suites pass on events; a click inside one frame is kept; the demo's thumbnail grid runs on `KeyedLoads` with no UI-thread wait and idles at 0% CPU; 100 loads between two frames cause one wake |
| 3. Contracts | renderer, host, surface; the generated command union and lowering; `zui_app`; conformance suites; the raylib adapter | every backend passes its suite and runs the demo through `zui_app` |
| 4. A native host | Windows, with the system material, per-monitor scale, lifecycle, clipboard and drop | the demo runs unchanged, passes the host suite, and idles at 0% CPU |
| 5. The wire | relay, replay, `zui_wire`, wire host and renderer, file watching as a source | a session replays to identical commands; the demo draws in another process |
| 6. Text and layout | string cache and fast path, segmentation, grow basis, aspect ratio, natural sizes, floating options, right-to-left, wrap, static styles | goldens for each; warm text within its budget; no other budget regresses |
| 7. Gestures | intents, gesture arbitration, momentum, custom recognizers, drag and drop | the nested-gesture scenes: a carousel in a list, a pinch starting on a list inside a map, a lasso module against a map's pan |
| 8. Effects | optional commands, lowering, transforms with hit inversion, materials, `ExtendedColor` | lowering tested for each; one renderer draws each; HDR white brighter than SDR on the Windows host |
| 9. Seeing the UI | `zui_debug`, semantics with accessibility actions, safety sweeps, the demo in a browser | the Windows host bridges semantics to UI Automation |
| 10. Reach | macOS, Linux and web hosts; services; window decorations; many windows | each host passes its suite and runs the demo unchanged |
| 11. Polish | `zui_motion` and exit ghosts; full text editing with IME; `zui_color`, `zui_icons`, skins and theme packs; samples and the template | each with `zui_testing` coverage; IME on Windows |
| Later | docking, a grid layout, layout islands, static subtrees, SIMD | only with a measured win or a demonstrated need |

Two rules hold throughout:
- **One breaking release.** Everything that changes the shape of the
  record, the context's parameters or the contracts lands in stage 2 and
  3, before any host or wire format freezes it.
- **A module before core.** A feature that can be built on the public API
  is; the core gains only what a module proves it cannot do without.

---

## 22. Open questions

1. **A custom recognizer's claim lands a frame late.** Planned: accept it,
   until a recognizer shows that it matters.
2. **Physical keys.** Planned: logical keys plus the opaque scancode; a
   physical key enum only when a binding needs portable physical keys.

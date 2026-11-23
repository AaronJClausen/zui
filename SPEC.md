# zui: specification

zui is an immediate-mode UI engine for Zig 0.16. Each frame, the
application declares its UI as nested function calls. zui lays it out,
resolves interaction, and returns a frame of plain data: render
commands, hit regions, semantics and requests to the host. Drawing,
windowing, fonts, threads and the application's own work all belong to
someone else, and zui reaches each of them only through a contract
checked at compile time.

The whole system fits in one line:

```
Frame = endFrame(declare(beginFrame(state, FrameRecord, Sources)))
```

A **frame record** comes in: time, the viewport, events, and whatever
outside data the application's sources received. A **frame** goes out:
everything a renderer, a host, an accessibility bridge and the
application's loader need. Between the two, declaration reads only what
came in, and nothing changes under it. Every feature in this document is
either part of one of those two values, or part of the state that
carries from one frame to the next.

This document is the contract. Where it states a number, it is a
**budget** the implementation is measured against (§20). §21 orders the
work; ROADMAP.md says what exists today and where each stage stands, and
ARCHITECTURE.md maps where each feature lives across the layers and
packages.

---

## 1. Principles

1. **Layout and interaction, not rendering.** zui produces data that
   describes what to draw and what was hit. It works with any renderer,
   host or toolkit, including ones that do not exist yet.
2. **One frame boundary.** Everything from outside a frame is applied at
   `beginFrame`, and everything leaving it is produced by `endFrame`.
   Declaration never sees data change under it, so any frame can be
   recorded, relayed, replayed or computed in another process.
3. **Determinism by construction.** A frame is a function of the
   previous frame's persistent state and the frame record. zui reads no
   clock, no environment and no callback during a frame that the record
   did not carry. The application's side of this is documented in §6.8.
4. **Memory fixed at compile time.** All of zui's memory is one
   reservation whose size is a comptime constant. A frame allocates
   nothing, and exceeding a limit is defined, reported behavior, never
   corruption.
5. **Linear time, data-oriented.** Every pass is O(n) in elements and
   text wrapping O(n) in bytes. Elements live in structure-of-arrays in
   declaration order, and no pass recurses.
6. **Plain data in, plain data out.** Configuration is structs with
   defaults. Output is slices of tagged unions. There are no callbacks
   in the hot path, no inheritance and no style cascade.
7. **Comptime proves, precomputes and prunes.** Comptime is used where
   it turns a run-time mistake into a compile error, moves work out of
   the frame, or removes code the application did not ask for. It is not
   used to specialize the layout engine per tree, because that
   multiplies code size for no measured gain.
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
| font loading, shaping, glyph rasterization | large, and every platform already has them | font systems behind the text contract (§9.4), in the `text/` packages: `zui_truetype` today, a shaper or another rasterizer beside it |
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
| **Modules** (`zui_*`, in `core/`) | defaults built on the public API: async sources, widgets, reflection, testing, tracing, the app runner, wire, debug, motion, color, icons, design | the public API only, enforced by the module boundary (§3.3) |
| **Text** | font systems, typefaces, and the layout of a run that font systems and renderers share | implement the text contract; never import a renderer |
| **Renderers** | drawing, images, materials, and text where its layout places it | implement the renderer contract, and may implement the text contract; never import a host |
| **Hosts** | windows, the event loop, OS events and services, frame pacing | implement the host contract; never import a renderer |
| **Theme packs** | design languages as `zui.design.Design`s (§18) | data only; import only `zui` |

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

### 3.2 The repository

zui is one repository, `zui`, of packages:

| Directory | Holds |
|---|---|
| the root | the package `zui`, which re-exports core's modules and those of `zui_glyphs`, `zui_fonts`, `zui_tour` and `zui_showcase` |
| `core/` | the core, the contracts, and the modules, as the package `zui_core` |
| `text/` | text, one package each: `glyphs/` (`zui_glyphs`, what font systems and renderers share), `truetype/` (`zui_truetype`, the default font system) and `fonts/` (`zui_fonts`, the bundled typefaces) |
| `apps/` | the tour (`zui_tour`) and the showcase (`zui_showcase`), which every renderer and host runs |
| `themes/` | skins for OS design languages (`zui_themes`) |
| `examples/` | samples and the template project |
| `renderers/` | renderers, one package each: `raylib/` (`zui_raylib`, which also holds an adapter host), `sokol/` (`zui_sokol`), `terminal/` (`zui_terminal`) and `webgl/` (`zui_webgl`, the browser's drawing) |
| `hosts/` | hosts, one package each: native hosts in `native/` (`zui_host`), one directory per OS, and the web host in `web/` (`zui_web`) |

### 3.3 The module boundary

Each module's root file is named after it
(`core/zui_widgets/zui_widgets.zig`), because Zig names types after
their file and users read those names in compile errors. A module can
import only files in its own directory, so modules reach zui only
through `@import("zui")`: **the compiler keeps them on the public API.**
Anything a module does, application code can do, and any module can be
replaced by the application's own. A module may also import its own
build options (`zui_tracy_options`) and a third-party library it binds,
never another part of zui.

### 3.4 Build options

| Option | Default | Effect |
|---|---|---|
| `-Dzui-debug=bool` | `false` | `Id.of` keeps its name, so panics and diagnostics name elements. Off, those paths are never analyzed. It is a build option, not a `Config` field, because ids are created outside any `Context`. |

Everything else is per-`Context` configuration (§4).

### 3.5 Targets

The core builds for every target Zig does, including 32-bit, big-endian,
`wasm32-freestanding` and freestanding embedded. It uses no OS API,
keeps no global state, never assumes `usize` is 64 bits, and can run
with `frames_in_flight = 1` on an `Io` that has no threads (§15). CI
builds a full frame for each of these classes.

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
    extended_color: bool = false, // the renderer's `zui_extended_color`; without it the commands carry `zui.Color`
    /// Corner shapes the renderer draws; the rest are drawn round (§18.7).
    corner_shapes: CornerShapeSet = .initOne(.round),

    features: Features = .{},
    /// Frames alive at once: one being declared plus those a renderer holds.
    frames_in_flight: u8 = 2,
};

pub const Limits = struct {
    max_elements: u32 = 4096,               // declared per frame
    max_depth: u16 = 64,                    // nesting of `open` inside `open`
    max_text_bytes: u32 = 64 * 1024,        // UTF-8 bytes of all `text` content, and of semantic labels and values, per frame
    max_render_commands: u32 = 8192,        // per frame
    max_effects: u32 = 256,                 // elements with effects per frame; past it, drawn without them
    state_slots: u32 = 1024,                // persistent `(id, type)` entries (§12); a power of two
    state_frames_until_eviction: u8 = 2,    // counted from the last frame its element was declared
    measure_cache_entries: u32 = 4096,      // the segment cache (§9.3); a power of two
    string_cache_entries: u32 = 1024,       // the whole-string cache (§9.3); a power of two
    max_input_contacts: u8 = 10,            // e.g. fingers, pens and mice touching or hovering at once
    max_events_per_frame: u16 = 256,        // input events kept from one record
    max_text_input_bytes: u16 = 256,        // typed and IME-committed text kept from one record
    max_dropped_path_bytes: u32 = 4096,     // paths of dropped files kept from one record; 0 keeps none
    parallel_measure_threshold: u32 = 256,  // cache misses in one frame before measuring in parallel
    parallel_measure_capacity: u32 = 4096,  // distinct misses one cold frame can batch
    exit_ghost_commands: u32 = 0,           // commands kept for exit animations, with up to max_text_bytes of their text; 0 compiles them out
};

pub const Features = struct {
    semantics: bool = false,                          // the accessibility tree (§13.5)
    gestures: bool = true,                            // pan, zoom, drag, long press, double tap (§11.4)
    flex_wrap: bool = false,                          // `wrapChildren()` (§8.1)
    chrome_regions: bool = false,                     // `Frame.chromeRegions()`, a custom title bar (§13.4)
    safety_sweeps: bool = std.debug.runtime_safety,   // invariant checks at the end of `endFrame` (§20.1)
    nested_corners: bool = false,                     // `Decoration.nested_corners` (§18.7)
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
| API surface | payload types, `Text`, features | `image`, `custom`, `text`, `semantics`, `chromeRegions`, `wrapChildren` and the gesture queries exist only when their type or feature is set; calling one that does not is a compile error naming the field to set |
| contract checks | `Text`, `Sources`, `Tracer` | run once, at instantiation, with exact messages (§16.1) |

### 4.2 Validation

Every check is a `@compileError` with an exact message, pinned by a
compile-error test:

- `"zui: limits.state_slots must be a power of two, got 1000"` (also
  `measure_cache_entries`, `string_cache_entries`);
- `"zui: frames_in_flight must be at least 1"`;
- `"zui: Color must be zui.Color or zui.ExtendedColor, got [4]u8"`;
- `"zui: commands includes .material but MaterialHandle is void"`;
- `"zui: corner_shapes does not include .round, which every other shape is drawn as"`;
- `"zui: Decoration.nested_corners needs Config.features.nested_corners = true"`,
  inside Zig's error for the struct initialization (§18.7);
- each API whose feature is off, naming the field to set:
  `"zui: semantics() needs Config.features.semantics = true"`,
  `"zui: manipulation() needs Config.features.gestures = true"`,
  `"zui: doubleTapped() needs Config.features.gestures = true"`,
  `"zui: pointerEvents() needs Config.features.gestures = true"`,
  `"zui: dropped() needs Config.features.gestures = true"`,
  `"zui: wrapChildren() needs Config.features.flex_wrap = true"`,
  `"zui: chromeRegions() needs Config.features.chrome_regions = true"`;
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
| `child_counts` | two `ElementIndex`: all children and those in the flow, side by side so declaration zeroes and counts them in one store | sizing, ids |
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

Written by hand, it is the same steps, in this order:

```zig
while (host.zuiPoll(window, &builder)) {   // builder: a zui.RecordBuilder (§16.3)
    ui.beginFrame(&builder.recordWith(Ui.Deliveries), &app.sources);
    app.declare(&ui);
    const frame = ui.endFrame();
    try renderer.zuiSubmit(host.zuiSurface(window), frame);
    host.zuiApply(window, frame.requests());
    ui.release(frame);              // or from the render thread
    app.load(&ui, io);              // the loader: demand → work
    host.zuiWait(ui.nextFrame(&app.sources));
}
```

The loader runs after `endFrame`, so it sees the demand of the frame
just declared, and before the wait, so work it starts can wake the next
one. With many windows, each window is a context of its own, and the
loop polls each and waits once for all (§19.5).

**Who turns the loop.** The steps from the poll to the loader are one
turn, which never blocks; only the wait does. A host says who waits by
its loop half (§16.3): zui waits on a host that declares `zuiWait`, the
platform runs the loop of a host that declares `zuiRun` and calls zui
from its callbacks, and the application's own loop turns a host that
declares neither. `zui_app` gives each the same turn,
`zui_app.Session(App).step()`, which returns when it next wants to run:

```zig
while (try session.step()) |next| session.wait(next);            // zui owns the loop: what run does
const next = try driver.step() orelse return driver.stop();      // the platform owns it: in rAF, CADisplayLink, SDL_AppIterate
schedule(next);
if (try session.step()) |next| editor.redrawAt(next);            // the application owns it: in its own frame
```

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

1. **Take a frame arena.** `beginFrame` waits for one if a renderer
   holds all of them (§15.2), which is zui's only wait. `tryBeginFrame`
   returns `error.NoFreeFrame` instead, for hosts that cannot block, and
   `hasFreeFrame()` says beforehand whether one would, so a loop that
   cannot block leaves input it could not declare with its host. Only
   the thread that begins frames takes one, so the answer holds until it
   begins one.
2. **Advance the state table's generation** and evict slots past their
   TTL (§12).
3. **Apply events in arrival order** (§7): environment changes, then
   pointer, key, text and action events against the previous frame's hit
   regions.
4. **Swap each source,** in `Sources` field order, in an `inline for`;
   or, when `record.deliveries` is set, inject each recorded delivery
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
sweeps the frame with `features.safety_sweeps` (§20.1), settles source
demand (§14.5), and returns the frame. **It always returns a usable
frame.** If a limit was exceeded, the part that fit was laid out, and
`frame.diagnostics` says what to raise; an application that wants an
error writes `try frame.diagnostics.check()`.

```zig
pub const Frame = struct {
    pub fn commands(self: *const Frame) []const RenderCommand
    pub fn hitRegions(self: *const Frame) []const HitRegion
    pub fn semantics(self: *const Frame) []const SemanticNode     // features.semantics
    pub fn chromeRegions(self: *const Frame) []const ChromeRegion // features.chrome_regions: title bar, caption buttons, resize edges
    pub fn requests(self: *const Frame) HostRequests              // cursor, IME area, text input
    pub fn inspect(self: *const Frame, index: ElementIndex) ElementView   // by declaration order, for inspectors
    pub fn elementCount(self: *const Frame) ElementIndex
    pub fn sweep(self: *const Frame) ?SweepFailure               // the first invariant broken (§20.1)
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
swapped (§14.4) or a frame was requested; otherwise `.at` the earliest
of every `requestFrameAt`, running momentum, and pending long-press and
double-tap timers; otherwise `.on_event`. The host sleeps accordingly,
so an idle UI uses no CPU and a blinking caret costs one frame per
blink.

`nextFrame` takes the sources, as `beginFrame` does, because zui holds
no pointer into them between frames (§14.1), and it is called after the
loader, whose publishes must count.

### 6.7 One frame of latency

Interaction queries answer for the **previous** frame's layout, because
a click is resolved against what was on screen when the user clicked.
Declaration therefore never waits for layout, and styles can depend on
interaction before the element is declared.

### 6.8 Relay, replay and determinism

```zig
pub fn relayTo(self: *Self, listener: ?Ui.Relay) void   // Ui.Relay is zui.Relay(Ui.FrameRecord); null detaches

pub fn Relay(comptime Record: type) type {   // as `Waker`: the listener's pointer, passed back
    return struct { context: *anyopaque, relayFn: *const fn (*anyopaque, *const Record) void };
}
```

- **Relay.** A listener receives each applied record during
  `beginFrame`, after the sources swap: its parameters, the events zui
  kept (at most `max_events_per_frame`), and the deliveries each source
  reported through `zuiDelivery`, or, in a replay, the record's own. The
  record is valid only during the call; a listener copies what it keeps,
  and a slow listener buffers on its own side. With no listener, nothing
  is copied; the deliveries are filled in the context's reservation, so
  relaying allocates nothing either way.
- **Replay.** Feeding recorded records back, with `deliveries` set,
  drives declaration to the same commands. No loader runs during replay,
  and declaration starts no work (§14.1), so replay does no real I/O.
- **The application's side.** Replay is exact if declaration reads the
  outside world only through the record and its sources: no clock,
  random number or file read that bypasses them, and no state its own
  work keeps outside its sources, such as a count of loads finished. A
  source delivers whatever its view shows that the loader changed
  between frames, as `KeyedLoads` delivers the keys loading. This is
  documented, not enforced. Text measurement is the one outside call
  during a frame; it is deterministic for a given set of fonts, which
  the wire format fingerprints (§19.6).
- **Windows.** Opening and closing windows is in no record: each
  window's context relays and replays its own records, and a replay
  opens no window.

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
    action: ActionEvent,            // invoke, focus, adjust, scroll, show_menu or dismiss, naming an element id
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

```zig
pub const FilesDropped = struct {
    position: [2]f32,               // layout units, from the surface's top-left
    path_list: []const u8,          // each path in UTF-8 followed by a 0 byte
    at: Instant,
    pub fn paths(self: FilesDropped) std.mem.TokenIterator(u8, .scalar)
};
pub const Lifecycle = enum { @"suspend", @"resume", terminate_requested, low_memory };

pub fn filesDropped(self: *const Self) []const FilesDropped   // this frame's, in order
pub fn lifecycle(self: *const Self) std.EnumSet(Lifecycle)    // what the OS reported this frame
```

The rules:

- **Events apply in order.** A press and release in one frame is a
  click; "release, then a new touch" is handled in that order.
- **Moves coalesce per pointer.** Only the last move before another
  event of the same pointer is hit-tested; earlier ones are history, for
  velocity. A mouse reporting at 8 kHz costs one hover hit test per
  pointer per frame.
- **Velocity uses the events' instants,** never a clock read in the
  frame.
- **Touch never hovers.** Mouse and pen hover while over the surface.
- **The pointer table** has `max_input_contacts` slots. A contact beyond
  it is ignored until a slot frees, as digitizers do.
- **Sampled input** (a library that reports only current state) goes
  through `zui.InputSampler`, which turns successive states into events.
- **Dropped files** are copied, whole paths only, into
  `max_dropped_path_bytes`; a path that does not fit is dropped and
  reported (§17.2). zui does not hit-test a drop: the application
  compares its position with `rectOf`.
- **A terminate request ends the window.** The host delivers
  `.terminate_requested` in one record, so the application can save, and
  its next `zuiPoll` returns false: the OS default, with one frame to
  react.

### 7.2 Environment

```zig
pub const Environment = struct {
    theme: Theme = .light,                          // enum { light, dark }
    contrast: Contrast = .normal,                   // enum { normal, high }
    reduced_motion: bool = false,
    reduced_transparency: bool = false,
    text_scale: f32 = 1,            // the user's text size preference, e.g. 1.25; applied by skins, not by layout
    locale: Locale = .default,      // a BCP 47 tag of up to 23 bytes, e.g. "fr-CA"; zui only reports it
    direction: ReadingDirection = .left_to_right,   // the language's, which the root's `mirrored = .inherit` follows
    hdr_headroom: f32 = 1,          // display peak over SDR white, e.g. 4; 1 is an SDR display
    power: Power = .plugged,                        // enum { plugged, battery, saver }
    window_focused: bool = true,    // the OS window has keyboard focus, not an element
    system_material: bool = false,  // the window shows the system's material where nothing is drawn
    custom_title_bar: bool = false, // the application draws the title bar (§13.4)
    window_maximized: bool = false, // the window fills its monitor's work area
    accent: ?Color = null,          // the user's accent color in the OS, where it has one
};

/// One field's new value: `.{ .environment = .{ .theme = .dark } }`.
pub const EnvironmentChange = union(enum) { theme: Environment.Theme, contrast: Environment.Contrast, ... };

pub fn environment(self: *const Self) *const Environment
```

The environment is state the core keeps; `EnvironmentChange` events
update it, one field each, so a record carries only what changed, and
the change applies before the declaration of the frame that carries it.
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
  are hit-tested, so a cursor elsewhere has no effect. Touch never
  hovers and never sets one.
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
    padding: Edges = .{},                    // logical: `left` is the start side, on the right when mirrored
    child_gap: f32 = 0,                      // between adjacent children, not around them
    child_alignment: Alignment2 = .{},       // where the children as a group sit, on each axis
    mirrored: Mirrored = .inherit,           // .yes, .no; .inherit: the parent's, and the root the environment's
};

pub const Mirrored = enum(u8) { inherit, yes, no };   // one byte: a `?bool` is two, and `Layout` would grow

pub const Sizing = struct {
    rule: enum(u32) { fit, grow, grow_from_min, aspect_ratio, fixed, percent } = .fit,   // four bytes: no padding to copy
    /// fixed: the size. percent: fraction of the parent's content box. grow, grow_from_min: the weight.
    /// aspect_ratio: width / height.
    amount: f32 = 0,
    min: f32 = 0,                                   // layout units, for every rule
    max: f32 = std.math.inf(f32),

    pub const fit: Sizing = .{};
    pub const grow: Sizing = .{ .rule = .grow, .amount = 1 };                   // a content basis
    pub const grow_equal: Sizing = .{ .rule = .grow_from_min, .amount = 1 };    // a zero basis
    pub fn fixed(size: f32) Sizing
    pub fn percent(fraction: f32) Sizing
    pub fn growWeighted(weight: f32) Sizing   // 2: twice the free space of a `.grow` sibling
    pub fn fitBetween(min: f32, max: f32) Sizing
    pub fn aspectRatio(width_over_height: f32) Sizing   // a height: .height = .aspectRatio(16.0 / 9.0)
};
```

`Sizing` is a struct with declarations rather than a union so that decl
literals stay short:
`.sizing = .{ .width = .grow, .height = .fixed(48) }`.

The meanings, which follow CSS where CSS has an answer:

- **`fit`** is the size of the content, clamped to `min` and `max`.
- **`grow`** has a content basis: it starts from its content and shares
  free space by weight, as `flex: auto`. **`grow_from_min`** has a zero
  basis: it starts from `min` and shares the content box by weight, as
  `flex: 1`, which gives equal columns while keeping weights; it is
  never narrower than its content's minimum, and the others share what
  that leaves. The basis is a rule rather than a field of its own
  because `Sizing` has no room for one without padding: two two-byte
  fields made the box tree's declaration 3.8% more instructions.
- **`percent`** is a fraction of the parent's content box, not counting
  gaps. It contributes nothing to a `fit` parent, whose size would
  otherwise depend on it in a cycle.
- **Shrinking.** When children overflow, the largest shrinkable child
  shrinks first until it matches the next largest, never below its
  minimum. Percent children shrink like the others.
- **`aspect_ratio`** is a height derived from the settled width, under
  whichever rule set the width, clamped to `min` and `max`. Deriving
  width from height would need a second width pass and is not supported,
  so on a width, or with a ratio that is not positive, it takes the
  content's size. Children do not stretch it; they overflow it, and a
  parent neither stretches nor grows it. It is a rule rather than a
  field of `Layout` for the reason the basis is: a field made every
  `Layout` eight bytes larger, and the box tree's declaration 6.6%
  slower.
- **Direction** is logical. A mirrored element (`mirrored`, inherited
  from the parent, and at the root from the environment's `direction`)
  places its children from the right: a row flows from its right edge,
  `.start` alignment on either axis is the right, its padding's `left`
  is its start side and lies on the right, its floating children's
  anchors, attach points and offsets are reflected across the box they
  attach to, a text's `.start` and `.end` lines swap, and a horizontal
  scroll offset grows to the left, so the wheel moves it the way the
  pointer does. `right_to_left` does the same for an element's own
  children alone, as CSS `row-reverse` does, so in a mirrored element it
  flows from the left. Positions in a frame are physical, and borders
  stay physical. A frame in which no element mirrors, in a left-to-right
  environment, does no mirroring work. `mirrored` is a one-byte enum
  rather than a `?bool`, which is two bytes and would make every
  `Layout` four bytes larger, as the aspect ratio's field did.
  Bidirectional text inside a run is the text contract's (§9.4).
- **Wrap** moves each child that would overflow a row onto a new line,
  for a row that opts in with `ui.wrapChildren()` after its `open`
  (§10.1), with `features.flex_wrap` on; without it the call is a
  compile error,
  `"zui: wrapChildren() needs Config.features.flex_wrap = true"`, and
  none of the work below is compiled. A child goes on the current line
  if it fits at the size its rule asks for before free space is handed
  out (a `grow_from_min` child at its minimum, a `percent` one
  resolved), and each line then grows and shrinks its children as a row
  would, so a child wider than the row takes a line of its own and
  shrinks to it. A wrapping row is as wide as its children on one line
  but no narrower than its widest child's minimum, and as tall as its
  lines, each as tall as its tallest child and `child_gap` apart. A
  growing height stretches to its line. `child_alignment.y` places the
  lines as a group and each child within its line, and `.x` each line
  along the row; mirroring reflects them as it does a row. A column does
  not wrap, since its heights would have to settle before its widths.
  Dividers sit between the children of a line, as tall as the line, and
  between lines, across the row. Wrap is a call rather than a `Layout`
  field because a field's value is not known at compile time, so it
  could not fail as a gated API does, and because `Layout` has no byte
  free: a field would make it 60 bytes, the size that made the box
  tree's `endFrame` 6.7% slower. The row keeps it in an element flag.

### 8.2 Passes

| # | Pass | Order | Work |
|---|---|---|---|
| 0 | measure text | each text | look up whole strings, then segments, through the caches (§9.3) |
| 1 | fit widths | reverse | each `fit` width from its children, plus padding and gaps; each element adds itself into its parent, so no child list is walked; a wrapping row walks its children instead |
| 2 | distribute widths | forward | fixed and percent first, then free space by weight, then shrinking; a wrapping row breaks its children into lines first, then distributes each line |
| 3 | wrap text | each text | lines from the widths pass 0 recorded, looking up a long cached string's segments only if it wraps |
| 4 | fit heights | reverse | as 1; `aspect_ratio` heights, and images' natural heights, from the settled widths; a wrapping row sums its lines |
| 5 | distribute heights | forward | as 2; a wrapping row stretches each line's growing children to the line |
| 6 | position | forward | a cursor per parent from its content box, alignment, direction and scroll offset, reflected across the parent when it is mirrored; a wrapping row line by line; floating elements from their targets (§8.4) |
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
- **Scrolled children are not shrunk** along the scrolled axis; they
  keep their size, which is what makes them scrollable.
- **The offset is clamped** to `[0, content − size]` at layout time and
  written back. `ui.scrollOffset(id)` and
  `ui.setScrollOffset(id, offset)` read and set it.
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
- **An element target may be declared later.** A floating subtree whose
  target comes later is placed against its parent in pass 6, then placed
  again, with its subtree (`index..subtree_end`, contiguous), once pass
  6 has placed the target. These subtrees are placed in declaration
  order, so one nested in another follows it; a target inside a floating
  subtree that is itself placed later is taken where pass 6 left it. A
  target inside the floating element's own subtree, or an id no element
  has, falls back to the parent, since the subtree's position would
  depend on itself.
- **They paint in layer `z`,** sorted stably, so declaration order holds
  within a layer, and they escape their ancestors' clips unless
  `.clip = .target`, which cuts them off where their target's children
  are: for `.parent`, as a child in the flow; for an element, by that
  element's own clip within its ancestors'; for `.root`, by the
  viewport. That clip, merged with the floating element's own, is pushed
  in its layer before it draws, since sorting moves the layer away from
  its ancestors' clips.
- **They win the hit test** over lower layers when `capture` is true,
  and their tree ancestors still count as hovered, so a menu stays
  hovered while the pointer is over its dropdown. With `capture = false`
  the element has no hit region of its own, so a tooltip lets the
  pointer through to what it covers; interactive elements inside it
  still take it.

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

- **The fast path.** A text with no paragraph break whose unwrapped
  width fits its box is emitted as one line without walking its
  segments.
- **Segments are never broken.** A text's minimum width is its widest
  segment, and no pass makes an element narrower than its minimum, so an
  over-wide segment gets a line of its own and overflows, as in CSS.
- **One command per line,** so renderers never wrap.
- **Spaces before a break hang.** A line that breaks after a segment
  leaves the spaces that end it past its right edge, so they neither
  count toward its width nor push it onto another line; the last line of
  a paragraph keeps them.

### 9.3 Caches

| Cache | Key | Holds | Why both |
|---|---|---|---|
| strings | `(hash(bytes), MeasureKey, zoom, wrap)` | the whole text's metrics (unwrapped width, widest segment, has break), the widths of up to 16 segments, and the lines of its last wrap if there were at most 4, with the width it was wrapped at | a warm text costs one probe, not one per word, even when it wraps, and is not wrapped again at the same width |
| segments | `(hash(bytes), MeasureKey)` | one segment's size | text that changes every frame (`"Frame 1234"`) measures only its new segments |

Both are open-addressed, sized by `Limits`, persistent across frames,
and evict the least recently used entry in the probe window. Hashing is
one wyhash of the bytes, seeded with the key; a string's key also holds
the zoom and the wrap mode, because its metrics are in layout units and
its segments depend on how it wraps. A string of more than 16 segments
is cached by its metrics alone, and its segments are looked up only if
it wraps. A string's lines are kept from the second frame that finds it,
and reused only at exactly the same width. Steady-state frames make
almost no calls to the text contract.

### 9.4 The text contract

```zig
const Fonts = struct {
    /// Required. Size of `run` in layout units.
    pub fn zuiMeasure(self: *Fonts, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 { ... }

    /// Optional. Break opportunities in one paragraph; without it, after ASCII spaces.
    pub fn zuiSegment(self: *Fonts, paragraph: []const u8, breaks: *zui.BreakSink) void { ... }
    /// Optional. `zuiMeasure` may be called from several threads at once (§15.3).
    pub const zui_thread_safe = true;
    /// Optional. Identifies the fonts, so a frame measured elsewhere can be checked (§19.6).
    pub fn zuiFingerprint(self: *const Fonts) u64 { ... }
};
```

```zig
pub const BreakSink = struct {
    /// A line may break before byte `offset` of the paragraph. Offsets come
    /// in increasing order; any other, or one not inside the paragraph, is ignored.
    pub fn add(self: *BreakSink, offset: usize) void
};
```

zui splits a text at newlines itself, so `zuiSegment` sees one paragraph
at a time and never a newline. It is called on the thread that runs
layout, for each paragraph of a text that wraps at words, when the text
is measured and again when it does not fit on one line. Its breaks are
held in a scratch buffer of `limits.max_text_bytes` offsets, reserved
only for a contract that declares it, which no paragraph can overflow.

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
pub fn wrapChildren(self: *Self) void                    // the open row wraps (§8.1); features.flex_wrap

pub const Image = struct {
    handle: config.ImageHandle,
    natural_size: ?[2]f32 = null,       // layout units: a `fit` image takes this size
    tint: config.Color = .white,        // multiplied into the pixels; white leaves them unchanged
    corner_radius: CornerRadius = .{},
    corner_shape: CornerShape = .round, // as a decoration's (§18.7)
};
```

An image's natural size is its content, inside its padding. Its width
may shrink below the natural width, as any leaf does when its parent is
narrower; its height then keeps the natural proportions, unless the
height's rule is `aspect_ratio`, `fixed` or `percent`, which take
precedence.

```zig
pub const Element = struct {
    id: Id = .none,                     // needed for queries, state, scrolling and focus
    style: ?Static(Style) = null,       // comptime-built, zero-copy (§10.3)
    layout: ?Layout = null,             // overrides style.layout
    decoration: ?Decoration = null,     // background, border, corner radius, material
    effects: ?*const Effects = null,    // gradient, shadow, backdrop blur and transform, copied when declared
    clip: Axes = .none,                 // the axes on which descendants are cut off, e.g. .vertical
    scroll: ?Scroll = null,
    floating: ?Floating = null,
    interactive: ?bool = null,          // takes hover, press and click, and blocks them below it
    focusable: ?bool = null,            // implies interactive
    focus_scope: ?bool = null,          // Tab cycles inside this subtree, as in a dialog
    disabled: ?bool = null,             // no hover, press or focus; queries report `.disabled`
    gestures: Gestures = .{},           // features.gestures, ignored without it; makes it interactive (§11.4)
    cursor: ?Cursor = null,             // the pointer's shape while this element is hot
    chrome: ?ChromeKind = null,         // features.chrome_regions: a title bar, caption button or resize edge (§13.4)
    semantics: ?Semantics = null,       // features.semantics (§13.5)
    exit: ?Exit = null,                 // limits.exit_ghost_commands, ignored without it; needs an id (§19.9)
};

pub const Exit = struct {
    seconds: f32,
    fade: ExitFade = .linear,
};

pub const ExitFade = enum(u8) { none, linear, ease_in, ease_out, ease_in_out }; // `none` holds, then vanishes
```

```zig
pub const Decoration = struct {
    background: ?config.Color = null,  // also the material's fallback
    border: ?Border = null,
    corner_radius: CornerRadius = .{},
    corner_shape: CornerShape = .round,      // enum { round, continuous, chamfer } (§18.7)
    nested_corners: ?NestedCorners = null,   // concentric with the parent's corners; needs `features.nested_corners` (§18.7)
    material: ?config.MaterialHandle = null, // drawn in place of the background; `void` without a handle
};

pub const Border = struct {
    color: config.Color,
    widths: Edges = .{},
    between_children: f32 = 0,   // a divider of this width between each two adjacent children in the flow
};
```

`Element`, `Decoration` and `Style` are each context's own,
`Ui.Element`, `Ui.Decoration` and `Ui.Style`, and are the same types as
`zui.Element`, `zui.Decoration` and `zui.Style` unless the config's
`MaterialHandle` or `Color` is set or `features.nested_corners` is on.
Without a handle `material` is `void`, and without the feature
`nested_corners` is zero-sized, so every context without them shares one
set of types and stores nothing more. So are the types that hold a
color, `Ui.Border`, `Ui.Effects`, `Ui.Gradient`, `Ui.Shadow`,
`Ui.BackdropBlur` and `Ui.TextStyle`, each `zui`'s own unless `Color` is
`ExtendedColor`. A helper that builds an element for a context with
materials names `Ui.Element`, since a literal passed through `anytype`
is not converted to it.

```zig
pub const Effects = struct {
    gradient: ?Gradient = null,   // painted over the background
    shadow: ?Shadow = null,       // painted under it; with no offset, a glow
    backdrop_blur: ?BackdropBlur = null, // over the shadow, under the background
    transform: ?Transform = null, // moves the element, its effects and its subtree as painted
};

pub const Gradient = struct {
    from: config.Color,
    to: config.Color,
    angle: f32 = 0,               // radians clockwise from left to right
};

pub const Shadow = struct {
    color: config.Color,
    offset: [2]f32 = .{ 0, 0 },   // right and down
    blur: f32 = 0,                // how far the edge fades, outward
    spread: f32 = 0,              // how far the shape grows before it is blurred
};

pub const BackdropBlur = struct {
    radius: f32,                  // the blur's standard deviation, as CSS's blur() takes it
    tint: config.Color,           // drawn over the blurred backdrop, and alone where it is lowered
};

pub const Transform = struct {
    translation: [2]f32 = .{ 0, 0 }, // layout units, right and down
    scale: [2]f32 = .{ 1, 1 },
    rotation: f32 = 0,                // radians clockwise
    origin: [2]f32 = .{ 0.5, 0.5 },   // a fraction of the element's box
    pub fn affine(self: Transform, bounds: Rect) Affine; // scale, then rotate, about the origin, then translate
};
```

Effects take the shape of the element's box and its decoration's corner
radius, and paint from the bottom as shadow, backdrop blur, background,
gradient, then the element's content. A backdrop blur blurs what zui
drew beneath the element, averaging the pixels as the target stores them
and sampling only inside the element's box, its edges extended, then
draws its tint over them; it has one tint, which is also what a renderer
without blur draws. A gradient is interpolated in OKLab along a line
through the element's center at `angle`, just long enough that the two
corners farthest along it take `from` and `to`. A shadow is culled by
what it paints, not by its element's box. Effects are a pointer, not a
value in `Element` or `Decoration`, and not part of a static `Style`: as
a value in `Element`, every declaration copied them and the interactive
box tree's declaration was 22% slower; in `Decoration`, every decorated
element copied them; in `Style`, every styled element looked for them,
3.5% of the static box tree's declaration. Their copies have a limit of
their own, `max_effects`, since one for every element made each frame
160 KiB larger and `init` 21% slower. A frame that declares no effects
is emitted by a walk that never looks for them; one that does pays for
the look at every element.

A transform applies when painting only: layout, `rectOf` and the
element's neighbours are as if it were absent. Its `transform_begin`
comes before the element's shadow and its `transform_end` after its
subtree, border and clip, so the element's own clip is transformed with
it; a floating element's clip, which holds its target's, comes first and
is not. A floating element on another layer than its parent's begins
every transform around it again on its own layer, outermost first, since
the layer sort moves its commands out of theirs. Culling inside a
transform uses the box around the clip in the element's units, so an
element laid out outside the clip but moved into it is drawn. Hit
testing inverts it: each transformed element enters a space, a region
inside it is hit where the pointer lands in that space's units, and only
inside the clip around every transformed element enclosing it. A
transform that scales to nothing draws nothing and is never hit.

A divider is centered in the gap between two children and spans the
element across its flow, inside the border's widths. Floating children
take no part. Dividers are `rectangle` commands in the border's color,
emitted inside the element's clip, so they scroll and are cut off with
the children they separate, and they paint over the children and under
the border. A border whose widths are all zero emits no `border`
command, so `.border = .{ .color = line, .between_children = 1 }` draws
dividers alone.

The four switches are written as booleans, `.focusable = true`, and null
means false. They are optional because Zig stores a `bool` field as one
bit and loads it as a byte, which LLVM cannot fold: with `bool`, every
`open` stored its four defaults to the stack and loaded them back, 14%
of the box tree's declaration (§20.2). `Axes` is a byte for the same
reason.

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

- **64-bit FNV-1a, by content.** 32-bit ids collide in practice: at
  8,000 ids a frame the birthday bound is about 1% per frame, against
  about 2 × 10⁻¹² at 64 bits.
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
frames in flight. A `layout` or `decoration` set on the element itself
replaces the style's.

Config references in element storage are therefore pointers, either into
the frame arena or to static memory. The extra width on 64-bit targets
is paid for by never copying a static config; the box tree's declaration
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
  `pressed` is true while any pointer whose press began on the element
  is down.
- **Keyboard and accessibility activation.** Enter or Space on the
  focused element, and an `invoke` action naming the element, also count
  as `clicked`, so everything clickable works without a pointer.
- **`widgetState`** is `.disabled`, `.pressed`, `.hovered`, `.focused`
  or `.idle`, checked in that order. Skins index it with
  `std.EnumArray`, so a new state is a compile error in every skin until
  it is handled.
- **The answers come from a compact copy** of the previous frame's
  rectangles, hit regions and tab order, kept in the `Context` so they
  survive `frames_in_flight = 1`.

### 11.2 Focus

Pressing a focusable element focuses it; pressing elsewhere clears
focus; an element that stops being declared loses it. Tab and Shift-Tab
move in declaration order among focusable, enabled elements, and a
`focus_scope` keeps focus inside its descendants. `requestFocus` takes
effect at the next `beginFrame`.

### 11.3 Intents

Queries that merge devices into what the user meant:

| Query | From |
|---|---|
| `clicked(id)` | click, tap, Enter/Space, `invoke` action |
| `manipulation(id) ?Manipulation` | drag, pinch, rotate, wheel, momentum, `scroll` action: translation, scale, rotation and pivot, summed over the frame; `translation` moves the content with the pointer, and against the wheel |
| `contextRequested(id)` | right click, long press, the menu key on the focused element, `show_menu` action |
| `doubleTapped(id)` | a second tap within the double-tap window, on an element with `double_tap` |
| `dismissed(id)` | Escape, back, gamepad B, while `id` or an element in its focus scope is focused; a `dismiss` action naming one of them |
| `adjusted(id) ?i32` | arrows on a focused slider, a dial, `adjust` action: right and up +1, left and down −1, and an action's own steps |
| `navigated(id) ?NavigationDirection` | arrows, D-pad, on the focused element: `left`, `right`, `up` or `down`, the last this frame |

`navigated` returns a `NavigationDirection`, not `Layout`'s `Direction`,
which has no up or left. Only `doubleTapped` and `manipulation` need
`features.gestures`; the others come from keys and buttons too, so a
long press is the only part of `contextRequested` the feature adds.

### 11.4 Gestures

*Compiled out without `features.gestures`. `Element.gestures` is then
ignored rather than a compile error, so a widget declares its gestures
once for every context.*

Elements declare what they accept, as a packed set (`zui.Gestures`, one
byte) stored in their hit region:

```zig
.gestures = .{
    .pan = .vertical,   // the axes it scrolls or pans on, with any pointer: .horizontal, .vertical, .both
    .zoom = true,       // two-pointer scale and rotation
    .drag = true,       // moves a drag-and-drop payload (§11.5), not the view
    .long_press = true,
    .double_tap = true, // delays this element's single tap
    .custom = true,     // the application's recognizer claims or declines
},
```

Declaring any gesture makes an element interactive, as `focusable` does:
a map that pans is hovered, pressed and tapped like a button. A scroll
container accepts pan on its scrolled axes by default, with touch and
pen; the mouse scrolls it with the wheel, so a mouse drag in a list
stays with what it pressed, unless the container declares `pan` itself.

- **One rule decides.** Once a pointer passes the touch slop
  (`Gestures.touch_slop`, 8 layout units, measured from where it
  pressed), its axis locks to the larger component of the motion, and
  the pointer goes to the innermost region under its press that accepts
  that motion component and still has room to move that way. That rule
  is also scroll chaining. The region that takes it keeps it until it
  lifts, and takes the other axis too if it pans on both. Any other
  element it pressed loses the press, so it is neither `pressed` nor
  clicked. The motion is reported by `manipulation`, from where the
  pointer pressed, and a scroll container scrolls by it itself. The
  wheel goes to the innermost region that scrolls with room on its axis,
  or pans on it, likewise. With two pointers, scale and rotation go to
  the innermost region that accepts zoom: a pointer pressed while
  another is down, both inside such a region, makes the pair zoom it,
  taking both from what they pressed or panned, so a pinch that starts
  on a list inside a map zooms the map. `scale`, `rotation` (clockwise)
  and the centroid's `translation` are summed over the frame, and
  `pivot` is where the centroid ended. When one lifts, the other pans
  the region if it pans. A release nothing claimed is a tap.
- **Delays are opt-in and local.** Only an element with `double_tap`
  delays its single tap until the double-tap window passes
  (`Gestures.double_tap_seconds`, 0.3 s from the first tap's release to
  the second's); it is then `clicked`, and a second tap in time is
  `doubleTapped` instead. A press on an element with `long_press` held
  within the slop for `Gestures.long_press_seconds` (0.5 s) is
  `contextRequested` and not a tap. Both are timed by the events'
  instants and the record's `now`, and set the next frame's deadline
  (§6.6), so a replay fires them in the same frames.
- **Momentum** is state in the state table under the element, so it ends
  when the element is no longer declared, and it sets the next frame's
  deadline (§6.6). A pan released faster than `Gestures.fling_speed` (50
  layout units a second, measured over the events of the last 0.1 s
  before the release, by their instants) coasts on its axes, slowing by
  a factor of e every `Gestures.momentum_seconds` (0.325 s), so it
  travels about the release speed times that; each frame moves it to the
  record's `now`, before the record's events, as `manipulation` and a
  scroll container's offset. It stops below 10 units a second, at the
  end of a scroll container's content, or when a pointer presses on it,
  and asks for frames `Gestures.momentum_frame_seconds` (1/120 s) apart
  meanwhile. At most `max_input_contacts` elements coast at once; a
  fling beyond them does not coast and is reported on that limit.
- **Custom recognizers are code in declaration.** `ui.pointerEvents(id)`
  returns the frame's events of pointers pressed on or claimed by `id`,
  in order, as an iterator (`zui.PointerEvents`). A recognizer keeps its
  state in `state(id, T)`. An element with `custom` holds itself and its
  ancestors off a pointer, with every built-in gesture, until it calls
  `ui.claim(pointer)` or `ui.decline(pointer)`; the decision applies at
  the next `beginFrame`, a frame late, and no events are lost meanwhile:
  a declined pointer is arbitrated over all its motion since the press,
  and a claimed one takes its press from whatever else it pressed and is
  never a tap. A pointer released undecided is a tap. A module ships a
  recognizer as a plain function, as `zui_widgets`' `lasso` does.

### 11.5 Drag and drop

*Compiled out without `features.gestures`, like the gestures it is
arbitrated with.*

```zig
pub fn dragging(self: *const Self, source: Id) ?Drag                       // the pointer, where it is, and how far from its press
pub fn startDrag(self: *Self, source: Id, payload: anytype) void
pub fn dropped(self: *Self, target: Id, comptime Payload: type) ?Payload   // released on `target` this frame
pub fn draggedOver(self: *Self, target: Id, comptime Payload: type) ?Payload  // over `target` now
```

A drag source declares `.gestures.drag`, so §11.4 decides between
dragging, scrolling and clicking: past the touch slop, a source takes
the pointer on the axes no region around it pans on for that pointer, so
a card in a list that scrolls vertically drags sideways and scrolls the
list vertically, and with the mouse, which scrolls the list with its
wheel, drags on both axes. A region inside the source that pans on the
axis is nearer and takes it first. The source stays where it is laid out
and is neither scrolled nor clicked; `dragging` reports the pointer, and
the application draws what follows it, as a floating element with
`capture = false`.

`startDrag` gives the drag its payload, called once `dragging` reports
it. Called while a pointer's press on the source is still down but
nothing drags it, it starts the drag with that pointer, taking it from
whatever else it pressed or panned: this is how a long press, or a
custom recognizer that claims the pointer, lifts a card out of a list
that pans on both axes. The payload lives in the state table under the
source, typed, and stays while the drag lasts, so dropping one type on a
target that expects another yields `null`, never a reinterpretation, and
the source may stop being declared while it is dragged. A drag released
in the record that started it, before declaration could give it a
payload, drops nothing, and neither does a cancelled pointer.

A target is any element with a hit region: `dropped` and `draggedOver`
answer for each region the hit test at the pointer passes through, the
topmost and those around it, so a list and the row a card was released
on both receive it. Files from the OS are a `files_dropped` event, not
this.

---

## 12. Persistent state

```zig
pub fn state(self: *Self, id: Id, comptime T: type) *T              // zeroed on first use
pub fn stateIfPresent(self: *Self, id: Id, comptime T: type) ?*T   // null instead of creating it
```

- **Keyed by `(id, type)`.** The same id can hold a `ScrollState` and an
  application's `Expanded` flag in separate slots, and asking for
  another type never returns the wrong one.
- **Fixed slots.** `@sizeOf(T) <= 64` and `@alignOf(T) <= 16`, checked
  at comptime; the error says to store an index to the application's own
  storage instead.
- **Eviction.** A slot untouched for `state_frames_until_eviction`
  frames is freed at the next `beginFrame`, with backward-shift
  deletion, so the table accumulates no tombstones. An element that
  disappears loses its state: the immediate-mode equivalent of
  unmounting.
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
`ImageHandle` is set and `custom` when `CustomData` is set. An `image`
carries its handle, tint and corner radius, as declared (§10.1).
**Optional commands** exist only when `Config.commands` includes them:
`gradient`, `shadow`, `backdrop_blur`,
`transform_begin`/`transform_end`, `material`.

`Payload` is a union built with `@Union` from exactly those variants, so
a renderer's exhaustive `switch` covers what it draws and nothing else.
Adding an optional command to zui never breaks an existing renderer;
adding a base command always does, at compile time.

### 13.2 Order and snapping

`Frame.commands()` is in paint order: by layer, then declaration order.
A border and its dividers are emitted after its element's subtree,
inside the element's own clip, which leaves them whole since both lie in
its box. Bounds snap to whole physical pixels using the frame's
`scale × zoom`.

### 13.3 Lowering

Emission replaces what the renderer did not declare, so the renderer
never sees it:

| Optional | Lowered to |
|---|---|
| gradient | a rectangle in its mean color, in OKLab |
| shadow, glow | nothing |
| backdrop blur | a rectangle in its tint |
| transform | the untransformed element; its hit region stays untransformed |
| material | the element's fallback background |
| a corner shape outside `Config.corner_shapes` | the same corners, round, listed in `Diagnostics.lowered_corner_shapes` |
| `ExtendedColor` without `zui_extended_color` | the color clamped to `Color`, and `Diagnostics.clamped_colors` set when that changed it |

Capabilities are comptime-known, so lowering costs nothing when the
renderer supports everything, and each lowering is listed in the frame's
diagnostics for the inspector.

### 13.4 Hit regions and chrome

Hit regions carry the id, rectangle, clip, layer, flags and accepted
gestures of every interactive element, and of every floating element
with `capture = true`.

*With `features.chrome_regions`.* A window opened with
`WindowOptions.title_bar = .custom` leaves its title bar to the
application, and `Environment.custom_title_bar` says whether it did. The
application marks the parts it draws with `Element.chrome`: a
`title_bar`, which a press drags, a double click maximizes and a
secondary click opens the window menu on; the `minimize_button`,
`maximize_button` and `close_button`, which the host works itself when a
press and its release land on them, as the system's own; and `resize_*`
edges and corners. `Frame.chromeRegions()` lists them in tree order,
each with its id and its bounds as laid out:

```zig
pub const ChromeKind = enum(u8) { title_bar, minimize_button, maximize_button, close_button,
    resize_top, resize_bottom, resize_left, resize_right, resize_top_left, resize_top_right, resize_bottom_left, resize_bottom_right, client };
pub const ChromeRegion = struct { id: u64, bounds: Rect, kind: ChromeKind };
```

Each title bar is followed by a `client` region for every interactive,
disabled or scrolling element inside it that declares no chrome, so a
search field or a tab in the title bar stays the application's. Where
regions overlap, the later one is on top. Each element adds at most one
region, so the list never overflows. `zui_app` hands the list to the
host's `zuiChromeRegions` with every frame (§16.3). The host answers the
window manager from its copy (`WM_NCHITTEST` on Windows,
`xdg_toplevel.move` and `resize` on Wayland), and still forwards the
pointer over the caption buttons, so they show hover and press. A press
the host works ends as `pointer_cancel`, not a release, so zui reports
no click and an application that works the buttons on `clicked`, for the
keyboard and assistive technologies, never works one twice. Chrome
changes nothing about an element's interaction, and a frame without the
feature lists none and costs nothing.

### 13.5 Semantics

*With `features.semantics`.*

`.semantics = .{ .role = .button, .label = "Save" }` adds an entry to
`Frame.semantics()`: id, role, label, value, bounds, state, supported
actions and a heading's level, in tree order, each with the index of the
nearest entry around it, and, for an element that scrolls, where its
view lies over its content (`SemanticScroll`: offset, content and
viewport sizes, and the axes it scrolls on, as the frame's layout placed
them). A host that declares `zuiSemantics` (§16.3) is handed the list
after each `endFrame` and bridges it to the platform's accessibility
API; the window is opened with room for it (`WindowOptions.semantics`).
Actions come back as `action` events naming the id, answered by the same
queries as other input (§11.3). An element's flags and gestures are the
actions it reports, beyond those it declares: `invoke` when it is
interactive, `focus` when focusable, `scroll` when it scrolls or pans,
`show_menu` when it takes a long press; a disabled element reports and
takes none.

```zig
pub const Semantics = struct {
    role: SemanticRole,            // button, checkbox, slider, text_field, combo_box, option, dialog, ...
    label: []const u8 = "",        // copied
    value: SemanticValue = .none,  // .text (copied), or .range: value, min, max, step
    state: SemanticState = .{},    // checked, expanded, selected; zui adds disabled and focused
    actions: Actions = .initEmpty(),
    level: u8 = 0,                 // a heading's level, 1 for the topmost; 0 for none
};
pub const Action = union(ActionKind) { invoke, focus, adjust: i32, scroll: [2]f32, show_menu, dismiss };
```

`invoke` is a click, `focus` moves focus as Tab would, `adjust` adds its
steps to `adjusted`, `scroll` moves a scroll container as the wheel does
and is reported by `manipulation`, `show_menu` is a context request and
`dismiss` a dismissal. Labels and text values are copied into the frame,
counted against `max_text_bytes`; one that does not fit is cut at a
character and reported (§17.2). Without the feature, `Element.semantics`
is ignored, `action` events are dropped, and none of this is compiled.

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
5. **The handoff calls no `Io`.** Publishing is plain atomics over
   memory reserved up front, so it behaves the same from a thread pool,
   a fiber, a single-threaded `Io`, an OS thread or a C callback.
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
  `View`. Every read in a frame sees what the swap made readable.
  Outside a frame it panics, in every build: zui holds the sources only
  from `beginFrame` to `endFrame`, so there is no view to read.
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
- **Abandoning.** Keyed and task sources carry an atomic abandon flag
  the UI sets when demand lapses and the producer reads at its own pace.
  It is written only when demand changes, and nothing waits on it.
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
  assert it in the source, since the core keeps nothing in the source to
  tell two contexts apart. `zui_async`'s sources assert that the frame
  numbers `zuiEndFrame` sees only increase.
- **Large data travels by handle.** A publish copies its value once, so
  a catalog or decoded image is published as a handle to immutable data,
  and handed back for release by the source.
- **A producer that may run on the UI thread never waits for space.** On
  a single-threaded `Io`, the swap that would free space runs on the
  same thread; it handles `error.Full` instead.
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
`frames_in_flight` frames ahead. The event is reset before a second
check for a free arena, which closes the race with a `release` between
the check and the wait. Each arena owns everything its frame references,
so the threads share no mutable memory.

### 15.3 Parallel measurement

With `zui_thread_safe` text, text is measured inline until a frame has
made `parallel_measure_threshold` calls. The frame is then evidently
cold (the first frame, a font or zoom change), so zui collects the rest
of the frame's distinct misses, measures them in batches across an
`Io.Group`, stores them in the cache, and continues inline on hits. Warm
frames never pay for the check. A cancelation of the frame's task keeps
the measurements made and passes the cancelation on.

### 15.4 Many contexts

Contexts share nothing, so separate windows, an offscreen panel or a
thumbnail render run their frames concurrently with no code in zui. Each
context has its own sources; data shared between windows is published
into each. `zui_app` runs one context per window (§19.5). Opening a
window makes its context, which allocates as `init` does; its frames
allocate nothing.

---

## 16. Contracts

### 16.1 How every contract is checked

A type implements a contract by declaring `zui`-prefixed members.
Everything else on the type is its own business, so a contract never
collides with its API, and one type may implement several (a renderer
may also be the text contract).

**The exceptions are types the application names directly,** which keep
their plain names because they are the implementer's own API as much as
the contract's:

| Contract | Unprefixed declarations | Why |
|---|---|---|
| Source | `Delivery`, `View` | the application writes `Source.View`; the wire format names `Delivery` |
| Renderer | `ImageHandle`, `MaterialHandle`, `CustomData`, `FontId` | they are the renderer's real types, which `contextConfig` copies into `Config` |
| Application (`zui_app`) | `Host`, `Renderer`, `Text` | the composition root names its host, its renderer and, when the renderer does not measure, its text contract; `zui_app` reads them to open the window, measure and draw |

These are the only plain names a contract reads. They are checked like
the prefixed ones: a missing required one is a compile error, and an
optional one that is absent takes its documented default (`void` for the
payload types, `u16` for `FontId`).

- **A missing required declaration** is a compile error naming the type,
  the contract and the declaration:
  `` "zui: SokolRenderer does not implement zui.Renderer: missing `zuiSubmit`" ``.
- **A wrong signature** is reported by name, with the expected type.
- **An unknown `zui`-prefixed declaration** (one that belongs to no zui
  contract) is a compile error, so a misspelled optional one is never
  silently ignored:
  `` "zui: AppSources.quotes declares unknown `zuiPendng`" ``.
- **Every optional declaration has a documented default.**
- Each message is pinned by a compile-error test.

### 16.2 Renderer

```zig
const SokolRenderer = struct {
    pub const zui_commands: zui.CommandSet = .initMany(&.{ .gradient, .shadow });              // optional commands it draws
    pub const zui_corner_shapes: zui.CornerShapeSet = .initFull();                             // corner shapes it draws; always .round
    pub const zui_surfaces: zui.SurfaceKinds = .initMany(&.{ .win32, .cocoa, .wayland, .x11 }); // native windows it can draw into
    pub const zui_extended_color = false;                                                      // accepts HDR colors
    pub const zui_output_formats: zui.OutputFormats = .initOne(.sdr);                          // targets it draws into; .scrgb_fp16 needs zui_extended_color
    pub const zui_render_thread = true;                                                        // zuiSubmit may run on zui_app's render thread
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

`zui_render_thread` (default `false`) says that `zuiSubmit` may be
called on a thread other than the one that made the renderer and its
surface, so `zui_app` may submit from a render thread of its own. A
renderer bound to its thread's graphics context, as raylib's is, leaves
it out.

`zuiAttachSurface(self, surface) !void` and
`zuiDetachSurface(self, surface) void` (optional, declared together)
give a renderer each window after the first that `zui_app` opens, and
take back each window before it closes, the first included, on the
thread that submits. Around a surface loss (§19.5) they are called for
every window, the first included: each surface is detached when the
platform takes it away and attached again, as the host then names it,
when it returns. A renderer that keeps a swapchain per window makes and
frees it there. Without them a renderer draws any surface it is given as
it is. One without the other is a compile error:
`` "zui: SokolRenderer declares `zuiAttachSurface` without `zuiDetachSurface`; a renderer that keeps something per window declares both" ``.

`zui_app.contextConfig(Renderer, .{ ... })` builds a `Config` from a
renderer's declarations (commands, payload types, and text unless the
overrides name a `Text`), so the renderer's vocabulary and the core's
never disagree.

### 16.3 Host

```zig
const Win32Host = struct {
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .many, .system_material = true }; // material: Mica, vibrancy
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.win32);
    pub const zui_output_formats: zui.OutputFormats = .initMany(&.{ .sdr, .scrgb_fp16 });         // an FP16 swapchain on an HDR display

    pub fn zuiPoll(self: *Win32Host, window: zui.WindowId, record: *zui.RecordBuilder) bool { ... } // false: the window closed
    pub fn zuiWaker(self: *Win32Host) zui.Waker { ... }
    pub fn zuiWait(self: *Win32Host, next: zui.NextFrame) void { ... }   // the loop half: this, or zuiRun, or neither
    pub fn zuiSurface(self: *Win32Host, window: zui.WindowId) zui.Surface { ... }
    pub fn zuiApply(self: *Win32Host, window: zui.WindowId, requests: zui.HostRequests) void { ... } // cursor, IME window
    pub fn zuiOpenWindow(self: *Win32Host, options: zui.WindowOptions) zui.OpenWindowError!zui.WindowId { ... } // with .many
    pub fn zuiCloseWindow(self: *Win32Host, window: zui.WindowId) void { ... }                                  // with .many
    pub fn zuiSemantics(self: *Win32Host, window: zui.WindowId, nodes: []const zui.SemanticNode) zui.SemanticsDropped { ... } // optional: the accessibility bridge
    pub fn zuiChromeRegions(self: *Win32Host, window: zui.WindowId, regions: []const zui.ChromeRegion) void { ... } // optional: a custom title bar

    pub const zuiClipboard = struct { ... };       // optional services: write(host, text); read(host, request, sink)
    pub const zuiNotifications = struct { ... };   // show(host, request, notification, sink)
    pub const zuiFileDialogs = struct { ... };     // show(host, window, request, dialog, sink)
    pub const zuiOpenUrl = struct { ... };         // open(host, url)
    pub const zuiMenus = struct { ... };           // popup(host, window, request, items, position, sink); setBar, optional
    pub const zuiFileWatch = struct { ... };       // watch(host, directory, sink): file changes into a source
};
```

```zig
/// Names one call to a service, so its answer can be told from others'.
pub const ServiceRequest = enum(u32) { _, pub fn of(comptime name: []const u8) ServiceRequest };
/// What one call answered, borrowed for the publish.
pub const ServiceAnswer = struct {
    request: ServiceRequest,
    window: WindowId = .main,
    outcome: union(enum) { clipboard_text: []const u8, files_chosen: []const u8, menu_item_chosen: MenuItemId,
                           notification_activated, notification_dismissed, canceled, failed: ServiceFailure },
    left_out_bytes: u32 = 0,        // what the host itself could not hold
};
/// Where a host publishes answers, as `FileChangeSink` is a pointer and a function.
pub const ServiceSink = struct {
    context: *anyopaque,
    publishFn: *const fn (*anyopaque, *const ServiceAnswer) Wake,
    pub fn of(source: anytype) ServiceSink   // any source whose publish takes a ServiceReply(n)
};
/// The answer as plain data, `n` bytes of text or paths inline: text cut at a character, paths whole, the rest counted.
pub fn ServiceReply(comptime n: u32) type   // .request, .window, .kind, .menu_item, .failure, .left_out_bytes; text(), paths()
pub const ServiceError = error{ Busy, TooLarge, InvalidUtf8, InvalidUrl, Unavailable };
pub const ServiceFailure = enum(u8) { unavailable, denied };
pub const Notification = struct { title: []const u8, body: []const u8 = "" };
pub const FileDialog = struct { kind: Kind = .open_file, title, directory, file_name: []const u8 = "", filters: []const FileFilter = &.{} };   // open_file, open_files, save_file, choose_folder
pub const FileFilter = struct { name: []const u8, extensions: []const []const u8 };   // .{ .name = "Themes", .extensions = &.{"zon"} }
pub const MenuItem = struct { id: MenuItemId, label: []const u8 = "", submenu: []const MenuItem = &.{}, enabled: bool = true, checked: ?bool = null, shortcut: ?Chord = null };   // MenuItem.separator
pub fn isOpenableUrl(url: []const u8) bool   // a scheme of two letters or more, and not `file:`
```

`checkHost` checks each function's type exactly:

| Service | Function | Type (`Host` is the host) |
|---|---|---|
| `zuiClipboard` | `write` | `fn (*Host, []const u8) zui.ServiceError!void` |
| | `read` | `fn (*Host, zui.ServiceRequest, zui.ServiceSink) zui.ServiceError!void` |
| `zuiNotifications` | `show` | `fn (*Host, zui.ServiceRequest, zui.Notification, zui.ServiceSink) zui.ServiceError!void` |
| `zuiFileDialogs` | `show` | `fn (*Host, zui.WindowId, zui.ServiceRequest, zui.FileDialog, zui.ServiceSink) zui.ServiceError!void` |
| `zuiOpenUrl` | `open` | `fn (*Host, []const u8) zui.ServiceError!void` |
| `zuiMenus` | `popup` | `fn (*Host, zui.WindowId, zui.ServiceRequest, []const zui.MenuItem, [2]f32, zui.ServiceSink) zui.ServiceError!void` |
| | `setBar`, optional | `fn (*Host, zui.WindowId, zui.ServiceRequest, []const zui.MenuItem, zui.ServiceSink) zui.ServiceError!void` |
| `zuiFileWatch` | `watch` | `fn (*Host, []const u8, zui.FileChangeSink) zui.FileWatchError!void` |

A service that is not a struct, a function missing or of another type,
is a compile error:
`` "zui: demo.Host.zuiClipboard is missing `read`, which must be fn (*demo.Host, zui.ServiceRequest, zui.ServiceSink) zui.ServiceError!void" ``.
A service may declare more functions than these, which are not checked.

```zig
/// One change in a watched directory; plain data, so it relays and replays.
pub const FileChange = struct {
    kind: Kind,                     // added, removed, modified, renamed_from, renamed_to, rescan
    path: Path = .{},               // relative to the directory, `/`-separated, up to 255 bytes inline
    pub fn of(kind: Kind, path: []const u8) FileChange   // `.rescan` when the path does not fit
};
/// Where a watch publishes: any source with `publish(change)`, as `Waker` is a pointer and a function.
pub const FileChangeSink = struct {
    context: *anyopaque,
    publishFn: *const fn (*anyopaque, FileChange) Wake,
    pub fn of(source: anytype) FileChangeSink   // .of(&app.sources.theme_files)
};
pub const FileWatchError = error{ TooManyWatches, DirectoryUnavailable };
```

```zig
pub const WindowId = enum(u32) { main = 0, _ };   // `init` opens `.main`; ids are never given twice in a run
pub const OpenWindowError = error{ TooManyWindows, WindowNotCreated };
pub const HostCapabilities = struct {
    windows: enum { one, many } = .one,   // .many: the host declares zuiOpenWindow and zuiCloseWindow
    system_material: bool = false,
    custom_title_bar: bool = false,   // leaves the title bar to the application; needs `zuiChromeRegions`
};
/// What a host opens a window with (`zui_app` passes it to the host's `init`, and to `zuiOpenWindow`).
pub const WindowOptions = struct { title: [:0]const u8 = "zui", size: [2]u32 = .{ 1280, 720 }, visible: bool = true, resizable: bool = true, material: SystemMaterial = .none, semantics: SemanticsCapacity = .{}, title_bar: TitleBar = .native };
/// Who draws a window's title bar: the system, or the application (§13.4).
pub const TitleBar = enum { native, custom };
/// Room for a window's accessibility bridge; zero nodes opens it with none.
pub const SemanticsCapacity = struct { nodes: u32 = 0, text_bytes: u32 = 0 };
/// What `zuiSemantics` had no room for: nodes cut from the end, and text bytes cut at a character.
pub const SemanticsDropped = struct { nodes: u32 = 0, text_bytes: u32 = 0 };
/// The backdrop a window asks for, by role: Mica and Acrylic on Windows 11, vibrancy on macOS.
pub const SystemMaterial = enum { none, window, transient };

/// Filled by `zuiPoll`, in buffers the application reserved, so polling allocates nothing.
pub const RecordBuilder = struct {
    params: FrameParams,          // the host sets now, viewport and scale; zoom is the application's
    dropped_events: u32,          // refused since `begin`: the newest are dropped, so order holds
    dropped_text_bytes: u32,
    pub fn init(events: []Event, text: []u8) RecordBuilder
    pub fn begin(self: *RecordBuilder, host_params: HostParams) void   // .{ now, viewport, scale }; forgets the last record, keeps zoom
    pub fn append(self: *RecordBuilder, event: Event) void
    pub fn appendText(self: *RecordBuilder, text: []const u8) void     // copied; cut at a character boundary
    pub fn appendFilesDropped(self: *RecordBuilder, drop: FilesDropped) void   // paths copied into the text buffer, whole
    pub fn record(self: *const RecordBuilder) FrameRecord              // valid until the next `begin`
    pub fn recordWith(self: *const RecordBuilder, comptime Deliveries: type) FrameRecordWith(Deliveries)
};

pub fn checkHost(comptime Host: type) void
pub fn checkHostAndRenderer(comptime Host: type, comptime Renderer: type) void   // also: a surface kind both share
```

- **Two halves.** The *window half* is what every host gives:
  `zui_surfaces`, `zuiPoll`, `zuiWaker`, `zuiSurface`, `zuiApply`, and
  the optional declarations below. The *loop half* says who turns the
  loop (§6.1), and a host declares at most one of its calls: `zuiWait`,
  and zui waits on it (*pulled*); `zuiRun`, and the platform runs the
  loop (*pushed*); neither, and only the application's own loop steps it
  (*stepped*). Both is a compile error:
  `` "zui: Win32Host declares both `zuiWait` and `zuiRun`; zui pulls a host's loop or the platform pushes it, never both" ``.

- **`zuiPoll`** starts the record with `begin`, appends what the OS
  reported since the last poll in arrival order, and returns false when
  the window has closed. It is a drain: it never blocks, never presents
  and never begins drawing, so a turn may poll without declaring, and a
  loop that is not zui's may poll whenever it turns.

- **`zuiWait`** returns at once for `.immediately`, at the instant for
  `.at`, and on input or a wake for `.on_event`. Its wake is sticky: it
  clears the wake after the wait returns, never before, so a wake
  between `nextFrame` and the wait ends the wait.

- **`zuiRun(self, io, window, driver) !void`**, or `noreturn` on a
  platform whose loop never returns (`[NSApp run]`), is the whole life
  of a pushed host: it opens the window when the platform allows, calls
  `driver.start(io)` once `zuiSurface(.main)` names its surface, calls
  `driver.step()` from the platform's callbacks and schedules the next
  as the `NextFrame` it returns says, and calls `driver.stop()` before
  the window closes. A pushed host declares no `init` or `deinit`, a
  compile error naming `zuiRun`. Any other type is a compile error:
  `"zui: Win32Host.zuiRun must be fn (*Win32Host, std.Io, zui.WindowOptions, zui.Driver) !void, or noreturn, found fn (*Win32Host, host.Driver) void"`.
  The `io` it passes to `start` is the one the application's tasks run
  on, which may be its own; such a host steps that `Io` before each turn
  and folds the `Io`'s next wake into what it schedules with
  `NextFrame.sooner`.

  ```zig
  /// What zui_app hands a pushed host, as a host hands out its Waker: a pointer and five calls, made on the thread that polls.
  pub const Driver = struct {
      context: *anyopaque,
      calls: *const Calls,   // start, step, suspendSurfaces, resumeSurfaces, stop
      pub fn start(self: Driver, io: std.Io) anyerror!void      // the window is open: makes the text, renderer, contexts, application
      pub fn step(self: Driver) anyerror!?NextFrame             // one turn; null once every window has closed
      pub fn suspendSurfaces(self: Driver) void                 // the platform took the surfaces away
      pub fn resumeSurfaces(self: Driver) anyerror!void         // zuiSurface names each again
      pub fn stop(self: Driver) void                            // frees what start made; again, or before start, nothing
  };
  pub fn sooner(self: NextFrame, other: NextFrame) NextFrame    // on NextFrame: the one that comes first
  ```

- **A stepped host** declares `init` and `deinit` and neither loop call:
  it is a window the application already owns (an editor's panel, a
  game's overlay, a page's canvas behind a host package's exports), and
  its waker is the application's to forward to that loop.

- **`zuiApply`** takes the frame's `HostRequests`, setting the cursor
  and placing the IME window.

- **Many windows.** A host whose `zui_capabilities.windows` is `.many`
  declares `zuiOpenWindow` and `zuiCloseWindow`; one whose windows are
  `.one` declares neither, each a compile error otherwise:
  `` "zui: Win32Host declares zui_capabilities.windows = .many but not `zuiOpenWindow`, which must be fn (*Win32Host, zui.WindowOptions) zui.OpenWindowError!zui.WindowId" ``.
  `init` opens `.main`. `zuiOpenWindow` opens another, on the thread
  that polls, with an id the host never gives again in the run, and
  returns `error.TooManyWindows` past the windows it holds. Each window
  has its own events, viewport, scale and requests, polled with its id;
  `zuiWaker` and `zuiWait` are the host's, so a wake or input in any
  window ends the one wait. `zuiCloseWindow` closes any window, `.main`
  included, after its last frame has been submitted; its id then polls
  false. Lifecycle events reach every open window, since each window's
  context reacts to them.

- **`zuiSemantics`**, optional, is handed `Frame.semantics()` on the UI
  thread after `endFrame` and before the frame is submitted, so a render
  thread never races it; the nodes are valid only during the call. The
  host copies them into room it took when the window opened with
  `WindowOptions.semantics`, which `zui_app` sizes from `Config.limits`,
  so it allocates nothing after `init`. What does not fit is cut from
  the end, which leaves a tree since parents come first, and returned in
  `SemanticsDropped`; `zui_app` reports it once. The platform's requests
  are appended to the next record as `action` events, so they relay and
  replay as other input does. A window opened without room is left to
  the OS's default accessibility. `checkHost` checks its signature.

- **`zuiChromeRegions`**, optional, is handed `Frame.chromeRegions()` at
  the same point, valid only during the call. A host whose capabilities
  include `custom_title_bar` must declare it, or `checkHost` fails with
  `"zui: Win32Host.zui_capabilities.custom_title_bar is true but Win32Host does not declare zuiChromeRegions, so the OS could not move its window"`.
  It keeps a copy in fixed room, keeping the regions that fit from the
  first, and answers the window manager from that copy on whatever
  thread the OS asks on. `checkHost` checks its signature.

- **The composition root checks the pair.** `checkHostAndRenderer` is
  called by the application or `zui_app`, the one place naming both:
  `"zui: RaylibHost and TerminalRenderer share no surface kind: the host gives .library, the renderer draws into .terminal"`.

- **Native hosts** own the window, one per OS, and pull the loop where
  the OS lets a thread block (Windows, Wayland), or push it where the OS
  owns it (macOS and iOS, whose `zuiRun` is `noreturn`).

- **Adapter hosts** wrap a library that insists on owning its window
  (raylib), with fewer capabilities, through `InputSampler`.

- **System materials.** A host with `system_material` asks the OS for
  the window's `material`, and reports whether it shows as
  `Environment.system_material`: false on a system without one (Windows
  10), with transparency turned off, or for `.none`. The renderer clears
  to transparent and keeps the alpha it draws, and the application's
  root leaves its background off while `system_material` is true, so the
  same code shows the material or its own solid background.

- **Signal handlers** only set an atomic flag and wake; the lifecycle
  event arrives in the next record. SIGKILL and SIGSTOP cannot be
  caught, so they are not values of `Lifecycle`.

- **Services** are optional nested declarations, each a struct of
  functions taking the host first. They are work, so declaration never
  calls one (§14.1): declaration records that the application wants one,
  and the application calls it between frames, usually from `zuiLoader`,
  through `zui_app.ServicesOf(Host)` and its `has_*` guards (§16.6).

- **Every call returns at once.** One that may take the user's time (a
  dialog, a menu, a notification) or the OS's (reading the clipboard,
  which is asynchronous on Wayland and the web) names a
  `zui.ServiceRequest` and a `zui.ServiceSink`, and a call that returns
  without an error publishes exactly one answer for its request into the
  sink later, never from two threads at once, waking for it; a menu bar
  answers once for each choice. The sink is usually a
  `zui_async.Stream(zui.ServiceReply(n), ...)` in the application's
  `Sources`, so answers are deliveries that relay and replay, and a
  replayed session sees the file the user chose without opening a
  dialog. An answer that does not fit `n` bytes keeps what fits, text
  cut at a character and paths whole, and counts the rest.

- **Calls that attach to a window** (dialogs, menus) name it. A host
  shows one dialog or menu at a time, and refuses another with
  `error.Busy`, as it refuses a call of a kind it is still answering.
  Positions are in layout units from the window's top-left. `setBar`
  replaces the window's menu bar, or removes it given no items; a choice
  the user made from a bar before it was replaced is still answered, to
  that bar's request.

- **Opening a URL** hands it to the system's handler for its scheme. A
  path, or a `file:` URL, is refused with `error.InvalidUrl`, since
  opening it would run what it names (`zui.isOpenableUrl`). A URL the
  system then fails to open is not answered: the system shows its own
  error.

- **Clipboard text** is copied by `write` at once, into the OS's memory
  or, on a host that serves the selection itself, into its own fixed
  buffer (`error.TooLarge` past it). Where the platform offers no
  clipboard, as a compositor without a data device does, `write` and
  `read` are refused with `error.Unavailable`.

- **Text the system cannot show whole,** such as a notification's title
  past its length, is cut at a character, as a label is.

- **Watching files** is the service that is a source:
  `zuiFileWatch.watch(host, directory, sink)` watches a directory and
  its subdirectories until the host's `deinit`, and publishes each
  change into `sink` from a thread of the host's, waking for the publish
  that made the source fresh. The sink is usually a
  `zui_async.Stream(zui.FileChange, ...)` in the application's
  `Sources`, so the changes are deliveries that relay and replay, and a
  full stream refuses and is reported as any source is (§14.7). Changes
  the OS lost, or a path that does not fit, arrive as `.rescan`.
  Declaration sees which files changed; reading them is the loader's,
  since declaration does no I/O (§14.1), and what it reads reaches a
  frame through a source of its own, such as a `Latest(Theme)`, so a
  replayed session restyles as the live one did. `checkHost` checks
  `watch`'s signature.

### 16.4 Surface

`zui.Surface` is a tagged union of native handles: `win32`, `cocoa`,
`wayland`, `x11`, `web`, `offscreen`; plus `terminal`, a character grid
by its size in cells, with the `*std.Io.Writer` the host gives its
renderer to write the grid through; `library`, a window that a library
such as raylib or sokol_app creates and draws into itself, which only
that library's adapter host provides; and `wire`, a connection to
another process that `zui_wire`'s host makes and only its renderer
writes into (§19.6). A host and renderer whose `zui_surfaces` share no
kind are a compile error naming both, from `checkHostAndRenderer`
(§16.3). Output formats (an FP16 swapchain for HDR) are negotiated
through it, and fall back to SDR unless both sides support them: a host
and a renderer each declare `zui_output_formats: zui.OutputFormats`,
which must include `.sdr` (SDR alone when left out), and a renderer that
names `.scrgb_fp16` must also declare `zui_extended_color`, each a
compile error. The window is opened with `WindowOptions.output_formats`,
the formats both declare (`zui.sharedOutputFormats(Host, Renderer)`);
the host picks the best its display shows, and a native surface carries
the one it chose, which the renderer reads with
`surface.outputFormat()`. A `wayland` surface also carries
`transparent`, true for a window that shows the system's material
(§16.3): a Wayland compositor blends a surface over what is behind it by
the alpha its buffer holds, so the renderer keeps alpha only there and
presents every other surface opaque, whatever alpha its blended draws
leave.

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
| `begin_frame` | `wait_for_frame`, `evict_state`, `apply_events`, `swap_sources` when `Sources` has a field, `relay` while a listener is attached (§6.3) |
| `end_frame` | `measure_text`, `fit_widths`, `distribute_widths`, `wrap_text`, `fit_heights`, `distribute_heights`, `position` (§8.2), then `emit`, and `sort_layers` when a frame draws outside layer 0 |

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
| zui uses it implicitly | **a documented fallback** | no material: the fallback background; no blur: the tint; an unhandled lifecycle event: the OS default; no `zuiSemantics`: an assistive technology sees only the window |
| the application asks for it by name | **a compile error at the call**, unless guarded by `has_*` | notifications on a target without them; a second window on a host with one |
| the target has it, this machine does not | **a returned status** | Mica on Windows 10; notifications the user denied |

`zui_app` reports every fallback in effect at run time, and the
inspector lists them, so none is silent to a developer who looks.

The guards are `zui_app.ServicesOf(Host)`'s `has_clipboard`,
`has_notifications`, `has_file_dialogs`, `has_open_url`, `has_menus`,
`has_menu_bar` and `has_file_watch`, each known at compile time, so a
call inside one is not compiled for a host without the service; a call
outside its guard on such a host fails naming the guard:
`` "zui_app: zui_raylib.Host has no `zuiNotifications`; guard the call with `if (zui_app.ServicesOf(zui_raylib.Host).has_notifications)`" ``.
`zui_app.Windows(App).has_many_windows` guards opening a window:
`"zui_app: zui_raylib.Host opens one window (its zui_capabilities.windows is .one), so demo.App cannot open another"`.

### 16.7 Skin

```zig
const QuietSkin = struct {
    accent: zui.Color = .rgb(0x5b8cff),

    pub fn zuiStyle(skin: *const QuietSkin, part: zui_widgets.Part, state: zui.WidgetState, environment: *const zui.Environment) zui_widgets.Style(Ui) { ... }
};

const widgets: zui_widgets.Widgets(Ui, QuietSkin) = .{ .skin = .{} };
```

`zui_widgets` checks the skin once, when `Widgets(Ui, Skin)` is
instantiated. A skin is a struct that declares `zuiStyle` and no other
`zui`-prefixed declaration.

- **`part`** is one element a widget draws: `button`, `checkbox_box`,
  `checkbox_mark`, `slider_thumb`, `text_field_caret`, `dropdown_option`
  and the rest of `zui_widgets.Part`. A checked box
  (`checkbox_box_checked`) and the selected option
  (`dropdown_option_selected`) are parts of their own, so `state` stays
  `WidgetState`.
- **`state`** is the element's `widgetState`, or `.disabled` from the
  frame a control is declared disabled. A skin that indexes
  `std.EnumArray(WidgetState, T)` fails to compile when a state is
  added.
- **`environment`** is the context's (§7.2). A skin follows the theme,
  the contrast and `text_scale` by reading it, so no widget reads them.
- **`Style(Ui)`** holds the background, the border, the focus ring, the
  corner radius, the text style, a fixed size, the padding, the gap, an
  indicator glyph and a popup's layer, in the context's color and font
  types. Each `Part` reads only the fields its doc comment lists.
- **The focus ring is `Style.focus_ring`.** It is drawn in place of the
  border while the element has keyboard focus, which it keeps while
  hovered or pressed, so it is a field and not a state.
- **A skin of data** holds its tables and returns from them:
  `parts: std.EnumArray(Part, std.EnumArray(WidgetState, Style(Ui)))`
  answers `return skin.parts.get(part).get(state);`. A theme pack
  (`zui_themes`) is such a type, generic over `Ui` so the application
  gives it its fonts.
- **No cost beyond the call.** `Skin` is a comptime type and `zuiStyle`
  a direct call, so `Widgets` is exactly as large as its skin and has no
  vtable.
- **`zui_widgets.DesignSkin(Ui)`** is zui's own skin (§19.2): each
  `Part` declares its appearance (§18.2), and `zuiStyle` answers from
  the `Tokens` (§18.1) it holds.

The messages: `"zui_widgets: a skin must be a struct type, got u32"`;
`` "zui_widgets: demo.Skin does not implement the skin contract: missing `zuiStyle`" ``;
`"zui_widgets: demo.Skin.zuiStyle must be fn (*const demo.Skin, zui_widgets.Part, zui.WidgetState, *const zui.Environment) zui_widgets.Style(Ui), found …"`;
`` "zui_widgets: demo.Skin declares unknown `zuiStlye`" ``.

---

## 17. Errors and diagnostics

Declaration functions never return errors. Failures are reported once
per frame, with full context.

### 17.1 Programmer errors

| Condition | Safe builds | Release builds |
|---|---|---|
| unbalanced `open`/`close` | panic naming the unclosed element | closed implicitly; reported |
| `close` without `open` | panic | ignored; reported |
| duplicate id in a frame | panic naming both declarations | the second is non-interactive; reported |
| `scroll` or `focusable` without an id | panic | clips without scrolling / not focusable; reported |
| `exit` without an id | panic | no exit animation |
| `ui.source` outside a frame | panic | panic: zui holds no sources between frames (§14.3) |

With `-Dzui-debug`, ids keep their names, so messages read
`zui: duplicate id "save" (0x…) in one frame`.

### 17.2 Limits

Elements, depth, text bytes, commands, state slots, cache entries,
events, pointers, ghost commands and source capacities all fail the same
way:

1. The part that fits is kept. Overflowing elements are dropped, their
   subtrees skipped cheaply with depth still tracked, so `close` pairs
   up.
2. `frame.diagnostics` records which limit, by how much, the peak
   needed, and the id where it first happened.
3. `frame.diagnostics.check()` returns `error.CapacityExceeded` for
   applications that want to stop; `zui_app` logs it once per limit.

---

## 18. Styling, color and themes

- **`Color`** is RGBA8, with `.rgb(0x3366ff)`, `.rgba`, `.mix`, and
  comptime conversion from hex. **`ExtendedColor`** is 4×f16 linear
  scRGB, where 1.0 is SDR white; values above it are HDR, values outside
  0–1 are wide gamut. It has `Color`'s helpers, `.rgb` and `.rgba`
  decoding sRGB, so a theme compiles with either, plus
  `.linear(r, g, b, a)` and `toColor`, which clamps. `Config.Color`
  picks one, so an SDR application keeps 4-byte colors.
- **A theme is the application's struct.** zui has no theme registry, no
  inheritance and no cascade. Switching theme passes a different value,
  and costs a field read.
- **State-dependent styles** index `std.EnumArray(WidgetState, T)`, so a
  new state is a compile error in every theme until handled.
- **Comptime precomputation:** colors in OKLCH or hex, palettes, and
  whole static styles (§10.3) are computed during the build and live in
  read-only memory.

**The design system** builds on these without changing them. An
application can still style by hand. One that declares its components'
looks in roles instead gets light, dark and high contrast, the user's
density, text size and color vision, coherent type and shape, and
contrast checked in every one of those, without writing any of it.
Making an inaccessible application should take effort. The pieces:

| Piece | Holds | Where |
|---|---|---|
| the vocabulary | roles, tiers, `Design`, `Tokens`, the appearance contract and its check | core, `zui.design` |
| the maker of tokens | palettes from seeds, contrast solving, color vision, density, the type scale; the audit and the permutations | `zui_design` (§19.11) |
| the widgets' look | `DesignSkin(Ui)`, a skin over `Tokens` | `zui_widgets` (§19.2) |
| design languages | Fluent, libadwaita and Breeze as `Design`s | `zui_themes` |
| the review | stepping through permutations, verdicts and the report | `apps/review/` |

Tokens are resolved when a preference changes, never during a frame. A
frame reads plain values, as a theme's field is read, so there is still
no cascade.

### 18.1 The vocabulary

```zig
pub const design = struct {
    pub const ColorRole = enum {
        background, surface, surface_raised, surface_sunken, surface_inverse,
        on_surface, on_surface_muted, on_surface_inverse,
        accent, on_accent, accent_container, on_accent_container,
        secondary_container, on_secondary_container,
        danger, on_danger, warning, on_warning, success, on_success,
        outline, outline_muted, focus, scrim,
    };
    pub const Space = enum { none, hair, xs, s, m, l, xl, xxl };
    pub const TypeRole = enum { display, headline, title, body, body_strong, label, caption, code, numeric };
    pub const ShapeRole = enum { control, container, popup, chip, image, indicator };
    pub const CornerSize = enum { square, sharp, smooth, soft, bubble };
    pub const Target = enum { none, pointer, touch };
    pub const Density = enum { compact, comfortable, roomy };
    pub const FaceMetrics = struct { ascent: f32, descent: f32, x_height: f32, cap_height: f32 }; // font units

    pub const Design = struct { ... };                             // what an application or theme pack declares
    pub fn Tokens(comptime Ui: type, comptime ExtraRoles: type) type // resolved values; `ExtraRoles` an enum or void
    pub fn Appearance(comptime Part: type, comptime parts: Parts(Part, void)) type
    pub fn AppearanceWith(comptime Part: type, comptime ExtraRoles: type, comptime parts: Parts(Part, ExtraRoles)) type
    pub fn ColorChoice(comptime ExtraRoles: type) type             // a role, `.extra(role)` or `.unchecked(color, reason)`
};
```

- **`ColorRole`** names what a color is for, never what it looks like.
  Each `on_*` role is the text and icons on its partner. An application
  adds its own roles as an enum, `ExtraRoles`, each declared with the
  role it pairs with in its `zuiPairs`; they are solved and checked like
  the built-in ones. A part names one as `.extra(.brand)`, in an
  appearance made with `AppearanceWith(Part, ExtraRoles, …)`.

  ```zig
  const Roles = enum {
      brand, on_brand, chart_line,
      pub const zuiPairs = .{ .brand = .on_brand, .on_brand = .brand, .chart_line = .surface };
  };
  ```

- **`Space`** tiers are on a base unit of 4 (§18.5).

- **`TypeRole`** is the only way a design names a text style (§18.6).

- **`CornerSize`**, from `square` (no radius) to `bubble` (half the
  shorter side, a pill), is what a `ShapeRole` resolves to (§18.7).

- **`Design`** holds the seeds, the type scale's inputs and fonts, each
  shape role's size and the corner family, and the density table, a
  length per `Space` at each `Density`. It is plain data, so a theme
  pack imports only `zui`: its fonts are the integer values of the
  application's `FontId`, and its seeds are OKLCH as `zui.design.Oklch`.

- **`Tokens`** holds a color per role in each `WidgetState`'s layer of
  the resolved theme, a length per tier, a `TextStyle` per type role, a
  `CornerRadius` and `CornerShape` per shape role, the target floors,
  the outline and focus ring widths, the factor a part that draws text
  pads by, and the body text's measure; `tokens.space(.m)` reads a tier.
  Every field is empty until a resolver writes it.
  `tokens.look(Component, part, state)` answers a part's decoration,
  padding, gap, text style and minimum size in one `WidgetState`, and
  checks the component's appearance the first time it is read, so a
  component no tokens read costs nothing.

### 18.2 The appearance contract

```zig
const Chip = struct {
    pub const Part = enum { container, container_selected, label, close };

    pub const zuiAppearance = zui.design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container, .shape = .chip, .padding = .{ .x = .s, .y = .xs }, .gap = .xs },
        .container_selected = .{ .surface = .accent_container, .shape = .chip, .padding = .{ .x = .s, .y = .xs }, .gap = .xs, .cue = "a check mark before its label" },
        .label = .{ .text = .on_secondary_container, .type = .label, .on = .container },
        .close = .{ .icon = .on_secondary_container, .on = .container, .target = .touch },
    });

    pub const zuiDistinguish = .{
        .{ .container, .container_selected },
    };
};

const look = tokens.look(Chip, .container, ui.widgetState(id));
```

- **A part** gives roles, never values: a `surface`, a `text` or `icon`
  role, an `outline`, a `shape`, `padding` and `gap` in tiers, a `type`
  role and a `target`.
- **`.on`** names the part a text, an icon or an outline is drawn on, so
  every pair the component can draw is known at comptime and checked in
  every theme, contrast and color vision (§18.4). A part that draws text
  or an icon and names no `.on` is a compile error, and so is one drawn
  on a part with no surface; an outline with no `.on` is drawn on its
  own part's surface. A part draws text or an icon, not both.
- **States** come from the resolver's state layers: hovered, pressed,
  focused and disabled are derived from the part's roles, and the focus
  ring is the `focus` role, drawn as the outline of a part with a
  `target` while it is focused. A part may give a state its own colors
  with `.states = .{ .pressed = .{ ... } }`, read in that state's layer.
- **`zuiDistinguish`** lists the pairs of parts that must look
  different, as a checked and an unchecked box are parts of their own
  (§16.7); `.{ .part, .idle, .hovered }` pairs one part in two states.
  Under every color vision simulation, they must stay apart in
  lightness, or differ in a cue that is not color: `zui_widgets`'
  checkbox has its mark, a selected tab its indicator. A part names its
  cue as `.cue = "a check mark before its label"`, and a pair either of
  whose parts has one is not measured. The core does not resolve colors,
  so the pairs are checked against a design by
  `comptime zui_design.checkDistinguished(design, .{ Chip, … })`
  (§18.4).
- **A raw color** is `.unchecked(.rgb(0xff00ff), "the brand's logo")`.
  It compiles, it is drawn in every state as given, and the audit
  (§18.8) lists it with its reason, every time, from the appearance's
  `unchecked_colors`.

The messages, for a `Chip` declared in `demo.zig`:
`` "zui: demo.Chip's appearance has no part `container` of demo.Chip.Part" ``;
`` "zui: demo.Chip.label draws text but names no part it is drawn `.on`" ``
(`draws an icon` for an icon);
`` "zui: demo.Chip.label is drawn on `badge`, which is not a part of demo.Chip.Part" ``;
`` "zui: demo.Chip.label is drawn on `close`, which has no surface" ``;
`"zui: demo.Chip.close draws both text and an icon; give each a part of its own"`;
`` "zui: demo.Chip.close's `.unchecked` color needs a reason" ``;
`` "zui: demo.Chip declares no `Part`, the enum of its parts" ``;
`` "zui: demo.Chip declares no `zuiAppearance`" ``;
`"zui: demo.Chip.zuiAppearance must be a zui.design.Appearance(demo.Chip.Part, …)"`;
`"zui: an appearance's Part must be an enum, got demo.Chip.Part"`;
`"zui: demo.Badge's appearance names the extra roles demo.Roles, but the tokens' extra roles are void"`;
`"zui: each entry of demo.Chip.zuiDistinguish is two parts, or a part and two states"`;
`` "zui: demo.Chip.zuiDistinguish names `badge`, which is not a part of demo.Chip.Part" ``;
`` "zui: demo.Chip.zuiDistinguish names `normal`, which is not a zui.WidgetState" ``.
And from `zui_design.checkDistinguished`, for the `Chip` above without
its cue:
`` "zui_design: under demo.design, demo.Chip's container and container_selected are 0.01 apart in lightness under protanopia in light, need 0.15; give one a `.cue` that is not color" ``
(`demo.Chip.close's idle and hovered layers are` …
`` give it a `.cue`  `` for a part in two states). And for extra roles:
`"zui: ExtraRoles must be an enum or void, got u8"`;
`` "zui: demo.Roles's `accent` is already a zui.design.ColorRole" ``;
`` "zui: demo.Roles declares no `zuiPairs`, the role each of its roles pairs with" ``;
`` "zui: demo.Roles.zuiPairs gives no pair for `on_brand`" ``;
`` "zui: demo.Roles.zuiPairs pairs `brand` with `logo`, which is neither a zui.design.ColorRole nor a role of demo.Roles" ``;
`` "zui: demo.Roles.zuiPairs names `logo`, which is not a role of demo.Roles" ``.

### 18.3 Preferences and resolution

```zig
pub const Preferences = struct {
    theme: zui.Environment.Theme = .light,
    contrast: zui.Environment.Contrast = .normal,
    text_scale: f32 = 1,
    reduced_transparency: bool = false,
    accent: ?zui.Color = null,          // the user's, else the system's, as it is; else the design's seed
    density: Density = .comfortable,     // zui.design.Density: enum { compact, comfortable, roomy }
    color_vision: ColorVision = .typical, // enum { typical, protan, deutan, tritan, achromat }
    corners: CornerPreference = .as_designed, // enum { sharper, as_designed, rounder }: one `CornerSize` step
    pointer: Target = .pointer,          // `.touch` raises every target floor
};

const preferences: zui_design.Preferences = .from(ui.environment(), app.choices);
if (!std.meta.eql(preferences, app.preferences)) {
    app.preferences = preferences;
    _ = zui_design.resolve(app.design, preferences, &app.tokens);
}
```

- **What the OS reports comes from the environment** (§7.2), including
  `accent`. Density, color vision, the corner preference and the pointer
  are the user's choices in the application, which `choices` carries.
- **`resolve` is a free function,** since `Design` is the core's and a
  module cannot give it methods. It takes the tokens as a pointer to any
  `zui.design.Tokens(Ui, ExtraRoles)`.
- **`resolve` allocates nothing,** writes every token, and returns what
  it repaired (§18.4).
- **A design resolved at comptime,**
  `comptime zui_design.resolve(design, …)` for each theme and contrast,
  is checked during the build.

### 18.4 Color, contrast and color vision

- **From seeds.** `Design.seeds` gives an accent and a neutral in OKLCH,
  and optionally a hue for each status role. Each becomes a tonal ramp,
  and every role is taken from a ramp per theme. Dark is solved from the
  same ramps, not inverted: its raised surfaces are lighter, not
  shadowed, and its filled roles are darker than their light text, all
  but `warning`, a light amber under dark text in every theme, which
  leaves the three status fills room to differ in lightness. A chosen
  accent, the user's or the system's, is the accent fill as it is, its
  lightness included; the design's accent seed gives only its hue and
  chroma.

- **Contrast is solved, not only checked.** Each declared pair must meet
  both APCA's lightness contrast and WCAG 2's ratio:

  | Pair | Normal contrast | High contrast |
  |---|---|---|
  | body text, `label`, `caption`, `code` | Lc 75 and 4.5:1 | Lc 90 and 7:1 |
  | `title` and larger | Lc 60 and 3:1 | Lc 75 and 4.5:1 |
  | icons, outlines that show a state, the focus ring | Lc 45 and 3:1 | Lc 60 and 4.5:1 |
  | disabled | none: disabled text is not required to be read | |

  Both are measured on the color as it is encoded in sRGB, its alpha
  ignored. Each `on_*` role is text; `outline` and `focus` are the
  non-text tier; `outline_muted`, the surfaces and `scrim` have no
  target. The resolver moves the foreground's OKLCH lightness away from
  the background, keeping its hue and chroma, until both pass; if no
  lightness of it passes, it goes to white or black and the background
  moves too. The hovered, focused and pressed layers are held to the
  same targets: a fill whose pairs would fall below them moves less of
  the way toward its `on_*` role, or, when too little of the way would
  show, moves as far toward white or black instead.

- **A design that cannot meet a target at comptime is a compile error**
  naming the design by `Design.name`, the pair, the scheme and the
  lightness that would pass, as "zui_design: *design*'s *foreground* on
  *background* is Lc *measured* in *scheme*, needs *target*;
  *foreground* at L *lightness* passes". A pair that misses only WCAG
  2's ratio is named by its ratio and the ratio it needs. No seed of the
  built-in tables reaches it, since their status fills keep a margin at
  every hue; the status roles' separation, below, is the comptime error
  a design's own hues can reach. A design is named "the design" until it
  sets `name`.

- **A color that arrives at run time,** the user's accent or the
  system's, is repaired the same way, never fatally, even at comptime,
  and `resolve` returns each repair in `Repairs`: what was measured
  (contrast, color vision, or a pair that needs a cue that is not
  color), the pair, the scheme, its contrast or its nearest simulation
  before, and the lightness each side took, the first 32 kept and the
  rest counted as dropped.

- **Color vision.** Each color is simulated, as it is encoded in sRGB,
  under protanopia, deuteranopia, tritanopia and achromatopsia (Machado
  et al., 2009, at full severity, on linear sRGB; achromatopsia keeps
  the luminance alone), and two colors are apart when their OKLab
  lightness differs by at least 0.15 under each.

  - **The status fills,** `danger`, `warning` and `success`, are held
    apart in pairs by `resolve`, in the idle palette after contrast is
    solved. A pair that is not is moved apart: the fill whose move is
    the shorter goes away from the other in lightness, as far as its
    `on_*` role still meets its target, and the move is reported. A pair
    no such move parts is reported as needing a cue that is not color.
    At comptime either is a compile error unless the user chose the
    color vision, as for a design in `demo.zig` whose `success_hue` is
    red, resolved in high contrast:
    `"zui_design: demo.design's danger and success are 0.14 apart in lightness under protanopia in light high contrast, need 0.15; success at L 0.42 passes"`.
  - **`zuiDistinguish` pairs** are checked, not moved: their roles are
    shared by every component, so moving one for one pair would move it
    for all.
    `comptime zui_design.checkDistinguished(design, components)`
    resolves the design in every scheme and compares two parts'
    surfaces, text or icons, and outlines idle, and one part's in its
    two states; an entry passes when one of those colors is apart under
    every simulation, or when a part declares a `.cue`, and fails the
    build otherwise (§18.2).
  - **`Preferences.color_vision`** adapts the status roles further for
    the user who chose it: `protan` and `deutan` move `danger` to hue
    40° and `success` to 230°, apart on the blue-yellow axis that is
    left, and `warning` to 85°; `tritan` and `achromat` keep the hues,
    since red and green stay apart without blue and yellow and warning's
    light fill has too little chroma for its hue to show, and hold the
    status fills 0.20 apart instead. Images and custom drawing are not
    recolored.

### 18.5 Spacing and density

| `Space` | compact | comfortable | roomy |
|---|---|---|---|
| `none` | 0 | 0 | 0 |
| `hair` | 1 | 1 | 2 |
| `xs` | 2 | 4 | 6 |
| `s` | 4 | 8 | 10 |
| `m` | 8 | 12 | 16 |
| `l` | 12 | 16 | 24 |
| `xl` | 16 | 24 | 32 |
| `xxl` | 24 | 32 | 48 |

- **Density is not one factor.** The small tiers shrink most and the
  large ones least, so grouping survives a compact layout. A `Design`
  may give its own table.
- **Floors no density breaks:** a part with `target = .pointer` is at
  least 24 units on each side, with `.touch` (or
  `Preferences.pointer = .touch`) at least 44; the focus ring keeps its
  2 units.
- **Text scale reaches spacing by half:** a part that draws text pads by
  its tier × (1 + (text_scale − 1) / 2), so large text has room without
  the layout outgrowing the window.

### 18.6 Typography

- **Sizes from a scale.** `Design.type` gives a ratio (1.2 by default),
  the body size (15), and a font for regular, strong and monospace text.
  Each `TypeRole` is a step of the scale: `caption` −2, `label` −1,
  `body` 0, `title` 1, `headline` 2, `display` 4. `body_strong` is body
  in the strong font; `code` and `numeric` are body in monospace and
  tabular figures.
- **Set by the face.** Sizes are scaled so the body face's x-height
  (`zui_glyphs.FontMetrics.x_height`) is the design's, so two faces at
  the same role look the same size. `Design.type.x_height` is body
  text's x-height, 6 by default, Atkinson Hyperlegible's at 15. Each
  font whose face `Design.type.faces` gives, as
  `zui.design.FaceMetrics.of(text.fontMetrics(font).?)`, is sized to it;
  a font whose face is not given is set at the body size.
- **Line height** falls with size, from 1.5 at 14 and below to 1.15 at
  40 and above, and is rounded to the 4-unit grid.
- **Tracking** is +1% of the size at 12 and below, none at 16, and −2%
  at 32 and above, between them in proportion.
- **Text scale by role.** A role's size is multiplied by `text_scale` to
  a power of 1 from `caption` to `body`, falling in proportion to the
  step to 0.5 for `display`, so body text doubles at 200% and headings
  do not outgrow the screen.
- **Measure.** `Tokens.measure` is the width of 66 average characters of
  body text, for a column to cap its width at.

### 18.7 Shape

- **A family and a size.** `zui.CornerShape` is `round` (circular arcs),
  `continuous` (a superellipse, with no break in curvature where the
  corner meets the side) or `chamfer` (a 45° cut);
  `Decoration.corner_shape` sets it for an element's four corners.
  `Design.shapes` maps each `ShapeRole` to a `CornerSize`, and
  `Design.corner_shape` sets the family. `Preferences.corners` moves
  every role one size sharper or rounder.

  | `CornerSize` | radius |
  |---|---|
  | `square` | 0 |
  | `sharp` | 2 at `compact`, 4 otherwise |
  | `smooth` | 8 |
  | `soft` | 16 |
  | `bubble` | half the shorter side |

- **Emission clamps** each corner to half the element's shorter side, so
  `bubble` is any radius that large.

- **The families' curves.** Within a corner's radius along both sides,
  `round` is the quarter circle, `continuous` the quarter superellipse
  |x|⁴ + |y|⁴ = radius⁴, which meets each side with no curvature, as the
  side has none, and `chamfer` the straight cut between the two sides'
  points. A border's inner edge, or a shadow's spread, moves a chamfer's
  cut parallel to itself.

- **Renderers declare their shapes.** `Config.corner_shapes` is the set
  the renderer draws, its `zui_corner_shapes`, `round` alone by default
  and always with `round`. A command carries its shape, `corner_shape`,
  only when that set holds more than `round`; otherwise the field is
  `void`, and `zui.cornerShapeOf(payload)` reads either as a
  `CornerShape`. A shape a renderer does not draw is drawn round, and
  lowered (§13.3). Square corners, of radius 0, have no shape to draw,
  so they are never lowered.

- **Nested corners.** `Decoration.nested_corners = .{ .minimum = 2 }`
  (behind `Features.nested_corners`) gives each corner the radius that
  is concentric with its parent's, in place of its own `corner_radius`.
  The parent is the nearest ancestor with a decoration, so a row or
  column that only lays children out is passed over; an element with
  none sits in the window's square corners. Its inset is the child's
  distance from that corner of the parent, along the farther axis, as
  laid out, so a child that does not reach a corner does not follow it.
  By the child's family: `round` and `continuous` take the parent's
  drawn radius less the inset, and `chamfer` shortens its cut by (2 −
  √2) × the inset. Below `minimum` (0 by default), or past the parent's
  radius, a corner takes `minimum`. Emission resolves it, since only it
  knows both boxes; a parent that is nested itself resolves first. With
  the feature off the field holds nothing and `Decoration` keeps its
  size; declaring it is a compile error,
  `"zui: Decoration.nested_corners needs Config.features.nested_corners = true"`.
  A field's coercion can raise no custom error, so the message is the
  name of the field's type, which appears inside Zig's own error for the
  struct initialization. With the feature on, `Ui.Decoration` is the
  context's own type (§10.1), so a `zui.Decoration`, such as a look's,
  is copied into it field by field.

  ```zig
  const look = tokens.look(Card, .container, .idle).decoration;
  ui.open(.{ .id = .of("card"), .decoration = .{ .background = look.background, .border = look.border, .corner_radius = look.corner_radius, .corner_shape = look.corner_shape }, .layout = .{ .padding = .all(tokens.space(.m)) } });
  defer ui.close();
  ui.box(.{ .id = .of("thumbnail"), .decoration = .{ .background = thumbnail_color, .nested_corners = .{} } });
  ```

### 18.8 Seeing every permutation

**The axes** a component is seen under: theme, contrast, density, text
scale (1, 1.5, 2), color vision, reading direction, corner preference,
reduced transparency, each `WidgetState`, and its content.

- **Content.** A component may declare `zuiPreviews`, the content it
  shows under review: short, long, empty, overflowing, right to left,
  large numbers. Without it, it is shown with what it is declared with.

- **Levels.**

  | Level | What | About |
  |---|---|---|
  | `glance` | the defaults, and the extremes designed to break things together: dark, high contrast, 200%, compact, right to left | 5 per component |
  | `sweep` | one axis through its values, the rest at their defaults | 5 to 10 per axis |
  | `pairs` | a covering array: every pair of two axes' values in at least one permutation | 30 to 60 per component |
  | `full` | every combination, for the audit in CI | thousands |

- **The audit** (`zui_design.audit`) checks a finished frame's commands,
  not the declarations, so custom drawing and `.unchecked` colors are
  caught too: text against what is painted beneath it, the focus ring
  against its surroundings, hit target sizes, text cut short,
  overlapping controls, and each `zuiDistinguish` pair under every
  simulation. Each finding names its element, its check and the value.

- **Keys and hashes.** Each permutation has a `PermutationKey`: the
  component, its preview and every axis value. Its command hash is the
  same in Debug and release and on every target.

- **The review** (`apps/review/`) shows each permutation of a level with
  its axis values and its findings. **Y** accepts it, **N** flags it,
  **R** adds a remark, with a region dragged over the part it is about.
  Arrows step, `[` and `]` move between axes. Verdicts are kept in a ZON
  file in the application's repository, by key, each with its command
  hash. When the hash changes, the verdict is stale and the permutation
  is asked again, so an approved look is a golden for free.

- **The report**, in Markdown and as an HTML page with an image of each
  permutation, groups the flags and findings by component, then by the
  axis that brings them ("fails under deuteranopia in high contrast"),
  and names the token or part to change where it can be told.

- **In CI,** a build step fails on a permutation that is stale, flagged
  or failing the audit.

- **The workbench** is a mode of the review: one component in a grid of
  its glance permutations, restyled as its design file is saved, with a
  badge the moment a check fails.

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
| `KeyedLoads(Key, Result, .{ .capacity, .unread_frames_before_release, .owns_resources, .Progress })` | many keyed loads driven by demand: thumbnails, remote rows, search results per query | many | keys completed this frame, with status; relayed, also the keys loading, with progress, and abandoned loads that finished, which the loader changed between frames |

- **`Latest`** is a triple buffer and one atomic byte (middle index and
  a fresh bit). A publish exchanges the producer's back buffer with the
  middle one; a swap exchanges front and middle if fresh. The view reads
  the front buffer in place. Two publishes between swaps lose the first,
  so `Latest` holds plain data or handles the producer keeps alive.
- **`Stream`** is a bounded ring with a sequence per slot, its capacity
  a power of two. Many producers claim with a compare-and-swap on the
  head; one producer compiles to a plain store. A swap first releases
  the slots the previous frame read, then walks forward while slots are
  written, stopping without waiting at the first claimed but unwritten
  slot. Items are read in place, through an iterator, because they may
  wrap.
- **`Task`** is a `Latest` of its status plus run bookkeeping. The
  loader calls `begin(waker)` for a `Run`; the producer calls `progress`
  and exactly one `finish`. `begin` refuses while the previous run's
  final status is unswapped, which keeps it single-producer; restartable
  work is keyed. `CatalogTask.publishing(f)` adapts a plain function
  into one that finishes a `Run`, taking `f`'s arguments as one tuple.
  `clear` hands back an owned result once `frames_in_flight` frames have
  passed since it was last read. The loader can `abandon` a run, which
  the producer reads from `run.abandoned()`.
- **`KeyedLoads`** moves keys through *wanted* (`get` asked; `.idle`) →
  *loading* (the loader took it from `toStart`; `.running`) → *ready*
  (`.ready`/`.failed`) → *releasing* (unread too long; handed back by
  `toRelease`). `get` never starts work. Completions go through a ring
  sized by claims, so it can never overflow however rarely it is
  drained. A slot is reused only after its load's completion is swapped,
  so an abandoned load never completes the next one; safe builds keep a
  generation per load to catch one finished twice. An abandoned load
  still finishes, into `toRelease`. A value is never released before
  `max(unread_frames_before_release, frames_in_flight)` unread frames,
  computed rather than configured, so a texture is never freed under a
  frame in flight. `toRelease` exists only with `owns_resources`, and a
  forgotten release shows as a full source, not a leak. A key `get`
  cannot track for lack of space stays `.idle`, and the next frame
  reports the refusal. `Progress` must fit in a `usize`, checked at
  comptime, so a producer reports it with one atomic store on every
  target.
- **Costs:** a swap with nothing published is one atomic load; a publish
  is one copy and one atomic exchange; producer-side and reader-side
  atomics sit on separate cache lines; memory is fixed at comptime in
  the application's own struct.

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
that implements the skin contract
(`zuiStyle(part, state, environment) Style`, §16.7), so theme packs and
applications bring their own look without forking the widgets.
`widgets.style(ui, part, state)` asks the skin for an element that
should match a widget. The default skin, `zui_widgets.DesignSkin(Ui)`,
styles every control from `zui.design.Tokens` (§18), so the widgets
follow the theme, the contrast, the density, the text scale and the
color vision the tokens were resolved for.

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
- **`Driver(Ui)`**: runs complete frames from events, by element id,
  with points as fractions of the element's previous rectangle: `click`,
  `tap`, `drag`, `pinch`, multi-pointer drags, `typeText`, `pressKeys`,
  `action`, and
  `frameDelivering(.{ .catalog = .{ .ready = &catalog } })` to set any
  source's state without threads. A context with sources takes them as
  `.sources = &app.sources`; in `frameDelivering`, a source not named
  receives nothing, which is `null` for an optional `Delivery` and
  `Delivery.empty` otherwise.
- **`Recording(Ui)`** keeps each record a context applies, as its relay
  listener, in memory reserved by `init`; a record that does not fit is
  dropped whole and counted. **`driver.replay(app, declare, record)`**
  runs one frame from a recorded record, its deliveries injected and no
  loader between frames, so a recorded session replays to the same
  commands without starting any work.
- **`snapshot` / `expectSnapshot`**: one line per command, for named ids
  only, defaults omitted, identical in debug and release.
- **`checkCommands`**: finite bounds, nondecreasing layers, balanced
  clips and transforms, each ending inside what it began inside.
- **Conformance suites**, which every implementation runs in CI. Each
  takes a harness that does what only the implementation can: make a
  drawing target and read it back, make the OS report an event, or
  publish into a source.
  - `expectRendererConforms(Renderer, harness, .{ .gpa, .io })` draws a
    reference scene of every command the renderer's declarations can
    produce (the base commands, and `image`, tinted and rounded, and
    `custom` with their payload types), clips nested 100 deep, commands
    of no size or out of bounds, an empty frame, and the reference scene
    again. When the harness reads pixels back, it checks that each clip
    cuts off what lies outside it and is restored when a clip inside it
    ends, that nothing an earlier frame set outlives it, and the scene's
    colors within a tolerance, an image's tint multiplied into it and
    its corners left undrawn. An optional command joins the scene with
    the declaration that produces it (§13.3). The scene is declared in
    `ExtendedColor`, with a box of HDR white: a renderer that declares
    `zui_extended_color` is given each color as declared and must encode
    it for its target, and any other is given it clamped (§13.3). A
    harness that opens a `.scrgb_fp16` target reads it back as
    `ExtendedColor`, where HDR white must read back as declared,
    brighter than SDR white, and translucent colors blend in linear
    light.
  - `expectHostConforms(Host, harness, .{ .io })` checks that a poll
    keeps the application's zoom and reports posted events in order,
    that `.immediately` does not wait, that a wake before a wait ends it
    and is then cleared, that a wake from another thread ends an
    `.on_event` wait, and that an `.at` wait ends at its instant. Every
    wait it starts is bounded: a lost wake fails the suite, never hangs
    it. For a host with many windows it also opens a second window,
    checks that it has its own id, viewport and surface, that an event
    posted to either window is reported by that window alone, that
    closing it leaves the first polling, and that a window opened after
    it has a new id; that harness declares `postTo(window, event)`. It
    is the pulled host's suite. A pushed host's,
    `expectPushedHostConforms`, runs `zuiRun` with a `zui.Driver` of the
    suite's own, whose steps ask for the next turn `.immediately`, `.at`
    an instant and `.on_event`, with a wake from another thread, and
    checks that the host starts the driver once and before any step,
    schedules each step as the one before asked, never blocks in a poll,
    calls `suspendSurfaces` and `resumeSurfaces` when its harness's
    platform takes the surface away and gives it back, stops the driver,
    and steps no more once a step has ended the run; that harness
    declares `takeSurfaceAway`, `giveSurfaceBack` and `quit`, which the
    suite calls from another thread for a platform that stopped
    stepping. A stepped host's, `expectSteppedHostConforms`, checks that
    a poll never blocks, with nothing to report or after a wake from
    another thread, that the surface is one the host declares, and that
    posted events arrive in order. Each is a compile error for a host of
    another loop half.
  - `expectSourceConforms(Source, harness, .{ .io })` stresses publish,
    swap, inject and refusal under many producers, on any `Io`, with a
    harness that publishes, since publishing is not part of the
    contract.

### 19.5 `zui_app`

The composition root as a library: `contextConfig(Renderer, overrides)`,
and `run(App, init, options)`, which runs the loop of §6.1 as the host's
loop half says, calls the application's `zuiDeclare` and optional
`zuiObserve` and `zuiLoader`, moves submission to a render thread when
the renderer allows, applies host requests, paces to `nextFrame`, and
reports capabilities and fallbacks. An application that owns its loop
steps a `Session(App)` from it; one that wants nothing of `zui_app`
writes the lines of §6.1 instead.

```zig
try zui_app.run(App, init, options);                 // zui or the platform owns the loop

var session: zui_app.Session(App) = undefined;       // the application owns it
try session.start(.{ .gpa = gpa, .io = io }, options);
defer session.stop();
while (editor.running()) {
    if (try session.step()) |next| editor.redrawAt(next) else break;
}
```

```zig
const App = struct {
    pub const Host = zui_raylib.Host;
    pub const Renderer = zui_raylib.Renderer;
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .Sources = AppSources }));

    sources: AppSources = .{},

    pub fn init(app: *App, start: zui_app.Start(App)) !void { ... }   // optional; else every field has a default
    pub fn zuiRecord(app: *App, record: *zui.RecordBuilder) void { ... } // optional
    pub fn zuiDeclare(app: *App, ui: *Ui) void { ... }
    pub fn zuiObserve(app: *App, ui: *const Ui, frame: *const Ui.Frame) void { ... } // optional
    pub fn zuiLoader(app: *App, ui: *const Ui, io: std.Io) void { ... } // optional
    pub fn deinit(app: *App) void { ... }                              // optional
};
```

- **What it builds.** `contextConfig` takes the renderer's commands and
  payload types, and the renderer itself as `Text` when it declares
  `zuiMeasure`, so `zui_app` hands the context the renderer to measure
  with. `Ui` is read from `zuiDeclare`'s parameter.

- **A text contract of its own.** When the renderer does not measure,
  the application builds its `Config` with `.Text = Fonts` and declares
  `pub const Text = Fonts`: `zui_app` makes one (with `init(self) !void`
  and `deinit` if it declares them) and gives the context and the
  renderer a pointer to it. A `Ui` whose `Text` is neither the renderer
  nor `App.Text` is a compile error.

- **What it opens.** A pulled or stepped host declares
  `init(self, io, window: zui.WindowOptions) !void` (title, size,
  visible, resizable, material, title bar; `Options.title_bar = .custom`
  without `features.chrome_regions` makes `start`, or `run`, return
  `error.CustomTitleBarWithoutChromeRegions`) and `deinit`; a pushed
  host is given the same options by `zuiRun`. The renderer may declare
  `init(self, surface) !void`, or
  `init(self, surface, text: *const Text) !void` beside `App.Text`, and
  `deinit`. Each field with a default holds it when `init` is called, so
  a setting made on the type survives. `Start(App)` gives the
  application the allocator, the `Io`, the process, its host, its
  renderer, the `App.Text` it made (`void` without one), for the fonts
  the application adds and the ids they are given, and the host's
  `Waker`.

- **The application's part of the record.** `zuiRecord` runs after the
  host's poll and before `beginFrame`: the application sets its zoom
  there and appends events it makes itself, after the host's. Its
  `sources` field holds the `Config`'s `Sources` or points to them, so
  an application that wraps another can use the sources it already has.

- **The application's view of the frame.** `zuiObserve` runs on the UI
  thread with each frame `endFrame` returns, before it is submitted or
  handed to the render thread, so an inspector (§19.7) reads the frame
  before the next `beginFrame`; `zuiLoader` sees only the context.

- **The render thread.** With `zui_render_thread` and more than one
  frame in flight, frames go through a queue of `frames_in_flight`
  entries to a task on the application's `Io` that submits and releases
  them; the UI thread applies host requests before handing a frame over.
  An error there is returned by a later `step()`.

- **What it reports,** once each, through `Options.notify` (by default
  `std.log`): at start, the host, its capabilities, where frames are
  submitted and why, the optional commands lowered and the services the
  host lacks; then the first time input is dropped by the record
  builder, each limit is exceeded, a source refuses, ids repeat or the
  tree is unbalanced.

- **The host's services** are reached through `ServicesOf(App.Host)`,
  with the host `init` was given (`start.host`), from `zuiLoader` or
  other code outside declaration (§16.3).

- **Many windows.** An application whose `zuiDeclare` takes a
  `zui.WindowId` declares each of its windows, and every hook takes the
  window too:

  ```zig
  pub fn zuiDeclare(app: *App, ui: *Ui, window: zui.WindowId) void { ... }
  pub fn zuiSources(app: *App, window: zui.WindowId) *AppSources { ... }      // with Sources, in place of the field
  pub fn zuiRecord(app: *App, window: zui.WindowId, record: *zui.RecordBuilder) void { ... }
  pub fn zuiObserve(app: *App, ui: *const Ui, window: zui.WindowId, frame: *const Ui.Frame) void { ... }
  pub fn zuiLoader(app: *App, ui: *const Ui, window: zui.WindowId, io: std.Io) void { ... }
  pub fn zuiWindowClosed(app: *App, window: zui.WindowId) void { ... }       // after its context is freed
  ```

  Each window has a context of its own, and a source has one reader
  (§14.8), so each window's sources are its own: data shared between
  windows is published into each. `Start(App).windows`, a
  `zui_app.Windows(App)`, opens a window and its context and closes one,
  between frames: opening one during `zuiDeclare` panics. At most
  `zui_app.max_windows` are open. Each turn polls every window, runs
  `zuiRecord`, and declares only those with an event, a new viewport,
  scale, zoom or output format, a `nextFrame` that is due, or no frame
  yet; when a source lacks `zuiPending`, every window is due on every
  turn. It then waits once for the earliest `nextFrame` of all. A window
  the user closes is closed; `run` returns once none is open. Frames,
  attaches and detaches share the render thread's queue, so a closed
  window's frames are released before its context is freed.

- **Who turns the loop** follows the host's loop half (§16.3),
  `zui_app.loopOf(Host)`: `.pulled`, `.pushed` or `.stepped`. `run` on a
  pulled host starts a `Session`, then
  `while (try session.step()) |next| session.wait(next)`, then stops it.
  On a pushed host it hands `zuiRun` a `zui.Driver` over a `Session` and
  returns as `zuiRun` does: when `zuiRun` is `noreturn`, `run`'s type is
  `zui_app.PushedStartError!noreturn`, and nothing after it runs, not
  even a `defer`; Zig does not reject code there, so the caller keeps
  none, and teardown is the application's `deinit`, which
  `driver.stop()` runs. After `zuiRun` returns, `run` stops the driver
  if the host did not. On a stepped host `run` is a compile error:
  `` "zui_app: demo.Host declares neither `zuiWait` nor `zuiRun`, so only the application's own loop can turn it: step a zui_app.Session(demo.App) from that loop" ``.
  `runWith(App, setup, options)` is `run` without a process.

- **`Session(App)`** is one run's state, turned by any loop. It must not
  move after `start`. `start(setup, options)` opens the host's window
  and makes the text, the renderer, the contexts and the application; on
  a pushed host it is a compile error naming `run`. `step()` is one
  turn, and never blocks: it polls each window, runs `zuiRecord`, and
  declares, ends and submits each window that is due, by the rule of
  *Many windows* below, for one window as for many; it returns when the
  next turn is wanted, or null once every window has closed. An
  application with one window is also due on the turn after `wait`,
  since a wait may end for a repaint its record does not show. Unless
  the host is waited on, a window whose frames the render thread holds
  every one of is not polled, so its input stays with the host, and the
  turn returns `.immediately`. `wait(next)` blocks in the host's
  `zuiWait`, and `frame()` is `step` then `wait`; on a host without
  `zuiWait` both are compile errors:
  `` "zui_app: demo.Host declares no `zuiWait`, so zui_app cannot wait on it; the loop that calls step waits as the zui.NextFrame it returns says" ``.
  `stop()` frees what `start` made, the application first, and closes
  the window. Each mistake in `App` is a compile error naming it:
  `` "zui_app: demo.App declares unknown `zuiLoder`" ``.

- **Surface loss.** `suspendSurfaces()` (`Driver.suspendSurfaces`) is
  called when the platform takes the windows' surfaces away, as Android
  does on pause or a GPU on a lost device: each window's surface is
  detached from the renderer after the frames the render thread holds
  for it, and turns declare nothing and return `.on_event` until
  `resumeSurfaces()`, which attaches each surface as `zuiSurface` now
  names it and makes every window due. On an error the surfaces stay
  suspended, and those attached are detached again. The contexts, their
  state, the application and its sources live on.

### 19.6 `zui_wire`

A versioned, little-endian encoding of both sides of the frame boundary:
records in, frames out, as deltas from the previous frame.

```zig
pub fn writeHeader(writer: *std.Io.Writer, fingerprint: ?u64) !void   // fingerprintOf(&fonts)
pub fn readHeader(reader: *std.Io.Reader, fingerprint: ?u64) !void    // error.FontsDiffer, UnsupportedVersion
pub fn Encoder(comptime Ui: type) type    // writeRecord(writer, record), writeFrame(writer, frame), writeKeyFrame
pub fn Decoder(comptime Ui: type) type    // init(gpa, .of(Ui)); next(reader): .record or .frame, null at the end
```

- **A record** is its parameters as changes from the last record's (a
  mask, the time since, the fields that changed), its events, and its
  deliveries when it has them, so a decoded record replays.
- **A frame** is what a renderer and a host take: its number,
  parameters, host requests and commands. Hit regions and semantics stay
  with the context that made them. Commands are written against the last
  frame's: runs kept, skipped, inserted, or changed in the fields that
  differ, so a frame that did not change costs a few bytes.
  `writeKeyFrame` writes one whole, for a reader joining the stream.
- **Payloads** (`ImageHandle`, `CustomData`, `MaterialHandle`,
  deliveries) serialize automatically when they are plain data, and
  otherwise must declare `zuiSerialize` and `zuiDeserialize`, checked at
  comptime:
  `` "zui_wire: delivery of source `catalog` holds a pointer (*const Catalog); declare zuiSerialize on it to send it" ``.
  `zuiSerialize(self, serializer)` writes with
  `serializer.write(value)`, and `zuiDeserialize(deserializer)` reads
  with `deserializer.read(T)`; both take the wire's own type as
  `anytype`, so a source that is not sent never imports `zui_wire`.
- **The fonts.** A stream's header carries the text contract's
  fingerprint, and a renderer whose fonts differ rejects it rather than
  drawing overflowing text. When either side has no `zuiFingerprint`,
  nothing is checked.
- **Limits.** Encoding allocates only in `init`; the decoder reserves
  what `Capacity` says (by default what the context's limits allow) and
  fails a message that does not fit with `error.CapacityExceeded`, since
  a delta cannot be applied in part. A message cut short fails with
  `error.EndOfStream` and leaves the decoder as it was, so a reader
  given the stream in pieces, as a browser is, reads it again when the
  rest arrives.

A wire renderer and a wire host make a remote client nothing more than a
host plus a renderer:

```zig
// Where the application runs: its host and renderer are the wire's.
pub const Host = zui_wire.Host(Ui);         // records from the client; gives a .wire surface
pub const Renderer = zui_wire.Renderer(Ui); // frames to the client, as changes
try start.host.attach(start.gpa, try server.accept(io));   // in the application's init

// Where it draws: any host and renderer, joined to it by a client.
var client: zui_wire.Client(Ui) = undefined;
try client.init(gpa, io, try address.connect(io, .{ .mode = .stream }), .{ .waker = host.zuiWaker(), .fingerprint = zui_wire.fingerprintOf(&fonts) });
while (try client.frame(&host, &renderer)) {}
```

- **The wire host** reads each record on a task of the `Io`, and a poll
  gives everything that arrived since the last one: the newest viewport
  and scale, and every event in order. Time is the client's: between
  records the host counts on from the last record's `now`, so an `.at`
  wait and a record made after a wake keep the clock the client's events
  carry. The connection ending is the window closing: the next poll
  returns false. Host requests go back with the frame, for the client's
  host to apply. It declares no services, so an application behind it
  finds every `has_*` false and falls back as on a host without them.
- **The wire renderer** writes each frame as changes from the last,
  after a header with the application's fonts' fingerprint, and declares
  the commands, colors and payload types `Ui` generates, so `zui_app`
  reports what the client's renderer lowers and `zui_app.contextConfig`
  of it gives back `Ui`'s images, custom payloads, materials and fonts.
  It may submit on a render thread.
- **The client** polls its own host, sends a record when it holds events
  or the viewport or scale changed (not for time passing alone), and
  presents the newest frame that arrived with its own renderer, applying
  its host requests; frames that arrive faster are skipped. Frames are
  read on a task of the `Io`, which wakes the client's host. Closing the
  client closes the application's window: it stops sending, and reads
  until the application has closed its end, so no frame is written into
  a closed connection.

### 19.7 `zui_debug`

An inspector over `Frame.inspect`: the element tree, the hovered element
and its configs, the frame's diagnostics, lowerings and fallbacks in
effect, and a performance overlay from the tracer. Over the wire it runs
in another process. An application on `zui_app` hands it each frame from
`zuiObserve`.

### 19.8 `zui_color`, `zui_icons`

OKLab, OKLCH and HSL conversion, mixing and palettes, all usable at
comptime; icon names to codepoints in an icon font, drawn as text.

### 19.9 `zui_motion`

Tweens and springs over `state(id, T)` and `dt()`, which ask for the
next frame while they move, for a frame at the instant a delayed one
starts, and for none at rest, and finish instantly under
`reduced_motion`. Exit animations use the core's ghost buffer: an
element with an `exit` keeps emitting its last commands for
`exit.seconds` after it is last declared, taking no space and receiving
no hits, from `limits.exit_ghost_commands` (0 compiles it out). The
commands are those its subtree emitted in that frame, inside the clip
and transforms around it, drawn at the end of their layers, a newer
ghost over an older one; they do not follow a container that scrolls
afterwards. A fade multiplies the alpha of every color they draw by an
opacity from 1 to 0, linear or cubic as `zui_motion`'s easings; `.none`
holds them unchanged and asks only for a frame at the instant it ends,
and a fade asks for the next frame while it lasts. The fade is chosen
once per ghost per frame, so `.none` runs no alpha code and `.linear` no
easing, and no set of fades is declared. An element inside another that
leaves with it is drawn only in the outer one's ghost. A ghost is
dropped when its element is declared again, and every ghost at once
under `reduced_motion`. A ghost whose commands or text do not fit is not
kept, and reported as `exit_ghost_commands`.

### 19.10 `zui_tracy`

`zui_tracy.Tracer` traces into the Tracy profiler, and
`zui_tracy.frameMark()` ends a frame in its frame graph. Tracy is a lazy
dependency, fetched and linked only by a build with `-Dzui-tracy=true`.
Without it, `Tracer` is `void`, so an application keeps
`.features = .{ .Tracer = zui_tracy.Tracer }` in its `Config` and pays
nothing until it builds with Tracy.

### 19.11 `zui_design`

The default maker of `zui.design.Tokens` (§18): `Preferences.from` the
environment and the user's choices, and
`resolve(design, preferences, *Tokens)`, which makes palettes from
seeds, solves every declared pair's contrast and color vision, applies
the density and the type scale, and returns what it repaired, without
allocating, and `checkDistinguished(design, components)`, which checks
each component's `zuiDistinguish` pairs against a design at comptime. It
also holds the audit of a finished frame (`audit`), the axes and levels
of a component's permutations (`Permutations`, `PermutationKey`), and
the verdict file and report the review writes (§18.8).
`zui_design.default` is zui's own design, on the bundled fonts.

---

## 20. Verification and budgets

### 20.1 Tests

- **Invariants**, on every test frame: children in the flow start inside
  their parent's content box, on each axis that does not scroll; grow
  siblings proportional to weight except where clamped; overflow only
  once every shrinkable child is at its minimum, and free space only
  once every growing child is at its max; no negative or NaN size; child
  lists that agree with the parent links and counts; commands in
  nondecreasing layer order, with clips balanced in each layer. These
  read only a `Frame`: `frame.sweep()` returns the first one broken, as
  a `SweepFailure` naming the invariant and the element or command, and
  with `features.safety_sweeps` `endFrame` runs it in any build and
  panics on a failure, naming the frame. Tests turn it on, so every test
  frame is swept.
- **Randomized trees** of 1–5,000 elements from a seed, through the
  invariants.
- **Golden layouts** with exact rectangles for every sizing rule, basis,
  aspect ratio, alignment, direction, wrap mode and floating option.
- **Allocation discipline:** every test runs with a failing allocator
  after `init`.
- **Compile-error tests** for every message in this document.
- **Sources under ThreadSanitizer,** with many producers against a
  reader that swaps at random intervals, and on a single-threaded `Io`
  where every producer runs inline.
- **Replay:** a recorded session replays to identical commands without
  starting any work.

### 20.2 Budgets

On one 2020-era desktop core at its base clock (the reference is an
i9-10900K at 3.7 GHz, Turbo Boost off and the `performance` governor,
the mode `bench-compare` measures in), so that a budget is judged on the
same clock as every comparison:

| Scenario | Budget |
|---|---|
| 4,096 boxes, depth 8: layout and emission | < 125 µs |
| 4,096 boxes, depth 8: declaration | < 69 µs |
| 1,000 texts of ~40 bytes, warm caches: layout and emission | < 150 µs |
| 133 pointer moves in one frame | one hover hit test per pointer |
| a frame with 10 idle sources | no more instructions than with none |
| an idle application | 0% CPU |
| allocations after `init` | 0 |

### 20.3 Measuring

- **`zig build bench`**, always ReleaseFast: the budget scenarios, deep
  and wide trees, a realistic document view, cold text on one thread and
  in parallel, a render thread against one thread, a renderer reading a
  frame of 1,000 labels' commands, timed as a phase of its own, and
  startup (`init`, `initBuffer`, first frames). It fails on any
  allocation after `init`, and reports each phase's fastest, median and
  95th-percentile frame, warning when a phase's frames fall into two
  clusters. `--core <n>` pins it to one core at a raised priority;
  `--machine-json <path>` records the machine's state; `--capabilities`
  lists the options it supports. `--list-scenarios` lists the scenarios,
  `--scenario <name>` (repeated) runs only those, and `--order-seed <n>`
  shuffles their order; startup scenarios always run last, since their
  page faults are part of what they time. `--counters` also counts each
  phase's cycles, instructions, branch misses, L1D read misses and
  last-level misses through Linux's `perf_event_open`, user mode only,
  keeping each event's fewest per frame, and refuses counts the kernel
  had to multiplex. The `ZUI_BENCH_LAYOUT_SEED` environment variable
  moves the stack by up to 4 KiB and each `Context`'s memory within 4
  KiB; the `-Dbench-layout-seed` build option moves every function by up
  to 4080 bytes. `--results-dir <dir>` writes the times with the machine
  they came from (OS and version, CPU, cores, caches, the target built
  for, the power settings and the commit) to
  `<dir>/<machine fingerprint>/<commit>.json`.
- **`zig build bench-report -- <dir> [<commit>]`** sets one commit's
  results from each machine side by side, each divided by that machine's
  box tree in the same phase, and names the scenarios whose relative
  cost differs most between machines.
- **`zig build bench-compare -- <base> [<head>]`** alternates two
  commits on one machine, pinned to one core after both are built,
  recording the machine's state before every run. It reports the median
  of the paired head/base ratios with a bootstrap 95% confidence
  interval (a fixed seed, 10,000 resamples), and calls a change only
  when the whole interval lies beyond that time's noise band.
  `--calibrate` measures the bands by comparing a commit with itself,
  and saves them for the machine's setup; without them, each band is 2%.
  Rounds continue until every interval is narrower than its target
  (`--target-width`, 1%, or the band if wider) or the time budget
  (`--time-budget`, 420 s) is spent; `--rounds` fixes their number.
  `--require-quiet` refuses to run while turbo is on. When both sides
  can, each round runs one scenario at a time, from each side's
  installed benchmark, in a new random order, alternating which side
  goes first from one scenario to the next; otherwise each round runs
  every scenario at once. The rounds take turns with `--layouts` layouts
  (3), fresh for each comparison: each a seed for the stack, the
  `Context` memory and, with each side built once per layout and in
  parallel, the code, plus on Linux a random length of padding in the
  environment. The interval resamples layouts and then the rounds within
  them, so a change that only moves code is not called.
  `--metric cycles` or `instructions` compares hardware counts instead
  of times.
- **`zig build counts`**, instruction counts under Callgrind for the
  single-threaded scenarios, from an executable always built for one CPU
  model without libc, over a fixed number of frames, so they are the
  same on every machine. CI fails on more than 2% growth over the parent
  commit. Beside each count, Callgrind's simulated I1, D1 and last-level
  cache misses and branch mispredictions, under a fixed cache geometry;
  they show the direction of a memory change and never fail the check.
  Wall-clock times on shared runners are reported, never compared.
- **Every feature that claims a speedup ships with its measurement,**
  and a feature whose win is not measured does not ship.

---

## 21. Build order

The order follows the dependencies of the design, not a calendar.

| Stage | Delivers | Done when |
|---|---|---|
| 1. Measure | instruction counts in CI, with simulated cache and branch misses; the tracer contract; comparisons of two commits pinned, one scenario at a time in a shuffled order, over several code and memory layouts, judged by confidence intervals against a calibrated noise band; hardware counters; results that record their machine | counts repeat exactly between runners; an off tracer leaves them unchanged; a commit compared with itself calls nothing, and a change that only moves code is not called |
| 2. The frame record *(the breaking change, made once)* | `Context(config)` with the text contract; `FrameRecord` with `now`, scale and zoom; input as events with the pointer table; the environment; `endFrame` that always returns a frame; `NextFrame`; sources in the core, `Status`, `Waker`; `zui_async`; `MeasureKey` with letter spacing; `TaskPool` deleted | the interaction, widget and testing suites pass on events; a click inside one frame is kept; the demo's thumbnail grid runs on `KeyedLoads` with no UI-thread wait and idles at 0% CPU; 100 loads between two frames cause one wake |
| 3. Contracts | renderer, host, surface; the generated command union and lowering; `zui_app`; conformance suites; the raylib adapter | every backend passes its suite and runs the demo through `zui_app` |
| 4. A native host | Windows, with the system material, per-monitor scale, lifecycle, clipboard and drop | the demo runs unchanged, passes the host suite, and idles at 0% CPU |
| 5. The wire | relay, replay, `zui_wire`, wire host and renderer, file watching as a source | a session replays to identical commands; the demo draws in another process |
| 6. Text and layout | string cache and fast path, segmentation, grow basis, aspect ratio, natural sizes, floating options, right-to-left, wrap, static styles | goldens for each; warm text within its budget; no other budget regresses |
| 7. Gestures | intents, gesture arbitration, momentum, custom recognizers, drag and drop | the nested-gesture scenes: a carousel in a list, a pinch starting on a list inside a map, a lasso module against a map's pan |
| 8. Effects | optional commands, lowering, transforms with hit inversion, materials, `ExtendedColor` | lowering tested for each; one renderer draws each; HDR white brighter than SDR on the Windows host |
| 9. Seeing the UI | `zui_debug`, semantics with accessibility actions, safety sweeps, the demo in a browser | the Windows host bridges semantics to UI Automation |
| 10. Reach | Linux and web hosts; services; window decorations; many windows | each host passes its suite and runs the demo unchanged |
| 11. Polish | `zui_motion` and exit ghosts; the design system: its vocabulary and appearance contract, `zui_design`, the type scale, corner shapes and nested corners, the system's accent, the default design, the audit, permutations and the review; full text editing with IME; `zui_color`, `zui_icons`, skins and theme packs; samples and the template | each with `zui_testing` coverage; every widget meets §18.4 in every theme, contrast and density; IME on Windows |
| Later | docking, a grid layout, layout islands, static subtrees, SIMD | only with a measured win or a demonstrated need |
| Set aside | the macOS host, and macOS's counters, skin and IME; the contracts keep their macOS shapes (the `cocoa` surface, vibrancy) | not built until macOS is taken up |

Two rules hold throughout:

- **One breaking release.** Everything that changes the shape of the
  record, the context's parameters or the contracts lands in stage 2 and
  3, before any host or wire format freezes it.
- **A module before core.** A feature that can be built on the public
  API is; the core gains only what a module proves it cannot do without.

---

## 22. Open questions

1. **Physical keys.** Planned: logical keys plus the opaque scancode; a
   physical key enum only when a binding needs portable physical keys.

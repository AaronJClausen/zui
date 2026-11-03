# zui: technical specification

zui is an immediate-mode UI **layout** library for Zig 0.16, in the spirit
of Clay. Each frame, the application declares its UI as nested function
calls. zui computes a flexbox-style layout and returns a flat list of render
commands, which the application's own renderer draws. zui owns layout,
interaction state and the frame's memory. It does not own windows, GPUs,
fonts or threads.

This document is the design contract. It states what zui does, the data
structures and algorithms it uses, the guarantees it makes, and what it
deliberately leaves out. Where a number is a **target** rather than a
measurement, it says so. Where a feature is committed to but not yet
built, it is marked *Planned for 0.x*, and [ROADMAP.md](ROADMAP.md) has
its plan. [ARCHITECTURE.md](ARCHITECTURE.md) covers what surrounds the
core: hosts, renderers, modules, and the contracts that connect them.

---

## 1. Design principles

1. **Layout, not rendering.** zui produces render commands. Drawing them
   is the application's job, so zui works with any renderer: raylib,
   sokol, Vulkan, a terminal, a test recorder.
2. **No allocation per frame.** All memory is reserved at initialization.
   A frame touches only memory it already owns, and the cost of a frame is
   proportional to the number of elements declared.
3. **Linear time.** Every layout pass is O(n) in elements, and text
   wrapping is O(n) in characters. No pass revisits a subtree an unbounded
   number of times.
4. **Plain data in, plain data out.** Configuration is structs with
   defaults. Output is a slice of tagged unions. There are no callbacks in
   the hot path, no inheritance, and no style cascade.
5. **Comptime where it changes the generated code, and nowhere else.**
   Comptime decides IDs, limits, the platform, user payload types and
   compiled-out debug features. The layout engine itself is an ordinary
   loop over arrays, because specialization multiplies code size (5–12×
   measured in the comptime lesson's antipatterns B1 and B2).
6. **Explicit threading.** One thread declares a frame. Finished frames
   are immutable, so they can move to a render thread. Background work
   reports back through a queue that the UI drains. There is no hidden
   locking.
7. **A small core, with extensions beside it.** Widgets, reflection-driven
   inspectors and backends are separate modules that use only the public
   API. Anything they can do, application code can do too.
8. **One frame boundary.** Everything from outside a frame (time, host
   events, input, task completions, feed deliveries) is applied at
   `beginFrame`, and everything leaving it is produced by `endFrame`.
   Declaration never sees data change under it, and a frame's inputs can
   be relayed, replayed or sent elsewhere (ARCHITECTURE.md §2). *Planned
   for 0.6:* task completions are still drained at each `request` (§10.3).

### Non-goals

These are out of scope for the core, permanently or until a later
version. Each has a reason:

| Not in core | Why | Where it goes instead |
|---|---|---|
| Rendering, windowing, input polling, OS services | they are platform-specific, and owning them would tie zui to one stack | renderers and hosts, separate packages that implement contracts defined in the core (ARCHITECTURE.md) |
| Font rasterization, shaping | they are large, and the platform already has them | the `Platform.measureText` hook (§8), supplied by the renderer |
| A retained widget tree | immediate mode is the model; state lives in a small keyed table (§9) | — |
| CSS-style cascading styles | cascades cost time per element and hide where values come from | themes as plain structs (§12) |
| Animation system | easing policies vary by application | `dt`, plus per-id state slots (§9) |
| Flex wrap (`flex-wrap`) in v1 | it adds a pass and complicates shrinking | *planned for 0.10*, as an opt-in pass (ROADMAP.md L7) |
| Accessibility tree generation | it is platform-specific | the optional `semantics` config, emitted as a separate list (§7.6) |

---

## 2. Glossary

| Term | Meaning |
|---|---|
| **Context** | the object that owns all of zui's memory. One per independent UI surface (window, offscreen panel). |
| **Frame** | one declaration pass plus layout. Produces a `Frame` result: commands, hit regions, and the task and semantics lists. |
| **Element** | a node declared with `open`/`close`, or a leaf such as `text`. |
| **Id** | a 64-bit hash naming an element across frames. Required for anything interactive or stateful. |
| **Platform** | a comptime type parameter that supplies text measurement and, optionally, wakeups. |
| **State slot** | a small piece of per-id memory that survives across frames (scroll offset, focus, a task handle). |

---

## 3. Package layout

```
zui/                     the core module "zui"
  src/root.zig           public API: Context, Id, config types, Frame
  src/layout.zig         the layout passes
  src/text.zig           word splitting, wrapping, the measurement cache
  src/interaction.zig    hit testing, hover/press/focus, scrolling
  src/state.zig          the keyed state table
  src/tasks.zig          TaskPool and its slots
  src/commands.zig       the RenderCommand union
  src/emission.zig       render commands, clip and hit regions
zui_widgets/             optional module: button, checkbox, slider, text field, dropdown, disclosure
zui_reflect/             optional module: struct inspectors generated with @typeInfo
zui_testing/             optional module: test platform, input driver, snapshots, command checks
zui_app/                 optional module: Platform from a host and a renderer, and the standard loop (planned for 0.7)
zui_wire/                optional module: the wire format for frame records and commands (planned for 0.9)
zui_debug/               optional module: the element inspector (planned for 0.12)
zui_motion/              optional module: tweens and exit animations (planned for 0.14)
zui_color/               optional module: HSL, OKLCH and OKLab, mixing, palettes (planned)
zui_icons/               optional module: icon names to icon-font codepoints (planned)
```

Each optional module's root file is named after it
(`zui_widgets/zui_widgets.zig`), because Zig names types after their file
and users read those names in compile errors. A module can only import
files inside its own directory, so the optional modules can reach zui
only through `@import("zui")`: **the compiler, not a review, keeps them
on the public API.** `zui_reflect` also imports `zui_widgets`.

Backends (`zui-raylib`, `zui-sokol`, `zui-terminal`) are separate packages
that depend on `zui`. They are never dependencies of it. *Planned for
0.7:* they become renderers and hosts implementing contracts defined in
this repo, and native hosts live in one `zui-host` repo, one directory per
OS (ARCHITECTURE.md §1, §8).

Build options, exposed as a `zui_options` module through `b.addOptions`:

| Option | Default | Effect |
|---|---|---|
| `-Dzui-debug=bool` | `false` | keeps each id's name, so panics and diagnostics name elements instead of printing hashes (§13). Otherwise those code paths are not analyzed at all. |
| `-Dzui-safety=bool` | follows `std.debug.runtime_safety` | the invariant sweeps in §14. *Planned for 0.12.* |

---

## 4. The Context

### 4.1 Type and configuration

```zig
pub const Config = struct {
    /// Maximum elements declared in one frame.
    max_elements: u32 = 4096,
    /// Bytes of text one frame may reference (copied into the frame arena).
    max_text_bytes: u32 = 64 * 1024,
    /// Maximum nesting depth of open elements.
    max_depth: u16 = 64,
    /// Render commands one frame may emit. Each wrapped line of text is one.
    max_render_commands: u32 = 8192,
    /// Persistent per-id state slots (§9). Must be a power of two.
    state_slots: u32 = 1024,
    /// Frames a state slot survives without being touched (§9).
    state_ttl_frames: u8 = 2,
    /// Text measurement cache entries (§8.3). Must be a power of two.
    measure_cache_entries: u32 = 4096,
    /// Number of frames that can be alive at once (§10.2). 2 = double buffering.
    frames_in_flight: u8 = 2,
    /// With a thread-safe platform (§10.5): after this many inline
    /// measurements in one frame, the frame's remaining misses are measured
    /// in parallel.
    parallel_measure_threshold: u32 = 256,
    /// The most distinct misses one frame measures in parallel.
    parallel_measure_capacity: u32 = 4096,
    /// Payload type of `.custom` elements and render commands.
    CustomData: type = void,
    /// Payload type of `.image` elements, e.g. a texture handle.
    ImageHandle: type = u64,
    /// Font identifier type passed back to the platform.
    FontId: type = u16,
};

pub fn Context(comptime config: Config, comptime Platform: type) type
```

`Context` validates `config` at comptime, using the lesson's
`@compileError` pattern with exact messages:
- `state_slots` and `measure_cache_entries` must be powers of two
  (`"zui: state_slots must be a power of two, got 1000"`);
- `frames_in_flight` must be at least 1;
- `Platform` must implement the interface in §8.1. That check reuses the
  `assertImplements` pattern, so a missing `measureText` is reported as
  `"MyPlatform does not implement zui.Platform: missing \`measureText\`"`
  instead of failing somewhere deep inside the layout code.

The index type is the smallest whole-byte unsigned integer that holds
`max_elements`: `u16` for the default 4,096. (The draft used the smallest
integer, a `u13`. It is stored in 16 bits anyway, and every load of one is
masked; rounding up made the 4,096-box benchmark 10% faster.) The enums
stored per element (`Sizing.Rule`, `Direction`, `Alignment`, `TextWrap`,
the content kind) are `u8`-backed for the same reason.

### 4.2 Memory

```zig
pub fn init(gpa: std.mem.Allocator, io: std.Io, platform: *Platform) !Self
pub fn initBuffer(buffer: []align(16) u8, io: std.Io, platform: *Platform) error{BufferTooSmall}!Self
pub fn deinit(self: *Self, gpa: std.mem.Allocator) void
pub const required_bytes: usize // comptime-known size for initBuffer
```

The `io` is used for tasks (§10.3) and for waiting on frames held by a
renderer (§10.2). A program with neither can pass any `Io`, and nothing
will be called on it.

`init` makes **exactly one allocation**, of `required_bytes`. Everything
is carved out of it: `frames_in_flight` frame arenas, the state table, the
measurement cache, the hit-test table and the scratch stacks.
`required_bytes` is a comptime constant, so embedded applications can
place the whole UI in a static buffer with `initBuffer`.

Each frame arena is sized for the worst case of `max_elements` and
`max_text_bytes`. When a frame exceeds a limit, that is a defined,
reported condition (§13.2), never memory corruption.

### 4.3 Element storage

Per-frame element data is stored as structure-of-arrays, so each layout
pass streams through only the fields it uses.

| Array (length `max_elements`) | Type | Used by |
|---|---|---|
| `id` | `u64` | interaction, state, duplicate detection |
| `parent` | `ElementIndex` | every pass |
| `subtree_end` | `ElementIndex`: one past the element's last descendant | walking children, emission |
| `child_count`, `flow_child_count` | `ElementIndex` | sizing passes |
| `layout` | `u32` index into the layout-config array, or `none` | sizing and positioning |
| `decoration` | `u32` index, or `none` | command emission |
| `content` | a tagged index: `none`, text, image, custom | text wrapping, emission |
| `flags` | `packed struct(u16)`: clips, scrolls, floating, interactive, has_semantics, ... | every pass |
| `size` | `[2]f32` | sizing passes |
| `min_size` | `[2]f32` | the shrink pass |
| `position` | `[2]f32` | positioning, hit testing |

Elements are stored in declaration order (pre-order), so the tree needs
no child or sibling links. A parent's first child, if it has one, is the
next element, and each child's next sibling is `subtree_end[child]`:

```zig
var child = parent + 1;
while (child < frame.subtree_end[parent]) : (child = frame.subtree_end[child]) {
    // visit child
}
```

`Frame.children(parent)` is this loop as an iterator. In 0.5 and earlier each
element also stored `first_child`, `last_child` and `next_sibling`, and
declaring an element wrote them for it and for its parent; dropping them
made declaration 6–31% faster with no change to layout.

Config structs are stored once, in separate arrays per kind, and
elements refer to them by index. An element without decoration costs no
decoration memory. This is the same idea as Clay's separate config
arrays, and it keeps the per-element core at **59 bytes**: an 8-byte id,
eight 2-byte links and indices, 2 bytes of flags, a content-kind byte,
and 32 bytes of geometry (size, minimum size, position and content
size).

The arrays are *reserved* for the worst case, though. Every config kind
gets `max_elements` slots, and commands and lines get
`max_render_commands`, so the reservation is much larger than the core.
Measured for the default `Config` in 0.2: **1.79 MiB per frame in flight,
and 4.29 MiB of `required_bytes`**. That covers two frames, the text
cache, the state table (96 KiB) and the previous frame's interaction
results (480 KiB, §7.4). By `a6d8e34`, `required_bytes` had grown to
4.63 MiB; `zig build bench` prints the current figure (§14.3). A frame
only *touches* the slots it uses, so the cost per frame still scales
with the elements declared. Applications with smaller UIs should lower the
limits, and `required_bytes` reports the result exactly.

---

## 5. Frame lifecycle

```zig
pub fn beginFrame(self: *Self, input: Input) void
pub fn endFrame(self: *Self) EndFrameError!*const Frame
pub fn release(self: *Self, frame: *const Frame) void
```

1. **`beginFrame(input)`**
   - Selects the next free frame arena, or blocks if every arena is still
     held by a renderer (§10.2), and resets it. This is O(1): the arena's
     counters reset, and its memory is not cleared.
   - Advances the state table's generation counter (§9).
   - Resolves interaction against the **previous** frame's hit regions:
     hover, press and release, the focus target, and the scroll target.
     Results are kept by id for the queries in §7.4. *Planned for 0.7:*
     it processes the frame's input events one at a time, in arrival
     order (§5.1).
   - Applies the completions of every registered task pool, without
     blocking (§10.3). Every request in the frame sees the pools as they
     are now.
2. **Declaration.** The application calls `open`, `close`, `text`, and
   the other declaration functions. These only *append* to arrays. No
   layout happens yet.
3. **`endFrame()`**
   - Checks that `open` and `close` balanced (§13.1).
   - Runs the layout passes (§6).
   - Emits render commands, hit regions and semantics (§7.5–7.6).
   - Cancels the tasks of ids that were not declared (§10.3).
   - Returns the frame, or an error with diagnostics if a limit was
     exceeded (§13.2). On a limit error the frame is still valid: the
     elements that fit were laid out and emitted.
4. **`release(frame)`** returns the frame's arena once the renderer is
   done with it. With `frames_in_flight = 1` it must be called before the
   next `beginFrame`.

The **one-frame latency** of interaction is deliberate, and standard for
immediate mode. A click is resolved against what was on screen when the
user clicked, which is the previous frame. It also means declaration never
has to wait for layout.

### 5.1 Input

```zig
pub const Input = struct {
    viewport: [2]f32,
    dt_seconds: f32 = 0,
    pointer: ?[2]f32 = null,          // null when the pointer is outside the surface
    buttons: std.EnumSet(Button) = .initEmpty(),
    wheel: [2]f32 = .{ 0, 0 },        // layout units; positive scrolls toward the end
    keys_pressed: []const Key = &.{}, // this frame's key-down events, in order
    modifiers: Modifiers = .{},       // held: shift, control, alt, super
    text_input: []const u8 = "",      // UTF-8 typed this frame
};
```

`Key` is a small enum of navigation and editing keys: tab, enter, escape,
space, backspace, delete, the arrows, home, end, page up and page down.
Modifiers are a separate field because they are *held state* rather than
events: shift-tab needs to know that shift is down while tab is pressed.
Mapping platform key codes onto both is the backend's job.

The slices only need to live until `beginFrame` returns, because zui
copies what it keeps: at most `zui.max_keys_per_frame` (32) key events
and `zui.max_text_input_bytes` (128) bytes of text per frame. The rest of
a frame's events are dropped.

*Planned for 0.7 (ROADMAP.md I3, I4):* input becomes an ordered event
log. Sampled `buttons` lose a press and release that both fall between
two polls, which is common when the application sleeps until input
arrives, and they can describe only one pointer.

```zig
pub const Input = struct {
    viewport: [2]f32,
    dt_seconds: f32 = 0,
    events: []const Event = &.{}, // in arrival order
};

pub const Event = union(enum) {
    pointer_down: PointerButton,
    pointer_up: PointerButton,
    pointer_move: PointerMove,
    pointer_cancel: PointerId, // the OS took the pointer: palm rejection, a system gesture
    pointer_leave: PointerId,
    wheel: Wheel,              // position, delta, and whether the delta is precise or in lines
    key_down: KeyEvent,        // key, modifiers held at that moment, repeat
    key_up: KeyEvent,
    text: []const u8,
    os_gesture: OsGesture,     // pinch and rotate the OS recognized, at a position
};

pub const Pointer = struct {
    id: PointerId,
    kind: enum { mouse, touch, pen },
    position: [2]f32,
    seconds: f64,              // the host's timestamp
    pressure: f32 = 1,
    tilt: [2]f32 = .{ 0, 0 },
};
```

`PointerButton` and `PointerMove` extend `Pointer` with the button, and
with the coalesced history of a move. The rules:
- **Events are processed in order.** A press and release in one frame is
  a click, and "release, then a new touch" is handled in that order.
- **Moves are coalesced per pointer.** Only the last move before another
  event of the same pointer is hit-tested; the earlier ones stay as
  history, for velocity. A mouse that reports at 8 kHz costs one hover
  hit test per frame, as today.
- **Velocity comes from the host's timestamps,** never from a clock read
  during the frame, so replay is deterministic.
- **Touch never hovers.** A mouse or pen hovers while it is over the
  surface.
- **`Key` grows** to letters, digits, punctuation and function keys.
  Modifiers travel with each key event, so shift-tab followed by tab in
  one frame is resolved correctly.
- **Limits:** `Config.max_pointers` (default 10) sizes the pointer table;
  a contact beyond it is ignored until a slot frees, as digitizers do.
  `Config.max_events_per_frame` replaces `zui.max_keys_per_frame`, and
  events past it are dropped and reported (§13.2).
- **Sampled backends** use `zui.InputSampler`, which turns successive
  states into events.

Accessibility actions (Invoke, RangeValue, Scroll) join the union in
0.12 as events naming an element id (ROADMAP.md V2).

---

## 6. Layout

### 6.1 Model

Every element is a box with an axis (`left_to_right` or `top_to_bottom`),
padding, a gap between its children, child alignment on both axes, and a
sizing rule per axis:

```zig
pub const Sizing = struct {
    rule: enum(u2) { fit, grow, fixed, percent } = .fit,
    /// fixed: the size. percent: the fraction of the parent's content box (0..1). grow: the weight.
    amount: f32 = 0,
    min: f32 = 0,
    max: f32 = std.math.inf(f32),

    pub const fit: Sizing = .{};
    pub const grow: Sizing = .{ .rule = .grow, .amount = 1 };
    pub fn fixed(size: f32) Sizing { ... }
    pub fn percent(fraction: f32) Sizing { ... }
    pub fn growWeighted(weight: f32) Sizing { ... }
    pub fn fitBetween(min: f32, max: f32) Sizing { ... }
};

pub const Sizing2 = struct {
    width: Sizing = .fit,
    height: Sizing = .fit,
    pub const grow_both: Sizing2 = .{ .width = .grow, .height = .grow };
};
```

`Sizing` is a struct with declarations, rather than a tagged union,
because Zig forbids a field and a declaration with the same name, and the
helpers are what keep literals short. Using one 16-byte struct also
avoids a tag-dependent layout. Thanks to decl literals, config literals
read as `.sizing = .{ .width = .grow, .height = .fixed(48) }` or
`.sizing = .grow_both`.

A `percent` child contributes nothing to a `fit` parent's size, because
the parent's size would otherwise depend on the child's and the child's
on the parent's. Percent is meant for parents whose size is decided some
other way (`fixed`, `grow`, or the root).

As in CSS, a percentage is of the parent's content box, **not counting
gaps**, and a percent child can shrink like a `fit` or `grow` child. Two
`.percent(0.5)` children with a 10-unit gap and a 50-unit child that
cannot shrink, in a 210-unit row, come out 70, 70 and 50: the overflow
of 80 is taken from the two largest. (Clay subtracts the gaps first and
never shrinks percent children, so its version of that row overflows.)

A `grow` child starts from its content size, and free space is added on
top, as with CSS `flex-basis: auto`. Two `grow` children whose contents
are 8 and 128 wide share 300 units as 90 and 210, not 150 each. *Planned
for 0.10:* a zero basis (`.growEqual`) for equal columns.

### 6.2 Passes

All passes iterate over the element arrays in declaration (pre-) order or
in reverse. None of them recurses.

| # | Pass | Direction | Work |
|---|---|---|---|
| 0 | measure text | each text element | every word (or paragraph, or the whole text, by wrap mode) is measured through the cache, and its width recorded for pass 3. |
| 1 | fit widths | reverse order (children before parents) | each `fit` width becomes the sum of its children along its axis (or their maximum across it), plus padding and gaps, clamped to min/max. Text contributes the width of its longest word as its minimum and its unwrapped width as its preferred width. Each element adds its size into its parent's as it is reached, so no child list is walked. |
| 2 | distribute widths | forward (parents before children) | inside each parent along the width axis: `percent` and `fixed` children first, then free space goes to `grow` children by weight. If the children overflow, they shrink: the largest shrinkable child shrinks first until it matches the next largest (Clay's approach), never below its minimum. The parent's content size is recorded for scrolling and alignment. |
| 3 | wrap text | each text element | with its width now known, the text is wrapped into lines (§8.2) from the widths pass 0 recorded, which fixes its height. |
| 4 | fit heights | reverse | as pass 1, for heights. |
| 5 | distribute heights | forward | as pass 2, for heights. |
| 6 | position | forward | each parent, once placed, prepares a cursor from its content box, alignment and scroll offset, and each child takes its place from its parent's cursor. Floating elements are positioned relative to their attach target (§6.4). |
| 7 | emit | forward, then per z-layer | render commands, clip regions, hit regions (§7.5). Elements that draw nothing are skipped; a border waits until the element's subtree ends. |

Widths are settled before heights because text wrapping needs the width,
and the height depends on the wrap. This is the one ordering constraint,
and it is why the passes come in pairs.

Each pass is a tight loop over a few arrays. Measuring is the only
per-character work, and it runs once per text element. §6.5 has the
measured cost, and what fusing passes did to it.

### 6.3 Clipping and scrolling

An element with `.clip = .both` (or `.{ .horizontal = true, .vertical = false }`)
clips its descendants. zui emits a `clip_begin` whose rectangle is
already intersected with every enclosing clip, so a renderer only needs
a scissor stack: push on `clip_begin`, pop on `clip_end`. Elements and
lines of text entirely outside the active clip are not drawn at all, which
keeps long scrolled lists cheap to render.

`.scroll = .{}` (vertical by default; `.both`, or `.horizontal = true`)
makes an element scroll on those axes, and clips them. The rules:
- **It needs an id,** because the offset is kept in the state table (§9)
  as a `zui.ScrollState` under that id. A scroll container without an id
  panics in safe builds and only clips in release builds.
- **Its children are not shrunk along a scrolled axis.** They keep their
  size and overflow, which is what makes the content scrollable. For
  example, a long line of text in a horizontally scrolling strip stays on
  one line.
- **The offset is clamped** to `[0, content − size]` at layout time, once
  the content has been measured, and the clamped value is written back.
  `ui.scrollOffset(id)` reads it, and `ui.setScrollOffset(id, offset)`
  sets it; the new offset takes effect at the next layout.

Wheel input goes to the deepest scroll container under the pointer that
can still move in the wheel's direction. If it cannot, the input passes
to the next container outward, as in browsers. *Planned for 0.10:*
dragging and two-finger gestures follow the same rule by the motion
component they carry: a drag locks to an axis once it passes the touch
slop, and goes to the innermost element that accepts panning on that axis
and still has room (ROADMAP.md I5).

### 6.4 Floating elements

Tooltips, dropdowns and modals are declared in place:

```zig
.floating = .{
    .attach_to = .parent,          // or .root (the viewport), or .{ .element = id }
    .anchor = .top_center,         // this point of the floating element...
    .attach_point = .bottom_center, // ...goes on this point of the target
    .offset = .{ 0, 4 },
    .z = 1,
},
```

The anchor and attach points are one of nine positions, `.top_left`
through `.bottom_right`. Floating elements follow these rules:
- **They take no space** in their parent's flow, and are positioned after
  it in pass 6, relative to their target.
- **`grow` and `percent`** resolve against the viewport for `.root`, and
  against the parent otherwise. An `.element` target may not be sized yet
  when the parent is visited.
- **An `.element` target must be declared earlier** in the frame. A later
  or missing target falls back to the parent.
- **They paint in their own layer** `z`. Commands are sorted stably by
  `z`, so a floating element paints over everything in lower layers, in
  declaration order within its layer. They escape their ancestors'
  clipping, so a tooltip inside a scroll list stays visible.
- **They win the hit test** over lower layers. A floating element always
  gets a hit region, even when it is not interactive, so it covers what is
  beneath it. Its own tree ancestors still count as hovered when they
  contain the pointer, as in CSS, so a menu stays hovered while the
  pointer is over its dropdown.

### 6.5 Performance targets

The targets, for one 2020-era desktop core:
- **4,096 boxes, depth 8, no text:** layout and emission under 100 µs.
- **1,000 text elements averaging 40 characters, all measurements cached:**
  under 250 µs.
- **Allocation:** zero after `init`.

Measured in 0.5 on an Intel i9-10900K (a 2020 desktop CPU), with
`zig build bench`, as the fastest of 400 frames:

| Scenario | 0.4 | 0.5 | Target |
|---|---|---|---|
| 4,096 boxes, depth 8 | 216 µs | 97 µs (CI runners: 63–125 µs) | 100 µs |
| 1,000 texts, warm cache | 346 µs | 166–176 µs (CI runners: 97–204 µs) | 250 µs |
| 4,000 children of one parent | 163 µs | 65 µs | |
| allocations after `init` | 0 | 0 | 0 |

The box tree is 512 chains of 8 nested boxes with mixed sizing rules, so
nearly every element is a parent: the most layout work a tree of that
size can ask for. Shallower, wider trees cost less per element. Its time
is within a few percent of the target, so it has no headroom.

What made the difference, in order of effect:
- **Text is looked up once per frame.** Measuring records the width of
  every word in a scratch buffer (`text.maxRuns` entries, sized by
  `max_text_bytes + max_elements`), and wrapping reads the widths back
  instead of hashing each word again.
- **The cache key is one hash.** Wyhash of the bytes, seeded with the font
  and size, instead of a hash and two mixes, and the word splitter scans
  16 bytes at a time.
- **No pass walks a child list it doesn't need to.** The fit passes run
  backward and add each element into its parent, positions stream forward
  from a per-parent cursor, and every parent's flow child count is kept at
  declaration.
- **Byte-sized indices and enums** (§4.1), and float `min`/`max` without
  NaN handling (`style.larger`, `style.clampSize`): Zig's `@max` on floats
  costs about five extra instructions each.
- **Emission skips elements that draw nothing** and opens a level only for
  elements that clip, float, have a border, or form a hit region or a
  focus scope.
- **The interaction table is cleared slot by slot**, instead of zeroing
  all 16,384 slots every frame.
- **Each pass stays its own function.** Inlined into one body they were
  about 3% slower, and fused into four loops 17% slower.

In 0.5, declaration was the larger half of a frame: about 110 µs of the
box tree's 206 µs. `zig build bench` now times it on its own (§14.3).
Inlining `open` and `box` so the 168-byte `ElementConfig` is never
copied, dropping the child links (§4.3), writing fewer per-element
fields, and fixing a store-forwarding stall on the open-element depth
cut it by 42–56%: the box tree's declaration went from 104 µs to 52 µs
and the wide tree's from 124 µs to 55 µs, with layout unchanged.

---

## 7. Declaration API

### 7.1 Elements

```zig
pub fn open(self: *Self, element: ElementConfig) void
pub fn close(self: *Self) void
/// A leaf element: `open` and `close` in one call.
pub fn box(self: *Self, element: ElementConfig) void
pub fn text(self: *Self, content: []const u8, style: TextStyle) void
pub fn image(self: *Self, handle: config.ImageHandle, element: ElementConfig) void
pub fn custom(self: *Self, data: config.CustomData, element: ElementConfig) void
```

`text`, `image`, `custom` and `box` are leaves: they take no children and
need no `close`.

`ElementConfig` has a field for each config kind (`layout`, `background`,
`corner_radius`, `border`, `clip`, `scroll`, `floating`, and later
`semantics`), each with a default. Only the kinds that are set get
stored. Four flags control interaction (§7.4):
- `interactive` makes the element hit-tested, so it can be hovered,
  pressed and clicked;
- `focusable` makes it reachable with tab, and implies `interactive`;
- `focus_scope` keeps tab inside the element's descendants;
- `disabled` keeps the element hit-tested, so it still covers what is
  beneath it, but it is never pressed, clicked or focused.

*Planned for 0.10:* `.gestures` declares what else an element accepts
(pan on an axis, zoom, drag, long press, double tap, a custom
recognizer), as a packed set stored in its hit region (ROADMAP.md I5).

`text` copies its content into the frame arena, so the caller's buffer
may be reused immediately.

Nesting follows the code, with `defer`:

```zig
fn toolbar(ui: *Ui, app: *App) void {
    ui.open(.{
        .id = .of("toolbar"),
        .layout = .{ .direction = .left_to_right, .sizing = .{ .width = .grow, .height = .fixed(40) }, .padding = .all(4), .child_gap = 4 },
        .background = theme.panel,
    });
    defer ui.close();

    toolButton(ui, .of("save"), "Save", app);
    toolButton(ui, .of("export"), "Export", app);
}
```

A "component" is just a function that declares elements. zui has no
component type, registry or lifecycle.

### 7.2 Ids

```zig
pub const Id = struct {
    hash: u64,
    pub fn of(comptime name: []const u8) Id            // hashed at compile time
    pub fn indexed(comptime name: []const u8, index: usize) Id
    pub fn dynamic(name: []const u8) Id                 // hashed at run time
    pub fn child(parent: Id, comptime name: []const u8) Id
    pub fn indexedChild(parent: Id, comptime name: []const u8, index: usize) Id
    pub const none: Id;
};
```

- **The hash is 64-bit FNV-1a,** which is cheap to evaluate at comptime.
  The width is 64 bits because 32-bit ids collide in practice: with 8,000
  ids per frame, the birthday bound gives a roughly 1% chance of a
  collision every frame at 32 bits, and about 2 × 10⁻¹² at 64 bits.
- **`of` and `indexed` hash the name at compile time.** At run time, `of`
  costs a constant and `indexed` costs one mix with the index. Hashing is
  by *content*, so the same name always gives the same id however the
  string is stored (the slice memoization trap from the lesson, B8, does
  not apply to a hash).
- **`child(parent, name)`** mixes the parent's hash with the name, so that
  repeated components (`list_item` inside two different lists) do not
  collide. Element ids are never mixed with their parent implicitly. That
  would make an id depend on where the element sits in the tree, so that
  moving an element would silently reset its state.
- **`indexedChild(parent, name, index)`** is `child` for the items of a
  list, such as a dropdown's options, which must not collide with the
  options of another dropdown.
- **Elements without an id** get an internal one from their parent's id
  and their sibling index. They cannot be queried and cannot hold state,
  which is what you want for purely decorative boxes.

`zui.ids(.{ "save", "export", "close" })` returns a struct with one `Id`
field per name. It checks at comptime that no two names collide. This is
the duplicate check possible within one declaration, given that comptime
has no global state. Across the whole frame, duplicates are detected at
run time (§13.1).

### 7.3 Text

```zig
pub const TextStyle = struct {
    font: config.FontId = 0,
    size: f32 = 16,
    color: Color = .black,
    line_height: f32 = 0, // 0 = use the font's own
    wrap: enum { words, newlines, none } = .words,
    alignment: enum { start, center, end } = .start,
};
```

Text is UTF-8. zui splits it into words at ASCII spaces and newlines,
and measures through the platform (§8). It does not shape text: a
platform that shapes text returns shaped widths from `measureText`.

### 7.4 Interaction queries

Every query answers for the **previous** frame (§5), by id:

```zig
pub fn hovered(self: *const Self, id: Id) bool
pub fn pressed(self: *const Self, id: Id) bool           // button held, press began on id
pub fn clicked(self: *const Self, id: Id) bool           // released on the same id it was pressed on
pub fn focused(self: *const Self, id: Id) bool
pub fn requestFocus(self: *Self, id: Id) void            // at the next beginFrame, if id is then focusable and enabled
pub fn widgetState(self: *const Self, id: Id) WidgetState
pub fn pointerLocal(self: *const Self, id: Id) ?[2]f32   // pointer relative to the element's last rect
pub fn rectOf(self: *const Self, id: Id) ?Rect           // last frame's layout result
pub fn pointer(self: *const Self) ?[2]f32
pub fn keyPressed(self: *const Self, key: Key) bool
pub fn keysPressed(self: *const Self) []const Key        // in the order they happened
pub fn modifiers(self: *const Self) Modifiers
pub fn typedText(self: *const Self) []const u8
```

Two more queries exist for widgets. They answer for the current frame,
not the previous one:

```zig
pub fn measureText(self: *Self, content: []const u8, font: FontId, size: f32) [2]f32 // through the cache
pub fn viewport(self: *const Self) [2]f32
```

The exact meanings:
- **Hover.** The *hot* element is the topmost interactive element under
  the pointer: highest layer first, then the last painted. `hovered` is
  true for it and for each interactive ancestor that also contains the
  pointer, as with CSS `:hover`.
- **Press and click.** Both go to the hot element only. A click needs the
  press and the release on the same element, and lasts one frame.
- **Keyboard activation.** Enter or Space on the focused element also
  counts as `clicked`, so every clickable element works from the keyboard.
- **Focus.** Pressing on a focusable element focuses it; pressing anywhere
  else clears focus. Focus is also cleared when its element is no longer
  declared.
- **Where the answers come from.** Every query reads a compact copy of
  the previous frame's results: element rectangles by id, hit regions,
  and the tab order. The copy lives in the `Context` rather than in a
  frame, because with `frames_in_flight = 1` the previous frame's memory
  is reused before the queries run.

Because the queries run before the element is declared, styles can
depend on interaction:

```zig
fn toolButton(ui: *Ui, id: zui.Id, label: []const u8, app: *App) void {
    ui.open(.{
        .id = id,
        .interactive = true,
        .background = theme.button.get(ui.widgetState(id)),
        .layout = .{ .padding = .symmetric(12, 6) },
    });
    defer ui.close();
    ui.text(label, theme.button_text);
    if (ui.clicked(id)) app.handle(id);
}
```

`widgetState(id)` returns `.idle`, `.hovered`, `.pressed`, `.focused` or
`.disabled`, checked in the order disabled, pressed, hovered, focused.
Themes index it with an `std.EnumArray`, so adding a state is a compile
error in every theme until the theme handles it.

**Focus** moves with tab and shift-tab, in declaration order, among
elements marked `.focusable = true`. Elements in a `.focus_scope`, such as
a modal, keep focus inside the scope.

*Planned for 0.7 (ROADMAP.md I4):* the queries answer for every pointer.
`hovered` is true under any pointer that can hover; `pressed` while any
pointer whose press began on the element is down; `clicked` when one of
them is released over it. `pointer()` and `pointerLocal` follow the
primary pointer: the mouse, or the first touch to go down while no other
was down. `chordPressed(.{ .key = .s, .modifiers = .{ .control = true } })`
matches a key with the modifiers held when it was pressed.

*Planned for 0.10 (ROADMAP.md I5):* queries that merge devices into
intents: `manipulation(id)` (translation, scale, rotation and pivot,
summed over the frame, from a drag, a pinch, the wheel or momentum),
`contextRequested`, `dismissed`, `adjusted` and `navigated`. Custom
recognizers read `pointerEvents(id)` and take or give up a pointer with
`claim` and `decline`.

### 7.5 Render commands

```zig
pub const RenderCommand = struct {
    bounds: Rect,
    id: u64,
    z: i16,
    payload: union(enum) {
        rectangle: struct { color: Color, corner_radius: CornerRadius },
        border: struct { color: Color, widths: Edges, corner_radius: CornerRadius },
        text: struct { content: []const u8, style: TextStyle, line: u32 },
        image: config.ImageHandle,
        clip_begin: Rect,
        clip_end,
        custom: config.CustomData,
    },
};
```

`Frame.commands()` returns `[]const RenderCommand`, in paint order: by z,
then by declaration order. A text element produces one command per
wrapped line, so renderers never have to wrap text themselves. All
slices point into the frame's arena and stay valid until `release`.

Payload types come from `Config`, so `.custom` and `.image` carry your
own types, with no casting from `*anyopaque` or `u64`. If `CustomData` is
`void`, the `custom` declaration function does not exist: calling it is a
compile error that names the config field to set.

### 7.6 Semantics (optional)

*Planned for 0.12.*

An element can carry `.semantics = .{ .role = .button, .label = "Save" }`.
Frames then also contain `Frame.semantics()`: a flat list of
`{ id, role, label, bounds, state }` in tree order, for a backend that
bridges to the platform's accessibility API. When no element sets
semantics, the list is empty and costs nothing.

---

## 8. Platform interface

### 8.1 Required and optional declarations

```zig
const MyPlatform = struct {
    /// Required. Width and height of `text` in `font` at `size`, in layout units.
    /// `FontId` is `Config.FontId` (u16 by default).
    pub fn measureText(self: *MyPlatform, text: []const u8, font: FontId, size: f32) [2]f32 { ... }

    /// Optional. Called from any thread when a task completes, so a sleeping
    /// event loop can wake and render a frame.
    pub fn wake(self: *MyPlatform) void { ... }

    /// Optional. Physical pixels per layout unit. When declared, command
    /// bounds snap to whole physical pixels; without it, nothing is snapped.
    pub fn scale(self: *const MyPlatform) f32 { ... }
};
```

`measureText` takes the font and size rather than a whole `TextStyle`.
Those two values are exactly what the measurement cache keys on (§8.3),
and the narrower signature avoids a type cycle: `TextStyle` depends on
`Config.FontId`, which belongs to the `Context` the platform is a
parameter of.

`pub const thread_safe_measure = true;` is the one optional non-function
declaration: it promises that `measureText` may be called from several
threads at once, which enables parallel measurement (§10.5). It must be a
`bool`.

**Measurement must be additive:** measuring `a` and `b` separately must
sum to measuring `a ++ b` (`width("one") + width(" ") + width("two") ==
width("one two")`). zui measures each word and each space once, caches
them, and wraps by adding them up. A platform with letter spacing must
therefore count the spacing after *every* glyph, including the last.
raylib's `MeasureTextEx` omits that last spacing. Used directly, it
under-measures every word and space, and lines overflow their boxes. The
zui-raylib backend found this, and compensates. Kerning across word
boundaries is the one effect additive measurement cannot express, and at
those boundaries it is usually negligible.

The platform is a **comptime** type parameter, not a vtable. Text
measurement is the hottest call that leaves zui, so it is dispatched
directly and can be inlined. An application has one platform, so this is
one instantiation of the engine, not the B1 explosion. `@hasDecl` checks
for the optional declarations, and their default behavior is documented.
The check rejects unknown `pub` declarations whose names start with
`zui`, because a misspelled optional hook would otherwise be silently
ignored (lesson B5).

### 8.2 Wrapping

Pass 3 wraps each text element against its final width:
1. **Split into words** once per element, recording each word's byte
   range and whether a newline follows it.
2. **Measure each word through the cache** (§8.3): one `measureText` per
   distinct (word, font, size) per cache lifetime.
3. **Lay words into lines** greedily, using the width of a space measured
   once per (font, size).

**Words are never broken.** A text element's minimum width is its longest
word (§6.2, pass 1), and no pass makes an element narrower than its
minimum, so a line can only be narrower than a word when the parent is
too small for that word. The word then gets a line of its own and
overflows, as in CSS by default. (An earlier draft of this spec broke
over-wide words at code points; the layout rules made that path
unreachable, so 0.1 removed it.)

### 8.3 Measurement cache

The cache is an open-addressed table with `measure_cache_entries`
entries. The key is `(hash64(bytes), font, quantized size)`. The value is
the size and a last-used generation. On a miss, zui calls the platform.
When probing fails, it evicts the least recently used of the probe window.
The cache lives in the `Context` and persists across frames, which is why
steady-state frames make almost no platform calls.

---

## 9. Persistent state

Some state has to survive between frames: scroll offsets, focus, text
cursor positions, open/closed toggles, task handles. zui keeps it in one
keyed table, never in the element arrays.

```zig
pub fn state(self: *Self, id: Id, comptime T: type) *T     // created zeroed on first use
pub fn stateIfPresent(self: *Self, id: Id, comptime T: type) ?*T
```

- **The table** is open-addressed with linear probing, with `state_slots`
  entries, keyed by `(id, @typeName(T) hash)`. The same id can therefore
  hold, for example, both a `ScrollState` and an application `Expanded`
  flag. Because the type is part of the key, asking for a different type
  under the same id gives a different slot, never the wrong one.
- **Payloads are limited** at comptime to `@sizeOf(T) <= 64` and
  `@alignOf(T) <= 16`. That keeps slots fixed-size, and the error tells
  you to store an index to your own storage instead.
- **Eviction.** Each slot records the frame it was last touched. Slots not
  touched for `state_ttl_frames` (default 2) are freed at the start of the
  next frame. An element that disappears loses its state, which is the
  immediate-mode equivalent of unmounting. Freed slots use backward-shift
  deletion, so the table never accumulates tombstones.
- **Gestures** keep their state here too *(planned for 0.10)*: momentum,
  and the state of custom recognizers, so both end when their element is
  no longer declared (ROADMAP.md I5).
- **Full table.** It does not corrupt anything: `state` returns a pointer
  to zeroed scratch memory, and `endFrame` reports
  `error.CapacityExceeded` with the `.state_slots` limit in its
  diagnostics (§13.2).

---

## 10. Concurrency

zui is single-threaded where that is fastest (declaration and layout of
one context) and explicit everywhere threads meet. It integrates with
Zig 0.16's `std.Io`: `io.async`/`io.concurrent`, `Io.Future`, `Io.Group`
and `Io.Queue`. Tasks therefore work with any `Io` implementation the
application chooses: threaded, evented, or single-threaded blocking.

### 10.1 Threading contract

| Object | Contract |
|---|---|
| `Context` | not thread-safe. One thread at a time calls `beginFrame` through `endFrame`, and the thread may change between frames. |
| `*const Frame` | immutable after `endFrame`, and safe to read from any thread until `release`. |
| `release` | callable from any thread. It is a single atomic store that returns the arena. |
| `TaskPool` | `request`/`get` from the UI thread; tasks complete on any thread. |
| `Platform.wake` | must be callable from any thread. |

### 10.2 Pipelining with a render thread

With `frames_in_flight = 2`, the UI thread can build frame N+1 while a
render thread still submits frame N:

```
UI thread:      begin(N) declare endFrame(N) ─┐  begin(N+1) declare endFrame(N+1) ...
                                              │ hand over *const Frame
render thread:                                └─▶ submit(N) ... release(N)
```

`beginFrame` takes the next arena whose frame has been released. If none
has been released, it waits on an `Io.Event` that `release` sets. This is
the only point where zui blocks, and it is also backpressure: the UI cannot
run ahead of the renderer by more than `frames_in_flight` frames. The
event is reset before a second check for a free frame, which closes the
race with a `release` that lands between the check and the wait.

Each arena owns everything its frame references (element arrays, copied
text, commands), so the two threads share no mutable memory.

### 10.3 Tasks: async work owned by the UI

A *task* is background work whose lifetime follows an element. A typical
example is a thumbnail that loads while its grid cell is declared, and is
canceled when the cell scrolls away and stops being declared.

```zig
pub fn TaskPool(comptime Result: type, comptime capacity: u16) type

var thumbnails: zui.TaskPool(Io.Cancelable!Thumbnail, 96) = .{ .discard = releaseThumbnail };

fn thumbnailCell(ui: *Ui, io: Io, path: []const u8, index: usize) void {
    const id: zui.Id = .indexed("thumbnail", index);
    ui.open(.{ .id = id, .layout = .{ .sizing = .{ .width = .fixed(96), .height = .fixed(96) } } });
    defer ui.close();

    switch (thumbnails.request(ui, id, loadThumbnail, .{ io, path }, .{ .key = hashOf(path) })) {
        .pending => ui.box(.{ .background = theme.placeholder, .layout = .{ .sizing = .grow_both } }),
        .ready => |thumbnail| drawThumbnail(ui, thumbnail),
        .failed => |err| ui.text(@errorName(err), theme.error_text),
    }
}
```

The pool is **typed** by its result, so there is no type erasure and no
casting at the call site. Its status union is generated from `Result`:
- `.pending`;
- `.ready`, with the value;
- `.failed`, with the error, only when `Result` is an error union, so an
  infallible pool needs no `.failed` prong.

The capacity is fixed, so a pool cannot grow without bound. A request
that finds every slot busy stays `.pending` and counts in
`pool.stats.rejected`. Tasks run on the `Io` given to `Context.init`.

How `request(ui, id, function, args, .{ .key = ... })` works:
1. **First request for an id.** Claim a slot, then start the work with
   `io.concurrent`, falling back to `io.async` when the `Io` reports
   `ConcurrencyUnavailable`. A wrapper runs `function`, stores the result
   in the slot, marks the slot finished with the generation it started
   with, and wakes the platform. The first request returns `.pending`,
   even when, without concurrency, `io.async` ran the task inline.
2. **Later requests for the same id and key** return the slot's state
   without blocking or doing work.
3. **Completions are applied at `beginFrame`** (§5, principle 8), never
   during declaration, so every request in a frame sees the same state.
   A task that finishes mid-frame is `.ready` from the next frame. In 0.9
   `TaskPool` becomes a feed that delivers once (ROADMAP.md F1).
   - Each slot carries a **generation**, advanced whenever it is claimed,
     and a finished task records the generation it was started with, so
     a canceled task can never complete the next task in the same slot.
   - A pool-wide flag, set by the wrapper, lets `beginFrame` skip pools
     in which nothing finished.
   - A task that finishes in the frame its id stops being requested is
     canceled at `endFrame` like any other: it counts in
     `stats.canceled`, and its result goes to `discard`.
4. **Unmounting.** Each pool registers itself with the Context on its
   first request. In `endFrame`, every registered pool cancels the tasks
   whose id was not requested that frame. This works even for a pool that
   made no request at all that frame.
5. **A different key for the same id** cancels the old task and starts a
   new one. This is how a cell that is reused for different data gets
   fresh work.

**Cancelation waits.** `Io.Future.cancel` is "await plus a cancel
request": it returns only once the task has returned. Tasks must
therefore reach cancelation points, meaning any `Io` call or
`io.checkCancel()` in a long computation. Otherwise unmounting a task
waits for it to finish, on the UI thread. (`Io.Future` has no
non-blocking poll either, which is why a finished task marks its slot.)

**Owned results.** When a slot is freed, the pool passes its result to
the optional `discard` function on the UI thread. That happens whether
the result was handed out as `.ready` or was produced by a task that was
then canceled. `discard` is where results that own resources, such as
GPU textures, are released. A task canceled before it ever ran produced
no result, and is not passed to `discard`.

**Lifetime rules.** A pool and its Context reference each other by
pointer, so neither may move after the pool's first request.
`pool.deinit(ui)` cancels the pool's tasks and unregisters it.
`Context.deinit` cancels the tasks of every pool still registered.

**Redraws on demand.** `ui.needsFrame()` is true when the frame just
drawn may be out of date:
- the last input changed something: hover, a press, focus, a click, a
  key, typed text, or a scroll that actually moved;
- a task completed since the last `beginFrame`;
- the application called `ui.requestFrame()`, for example during an
  animation.

When it is false, an event loop can sleep until the next input or
`Platform.wake`. `wake` is called from the task's thread, so it must be
thread-safe; zui-raylib implements it with `glfwPostEmptyEvent`.
Measured with zui-raylib's demo in a hidden window: **0.0 ms of CPU over
10 idle seconds** in both of its views. The same build with event
waiting disabled used 1,515.6 ms (about 15% of a core) over those 10
seconds.

### 10.4 Data from other threads

Application-level background state (network messages, file watchers) is
the application's to own. zui documents one pattern and adds no machinery
for it: give each producer an `Io.Queue(Message)`, and drain it at the
start of the frame, before declaration, with `get(buffer, 0)`. Mutations
then happen on the UI thread at a frame boundary, and declaration never
observes half-applied updates.

### 10.5 Parallel layout

The sizing passes and text wrapping are sequential within a context,
because each depends on results from the pass before. Parallelism enters
at three levels, in increasing order of complexity:
1. **Contexts in parallel (v1).** Contexts share nothing, so separate
   windows, a main view and an offscreen thumbnail render can run their
   frames concurrently, each as one task in an `Io.Group`. This needs no
   code in zui beyond the contract in §10.1.
2. **Parallel measurement (0.5).** A platform whose `measureText` is
   thread-safe declares `pub const thread_safe_measure = true;`. Text is
   then measured inline until the frame has made
   `Config.parallel_measure_threshold` platform calls (default 256). At that
   point the frame is evidently cold (the first frame, or a font or size
   change), so zui collects the distinct missing (run, font, size) keys of
   the rest of the frame's text, measures them 64 per task across an
   `Io.Group`, stores them in the cache, and carries on inline, now
   hitting the cache.
   - **Warm frames pay nothing.** The draft collected misses before
     measuring every frame, and that scan made the warm 1,000-text
     benchmark 40% slower. Switching after the threshold costs nothing
     until there are misses.
   - **Cancelation is respected.** If the frame's task is canceled during
     the batch, the measurements already made are kept, the rest are left
     to the inline path, and the cancelation is passed on.
   - **Measured:** 1,000 cold texts whose measurements cost about 1 µs each,
     as with a shaping engine, take 4.6 ms on one thread and 1.1 ms in
     parallel on 10 cores (4.3×).
   - **The cache must hold the frame's misses,** or measurements evicted
     before layout reads them are measured again inline.
3. **Layout islands (later).** An element with `fixed` sizing on both
   axes and no floating descendants attached outside it is an *island*:
   nothing inside it can change anything outside it. Passes 1–6 can run
   for islands in parallel once their parents' passes reach them. This
   only pays above roughly 10k elements (an estimate), so it is opt-in per
   element (`.layout_island = true`) and must be justified by the
   benchmarks before it ships.

---

## 11. Comptime features

Each feature is listed with what it removes at run time and what it
costs, so the "comptime only where it changes the generated code" rule
can be audited.

| Feature | Mechanism | Runtime effect | Cost |
|---|---|---|---|
| Compile-time ids | `Id.of(comptime name)` hashes with FNV-1a during compilation | an id is a constant | none |
| Collision-checked id sets | `zui.ids(.{...})` checks for duplicates and collisions at comptime | none | compile time, linear in names |
| Exact memory | `Config` limits → `@Int` index types, comptime `required_bytes` | one allocation, dense indices | recompile to change the limits |
| Typed payloads | `CustomData`, `ImageHandle` in `Config` | no casts, no `*anyopaque` | none |
| Direct platform dispatch | `Platform` is a comptime type | `measureText` can be inlined | one engine instantiation per platform |
| Exhaustive themes | `std.EnumArray(WidgetState, Style)` | none | none; new states are compile errors |
| Compiled-out debugging | `-Dzui-debug` gates code that is then never analyzed | zero bytes when off | none |
| Typed tasks | `TaskPool(Result, capacity)` | no type erasure | one pool type per result type |
| Typed event thunks (widgets) | `onClick(comptime handler, context: *T)` generates a trampoline | `*T` with no cast | one small function per handler |

What zui deliberately does **not** do at comptime:
- **It does not specialize layout per element or per tree.** That is B1
  and B2 at UI scale.
- **It does not take `anytype` configs.** Config parameters are concrete
  types, so a mistake is reported at the call site in terms of zui's
  types (B4).
- **It does not pre-bake whole trees, in v1.** §16 describes static
  subtrees as a measured, opt-in later feature.

---

## 12. Styling and themes

Styles are plain values. A theme is the application's own struct:

```zig
const Theme = struct {
    panel: zui.Color,
    button: std.EnumArray(zui.WidgetState, zui.Color),
    button_text: zui.TextStyle,
    spacing: f32,
};
```

zui provides `Color` (RGBA8 with `.rgb(0x3366ff)` and `.mix`), `Edges`,
`CornerRadius`, and decl-literal helpers (`.all(n)`, `.symmetric(h, v)`).
*Planned for 0.11:* `Config.Color` may be `zui.ExtendedColor` (4×f16,
linear scRGB) for HDR and wide gamut, clamped for renderers without
support (ROADMAP.md G6).
It provides no theme registry, no inheritance and no cascade. Swapping a
theme means passing a different struct, so the cost is exactly the cost
of reading a field.

---

## 13. Errors and diagnostics

Declaration functions never return errors. A UI written as nested calls
with `try` on every line is unreadable, and most failures are better
reported once per frame, with full context.

### 13.1 Programmer errors (detected, then asserted or reported)

| Condition | Detection | In safe builds | In release builds |
|---|---|---|---|
| unbalanced `open`/`close` | depth counter at `endFrame` | panic naming the unclosed element's id, and its name when debug is on | the elements are closed implicitly, and `endFrame` reports `error.UnbalancedTree` |
| duplicate id within a frame | insertion into the frame's id → element table | panic naming both declarations | the second element becomes non-interactive |
| `close` without `open` | the depth counter would go below zero | panic | ignored |
| scroll container without an id | checked at `open` | panic | the element clips but does not scroll |

With `-Dzui-debug`, `Id.of` keeps its name, so panics name the element
(`zui: duplicate id "save" (0x…) in one frame`) instead of printing only
a hex hash.
Without it, the name is not stored at all.

### 13.2 Capacity limits (defined behavior, reported)

Elements, text bytes, depth, render commands (including wrapped lines),
state slots, task slots, the measurement cache, and, from 0.7, input
events per frame all fail the same way:
1. The part that fits is kept. Overflowing elements are dropped from the
   frame, and their subtrees are skipped cheaply: the depth is still
   tracked, so `close` calls pair up correctly.
2. A sticky diagnostic records which limit was hit, by how much, and the
   id at which it first happened.
3. `endFrame` returns `error.CapacityExceeded`. The frame is still
   available through `ui.lastFrame()`, and `ui.diagnostics()` says which
   `Config` field to raise and the peak value it needed.

The application decides what to do: log the problem, render the partial
frame, or (in development) treat it as fatal.

---

## 14. Testing and verification

### 14.1 zui's own tests

- **Layout invariants**, checked on every test frame by
  `src/tests/invariants.zig` (it reads the frame's internal arrays, so it
  is not part of `zui_testing`):
  - each child lies within its parent's clip box, unless it is floating;
  - the sizes of `grow` siblings are proportional to their weights,
    except where a min/max clamp applies;
  - no size is negative or NaN;
  - commands are in nondecreasing z order.
- **Randomized trees.** A seeded generator builds random trees of 1–5,000
  elements with random sizing rules, and runs the invariant checks on each
  (the same approach as the model-checked table in the asserts lesson).
- **Golden layouts.** About 30 hand-written trees with exact expected
  rectangles, covering every sizing rule, alignment, padding, gap, wrap
  mode and floating anchor.
- **Allocation discipline.** Every test runs with a failing allocator after
  `init`, which proves that frames do not allocate.
- **Compile-time guarantees** through `expect_errors` in `build.zig`, as
  in the comptime lesson: an invalid `Config`, a platform missing
  `measureText`, an `Id` collision in `zui.ids`, calling `custom` with
  `CustomData = void`, an oversized state type, a slider over a `bool`,
  and five misuses of `zui_reflect` (§15.2). Each is pinned to its exact
  message. Remember that `contains` matches line *endings*, so a message
  must end with stable text, not a generated type name.

### 14.2 Tools for applications

`zui_testing` holds what an application needs to test its own UI:

- **`FixedMetricsPlatform(FontId)`** has deterministic text metrics:
  each byte is `size / 2` wide and `size` tall (8×16 at the default size),
  so tests don't depend on fonts.
- **`Driver(Ui)`** runs frames with simulated input, by element id:

  ```zig
  var driver: zui_testing.Driver(Ui) = .{ .ui = &ui };
  _ = try driver.frame(&app, App.declare, .{});           // declares the ids
  _ = try driver.click(&app, App.declare, .of("save"));   // press frame, release frame
  _ = try driver.drag(&app, App.declare, .of("volume"), .{ 0.5, 0.5 }, .{ 0.9, 0.5 });
  _ = try driver.typeText(&app, App.declare, "Ada");
  _ = try driver.pressKeys(&app, App.declare, &.{ .home, .delete });
  ```

  Points are fractions of the element's rectangle in the previous frame,
  so tests never hard-code coordinates. Each helper runs complete frames
  and releases them, and calls `declare(app, ui)` once per frame. (The
  draft's `ui.simulate(.{ .click = id })` returned an `Input` instead. A
  click takes two frames, so a helper that runs them is simpler to use
  than one that returns their inputs.) *Planned for 0.7:* the driver
  emits input events, so a click fits in one frame, and it gains `tap`,
  `pinch` and drags with several pointers (ROADMAP.md I4).
- **`snapshot(writer, commands, names)`** writes one line per command,
  for golden-file tests:

  ```text
  rectangle id=panel x=0 y=0 w=84 h=36 color=#202020
  rectangle id=increment x=8 y=8 w=40 h=20 color=#3366ff80 radius=4
  text x=52 y=8 w=24 h=16 size=16 color=#ffffff "Add"
  ```

  Only ids that are fields of `names` (a `zui.ids(...)` set) are written,
  so snapshots don't change when an unrelated internal id does, and they
  read the same in debug and release builds. Values at their defaults
  (z 0, no corner radius, opaque alpha, font 0) are left out.
  `expectSnapshot` compares against an expected string.
- **`checkCommands(commands)`** checks what any frame must satisfy:
  finite, non-negative bounds; z that never decreases; and balanced clip
  commands. `findViolation` returns the first violation instead of
  printing it.

### 14.3 Benchmarks

`zig build bench` always builds in ReleaseFast and covers:
- the §6.5 targets;
- a deep tree (depth 64) and a wide tree (one parent with 4,000 children);
- the zui-raylib demo's Documents view, declared by hand: about 100 small
  elements, most with an id, a decoration and a label;
- 1,000 texts with the cache cold (a new font size every frame);
- the same cold text measured by a platform that costs about 1 µs per
  call, on one thread and in parallel (§10.5);
- frames per second with a render thread against one thread, using a
  renderer stand-in that takes 200 µs a frame (§10.2): 1.8× as many frames
  on the reference machine.
- startup, 50 samples each:
  - `init` at the default `Config`, each sample into memory the process
    has never touched, so its page faults are counted;
  - `initBuffer` into one static buffer, which only the first sample
    touches for the first time: zui's own preparation of the memory;
  - the first frame of a new `Context`, from the start of `beginFrame`
    to the end of `endFrame`, for the Documents view and for 1,000 texts:
    every measurement misses the cache, and the frame's memory is touched
    for the first time.

  On the reference machine at `a6d8e34`, the fastest samples were 74.6 µs,
  10.0 µs, 30.3 µs and 230.0 µs.

Each steady-frame scenario runs in a new `Context` whose allocator counts
every call after `init`; any allocation fails the run, as it does in a
first frame. It prints the fastest and median declaration (from the start
of `beginFrame` to the start of `endFrame`), the fastest and median
`endFrame`, the median whole frame, nanoseconds per element of `endFrame`
and platform calls per frame, then the fastest and median of each startup
scenario and `required_bytes` at the default `Config`.

| Flag | Effect |
|---|---|
| `--check-targets` | fail if a §6.5 target is missed |
| `--json <path>` | save each single-threaded scenario's fastest declaration and fastest `endFrame`, and each startup scenario's fastest sample |
| `--compare <path>` | fail if any of them is more than 10% slower than in that file |

**How CI uses it.** The benchmark job runs it without flags: it fails on
an allocation and reports the times, but compares nothing. Timing two
commits on one runner was tried and dropped. GitHub's runners range from
62.6 to 125.3 µs for the box tree, and one runner timed a commit 45%
slower than the commit before in three alternating attempts, while two
other runners and a bisect on the same CPU model found no difference. A
comparison is meaningful on one machine with nothing else running, through
`zig build bench-compare` below, or `--json` at the old commit and then
`--compare` at the new one. Enforcing the targets is a step for a
reference machine: `zig build bench -- --check-targets`.

**Comparing two commits.** `zig build bench-compare -- <base> [<head>]`
checks out each commit in a git worktree under `.zig-cache`, with the
head defaulting to the working tree, uncommitted changes included. It
runs each commit's own `zig build bench -- --json` once to build and warm
up, then alternately for `--rounds` rounds (10 by default), swapping
which goes first each round. For each time `--json` saves, it prints:
- the median of the rounds' head/base ratios;
- the middle half of those ratios, as the spread;
- *faster* or *slower* only when that whole middle half is more than 2%
  from no change.

On the reference machine, a commit compared with itself gives middle
halves that all contain zero and stay within 2%, except in scenarios
under 2 µs, where Windows' timer steps of 100 ns are 5% to 9%. The
`depth: u16` stall fixed in `946405e`, which left the instruction count
unchanged, comes out at −26.4% (−27.5% to −26.1%) for the box tree's
declaration. Ten rounds take about 45 seconds there, most of it spent
building the worktrees.

---

## 15. Extension points

| To... | Use |
|---|---|
| draw something zui does not know | `custom(data, config)`, with your `CustomData` |
| size a custom leaf from its content | `.layout.sizing = .fixed(...)` from your own measurement. *Planned for 0.10:* optional `measureCustom(data) [2]f32` and `imageSize(handle) [2]f32` on the renderer (ARCHITECTURE.md §3.2) |
| add widgets | functions over the public API; `zui_widgets` (§15.1) is the reference set |
| bridge accessibility | `Frame.semantics()` (§7.6, planned for 0.12) |
| animate | `state(id, T)` for per-element animation state, plus `Input.dt_seconds`. *Planned for 0.14:* `zui_motion` |
| render | iterate `Frame.commands()`; backends are ordinary packages |
| debug visually | *Planned for 0.12:* `zui_debug`, an inspector panel showing the element tree and the hovered element's id, rect and config, built on a read-only `Frame.inspect` |

### 15.1 Widgets

`zui_widgets.Widgets(Ui)` is a value that holds a `Theme`. Its methods
declare widgets into a `*Ui`:

```zig
const widgets: zui_widgets.Widgets(Ui) = .{ .theme = .{ .accent = .rgb(0x2fbf71) } };

if (widgets.button(ui, .of("save"), "Save", .{})) save();
_ = widgets.checkbox(ui, .of("autosave"), "Autosave", &settings.autosave, .{});
_ = widgets.slider(ui, .of("volume"), &settings.volume, .{ .min = 0, .max = 100, .step = 5 });
if (widgets.textField(ui, .of("name"), &settings.name, .{ .placeholder = "Name" }).submitted) rename();
_ = widgets.dropdownEnum(ui, .of("quality"), &settings.quality, .{});
```

| Widget | Edits | Returns | Keyboard |
|---|---|---|---|
| `button` | nothing | clicked | Enter, Space |
| `checkbox` | `*bool` | toggled | Enter, Space |
| `slider` | `*` any integer or float | changed | arrows, Page Up/Down, Home, End |
| `textField` | `*EditableText` | `.{ changed, submitted }` | characters, Left, Right, Home, End, Backspace, Delete, Enter |
| `dropdown` / `dropdownEnum` | `*usize` / `*` any enum | changed | Up/Down while closed; Tab within the open list; Escape |
| `disclosure` | `*bool` (expanded) | toggled | Enter, Space |
| `label`, `mutedLabel`, `labeledRow` | nothing | nothing | none |

How they are built, all from §7:
- **Every control is focusable** and draws the theme's focus ring when
  focused. Colors come from `widgetState`, indexed by an `EnumArray`.
- **The slider places its thumb with `grow` weights,** not with the
  previous frame's width. The filled track has weight `fraction`, the
  rest `1 - fraction`, and the fixed-width thumb sits between them, so the
  thumb is right from the very first frame. Dragging maps `pointerLocal`
  through the previous frame's width, which is what the pointer was over.
- **The text field** keeps its caret position in `state(id, ...)`. It
  splits the text at the caret into two text elements around a caret box,
  and scrolls an inner horizontal scroll container to keep the caret in
  view. A click places the caret at the nearest character boundary,
  measured with `ui.measureText`. Keys are handled in order
  (`keysPressed`), and the caret always moves by whole UTF-8 characters.
  `EditableText` wraps a caller-owned buffer; input that does not fit is
  cut at a character boundary. Not in 0.4: selection, the clipboard, word
  movement, IME composition and multiple lines.
- **The dropdown's list** is a floating element attached to the button,
  in layer `theme.popup_z + 1`. Below it, in layer `theme.popup_z`, an
  invisible interactive element covers the viewport and closes the list
  when clicked. The list is a focus scope, so Tab stays inside it while it
  is open, and choosing an option returns focus to the button.

### 15.2 Reflection

`zui_reflect.inspector(widgets, ui, id, &value)` declares an editor for
each field of a struct with the widgets above, and returns whether any
field changed. (The draft's signature had no `widgets` argument. The
inspector needs a theme, and taking the application's own `widgets` value
keeps the two consistent.)

| Field type | Editor |
|---|---|
| `bool` | checkbox |
| integer or float, with `min` and `max` | slider and the value |
| integer or float, otherwise | − and + buttons that move by `step` (default 1, or 0.1 for floats), saturating at the type's limits and at `min` or `max` if either is given |
| exhaustive enum | dropdown |
| `zui_widgets.EditableText` | text field |
| `[]const u8` | read-only text |
| struct | collapsible section, which reads that struct's own options |

Labels default to the field name with underscores as spaces and the first
letter capitalized: `max_fps` becomes "Max fps". Options come from a
**typed** declaration:

```zig
const Settings = struct {
    max_fps: u16 = 144,
    frames_rendered: u64 = 0,

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
        .max_fps = .{ .label = "Frame cap", .min = 30, .max = 240, .step = 10 },
        .frames_rendered = .{ .hidden = true },
    } };
};
```

`Options(T)` holds a struct built with `@Struct`, with one `FieldOptions`
field per field of `T`, so the compiler itself rejects a misspelled field
name: `no field named 'volum' in struct
'zui_reflect.FieldOptionsOf(Settings)'`. zui_reflect adds its own errors
for:
- a `zui_inspector` declared without the type, which would otherwise
  accept any misspelling;
- `min`, `max` or `step` on a field that is not a number;
- `min` above `max`, or a `step` that is not above 0;
- a visible field of a type it cannot edit, quoting the
  `.hidden = true` line that fixes it.

It lives outside the core because most applications will not need it.

---

## 16. Roadmap

| Version | Scope | Exit criteria |
|---|---|---|
| 0.1 | Context, memory, element declaration, sizing passes, text wrapping with the cache, render commands, golden and invariant tests | all §14.1 tests pass; zero allocations per frame |
| 0.2 | input, hover/press/click/focus, clipping, scrolling, floating elements, the state table | the interaction tests pass; a reference raylib backend renders the example application |
| 0.3 | TaskPool, the completion queue, `needsFrame`, frames in flight with a render thread | a thumbnail-grid example cancels off-screen loads, and an idle application uses 0% CPU |
| 0.4 | `zui_widgets` (button, checkbox, slider, text field), `zui_reflect`, `zui_testing` snapshots | the widget set is built on the public API only (enforced by the module boundary, §3) |
| 0.5 | parallel measurement; benchmarks that meet the §6.5 targets | targets met on a 2020 desktop core; CI reports them (§14.3) |
| 0.6 | measure and audit: CI counts instructions under Callgrind, for a build with a fixed `-Dcpu` and a fixed number of frames per scenario, and fails on more than 2% growth over the parent commit; `zig build bench-compare -- <ref>` alternates two commits locally and reports the median ratio with its spread; the async audit; task completions applied at `beginFrame` (principle 8); the input event log specified and prototyped behind today's API; startup benchmarks; `-Dzui-trace` | the instruction counts repeat exactly between runners; the local comparison catches the `depth: u16` stall fixed in `946405e`; an off trace build's instruction counts are unchanged; input over the event log costs no more than today |
| 0.7 | the contracts (the breaking release): renderer and host contracts, `Surface`, host events, conformance suites, `zui_app`; letter spacing through a `MeasureKey`; display scale and zoom; input as an ordered event log with many pointers; the raylib adapter host | every backend passes the conformance suites and runs the demo through `zui_app`; a click inside one frame is kept |
| 0.8 | the first native host, Windows, with the system material behind the window | the demo runs on it unchanged, passes the host suite and idles at 0% CPU |
| 0.9 | feeds (with `TaskPool` as a feed that delivers once), the relay tap, `zui_wire`, replay, rendering in another process, file watching | task tests pass unchanged; a recorded session replays to identical commands |
| 0.10 | text and layout: the single-line wrap fast path, a whole-string metrics cache, `.growEqual`, aspect ratio and natural sizes, dividers, decorated images, floating options (§6.4), right-to-left layout, flex wrap, drag and drop, the next-frame deadline, gestures with arbitration and momentum | golden, snapshot and interaction tests for each; warm text faster by 0.6's measure; no change to the other §6.5 scenarios beyond noise |
| 0.11 | effects: gradients, shadows, glow, backdrop blur, transforms, materials, each lowered for renderers without it; HDR and wide-gamut color | lowering tested for each; one renderer draws each |
| 0.12 | `zui_debug` over a read-only `Frame.inspect`; the semantics list (§7.6); `-Dzui-safety` (§3); a demo running in a browser | the inspector driven by `zui_testing` over the Documents view; the Windows host bridges semantics to UI Automation |
| 0.13 | macOS, Linux and web hosts; notifications, dialogs, URLs and menus; native and custom window decorations; more than one window | each host passes the host suite and runs the demo unchanged |
| 0.14 | `zui_motion` (tweens over `state` and `dt_seconds`), opt-in exit animations | tweens tested frame by frame; an idle application still sleeps; a full ghost buffer is reported like other limits (§13.2) |

| 0.15 | text field: selection, word movement, clipboard, multiple lines, IME | `zui_testing` tests for each; IME on Windows |
| later | docking, a grid layout, layout islands, static subtrees, SIMD | each one ships only with a measured win or a demonstrated need |

[ROADMAP.md](ROADMAP.md) breaks each release into items, with what
grounds each one and how it is judged.

**Static subtrees** (later, opt-in) are a tree described as a comptime
value, whose layout is computed during the build and stored as a constant
command array, for fixed toolbars and HUD frames. They are deferred
because the lesson measured the costs (about 2 µs per comptime iteration;
5× code size for unrolling), and the win only exists for subtrees with
no text measurement, or with text in fonts whose metrics are embedded with
`@embedFile`.

---

## 17. A complete minimal application

```zig
const std = @import("std");
const zui = @import("zui");
const Backend = @import("zui-raylib");

const Ui = zui.Context(.{ .max_elements = 2048, .ImageHandle = Backend.Texture }, Backend.Platform);

const ids = zui.ids(.{ "root", "sidebar", "content", "save" });

pub fn main(init: std.process.Init) !void {
    var backend = try Backend.open(init.gpa, "zui demo", .{ 1280, 720 });
    defer backend.close();

    var ui = try Ui.init(init.gpa, init.io, &backend.platform);
    defer ui.deinit(init.gpa);

    var saved_count: u32 = 0;
    while (backend.pollEvents(ui.needsFrame())) |input| {
        ui.beginFrame(input);
        {
            ui.open(.{ .id = ids.root, .layout = .{ .direction = .left_to_right, .sizing = .grow_both } });
            defer ui.close();

            ui.open(.{ .id = ids.sidebar, .layout = .{ .sizing = .{ .width = .fixed(240), .height = .grow } }, .background = .rgb(0x1e1e24) });
            ui.close();

            ui.open(.{ .id = ids.content, .layout = .{ .sizing = .grow_both, .padding = .all(16) } });
            defer ui.close();

            ui.open(.{ .id = ids.save, .interactive = true, .background = if (ui.hovered(ids.save)) .rgb(0x3a6ff7) else .rgb(0x2c55c4), .layout = .{ .padding = .symmetric(12, 6) } });
            ui.text("Save", .{ .color = .white });
            ui.close();
            if (ui.clicked(ids.save)) saved_count += 1;
        }
        const frame = ui.endFrame() catch ui.lastFrame();
        backend.render(frame.commands());
        ui.release(frame);
    }
}
```

The example uses one allocation for zui, a comptime-hashed id for every
interactive element, and a frame loop that sleeps when nothing changes.
Everything the renderer needs arrives as one slice.

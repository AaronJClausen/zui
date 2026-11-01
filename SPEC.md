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
measurement, it says so.

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

### Non-goals

These are out of scope for the core, permanently or until a later
version. Each has a reason:

| Not in core | Why | Where it goes instead |
|---|---|---|
| Rendering, windowing, input polling | they are platform-specific, and owning them would tie zui to one stack | backend packages, application code |
| Font rasterization, shaping | they are large, and the platform already has them | the `Platform.measureText` hook (§8) |
| A retained widget tree | immediate mode is the model; state lives in a small keyed table (§9) | — |
| CSS-style cascading styles | cascades cost time per element and hide where values come from | themes as plain structs (§12) |
| Animation system | easing policies vary by application | `dt`, plus per-id state slots (§9) |
| Flex wrap (`flex-wrap`) in v1 | it adds a pass and complicates shrinking | a later version (§16) |
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
  src/tasks.zig          TaskPool and the completion queue
  src/commands.zig       the RenderCommand union and emission
  src/debug.zig          the debug overlay (compiled out unless enabled)
zui_widgets/             optional module: button, checkbox, slider, text field
zui_reflect/             optional module: struct inspectors generated with @typeInfo
zui_testing/             optional module: command snapshots, layout invariant checks
```

Backends (`zui-raylib`, `zui-sokol`, `zui-terminal`) are separate packages
that depend on `zui`. They are never dependencies of it.

Build options, exposed as a `zui_options` module through `b.addOptions`:

| Option | Default | Effect |
|---|---|---|
| `-Dzui-debug=bool` | `false` | compiles in the debug overlay and the duplicate-id names (§13). Otherwise those code paths are not analyzed at all. |
| `-Dzui-safety=bool` | follows `std.debug.runtime_safety` | the invariant sweeps in §14 |

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

The index types are computed from the limits with `@Int`. For example,
`ElementIndex = SmallestUnsignedFor(max_elements)`, so the default
configuration uses 13-bit indices padded into `u16` fields. Smaller
indices mean denser arrays.

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
| `parent`, `first_child`, `next_sibling` | `ElementIndex` | every pass |
| `child_count` | `ElementIndex` | sizing passes |
| `layout` | `u32` index into the layout-config array, or `none` | sizing and positioning |
| `decoration` | `u32` index, or `none` | command emission |
| `content` | a tagged index: `none`, text, image, custom | text wrapping, emission |
| `flags` | `packed struct(u16)`: clips, scrolls, floating, interactive, has_semantics, ... | every pass |
| `size` | `[2]f32` | sizing passes |
| `min_size` | `[2]f32` | the shrink pass |
| `position` | `[2]f32` | positioning, hit testing |

Config structs are stored once, in separate arrays per kind, and
elements refer to them by index. An element without decoration costs no
decoration memory. This is the same idea as Clay's separate config
arrays, and it keeps the per-element core at about **48 bytes**: an
8-byte id, seven 2-byte links and indices, a content-kind byte, and 24
bytes of geometry.

The arrays are *reserved* for the worst case, though. Every config kind
gets `max_elements` slots, and commands and lines get
`max_render_commands`, so the reservation is much larger than the core.
Measured for the default `Config` in 0.2: **1.79 MiB per frame in flight,
and 4.29 MiB of `required_bytes`**. That covers two frames, the text
cache, the state table (96 KiB) and the previous frame's interaction
results (480 KiB, §7.4). A
frame only *touches* the slots it uses, so the cost per frame still scales
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
   - Drains the task completion queue without blocking (§10.3).
   - Advances the state table's generation counter (§9).
   - Resolves interaction against the **previous** frame's hit regions:
     hover, press and release, the focus target, and the scroll target.
     Results are kept by id for the queries in §7.4.
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

### 6.2 Passes

All passes iterate over the element arrays in declaration (pre-) order or
in reverse. None of them recurses.

| # | Pass | Direction | Work |
|---|---|---|---|
| 1 | fit widths | reverse order (children before parents) | each `fit` width becomes the sum of its children along its axis (or their maximum across it), plus padding and gaps, clamped to min/max. Text contributes the width of its longest word as its minimum and its unwrapped width as its preferred width. |
| 2 | distribute widths | forward (parents before children) | inside each parent along the width axis: `percent` and `fixed` children first, then free space goes to `grow` children by weight. If the children overflow, they shrink: the largest shrinkable child shrinks first until it matches the next largest (Clay's approach), never below its minimum. |
| 3 | wrap text | each text element | with its width now known, the text is wrapped into lines (§8.2), which fixes its height. |
| 4 | fit heights | reverse | as pass 1, for heights. |
| 5 | distribute heights | forward | as pass 2, for heights. |
| 6 | position | forward | each child's position follows from its parent's content box, its alignment, the gap and the scroll offset. Floating elements are positioned relative to their attach target (§6.4). |
| 7 | emit | forward, then per z-layer | render commands, clip regions, hit regions (§7.5). |

Widths are settled before heights because text wrapping needs the width,
and the height depends on the wrap. This is the one ordering constraint,
and it is why the passes come in pairs.

Each pass is a tight loop over two or three arrays. Text wrapping is the
only per-character work, and it runs once per text element.

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
to the next container outward, as in browsers.

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

These are **targets**, to be verified by the benchmark suite in §14.3
before v1:
- **4,096 boxes, depth 8, no text:** layout and emission under 100 µs on
  a 2020-era desktop core.
- **1,000 text elements averaging 40 characters, all measurements cached:**
  under 250 µs.
- **Allocation:** zero after `init`, verified by running the benchmarks
  under a failing allocator.

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
  beneath it, but it is never pressed, clicked or focused. `text` copies its content into the frame arena, so the caller's
buffer may be reused immediately.

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
pub fn requestFocus(self: *Self, id: Id) void            // takes effect at the next beginFrame
pub fn widgetState(self: *const Self, id: Id) WidgetState
pub fn pointerLocal(self: *const Self, id: Id) ?[2]f32   // pointer relative to the element's last rect
pub fn rectOf(self: *const Self, id: Id) ?Rect           // last frame's layout result
pub fn pointer(self: *const Self) ?[2]f32
pub fn keyPressed(self: *const Self, key: Key) bool
pub fn modifiers(self: *const Self) Modifiers
pub fn typedText(self: *const Self) []const u8
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
run ahead of the renderer by more than `frames_in_flight` frames. Until
0.3, when this waiting arrives, `beginFrame` panics if every frame is
still held.

Each arena owns everything its frame references (element arrays, copied
text, commands), so the two threads share no mutable memory.

### 10.3 Tasks: async work owned by the UI

A *task* is background work whose lifetime follows an element. A typical
example is a thumbnail that loads while its list item is visible, and is
canceled when the item scrolls away.

```zig
pub fn TaskPool(comptime Result: type, comptime capacity: u16) type

var thumbnails: zui.TaskPool(LoadError!Image, 64) = .init;

fn thumbnail(ui: *Ui, path: []const u8, index: usize) void {
    const id: zui.Id = .indexed("thumbnail", index);
    ui.open(.{ .id = id, .layout = .{ .sizing = .{ .width = .fixed(96), .height = .fixed(96) } } });
    defer ui.close();

    switch (thumbnails.request(ui, id, loadImage, .{path})) {
        .pending => ui.box(.{ .background = theme.placeholder, .layout = .{ .sizing = .grow_both } }),
        .ready => |image| ui.image(image, .{ .layout = .{ .sizing = .grow_both } }),
        .failed => |err| ui.text(@errorName(err), theme.error_text),
    }
}
```

The pool is **typed** by its result, which removes type erasure and casts
at the call site. Its capacity is fixed, so a pool cannot grow without
bound. Tasks run on the `Io` given to `Context.init`. How
`request(ui, id, function, args)` works:
1. **First request for an id.** Claim a slot, then start the work with
   `io.concurrent`, falling back to `io.async` when the `Io` reports
   `ConcurrencyUnavailable`. Running it in a wrapper means that when
   `function` returns, the wrapper stores the result in the slot, pushes
   the slot index onto the context's completion `Io.Queue` (with
   `putOneUncancelable`, so a completion is never lost), and calls
   `Platform.wake` if the platform has it. The function returns
   `.pending`.
2. **Later requests for the same id** return the slot's current state:
   `.pending`, `.ready`, or `.failed`. They do not block and do no
   work.
3. **`beginFrame` drains the completion queue** with
   `get(buffer, min = 0)`, which never blocks, and marks each completed
   slot `.ready`. Results become visible at a frame boundary, which keeps
   one frame internally consistent.
4. **Unmounting.** In `endFrame`, any slot whose id was not requested this
   frame has its `Future` canceled with `future.cancel(io)`. The task sees
   `error.Canceled` at its next cancelation point, and the slot is freed
   once the wrapper finishes. `Future.cancel` is not thread-safe, and only
   the UI thread calls it, which fits the contract in §10.1.
5. **Retry and invalidation.** `request` takes an optional `key: u64`,
   such as a hash of `path`. A changed key cancels the old task and starts
   a new one. This is how a list item that is reused for different data
   gets fresh work.

`Io.Future` has `await` and `cancel` but no non-blocking poll, which is
why completion goes through the queue instead of each frame asking the
futures.

**Redraws on demand.** `ui.needsFrame()` is true when any of these hold:
- the last input changed interaction state (hover, press or focus moved);
- a task completed since the last frame;
- a scroll inertia or caret blink is in progress;
- the application called `ui.requestFrame()`.

An event loop that waits on platform events, plus `wake`, can sleep the
rest of the time. An idle zui application uses no CPU.

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
2. **Parallel measurement (v1.x).** On a frame with many cache misses,
   such as the first frame or a font change, pass 3 first collects the
   distinct missing (word, font, size) keys, measures them in chunks across
   an `Io.Group`, writes them into the cache, and only then wraps. This
   requires `measureText` to be thread-safe, which the platform declares
   with `pub const thread_safe_measure = true;`, a comptime flag. Below a
   threshold of missing keys (default 256), it measures inline, because
   task overhead would exceed the work.
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

With `-Dzui-debug`, `Id.of` keeps its name in a comptime table that is
linked only in debug builds, so messages read
`duplicate id "save" (from toolbar and from file_menu)`, not a hex hash.

### 13.2 Capacity limits (defined behavior, reported)

Elements, text bytes, depth, render commands (including wrapped lines),
state slots, task slots and the measurement cache all fail the same way:
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

- **Layout invariants**, checked by `zui_testing.checkInvariants(frame)`:
  - each child lies within its parent's clip box, unless it is floating;
  - the sizes of `grow` siblings are proportional to their weights,
    except where a min/max clamp applies;
  - no size is negative or NaN;
  - commands are in nondecreasing z order.
- **Randomized trees.** A seeded generator builds random trees of 1–5,000
  elements with random sizing rules, and runs the invariant checks on each
  (the same approach as the model-checked table in the asserts lesson).
- **Golden layouts.** About 50 hand-written trees with exact expected
  rectangles, covering every sizing rule, alignment, padding, gap, wrap
  mode and floating anchor.
- **Allocation discipline.** Every test runs with a failing allocator after
  `init`, which proves that frames do not allocate.
- **Compile-time guarantees** through `expect_errors` in `build.zig`, as
  in the comptime lesson: an invalid `Config`, a platform missing
  `measureText`, an `Id` collision in `zui.ids`, calling `custom` with
  `CustomData = void`, and an oversized state type. Each is pinned to its
  exact message (remember that `contains` matches line *endings*).

### 14.2 Tools for applications

- `zui_testing.snapshot(frame, writer)` writes the commands as stable text
  (`rect id=toolbar x=0 y=0 w=800 h=40 color=#202020`), for golden-file
  tests of application UIs.
- A **recording platform** with deterministic text metrics (each byte is
  8×16 units), so application tests don't depend on fonts.
- `ui.simulate(.{ .click = id })` creates the input that clicks an
  element's center in its last frame, for interaction tests that don't
  hard-code coordinates.

### 14.3 Benchmarks

`zig build bench`, in ReleaseFast, covers:
- the §6.5 targets;
- a deep tree (depth 64);
- a wide tree (one parent with 4,000 children);
- text-heavy frames with the cache cold and warm;
- frames-in-flight pipelining throughput.

It reports nanoseconds per element and the allocation count (which must
be 0). A regression of more than 10% against the stored baseline fails CI.

---

## 15. Extension points

| To... | Use |
|---|---|
| draw something zui does not know | `custom(data, config)`, with your `CustomData` |
| size a custom leaf from its content | `.layout.sizing = .fixed(...)` from your own measurement, or a `Platform.measureCustom(data) [2]f32` hook (optional declaration) |
| add widgets | functions over the public API; see `zui_widgets` for the reference set |
| bridge accessibility | `Frame.semantics()` (§7.6) |
| animate | `state(id, T)` for per-element animation state, plus `Input.dt_seconds` |
| render | iterate `Frame.commands()`; backends are ordinary packages |
| debug visually | `-Dzui-debug` adds `ui.debugOverlay()`, which declares an inspector panel showing the hovered element's id, rect and config |

`zui_reflect.inspector(ui, id, &value)` declares an editor for any
struct: checkboxes for bools, sliders for bounded integers, dropdowns for
enums, and nested panels for structs. It walks `@typeInfo`, as the
lesson's flag parser did. Labels, ranges and hidden fields come from a
**typed** `pub const zui_inspector: zui_reflect.Options = .{...}`
declaration, and misspelled options are compile errors. It lives outside
the core because most applications will not need it.

---

## 16. Roadmap

| Version | Scope | Exit criteria |
|---|---|---|
| 0.1 | Context, memory, element declaration, sizing passes, text wrapping with the cache, render commands, golden and invariant tests | all §14.1 tests pass; zero allocations per frame |
| 0.2 | input, hover/press/click/focus, clipping, scrolling, floating elements, the state table | the interaction tests pass; a reference raylib backend renders the example application |
| 0.3 | TaskPool, the completion queue, `needsFrame`, frames in flight with a render thread | a thumbnail-grid example cancels off-screen loads, and an idle application uses 0% CPU |
| 0.4 | `zui_widgets` (button, checkbox, slider, text field), `zui_reflect`, `zui_testing` snapshots | the widget set is built on the public API only |
| 0.5 | parallel measurement; benchmarks that meet the §6.5 targets | targets met in CI |
| later | layout islands, flex wrap, static subtrees | each one ships only if the benchmarks show a win |

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

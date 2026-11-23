# 11-polish: Polish

Stage 11 of SPEC.md §21: `zui_motion` and exit ghosts; full text editing
with IME; `zui_color`, `zui_icons`, skins and theme packs; samples and
the template. Its items are numbered in the queue's dependency order,
and each is given its Grounding, Plan and Done when as it is taken.

**Done when (each):** `zui_testing` coverage; IME works on Windows.

**Spec.** §19.2, §19.8, §19.9.

## Items

| Item | Status |
|---|---|
| `11-polish:01-zui-motion` `zui_motion` | done |
| `11-polish:02-exit-animations` Exit animations | done |
| `11-polish:03-zui-color` `zui_color` | done |
| `11-polish:04-skin-contract` The skin contract | done |
| `11-polish:05-default-skin` The default skin | retired: merged into `11-polish:19-default-design` |
| `11-polish:06-text-editing` Text editing | not started |
| `11-polish:07-zui-icons` `zui_icons` | not started |
| `11-polish:08-zui-themes` `zui_themes` | not started |
| `11-polish:09-template-project` The template project | not started |
| `11-polish:10-samples` Samples | not started |
| `11-polish:11-profiling-guide` A profiling guide | done |
| `11-polish:12-developer-experience-audit` A developer-experience audit | not started |
| `11-polish:13-design-vocabulary` The design vocabulary and the appearance contract | done |
| `11-polish:14-zui-design` `zui_design`: tokens from seeds and preferences | done |
| `11-polish:15-type-scale` The type scale | done |
| `11-polish:16-corner-shapes` Corner shapes | done |
| `11-polish:17-nested-corners` Nested corners | done |
| `11-polish:18-system-accent` The system's accent color | done; the Windows host's part waiting on CI |
| `11-polish:19-default-design` The default design | done |
| `11-polish:20-appearance-audit` The appearance audit | done |
| `11-polish:21-permutations` Every permutation of a component | done |
| `11-polish:22-appearance-review` The appearance review | not started |
| `11-polish:23-design-workbench` The design workbench | not started |
| `11-polish:24-the-tour` The tour, redone | done |
| `11-polish:25-focus-ring-on-fills` A focus ring that shows on a filled control | not started |
| `11-polish:26-small-targets` Targets of at least 24 units in the tour | not started |
| `11-polish:27-essential-inputs` Essential inputs | not started |
| `11-polish:28-containers-and-navigation` Containers and navigation | not started |
| `11-polish:29-overlays` Overlays | not started |
| `11-polish:30-feedback-and-media` Feedback and media | not started |
| `11-polish:31-rich-text-and-reordering` Rich text and the reorderable list | not started |
| `11-polish:32-zui-widgets-data` `zui_widgets_data` | not started |
| `11-polish:33-pickers` Pickers | not started |
| `11-polish:34-zui-widgets-views` `zui_widgets_views` | not started |
| `11-polish:35-italics` Italics | not started |
| `11-polish:36-motion-in-core` Motion in the core | done |

### The design system

Items 13 to 23 build SPEC.md §18: a design system that makes an
accessible, coherent app the easy path. They replace the default skin
(`11-polish:05-default-skin`, retired into
`11-polish:19-default-design`) and turn `11-polish:08-zui-themes` into
seed sets, so they come ahead of the rest of stage 11. The owner's
decisions are under *Made* in `roadmap/decisions.md`.

How the pieces divide, given that modules cannot import one another
(SPEC.md §3.3):

- **The core** holds the vocabulary that every piece speaks: roles,
  tiers, the appearance contract and its check, `Design`, what an
  application or a theme pack declares, and `Tokens`, the resolved
  values. It also gains the corner shapes and nested corners, which
  emission and the renderers need.
- **`zui_design`** makes `Tokens`: palettes from seeds, contrast
  solving, color vision, density, the type scale. It also audits a frame
  and lists a component's permutations.
- **`zui_widgets`** styles its controls from `Tokens` through
  `DesignSkin`, without importing `zui_design`.
- **`apps/review/`** is the review tool, an app that can import them
  all.

**The default design's components.** Items 27 to 34 build the 57
components of the default design, steps D4 to D11 of
`docs/plans/default-ui-designs/README.md`. Each component's approved
spec is its entry in `components` of
`docs/plans/default-ui-designs/exports/zui-default-design.json`: its
`api` is the starting signature, its `parts` the appearance each part
declares in roles, tiers and shapes, and its `variants`, `states` and
`keyboard` the behavior. A value the spec names as a role, a tier, a
control height, an icon size, a shape role or an elevation is read from
`Tokens`; a literal is a named constant of the skin. Every item:

- adds its widgets to `Widgets(Ui, Skin)`, with `Part` tags and
  `DesignSkin`'s appearance for each, or to its module's equivalent,
  with semantics, keyboard operation and accessibility actions, as
  SPEC.md §19.2 requires of every control;
- declares a `zuiPreviews` for each component, so `Permutations` and the
  review app see it, and exercises each generic API in
  `core/tests/instantiate.zig`;
- puts a screen, or a section of one, in the tour where a user would
  meet it;
- adds its widgets to SPEC.md §19.2's table and an entry for each group
  to the feature tour, with an example in an app's own code.

Each is **done when** `zui_testing.Driver` tests cover every state and
key its specs list; the audit is clean for each component's `glance`
permutations in every scheme and density; nothing is allocated after
`init`; `counts` stays within 2% of the parent commit for the scenarios
that use none of its widgets; and `test-all` and `check-all` pass.
`zui_widgets_data` and `zui_widgets_views` are modules, so each also
follows CLAUDE.md's row for a module, and since modules cannot import
one another (SPEC.md §3.3), each takes a `Widgets` value as `anytype`
rather than importing `zui_widgets`. The two other personalities the
design sketched, in `docs/plans/default-ui-designs/personalities/`, are
reference for `11-polish:08-zui-themes` and `11-polish:10-samples`, not
items.

---

## 11-polish:01-zui-motion — `zui_motion`

Tweens over `state(id, T)` and `dt()`, requesting frames by instant and
finishing at once under `reduced_motion`.

**Grounding.** Everything a tween needs is public on a context:
`ui.state(id, T)` (`core/src/context.zig:2691`) gives per-element state,
created zeroed and kept while the id keeps being used, and returns
zeroed scratch while reporting `.state_slots` when the table is full
(`:2694`), so a tween's state must mean "at rest" when zero; a state
type is at most 64 bytes (`core/src/state.zig:4`, `:13`). `ui.now()` and
`ui.dt()` (`core/src/context.zig:1272`, `:1278`) read the record's
clock, 0 for `dt` on the first frame. `ui.requestFrame()` and
`ui.requestFrameAt(instant)` (`:1180`, `:1185`, keeping the earliest)
feed `nextFrame` (`:1173`), and both are cleared at each `beginFrame`
(`:981`). `zui.Instant` (`core/src/record.zig:7-38`) has `addSeconds`,
`secondsSince` and `isBefore`. `ui.environment().reduced_motion`
(`core/src/input.zig:314`) arrives as an `.environment` event.
`Color.mix` (`core/src/style.zig:51`) interpolates sRGB channels. The
modules are registered at `core/build.zig:206-220` (`b.addModule`),
`:227` (`tested_modules`), `:232` (driven tests), the compile-error and
`check` imports, and `formatted_paths`; `.paths` in
`core/build.zig.zon`, and `core_modules` in the root `build.zig:35`.
`zui_testing.Driver` (`core/zui_testing/zui_testing.zig:71`) advances
`now` by `frame_interval_ns` per frame.

**Plan.** One slice, a module `zui_motion` built only on the public API,
adding nothing to the core:

- `Easing`: `linear` and cubic `ease_in`, `ease_out` and `ease_in_out`,
  each exact at 0 and 1.
- `tween(ui, id, T, target, options)`: the first target is where it
  starts; a new target starts a tween from the current value, so a
  retarget is continuous; it eases over `duration` from an instant held
  in its state, so it lands exactly at its duration, and it asks for the
  next frame while moving, for a frame at the instant a `delay` ends,
  and for none at rest.
- `spring(ui, id, T, target, options)`: a critically damped spring
  stepped exactly by `dt()`, keeping its velocity across retargets,
  landing within `rest_distance`; the frame it leaves rest it does not
  advance, since the time since the previous frame was spent at rest.
- Under `reduced_motion` both land on the target in the frame it
  changes.
- A value is `f32`, `[N]f32`, `zui.Color` (per sRGB channel, as
  `Color.mix`; `11-polish:03-zui-color` may refine it),
  `zui.ExtendedColor` (per linear channel), or a struct of them; any
  other type is a compile error, pinned by
  `core/tests/compile_errors/motion_value_not_animatable.zig`.
- Registered at every point a module is, exercised in
  `core/tests/instantiate.zig`, and documented in the README, the
  feature tour and ARCHITECTURE.md. SPEC.md §19.9 says how frames are
  asked for.

**Done when.** Core's tests in Debug, ReleaseFast, ReleaseSafe and on
`x86-linux` pass, with `zui_motion`'s own: a tween reaches its target at
its duration, asking for every frame until then and none after; the
easings' endpoints are exact; under `reduced_motion` a tween and a
spring land in one frame without asking for another, and a moving tween
lands when it turns on; a retarget starts from the value the old tween
had reached; a delayed tween asks for the instant it starts; a full
state table reports `.state_slots` and the tween returns its target;
colors and structs are tweened per channel and field; a spring never
overshoots and stops asking at rest. `check` passes natively, for
`wasm32-freestanding` and `powerpc-linux`, and `check-all` passes, so
the root re-exports `zui_motion`. No allocation and no change under
`core/src/`.

**Spec.** §19.9.

**Status.** Done: `core/zui_motion/` with `Easing`, `tween` and
`spring`, 12 tests and one compile-error case, in Debug, ReleaseFast,
ReleaseSafe and `x86-linux`; `check` natively, for `wasm32-freestanding`
and `powerpc-linux`, and `check-all`, pass. Nothing under `core/src/`
changed, so no hot path moved and instruction counts were not taken.
SPEC.md §19.9 now says a tween asks for the next frame while it moves
and for an instant only when delayed: frames during motion come at the
display's rate, which only the host knows. Exit animations are
`11-polish:02-exit-animations`.

## 11-polish:02-exit-animations — Exit animations

`Element.exit` and the ghost buffer.

**Grounding.**

- SPEC.md declares the feature and the code has none of it: §5 lists
  `exit_ghost_commands: u32 = 0`, §10.1 `Element.exit_seconds: f32 = 0`,
  §19.9 says an element with `exit_seconds` "keeps emitting its last
  commands, taking no space and receiving no hits", and §17.2 names
  ghost commands among the limits.
  `grep -rn 'exit_ghost\|exit_seconds' core/src` is empty.
- `Limits` is `core/src/context.zig:90`, and `Limit` is
  `std.meta.FieldEnum(Limits)` (`:129`), so a new limit is a new
  `Diagnostics.needed` entry by itself. `Diagnostics` (`:131`) is held
  at 96 bytes: one byte more moved every array of `Frame` after it
  (`:137`, `:486`), and its fields already sum to 96, so a limit of 4
  bytes makes it 104.
- `Element` is `ElementWith` (`:186`); `chrome` (`:232`) is ignored
  without its feature so that a widget can declare it for every context.
  `ElementFlags` (`:253`) is a `packed struct(u16)` whose 16 bits are
  all taken, so an exiting element cannot be marked by a flag.
- `appendElement` is `inline` (`:1431`), so a field left at its default
  costs nothing; `chrome` and `semantics` are gathered there into lists
  beside the frame, in `FrameSlot` (`:771`), not in `Frame`, since a
  field added to `Frame` reorders its arrays. A scroll container without
  an id panics in safe builds and does not scroll (`:1665`), since its
  offset is stored by id.
- Emission (`core/src/emission.zig:52`) has one copy of its walk per
  frame kind (`:56-61`, `:63`), because any change to the walk moved
  `endFrame` by up to 5%. The walk visits each element in declaration
  order (`:94`), skips one that draws nothing (`:104`), opens a level
  for one that clips, has a border, floats, is a region or transforms
  (`enter`, `:279`), and pushes its border and `clip_end` on `leave`
  (`:539`), so before the layers are sorted (`:120`) an element's
  subtree is one contiguous run of commands. Hit regions and `rectOf`'s
  results are written only in `enter` (`:328`, `:331`).
  `reopenTransforms` (`:372`) begins the transforms around an element
  again on another layer.
- A text command's `content` points into its frame's `text_bytes`, which
  the next `beginFrame` on that slot overwrites; with
  `frames_in_flight = 1` that is the very next frame.
- `beginFrame` clears `frame_requested` and `requested_deadline`
  (`core/src/context.zig:981`), and `nextFrame` (`:1173`) reads them
  after `endFrame`, so `endFrame` can ask for the next frame itself.
  `Environment.reduced_motion` is `core/src/input.zig:314`.
- `zui_motion` (`core/zui_motion/zui_motion.zig`) animates an element
  only while it is declared; nothing keeps drawing one that is not.

**Plan.** One slice, in the core, all of it behind
`comptime limits.exit_ghost_commands != 0`:

- **The API** is `Element.exit: ?Exit`, in place of SPEC.md's
  `exit_seconds`, so that an element also chooses how its ghost leaves:
  `Exit = struct { seconds: f32, fade: ExitFade = .linear }`, and
  `ExitFade = enum { none, linear, ease_in, ease_out, ease_in_out }`,
  the eased ones cubic and exact at 0 and 1 as `zui_motion.Easing`'s
  are. `.none` holds the ghost unchanged for its seconds and then drops
  it. `exit` is ignored when `exit_ghost_commands` is 0, as `chrome` is
  without its feature, so a widget declares it for every context; no
  compile error. It needs an id, as a scroll container does: without one
  it panics in safe builds and is ignored in release, since an internal
  id changes when a sibling before it is added and the element would
  seem to exit. A `seconds` of 0, a negative or a NaN keeps no ghost.
- **What a ghost holds:** every command its element's subtree emitted in
  the last frame it was declared, in emission order (backgrounds,
  borders, dividers, text lines, images, customs, effects, its own clips
  and transforms), with each command's `z`. They are preceded by the
  transforms around it, begun again as `reopenTransforms` does, and by a
  `clip_begin` of the clip in effect around it, and followed by their
  ends, so the ghost is cut off and placed as it was. Text bytes are
  copied with it. An element inside another that exits in the same frame
  is drawn only as part of the outer ghost.
- **How it changes:** as its `fade` says. Over `seconds` from the `now`
  of the last frame its element was declared, a fading ghost multiplies
  the alpha of every color in its commands (fills, borders, text, tints,
  gradient stops, shadow colors, a material's fallback) by
  `1 - curve(t)`; customs, a material's handle, clips and transforms are
  unchanged. A `.none` ghost is copied into the frame as it is, with no
  alpha pass; a `.linear` one computes `1 - t` once per frame and runs
  no easing; an eased one evaluates its cubic once per frame. The fade
  is chosen by a switch per ghost per frame, not per command, so a
  context that never eases pays one branch per ghost and no comptime set
  of curves is declared. Overlapping commands of one ghost fade
  separately, so its text shows its background through it as both fade.
  SPEC.md §19.9 gains these sentences.
- **Knowing an element exited:** each candidate (an element declared
  with an `exit` of positive seconds and an id) is listed in `FrameSlot`
  as it is declared, in declaration order, beside its `Exit`, as chrome
  is. The walk compares each element's index with the next candidate's,
  as it does the next effect's (`emission.zig:98-102`), and a candidate
  opens a level, so its `leave` copies the run of commands its subtree
  emitted into the context's snapshot store. At the end of the next
  frame, each snapshot whose id that frame's `lookup` does not find
  becomes a ghost. Cost when on: one index comparison per element in the
  walk, a copy of each candidate's commands per frame, one `lookup` per
  snapshot and per ghost. Cost when off: none; the comparison, the level
  and the store are `comptime`-removed.
- **The stores:** two of `exit_ghost_commands` commands each, in
  `Memory`, alternating by frame: one is written with this frame's
  snapshots and then the live ghosts (carried and newly exited, oldest
  first), while the other holds the last frame's. Each keeps its text in
  `max_text_bytes` of its own. Nothing is allocated; with the limit at 0
  they are zero-sized.
- **Where ghosts are drawn:** after the walk and before the layers are
  sorted, each live ghost's commands are pushed into the frame at their
  own `z`, through `switchLayer`, so each lands in its last layer, over
  everything declared in that layer this frame, a newer ghost over an
  older one. They take no space, since layout never sees them, and no
  hits, since no region or result is written for them: `rectOf` of their
  id is null. They count against `max_render_commands`, and their text
  is copied into the frame's `text_bytes` and counts against
  `max_text_bytes`, so a frame a renderer holds never points into a
  store that is rewritten. A ghost does not follow a container that
  scrolls or moves after it exited, and is unaffected when its ancestors
  also exit: it keeps the clip and transforms it had, as the box around
  the clip in the innermost transform's units.
- **Frames:** while a fading ghost lives `endFrame` calls
  `requestFrame`, since it changes every frame; a `.none` ghost asks
  only for a frame at the instant it ends, with `requestFrameAt`. A
  ghost whose time is up, or whose id is declared again, is dropped
  before it is drawn; the frame after the last one is dropped asks for
  nothing. Under `reduced_motion` no snapshot is kept and every ghost is
  dropped at once.
- **Limits:** a snapshot or ghost whose commands or text do not fit its
  store is not kept, and the frame records `.exit_ghost_commands` in
  `diagnostics.exceeded`, the commands it needed in `needed`, and its id
  in `first_dropped_id`, as §17.2 says. The rest are kept. A subtree
  that lost commands to `max_render_commands` keeps no snapshot, since
  its clips might not end.
- **Kept free when off:** `Diagnostics` grows with a new limit whatever
  its value, so before anything else the `Limits` field was added alone
  and counts were compared with `dfe65ed`. The rest is gated on the
  limit, so the walk and `appendElement` compile as before, and every
  instruction count of `zig build counts -- --compare` must be
  identical.
- Tests in `core/src/tests/exit_animations.zig`, the API in
  `core/tests/instantiate.zig` with ghosts on, the feature tour, and
  SPEC.md §5, §10.1, §17.1 and §19.9.

**Decisions.** Made by the owner when `11-polish:02-exit-animations` was
taken:

- An element chooses how its ghost leaves, and pays only for that
  choice: `.none` runs no alpha code, `.linear` no easing. A runtime
  switch per ghost was kept over a comptime set of fades, since it costs
  one branch per ghost per frame.
- Ghost text has no limit of its own: each store keeps it in
  `max_text_bytes`, and text that does not fit is reported as
  `.exit_ghost_commands`. A second limit would have made `Diagnostics`
  97 bytes.
- `exit` without an id panics in safe builds and is ignored in release.
- `Diagnostics.first_refusing_source` became a `[*:0]const u8`, so
  `Diagnostics` stays at 96 bytes with the new limit. With the field
  added and `Diagnostics` at 104 bytes, every declaration executed 2 to
  4 instructions more (4096 boxes declare 436,605 → 436,607), the 3000
  cells' 53 more and 1000 new strings' 101 fewer, from the frame's reset
  of a larger `Diagnostics`.

**Done when.** Core's tests pass in Debug, ReleaseFast, ReleaseSafe and
on `x86-linux`, with the exit animations' own: an element that stops
being declared keeps drawing for its `seconds` and then not, unchanged
with `.none` and at each curve's alpha with a fade; it takes no space
and no hits and `rectOf` does not find it; its text survives the frame
it came from being reused, with `frames_in_flight = 1`; it keeps its
layer and the clip and transforms around it; a nested candidate is drawn
once; it is dropped when declared again; every frame is asked for while
a ghost fades and none after; `reduced_motion` drops it at once; a full
store keeps what fits and reports the limit; `exit` is ignored with the
limit at 0. `check` passes natively, for `wasm32-freestanding` and
`powerpc-linux`; `test-all` and `check-all` pass; and every instruction
count of `zig build counts -- --compare` against `dfe65ed` is identical.

**Spec.** §5, §10.1, §17.1, §17.2, §19.9.

**Status.** Done:

- `Element.exit`, `zui.Exit` and `zui.ExitFade` (`core/src/exit.zig`),
  behind `limits.exit_ghost_commands`. Candidates are listed beside the
  frame; emission keeps each one's commands as a snapshot when its
  subtree ends, and after the walk draws every ghost still leaving at
  the end of its layer. 13 tests in
  `core/src/tests/exit_animations.zig`, in Debug, ReleaseFast,
  ReleaseSafe and `x86-linux`; `check` natively, for
  `wasm32-freestanding` and `powerpc-linux`; `test-all` and `check-all`.
- `Diagnostics.first_refusing_source` is a `[*:0]const u8`, so
  `Diagnostics` stays at 96 bytes with the new limit.
- `01-measure:03-instruction-counts-in-ci`, measured here against
  `dfe65ed` with the limit at 0: all 35 instruction counts are identical
  (4096 boxes declare 436,605 and `endFrame` 1,264,648). Simulated
  misses moved in 20 rows, every one within 2% but four: 4096
  interactive boxes' `endFrame` branch misses 19,844 → 20,868 (+5.2%),
  the documents view's declaration I1 misses 25 → 27 and its
  `endFrame`'s 32 → 31, and the 3000 cells' `endFrame` I1 misses 0 → 5.
  The same rows moved by the same amounts with only the limit and the
  smaller `Diagnostics` in place, so they come from the reservation's
  new layout, not from the ghosts' code. Timings were not taken; with
  counts identical none were needed.
- SPEC.md §10.1 names the field `exit: ?Exit` in place of
  `exit_seconds`, since an element also chooses its fade; §19.9 says
  what a ghost holds, where it is drawn, how it fades and which frames
  it asks for; §17.1 lists `exit` without an id; §5 says the ghosts'
  text is kept in `max_text_bytes`.

## 11-polish:03-zui-color — `zui_color`

OKLab, OKLCH and HSL, mixing and palettes, at comptime.

**Grounding.** `zui.Color` (`core/src/style.zig:30`) is four
sRGB-encoded bytes with straight alpha, written `.rgb(0x3366ff)`
(`:41`); `Color.mix` (`:51`) interpolates the encoded channels, and
`Color.mixOklab` (`:74`) goes through an OKLab of the core's own, which
is private (`:178`) with its transfer functions (`:218`, `:223`), so a
gradient's `colorAt` can mix in it without a module. `zui.ExtendedColor`
(`:105`) is linear scRGB in `f16`, with `fromColor` and `toColor`
(`:129`, `:135`), so OKLab reaches it without a transfer function and
without clamping. Nothing public converts to OKLCH or HSL, makes a
palette, or maps a color outside sRGB back into it except by clamping
each channel (`:223`), which shifts its hue. `std.math.cbrt`,
`std.math.pow` and `std.math.atan2` all run at comptime, but every call
there counts against the branch quota, and `pow` makes hundreds, so a
handful of conversions would end a comptime block at the default quota
of 1000. A module is registered as `zui_motion` was: its `b.addModule`
(`core/build.zig:214`), `tested_modules` (`:227`), the compile-error and
`check` imports, `formatted_paths` (`:393`), `.paths` in
`core/build.zig.zon`, `core_modules` in the root `build.zig:35`, and the
README's import snippet and *Packages* table.

**Plan.** One slice, a module `zui_color` on the public API alone,
adding nothing to the core:

- `Oklab`, `Oklch` and `Hsl`, with `f32` fields named in full and a
  straight `alpha`, each converting to and from `zui.Color`; `Oklab` and
  `Oklch` also to and from `zui.ExtendedColor`, unclamped, and to and
  from each other; `Oklab` from and to linear sRGB with Björn Ottosson's
  matrices; `Hsl` as CSS Color 4 defines it, over encoded channels.
- `toColor` brings a color outside sRGB in by reducing its OKLCH chroma,
  by bisection, keeping its lightness and hue, rather than clipping.
- `mix` in OKLab and `mixOklch`, whose hue takes the shorter arc and
  whose grey end takes the other end's hue; alpha mixes linearly.
- Palettes: `ramp(steps, from, to)`, both ends included; `withLightness`
  and `shiftLightness` for a skin's hovered and pressed shades;
  `lightnessScale(steps, color, darkest, lightest)`, a tonal scale.
  Fewer than two steps is a compile error, pinned by
  `core/tests/compile_errors/color_ramp_too_few_steps.zig` and
  `color_lightness_scale_too_few_steps.zig`.
- At comptime, the sRGB transfer function is two tables of 256 built
  once, and a conversion raises the branch quota itself, so a block of
  hundreds of conversions needs no `@setEvalBranchQuota` of its own.
- Registered at every point a module is, and documented in the README
  and the feature tour; ARCHITECTURE.md's module list and §6 row follow.

**Done when.** Core's tests in Debug, ReleaseFast, ReleaseSafe and on
`x86-linux` pass, with `zui_color`'s own: sRGB's white, black, mid grey
and primaries land within 0.0005 of their published OKLab values, and
the primaries on their OKLCH chroma and hue; a grid of sRGB colors comes
back from OKLab, OKLCH and HSL within one 8-bit step; HSL matches CSS's
examples and wraps any hue; an `ExtendedColor` brighter than white goes
through OKLab unclamped; a mix's ends are its colors exactly and black
to white is `#636363`, as `Color.mixOklab`; OKLCH's hue takes the
shorter arc; a color outside sRGB keeps its lightness and hue and lands
on the gamut's edge; a ramp and a lightness scale are evenly spaced,
keep their ends and hue, and are the same at comptime as at run time; a
comptime block converts a hundred colors at the default quota; and both
compile-error cases. `check` passes natively, for `wasm32-freestanding`
and `powerpc-linux`, and `check-all` passes, so the root re-exports
`zui_color`. No allocation and no change under `core/src/`.

**Spec.** §19.8.

**Status.** Done: `core/zui_color/` with `Oklab`, `Oklch`, `Hsl`, `mix`,
`mixOklch`, `ramp`, `withLightness`, `shiftLightness` and
`lightnessScale`, 11 tests and two compile-error cases, in Debug,
ReleaseFast, ReleaseSafe and `x86-linux`; `check` natively, for
`wasm32-freestanding` and `powerpc-linux`, and `check-all`, pass. A
conversion costs a few hundred comptime branches; each raises the quota
to 200,000, so a hundred shades in one comptime block need nothing more.
Nothing under `core/src/` changed, so no hot path moved and instruction
counts were not taken. `core/tests/instantiate.zig` does not yet name
`zui_color`, so `check` type-checks it only through its tests, on the
host.

## 11-polish:04-skin-contract — The skin contract

`Widgets(Ui, Skin)` and `zuiStyle`, so a theme pack restyles every
widget without forking it.

**Grounding** (at `f77934b`). `zui_widgets` is `Widgets(UiType)`
(`core/zui_widgets/zui_widgets.zig:99`), a struct of two values,
`theme: Theme` and `dark_theme: ?Theme` (`:105-109`). `Theme`
(`:111-147`) is one flat struct of a text style, fifteen colors, a
`std.EnumArray(zui.WidgetState, zui.Color)` for control backgrounds, ten
metrics, the popup's layer and three indicator strings, shared by every
widget. `activeTheme` (`:159-162`) picks `dark_theme` while
`ui.environment().theme` is dark. Each widget reads the fields it wants
and decides per state in its own code: the checkbox's outline turns
`accent` while hovered or pressed (`:268`), the slider's thumb `accent`
while pressed and `disabled_text_color` while disabled (`:412-416`), the
disclosure draws a background only while hovered or pressed (`:198`), a
dropdown's option `option_highlight` or `selected_option` (`:699-702`).
The focus ring is `focusRingOr` (`:763-766`), a 2-unit border of
`theme.focus_ring` drawn in place of the element's border while
`ui.focused(id)`, which is also true while the element is hovered or
pressed, so it is not one of `widgetState`'s states
(`core/src/context.zig:2619-2625` checks disabled, pressed, hovered,
focused, in that order). Some metrics are fixed in the widgets: the
check mark's radius 2 and size `0.45 * checkbox_size` (`:281-286`), the
popup's padding and offset of 4 (`:678`, `:686`) and its options'
padding `horizontal_padding - 4` (`:708`). Text is styled by `textStyle`
(`:741-750`) in three tones, normal, muted and disabled;
`environment().text_scale` is read by no widget.

The callers: the tour builds a `Widgets.Theme` each frame from its
palette and the clamped `text_scale` (`apps/tour/src/kit.zig:141-169`)
and sets it as both themes (`:195`); its classic screen gets a theme of
one text style (`apps/tour/src/tour.zig:101`). The showcase holds
`zui_widgets.Widgets(Ui)` (`apps/showcase/zui_showcase.zig:68`),
restyles metrics for cells (`:302-311`), and reads
`widgets.theme.control` directly for a hover target (`:162`).
`zui_reflect` reads `widgets.activeTheme(ui).horizontal_padding`, `.gap`
and `.control_height` (`core/zui_reflect/zui_reflect.zig:141`, `:153`).
The rest name `Widgets(Ui)` and take its defaults:
`core/tests/instantiate.zig:136` (with `.dark_theme = .{}`),
`core/zui_reflect/tests.zig:20`, `core/zui_widgets/tests.zig:19`, `:437`
(which also read `widgets.theme.slider_thumb_size` and `.gap` at `:129`,
`:150`, `:159`, `:250`, `:293`, and test `dark_theme` at `:370-377`),
`hosts/native/examples/accessible.zig:18`, `title_bar.zig:23`,
`many_windows.zig:27`, `services.zig:29`,
`hosts/native/windows/conformance.zig:1011`, and the compile-error cases
`core/tests/compile_errors/widgets_slider_on_bool.zig:11` and
`reflect_*.zig:12`. `core/bench/` does not use `zui_widgets`
(`core/bench/scenes.zig:441` declares its documents view by hand), so no
instruction count moves.

SPEC.md §19.2 (`:2402-2405`) names the contract
`zuiStyle(widget, state) Style` and says every control "draws the skin's
focus ring"; §11.1 (`:1267-1269`) says skins index `WidgetState` with
`std.EnumArray`; §7.2 (`:638`) says `text_scale` is applied by skins;
§16 has no section for the skin. `ARCHITECTURE.md:122` lists the role
and `:304` the difference this item closes.

**Plan.** One commit.

1. **The contract, in `zui_widgets`.** `zui_widgets.Part`, an enum of
   every element a widget styles; `zui_widgets.Style(Ui)`, what a skin
   returns for one part in one state; and the check: a skin is a struct
   type declaring
   `zuiStyle(*const Skin, Part, zui.WidgetState, *const zui.Environment) Style(Ui)`
   and no other `zui`-prefixed declaration. `Widgets(Ui, Skin)` checks
   it once and holds `skin: Skin`; `widgets.style(ui, part, state)` asks
   the skin, for callers that match a widget's look.
2. **Every widget styled through the skin**, including the focus ring,
   which is the style's `focus_ring`, drawn while focused. The metrics
   fixed in the widgets today become the skin's.
3. **`DefaultSkin(Ui)`**: today's `Theme` and `dark_theme`, answering
   `zuiStyle` from them, so every caller keeps its look;
   `11-polish:05-default-skin` replaces its data.
4. **Callers** move to `Widgets(Ui, zui_widgets.DefaultSkin(Ui))`, and
   the three that read the theme to `widgets.style` or `widgets.skin`.
5. **Tests:** a second skin of data only, in
   `core/zui_widgets/tests.zig`, restyles every widget; a recording skin
   shows every part and every state reaches `zuiStyle`; `Widgets` over a
   skin of no fields is as large as the skin. Compile-error cases
   `skin_*` for each mistake; `core/tests/instantiate.zig` instantiates
   `Widgets` with both skins.
6. **Documents:** SPEC.md §16.7 (the skin contract) and §19.2;
   `ARCHITECTURE.md` §7's row removed.

**Done when.** Core's tests in Debug, ReleaseFast and ReleaseSafe, and
`check` natively, for `wasm32-freestanding` and for `powerpc-linux`;
`test-all` and `check-all`; each `skin_*` case fails with its message;
the tour's and the showcase's tests in all three modes and their `check`
for `x86_64-windows`; the raylib tour's cycle prints
`diagnostics ok: true` and its `gallery` screenshot is the same before
and after; the terminal tour's `--dump --every-screen` passes; the
data-only skin's test restyles every widget without a change to
`zui_widgets`.

**Spec.** §7.2, §11.1, §16.1, §16.7, §18, §19.2.

**Status.** Done in one commit. `zui_widgets` has the contract: `Part`,
23 elements a widget draws (a checked box and the selected option are
parts of their own), `Style(Ui)`, and `expectSkin`, which
`Widgets(Ui, Skin)` runs once: a skin is a struct declaring
`zuiStyle(*const Skin, Part, zui.WidgetState, *const zui.Environment) Style(Ui)`
and no other `zui`-prefixed declaration. Every widget, and its focus
ring (`Style.focus_ring`, drawn in place of the border while focused),
is styled through the skin; the metrics the widgets fixed (the check
mark's size and radius, the popup's padding and offset, the options'
padding) are the skin's. `Widgets` holds `skin: Skin` and no default,
since Zig cannot give a field a default that only some skins can build,
so a caller writes `.{ .skin = .{} }`; `widgets.style(ui, part, state)`
serves `zui_reflect` and the showcase's hover target. `DefaultSkin(Ui)`
is the former `Theme` and `dark_theme`, answering `zuiStyle` from them,
for `11-polish:05-default-skin` to grow. Every caller names
`Widgets(Ui, zui_widgets.DefaultSkin(Ui))`. A control declared disabled
is styled disabled from that frame, where `widgetState` reports it a
frame later. Measured: core's tests pass in all three modes with four
new `skin_*` compile-error cases; a skin of data alone restyles every
widget (every rectangle, border and text command takes its colors, every
control its height), a recording skin is asked for all 23 parts and all
five states, and `Widgets` over a skin of no fields is 0 bytes and over
`DefaultSkin` exactly its size. The raylib tour's `gallery` screenshot
differs from one taken before the change only in the frame-time strip at
the bottom (rows 836-875), as two screenshots before the change also
differ, so the widgets draw the same pixels; its 600-frame cycle prints
`diagnostics ok: true`; the terminal tour's `--dump --every-screen`
passes. `core/bench/` does not use `zui_widgets`, so instruction counts
do not move.

## 11-polish:05-default-skin — The default skin

Light, dark and high contrast, following the environment.

**Status.** Retired before it started, by the owner's decision to build
the design system (SPEC.md §18): its light, dark and high-contrast skin
is `11-polish:19-default-design`'s, made from tokens instead of tables.

## 11-polish:06-text-editing — Text editing

Selection, word movement, the clipboard through the host, multiple
lines, and IME composition with the IME area in `HostRequests`.

Multiple lines include `textArea`, as its entry in `components` of
`docs/plans/default-ui-designs/exports/zui-default-design.json` gives
it: a text field's container, padded `m` by `s`, that grows with its
lines from `min_lines` to `max_lines` and then scrolls, with a caption
counter at its bottom trailing corner; and the text field's `selection`
part, `selection` behind `on_selection` text.

## 11-polish:07-zui-icons — `zui_icons`

The default design's components need, at `icon_sizes` of each
`ControlSize`: a chevron down and right (dropdown, disclosure), a check
(checkbox, menu items, the selected option), close (chip, dialog,
toast), search, an alert (a field's error, the banner), the four status
glyphs (info, success, warning, danger), arrows up and down (a table's
sort), a broken image (`asyncImage`'s failure) and a spinner's arc.
`11-polish:27-essential-inputs` and `11-polish:30-feedback-and-media`
wait for them.

## 11-polish:08-zui-themes — `zui_themes`

The design languages of Windows (Fluent), GNOME (libadwaita) and KDE
(Breeze), in `themes/`, each one a `zui.design.Design`: its seeds, type
roles, density defaults, shape roles and corner family, following the
system's accent (`11-polish:18-system-accent`). A design is data in the
core's vocabulary, so `zui_themes` still imports only `zui`; its tests
check each design with `zui_design` at comptime, in light, dark and high
contrast, as every design is checked. macOS's is set aside as
`14-macos:03-macos-skin`.

**Waits for** `11-polish:19-default-design`, whose design is the
template each language starts from.

Each language changes seeds, shapes, type and density, never a tone,
which the resolver keeps for every design (`roadmap/decisions.md`). The
plan's personalities, `quiet-instrument` and `crisp-technical`
(`docs/plans/default-ui-designs/personalities/`), show how far that
reaches from `zui_design.default`.

## 11-polish:09-template-project — The template project

In `examples/template/`.

## 11-polish:10-samples — Samples

A settings screen with `zui_reflect` and ZON, a data feed, a
multi-window tool, a remote session.

One sample can show one app in two designs: the plan's personalities,
`quiet-instrument` and `crisp-technical`
(`docs/plans/default-ui-designs/personalities/`), each a `Design`
fragment with its preferences and skin choices.

## 11-polish:11-profiling-guide — A profiling guide

Over `01-measure:04-tracer-contract`'s tracer.

**Grounding.** `docs/benchmarking.md`'s `## Profiling` section was one
paragraph on Tracy and a list of ways to keep noise out. The tracer
contract is `core/src/trace.zig:3` (`TraceZone`) and
`core/src/contracts.zig:380` (`checkTracer`); `zui_tracy` is
`core/zui_tracy/zui_tracy.zig`, with Tracy 0.14.1 pinned in
`core/build.zig.zon:8`; `ZoneTimer` is
`core/zui_debug/zui_debug.zig:32`; the tour's `--measure-idle` is
`apps/tour/src/root.zig:330`.

**Plan.** Grow `docs/benchmarking.md`'s `## Profiling` into a guide for
an application's author, with the consumer's own `build.zig` lines and
Zig for: Tracy through `zui_tracy`, and the zones zui emits; the
application's own zones; a tracer of one's own; `zui_debug`'s inspector
and `ZoneTimer`; reading `Diagnostics` and `NextFrame`; and measuring a
change. Compile every snippet in a consumer project of its own.

**Done when:** the guide covers those six parts, each snippet matches
the current API and compiles in a consumer project, the Tracy version
and the zone list are read from the code, and no API is described that
does not exist.

**Spec.** §16.5, §19.7, §19.10.

**Status.** Done: `docs/benchmarking.md`'s `## Profiling` is a guide in
six parts. Every Zig snippet was compiled and run in a consumer project
naming the repository by path, without Tracy and with
`-Dzui-tracy=true -Dtarget=x86_64-linux-gnu`, except the `zui_raylib`
dependency line, which copies `renderers/raylib/README.md`. `zui_tracy`
has no API for an application's own zones, so the guide declares Tracy's
C API, gated on `zui_tracy.enabled`; a public zone API in `zui_tracy`
would spare that. `tracy-capture`'s and `tracy-csvexport`'s flags are
from Tracy's documentation, not run here, since neither is installed.

## 11-polish:12-developer-experience-audit — A developer-experience audit

A new user builds each sample from the docs alone, and every place they
get stuck becomes an item.

## 11-polish:13-design-vocabulary — The design vocabulary and the appearance contract

`zui.design`: the roles, tiers and contract a component declares its
look in, so that every look can be checked before it is drawn.

**Grounding** (at `3f4ff58`). A look today is the skin contract's:
`zuiStyle(part, state, environment) Style`
(`core/zui_widgets/zui_widgets.zig:196`), over `Part`, a closed enum of
the parts `zui_widgets` draws (`:103`), so a component of the
application's own cannot join it. `Style(Ui)` (`:165`) holds raw colors
and numbers; no declaration says which text sits on which background, so
contrast cannot be checked without drawing. `zui.Color`, `CornerRadius`
(`core/src/style.zig:253`) and `Decoration` (`core/src/style.zig:679`)
are core vocabulary already; modules cannot import one another (SPEC.md
§3.3), so the roles that `zui_widgets`, `zui_design` and `zui_themes`
all name must be the core's too.

**Plan.**

1. `core/src/design.zig`, exported as `zui.design`: `ColorRole`,
   `Space`, `TypeRole`, `ShapeRole`, `CornerSize`, `Target`; `Design`,
   what an application or a theme pack declares;
   `Tokens(Ui, ExtraRoles)`, the resolved values;
   `tokens.look(Component, part, state)`, a part's decoration, padding,
   gap, text style and minimum size in one state.
2. The appearance contract, checked in `core/src/contracts.zig`: a
   component declares `Part` and `zuiAppearance`, and may declare
   `zuiDistinguish`. A part's text or icon names the part it sits `.on`;
   a raw color is `.unchecked(color, reason)`.
3. The compile errors SPEC.md §18.2 quotes, one case each in
   `core/tests/compile_errors/`.
4. `core/tests/instantiate.zig` instantiates `Tokens` and `look` for a
   component with parts and one with extra roles.

**Done when.** Core's tests in all three modes, `check` for
`wasm32-freestanding` and `powerpc-linux`; every message of §18.2
pinned; a component with no `zuiAppearance` costs nothing: the
instruction counts do not move.

**Spec.** §18.1, §18.2.

**Status.** Done:

- `core/src/design.zig`, `zui.design`: the roles and tiers of SPEC.md
  §18.1 and `Density`; `Design`, with the density table of §18.5 and the
  type scale's 1.2 and 15 as defaults, its fonts the integer values of
  the application's `FontId`; `Tokens(Ui, ExtraRoles)`, a color per role
  in each `WidgetState`, filled by a resolver, with `space` and `look`,
  which takes its part and state at run time, switching to a look made
  at comptime for each; `Appearance(Part, parts)` and
  `AppearanceWith(Part, ExtraRoles, parts)` for parts that name the
  application's own roles as `.extra(.brand)`. `zui.CornerShape` is a
  plain enum in `core/src/style.zig`.
- An extra role declares its pair in its enum's `zuiPairs`. A part's
  colors are a `ColorChoice`, a union whose void tags are the
  `ColorRole`s, so `.accent`, `.extra(.brand)` and `.unchecked(…)` all
  take a result type: `parts` is a struct with a field per part, not
  `anytype`, since a decl literal has none in an anonymous literal.
- The contract, `checkAppearance` and `checkExtraRoles` in
  `core/src/contracts.zig`, runs when `look` first reads a component and
  when `Tokens` is made. Its 22 messages each have a compile-error case.
- 12 tests in `core/src/tests/design.zig`; `core/tests/instantiate.zig`
  looks at a component of built-in roles and one of extra roles. Core's
  tests in Debug, ReleaseFast and ReleaseSafe; `check` natively, for
  `wasm32-freestanding` and `powerpc-linux`; `test-all` and `check-all`.
- Instruction counts against `42c0b0a`: all 175 rows identical (4096
  boxes at depth 8 still declare in 436,605).
- SPEC.md §18: a state was named `.normal`, which `zui.WidgetState`
  calls `.idle`; `Appearance`'s `parts` is typed; every message is
  quoted, as a `Chip` in `demo.zig` prints.

For `11-polish:14-zui-design`: `Design` has no seed for an extra role,
so the resolver picks its ramp; a part's outline is paired with its own
surface unless it names `.on`. For `11-polish:16-corner-shapes`: `look`
does not yet answer the shape role's `CornerShape`, which
`Decoration.corner_shape` will carry.

## 11-polish:14-zui-design — `zui_design`: tokens from seeds and preferences

The default maker of `Tokens`: palettes from a few seeds, solved for
contrast and color vision, spaced by the user's density.

**Grounding** (at `3f4ff58`). `zui_color`
(`core/zui_color/zui_color.zig`) has OKLab and OKLCH (`:23`, `:99`),
`withLightness` (`:253`) and `lightnessScale` (`:277`), all usable at
comptime: what solving a lightness needs. It cannot be imported by
another module, so `zui_design` carries the conversions it needs or is
given them; which, the item's first slice decides by measuring the
comptime cost. The environment (`core/src/input.zig:311`) reports theme,
contrast, `text_scale` and reduced transparency, but no density or color
vision, which are the user's choices in the application, not the OS's.

**Plan.** In slices, each a commit.

1. `core/zui_design/`, the module, wired as CLAUDE.md lists:
   `Preferences.from(environment, choices)` and
   `design.resolve(preferences, *Tokens)`, with no allocation.
2. Color: tonal ramps from `Design.seeds` in OKLCH; every role in light,
   dark and high contrast; state layers for hover, press and disabled.
3. Contrast: APCA and WCAG 2 for each declared pair, at the targets of
   SPEC.md §18.4. The resolver moves a foreground's lightness, keeping
   its hue and chroma. A design resolved at comptime that cannot meet a
   target is a compile error naming the pair and the lightness that
   passes. One resolved at run time is repaired, and `resolve` returns
   what it repaired.
4. Color vision: simulated protanopia, deuteranopia, tritanopia and
   achromatopsia (Machado et al., 2009, at full severity) for every
   `zuiDistinguish` pair and every status role. A pair that collapses is
   moved apart in lightness, or, if it cannot be, reported as needing a
   cue that is not color.
5. Density: the tier table of SPEC.md §18.5, with the target floors and
   `text_scale` coupling.

**Done when.** `zui_design`'s tests in all three modes and its `check`
for `wasm32-freestanding`: a seed of every hue resolves to tokens that
meet every target in every theme and contrast; a static design that
cannot is a compile error with its message; a run-time accent of pure
yellow on white is repaired and reported; every status role pair stays
apart under every simulation; a resolve allocates nothing, and changing
one preference resolves in under 50 µs in ReleaseFast.

**Spec.** §18.3, §18.4, §18.5, §19.11.

**Decided here.** `zui_design` carries the OKLab conversions it needs
(`core/zui_design/oklab.zig`: to and from linear sRGB, gamut mapping by
chroma, and the sRGB transfer as two 256-entry tables, as `zui_color`
builds them) over `zui.design.Oklch`, rather than being handed them by
the application, which would put a color module in every resolve's
signature. Measured with a fresh cache, type-checking the module's
instantiation (now in `core/tests/instantiate.zig`) took 0.37 s with a
design resolved at comptime in dark high contrast with three extra
roles, colors and all, and 0.32 s without it (0.20 s and 0.19 s before
slice 2's colors), so a comptime resolve costs about 0.05 s of the
build. `resolve` is a free function,
`zui_design.resolve(design, preferences, &tokens)`, since `Design` is
the core's and a module cannot give it methods; SPEC.md §18.3 and §19.11
say so.

Slice 3 decided four things. First, slice 2's tone tables missed §18.4's
APCA targets at every accent hue: dark text on the dark themes' fills (L
0.70 to 0.82) reached only Lc 47 to 78, light's amber `warning` Lc 61,
and dark's `on_surface_muted` and `outline` Lc 55 and 36. The owner
chose light text on darker fills in the dark themes, and these
lightnesses changed, chroma share in brackets where it changed:

| Scheme | Role | Before | After |
|---|---|---|---|
| light | `warning`, `on_warning` | 0.78, 0.25 | 0.86, 0.18 |
| dark | `accent`, `danger`, `warning`, `success` | 0.74, 0.70, 0.82, 0.74 | 0.45 each |
| dark | `on_accent`, `on_danger`, `on_warning`, `on_success` | 0.22 to 0.24 (0.5) | 0.99 (0.05) |
| dark | `on_surface_muted`, `outline` | 0.74, 0.62 | 0.88, 0.72 |
| light high contrast | `warning`, `on_warning` | 0.80, 0.15 | 0.93, 0.10 |
| light high contrast | `on_accent_container` | 0.20 | 0.16 |
| dark high contrast | `accent`, `danger`, `warning`, `success` | 0.82, 0.78, 0.86, 0.80 | 0.30 each |
| dark high contrast | `on_accent`, `on_danger`, `on_warning`, `on_success` | 0.12 to 0.14 (0.5) | 1, neutral |
| dark high contrast | `on_surface_muted` | 0.86 | 0.94 |

Second, the state layers cannot all keep a pair passing at 16% toward
its text, whatever the tables: light high contrast's `on_surface` on
`surface` falls to Lc 79 pressed, and a dark-text fill such as light's
`warning` would need an idle lightness above 0.97. So `layerShares`
solves each surface and fill's share of the layers, the largest that
keeps every pair on it passing when pressed, searched to 1/256; a share
under 0.25, which would hardly show, becomes a move as far toward white
or black, away from the text. Light's `warning` and light high
contrast's status fills and containers move that way; light's `surface`
keeps about 0.35 of the layers. Third, a chosen accent keeps its own
lightness, the owner's call, so a run-time color that fails is a real
repair. Fourth, `zui.design.Design.name` names a design in the compile
error, "the design" by default, rather than a separate comptime entry
point.

Slice 4 decided five things. First, the owner's rule for the dark themes
(light text on darker fills) leaves the three status fills no room to
differ in lightness: white text caps a fill at about L 0.54 (Lc 75) and
0.44 (Lc 90), and three fills 0.15 apart below that put `danger` at the
surface's own lightness, 0.20 on 0.21 in dark and 0.10 on 0.10 in dark
high contrast. Simulation moves a fill's lightness little: protanopia
darkens red by about 0.08 at L 0.5 and amber by 0.035, and lightens
green by 0.025; the others move a fill by 0.03 or less. So the owner
made one exception: `warning` alone takes dark text on a light amber
fill in the dark themes, as light already does. `danger` is the darker
of the two white-text fills in every scheme, since protanopia darkens
red further. The tables changed, chroma share in brackets where it
changed:

| Scheme | Role | Before | After |
|---|---|---|---|
| light | `danger`, `success` | 0.55, 0.52 | 0.34, 0.53 |
| dark | `danger`, `success` | 0.45, 0.45 | 0.32, 0.52 |
| dark | `warning`, `on_warning` | 0.45, 0.99 (0.05) | 0.87, 0.18 (0.5) |
| light high contrast | `danger`, `success` | 0.45, 0.42 | 0.23, 0.41 |
| dark high contrast | `danger`, `success` | 0.30, 0.30 | 0.23, 0.41 |
| dark high contrast | `warning`, `on_warning` | 0.30, 1 (neutral) | 0.93, 0.10 (0.4) |

With them no seed reaches a contrast failure any more: a scan of every
status hue in 10° steps and every neutral hue in 30° steps at chroma up
to 0.3 repairs no contrast pair. So `design_pair_below_target`, whose
green `danger` passed after the retune, became
`design_status_roles_collapse`, a design whose `success_hue` is red
(20°), the one kind of fatal repair a design's own hues still reach, and
SPEC.md §18.4 describes the contrast message's form instead of quoting
it. Second, `zuiDistinguish` pairs are checked, not moved, by
`zui_design.checkDistinguished(design, components)` at comptime, since
their roles are shared by every component, and a part declares a cue
that is not color as `PartAppearance.cue`, a string naming it. Two parts
are compared idle only: compared in every layer, a `danger` part and a
`success` part fail when hovered, 0.08 apart under deuteranopia in
light, because `danger` takes its layers toward its white text and
`success`, too near its text's limit for that, takes them toward black.
A state's layer is feedback on one part, which an entry of a part in two
states checks. Third, separation is measured on the colors as encoded in
sRGB, as contrast is; measured before encoding, achromatopsia's 0.20
came out at 0.199 after rounding. Fourth, `Preferences.color_vision`:
`protan` and `deutan` move `danger` to 40° and `success` to 230°, with
`warning` at 85°, which in a test widens their simulated chromatic
distance under protanopia and deuteranopia in every scheme. A move of
`warning`'s hue for `tritan` did nothing: a scan of its hue from 20° to
110° moved its tritanopia distance from `success` by at most 0.01, since
a light fill has little chroma to show. So `tritan` and `achromat` keep
the hues and hold the fills 0.20 apart instead. Fifth, a repair a chosen
color vision needs is never fatal at comptime, as a chosen accent's is
not.

**Status.** Done, in five slices. Slice 1 done: `core/zui_design/`,
wired as a module and re-exported by the root, with `Preferences`,
`Preferences.from` (the accent from `Choices` alone until
`11-polish:18-system-accent`), `Repairs` (empty until slice 3) and
`resolve`, which writes spacing from the density table, each shape
role's radius one `CornerSize` step from its design's by
`Preferences.corners` (`bubble` is 65,536 units, which emission's clamp
makes a pill), the design's corner shape, target floors of 24 and 44 (44
for both under `pointer = .touch`), an outline of 1 and a focus ring of
2, `text_padding_scale` as half of `text_scale` past 1 added to 1, text
styles at the modular scale's sizes in the design's fonts with
`text_scale` to a power from 1 at `caption` to 0.5 at `display`, and a
measure of 66 characters of half the body size. `zig build check`
type-checks `zuiCheckDesignResolve` in `core/tests/instantiate.zig`,
which resolves at run time and at comptime, in `zui.Color` and
`zui.ExtendedColor`, with extra roles.

Slice 2 done: color (`core/zui_design/palette.zig`). Each seed is a
tonal ramp of its hue and chroma: the neutral, the accent (its hue and
chroma replaced by `Preferences.accent`), and danger, warning and
success at the design's hues or 27°, 75° and 150°, at chroma 0.16. Each
role is a lightness on a ramp, with a share of its chroma, in a table
for each of light, dark, light high contrast and dark high contrast;
dark's raised surfaces are lighter than its page; the seed's own
lightness is not read. Every color is brought into sRGB by reducing its
chroma, and encoded in `Ui.Color`, linear for `zui.ExtendedColor`. The
state layers move each fill 8%, 10% and 16% of the way to its `on_*`
role in OKLab when hovered, focused and pressed; text, icons and
outlines keep their idle color, and disabled, every role but the page's
surfaces and the scrim loses its chroma and keeps 38% of its alpha.
Reduced transparency raises the scrim to 85% opacity. An extra role is
colored as `builtInRoleOf` says: the partner of the built-in role its
pair names, in turn along a chain of extra roles, and `accent` and
`on_accent` alternating from the first declared around a cycle. Palettes
stay in OKLCH (`palettesFor`, `Shade`) until they are encoded, so slice
3 can move a foreground's lightness alone. Measured: in ReleaseFast a
resolve of every token with six extra roles, alternating theme and
accent, takes a median of 8.7 µs (47.6 µs in Debug), under the 50 µs of
the Done when. Before contrast is solved, `on_surface` on `surface` is
16.6:1 in light, 14.9:1 in dark, 20.1:1 in light high contrast and
20.4:1 in dark high contrast in WCAG 2, which a test holds at 4.5:1;
APCA is not measured yet. 17 tests in `core/zui_design/tests.zig`.

Slice 3 done: contrast (`core/zui_design/contrast.zig`,
`core/zui_design/repairs.zig`). APCA-W3 0.0.98G-4g's Lc and WCAG 2's
ratio, on each color as encoded in sRGB, alpha ignored (only the scrim
is translucent, and it has no target); tests pin black on white at Lc
106.04, white on black at −107.88, #888 on white at 63.06, 21:1 and #777
on white at 4.48:1. `tierOf` gives every `on_*` role the text tier (Lc
75 and 4.5:1, Lc 90 and 7:1 under high contrast) and `outline` and
`focus` the non-text tier (Lc 45 and 3:1, Lc 60 and 4.5:1); the
surfaces, fills, `outline_muted` and `scrim` have none. `checked_pairs`
is each role and its partner once, 14 pairs, `on_surface` on all four
surfaces; an extra role is colored as a built-in role, so its pair is
one of them. `solve` moves a failing foreground's lightness away from
its background by `passingLightness`, a 14-step bisection that keeps hue
and chroma, and when no lightness passes takes it to white or black and
moves the background; it runs on the idle palette before the state
layers, which take the shares above. `resolve` returns `Repairs`, the
first 32 `Repair`s (the pair, the scheme, the target, the contrast
before, each side's lightness from and to) and a count of the dropped.
At comptime a repair that does not involve a chosen accent is a compile
error, pinned by `design_pair_below_target`:
`zui_design: demo.design's on_danger on danger is Lc 73 in light, needs 75; on_danger at L 1.00 passes`.
Measured: an accent of every hue from 0° to 330° in 30° steps, at chroma
0.05, 0.25 and 0.37, resolves with no repair in all four schemes, every
pair passing idle, hovered, focused and pressed; the tightest idle pairs
are light's status fills at Lc 77.9 to 78.4 and light high contrast's at
Lc 90.4 to 91.9. A chosen pure yellow (`0xffff00`, L 0.97) under
near-white `on_accent` in light is one repair: `on_accent` goes to white
and `accent` darkens until both pass. In ReleaseFast a resolve of every
token with six extra roles, alternating theme and accent, takes a median
of 30.7 µs (135 µs in Debug), measured while other builds shared the
machine; the layer shares cost about 14 µs of it, and APCA's powers are
`@exp(@log(x) · e)`. 25 tests in `core/zui_design/tests.zig`. Slice 4,
color vision, is next.

Slice 4 done: color vision (`core/zui_design/color_vision.zig`,
`core/zui_design/distinguish.zig`). `simulatedLinear` applies Machado,
Oliveira and Fernandes's severity-1 matrices for protanopia,
deuteranopia and tritanopia on linear sRGB, clamped into the gamut, and
achromatopsia's luminance alone; a test pins each matrix's columns,
white and black under each, and red's lightness without color at
∛0.2126. `separateStatusRoles` runs after contrast is solved: a pair of
status fills nearer than 0.15 in lightness under any simulation is
parted by moving the fill with the shorter move away from the other, as
far as its `on_*` text still passes, a 9-step bisection; a pair no move
parts is recorded as needing a cue that is not color. `Repair` gained a
`kind` (`contrast`, `color_vision`, `needs_non_color_cue`) and
`nearest`, the simulation and difference before. At comptime a
color-vision repair is a compile error unless the user chose the color
vision, pinned by `design_status_roles_collapse`:
`zui_design: demo.design's danger and success are 0.14 apart in lightness under protanopia in light high contrast, need 0.15; success at L 0.42 passes`.
`zui_design.checkDistinguished` is pinned by `distinguish_without_cue`
and `distinguish_states_without_cue`, and `core/tests/instantiate.zig`
checks a component of extra roles with it. No component in
`zui_widgets`, `themes/` or `apps/` declares `zuiDistinguish` yet.
Measured on the default tables: an accent of every hue from 0° to 330°
in 30° steps, at chroma 0.05, 0.25 and 0.37, resolves with no repair in
all four schemes, every contrast target met idle, hovered, focused and
pressed, and every status pair at least 0.15 apart. The tightest are
`danger` and `success` under tritanopia, 0.170 in light, 0.182 in dark,
and 0.167 in both high-contrast schemes; the tightest status contrast is
`on_success` on `success`, Lc 76.7 in light, 77.9 in dark and 93.1 in
high contrast. In ReleaseFast a resolve of every token with six extra
roles, alternating theme and accent, takes a median of 30.7 to 31.6 µs
in two runs with typical color vision (slice 3: 30.7 µs), 31.0 to 31.2
µs for `deutan`, and 37.7 to 38.3 µs for `achromat`, which moves fills
on every resolve (141 µs in Debug with typical color vision), under the
50 µs budget, measured while other builds shared the machine. Holding
the other fills' simulated lightness fixed for the search, and searching
to 1/512 rather than 1/4096, brought a mix of half typical and half
`achromat` resolves down from a median of 53 to 57 µs (90th percentile
75 µs) to 36 µs. 32 tests in `core/zui_design/tests.zig`. Slice 5,
density, is next.

Slice 5 done: density, and with it the item. Slice 1's resolve already
met SPEC.md §18.5, so no code changed; four tests in
`core/zui_design/tests.zig` now hold it, through `Tokens.look` on a
component of a button (`target = .pointer`), a label that draws text, a
close icon (`target = .touch`) and a panel. `Design.default_density` is
the spec's table, every tier at every density, written out cell by cell
in the test, and resolves as it is; a `Design`'s own table is still used
when given. Density is not one factor: from `compact` to `roomy`, `xs`
and `s` grow 3 and 2.5 times and `xl` and `xxl` 2 times, and to
`compact` from `comfortable` the first two halve while the last two keep
2/3 and 3/4. In every theme and contrast, at every density, at
`text_scale` 1, 1.5 and 2, in every state, the button is 24 units on
each side (44 under `Preferences.pointer = .touch`), the close icon 44
and the panel unfloored, and the focused button and icon ring in `focus`
2 units wide. The label pads by its tiers times 1, 1.25 and 1.5 at those
text scales; the button's padding and gap, the icon's and the panel's
are not scaled. Each criterion of the Done when is held by a test or a
measurement: every hue's seed meeting every target in every state of
every scheme, by "a seed of every hue meets every target"; the static
design that cannot, by the compile error `design_status_roles_collapse`;
the run-time pure yellow, by "a chosen pure yellow accent keeps its
lightness"; the status fills, by "the status fills stay apart in
lightness under every simulation"; a resolve allocating nothing, since
`resolve` takes no allocator and runs at comptime; and the time,
measured by a program outside the repository that resolves every token
with six extra roles 2,001 times, alternating theme and four accents: in
ReleaseFast, in three runs, a median of 30.3 to 31.2 µs with typical
color vision (90th percentile 31.6 to 32.0 µs), 30.6 to 30.9 µs for
`deutan` and 38.9 to 39.9 µs for `achromat` (90th percentile up to 41.5
µs), and the same within 1 µs when density and `text_scale` change on
every resolve too, under the 50 µs budget, measured while other builds
shared the machine. 36 tests in `core/zui_design/tests.zig`. The type
scale, `11-polish:15-type-scale`, reworks `writeTextStyles` and the
measure.

## 11-polish:15-type-scale — The type scale

Type roles that look right: sizes from a modular scale set by the face's
x-height, line heights on the grid, tracking by size, and `text_scale`
applied by role.

**Grounding** (at `3f4ff58`). `zui_glyphs.FontMetrics`
(`text/glyphs/src/fonts.zig:12`) holds `ascent`, `descent` and
`line_gap`, but no x-height or cap height, which stb_truetype reads from
a face's OS/2 table. Letter spacing reaches measurement and drawing
already (`MeasureKey`, SPEC.md §9.1). No widget reads `text_scale`
(`11-polish:04-skin-contract`'s Grounding).

**Plan.**

1. `FontMetrics.x_height` and `cap_height`, from `zui_truetype`, with a
   documented estimate for a face without an OS/2 table.
2. In `zui_design`, the type roles of SPEC.md §18.6 from `Design.type`:
   the scale's ratio, the body size, a font for each of regular, strong
   and monospace, and the body face's metrics.
3. Each role's line height snapped to the 4-unit grid, its tracking by
   size, `text_scale` applied less to larger roles, and the body text's
   measure in `Tokens`.

**Done when.** `zui_design`'s tests: two bundled faces of different
x-heights give body text whose x-heights differ by at most 0.5 units; at
`text_scale = 2`, body doubles and display grows by at most 1.5×; every
role's line height is a multiple of 4; the text packages' tests and
`check` pass.

**Spec.** §9.1, §18.6.

**Status.** Done. `zui_glyphs.FontMetrics` gained `x_height` and
`cap_height`, in font units, without defaults, and
`zui_glyphs.expectFontsConform` holds them above the baseline, the
x-height no higher than the cap height and that no higher than the
ascent (`BoxFonts` gives 500 and 700). `zui_truetype.Face` reads them
from the OS/2 table's `sxHeight` and `sCapHeight` (offsets 86 and 88,
version 2 on), finding the table in the font's directory itself, since
stb_truetype's `stbtt__find_table` is internal. A face whose table is
older or missing takes them from the tops of its `x` and `H` glyphs
(`stbtt_GetGlyphBox`), and a face without those from 0.55 and 0.75 of
its ascent. Measured, and checked against the tables read by a short
Python script outside the repository: Atkinson Hyperlegible Regular and
Bold are 496 and 668 of 1,240 units from ascent to descent (x-height
0.40 of the size), Liberation Mono 1,082 and 1,349 of 2,320 (0.466);
with the OS/2 version set to 1 in a copy, both faces' glyph tops are
within 3% of the tables'. Three tests in `text/truetype/src/face.zig`.

In core, `zui.design.FaceMetrics` (ascent, descent, x-height and cap
height, `.of(any value with them)`, `xHeightPerSize`) and
`Design.TypeScale.faces`, a face for each of regular, strong and
monospace, which the application fills from its font system, since
`zui_design` cannot import `zui_glyphs`; `TypeScale.x_height` became 6,
Atkinson Hyperlegible's at 15, rather than optional. `zui_design` sizes
body text in each font whose face is given so its x-height is the
design's (`bodySizeIn`), and in a font not given at `body_size`;
`body_strong` takes the strong font and face, `code` and `numeric` the
monospace ones. A role's line height is `lineHeightFor` its size, 1.5
times it at 14 and below falling to 1.15 at 40, rounded to the 4-unit
grid; its letter spacing `trackingFor`, +1% at 12 and below, none at 16
and −2% at 32 and above. The measure stays 66 characters of half the
body size, now of the body face's size. `text_scale`'s power is 1 up to
`body` and falls to 0.5 at `display`; slice 1's fell from `caption`, so
body text grew only 2^0.83 = 1.78 times at `text_scale = 2`, against the
Done when, and SPEC.md §18.6 now says so. Tests in
`core/zui_design/tests.zig` (42): Atkinson and Liberation Mono as body
faces, 0.40 and 0.47 x-height per size, set body text at x-height 6 and
6, 0 apart where at size 15 they would be 1.0 apart, and code in
Liberation Mono beside Atkinson body matches its x-height; at
`text_scale = 2` the roles up to body double, and title, headline and
display grow 1.83, 1.68 and 1.41 times; every role's line height at text
scales 1 to 3 is a multiple of 4 and within 2 of its leading; tracking
is 0.12 at 12, 0 at 16, −0.24 at 24 and −0.64 at 32.
`zuiCheckDesignResolve` in `core/tests/instantiate.zig` resolves with a
face given through `FaceMetrics.of`. `numeric` is body in monospace,
whose figures are tabular already; `Ui.TextStyle` has no way to ask a
proportional face for tabular figures.

## 11-polish:16-corner-shapes — Corner shapes

Round, continuous and chamfered corners, drawn by the renderers that
declare them and lowered to round by the rest.

**Grounding** (at `3f4ff58`). `CornerRadius` is four floats
(`core/src/style.zig:253`); every command that carries one is round
(`core/src/commands.zig:77`, `:83`). The sokol renderer clamps each
corner to half the shorter side (`renderers/sokol/src/renderer.zig:842`,
`:851`), so a radius of a pill drawn there is already clamped; emission
does not clamp. Lowering reports what it replaced in
`diagnostics.lowered` (`core/src/context.zig:158`).

**Plan.**

1. `Decoration.corner_shape`, over `zui.CornerShape` (`round`,
   `continuous`, `chamfer`; `core/src/style.zig`), which
   `11-polish:13-design-vocabulary` added as a plain enum since `Design`
   and `Tokens` hold it, and `Config.corner_shapes`, the shapes the
   renderer draws. A command carries its shape only when that set holds
   more than `round`, so the commands of an application that declares
   none are unchanged.
2. Emission clamps each corner to half the shorter side, and draws a
   shape the renderer does not declare as round, reporting it lowered.
3. The sokol and WebGL renderers draw all three, traced into the
   outlines they already draw every rounded shape and effect with
   (`corner_segments` per corner, the WebGL one triangle for triangle as
   the sokol one), not as signed distances: neither renderer has a
   distance shader to give them; the raylib and terminal renderers
   declare only `round`.
4. The renderer suite draws each declared shape and reads a pixel inside
   the chamfer's cut and outside a round corner's arc.

**Done when.** Core's tests and counts (within CI's 2% gate with no
shapes declared); `test-all`; the sokol and WebGL renderers pass the
suite with every shape; `test-draw` in `hosts/web/` passes.

**Spec.** §4, §10.1, §13.1, §13.3, §18.7.

**Status.** Done:

- `Decoration.corner_shape` and `Image.corner_shape`;
  `zui.CornerShapeSet`, a renderer's `zui_corner_shapes`, checked and
  always with `round`, carried by `zui_app.contextConfig` into
  `Config.corner_shapes`. Each payload with corners has a
  `corner_shape`, `void` unless the set holds more than `round`;
  `zui.cornerShapeOf` reads either. Two compile errors pin a set without
  `round`.

- Emission clamps each radius to half the snapped bounds' shorter side,
  and draws a shape the renderer lacks round, listing it in
  `Diagnostics.lowered_corner_shapes`, a field of its own (a set of
  shapes, not `CommandSet`, which holds commands); `Diagnostics` stays
  96 bytes. Square corners skip both, by one test of the radii's bits.

- `Tokens.look` sets the part's shape role's shape with its radius.

- The sokol and WebGL renderers declare every shape and trace them in
  one `Outline`: a continuous corner is the superellipse |x|⁴ + |y|⁴ =
  r⁴, the circle's points with each coordinate's square root; a chamfer
  is its cut's two ends, moved by (2 − √2) × an inset so a border's
  inner edge stays at 45°. No shader rounds a corner itself.

- The renderer suite draws a box of each shape in a scene of its own and
  reads pixels near each's top-left and bottom-right corners that tell
  the three apart, a shape the renderer lacks checked as round; a
  renderer that draws every corner round fails it. sokol passes it in
  every target; WebGL's laid-out fans are checked by test. Six scenes
  overflowed the suite's frame time on `x86-linux`, now in `u64`.

- `hosts/web`'s `DemoUi` and `PageRenderer` carry the WebGL renderer's
  shapes, as they carry its commands; `test-draw` and `test-demo` pass.

- Instruction counts against `f6051f4`, with no shapes declared, each
  growth the clamp and shape test on corners, or the new byte a declared
  decoration stores:

  | Row | Growth |
  |---|---|
  | 3000 cells, tooltip first / last, endFrame | +0.76% / +0.78% |
  | documents view, endFrame | +0.38% |
  | 4096 boxes, depth 8, declare | +0.35% |
  | 4000 children of one parent, endFrame | +0.12% |
  | 4096 interactive boxes, declare / pressed / clicked | +0.12% to +0.14% |
  | 4096 boxes, depth 8, endFrame; static-styled, endFrame | +0.08% |
  | 4096 interactive boxes, endFrame (all three) | +0.05% |
  | 1000 labels, rendered, endFrame | +0.01% |

  Without the square-corner test the cells rows grew 4.1% and 4.2%. The
  owner accepted this growth over compiling the clamp and the report out
  of a context that declares only `round` (`roadmap/decisions.md`), and
  the *Done when* now asks for counts within CI's 2% gate.

## 11-polish:17-nested-corners — Nested corners

A child's corners that follow its parent's at the child's own inset,
resolved where both boxes are known.

**Grounding** (at `3f4ff58`). The sokol renderer already insets a
border's inner edge by the concentric rule: its inner radius is the
outer one less the larger of the two adjacent border widths
(`renderers/sokol/src/renderer.zig:844-847`). Emission knows an
element's bounds and its parent's as it walks the tree in pre-order
(`core/src/emission.zig:388`, `cornerRadiusOf`), so a parent's resolved
radius is known before its children are emitted.

**Plan.**

1. `Decoration.nested_corners: ?NestedCorners`, behind
   `Features.nested_corners`.
2. At emission, each corner's radius is the parent's, less the child's
   distance from that corner of the parent along the farther axis, by
   the family's rule of SPEC.md §18.7. A parent that is itself nested
   resolves first.
3. Below `NestedCorners.minimum`, the corner keeps the minimum. A corner
   farther from the parent's than the parent's radius takes the minimum
   too.

**Done when.** Core's tests: a card of radius 16 and padding 6 gives its
filling child radius 10; a child that touches only the card's top edge
follows only the top corners; a chamfer nests by `(2 − √2)·d`; a
three-deep nesting resolves; counts are unchanged with the feature off.

**Spec.** §4, §10.1, §18.7.

**Status.** Done:

- `zui.NestedCorners { minimum = 0 }` and `Features.nested_corners`.
  `Decoration.nested_corners` is `?NestedCorners` with the feature on.
  Off, it is a one-tag enum of no bytes, so `zui.Decoration` stays 52
  bytes, which a test asserts, and `Ui.Decoration` is `zui.Decoration`.
  `DecorationWith` takes the feature as its third parameter.
- The parent is the nearest ancestor with a decoration, so a row or
  column that only lays children out is passed over. An element with no
  decorated ancestor sits in the window's square corners and takes
  `minimum`. The family is the child's own `corner_shape`.
- Emission keeps the drawn radius of each decorated element as it enters
  it, already clamped to the snapped bounds, in `drawn_corner_radii`.
  That array is in the context's one reservation and has `max_elements`
  entries with the feature on and none with it off. A nested element
  walks up `Frame.parent` to its decorated ancestor and reads that
  radius, which the pre-order walk has already written. The background,
  material, shadow, gradient, blur and border all read the resolved
  radius, and the existing clamp and lowering then apply.
- A declaration in a context without the feature fails with
  `"zui: Decoration.nested_corners needs Config.features.nested_corners = true"`.
  A field's coercion can raise no `@compileError`, so the message is the
  name of the field's zero-size type, and it appears inside Zig's own
  "does not support struct initialization syntax" error. Its case,
  `nested_corners_without_feature`, matches it with the `/?/` wildcard,
  since the matcher compares line endings.
- Core's tests (`core/src/tests/corners.zig`) cover:
  - radius 16 and padding 6 give 10;
  - a child touching only the top edge gets 10 at the top and its
    `minimum` 2 at the bottom;
  - a chamfer gets 16 − (2 − √2)·6;
  - three levels with an undecorated wrapper give 16, 12, 8;
  - `minimum` applies below it, past the parent's radius, and with no
    decorated ancestor;
  - a border and a shadow follow too. `core/tests/instantiate.zig` nests
    one in a context with every command and materials.
- Instruction counts against `6accded`, with the feature off: every one
  of the 175 rows, misses included, +0.00%.
- Known issue for `11-polish:19-default-design`: with the feature on,
  `Ui.Decoration` is the context's own type, as it is with materials, so
  a `zui.Decoration` such as `tokens.look(...).decoration` cannot be
  assigned to it without being copied field by field (SPEC.md §18.7's
  example shows the copy).

## 11-polish:18-system-accent — The system's accent color

`Environment.accent`, reported by each host, so a design follows the
user's accent.

**Grounding** (at `f31e1ef`). The Linux host's portal settings carry
`accent-color` as `(ddd)`, and the host passes it over: its reader takes
only `u` values (`hosts/native/linux/desktop_bus.zig:299-313`), as its
test shows (`:366-399`). Windows reports its accent through `UISettings`
and `DwmGetColorizationColor`; the web host can read the page's
`AccentColor` system color.

**Plan.** `Environment.accent: ?Color` and its `EnvironmentChange`; the
Windows, Linux and web hosts report it; the host suite checks that a
change reaches the environment; `zui_design.Preferences` takes it as the
accent seed unless the application overrides it.

**Done when.** Core's tests; each host's tests and suite; the Linux host
reports the portal's accent; the Windows host's is waiting on CI if it
cannot be run here.

**Spec.** §7.2, §18.3.

**Status.** Done, with the Windows host's part waiting on CI:

- `zui.Environment.accent: ?zui.Color`, null where the system has none,
  and `EnvironmentChange.accent`, which `Context` applies as every other
  field (`core/src/input.zig`); `core/zui_wire/tests.zig` round-trips
  it. SPEC.md §7.2 and §18.3 already named it.
- The host suite: `expectPostedEvents`, which `expectHostConforms` and
  `expectSteppedHostConforms` run, posts an accent change of `#1f7a5c`
  after the move and expects it in order. A harness that cannot deliver
  one returns false from `post`, as the raylib harness does.
  `expectPushedHostConforms` posts no events, so the web host's accent
  is held by its own tests and `test-host`.
- Linux: the portal's `accent-color` `(ddd)` is read (`dbus.Reader`
  gained `double`) into `DesktopSettings.accent`, an out-of-range
  channel as null, and reported through `ReportedEnvironment` on Wayland
  and X11 alike, so the first record carries 9 environment changes
  beside focus. Tests: the portal's answer and a change, unset
  `(-1, -1, -1)` and a channel of 2 as null (`desktop_bus.zig`); set,
  repeated (nothing sent), changed and unset on Wayland, set and unset
  on X11; both harnesses post the suite's accent through
  `onDesktopReport`. 88 of 89 conformance tests pass on each backend
  (the opt-in shown window skips), in Debug and ReleaseSafe.
- Windows: `DwmGetColorizationColor`'s color, opaque, at the first
  record and again on `WM_DWMCOLORIZATIONCOLORCHANGED`, null when it
  fails; `Host.forced_accent` stands in for the user's in tests. The
  harness posts the suite's accent by setting it and sending the
  message, and a test checks the first record, a change and a repeat
  that sends nothing. Compiled with `check` for `x86_64-windows` and
  `aarch64-windows`, not run. **Waiting on CI:** the Windows leg of
  `hosts/native/`'s conformance, the host suite on both windows and the
  test "the accent is reported at the first poll, and again when the
  colorization changes".
- Web: `page_environment.mjs` reads the `AccentColor` system color from
  a hidden element's computed `color` as `#rrggbb` (`"none"` where
  `CSS.supports` does not know it) at the start, and again when the
  color scheme or forced colors change, since no event tells of the
  accent alone. `PageEnvironment.accent` parses it; native tests cover a
  change, an unset accent and five malformed values. `test-host` checks
  the page read a color (headless Chromium gives `#0075ff`) and that it
  reached the worker in its first settings.
- `zui_design.Preferences.from` takes `choices.accent` orelse
  `environment.accent`; two tests at the end of
  `core/zui_design/tests.zig`.
- Instruction counts against `f31e1ef`: every one of the 35 instruction
  rows +0.00%.
- Known flake, not this item's: `x11_conformance`'s INCR clipboard test
  failed 1 of 7 ReleaseSafe runs here while other builds loaded the
  machine (the text read back wrong), and passed 3 of 3 on `f31e1ef`;
  the change touches no clipboard code.

## 11-polish:19-default-design — The default design

zui's own design, and every widget styled from tokens: light, dark and
high contrast, every density, following the environment.

**Grounding** (at `3f4ff58`). `DefaultSkin(Ui)`
(`core/zui_widgets/zui_widgets.zig:216`) is two tables, a `Theme` for
light and one for dark, and reads neither `contrast` nor `text_scale`.
The tour builds a theme each frame from its palette
(`apps/tour/src/kit.zig`).

`11-polish:20-appearance-audit` found the tour's text below SPEC.md
§18.4's targets (Lc 75 and 4.5:1 for body text, Lc 60 and 3:1 from
`title` up) on every screen, 2,350 lines in all, by the palette entry
(`apps/tour/src/shared.zig:218`) each is drawn in. `muted`: dark
#9097a6, 842 lines at Lc 40 to 46 (4.4 to 6.7:1); light #596070, 210 at
Lc 63 to 70 (4.7 to 5.3:1). `faint`: dark #5c6372, 448 at Lc 19 to 21
(2.5 to 3.2:1); light #9aa1b0, 439 at Lc 39 to 51 (2.2 to 2.6:1). The
status and accent colors as text: in light `good` 82 lines at Lc 53 to
71, `accent` 31 at Lc 57 to 63, `warn` 27 at Lc 55 to 70, `bad` 23 at Lc
55 to 74 and `spectacle` 9 at Lc 64 to 67; in dark `good` 82 at Lc 57 to
64, `accent` 46 at Lc 38 to 43, `warn` 27 at Lc 61 to 67, `bad` 25 at Lc
40 to 45 and `spectacle` 23 at Lc 46 to 50. `on_accent` on `accent` in
dark, #0a0c10 on #5b8cff, 22 lines at Lc 45 to 60. One Declaration's
preview of the other theme adds 7 lines in that theme's entries, and
Light Lab's white text on its gradients 7 more, which match light's
`on_accent`. The tour's test (`apps/tour/src/tests.zig`) expects exactly
these causes until they are fixed.

**Plan.** In three slices, D1 to D3 of the plan in
`docs/plans/default-ui-designs/README.md`, whose `exports/` hold the
approved design:

1. `zui_design.default` and the vocabulary it needs: 12 new roles
   (`surface_overlay`, `on_surface_accent`, a container and its text for
   each status, `selection` and `on_selection`, `shadow` and `rim`),
   `label_strong` and headings in the strong font, the four schemes'
   tones, and in `Tokens` control heights and icon sizes per
   `ControlSize`, the focus ring's offset and a `Lift` per `Elevation`.
2. `zui_widgets.DesignSkin(Ui)`, a skin over a `*const Tokens`: each
   `Part` declares its appearance from the plan's `components` entry for
   its widget, and `zuiStyle` answers from `tokens.look`. `DefaultSkin`
   is removed, and its callers move.
3. The tour and the showcase resolve tokens on a change of preferences,
   and the tour gains a screen of density, color vision, contrast and
   text scale for the user to choose. The tour's `Palette`
   (`apps/tour/src/shared.zig:218`) gives way to tokens, each entry by
   its use, as the owner chose (`roadmap/decisions.md`): `background`,
   `surface`, `raised` and `sunken` the surfaces; `hovered` is
   `secondary_container`; `border` is `outline_muted`, or `outline`
   where it shows a state; `overlay` is `scrim`; `text` is `on_surface`;
   `muted` and `faint` are `on_surface_muted`; `accent` is the `accent`
   fill, or `on_surface_accent` as text; `on_accent` is `on_accent`;
   `good`, `warn` and `bad` are `success`, `warning` and `danger` as
   fills, and their containers' text as text; `focus` is `focus`; and
   `spectacle` is dropped, the Spectacle lane taking the accent. Its
   secondary actions, such as the header's, take the `secondary` button
   variant. The showcase's palette moves the same way.

**Done when.** `test-all`, `check-all`; every widget meets SPEC.md §18.4
in every theme, contrast and density, by `11-polish:20-appearance-audit`
when it lands and by `zui_design`'s pair checks until then; the tour's
every screen audits clean for text contrast in light and dark, and its
test expects no text contrast finding; the raylib tour's cycle prints
`diagnostics ok: true`; the terminal tour's `--dump --every-screen`
passes.

**Waits for** `11-polish:14-zui-design`, `11-polish:15-type-scale`,
`11-polish:16-corner-shapes`.

**Spec.** §16.7, §18, §19.2.

**Status.** Done, in three slices. Slice 1 is done: `zui_design.default`
resolves at comptime in every scheme with nothing repaired, and so does
each of its eight accent presets at run time. Every role in every state
of every scheme matches the approved colors in
`exports/zui-default-design.json` to the byte
(`core/zui_design/default_tests.zig`), but where the showcase that made
them drew one the resolver rightly does not: the hovered, focused and
pressed layers of `surface_sunken` in light and of every surface but
`surface` in light high contrast, where the showcase's port did not
check `on_surface` and its full layers would take it below its target;
`outline_muted` disabled, which the port left unfaded; and `danger`,
darkened by the owner's choice (`roadmap/decisions.md`). The text styles
match at text scale 1 and 1.5.

Slice 2 is done: `zui_widgets.DesignSkin(Ui)`, and
`DesignSkinWith(Ui, ExtraRoles)`, style every part from the tokens they
point at, through one component whose `zuiAppearance` declares each
part's roles, tiers and shapes from the plan's `components`; sizes come
from the tokens' control heights, and the spec's literals (a 2-unit
caret, a 4-unit track, a 20-unit thumb, a checkbox of 16, 18 and 20 by
density) are constants of the skin. A button takes the spec's five
variants, each a `Part` of its own. `Style` gains the corner's shape and
a popup's shadow, which the dropdown's list draws at the `floating`
elevation. Every widget passes the audit, text and focus ring contrast,
target floors and overlap, in all four schemes and all three densities
(`core/zui_widgets/tests.zig`). `DefaultSkin` is gone: the tour resolves
its widgets' tokens when the environment's preferences change, and One
Declaration one set per view; the showcase and the native host's
examples resolve the default design in dark, as their palettes are.
Where the spec could not be kept: the slider's thumb is ringed in
`outline`, not `accent`, since light high contrast draws `accent` and
`focus` alike, so a focused thumb would look idle; the focus ring is not
yet offset from the part (`11-polish:25-focus-ring-on-fills`); button
sizes, and the toggle, the text area, the progress bar and the image,
which `zui_widgets` does not have yet, wait for their items. The tour's
test now also audits focus rings in the tokens' color, and no longer
finds dark's `on_accent` in light, which One Declaration's dark button
drew. `hosts/web`'s `test-draw` fails on one frame
(`10-reach:08-ring-edges-agree`); every other check listed for the
packages it touches passes.

Slice 3 is done: the tour and the showcase draw every color from the
tokens they resolve, and neither has a palette. The tour's `Palette`
gave way to `Colors`, each role's color at rest, which the `Shell` holds
beside the tokens, each entry by its use as the owner chose; an
`Emphasis` (neutral, accent, success, warning, danger) gives a status
its fill, its container, the text on the container and its text on a
surface, so a chip, a pill or a legend takes the container and its text
rather than a mix of the fill. The Spectacle lane takes the accent, and
where four categories had taken the spectacles' violet (Gesture Arena's
lasso, the frame reasons, Time Machine's balls) they take danger or
warning. A selected row is drawn in `selection`, its quiet columns in
`on_selection`; tooltips in `surface_inverse`; Harbor's own primary
button takes the tokens' hovered and pressed layers of `accent`; Light
Lab's gradient holds each end no lighter than `accent`, so `on_accent`
reads on it, and its frosted panes name themselves on a tag in
`surface_inverse`. The header's buttons, Gesture Arena's zoom, One
Declaration's environment bar and Log Tail's Pause and Clear take the
`secondary` variant. One Declaration's views resolve their own tokens
and draw from them. A preferences screen,
`apps/tour/src/screens/preferences.zig`, chooses density, color vision,
contrast and text size over what the environment reports, held in the
tour as `PreferenceChoices`; `Appearance.follow` resolves again only
when the combined preferences change, and the screen shows the
preferences, control heights, status colors and widgets they give. The
showcase resolves the default design in dark, compact in cells, and
draws from it, with an audit of its text in its test.

The tour's test expects no text contrast finding in light or dark: from
2,350 to none. What it still finds, in each theme: the focus ring on the
checked `1 Hz` box (`11-polish:25-focus-ring-on-fills`) and 32 targets
below 24 units on Harbor X-ray (14), One Declaration (10), Log Tail (4),
Settings Form (3) and Photo Culling (1) (`11-polish:26-small-targets`);
33 before, the same screens. A new test resolves the preferences
screen's choices, compact, protan, high contrast and 150% text, over a
normal environment, and audits it clean; the showcase's text audits
clean with and without its dialog. Passing: `apps/tour` and
`apps/showcase` `test` in all three modes, `check` and
`check -Dtarget=x86_64-windows`; the terminal renderer's `test`, `check`
for Linux, Windows and macOS, `showcase -- --dump` and
`tour -- --dump --every-screen`; the raylib renderer's `test`, `check`,
`conformance`, the tour's cycle (600 frames, `diagnostics ok: true`),
the showcase (60 frames, `diagnostics ok: true`) and
`tour -- --measure-idle` (7.6 ms of CPU over 10 s, one frame); and
`hosts/web`'s `test-demo` in Debug and ReleaseSafe. `test-draw` now
compares a frame of all fifteen screens, not the first thirteen. It
failed on Harbor X-ray's ring edges before
(`10-reach:08-ring-edges-agree`); that frame matched in this run, on the
NVIDIA GPU. It fails on Clickable Chaos, which it did not compare
before: 758 pixels at one sample per pixel, by at most 137, and 481 at
four without text, at the edges of the turned cards. The preferences
screen matches.

## 11-polish:20-appearance-audit — The appearance audit

Checks of a finished frame's commands, which catch what the declarations
cannot: custom drawing and colors declared `.unchecked`.

**Grounding** (at `3f4ff58`). A frame's commands are in paint order
(SPEC.md §13.2), so the rectangle beneath a text command is found by
walking back. The terminal tour already fails on text cut short
(`renderers/terminal/examples/tour.zig:40`). Hit regions and semantics
are kept beside the frame (SPEC.md §13.4, §13.5).

**Plan.** `zui_design.audit(Ui, frame, tokens, options) Findings`, into
room the caller gives: text contrast against what is painted beneath,
focus ring contrast, hit target size, text cut short, overlapping
controls, and each `zuiDistinguish` pair under every color vision
simulation. Each finding names its element, its check and the measured
value.

**Done when.** `zui_design`'s tests: a scene with one fault of each kind
reports exactly those; the tour's every screen audits clean, or each
finding is an item.

**Waits for** `11-polish:14-zui-design`.

**Spec.** §18.8.

**Status.** Done. `core/zui_design/audit.zig`:
`zui_design.audit(frame, options, room) Findings` checks a finished
frame into the caller's room, allocating nothing, keeping what fits and
counting the dropped, as `Repairs` does. A `Finding` names its element,
the index `Frame.inspect` takes, and its id hash, its check
(`AuditCheck`), and in `Measured` the value with its target: a contrast
with the two colors measured, a size and the floor, a line's width and
how much of it shows, the other control and the overlap. Text is
measured at the middle of each line against the topmost rectangle,
border band or gradient painted there, found by walking back through the
commands with their clips and blending translucent fills, over
`AuditOptions.page_background`; text over an image, a material or a
custom command, or inside a transform, is not measured, nor is a
disabled element's. `title` size and up takes a new tier,
`Tier.large_text` (Lc 60 and 3:1). A focus ring is a border in
`AuditOptions.focus_ring_color`, since the frame does not record focus,
measured just outside and just inside it. A target is every interactive,
enabled, visible element against the floor; text is cut short when a
line runs past its clip's side, where no enclosing clip scrolls
sideways; two controls overlap when their visible areas, inside every
clip around them, meet by more than half a unit, in one floating layer,
neither inside the other.
`auditDistinguished(tokens, components, *Findings)` checks
`zuiDistinguish` pairs in the colors `tokens.look` gives, with a chosen
accent and color vision. `AuditOptions.fromTokens` takes the page, the
focus color, the floor and the title size from tokens. An element
without an id is found by searching from the last one found, since
commands come nearly in declaration order. Eight tests in
`core/zui_design/audit_tests.zig`: one fault of each kind found exactly,
naming its element and value; a clean scene clean; room for 2 of 5
keeping the first and dropping 3; checks turned off; a translucent fill
blended; a disabled control's text skipped; large text's target;
distinguish pairs, with a cue and apart; `fromTokens`.
`core/tests/instantiate.zig` runs both audits.

The tour's test audits every screen in light and dark, settled, with Tab
pressed so a control shows its ring: 2,418 findings, none dropped in a
room of 1,024. 2,350 are text contrast in the tour's palette, which
moves to tokens in `11-polish:19-default-design`, whose Grounding and
Done when now carry them; 2 are the focus ring on the checked `1 Hz`
box, `11-polish:25-focus-ring-on-fills`; 66 are 33 targets below 24
units in each theme, `11-polish:26-small-targets`. Nothing is cut short
and no controls overlap. The test classifies each finding by check and
by the palette entry its text is drawn in, or the screen of its target,
and fails on a finding it cannot classify and on a recorded cause no
longer found. The harness had shown the light overview in dark: the tour
asks for dark when it starts, and that came after the requested theme in
the first frame, so the harness now draws a frame before it asks. In
ReleaseFast an audit of a tour screen takes 53 µs (Time Machine, 306
commands) to 680 µs (Break It, 2,546 commands), and 1.6 ms for Clickable
Chaos, whose 800 elements are mostly controls the overlap check pairs,
measured while other builds shared the machine.

## 11-polish:21-permutations — Every permutation of a component

The axes a component is seen under, at the levels a person can review,
each permutation with a stable key and a hash of its commands.

**Grounding** (at `3f4ff58`). `zui_testing.Driver`
(`core/zui_testing/zui_testing.zig:71`) runs complete frames headlessly,
and its snapshot writes one line per command (`:441`). The tour already
declares every screen on renderers that draw every optional command and
none (`apps/tour/src/tests.zig`).

**Plan.** In `zui_design`: `Axes`, the axes of SPEC.md §18.8;
`Permutations(level)`, at `glance`, `sweep`, `pairs` (a covering array
built at comptime) and `full`; the `zuiPreviews` contract for a
component's content fixtures; and `PermutationKey` with a command hash
that is identical in Debug and release builds.

**Done when.** `zui_design`'s tests: every pair of axis values appears
in `pairs`; the same declaration hashes the same on every target `check`
builds; a change of one color changes only the hashes of permutations
that draw it.

**Waits for** `11-polish:13-design-vocabulary`.

**Spec.** §18.8.

**Status.** Done. `core/zui_design/permutations.zig`: `Axes`, one value
of each of SPEC.md §18.8's axes but the content, the user's defaults
unless set, with `preferences(base)` for `resolve` and
`environmentChanges()`, the five changes that set theme, contrast, text
scale, reduced transparency and direction, for a frame's events; the
`WidgetState` is `axes.state`, for `tokens.look`. `TextScale` names 1,
1.5 and 2 as `100%`, `150%` and `200%`. `Permutations(Component, level)`
gives `count`, `at(index)`, `preview(permutation)`, `previewName` and
`key`, the content axis from the component's `zuiPreviews`. `glance` is
the defaults, dark, dark at high contrast, compact at 200% and all of
them right to left, with each further preview at the defaults and at
every extreme: 5, and 9 with three previews. `sweep` is the defaults and
then each axis's other values: 19, and 21 with three previews. `pairs`
is a covering array of strength 2, made at comptime by a greedy
construction (each row from the first pair still uncovered, every other
axis given the value covering most new pairs): 27 for a component with
no previews, 28 with three and 27 with two, against a floor of 25, the
two five-value axes' product; SPEC.md §18.8's range for it now starts at
25, and its glance row says what glance is. `full` decodes an index into
every axis, 10,800 permutations without previews and 32,400 with three.
`zuiPreviews` is checked by `zui.checkPreviews` in
`core/src/contracts.zig`, a struct literal of named previews of one
type, pinned by `previews_of_two_types`. `PermutationKey` formats as
`component/preview/theme=dark,contrast=high,…`, every axis in order, and
parses back, refusing a malformed key, an unknown axis or value, a
repeated axis and a missing one. `hashCommands` hashes each command's
fields in order with Wyhash, integers little-endian at whole-byte
widths, floats by their bits with `-0` as `0` and every NaN as one,
enums and union tags by name, text by length and bytes, and refuses at
compile time any pointer but text; it runs at comptime. Nine tests in
`core/zui_design/permutations_tests.zig`: every pair of axis values in
`pairs` for three components; glance, sweep and full; keys; axes as
preferences; a fixed declaration hashing to one constant, which passes
natively, on `x86-linux`, in all three modes, and on big-endian
`powerpc-linux` under `qemu-ppc-static` (all 60 of `zui_design`'s tests
pass there); `-0` and NaN; and a swatch that draws `danger` only when
pressed, whose sweep permutations change hash when `danger` changes
exactly where the state is `pressed`. `core/tests/instantiate.zig`
hashes `zuiCheckFrame`'s frame, whose commands carry images and custom
data, and round-trips a key of a component with previews. In ReleaseFast
a hash takes about 35 ns a command (6 µs for 171 commands, three runs,
while other builds shared the machine).

## 11-polish:22-appearance-review — The appearance review

A person steps through the permutations, answers yes or no with an
optional remark, and gets a report of what needs work.

**Grounding** (at `3f4ff58`). The tour is one app over any host,
renderer and font system (`apps/tour/src/tour.zig`), run natively and in
a browser; the raylib renderer takes screenshots
(`renderers/raylib/examples/tour.zig`).

**Plan.**

1. `apps/review/`, the module `zui_review`: an app over the
   application's components that shows each permutation of a level with
   its axis values and the audit's findings; **Y**, **N** and **R** (a
   remark, with a region dragged over the part it is about); arrows
   step, `[` and `]` move between axes.
2. Verdicts in a ZON file in the application's repository, keyed by
   `PermutationKey` and holding the command hash; a verdict whose hash
   no longer matches is stale and asked again.
3. The report, in Markdown and as an HTML page with an image of each
   permutation, grouped by component, then by the axis that brings the
   trouble, with the token or part to change where it can be told.
4. A build step that fails on a permutation that is stale, flagged, or
   failing the audit, for CI.

**Done when.** The review app's headless test steps a scripted session
of verdicts, writes them, changes one token, and finds exactly the
permutations it touched stale; the report of that session is pinned as a
golden; the raylib and web builds open it.

**Waits for** `11-polish:20-appearance-audit`,
`11-polish:21-permutations`.

**Spec.** §18.8.

## 11-polish:23-design-workbench — The design workbench

One component, live, in a grid of its glance permutations, restyled as
its design file is saved, with a badge on the moment a check fails.

**Grounding** (at `3f4ff58`). Editing a theme file restyles a running
window within 4 ms through the host's file watch (stage 5);
`zui_debug`'s inspector reloads its theme the same way
(`core/zui_debug/zui_debug.zig:136`).

**Plan.** A mode of the review app: the glance permutations of the
component under work, the design read from a watched ZON file, the audit
run on every frame that changes, and `zig build --watch` for code.

**Done when.** Saving a design file restyles every permutation in the
grid within 50 ms of the save on this machine; a change that fails a
check shows its badge in the same frame.

**Waits for** `11-polish:22-appearance-review`.

**Spec.** §18.8.

## 11-polish:24-the-tour — The tour, redone

Taken out of the queue at the owner's request.

**Grounding.** The tour had twelve screens, one per feature
(`apps/tour/src/screens/` at f6051f4), which the owner found too wacky
to show zui in its best light, and a Classic screen that declared
`zui_showcase`.

**Plan.** Replace every screen with four lanes: an overview; Harbor, an
operations console that uses every feature with restraint, and its
X-ray, the same console with nodes that explain each feature with live
proof; field cases, each a real problem solved plainly; and spectacles,
each one claim proved live. Use what zui does today, and leave what it
cannot do yet to later items.

**Done when:** every screen declares within its limits and fits the
default window in pixels and in cells; the tour's cycle, the terminal's
`--every-screen` dump, `test-demo`, `test-draw`, `test-input` and
`test-site` pass; and the tour idles on its first screen.

**Spec.** §6.6, §6.8, §8, §11, §13.5, §14, §17.2, §18, §19.

**Status.** Done: fourteen screens in four lanes, described in
`apps/tour/README.md`. On raylib the overview idles at 0.055% of one
core with 1 frame in 10 s, and on the Linux host at 0.046%. Not shown
yet: HDR white in the Light Lab, since the tour's `Ui` declares
`zui.Color`; wheel zoom in the Gesture Arena, since `Manipulation` does
not say a wheel moved it; custom semantic actions on Kanban's cards,
which zui lacks. Break It keeps its render-command load below the limit
until the emitter keeps room for open clips (ARCHITECTURE.md §7). Since
`11-polish:16-corner-shapes`, cards and Harbor's panels declare
continuous corners, which the raylib and terminal tours draw round and
report; Harbor's X-ray has a fourteenth node for them, and the Light Lab
shows all three shapes. The tour's palette moves to `zui_design`'s
tokens in `11-polish:19-default-design`.

## 11-polish:25-focus-ring-on-fills — A focus ring that shows on a filled control

The focus ring stands apart from the control it rings and from what is
around it, also on a control filled with the accent.

**Grounding** (at `8a8507e`). `11-polish:20-appearance-audit` found the
ring of the tour header's checked `1 Hz` checkbox
(`apps/tour/src/tour.zig:275`) at Lc 0 and 1:1 in light, where the
ring's color, the palette's `focus`, is the box's own accent fill
(#2f62e9 on #2f62e9, `apps/tour/src/shared.zig:273`), and at Lc 16 and
1.48:1 in dark (#8fb0ff on #5b8cff), against the non-text target of Lc
45 and 3:1. The tour hands `zui_widgets`' skin its palette's `focus` as
`focus_ring` (`apps/tour/src/kit.zig:165`), and the skin draws the ring
as the box's own 2-unit border (`core/zui_widgets/zui_widgets.zig:274`),
inside the fill. Tab reaches the box from the kanban screen in light and
the Clickable Chaos screen in dark in the tour's test.

**Plan.** Draw the ring outside a filled control, with a gap in the
surface's color, or give `focus` a color apart from `accent` in both
themes; take whichever keeps the ring Lc 45 and 3:1 from both its
neighbors in light, dark and high contrast.

**Done when.** The tour's test no longer expects a `focus_ring_contrast`
finding, in light or dark; `test-all`, `check-all`.

**Spec.** §18.2, §18.4.

## 11-polish:26-small-targets — Targets of at least 24 units in the tour

Every control the tour declares can be hit at the floor of SPEC.md
§18.5.

**Grounding** (at `8a8507e`). `11-polish:20-appearance-audit` found 33
interactive elements under the 24-unit floor, in light and in dark
alike: X-ray's fourteen numbered markers, `1` to `14`, 14 to 20 units
wide and 18 tall (`apps/tour/src/screens/harbor.zig:1212`); Photo Cull's
scrollbar, 10 units wide (`apps/tour/src/screens/photo_cull.zig:617`);
Log Tail's level chips, `DEBUG`, `INFO`, `WARN` and `ERROR`, 23 tall;
Settings Form's text scale choices, `100%`, `150%` and `200%`, 21 tall;
and One Declaration's `Autopay` and `Email receipts` toggles, 18 tall in
four of its variants and 13 in the fifth, with its `Pay $786.00` button
there 22 tall (`apps/tour/src/screens/one_declaration.zig:226`).

**Plan.** Raise each to the floor, by its height or by padding a hit
area around what it draws, so the look need not grow.

**Done when.** The tour's test no longer expects a `target_size`
finding, in light or dark; `test-all`, `check-all`.

**Spec.** §18.5.

## 11-polish:27-essential-inputs — Essential inputs

The inputs a consumer app reaches for first, and the rest of the
existing widgets' specs: D4 of the default design's plan.

**Grounding** (at `1aa1061`). `zui_widgets` declares `label`,
`mutedLabel`, `labeledRow`, `disclosure`, `button`, `checkbox`, `lasso`,
`slider`, `textField` and `dropdown`
(`core/zui_widgets/zui_widgets.zig:498`), styled by `DesignSkin`
(`:236`) through one component, `Designed` (`:355`), whose `Part`s map
from `zui_widgets.Part` (`:103`). A button takes a `ButtonVariant`
(`:478`) but no size or icon. Its specs are the entries `radio_group`,
`segmented_control`, `number_stepper`, `search_field`, `icon_button`,
`link`, `chip` and `toggle` of `components` in
`docs/plans/default-ui-designs/exports/zui-default-design.json`, and,
for the existing widgets, `button`, `text_field`, `label`,
`labeled_row`, `slider`, `dropdown` and `disclosure`.

**Plan.**

1. New widgets: `radioGroup` and `segmented` over an enum,
   `numberStepper` over any integer or float, `searchField` with its
   shortcut hint, `iconButton` with a required accessible label, `link`,
   which returns true when activated and leaves opening the URL to the
   application's `open_url` service, `chip` (selectable or closable) and
   `toggle`.
2. The existing widgets' remaining spec: `button`'s `size` (a
   `ControlSize`) and `leading_icon`; `textField`'s `label`, `help`,
   `error`, `leading_icon` and `trailing`; `label`'s type role and tone
   (`default`, `muted`, `accent`); `labeledRow`'s description and its
   divider, rows on one card; the slider's value bubble while dragging
   and its ticks; the dropdown's check on the selected option; the
   disclosure's chevron, turning with `motion.disclosure`.
3. Motion from `Tokens.motion`: the press scale, the toggle's spring,
   the checkbox's check.

**Done when.** The components' common Done when (*The design system*).

**Waits for** `11-polish:19-default-design`, `11-polish:07-zui-icons`,
`11-polish:36-motion-in-core`.

**Spec.** §18, §19.2.

**Status.** Not started.

## 11-polish:28-containers-and-navigation — Containers and navigation

What holds and moves between content: D5 of the default design's plan.

**Grounding** (at `1aa1061`). `Tokens.elevations`
(`core/src/design.zig:486`) gives the `raised` level a card stands at,
its shadow, rim and surface role. Scrolling is the core's
(`Element.scroll`, `core/src/context.zig:218`; `scrollOffset` and
`setScrollOffset`, `:2771`, `:2777`). The specs are `card`, `divider`,
`scroll_area`, `group_box`, `tabs`, `navigation_list` and `breadcrumbs`
in `docs/plans/default-ui-designs/exports/zui-default-design.json`, with
the scrollbar's metrics in its `metrics.scrollbar`.

**Plan.** `card` (open and closed, at the `raised` elevation, optionally
interactive), `divider` (an axis, an inset, an optional label),
`scrollArea` with the design's scrollbar, thin at rest and wider while
hovered, fading when idle, `groupBox`, `tabs` over an enum (underline
and pill styles, arrow keys moving the selection), `navigationList`, the
sidebar's list, whose rows hover in `secondary_container`, and
`breadcrumbs`, which return the crumb chosen.

**Done when.** The components' common Done when (*The design system*).

**Waits for** `11-polish:19-default-design`.

**Spec.** §18, §19.2.

**Status.** Not started.

## 11-polish:29-overlays — Overlays

What floats over the page: D6 of the default design's plan.

**Grounding** (at `1aa1061`). The dropdown's list
(`core/zui_widgets/zui_widgets.zig:999`) is the pattern: a backdrop
attached to the root, a `floating` element attached to its anchor, a
`focus_scope`, and the `dismiss` action read by `ui.dismissed`
(`core/src/context.zig:2604`), at the `floating` elevation. The specs
are `tooltip`, `menu`, `popover`, `dialog` and `toast` in
`docs/plans/default-ui-designs/exports/zui-default-design.json`, with
the tooltip's delay, the toast's seconds and each overlay's greatest
width in its `metrics`.

**Plan.** `tooltip` after the hover delay, or at once on keyboard focus;
`menu` and its items (shortcuts, icons, checked and danger items), also
as a context menu at the pointer; `popover` placed below, above or
beside its anchor and flipped to stay on screen; `dialog` over the
`scrim`, at the `modal` elevation, trapping focus and returning it to
its opener; `toast`, queued, with an action, dismissed after its
seconds. Each enters and exits with `Tokens.motion`, and at once under
reduced motion.

**Done when.** The components' common Done when (*The design system*),
and focus returns to an overlay's opener when it closes.

**Waits for** `11-polish:28-containers-and-navigation`,
`11-polish:36-motion-in-core`.

**Spec.** §18, §19.2.

**Status.** Not started.

## 11-polish:30-feedback-and-media — Feedback and media

What tells the user how things stand, and the images that show who and
what: D7 of the default design's plan.

**Grounding** (at `1aa1061`). The status containers and their text,
`danger_container` to `on_success_container`, are roles since slice 1 of
`11-polish:19-default-design` (`core/src/design.zig:10`). An avatar
without an image takes `accent_container` at a hue hashed from the name,
from the eight accent presets, and a chart's series take the presets
too: neither is a role, and `zui_widgets` cannot resolve a palette. The
specs are `banner`, `badge`, `spinner`, `skeleton`, `empty_state`,
`avatar`, `progress_bar` and `async_image` in
`docs/plans/default-ui-designs/exports/zui-default-design.json`.

**Plan.**

1. `Tokens` gains a categorical palette: for each of the eight accent
   presets in `accents` of the JSON, its fill, its container and their
   text, resolved and checked by `zui_design.resolve` as the built-in
   roles are.
2. `banner` and `badge` in each tone, `spinner` (still under reduced
   motion, its arc shown), `skeleton` (lines, a block, a circle;
   shimmering unless motion is reduced), `emptyState`, `avatar` with its
   initials, presence and stacks, `progressBar` (determinate, and
   indeterminate sliding, or pulsing under reduced motion), and
   `asyncImage`, which takes its source as `anytype` with a status, so
   `zui_widgets` need not import `zui_async`.

**Done when.** The components' common Done when (*The design system*),
and every categorical color meets its text's target in every scheme.

**Waits for** `11-polish:19-default-design`, `11-polish:07-zui-icons`,
`11-polish:36-motion-in-core`.

**Spec.** §18.4, §19.2.

**Status.** Not started.

## 11-polish:31-rich-text-and-reordering — Rich text and the reorderable list

Text with structure, and lists the user rearranges: D8 of the default
design's plan.

**Grounding** (at `1aa1061`). Drag and drop is the core's:
`ui.startDrag(source, payload)` and `ui.draggedOver(target, Payload)`
(`core/src/context.zig:2545`, `:2580`), as the tour's Kanban moves cards
(`apps/tour/src/screens/kanban.zig:420`). The specs are `rich_text` and
`reorderable_list` in
`docs/plans/default-ui-designs/exports/zui-default-design.json`; the
spec's emphasis, body_strong in the accent text, gives way to italic,
since the owner chose to bundle italics.

**Plan.**

1. `richText` over a Markdown subset: paragraphs at the measure, two
   heading levels, strong, emphasis in italic, links (the `link`
   widget), inline code and code blocks, quotes and lists, laid out from
   a caller's buffer without allocating; selecting its text once
   `11-polish:06-text-editing` gives selection.
2. `reorderableList`: a row dragged at the `topmost` elevation, the
   others moving aside with `motion.reorder`, and Alt+Up and Alt+Down
   moving the focused row; it returns the move for the application to
   apply.

**Done when.** The components' common Done when (*The design system*).

**Waits for** `11-polish:28-containers-and-navigation`,
`11-polish:35-italics`, `11-polish:36-motion-in-core`;
`11-polish:06-text-editing` for selection in rich text.

**Spec.** §18.6, §19.2.

**Status.** Not started.

## 11-polish:32-zui-widgets-data — `zui_widgets_data`

A module of the components for data-heavy tools: D9 of the default
design's plan.

**Grounding** (at `1aa1061`). Modules cannot import one another (SPEC.md
§3.3), so the module takes a `Widgets` value as `anytype`, as
`zui_reflect.inspector` does (`core/zui_reflect/zui_reflect.zig:70`).
The tour's Harbor declares only the rows in view
(`apps/tour/src/screens/harbor.zig:284`). The specs are `table`, `tree`,
`split_pane`, `toolbar`, `status_bar`, `command_palette` and
`property_grid` in
`docs/plans/default-ui-designs/exports/zui-default-design.json`.

**Plan.** The module, registered at every point CLAUDE.md's row for a
module names, with `table` (sticky header, sort, selection, resizable
columns, numeric cells, only the visible rows declared), `tree`
(expansion and selection sets, arrow keys), `splitPane`, `toolbar`,
`statusBar`, `commandPalette` (filtered as typed, at the `topmost`
elevation) and `propertyGrid`, whose look `zui_reflect.inspector` takes
too. SPEC.md gains a section for the module after §19.2, its row among
§3's modules and §21's stage 11 scope; ARCHITECTURE.md's package table
names it.

**Done when.** The components' common Done when (*The design system*),
and a table of a million rows declares as fast as one of a hundred.

**Waits for** `11-polish:29-overlays`.

**Spec.** §3.3, §18, §19.

**Status.** Not started.

## 11-polish:33-pickers — Pickers

Choosing a color, a date, a time or a file: D10 of the default design's
plan.

**Grounding** (at `1aa1061`). Dropped files arrive as an event
(`files_dropped`, `core/src/input.zig:239`), and dragged payloads
through `ui.draggedOver`. Formatting dates for a locale is out of scope
(ARCHITECTURE.md §6), so the pickers take their month and weekday names
from the application. The specs are `color_picker`, `calendar`,
`date_picker`, `time_picker` and `drop_zone` in
`docs/plans/default-ui-designs/exports/zui-default-design.json`.

**Plan.** In `zui_widgets_data`: `colorPicker` (a field of lightness and
chroma, a hue strip, alpha, swatches), `calendar` and `datePicker` over
a plain date the module defines, with ranges, `timePicker` stepped by
minutes, and `dropZone`, which accepts files and payloads by type.

**Done when.** The components' common Done when (*The design system*).

**Waits for** `11-polish:32-zui-widgets-data`.

**Spec.** §18, §19.

**Status.** Not started.

## 11-polish:34-zui-widgets-views — `zui_widgets_views`

A module of views that show data rather than edit it: D11 of the default
design's plan.

**Grounding** (at `1aa1061`). The tour's Log Tail follows a busy log and
Harbor draws sparklines, each by hand. A chart's series take the
categorical palette of `11-polish:30-feedback-and-media`. The specs are
`code_view`, `sparkline`, `chart`, `timeline`, `node_graph` and
`minimap` in
`docs/plans/default-ui-designs/exports/zui-default-design.json`.

**Plan.** The module, registered as a module is, with `codeView` (line
numbers, highlights, following the tail, only visible lines declared),
`sparkline`, `chart` (bars and lines, at most six series, grid and axis
labels, a tooltip per point), `timeline` (a playhead, markers, ranges),
`nodeGraph` (pan and zoom, nodes, ports and curved edges) and `minimap`.
SPEC.md and ARCHITECTURE.md gain it as `11-polish:32-zui-widgets-data`
adds its module.

**Done when.** The components' common Done when (*The design system*).

**Waits for** `11-polish:19-default-design`,
`11-polish:30-feedback-and-media`.

**Spec.** §3.3, §18, §19.

**Status.** Not started.

## 11-polish:35-italics — Italics

Italic text, which the owner chose to bundle rather than draw emphasis
as weight.

**Grounding** (at `1aa1061`). `zui_fonts` embeds Atkinson Hyperlegible
Regular and Bold and Liberation Mono (`text/fonts/zui_fonts.zig:14`,
`:18`, `:22`), under the OFL and Liberation's licence. A design names
three fonts, `regular`, `strong` and `monospace`, in `Design.Fonts` and
`Design.Faces` (`core/src/design.zig:174`, `:166`).

**Plan.** Atkinson Hyperlegible Italic and Bold Italic join `zui_fonts`,
under the same OFL, in `.paths`; `Design.Fonts` and `Design.Faces` gain
`italic` and `strong_italic`, each the upright font when not given; the
resolver sizes them by their faces as the others; `Tokens` gives each
type role's italic, so a part that draws emphasis takes its role's
italic; the tour and the showcase load them.

**Done when.** `zui_fonts`' test finds both, with their licence;
`zui_design`'s tests resolve an italic for every type role, the upright
one when none is given; the text packages' `test` and `check`, and
`test-all` and `check-all`.

**Spec.** §18.6.

**Status.** Not started.

## 11-polish:36-motion-in-core — Motion in the core

Tweens and springs the widgets can reach, with the design's motion in
its tokens, as the owner chose.

**Grounding** (at `1aa1061`). `zui_motion` holds `Easing`, `tween` and
`spring` (`core/zui_motion/zui_motion.zig:15`, `:65`, `:115`), built on
`ui.state` and `ui.dt`; `zui_widgets` cannot import it (SPEC.md §3.3).
The design's motion tokens, from press to reorder, are in
`docs/plans/default-ui-designs/exports/tokens.zig.txt`.

**Plan.** `Easing`, `TweenOptions`, `SpringOptions`, `tween` and
`spring` move to `core/src/motion.zig`, exported as `zui.motion`;
`zui_motion` re-exports them, so its callers do not change. `Tokens`
gains `motion`, each token a `TweenOptions` or `SpringOptions` and the
press scale, which `zui_design.resolve` writes from the default design.
ARCHITECTURE.md §6's motion row and SPEC.md §19.9 say where motion
lives.

**Done when.** `zui_motion`'s tests pass unchanged through the
re-export; `counts` is within 2% of the parent commit, since nothing
that does not animate calls the moved code; core's checks for a change
to `core/src/`; `test-all` and `check-all`.

**Spec.** §19.9.

**Status.** Done: `core/src/motion.zig`, exported as `zui.motion`, holds
`Easing`, `TweenOptions`, `SpringOptions`, `tween` and `spring`, moved
from `zui_motion` unchanged but for reaching `Id`, `Color`,
`ExtendedColor` and `Instant` through their core files; `zui_motion`
re-exports them, and its 12 tests and its compile-error case pass with
`tests.zig` and the message untouched. `zui.design.Motion` holds the 13
motion tokens and `press_scale`; the design owns it as `Design.motion`,
and `Tokens.motion` defaults to `.{}` (`zui.motion`'s own options and a
scale of 1), so every existing literal compiles; `zui_design.resolve`
copies it as declared, since under reduced motion the tweens and springs
land by themselves. `zui_design.default` carries the approved values.
New tests: core's `tests/motion.zig` (`zui.motion` reached directly, and
a token driving a tween), `zui_design`'s default motion reaching every
token, a custom design's motion reaching the tokens in every theme, and
`resolve` writing `motion` in the poisoned-tokens sweep;
`core/tests/instantiate.zig` springs and tweens through `zui.motion`
with the default design's tokens. `test` in Debug, ReleaseFast,
ReleaseSafe and `x86-linux`, `check` for `wasm32-freestanding` and
`powerpc-linux`, `test-all` and `check-all` pass. `counts -- --compare`
against `2ba7904`: all 175 events +0.00% (4096 boxes at depth 8: declare
438141, endFrame 1265648 instructions, unchanged), since nothing that
does not animate calls the moved code.

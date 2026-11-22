# 11-polish: Polish

Stage 11 of SPEC.md §21: `zui_motion` and exit ghosts; full text editing
with IME; `zui_color`, `zui_icons`, skins and theme packs; samples and the
template. Its items are numbered in the queue's dependency order, and each
is given its Grounding, Plan and Done when as it is taken.

**Done when (each):** `zui_testing` coverage; IME works on Windows.

**Spec.** §19.2, §19.8, §19.9.

## Items

| Item | Status |
|---|---|
| `11-polish:01-zui-motion` `zui_motion` | done |
| `11-polish:02-exit-animations` Exit animations | done |
| `11-polish:03-zui-color` `zui_color` | done |
| `11-polish:04-skin-contract` The skin contract | done |
| `11-polish:05-default-skin` The default skin | not started |
| `11-polish:06-text-editing` Text editing | not started |
| `11-polish:07-zui-icons` `zui_icons` | not started |
| `11-polish:08-zui-themes` `zui_themes` | not started |
| `11-polish:09-template-project` The template project | not started |
| `11-polish:10-samples` Samples | not started |
| `11-polish:11-profiling-guide` A profiling guide | done |
| `11-polish:12-developer-experience-audit` A developer-experience audit | not started |

---

## 11-polish:01-zui-motion — `zui_motion`

Tweens over `state(id, T)` and `dt()`, requesting frames by instant and
finishing at once under `reduced_motion`.

**Grounding.** Everything a tween needs is public on a context:
`ui.state(id, T)` (`core/src/context.zig:2691`) gives per-element state,
created zeroed and kept while the id keeps being used, and returns zeroed
scratch while reporting `.state_slots` when the table is full (`:2694`),
so a tween's state must mean "at rest" when zero; a state type is at most
64 bytes (`core/src/state.zig:4`, `:13`). `ui.now()` and `ui.dt()`
(`core/src/context.zig:1272`, `:1278`) read the record's clock, 0 for `dt`
on the first frame. `ui.requestFrame()` and `ui.requestFrameAt(instant)`
(`:1180`, `:1185`, keeping the earliest) feed `nextFrame` (`:1173`), and
both are cleared at each `beginFrame` (`:981`). `zui.Instant`
(`core/src/record.zig:7-38`) has `addSeconds`, `secondsSince` and
`isBefore`. `ui.environment().reduced_motion` (`core/src/input.zig:314`)
arrives as an `.environment` event. `Color.mix`
(`core/src/style.zig:51`) interpolates sRGB channels. The modules are
registered at `core/build.zig:206-220` (`b.addModule`), `:227`
(`tested_modules`), `:232` (driven tests), the compile-error and `check`
imports, and `formatted_paths`; `.paths` in `core/build.zig.zon`, and
`core_modules` in the root `build.zig:35`. `zui_testing.Driver`
(`core/zui_testing/zui_testing.zig:71`) advances `now` by
`frame_interval_ns` per frame.

**Plan.** One slice, a module `zui_motion` built only on the public API,
adding nothing to the core:
- `Easing`: `linear` and cubic `ease_in`, `ease_out` and `ease_in_out`,
  each exact at 0 and 1.
- `tween(ui, id, T, target, options)`: the first target is where it
  starts; a new target starts a tween from the current value, so a
  retarget is continuous; it eases over `duration` from an instant held in
  its state, so it lands exactly at its duration, and it asks for the next
  frame while moving, for a frame at the instant a `delay` ends, and for
  none at rest.
- `spring(ui, id, T, target, options)`: a critically damped spring stepped
  exactly by `dt()`, keeping its velocity across retargets, landing within
  `rest_distance`; the frame it leaves rest it does not advance, since the
  time since the previous frame was spent at rest.
- Under `reduced_motion` both land on the target in the frame it changes.
- A value is `f32`, `[N]f32`, `zui.Color` (per sRGB channel, as
  `Color.mix`; `11-polish:03-zui-color` may refine it),
  `zui.ExtendedColor` (per linear channel), or a struct of them; any other
  type is a compile error, pinned by
  `core/tests/compile_errors/motion_value_not_animatable.zig`.
- Registered at every point a module is, exercised in
  `core/tests/instantiate.zig`, and documented in the README, the feature
  tour and ARCHITECTURE.md. SPEC.md §19.9 says how frames are asked for.

**Done when.** Core's tests in Debug, ReleaseFast, ReleaseSafe and on
`x86-linux` pass, with `zui_motion`'s own: a tween reaches its target at
its duration, asking for every frame until then and none after; the
easings' endpoints are exact; under `reduced_motion` a tween and a spring
land in one frame without asking for another, and a moving tween lands
when it turns on; a retarget starts from the value the old tween had
reached; a delayed tween asks for the instant it starts; a full state
table reports `.state_slots` and the tween returns its target; colors and
structs are tweened per channel and field; a spring never overshoots and
stops asking at rest. `check` passes natively, for `wasm32-freestanding`
and `powerpc-linux`, and `check-all` passes, so the root re-exports
`zui_motion`. No allocation and no change under `core/src/`.

**Spec.** §19.9.

**Status.** Done: `core/zui_motion/` with `Easing`, `tween` and `spring`,
12 tests and one compile-error case, in Debug, ReleaseFast, ReleaseSafe
and `x86-linux`; `check` natively, for `wasm32-freestanding` and
`powerpc-linux`, and `check-all`, pass. Nothing under `core/src/` changed,
so no hot path moved and instruction counts were not taken. SPEC.md §19.9
now says a tween asks for the next frame while it moves and for an
instant only when delayed: frames during motion come at the display's
rate, which only the host knows. Exit animations are
`11-polish:02-exit-animations`.

## 11-polish:02-exit-animations — Exit animations

`Element.exit` and the ghost buffer.

**Grounding.**
- SPEC.md declares the feature and the code has none of it: §5 lists
  `exit_ghost_commands: u32 = 0`, §10.1 `Element.exit_seconds: f32 = 0`,
  §19.9 says an element with `exit_seconds` "keeps emitting its last
  commands, taking no space and receiving no hits", and §17.2 names ghost
  commands among the limits. `grep -rn 'exit_ghost\|exit_seconds'
  core/src` is empty.
- `Limits` is `core/src/context.zig:90`, and `Limit` is
  `std.meta.FieldEnum(Limits)` (`:129`), so a new limit is a new
  `Diagnostics.needed` entry by itself. `Diagnostics` (`:131`) is held at
  96 bytes: one byte more moved every array of `Frame` after it (`:137`,
  `:486`), and its fields already sum to 96, so a limit of 4 bytes makes
  it 104.
- `Element` is `ElementWith` (`:186`); `chrome` (`:232`) is ignored
  without its feature so that a widget can declare it for every context.
  `ElementFlags` (`:253`) is a `packed struct(u16)` whose 16 bits are all
  taken, so an exiting element cannot be marked by a flag.
- `appendElement` is `inline` (`:1431`), so a field left at its default
  costs nothing; `chrome` and `semantics` are gathered there into lists
  beside the frame, in `FrameSlot` (`:771`), not in `Frame`, since a field
  added to `Frame` reorders its arrays. A scroll container without an id
  panics in safe builds and does not scroll (`:1665`), since its offset
  is stored by id.
- Emission (`core/src/emission.zig:52`) has one copy of its walk per
  frame kind (`:56-61`, `:63`), because any change to the walk moved
  `endFrame` by up to 5%. The walk visits each element in declaration
  order (`:94`), skips one that draws nothing (`:104`), opens a level for
  one that clips, has a border, floats, is a region or transforms
  (`enter`, `:279`), and pushes its border and `clip_end` on `leave`
  (`:539`), so before the layers are sorted (`:120`) an element's subtree
  is one contiguous run of commands. Hit regions and `rectOf`'s results
  are written only in `enter` (`:328`, `:331`). `reopenTransforms`
  (`:372`) begins the transforms around an element again on another layer.
- A text command's `content` points into its frame's `text_bytes`, which
  the next `beginFrame` on that slot overwrites; with `frames_in_flight
  = 1` that is the very next frame.
- `beginFrame` clears `frame_requested` and `requested_deadline`
  (`core/src/context.zig:981`), and `nextFrame` (`:1173`) reads them after
  `endFrame`, so `endFrame` can ask for the next frame itself.
  `Environment.reduced_motion` is `core/src/input.zig:314`.
- `zui_motion` (`core/zui_motion/zui_motion.zig`) animates an element
  only while it is declared; nothing keeps drawing one that is not.

**Plan.** One slice, in the core, all of it behind `comptime
limits.exit_ghost_commands != 0`:
- **The API** is `Element.exit: ?Exit`, in place of SPEC.md's
  `exit_seconds`, so that an element also chooses how its ghost leaves:
  `Exit = struct { seconds: f32, fade: ExitFade = .linear }`, and
  `ExitFade = enum { none, linear, ease_in, ease_out, ease_in_out }`,
  the eased ones cubic and exact at 0 and 1 as `zui_motion.Easing`'s are.
  `.none` holds the ghost unchanged for its seconds and then drops it.
  `exit` is ignored when `exit_ghost_commands` is 0, as `chrome` is
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
  gradient stops, shadow colors, a material's fallback) by `1 - curve(t)`;
  customs, a material's handle, clips and transforms are unchanged. A
  `.none` ghost is copied into the frame as it is, with no alpha pass; a
  `.linear` one computes `1 - t` once per frame and runs no easing; an
  eased one evaluates its cubic once per frame. The fade is chosen by a
  switch per ghost per frame, not per command, so a context that never
  eases pays one branch per ghost and no comptime set of curves is
  declared. Overlapping commands of one ghost fade separately, so its
  text shows its background through it as both fade. SPEC.md §19.9
  gains these sentences.
- **Knowing an element exited:** each candidate (an element declared with an
  `exit` of positive seconds and an id) is listed in `FrameSlot` as it is
  declared, in declaration order, beside its `Exit`, as chrome is. The
  walk compares each element's index with the next candidate's, as it
  does the next effect's (`emission.zig:98-102`), and a candidate opens a
  level, so its `leave` copies the run of commands its subtree emitted
  into the context's snapshot store. At the end of the next frame, each
  snapshot whose id that frame's `lookup` does not find becomes a ghost.
  Cost when on: one index comparison per element in the walk, a copy of
  each candidate's commands per frame, one `lookup` per snapshot and per
  ghost. Cost when off: none; the comparison, the level and the store are
  `comptime`-removed.
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
  `max_text_bytes`, so a frame a renderer holds never points into a store
  that is rewritten. A ghost does not follow a container that scrolls or
  moves after it exited, and is unaffected when its ancestors also exit:
  it keeps the clip and transforms it had, as the box around the clip in
  the innermost transform's units.
- **Frames:** while a fading ghost lives `endFrame` calls `requestFrame`,
  since it changes every frame; a `.none` ghost asks only for a frame at
  the instant it ends, with `requestFrameAt`. A ghost whose time is up, or
  whose id is declared again, is dropped before it is drawn; the frame
  after the last one is dropped asks for nothing. Under `reduced_motion`
  no snapshot is kept and every ghost is dropped at once.
- **Limits:** a snapshot or ghost whose commands or text do not fit its
  store is not kept, and the frame records `.exit_ghost_commands` in
  `diagnostics.exceeded`, the commands it needed in `needed`, and its id
  in `first_dropped_id`, as §17.2 says. The rest are kept. A subtree that
  lost commands to `max_render_commands` keeps no snapshot, since its
  clips might not end.
- **Kept free when off:** `Diagnostics` grows with a new limit whatever
  its value, so before anything else the `Limits` field was added alone
  and counts were compared with `dfe65ed`. The rest is gated on the
  limit, so the walk and `appendElement` compile as before, and every
  instruction count of `zig build counts -- --compare` must be identical.
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
  added and `Diagnostics` at 104 bytes, every declaration executed 2 to 4
  instructions more (4096 boxes declare 436,605 → 436,607), the 3000
  cells' 53 more and 1000 new strings' 101 fewer, from the frame's reset
  of a larger `Diagnostics`.

**Done when.** Core's tests pass in Debug, ReleaseFast, ReleaseSafe and on
`x86-linux`, with the exit animations' own: an element that stops being
declared keeps drawing for its `seconds` and then not, unchanged with
`.none` and at each curve's alpha with a fade; it takes no space and no
hits and `rectOf` does not find it; its text survives the frame it came
from being reused, with `frames_in_flight = 1`; it keeps its layer and
the clip and transforms around it; a nested candidate is drawn once; it
is dropped when declared again; every frame is asked for while a ghost
fades and none after; `reduced_motion` drops it at once; a full store
keeps what fits and reports the limit; `exit` is ignored with the limit
at 0. `check` passes natively, for `wasm32-freestanding` and
`powerpc-linux`; `test-all` and `check-all` pass; and every instruction
count of `zig build counts -- --compare` against `dfe65ed` is identical.

**Spec.** §5, §10.1, §17.1, §17.2, §19.9.

**Status.** Done:
- `Element.exit`, `zui.Exit` and `zui.ExitFade` (`core/src/exit.zig`),
  behind `limits.exit_ghost_commands`. Candidates are listed beside the
  frame; emission keeps each one's commands as a snapshot when its
  subtree ends, and after the walk draws every ghost still leaving at the
  end of its layer. 13 tests in `core/src/tests/exit_animations.zig`, in
  Debug, ReleaseFast, ReleaseSafe and `x86-linux`; `check` natively, for
  `wasm32-freestanding` and `powerpc-linux`; `test-all` and `check-all`.
- `Diagnostics.first_refusing_source` is a `[*:0]const u8`, so
  `Diagnostics` stays at 96 bytes with the new limit.
- `01-measure:03-instruction-counts-in-ci`, measured here against
  `dfe65ed` with the limit at 0: all 35 instruction counts are identical
  (4096 boxes declare 436,605 and `endFrame` 1,264,648). Simulated misses
  moved in 20 rows, every one within 2% but four: 4096 interactive boxes'
  `endFrame` branch misses 19,844 → 20,868 (+5.2%), the documents view's
  declaration I1 misses 25 → 27 and its `endFrame`'s 32 → 31, and the
  3000 cells' `endFrame` I1 misses 0 → 5. The same rows moved by the same
  amounts with only the limit and the smaller `Diagnostics` in place, so
  they come from the reservation's new layout, not from the ghosts'
  code. Timings were not taken; with counts identical none were needed.
- SPEC.md §10.1 names the field `exit: ?Exit` in place of `exit_seconds`,
  since an element also chooses its fade; §19.9 says what a ghost holds,
  where it is drawn, how it fades and which frames it asks for; §17.1
  lists `exit` without an id; §5 says the ghosts' text is kept in
  `max_text_bytes`.

## 11-polish:03-zui-color — `zui_color`

OKLab, OKLCH and HSL, mixing and palettes, at comptime.

**Grounding.** `zui.Color` (`core/src/style.zig:30`) is four sRGB-encoded
bytes with straight alpha, written `.rgb(0x3366ff)` (`:41`); `Color.mix`
(`:51`) interpolates the encoded channels, and `Color.mixOklab` (`:74`)
goes through an OKLab of the core's own, which is private (`:178`) with
its transfer functions (`:218`, `:223`), so a gradient's `colorAt` can mix
in it without a module. `zui.ExtendedColor` (`:105`) is linear scRGB in
`f16`, with `fromColor` and `toColor` (`:129`, `:135`), so OKLab reaches it
without a transfer function and without clamping. Nothing public converts
to OKLCH or HSL, makes a palette, or maps a color outside sRGB back into
it except by clamping each channel (`:223`), which shifts its hue.
`std.math.cbrt`, `std.math.pow` and `std.math.atan2` all run at comptime,
but every call there counts against the branch quota, and `pow` makes
hundreds, so a handful of conversions would end a comptime block at the
default quota of 1000. A module is registered as `zui_motion` was: its
`b.addModule` (`core/build.zig:214`), `tested_modules` (`:227`), the
compile-error and `check` imports, `formatted_paths` (`:393`), `.paths`
in `core/build.zig.zon`, `core_modules` in the root `build.zig:35`, and
the README's import snippet and *Packages* table.

**Plan.** One slice, a module `zui_color` on the public API alone, adding
nothing to the core:
- `Oklab`, `Oklch` and `Hsl`, with `f32` fields named in full and a
  straight `alpha`, each converting to and from `zui.Color`; `Oklab` and
  `Oklch` also to and from `zui.ExtendedColor`, unclamped, and to and from
  each other; `Oklab` from and to linear sRGB with Björn Ottosson's
  matrices; `Hsl` as CSS Color 4 defines it, over encoded channels.
- `toColor` brings a color outside sRGB in by reducing its OKLCH chroma,
  by bisection, keeping its lightness and hue, rather than clipping.
- `mix` in OKLab and `mixOklch`, whose hue takes the shorter arc and whose
  grey end takes the other end's hue; alpha mixes linearly.
- Palettes: `ramp(steps, from, to)`, both ends included;
  `withLightness` and `shiftLightness` for a skin's hovered and pressed
  shades; `lightnessScale(steps, color, darkest, lightest)`, a tonal
  scale. Fewer than two steps is a compile error, pinned by
  `core/tests/compile_errors/color_ramp_too_few_steps.zig` and
  `color_lightness_scale_too_few_steps.zig`.
- At comptime, the sRGB transfer function is two tables of 256 built once,
  and a conversion raises the branch quota itself, so a block of hundreds
  of conversions needs no `@setEvalBranchQuota` of its own.
- Registered at every point a module is, and documented in the README and
  the feature tour; ARCHITECTURE.md's module list and §6 row follow.

**Done when.** Core's tests in Debug, ReleaseFast, ReleaseSafe and on
`x86-linux` pass, with `zui_color`'s own: sRGB's white, black, mid grey
and primaries land within 0.0005 of their published OKLab values, and the
primaries on their OKLCH chroma and hue; a grid of sRGB colors comes back
from OKLab, OKLCH and HSL within one 8-bit step; HSL matches CSS's
examples and wraps any hue; an `ExtendedColor` brighter than white goes
through OKLab unclamped; a mix's ends are its colors exactly and black to
white is `#636363`, as `Color.mixOklab`; OKLCH's hue takes the shorter
arc; a color outside sRGB keeps its lightness and hue and lands on the
gamut's edge; a ramp and a lightness scale are evenly spaced, keep their
ends and hue, and are the same at comptime as at run time; a comptime
block converts a hundred colors at the default quota; and both
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
`zui_color`, so `check` type-checks it only through its tests, on the host.

## 11-polish:04-skin-contract — The skin contract

`Widgets(Ui, Skin)` and `zuiStyle`, so a theme pack restyles every widget
without forking it.

**Grounding** (at `f77934b`). `zui_widgets` is `Widgets(UiType)`
(`core/zui_widgets/zui_widgets.zig:99`), a struct of two values,
`theme: Theme` and `dark_theme: ?Theme` (`:105-109`). `Theme` (`:111-147`)
is one flat struct of a text style, fifteen colors, a
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
pressed, so it is not one of `widgetState`'s states (`core/src/context.zig:2619-2625`
checks disabled, pressed, hovered, focused, in that order). Some metrics
are fixed in the widgets: the check mark's radius 2 and size
`0.45 * checkbox_size` (`:281-286`), the popup's padding and offset of 4
(`:678`, `:686`) and its options' padding `horizontal_padding - 4`
(`:708`). Text is styled by `textStyle` (`:741-750`) in three tones,
normal, muted and disabled; `environment().text_scale` is read by no
widget.

The callers: the tour builds a `Widgets.Theme` each frame from its
palette and the clamped `text_scale` (`apps/tour/src/kit.zig:141-169`) and
sets it as both themes (`:195`); its classic screen gets a theme of one
text style (`apps/tour/src/tour.zig:101`). The showcase holds
`zui_widgets.Widgets(Ui)` (`apps/showcase/zui_showcase.zig:68`), restyles
metrics for cells (`:302-311`), and reads `widgets.theme.control` directly
for a hover target (`:162`). `zui_reflect` reads
`widgets.activeTheme(ui).horizontal_padding`, `.gap` and
`.control_height` (`core/zui_reflect/zui_reflect.zig:141`, `:153`). The
rest name `Widgets(Ui)` and take its defaults:
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
`std.EnumArray`; §7.2 (`:638`) says `text_scale` is applied by skins; §16
has no section for the skin. `ARCHITECTURE.md:122` lists the role and
`:304` the difference this item closes.

**Plan.** One commit.

1. **The contract, in `zui_widgets`.** `zui_widgets.Part`, an enum of
   every element a widget styles; `zui_widgets.Style(Ui)`, what a skin
   returns for one part in one state; and the check: a skin is a struct
   type declaring `zuiStyle(*const Skin, Part, zui.WidgetState, *const zui.Environment) Style(Ui)`
   and no other `zui`-prefixed declaration. `Widgets(Ui, Skin)` checks it
   once and holds `skin: Skin`; `widgets.style(ui, part, state)` asks the
   skin, for callers that match a widget's look.
2. **Every widget styled through the skin**, including the focus ring,
   which is the style's `focus_ring`, drawn while focused. The metrics
   fixed in the widgets today become the skin's.
3. **`DefaultSkin(Ui)`**: today's `Theme` and `dark_theme`, answering
   `zuiStyle` from them, so every caller keeps its look;
   `11-polish:05-default-skin` replaces its data.
4. **Callers** move to `Widgets(Ui, zui_widgets.DefaultSkin(Ui))`, and the
   three that read the theme to `widgets.style` or `widgets.skin`.
5. **Tests:** a second skin of data only, in `core/zui_widgets/tests.zig`,
   restyles every widget; a recording skin shows every part and every
   state reaches `zuiStyle`; `Widgets` over a skin of no fields is as
   large as the skin. Compile-error cases `skin_*` for each mistake;
   `core/tests/instantiate.zig` instantiates `Widgets` with both skins.
6. **Documents:** SPEC.md §16.7 (the skin contract) and §19.2;
   `ARCHITECTURE.md` §7's row removed.

**Done when.** Core's tests in Debug, ReleaseFast and ReleaseSafe, and
`check` natively, for `wasm32-freestanding` and for `powerpc-linux`;
`test-all` and `check-all`; each `skin_*` case fails with its message; the
tour's and the showcase's tests in all three modes and their `check` for
`x86_64-windows`; the raylib tour's cycle prints `diagnostics ok: true`
and its `gallery` screenshot is the same before and after; the terminal
tour's `--dump --every-screen` passes; the data-only skin's test restyles
every widget without a change to `zui_widgets`.

**Spec.** §7.2, §11.1, §16.1, §16.7, §18, §19.2.

**Status.** Done in one commit. `zui_widgets` has the contract:
`Part`, 23 elements a widget draws (a checked box and the selected option
are parts of their own), `Style(Ui)`, and `expectSkin`, which
`Widgets(Ui, Skin)` runs once: a skin is a struct declaring
`zuiStyle(*const Skin, Part, zui.WidgetState, *const zui.Environment) Style(Ui)`
and no other `zui`-prefixed declaration. Every widget, and its focus
ring (`Style.focus_ring`, drawn in place of the border while focused),
is styled through the skin; the metrics the widgets fixed (the check
mark's size and radius, the popup's padding and offset, the options'
padding) are the skin's. `Widgets` holds `skin: Skin` and no default,
since Zig cannot give a field a default that only some skins can build,
so a caller writes `.{ .skin = .{} }`; `widgets.style(ui, part, state)`
serves `zui_reflect` and the showcase's hover target.
`DefaultSkin(Ui)` is the former `Theme` and `dark_theme`, answering
`zuiStyle` from them, for `11-polish:05-default-skin` to grow. Every
caller names `Widgets(Ui, zui_widgets.DefaultSkin(Ui))`. A control
declared disabled is styled disabled from that frame, where
`widgetState` reports it a frame later. Measured: core's tests pass in
all three modes with four new `skin_*` compile-error cases; a skin of
data alone restyles every widget (every rectangle, border and text
command takes its colors, every control its height), a recording skin
is asked for all 23 parts and all five states, and `Widgets` over a skin
of no fields is 0 bytes and over `DefaultSkin` exactly its size. The
raylib tour's `gallery` screenshot differs from one taken before the
change only in the frame-time strip at the bottom (rows 836-875), as two
screenshots before the change also differ, so the widgets draw the same
pixels; its 600-frame cycle prints `diagnostics ok: true`; the terminal
tour's `--dump --every-screen` passes. `core/bench/` does not use
`zui_widgets`, so instruction counts do not move.

## 11-polish:05-default-skin — The default skin

Light, dark and high contrast, following the environment.

## 11-polish:06-text-editing — Text editing

Selection, word movement, the clipboard through the host, multiple lines,
and IME composition with the IME area in `HostRequests`.

## 11-polish:07-zui-icons — `zui_icons`

## 11-polish:08-zui-themes — `zui_themes`

Skins for Windows, GNOME and KDE, in `themes/`. macOS's skin is set aside
as `14-macos:03-macos-skin`.

## 11-polish:09-template-project — The template project

In `examples/template/`.

## 11-polish:10-samples — Samples

A settings screen with `zui_reflect` and ZON, a data feed, a multi-window
tool, a remote session.

## 11-polish:11-profiling-guide — A profiling guide

Over `01-measure:04-tracer-contract`'s tracer.

**Grounding.** `docs/benchmarking.md`'s `## Profiling` section was one
paragraph on Tracy and a list of ways to keep noise out. The tracer
contract is `core/src/trace.zig:3` (`TraceZone`) and
`core/src/contracts.zig:380` (`checkTracer`); `zui_tracy` is
`core/zui_tracy/zui_tracy.zig`, with Tracy 0.14.1 pinned in
`core/build.zig.zon:8`; `ZoneTimer` is `core/zui_debug/zui_debug.zig:32`;
the tour's `--measure-idle` is `apps/tour/src/root.zig:330`.

**Plan.** Grow `docs/benchmarking.md`'s `## Profiling` into a guide for
an application's author, with the consumer's own `build.zig` lines and
Zig for: Tracy through `zui_tracy`, and the zones zui emits; the
application's own zones; a tracer of one's own; `zui_debug`'s inspector
and `ZoneTimer`; reading `Diagnostics` and `NextFrame`; and measuring a
change. Compile every snippet in a consumer project of its own.

**Done when:** the guide covers those six parts, each snippet matches the
current API and compiles in a consumer project, the Tracy version and
the zone list are read from the code, and no API is described that does
not exist.

**Spec.** §16.5, §19.7, §19.10.

**Status.** Done: `docs/benchmarking.md`'s `## Profiling` is a guide in
six parts. Every Zig snippet was compiled and run in a consumer project
naming the repository by path, without Tracy and with `-Dzui-tracy=true
-Dtarget=x86_64-linux-gnu`, except the `zui_raylib` dependency line,
which copies `renderers/raylib/README.md`. `zui_tracy` has no API for an
application's own zones, so the guide declares Tracy's C API, gated on
`zui_tracy.enabled`; a public zone API in `zui_tracy` would spare that.
`tracy-capture`'s and `tracy-csvexport`'s flags are from Tracy's
documentation, not run here, since neither is installed.

## 11-polish:12-developer-experience-audit — A developer-experience audit

A new user builds each sample from the docs alone, and every place they
get stuck becomes an item.

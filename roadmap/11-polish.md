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
| `11-polish:02-exit-animations` Exit animations | not started |
| `11-polish:03-zui-color` `zui_color` | not started |
| `11-polish:04-skin-contract` The skin contract | not started |
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

`exit_seconds` and the ghost buffer.

## 11-polish:03-zui-color — `zui_color`

OKLab, OKLCH and HSL, mixing and palettes, at comptime.

## 11-polish:04-skin-contract — The skin contract

`Widgets(Ui, Skin)` and `zuiStyle`, so a theme pack restyles every widget
without forking it.

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

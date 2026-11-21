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
| `11-polish:01-zui-motion` `zui_motion` | not started |
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

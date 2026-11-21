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
| `11-polish:11-profiling-guide` A profiling guide | not started |
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

## 11-polish:12-developer-experience-audit — A developer-experience audit

A new user builds each sample from the docs alone, and every place they
get stuck becomes an item.

# Plan: the test card

A small, fixed application that every backend draws, built for the
checks that run it: the picture a station broadcasts so every receiver
can be compared against it and its faults show. It replaces the
showcase, removed in `069ab16`, whose targets proved only that 60 frames
drew with clean diagnostics. Its steps are T0 to T7. Until work begins,
this file holds them all: T0 enters T1 to T7 in the roadmap, under the
labels below if those numbers are still free in `roadmap/11-polish.md`.

| Step | Item | What it builds |
|---|---|---|
| T0 | (none) | the seven items in the roadmap, from *T0: entering the roadmap* below |
| T1 | `11-polish:37-test-card` | the app, its scenes and its `test-card` targets |
| T2 | `11-polish:38-frame-snapshots` | each scene's frame as committed text, compared exactly on every OS |
| T3 | `11-polish:39-terminal-snapshots` | the terminal's cells of each scene, committed and compared exactly |
| T4 | `11-polish:40-pixel-hashes` | each scene's pixels hashed per rasterizer, with the approved image rebuilt on a mismatch |
| T5 | `11-polish:41-scripted-input` | input through each host's own event path, its effects checked |
| T6 | `11-polish:42-test-card-review` | the test card's review mode: approve a scene by looking at it |
| T7 | `11-polish:43-test-card-on-the-web` | the card in the web checks: WebAssembly lays it out as native does, and WebGL draws it as sokol does |

## What already checks what

| Check | Proves | Misses |
|---|---|---|
| the renderer suite (`core/zui_testing/renderer_conformance.zig`) | each command draws, per renderer, at a tolerance of 32 | a whole frame: real layout, real fonts, the host |
| the tour's cycle | every screen declares within its limits on a real host | whether anything drawn is right |
| `hosts/web: test-draw` (`hosts/web/web/check_draw.mjs`) | WebGL draws the tour's frames as sokol does, within 2 levels a channel on a GPU and 5 on llvmpipe | raylib and the terminal; a mistake sokol and WebGL share |
| the terminal's `--every-screen` dump | no screen cuts text short | whether the cells are the right ones |

The middle layer is missing: that a real host, real fonts, real layout
and a real renderer together make the same, correct frame, and that real
input reaches it. The tour cannot be that reference, since it is large
and is redesigned; a reference taken from it would churn with every
redesign.

## The card

Fixed and deterministic: no animation, no clock, 640×384 units, which is
80×24 cells of 8×16, so the terminal lays out the same card. Each region
has an id and exists to make one check fail:

| Region | Contents | Fails on |
|---|---|---|
| `identity` | renderer, host, scene, viewport, fonts' fingerprint | (a dump or screenshot that does not say where it came from) |
| `swatches` | each color role of the default design as a labelled tile, and a ramp of 16 greys | color space, gamma, premultiplied alpha, the terminal's palette |
| `geometry` | hairlines, borders 1, 2 and 3 wide, corners at radii 0, 4 and 12, a box at a half-unit offset | snapping, border insets, corner coverage |
| `text` | a line per type role, `Hxgjpqy`, `WMW`, `0123456789`, a line cut short by its clip | baselines, descenders, advances, clipping |
| `clip_and_scroll` | a scroll box already scrolled, its content crossing the clip | scissor and offset mistakes |
| `layers` | a tooltip and a modal over the page, in a known order | layer order, overlay clipping |
| `controls` | a button, checkbox, slider and text field, each with its value printed beside it | the target of T5's scripted input |

A **scene** is the card in one state: `rest`, `hovered`, `pressed`,
`focused` (after Tab), `dialog` and `scrolled`. Each scene is a pure
function of its state, so any backend draws scene `n` alike.

## How the output is compared

The owner's proposal: hash each image by its raw content, commit the
hashes rather than the images, and approve the references by looking at
them. The trouble is that pixels differ between rasterizers, not only
between commits. llvmpipe rounds `src·a` and `dst·(1−a)` separately and
GPUs round once, so a translucent shape can come out one level apart,
and `check_draw.mjs:30` and `:36` allow 2 levels on a GPU and 5 on
llvmpipe for exactly this. CI's raylib job takes whatever Mesa the
runner's image installs (`.github/workflows/ci.yml:310`). An exact hash
of pixels fails on the owner's NVIDIA card, and again on each new runner
image, with no fault in zui.

So each layer of the stack is checked where it is deterministic, and
only the GPU's last step is held to a rasterizer:

1. **What zui decided** (T2): every command of each scene, as text, one
   line per command, positions to 1/64 unit, under a header of the
   viewport, the placement and the fonts' fingerprint. It is the same on
   every OS and GPU, so it is compared exactly and committed: a few
   hundred lines per scene, whose diff in a review says what changed
   ("the `text` region's third run moved 1 unit down") with no image at
   all.
2. **What the glyphs became**: the hash of each glyph's coverage in the
   atlas, in the same header. stb_truetype's math is zui's own Zig
   (`text/truetype/src/stb_truetype.c:19`–`28`), not each OS's libm, so
   coverage is the same everywhere; a change of font or of stb shows as
   one line ("fonts' fingerprint changed"), not two hundred.
3. **What the terminal drew** (T3): the cells are the image, so the dump
   is committed and compared exactly, on every OS.
4. **What the GPU drew** (T4): the owner's hash, keyed by the
   rasterizer. `apps/test_card/pixels.zon` holds, per scene, renderer
   and rasterizer (`GL_RENDERER` and its version, such as
   `llvmpipe (LLVM 20) Mesa 26.2.5`), the SHA-256 of the RGBA8 read-back
   and the commit it was approved at. A rasterizer with no entry is
   reported and passes; approving it adds the entry. Today nothing pins
   Mesa: CI takes `ubuntu-latest`'s (`.github/workflows/ci.yml:310`) and
   `tools/ci/Dockerfile` whatever `ubuntu:26.04` has on the day it is
   built. So T4 runs its job in an image pinned by digest, with Mesa's
   packages at fixed versions, which CI and `zig build ci` both use;
   then CI's entries hold until the pin is moved, and moving it is one
   approval.

### Knowing what went wrong without committed images

A hash that does not match keeps its information in the commit it was
approved at. On a mismatch the check:

- writes the drawn image to `ZUI_TEST_CARD_FAILURES` (a temporary
  directory by default; CI uploads it, as `test-draw`'s failures are);
- rebuilds the approved image by checking out the approved commit in a
  worktree of its own, as `zig build bench-compare` builds its base
  (`core/bench/compare.zig:212`), and drawing the same scene on the same
  rasterizer;
- writes a diff image, differences in red over the drawn frame greyed;
- names each region whose rectangle (`frame.rectOf(region)`) holds a
  differing pixel, the count, the largest channel difference and the
  bounding box, and says whether every difference is within
  `check_draw.mjs`' tolerance ("rounding: within 2") or beyond it ("the
  `geometry` region: 412 pixels, up to 255, in 8×8 at 312,40").

Rebuilding a commit takes minutes, so the approved images are also kept
on the developer's machine, in `apps/test_card/.references/`, which git
ignores. Each is named by its hash and checked against it when read, so
a stale or damaged file is not trusted, only drawn again. When an image
the check needs is missing, `zig build test-card-references` fills the
cache all at once: it builds each approved commit once and draws every
scene approved at it, for this machine's rasterizer. After that first
run a mismatch costs a read. CI starts with an empty cache and builds
only on a mismatch. Only this machine's rasterizer can be drawn here;
CI's llvmpipe images are drawn by `zig build ci`, in CI's pinned image.

Most failures need none of this: when T2's snapshot changed too, its
diff says what moved before a pixel is compared.

### Storage

Only text is committed: about seven scenes' snapshots in pixels and in
cells, seven terminal dumps, and one line per scene, renderer and
rasterizer of hashes. No image enters the repository.

## Real fonts

The card draws in `zui_fonts`' typefaces through `zui_truetype`, both
pinned by the repository, with the math above in Zig, so the same glyphs
come out everywhere. Where that may fail:

| Risk | Handled by |
|---|---|
| a float rounds differently on another target or optimize mode | positions to 1/64 unit in the snapshot; T2's Done when is the same file on Linux, Windows and macOS in all three modes, and a position that still differs is a bug found |
| x87 on 32-bit x86 rounds at 80 bits | the snapshots are not compared there; that leg checks indices, not drawing |
| a font, stb or `zui_glyphs` changes on purpose | one header line changes; every scene is approved again in one step |
| a user's own fonts | out of scope: the card checks zui, not the user's application |

## Approval

There is one app. `--review` (T6) opens the card's review mode: for each
scene that differs it shows the drawn frame and the approved one side by
side, the diff over them, and the snapshot's text diff; a key approves
it, rewriting its snapshot, its dump or its hash line. Until T6 lands,
`zig build test-card -- --approve` writes the same files and the images
into `ZUI_TEST_CARD_FAILURES` for any image viewer. The permutation
review of `11-polish:22-appearance-review` may take the review mode over
once it exists; the two show the same kind of comparison.

## Decisions

Made by the owner:

1. **A rasterizer the hashes do not know** is reported, and the check
   passes. A new GPU or Mesa asks for an approval rather than failing.

2. **The approved images are rebuilt from their commit,** and cached on
   the developer's machine as *Knowing what went wrong* says, rather
   than kept as release assets.

3. **The web host draws the card in the checks it already runs, and
   stores nothing** (T7). Today `hosts/web: test-draw` draws one frame
   of each of the tour's screens twice, natively with the sokol renderer
   and in headless Chromium with WebGL on SwiftShader
   (`hosts/web/web/headless_page.mjs:73`), and compares the two pixel by
   pixel, within 2 levels a channel, or 5 against llvmpipe, at one and
   at four samples a pixel; `test-demo` checks that the tour's
   WebAssembly worker draws the frames the tour draws natively. Of the
   four ways the card could join them, the owner chose two:

   | Option | Proves | Costs | Chosen |
   |---|---|---|---|
   | a. the card's scenes in `test-demo`'s worker check | the WebAssembly build, 32-bit and without an OS, lays the card out as the native build does | the card in the worker; small | yes, in T7 |
   | b. the card's scenes in `test-draw` | WebGL draws the card as sokol does, a failure named by region rather than as a pixel of a busy tour screen | a few frames more; nothing stored | yes, in T7 |
   | c. pixel hashes for Chromium, as T4's for GL | a WebGL regression that sokol shares, which a or b cannot see | CI installs the newest stable Chrome (`.github/workflows/ci.yml:494`), about every four weeks a new rasterizer, so a notice and an approval each time, unless Chrome is pinned to a Chrome for Testing version | not now |
   | d. T5's script through the page's `input_recorder.mjs` | the web host's input reaches the card | the script in a browser page; it waits for T5 | not now |

   c and d are not planned. T0 may add either as an optional item, as
   *Optional items* below says.

## T0: entering the roadmap

When work begins, in one commit: each item below in
`roadmap/11-polish.md` after the group's last item, renumbered to the
next free numbers if 37 to 43 are taken, with a row each in its *Items*
table (`not started`) and in the queue of `ROADMAP.md`, where the owner
places them; the three decisions under *Made* in `roadmap/decisions.md`;
and this file's table and items, then pointing to the roadmap, as
`docs/plans/benchmarking.md` does.

The queue's rows:

| Item | Where | Waits for |
|---|---|---|
| `11-polish:37-test-card` | `apps/test_card/`, `renderers/raylib/`, `renderers/terminal/`, `hosts/native/` | |
| `11-polish:38-frame-snapshots` | `core/zui_testing/`, `apps/test_card/` | `11-polish:37-test-card` |
| `11-polish:39-terminal-snapshots` | `renderers/terminal/`, `apps/test_card/` | `11-polish:38-frame-snapshots` |
| `11-polish:40-pixel-hashes` | `apps/test_card/`, `renderers/raylib/`, `hosts/native/`, `.github/`, `tools/ci/` | `11-polish:38-frame-snapshots` |
| `11-polish:41-scripted-input` | `apps/test_card/`, `renderers/raylib/`, `renderers/terminal/`, `hosts/native/` | `11-polish:38-frame-snapshots` |
| `11-polish:42-test-card-review` | `apps/test_card/` | `11-polish:40-pixel-hashes` |
| `11-polish:43-test-card-on-the-web` | `hosts/web/`, `apps/test_card/` | `11-polish:38-frame-snapshots` |

Their Groundings were checked at `bd80593`; T0 confirms each `file:line`
again, as taking an item does.

### Optional items

The owner may have T0 add either of these too, each after the item it
waits for, or leave them out; each gets its Grounding, Plan and Done
when when added:

- **Pixel hashes for Chromium** (option c): T4's hashes for
  `test-draw`'s WebGL frames of the card, keyed by Chromium's version
  and its SwiftShader, so a regression sokol and WebGL share fails.
  Worth adding once CI's Chrome is pinned to a Chrome for Testing
  version, or the notice comes every four weeks. Waits for T4 and T7.
- **Scripted input on the web host** (option d): T5's script through the
  page's `input_recorder.mjs`, so the web host's input is checked on the
  card as the native hosts' is. Waits for T5 and T7.

### 11-polish:37-test-card — The test card

T1 of `docs/plans/test-card.md`: a small, fixed application every
backend draws, built for the checks that run it, in place of the
showcase removed in `069ab16`.

**Grounding** (at `bd80593`). The showcase's targets proved only that 60
frames drew with clean diagnostics, and its terminal dump that its title
printed; nothing compared its frames. The tour (`apps/tour/`) is large
and is redesigned (`11-polish:24-the-tour`), so it cannot be a
reference. A target is `examples/<app>.zig` in `renderers/raylib/`,
`renderers/terminal/` and `hosts/native/`, built in each package's
`build.zig` beside `tour`. The terminal's dump is
`renderers/terminal/examples/dump.zig`.

**Plan.** `apps/test_card/`, the package and module `zui_test_card`,
which the root re-exports: the card of the plan's *The card*, its seven
regions each with an id, at 640×384 units, which is 80×24 cells of 8×16,
in six scenes, each a pure function of its state, with no clock.
`App(.{ .Host, .Renderer, .Text, .renderer_name })` for `zui_app`, in
`zui_fonts`' typefaces; `--scene <name>`, `--frames <count>` and
`--hidden`. A `test-card` target in each of the three packages, in place
of `showcase`, with its CI steps; its headless test declares every scene
on renderers that draw every optional command and none, in pixels and in
cells, with clean diagnostics and the contrast audit clean. The
package's rows in CLAUDE.md, ARCHITECTURE.md, SPEC.md §3, README.md and
`docs/development.md`, as the showcase's were.

**Done when.** The headless test passes in all three optimize modes and
compiles for `wasm32-freestanding`; each backend's
`test-card -- --frames 6` draws every scene once and prints
`diagnostics ok: true`, raylib and the native host under CI's display,
the terminal with `--dump`.

**Spec.** §3, §20.1.

**Status.** Not started.

### 11-polish:38-frame-snapshots — Frame snapshots

T2 of `docs/plans/test-card.md`: each scene's frame as committed text,
compared exactly on every OS.

**Grounding** (at `bd80593`). `Frame.commands()`
(`core/src/context.zig:594`) is every command a frame draws.
`zui_truetype.Text.zuiFingerprint` (`text/truetype/src/root.zig:56`)
names the fonts and the placement. stb_truetype's math is zui's own Zig
(`text/truetype/src/stb_truetype.c:19`–`28`), not each OS's libm.

**Plan.** In `zui_testing`, `writeSnapshot(frame, writer)`: a header of
the viewport, the placement, the fonts' fingerprint and the hash of each
glyph's coverage drawn, then one line per command, positions to 1/64
unit; and a comparison that reports the first lines that differ, with
the region whose rectangle holds them. The card's headless test, in
`zui_truetype`'s text, compares each scene in pixels and in cells with
`apps/test_card/snapshots/<scene>.<placement>.txt`; `--approve` writes
them. Its compile errors and tests as `zui_testing`'s are.

**Done when.** The snapshots are the same in all three optimize modes on
Linux, Windows and macOS (CI's pure-Zig legs and the Windows leg of
`text/truetype/`), and moving one region by a unit fails the test naming
that region.

**Waits for** `11-polish:37-test-card`.

**Spec.** §19.4, §20.1.

**Status.** Not started.

### 11-polish:39-terminal-snapshots — Terminal snapshots

T3 of `docs/plans/test-card.md`: the terminal's cells of each scene,
committed and compared exactly.

**Grounding** (at `bd80593`). `renderers/terminal/examples/dump.zig`
draws frames into cells without a terminal and prints them; CI checked
the showcase's dump only for its title.

**Plan.** `test-card -- --dump --check` compares every scene's cells,
glyphs and colors, with `apps/test_card/snapshots/<scene>.terminal.txt`,
printing the cells that differ and their region; `--approve` writes
them. Its CI step on Linux, Windows and macOS.

**Done when.** The check passes on all three OSes, and changing one
cell's color in the card fails it naming the cell and region.

**Waits for** `11-polish:38-frame-snapshots`.

**Spec.** §20.1.

**Status.** Not started.

### 11-polish:40-pixel-hashes — Pixel hashes per rasterizer

T4 of `docs/plans/test-card.md`: each scene's pixels hashed per
rasterizer, with the approved image rebuilt from its commit on a
mismatch, so no image is committed.

**Grounding** (at `bd80593`). GPUs and llvmpipe round blends
differently, so `hosts/web/web/check_draw.mjs:30` and `:36` allow 2
levels a channel and 5. Nothing pins Mesa: CI installs `ubuntu-latest`'s
(`.github/workflows/ci.yml:310`) and `tools/ci/Dockerfile` builds from
`ubuntu:26.04`. `ReadBack` (`core/zui_testing/harness.zig:26`) reads a
renderer's frame back. `bench-compare` builds a commit in a worktree of
its own (`core/bench/compare.zig:212`). `test-draw` writes failing
frames to `ZUI_WEB_DRAW_FAILURES`, which CI uploads.

**Plan.** `apps/test_card/pixels.zon`: per scene, renderer and
rasterizer (`GL_RENDERER` and its version), the SHA-256 of the RGBA8
read-back and the commit it was approved at. raylib's and the native
host's `test-card -- --check` compare; a rasterizer with no entry is
reported and passes. On a mismatch: the drawn image, the approved one
taken from the reference cache or rebuilt at its commit in a worktree,
and a diff image, to `ZUI_TEST_CARD_FAILURES`; each differing region
named with its count, largest difference and bounds, and whether it is
within `check_draw`'s tolerance. CI's pixel jobs in an image pinned by
digest with Mesa at fixed versions, which `zig build ci` uses too, their
failures uploaded. The reference cache, `apps/test_card/.references/`
and ignored by git: each image named by its hash and checked against it
when read, filled by `zig build test-card-references`, which builds each
approved commit once and draws every scene approved at it.

**Done when.** CI's entries pass in that image here and in CI; a
one-pixel change to a renderer's corner fails naming `geometry` and
writes the three images; a second mismatch takes the approved image from
the cache without building; an unknown rasterizer passes with its
notice.

**Waits for** `11-polish:38-frame-snapshots`.

**Spec.** §20.1.

**Status.** Not started.

### 11-polish:41-scripted-input — Scripted input on the test card

T5 of `docs/plans/test-card.md`: input through each host's own event
path, its effects checked on the card.

**Grounding** (at `bd80593`). raylib's `Host.script`
(`renderers/raylib/src/root.zig:187`) feeds sampled state; the terminal
host decodes bytes into events; the native hosts' checks have driven a
real right click (`68d1959`).

**Plan.** A script the card runs with `--script`: hover the button,
press and release it, Tab through the controls, open the dialog and
close it with Escape, drag the slider, type into the field, checking
after each step the value its region prints and the scene's snapshot.
Driven by raylib's `Host.script`, the terminal's bytes, and the native
hosts where they can synthesize input; a host that cannot says so.

**Done when.** The script passes on raylib, the terminal and one native
host, and a widget that ignores its press fails it at that step.

**Waits for** `11-polish:38-frame-snapshots`.

**Spec.** §19.4, §20.1.

**Status.** Not started.

### 11-polish:42-test-card-review — The test card's review mode

T6 of `docs/plans/test-card.md`: approving a scene by looking at it, in
the card itself.

**Grounding** (at `bd80593`). Until this item, `--approve` writes the
snapshots, dumps and hashes, and the images go to
`ZUI_TEST_CARD_FAILURES` for any viewer.

**Plan.** `--review` shows each scene that differs: the drawn frame and
the approved one side by side, the diff over them, and the snapshot's
text diff; a key approves it, rewriting its files. Built on the card's
own renderer and host, so it runs wherever the card does.

**Done when.** Changing a region, reviewing and approving it leaves
every check green, the files changed only for that scene.

**Waits for** `11-polish:40-pixel-hashes`.

**Spec.** §20.1.

**Status.** Not started.

### 11-polish:43-test-card-on-the-web — The test card in the web checks

T7 of `docs/plans/test-card.md`: the card in the two web checks that
already compare the browser with native drawing, storing nothing.

**Grounding** (at `bd80593`). `hosts/web: test-demo` runs the tour in a
worker under Node and checks every frame is the one
`tools/tour_frames.zig` draws natively (`web/check_worker.mjs`, wired at
`hosts/web/build.zig:110`). `test-draw` draws the frames
`tools/demo_stream.zig` streams, one per screen (`compared_frames`,
`hosts/web/build.zig:203`), with the sokol renderer
(`tools/draw_reference.zig`) and in headless Chromium, and compares them
in `web/check_draw.mjs`. `hosts/web/` names `apps/tour/` by path.

**Plan.** `hosts/web/` names `apps/test_card/` by path. A worker that
declares the card's scenes for `zui_webgl.Renderer`, checked by
`test-demo` against the scenes drawn natively, frame for frame; and the
card's scenes in `test-draw`'s stream, after the tour's, compared as the
tour's are, a failing pixel named by the card's region that holds it.
Both compile for `wasm32-freestanding` in `check`. `hosts/web/README.md`
and `docs/development.md` say what each check now covers.

**Done when.** `test-demo` and `test-draw` pass with the card's scenes,
here and in CI; moving a region in the WebAssembly build alone fails
`test-demo` naming that scene, and a WebGL change to one region's corner
fails `test-draw` naming that region.

**Waits for** `11-polish:38-frame-snapshots`.

**Spec.** §20.1.

**Status.** Not started.

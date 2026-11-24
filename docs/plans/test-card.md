# Plan: the test card

A small, fixed application that every backend draws, built for the
checks that run it: the picture a station broadcasts so every receiver
can be compared against it and its faults show. It replaces the
showcase, removed in `069ab16`, whose targets proved only that 60 frames
drew with clean diagnostics. The plan's steps, T1 to T7, are now items
in `roadmap/11-polish.md`, where their progress is recorded:

| Step | Item | What it builds |
|---|---|---|
| T1 | `11-polish:38-test-card` | the app, its scenes and its `test-card` targets |
| T2 | `11-polish:39-frame-snapshots` | each scene's frame as committed text, compared exactly on every OS |
| T3 | `11-polish:40-terminal-snapshots` | the terminal's cells of each scene, committed and compared exactly |
| T4 | `11-polish:41-pixel-hashes` | each scene's pixels hashed per rasterizer, with the approved image rebuilt on a mismatch |
| T5 | `11-polish:42-scripted-input` | input through each host's own event path, its effects checked |
| T6 | `11-polish:43-test-card-review` | the test card's review mode: approve a scene by looking at it |
| T7 | `11-polish:44-test-card-on-the-web` | the card in the web checks: WebAssembly lays it out as native does, and WebGL draws it as sokol does |

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

There is one app. `--review` (`11-polish:43-test-card-review`) opens the
card's review mode: for each scene that differs it shows the drawn frame
and the approved one side by side, the diff over them, and the
snapshot's text diff; a key approves it, rewriting its snapshot, its
dump or its hash line. Until T6 lands,
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

   c and d are not planned; either may be added later, as *Optional
   items* below says.

## Optional items

The owner left these out of the roadmap when the plan entered it. Either
may be added later, after the item it waits for, with its Grounding,
Plan and Done when:

- **Pixel hashes for Chromium** (option c): T4's hashes for
  `test-draw`'s WebGL frames of the card, keyed by Chromium's version
  and its SwiftShader, so a regression sokol and WebGL share fails.
  Worth adding once CI's Chrome is pinned to a Chrome for Testing
  version, or the notice comes every four weeks. Waits for
  `11-polish:41-pixel-hashes` and `11-polish:44-test-card-on-the-web`.
- **Scripted input on the web host** (option d): T5's script through the
  page's `input_recorder.mjs`, so the web host's input is checked on the
  card as the native hosts' is. Waits for `11-polish:42-scripted-input`
  and `11-polish:44-test-card-on-the-web`.

# Restructure: one repository

This is one unit of work: it gathers zui's sibling repositories into this
one, as packages, and removes the duplication their separation caused. It
is written to be carried out from this document alone.

**While this document exists, it takes precedence over the queue in
`ROADMAP.md`.** Every other item is shelved until the last slice below is
done; "tackle the next item" means the next slice here. Its last slice
deletes this document.

## Why

zui is built so that each part can be swapped: `zui_app` takes `Host` and
`Renderer` as types, and the renderer, host and text contracts are
separate. The repositories do not show it. Measured at zui `95fcfac`:

- **The tour exists twice.** zui-raylib's and zui-sokol's `examples/` hold
  about 4,000 lines each of one tour. Five files are byte-identical; most
  of the others differ by a branding string or a type spelled differently.
  They have already drifted: only zui-sokol has the `transforms` and
  `materials` screens and the overflow counters, only zui-raylib has the
  Tracy and inspector wiring, and `typography.zig`'s `sliderRow` is a free
  function in one and a `Shell` method in the other.
- **Copies kept by hand.** `showcase.zig` is identical in raylib, sokol and
  terminal, under a header asking that it stay so "until it moves into a
  shared package". The tour's fonts and their licences are duplicated.
- **The tour is tied to one renderer.** Its `Ui` is built from
  `zui_sokol_ui.config(...)` and its font ids assume sokol's six bitmap
  fonts. zui-web and zui-host run it by importing `zui_sokol_tour` out of
  zui-sokol's `examples/`; zui-raylib could not, so it forked.
- **Text forked between renderers.** zui-sokol and zui-web each keep
  `truetype.zig`, `glyph_atlas.zig` and `stb_truetype.c`, and zui-web
  depends on zui-sokol only for its `Text` and the tour.
- **Measuring and drawing text are separate code that must agree.** Each
  renderer advances its own pen glyph by glyph when it draws a text
  command, and is kept in step with the measurement only by a comment:
  zui-sokol's "the pen advances exactly as `Font.measure` measured",
  zui-web's "as zui-sokol measured it", and zui-raylib's and
  zui-terminal's own loops. No TrueType text contract declares
  `zuiFingerprint`, so the wire's check that a remote renderer has the
  application's fonts never runs; zui-web gets them right by convention,
  "in the order the tour's host added them".
- **Hosts are uneven.** zui-raylib ships a `zui_app` host; zui-sokol's and
  zui-terminal's demos run loops by hand; zui-host's `examples/tour.zig` is
  a 277-line adapter around the tour.
- **Pins.** 30 of the 117 commits in the five code-bearing siblings move a
  pin. The pins form a diamond (zui-web pins zui and zui-sokol, which pins
  zui): two different zui hashes make two `zui` modules whose types do not
  match, which is why each renderer re-exports `zui` "so the application
  and the renderer always agree", and they re-export different sets.
- **Breaks found late.** zui's CI builds no renderer or host; a core change
  that breaks one is found when that repository next moves its pin.

## The arrangement after

```
zui/                         the aggregator package `zui`: build.zig, build.zig.zon, CI, the documents
├── core/                    package `zui_core`: src/, tests/, bench/, zui_app/, zui_async/, zui_debug/,
│                            zui_reflect/, zui_testing/, zui_tracy/, zui_widgets/, zui_wire/
├── text/
│   ├── glyphs/              package `zui_glyphs`: what font systems and renderers share; pure Zig
│   ├── truetype/            package `zui_truetype`: the default font system, on stb_truetype
│   └── fonts/               package `zui_fonts`: the bundled typefaces and their licences
├── renderers/
│   ├── raylib/              package `zui_raylib`: Renderer, raylib Host, conformance, tour and showcase targets
│   ├── sokol/               package `zui_sokol`: Renderer, conformance, shaders
│   ├── terminal/            package `zui_terminal`: Renderer, terminal Host, conformance, targets
│   └── webgl/               package `zui_webgl`: the browser's drawing of a frame
├── hosts/
│   ├── native/              package `zui_host`: windows/, linux/, its examples
│   └── web/                 package `zui_web`: the page, the worker, the stepped Io, the site
├── apps/
│   ├── tour/                package `zui_tour`: one tour, generic over Host, Renderer and Text
│   └── showcase/            package `zui_showcase`
├── themes/                  package `zui_themes`
├── examples/                template/ and samples/
├── docs/  assets/
└── SPEC.md  ROADMAP.md  ARCHITECTURE.md  README.md  CLAUDE.md  LICENSE
```

Dependencies point one way:

```
zui_core ← zui_glyphs ← zui_truetype
                      ← zui_raylib, zui_sokol, zui_terminal, zui_webgl
zui_core ← zui_host, zui_web
zui_glyphs, zui_fonts ← zui_tour, zui_showcase
```

and a target, in a renderer's or host's package, names an app, a host, a
renderer and a font system. **A renderer never depends on a font system,
and a font system never depends on a renderer;** they meet in
`zui_glyphs`. A package names another by `.path`; only third-party
libraries (raylib, sokol, stb, Tracy) are fetched by URL, and every one of
them is `.lazy = true`.

A target is the application, a host, a renderer and a font system, named
at one place:

```zig
const App = zui_tour.App(.{ .Host = zui_raylib.Host, .Renderer = zui_raylib.Renderer, .Text = zui_truetype.Text, .renderer_name = "raylib" });

pub fn main(init: std.process.Init) !void {
    try zui_app.run(App, init, .{ .title = "zui tour (raylib)", .size = .{ 1440, 900 } });
}
```

A user pins one URL, as today:

```zig
const zui = b.dependency("zui", .{});
const zui_module = zui.module("zui");
const glyphs = zui.module("zui_glyphs");
const truetype = zui.builder.dependency("zui_truetype", .{}).module("zui_truetype");
const raylib_renderer = zui.builder.dependency("zui_raylib", .{}).module("zui_raylib");
```

The aggregator re-exports a package's modules exactly when the package has
no third-party library: core's, `zui_glyphs`, `zui_fonts`, and the apps.
Anything that links a C library is reached through `zui.builder`, so a
user never fetches a library they do not use.

## Room for the font system

The font system will be a section of its own in `ROADMAP.md`, after this
work: a contract with default implementations, through which an
application brings any typeface and any compatible font library, and zui
makes it work on every renderer. This restructure builds none of it. It
lays out the packages so that it fits without moving anything again, and
it removes the one fault the font system would otherwise inherit:
measurement and drawing done by separate code.

**The layers.** Every mature text stack splits text into the same parts:
Skia (typeface, font, shaper, text blob), cosmic-text (fontdb for
discovery, rustybuzz for shaping, swash for rasterization, its own layout
and glyph cache), egui (fonts laid out into a galley of positioned glyphs,
rasterized on demand into one atlas, drawn as textured triangles), and
Dear ImGui 1.92 (a font loader interface with stb_truetype and FreeType
behind it, glyphs loaded on demand into an atlas that grows, which the
renderer backend uploads):

| Layer | Turns | into | Implementations, now or later |
|---|---|---|---|
| source | a name, a file, embedded bytes, a system font | font bytes | `zui_fonts`; a host's system fonts (DirectWrite, fontconfig, CoreText), as a host service |
| face | font bytes | metrics, glyph ids, outlines or bitmaps | `zui_truetype` (stb); FreeType; DirectWrite and CoreText faces; bitmap faces (sokol_debugtext's) |
| layout | a run and a `MeasureKey` | positioned glyphs and their extent | one per-glyph pen in `zui_glyphs`, additive as SPEC.md §9.4 requires; a shaper (HarfBuzz) and font fallback later |
| raster | a glyph at a size | coverage, SDF, color, or nothing | stb, FreeType, platform rasterizers; nothing for a renderer that draws cells or outlines |
| atlas | rasters | texels in a cache with dirty rectangles | `zui_glyphs`, in the texel layout each renderer asks for |
| draw | positioned glyphs and an atlas | pixels or cells | each renderer |

**The rules this layout sets:**

- **One layout, two readers.** A text's `zuiMeasure` and its drawing take
  their glyph positions from the same function, in `zui_glyphs`. A
  renderer places what the layout gives it and advances no pen of its own.
  Commands keep carrying the text and its style, not glyphs, so frames and
  the wire stay as they are; a remote renderer runs the same layout, which
  the text contract's `zuiFingerprint` now guards.
- **The renderer declares what it draws, the font system provides it.**
  As a renderer declares `zui_commands` and `zui_output_formats` today, it
  declares the glyph placement it can draw: on a pixel grid, or one glyph
  per cell, as the terminal does. The font system lays text out for it,
  so a typeface brought by the application works on the terminal, with
  every glyph one cell wide and measured as such, and on a GPU, with its
  own advances. This is how the terminal runs the tour.
- **Core stays out of fonts.** The text contract in `zui_core` (SPEC.md
  §9.4: `zuiMeasure`, `zuiSegment`, `zuiFingerprint`, `FontId`,
  `MeasureKey`) is unchanged and does not import `zui_glyphs`. What font
  systems and renderers agree on lives in `zui_glyphs`, as does its
  conformance suite, since `zui_testing` is part of core.
- **Text looks its best with no setup.** Out of the box, text is drawn in
  `zui_fonts`' typefaces through `zui_truetype`: an application that names
  no fonts gets Atkinson Hyperlegible as font 0. A renderer's or library's
  built-in fonts (sokol_debugtext's 8×8 bitmaps, raylib's default font)
  are never a default and are not part of zui.
- **`text/` is a family,** as `renderers/` and `hosts/` are. A new face,
  shaper or rasterizer is a new package beside `truetype/` (`freetype/`,
  `harfbuzz/`), and a platform's system fonts are its host's. Nothing
  here is created ahead of the font system's own items.

What this restructure puts in `zui_glyphs` is only what today's renderers
need: a positioned glyph (font, glyph id, position), the pen that lays a
run out with per-glyph advances and letter spacing, its cell placement,
and the atlas. The font system's section designs the contract properly
and may change all of it.

## How the packages fit together

Each fact below was checked on Zig 0.16.0 in a model of this layout (a
core, two renderers, one with a lazy third-party library, an app, an
aggregator, and a separate consumer pinning the aggregator by URL):

| Fact | Consequence |
|---|---|
| Packages reaching one directory through different `.path` deps get one module: a type from it is the same type through either. | The renderers' re-exports of `zui` and its modules go; everything imports `zui` directly. |
| A lazy dependency is fetched only when a `build()` that runs calls `lazyDependency` for it. | raylib, sokol, stb and Tracy are fetched only for packages that use them. |
| A consumer pinning the aggregator fetches one package, and `.path` deps inside it resolve; the aggregator's `.paths` must list every package directory. | One hash for everything, as decided. |
| The aggregator can re-export a sub-package's module: `b.modules.put(b.graph.arena, "zui", core.module("zui"))`. | `b.dependency("zui", .{}).module("zui")` keeps working for users, as do the modules: `zui_app`, `zui_widgets`, and the rest. |
| **A `.path` cycle (root → renderer → `../..`) crashes the 0.16 toolchain** with a segfault before any `build()` runs. | Core cannot stay the root package once the root lists the renderers. It moves to `core/`, and the root is an aggregator. |
| As the top-level build, a package fetches every lazy dependency its `build()` asks for, whichever step was requested, even for `zig build --help`. | The aggregator's `build()` instantiates only packages without a third-party library. Each renderer and host runs its own steps from its own directory. |
| `std.Build.top_level_steps` is a public field. | The aggregator can forward core's steps under their own names. |

**Steps.** Each package keeps its own steps under its own names, run from
its directory: `cd renderers/raylib && zig build demo`. The root has:

- core's steps under their current names, forwarded: `test`, `check`,
  `docs`, `bench`, `bench-install`, `counts`, `bench-compare`,
  `bench-report`. `zig build test` stays core's quick run, and fetches
  only what core needs;
- `test-all` and `check-all`, each running `zig build test` (or `check`)
  in every package's directory as a process of its own, so nothing is
  fetched or configured until the step runs;
- `fmt` and `fmt-check` over the whole tree, which need no package.

The aggregator's `build()` therefore has this shape:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("zui_core", .{ .target = target, .optimize = optimize });
    for (core_modules) |name| b.modules.put(b.graph.arena, name, core.module(name)) catch @panic("OOM");
    reexport(b, "zui_glyphs", target, optimize);
    reexport(b, "zui_fonts", target, optimize);
    reexport(b, "zui_tour", target, optimize);
    reexport(b, "zui_showcase", target, optimize);
    forwardSteps(b, core, &.{ "test", "check", "docs", "bench", "bench-install", "counts", "bench-compare", "bench-report" });
    addStepInEveryPackage(b, "test-all", "test");
    addStepInEveryPackage(b, "check-all", "check");
    addFormatting(b);
}
```

## Rules while this is under way

- **Each slice is one commit on `main`** (or, for a repository's arrival,
  the history's merge plus one commit) and leaves every check green: the
  commands in `CLAUDE.md`'s *Verifying*, `zig build test-all`, and each
  moved package's own steps. Nothing is pushed unless the owner says so in
  that session.
- **History is kept.** A sibling's `main` is cloned into a scratch
  directory, rewritten with `git filter-branch --index-filter` so every
  commit's files sit under `<dir>/`, and merged with
  `--allow-unrelated-histories --no-ff`, so its commits, with their
  authors, dates and messages, stay in `git log -- <dir>`. (`git subtree
  add` keeps the original hashes, but its commits touch the old root
  paths, so `git log -- <dir>` shows only the merge.)
- **The documents teleport.** `SPEC.md`, `ROADMAP.md`, `ARCHITECTURE.md`,
  `README.md`, `CLAUDE.md` and `docs/` change only to stay correct about
  the new arrangement: paths, commands, which package holds what, and how
  to build. They describe the new arrangement as the way zui is. No
  roadmap item, *Done* entry, decision, or "moved from" note records the
  restructure; the commit messages carry that story, with this document's
  measurements. A slice brings the documents correct for what it moved, in
  the same commit.
- **Old repositories are read, not changed.** Before a sibling is merged,
  check that its `main` is clean and matches `origin/main`, and that no
  branch holds unmerged work (zui-host's `orchestrate/h4-slice3` and
  `orchestrate/linux-services` held none at `8673e9a`). If one does, stop
  and ask.
- **Outward-facing steps are the owner's.** Archiving the old GitHub
  repositories, changing the Pages source and anything else on GitHub is
  done by the owner, or with the owner's say in that session.
- **Measured before and after.** Slice 1 records the baseline: `zig build
  counts -- --json` and the test, check and conformance results of each
  sibling at its pin, in `RESTRUCTURE-BASELINE.md`, which slice 13
  deletes with this document. A slice that touches a hot path compares
  against it.

## Slices

Each slice says what it does and when it is done. Slices 2 to 7 bring the
repositories in as they are, so the merge and the cleanup are never in
one commit; slices 8 to 12 then remove the duplication.

### 1. Core into `core/`, an aggregator at the root

Move `src/`, `tests/`, `bench/` and every `zui_*` directory into `core/`,
with `build.zig` and `build.zig.zon` becoming core's. Core is a new
package, `.name = .zui_core` with a fingerprint of its own; the aggregator
keeps the name `zui` and the fingerprint `0xc00160dbaadffbc5`, since it is
what users have pinned. Write the aggregator as above, with `test-all` and
`check-all` covering core alone until other packages arrive. Tracy stays a
lazy dependency of core.

Done when:
- every command in `CLAUDE.md`'s *Verifying* runs from the root under its
  current name and passes, `-Dtarget=wasm32-freestanding`,
  `-Dtarget=powerpc-linux` and `-Dtarget=x86-linux` among them;
- `zig build bench-compare -- HEAD~1` works across the move, building the
  old layout's `bench-install` and the new one's, and the forwarded
  `bench-install` installs under the `--prefix` it is given;
- `zig build counts -- --compare` against the parent is within 2%;
- `test-all` runs core's tests as a process of its own and fails when
  they fail;
- a consumer outside the repository, pinning a tarball of the working tree,
  builds with `b.dependency("zui", .{}).module("zui")` and each module
  name, and fetches nothing else;
- the compile-error tests' expected paths still match.

### 2. zui-terminal into `renderers/terminal/`

Merge its history in, then: its zui pin becomes `.path = "../../core"`, its
re-exports of `zui` and the modules go, its CI jobs move into this
repository's workflow, each running in its directory
(`working-directory: renderers/terminal`), its README's content goes into
`README.md` and `ARCHITECTURE.md` where it belongs, and `test-all` and
`check-all` cover it.

Done when its tests, `check` on Linux, Windows and macOS, its conformance
and its demo's `--dump` check pass from its directory, and `test-all`
passes from the root.

### 3. zui-raylib into `renderers/raylib/`

As slice 2. raylib stays lazy; its demo's screenshots, cycle and idle
measurement run under `xvfb-run` as its CI ran them.

### 4. zui-sokol into `renderers/sokol/`

As slice 2. `zui_sokol_ui` and `zui_sokol_tour` stay as modules of the
package for now; the `shaders` step, the GL build (`-Dgl=true`), the
`wasm32-freestanding` tour link and the LLD workaround on Linux
(`linkThroughLlvmOnLinux`) come with it.

### 5. zui-host into `hosts/native/`

As slice 2. It drops its zui-sokol pin for `.path = "../../renderers/sokol"`.
Its `windows` and `linux` CI jobs move, the Windows cross-checks
(`x86_64-windows`, `aarch64-windows`) among them.

### 6. zui-web into `renderers/webgl/` and `hosts/web/`

Merge its history into `hosts/web/`, then move the drawing into
`renderers/webgl/`, with git's rename detection keeping each file's
history. Proposed split, confirmed by what each file imports:

| `renderers/webgl/` | `hosts/web/` |
|---|---|
| `draw_list.zig`, `backdrop_blur.zig`, `glyph_atlas.zig`, `truetype.zig`, `stb_truetype.c`, `text.zig`; `web/frame_drawer.mjs`, `web/check_draw.*`; `tools/draw_reference.zig`, `tools/bitmap_fonts.zig` | `browser.zig`, `browser_input.zig`, `browser_wire_check.zig`, `frame_stream.zig`, `record_stream.zig`, `stepped_io.zig`, `tour_session.zig`, `tour_worker.zig`, `demo_ui.zig`, `root.zig`; the rest of `web/`; `tools/demo_stream.zig`, `tools/replay_input.zig`, `tools/tour_frames.zig`; `pages.yml` |

Its `CLAUDE.md` folds into the root's. Its zui-sokol pin becomes a path.
The Pages workflow publishes from this repository; switching the Pages
source and the URL's move from `/zui-web` to `/zui` are the owner's.

Done when `test`, `test-demo`, `test-draw`, `test-input` and `test-site`
pass in headless Chromium from its directory, and `site` builds in
`ReleaseSmall`.

### 7. zui-themes and zui-examples into `themes/` and `examples/`

Merge both skeletons' histories in; their agent guides fold into the root's
`CLAUDE.md`, and their CI into the workflow.

### 8. `text/`: one layout for measuring and drawing

Make the three text packages from the copies:

- **`zui_fonts`:** one copy of Atkinson Hyperlegible regular and bold and
  of Liberation Mono, with their licences, each a `pub const` of its
  `@embedFile` bytes.
- **`zui_glyphs`:** a positioned glyph; the pen that lays a run out from a
  face's per-glyph advances and the letter spacing, without kerning, so
  measurement stays additive; the cell placement, in which every glyph is
  one cell; the renderer's declaration of which placement it draws; and
  the atlas, which takes coverage from any face on first use into memory
  reserved at `init`, packs it in rows, and lays it out in the texels the
  renderer asks for (sokol's RGBA, the browser's RG8).
- **`zui_truetype`:** `Text`, the text contract on stb_truetype, laying
  text out through `zui_glyphs` for the placement its renderer declares,
  with `zuiFingerprint` over its fonts' bytes and its options. A `Text`
  given no fonts draws in Atkinson Hyperlegible Regular as font 0 and
  embeds only that (53 KB); the bold (54 KB) and Liberation Mono (312 KB)
  are embedded only by an application that adds them.

Every renderer draws a text command by asking the same layout for its
glyphs: sokol and webgl from the atlas, raylib from the atlas in place of
raylib's own fonts, and the terminal into cells. No renderer advances a
pen of its own.

Done when:
- the copies of `truetype.zig`, `glyph_atlas.zig` and `stb_truetype.c` are
  gone, and no renderer computes a glyph's advance;
- `test-draw`'s comparison of the browser's frames against sokol's
  renderer passes unchanged;
- a stream measured with other fonts is rejected by the browser's client,
  where today it is drawn;
- nothing allocates after `init`.

### 9. Every renderer's host runs through `zui_app`

A `zui_terminal.Host`, a `zui_app` host as `zui_raylib.Host` is, which
hands its renderer the terminal's writer in its surface. A host belongs
to an OS, not a renderer, so sokol has none of its own: its hand-written
sokol_app demo goes, and its tour runs on `zui_host` through `zui_app`.
How a host whose platform owns the loop (the browser, macOS, mobile) runs
through `zui_app` is a roadmap item of its own after this work.

Done when the terminal's demo runs through `zui_app.run`, its `--dump`
and conformance pass, and `hosts/native`'s sokol tour cycle prints
`diagnostics ok: true` with no overflows.

### 10. One portable tour and one showcase in `apps/`

Build `zui_tour` from both copies, keeping every screen and feature of
either: `App` takes the Host, the Renderer and the Text as types, builds
its `Ui` with `zui_app.contextConfig`, and offers a screen only when the
renderer draws what it needs (`transforms` needs `.transform`, `materials`
needs `.material`, and `light_and_depth`'s frost needs `.backdrop_blur`).
It depends on `zui_glyphs` and `zui_fonts`, not on a font system: its
Text is `zui_truetype.Text` on every target, given the three fonts of
`zui_fonts` once, and its font ids come from adding them, not from fixed
numbers. No screen names a renderer's own fonts: the typography screen
shows the three, and sokol's bitmap fonts and raylib's built-in font leave
the tour. Tracy and the inspector stay optional, as zui-raylib's are.
`tour_test.zig` runs once, in `apps/tour`, declaring every screen
headlessly on a renderer that draws every command and on one that draws
none of the optional ones, in pixel and in cell placement.
`showcase.zig` moves to `apps/showcase`.

Done when one copy of each exists and the headless test passes.

### 11. Targets in place of the copies

Each renderer and host package gets a `tour` and a `showcase` target, the
terminal included, sokol's in `hosts/native`, each a `main` naming the app, the host, the renderer
and the font system. The terminal runs the whole tour; a screen whose
commands it does not draw is left out by the same capability test as on
any other renderer. zui-host's adapter shrinks to the target plus what its
options add (screenshots, idle measurement). zui-web's worker runs
`zui_tour`. Delete both `examples/` copies, the duplicated fonts and
licences, and `zui_sokol_tour`.

Then remove the renderers' own fonts, which nothing uses once the tour
draws in `zui_fonts`:

- sokol: `src/bitmap_glyphs.zig`, the renderer's and the destination's
  sokol_debugtext text path, and `zui_sokol_ui.Text`'s six bitmap fonts
  (`bitmap_font_count`, `glyphSize`), so its text is `zui_truetype.Text`;
- raylib: the fallback to raylib's built-in font and its spacing rule;
- webgl and the web host: `tools/bitmap_fonts.zig`, the `bitmap.fonts`
  file the page hands the client, the R8 bitmap texture and its drawing
  in `draw_list.zig`, and `text.zig`'s numbering after the six bitmap
  fonts;
- the sokol and raylib conformance harnesses, which measure with their
  renderer's text, measure with `zui_truetype.Text`.

Done when:
- every demo, screenshot, cycle, idle and stream check that ran before
  slice 2 runs from a target and passes;
- the terminal's `--dump` of every screen shows no text cut short;
- `rg -l 'Keep this file identical'` finds nothing, and `rg -i
  'debugtext|sdtx|bitmap_font|GetFontDefault'` finds nothing outside
  third-party code.

### 12. Conformance and CI, once

Fold what the renderers' `conformance.zig` executables share into
`zui_testing`, leaving each its window and its renderer. Collapse the
workflow: one job per package, running in its directory; every package on
every push; `counts` and `bench` on changes under `core/`; and every job
with `timeout-minutes: 10`.

### 13. The documents, and this one deleted

Read `SPEC.md`, `ROADMAP.md` (every *Where* naming `../zui-*` becomes a
directory here), `ARCHITECTURE.md` (§6 and §8 describe packages, not
repositories), `README.md`, `CLAUDE.md` (*Where things go*, *Verifying*,
and the rules for other repositories, which now describe packages) and
`docs/` end to end, and make each correct for the arrangement with no
trace of the move. SPEC.md's non-goals keep font loading, shaping and
rasterization out of the core, naming the `text/` packages as where they
go. Delete this document and `RESTRUCTURE-BASELINE.md`. The old
repositories are already archived, each with a README naming its new
directory.

## Decided

- The home is `github.com/AaronJClausen/zui`; users' URLs keep working.
- One hash for the whole repository is accepted; Zig's planned
  version-based deduplication will soften it, and 0.16 has none.
- All other work waits for this one.
- zui-web is split into a renderer (`renderers/webgl`) and a host
  (`hosts/web`), so the web host of H5 arrives as a host.
- The new packages are named `zui_core`, `zui_truetype`, `zui_webgl`,
  `zui_tour` and `zui_showcase`.
- The tour's text is `zui_truetype` on every renderer.
- The terminal runs the whole tour, not the showcase alone.
- Package steps keep their names and run from their own directories; the
  root forwards core's, and adds `test-all`, `check-all` and formatting
  over the whole tree.
- The font system is a section of `ROADMAP.md` of its own, after this
  work; this one only makes room for it.
- `text/` is a family of three packages, `zui_glyphs`, `zui_truetype` and
  `zui_fonts`; renderers depend on `zui_glyphs` and never on a font
  system.
- The renderers' own fonts are removed in slice 11 and are never a
  default: zui's text looks its best out of the box, in `zui_fonts`'
  typefaces.

Nothing is left to settle; the plan is ready to carry out.

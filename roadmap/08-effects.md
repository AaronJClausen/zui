# 08-effects: Effects

Stage 8 of SPEC.md §21: optional commands, lowering, transforms with hit
inversion, materials, `ExtendedColor`.

**Done when:** lowering tested for each; one renderer draws each; HDR
white brighter than SDR on the Windows host.

**Status.** Done.

## Items

| Item | Status |
|---|---|
| `08-effects:01-gradients-shadows-glow` Gradients, shadows and glow | done |
| `08-effects:02-backdrop-blur` Backdrop blur | done |
| `08-effects:03-corners-of-undrawn-decoration` Effects in the corners of a decoration that draws nothing | done |
| `08-effects:04-transforms` Transforms | done |
| `08-effects:05-materials` Materials | done |
| `08-effects:06-hdr-and-wide-gamut` HDR and wide gamut | done |

---

## 08-effects:01-gradients-shadows-glow — Gradients, shadows and glow

**Plan.** Gradients and shadows as optional commands, interpolated in
OKLab, declared by elements and lowered for renderers that do not draw
them. **Done when:** snapshot and lowering tests; the renderer suite's
reference scene declares both, and one renderer that declares the
commands passes the suite.

Elements declare `.effects = &zui.Effects{ .gradient, .shadow }`, a
pointer copied when declared; emission paints shadow, background,
gradient, culls a shadow by what it paints, and for a renderer that does
not declare them lowers a gradient to its OKLab middle and a shadow to
nothing, listing both in `Diagnostics.lowered`. `limits.max_effects`
(256) bounds their copies. The renderer suite's reference scene declares
both; its pixel renderer passes it drawing them and with them lowered,
and fails it interpolating in sRGB.

The sokol renderer (`c5b5de4`) declares both and passes the suite on
Linux, read back by `glReadPixels`: a gradient in bands at most 4 units
long, each vertex its OKLab `colorAt`, so sokol_gl's sRGB blend between
vertices stays within a step of it; a shadow as its box at the offset
grown by the spread, then six rings fading out to the blur. Its tour
shows them on a Light & Depth screen.

Against `c7810b7`, `counts` moves no scene by more than +0.77% (the
tooltip grids' `endFrame`) and no declaration at all; `bench-compare`,
turbo off, calls ten scenes faster (the documents view's declaration
−10.3%, the others −0.9% to −3.0%), none of the frame scenes slower, and
`init` +1.5% and the documents view's first frame +1.6% for the effects'
storage. One shadowed element makes the box tree's `endFrame` 3.1% more
instructions, the walk that looks for them.

Found on the way, each against the parent by `counts`: `Element.effects`
as a value made the interactive boxes' declaration 22% slower; a
`Style.effects` cost the static box tree's declaration 3.5%; one compare
added to the walk moved `endFrame` by up to 3.5%, and a second
instantiation of the walk stopped `emitText`, `floatingLayer` and
`sortLayers` being inlined, 4%; storage for every element made `init`
21% slower.

Not done: the raylib and terminal renderers still draw the lowered
forms.

**Spec.** §13.1, §13.3, §16.4.

## 08-effects:02-backdrop-blur — Backdrop blur

**Plan.** Backdrop blur of zui's own content, lowered to a tint. **Done
when:** snapshot and lowering tests; the renderer suite's reference
scene declares it, and one renderer that declares the command passes the
suite.

`Effects.backdrop_blur` (`zui.BackdropBlur`, a radius as CSS's standard
deviation and one tint) is emitted over the shadow and under the
background, in the decoration's corners, culled with its element, and
lowered to a rectangle in its tint, listed in `Diagnostics.lowered`
(`43e3d8f`). The renderer suite's viewport is 320 by 192 for a third
row: a blur floating over eight stripes, which a declared blur averages
under its tint and a lowered one tints stripe by stripe; its pixel
renderer passes both ways, box-averaging, and fails tinting without
blurring. The raylib and terminal renderers pass it lowered.

The sokol renderer (`d738cdc`) declares it and passes the suite on
Windows, read back by `glReadPixels`, and fails it drawing only the
tint. A frame with a blur is drawn into an offscreen target made like
the swapchain, so sokol_gl's pipelines and those of sokol's built-in
bitmap text draw into it unchanged, and copied to the swapchain at the
end; at each blur the scene's pass ends, a Gaussian runs along x then y
into two RGBA16F targets, its neighbouring pixels paired into one
filtered sample and the element's edge pixels repeated, and the pass
resumes with the result inside the rounded outline and the tint over it.
sokol_gl's vertex colors are 8-bit, so each weight is drawn as a coarse
part and a remainder scaled by a pipeline's fixed blend color of 1/255,
which sums the widest blur's weights to one within a quarter of a color
step. A frame without a blur is drawn as before. Its tour shows a
frosted pane drifting over the Light & Depth card, and on D3D11 the
title under it blurs in place, not mirrored.

Measured: the core's `counts` were unchanged in every scene, and
`bench-compare`, turbo off, called the box trees' `endFrame` 0.8% to
1.3% slower in the same instructions and simulated misses, `Effects`
having grown 12 bytes; moving the effects' storage last instead made
declaration 1% to 5% slower in most scenes, so it stays where
`08-effects:01-gradients-shadows-glow` put it. In the sokol renderer,
one D3D11 sample of the Light & Depth screen at 144 Hz reads "sokol
submit" 5.7 ms against 3.9 ms before, both holding 141 to 144 fps; the
GPU's cost is not timed.

Found on the way: an element whose decoration has a corner radius but no
background or border keeps no decoration (`core/src/context.zig:1223`,
`drawnDecoration`), so its effects are drawn square. Both the tour's
gradient card (`08-effects:01-gradients-shadows-glow`) and its frosted
pane show it; it is in ARCHITECTURE.md §7, and
`08-effects:03-corners-of-undrawn-decoration` fixes it.

Not done: the raylib and terminal renderers draw the tint alone. The
sokol renderer stops a blur's standard deviation at about 42 physical
pixels (129 taps per axis) and a frame at 16 blurs, drawing the rest as
their tint and counting them in `Renderer.backdrop_blurs.lowered`;
downsampling would lift the first.

**Spec.** §13.1, §13.3, §16.4.

## 08-effects:03-corners-of-undrawn-decoration — Effects in the corners of a decoration that draws nothing

**Plan.** Keep the decoration of an element that declares effects even
when it draws nothing itself, declared or through a static style, and
every other decoration as before. **Done when:** a test finds the radius
on each effect's command and its lowered form, both ways; `counts` moves
no scene by more than the noise; the sokol renderer's tour, on the fix,
shows the card and the pane rounded.

Declaration stored a decoration only when it had a background or a
border, so an element with a corner radius and effects alone drew them
square; `08-effects:02-backdrop-blur` found it on the sokol renderer's
tour. It now keeps the decoration whenever the element declares effects
(`keepsDecoration`, `62a21d2`), and emission draws nothing for it but
the effects' corners. Two tests in `core/src/tests/effects.zig` find the
radius on the `shadow`, `backdrop_blur` and `gradient` commands and on
the lowered rectangles, declared and static, and fail without the fix.
The sokol renderer (`6dbf06d`) draws the Light & Depth card's gradient
and shadow and the frosted pane rounded.

Measured: `counts` against the parent moved one scene, which declares no
effects: the documents view's declaration ran 40 fewer instructions
(30,567 to 30,527, −0.13%), the code generated for declaration having
changed; every other scene and phase was unchanged.

**Spec.** §13.1.

## 08-effects:04-transforms — Transforms

**Plan.** Transforms applied when painting only; hit testing inverts
them. **Done when:** snapshot and lowering tests; the renderer suite's
reference scene declares it, and one renderer that declares the command
passes the suite; an interaction test clicks a rotated button.

`Effects.transform` (`zui.Transform`, its `affine(bounds)` and
`zui.Affine`) is emitted as `transform_begin` before the element's
shadow and `transform_end` after its subtree and clip, begun again on a
floating element's own layer, culled through the box around the clip in
the element's units, and lowered to the element as laid out, listed in
`Diagnostics.lowered` (`592e305`). Each transformed element enters a
space in the hit results, and every hit test goes through
`Results.hits`, which maps the pointer into the region's space and
checks the clip around each transform. `core/src/tests/transforms.zig`
clicks a rotated button where it is drawn and not where it was laid out,
and through nested transforms up to the clip around them.
`checkCommands` checks transforms and clips nest; snapshots write a
transform's fields. The renderer suite's reference scene turns a box of
two halves a quarter, and its pixel renderer passes drawing it and with
it lowered, and fails turning it the wrong way; the raylib and terminal
renderers pass it lowered.

The sokol renderer (`f153f57`) declares it and passes the suite on
Linux, read back by `glReadPixels`. Each `transform_begin` composes its
affine with those around it and loads the result as sokol_gl's modelview
matrix, which sokol_gl bakes into each draw, so it holds across the
layers paint order needs. sokol's built-in bitmap text has no matrix, so
bitmap text inside a transform is drawn as sokol_gl quads from a texture
of its own font bits. A clip inside a transform is scissored to the box
around it in the window, and a backdrop blur inside one blurs that box
and samples each vertex where it is drawn. Its tour gains a Transforms
screen: a card turned, moved and scaled from sliders and pressed where
it is drawn, turned tiles, clock hands turned about their foot, and
sokol's six built-in bitmap fonts turned.

Measured: against `cceecfa`, `counts` moved no declaration and every
`endFrame` by −0.04% to −0.39%; `bench-compare`, turbo off, called no
frame scene slower and `init` 2.9% slower (+1.0% to +6.6%), `Effects`
having grown 32 bytes for each of its 256 copies a frame. The sokol
renderer's Transforms screen held 144 fps at 144 Hz on Linux, its "sokol
submit" reading 2.8 ms in one sample; the GPU's cost is not timed.

Not done: a pan or wheel over a transformed scroll container moves it
along the window's axes, and `Drag` and the pointer events report window
units; SPEC.md does not yet say which units they take inside a
transform. The sokol renderer cuts a clip inside a turned transform to
the box around it, since a scissor is upright; a stencil would cut it
exactly. The raylib and terminal renderers draw the element as laid out.

**Spec.** §13.1, §13.3, §16.4.

## 08-effects:05-materials — Materials

**Plan.** The decoration's `material`, typed by the renderer's
`MaterialHandle`, emitted in place of the background and lowered to it.
**Done when:** snapshot and lowering tests; the renderer suite's
reference scene declares it, and one renderer that declares the command
passes the suite; `counts` moves no scene beyond the noise.

`style.DecorationWith(MaterialHandle)`, `StyleWith` and `ElementWith`
make a context's types, `Ui.Decoration`, `Ui.Style` and `Ui.Element`,
identical to `zui.Decoration`, `zui.Style` and `zui.Element` when the
handle is `void` (`7af04c6`). A decoration with a material is kept even
without a background, and emission draws the `material` command over the
shadow and backdrop blur and under the gradient, its fallback the
background or transparent; for a renderer without `.material` it draws
the background and lists `.material` in `Diagnostics.lowered`.
`core/src/tests/materials.zig` tests both ways, a static style's
material and the order; snapshots write a material. The renderer suite's
reference scene declares a material when the harness gives one
(`harness.material(color)`), and its pixel renderer passes drawing it
and with it lowered, and fails drawing the fallback in its place.

The sokol renderer (`5903f48`) declares it with `zui_sokol.Material`, a
pattern between two colors (`solid`, `sheen`, `aurora`) moved by a phase
the application turns, and passes the suite on Linux with
`Material.solid` drawn through its shader, in a frame that also blurs a
backdrop. sokol_gl takes no shader of its own, so a material is a
triangle fan drawn with sokol_gfx at the start of its own layer, before
that layer's sokol_gl shapes; the shader is written in GLSL and checked
in as sokol-shdc's translation to GLSL 410, HLSL 5 and Metal. Its tour
gains a Materials screen: a card drawn by the shader with every field on
a slider, each pattern, a material beside its fallback, and a shadow
beneath one with a border and button over it. The tour's helpers that
build elements now name `Ui.Element`.

Measured: `counts` against `613760e` moved one scene, the documents
view's declaration, by 40 instructions (30,527 to 30,567, +0.13%), every
other scene and phase unchanged; `materialOf` is `inline`, since out of
line its `null` for a `void` handle was not folded and declaration grew
up to 6.3%. The sokol renderer's Materials screen held 144 fps at 144 Hz
on Linux, its "sokol submit" reading 2.3 ms in one sample; the GPU's
cost is not timed.

Not done: the sokol renderer's material has been drawn only with OpenGL;
its HLSL and Metal are sokol-shdc's and compile only when the tour runs
on Windows or macOS. The raylib and terminal renderers draw the
fallback.

**Spec.** §10.1, §13.1, §13.3.

## 08-effects:06-hdr-and-wide-gamut — HDR and wide gamut

**Plan.** `Config.Color = zui.ExtendedColor`, clamped for renderers
without `zui_extended_color`; headroom from the environment; the output
format negotiated through `Surface`.

**Done when:** snapshot and lowering tests; the renderer suite's
reference scene declares it, and one renderer that declares it passes
the suite; the Windows host shows HDR white brighter than SDR white.

The first slice landed the core: `zui.ExtendedColor` (4×f16 linear
scRGB, with `Color`'s helpers), `Config.Color` and its compile error,
and `Config.extended_color`, which `zui_app.contextConfig` takes from
the renderer. Every type that holds a color is generic over it
(`zui.BorderWith`, `EffectsWith`, `GradientWith`, `ShadowWith`,
`BackdropBlurWith`, `DecorationWith(Color, MaterialHandle)`,
`TextStyleWith`), named by the context as `Ui.Border` and the rest, and
`zui`'s own unless `Color` is `ExtendedColor`. The commands carry
`Ui.CommandColor`: emission clamps each color for a renderer that draws
only `Color` and sets `Diagnostics.clamped_colors` when that changed
one. A context in `Color` runs the same instructions as before in every
`counts` scenario, and `bench-compare` against `2ac7223` calls no
scenario slower. The flag first made `Diagnostics` 104 bytes, which
moved every array of the frame after it by 8 and made the box tree's
declaration 3.4% slower (2.8% for the documents view); `duplicate_ids`
became a saturating `u16`, so it stays 96. The second slice declares the
renderer suite's reference scene in `ExtendedColor`, with a box of HDR
white, and takes the suite's `extended_color` from the renderer, so one
that declares `zui_extended_color` is given every color as declared and
must encode it as `toColor` does (a test renderer that skips the
encoding fails); `zui_wire.Renderer(Ui)` declares `zui_extended_color`
when `Ui`'s commands carry `ExtendedColor`, and its commands round-trip
in either color. `toColor(fromColor(c))` is `c` for every 8-bit channel,
so the terminal renderer still passes at a tolerance of 0, and the
raylib and sokol renderers pass unchanged. The third slice, in the sokol
renderer (`06a28fa`): its renderer declares `zui_extended_color`, so
`zui_sokol.config` sets `extended_color`, and it encodes each command's
color at the point it is drawn, as `toColor` does, from either color the
application declares; it passes the suite in its sokol_app window, and
fails it when the channels are encoded linearly instead. The fourth
slice negotiates the output format: `zui.OutputFormat` (`.sdr`,
`.scrgb_fp16`) and a host's and a renderer's optional
`zui_output_formats`, which must include `.sdr`, and in a renderer names
`.scrgb_fp16` only beside `zui_extended_color`, each a compile error.
`zui_app` opens the window with the formats both declare,
`zui.sharedOutputFormats`, in `WindowOptions.output_formats`, and
reports them; each native `Surface` carries the format the host chose,
`.sdr` by default, so the backends compile unchanged, and
`surface.outputFormat()` reads it. The host suite fails a surface in a
format the host does not declare. The core's hot paths are untouched;
the raylib, sokol and terminal renderers pass unchanged. The fifth slice
reads an `.scrgb_fp16` target back: a harness whose `beginDraw` returns
a surface in that format is read through its optional `extendedPixel`,
HDR white must read back as `hdr_white` (four times SDR white, within
the tolerance's share of it), and a translucent color is expected to
blend, and a blur to average, in linear light there. The suite's own
test renderer draws into either target and passes in both; one that
clamps HDR into its FP16 target fails, reading back SDR white. Nothing
outside `zui_testing` changed. The sixth slice, in the sokol renderer
(`e06389e`): its renderer takes an `.offscreen` surface and draws into
an image of its own in the surface's format, RGBA16F for `.scrgb_fp16`,
in linear light, through a shader with sokol_gl's layout that decodes
each 8-bit sRGB vertex color and texel; a color brighter than SDR white
is carried divided by its brightest channel, which rides in sokol_gl's
per-vertex point size and is multiplied back. Its conformance run passes
the suite into the swapchain and into `.sdr` and `.scrgb_fp16` offscreen
images, and fails the FP16 run when HDR is clamped. It does not declare
`zui_output_formats` yet, since its `.win32` swapchain is still 8-bit.

The seventh slice, in `hosts/native/` (`da286d5`): the Windows host
declares `zui_output_formats` with `.scrgb_fp16`. It reads the monitor
the window is on through DXGI (whether Windows runs it in HDR, and its
peak) and the display configuration (the SDR white level the SDR content
brightness slider sets), opens the surface in `.scrgb_fp16` there when
the window was opened with it and in `.sdr` otherwise, and reports
`Environment.hdr_headroom`, the peak over SDR white, or 1 in `.sdr`. It
reads them again when the window moves to another monitor, the displays
change, or a setting does. `forced_display_color` keeps its tests off
the monitor. The eighth slice, in the sokol renderer (`f81fd03`): the
renderer declares `zui_output_formats` with `.scrgb_fp16` when it draws
through DirectComposition (not with `-Dgl=true`). A `.win32` surface in
`.scrgb_fp16` resizes the composition swapchain to RGBA16F in linear
scRGB, draws the frame as into an `.scrgb_fp16` offscreen image, which
the suite checks, and copies it into the swapchain through a shader that
multiplies each color by the monitor's SDR white over 80 nits, since
zui's scRGB puts SDR white at 1.0 and the swapchain's puts 80 nits
there. The level is read at most twice a second, since the slider tells
no window when it moves. The ninth, in `hosts/native/` (`cc3033b`):
`zig build hdr` shows boxes of SDR white and two and four times it, and
`-- --measure` reads them back off the desktop in scRGB through DXGI's
desktop duplication, which sees past SDR white where GDI clips at it. On
the reference machine's monitor in HDR (a 1,068-nit peak, SDR white at
280 nits): `scrgb_fp16`, headroom 3.81; SDR white 3.500 in scRGB, twice
it 7.000, four times it 14.000, 2.00× and 4.00× SDR white. The native
hosts' tour, the sokol renderer's demo, its conformance run and every
test pass in `.sdr` as before.

Left for later: the SDR content brightness slider is read again only
when the window moves, the displays change or a setting does, and by the
sokol renderer twice a second, so a headroom reported after the slider
moves waits for one of those; the Linux host (`10-reach:01-linux-host`)
and macOS (`14-macos:01-macos-host`) report no headroom.

**Spec.** §13.1, §13.3, §16.4, §18.

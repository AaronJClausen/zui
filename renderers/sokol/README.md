# The sokol renderer

`zui_sokol` is a [sokol](https://github.com/floooh/sokol) renderer,
through [sokol-zig](https://github.com/floooh/sokol-zig): it measures
text through zui's text contract, and draws zui's frames as a renderer with sokol_gl
and shaders of its own, on D3D11 (Windows), Metal (macOS) or OpenGL
(Linux), its text in the fonts of the text contract it is given, from a
`zui_glyphs` atlas where `zui_glyphs` laid it out. It draws every
optional command, gradients, shadows, backdrop blurs, transforms and
materials, and extended colors. sokol-zig, and stb_truetype (from
[stb](https://github.com/nothings/stb)) for the conformance harness's
`zui_truetype`, are fetched the first time it is built; on Linux it needs
`libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev libegl-dev libwayland-dev`.

```zig
// build.zig, with `zui` the dependency from the main README; `.gl = true` renders with OpenGL instead of D3D11 or Metal
const zui_sokol = zui.builder.dependency("zui_sokol", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui_sokol", zui_sokol.module("zui_sokol"));
```

```zig
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_sokol = @import("zui_sokol");
const zui_truetype = @import("zui_truetype");
const Ui = zui.Context(zui_app.contextConfig(zui_sokol.Renderer, .{ .Text = zui_truetype.Text }));

// before the first frame; given no fonts, font 0 is Atkinson Hyperlegible:
var text: zui_truetype.Text = .{};
const bold_font = try text.addFont(zui_fonts.atkinson_hyperlegible_bold);

// in sokol_app's init callback, after sg.setup:
renderer = .init(&text);
renderer.clear_color = background;

// in the frame callback, with the record your event callback built:
ui.beginFrame(&record);
// ... declare your UI ...
const frame = ui.endFrame();
try renderer.zuiSubmit(.library, frame); // one swapchain pass, cleared to clear_color
ui.release(frame);
```

zui has no host on sokol_app: `zui_app` runs the renderer on `zui_host`'s
native hosts (see [the tour on a native host](../../hosts/native/README.md#the-tour-on-a-native-host)).

`zui_sokol.Renderer` implements zui's renderer contract. Its surfaces are
`.library`, sokol_app's swapchain; `.offscreen`, an image of the renderer's
own in the surface's size and format (`.sdr` or `.scrgb_fp16`), which
`renderer.offscreenImage()` returns after `zuiSubmit`, drawn with
`renderer.offscreen_sample_count` samples per pixel (1 by default; 4
smooths its edges as a window with `.sample_count = 4` does) and resolved
to one; and on Windows `.win32`: a native host's window, such as
`zui_host`'s (in [hosts/native/](../../hosts/native/README.md)), which the
renderer draws into without sokol_app, setting sokol_gfx up on a context
of its own and presenting with vsync. With D3D11 (the default) that is a
swapchain DirectComposition composes into the window with its alpha, so
where the frame draws nothing a system backdrop (Mica, Acrylic) shows.
With D3D11 the renderer declares `zui_output_formats` with `.scrgb_fp16`,
so a host on an HDR monitor can open the window in it: the swapchain then
holds half-float scRGB, the frame is drawn as into an `.scrgb_fp16`
offscreen image, and one pass copies it into the swapchain, multiplied by
the monitor's SDR white over 80 nits (read again at most twice a second),
so that SDR white shows as other windows' white does and a color above it
shows brighter. With D3D11 it draws into many windows: `zuiAttachSurface`
makes a swapchain for each window after the first on the first one's
device, which the renderer holds until `deinit`, so any window may close
first, and each window keeps its own scRGB and backdrop-blur targets;
`zuiDetachSurface` frees them before the window closes, and `zui_app`
calls both. With `-Dgl=true` it is an OpenGL 4.3 context, whose alpha
Windows ignores, and SDR only. On Linux the native surface is `.wayland`,
a native host's Wayland surface, which the renderer draws into with an
OpenGL 4.3 context made through EGL on a `wl_egl_window`, sized to each
frame's viewport in physical pixels and presenting with vsync; its
configuration has no alpha, so the compositor shows the frame opaque.
It draws into many Wayland surfaces too: `zuiAttachSurface` makes a
`wl_egl_window` and an EGL surface for each surface after the first, on
the first one's EGL display and context, which the renderer holds until
`deinit`, so any window may close first; the context moves to the
surface each frame is drawn into, and each window keeps its own
backdrop-blur and offscreen targets. A frame drawn into a surface the
compositor never shows waits in its swap for a frame callback that never
comes, so a Wayland window the renderer draws must be shown:

```zig
var renderer: zui_sokol.Renderer = try .initForSurface(&text, host.zuiSurface(.main));
defer renderer.deinit(); // also shuts sokol_gfx down
renderer.clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 }; // let the backdrop show
try renderer.zuiSubmit(host.zuiSurface(.main), frame);
```

`zui_host` runs the tour and the showcase this way, through `zui_app`.
`zui_app.contextConfig(zui_sokol.Renderer, .{ .Text = … })` builds the
`Config` from the renderer's declarations: `ImageHandle` is `zui_sokol.Image` (the ids of a view and a sampler, made
by `zui_sokol.imageOf(view, sampler)`), `MaterialHandle` is
`zui_sokol.Material`, the optional commands are `gradient`, `shadow`,
`backdrop_blur`, `transform` and `material`, the renderer draws extended
colors (`Config.Color` may be `zui.ExtendedColor` or `zui.Color`), and
there is no `CustomData`, so the renderer's `switch` over the commands
names exactly the base commands, `image`, `gradient`, `shadow`,
`backdrop_blur`, `transform_begin`, `transform_end` and `material`. A
context with a `MaterialHandle` has its own element types, so a helper
that builds an element names `Ui.Element` (or `Ui.Decoration`,
`Ui.Style`) rather than `zui.Element`:

```zig
fn panel(seconds: f32) Ui.Decoration {
    return .{
        .background = .rgb(0x10304a), // drawn by a renderer without .material
        .material = .{ .pattern = .aurora, .first = .rgb(0x10304a), .second = .rgb(0x40e0a0), .phase = seconds / 8 },
        .corner_radius = .all(12),
    };
}
```

| zui | sokol |
|---|---|
| `rectangle` | sokol_gl quads, or a triangle fan with each corner's own radius |
| `border` | a ring of triangles inside the bounds, with per-edge widths and per-corner radii |
| `text` | laid out by `zui_glyphs` as it was measured, in the fonts of the text contract `init` was given, its glyphs rasterized at the text's size in physical pixels into a `zui_glyphs` atlas and drawn as sokol_gl quads; text in a font id those fonts lack is not drawn |
| `image` | a textured sokol_gl quad colored by the tint, or a triangle fan with each corner's own radius |
| `gradient` | the rounded outline cut into bands at most 4 units long across the gradient (64 at most), each vertex colored by `colorAt`, so sokol_gl's sRGB blend between vertices stays within a step of zui's OKLab one |
| `shadow` | the rounded box at the offset, grown by the spread, in the shadow's color, then six rings out to the blur, fading to clear along a smoothstep |
| `backdrop_blur` | the frame is drawn into an offscreen target like the swapchain, and paused at each blur: a Gaussian along x, then along y, of what lies under the element, its edge pixels repeated, summed tap by tap into two float targets the size of the frame: RGBA32F (16 bytes a pixel), or RGBA16F where the GPU cannot render, blend and filter that, though half floats round each sum as the driver chooses, and one driver's blur can differ from another's by several color steps; the frame resumes with the result drawn inside the rounded outline and the tint over it, and is copied to the swapchain at the end. A frame without one is drawn as before |
| `material` | `zui_sokol.Material`, a pattern between two colors (`solid`, `sheen`, `aurora`) moved by its phase: the rounded outline as a triangle fan, drawn by the material shader at the start of its own layer, before the layer's sokol_gl shapes. The shader and pipeline are made on the first frame with a material |
| colors | `zui.ExtendedColor` (the renderer declares `zui_extended_color`) or `zui.Color`, as the application declares them. Into an 8-bit target an extended color is clamped into SDR and sRGB's gamut and encoded to 8 bits, as `ExtendedColor.toColor` does. Into an `.scrgb_fp16` offscreen image (RGBA16F) the frame is drawn in linear light through a shader of the renderer's own, which decodes each 8-bit sRGB vertex color and texel; a color brighter than SDR white is carried divided by its brightest channel, with that channel in sokol_gl's per-vertex point size, which the shader multiplies back. Negative (out-of-sRGB-gamut) channels are still clamped there, and materials mix their colors in linear light |
| `clip_begin` / `clip_end` | `sg.applyScissorRect` per layer, at the record's `scale × zoom`; inside a transform, the box around the clip in the window |
| `transform_begin` / `transform_end` | sokol_gl's modelview matrix, loaded with the composed transform; a backdrop blur inside one blurs the box around it in the window and samples where it is drawn |

To keep zui's paint order around what sokol_gl cannot draw in a batch of
its own, the renderer starts a new layer whenever the clip changes, a
backdrop blur must sample what came before it, or a material follows
shapes, then replays the layers in order, each under its own scissor
rectangle. The shaders, the material's, the linear-light one and
the scRGB present, are written in `src/*.glsl` and checked in as their
`.glsl.zig`, translated by sokol-shdc to GLSL 410, HLSL 5 and Metal, so
building `zui_sokol` never runs sokol-shdc; after changing the GLSL, run
`zig build shaders`.

Current limits:
- **A backdrop blur's standard deviation stops at about 42 physical
  pixels**, the widest its 129 taps per axis reach, and a frame blurs at
  most 16 elements; the rest draw their tint alone, counted in
  `Renderer.backdrop_blurs.lowered`, as do all of them on a GPU that
  cannot render, blend and filter RGBA32F or RGBA16F. The format the
  blurs are summed in is `Renderer.backdrop_blurs.accumulation_format`.
- **A frame draws at most 256 materials**, of 32,768 vertices in all;
  the rest draw their fallback background, counted in
  `Renderer.materials.lowered`, as do all of them on a backend sokol-shdc
  was not asked for (GLES, WebGPU, Vulkan) or where the shader does not
  compile.
- **A turned clip cuts to the box around it.** A scissor rectangle is
  upright, so a clip inside a rotated transform lets through what lies
  between it and the box around it in the window; moved or scaled, it
  cuts exactly. Transforms nest 64 deep; deeper ones are drawn as their
  parent is, counted in `Renderer.transform_overflows`.
- **A shadow is geometry, not a blur.** Its fade is drawn in rings, so a
  wide blur on a small box shows faint steps, and a translucent element
  shows its own shadow through it.
- **Text has no kerning or shaping.** Each codepoint is one
  glyph, advanced by its own width, so measuring a run split at any word
  gives the same width. The atlas is one 1024×1024 image, reserved by
  `init` and remade whenever a frame needs glyphs it lacks (sokol_gfx
  images cannot be updated once made); when a frame needs more than it
  holds, it starts over, and `Renderer.glyphOverflows()` counts frames
  whose glyphs still did not fit. Text larger than 160 physical pixels is
  drawn from 160-pixel glyphs.

`zig build conformance` runs zui's renderer
suite (`zui_testing.expectRendererConforms`) against the renderer, in the
first frame of a sokol_app window, four times: into the window's
swapchain, into an `.offscreen` surface in `.sdr` and in `.scrgb_fp16`,
and into an `.sdr` one with four samples per pixel. `src/conformance.zig`
reads each frame back, from the swapchain with `glReadPixels` before the
window presents it and from the offscreen image with `glGetTexImage`, so
the suite checks every clip and fill, the image's tint and rounded
corners, and a drawn gradient, shadow, backdrop blur, transform and
material, by their pixels. The harness's material is `Material.solid`,
drawn through the shader. The suite declares its scene in
`zui.ExtendedColor`, HDR white among it, measured with `zui_truetype.Text`, and checks that each color is
encoded as `ExtendedColor.toColor` does in an 8-bit target, and that HDR
white reads back four times SDR white, with colors blended and blurs
averaged in linear light, in the FP16 one. sokol_gfx cannot read a frame
back, so the suite always renders with OpenGL, whatever `-Dgl` says. CI
runs it on Linux under `xvfb-run`, and it passes on Windows.

## Development

Run from `renderers/sokol/`; the first build fetches sokol-zig and stb, and on Linux needs
`libx11-dev libxi-dev libxcursor-dev libgl1-mesa-dev libpulse-dev libegl-dev libwayland-dev`:

| Command | What it does |
|---|---|
| `zig build test` | run the renderer's unit tests |
| `zig build conformance` | run zui's renderer suite against it in a window, always with OpenGL; needs a display |
| `zig build check` | compile the renderer, its tests and the conformance suite without running them |
| `zig build check -Dgl=true` | the same, rendering into a native host's window with OpenGL instead of D3D11 |
| `zig build shaders` | regenerate each `src/*.glsl.zig` from its GLSL with sokol-shdc, after the GLSL changes |

Its `tour` and `showcase` targets are the native hosts' (see
[hosts/native/](../../hosts/native/README.md#the-tour-on-a-native-host)).
Its links on Linux print `warning(link): unexpected LLD stderr` and a
`failed command:` line and still succeed.

## The tour on sokol

[The tour](../../apps/tour/README.md) on the sokol renderer draws every
screen: Light & Depth's gradients, shadows and frosted pane, and the
Transforms and Materials screens, which are offered only to a renderer
that draws what they need.

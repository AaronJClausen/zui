# The WebGL renderer

`zui_webgl` is the browser's drawing of a frame: `DrawList` lays a frame's commands
out as triangles, as the sokol renderer does, in batches that each draw
under one scissor rectangle, and `web/frame_drawer.mjs` draws them on a
canvas through WebGL 2, with four samples per pixel resolved to one,
which smooth every edge as the sokol renderer's multisampled targets do with
`sample_count = 4`: rectangles, borders, clips, gradients, shadows and
transforms, and text, once the page hands over the stream's fonts:
glyphs placed where `zui_glyphs` lays them out, from a `zui_glyphs` atlas
of RG8 texels, as the sokol renderer places and packs its own; text in a
font id the text has no face for is not drawn. It draws any text's fonts,
taken as `anytype`, and depends on no font system or third-party library.
A backdrop blur copies what was drawn beneath it and blurs it as the sokol
renderer does, along x and then y into two float targets, before the pane
is drawn from them; a material is drawn by the sokol renderer's material
shader, ported to GLSL ES. The blur is summed in RGBA32F where WebGL can
render, blend and filter it (`EXT_color_buffer_float`, `EXT_float_blend`,
`OES_texture_float_linear`), as the sokol renderer sums it where its GPU
can, and otherwise in RGBA16F, whose rounding differs between drivers by
several color steps; without `EXT_color_buffer_float`, blurs are drawn as
their tint alone. Images are not drawn yet. `zui_webgl.Drawing` declares
what it draws as a renderer declares it, with the sokol renderer's image
and material shapes, so an application whose frames a page draws
configures its context for it, as the web host's tour does:

```zig
const Ui = zui.Context(zui_app.contextConfig(zui_webgl.Drawing, .{ .Text = zui_truetype.Text }));
```

Everything in it compiles for `wasm32-freestanding`; it reserves its
memory in `init`.

```zig
// build.zig, with `zui` the dependency from the main README, for a module the browser runs
const browser = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
const zui_webgl = zui.builder.dependency("zui_webgl", .{ .target = browser, .optimize = optimize });
client.root_module.addImport("zui_webgl", zui_webgl.module("zui_webgl"));
```

```zig
var text: zui_truetype.Text = .{}; // or any text contract `zui_glyphs.Fonts.of` erases
var draw_list: zui_webgl.DrawList = try .init(gpa);
draw_list.layOut(frame.commands(), frame.params, &text);
// hand draw_list.batches(), .vertices(), .backdropBlurs(), .blurTaps(),
// .materials() and, when it changed, draw_list.glyph_atlas.texels to the
// page's FrameDrawer, as hosts/web's client does
```

The web host's `test-draw` checks it against the sokol renderer (see
[hosts/web/](../../hosts/web/README.md)).

## Development

Run from `renderers/webgl/`:

| Command | What it does |
|---|---|
| `zig build test` | run the draw list's and blur's unit tests |
| `zig build check` | compile the unit tests natively and for `wasm32-freestanding` without running them |

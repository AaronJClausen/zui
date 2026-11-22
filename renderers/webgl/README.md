# The WebGL renderer

`zui_webgl` is the browser's drawing of a frame: `DrawList` lays a frame's commands
out as triangles, as the sokol renderer does, in batches that each draw
under one scissor rectangle, and `web/frame_drawer.mjs` draws them on a
canvas through WebGL 2, with four samples per pixel resolved to one,
which smooth every edge as the sokol renderer's multisampled targets do with
`sample_count = 4`: rectangles, borders, clips, gradients, shadows and
transforms, with round, continuous and chamfered corners traced point
for point as the sokol renderer traces them, and text, once the page hands over the stream's fonts:
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
their tint alone. Images are not drawn yet.

`zui_webgl.Renderer` is the renderer: it draws into a `.web` surface,
`.{ .web = .{ .canvas = id } }`, laying each frame out in its `DrawList`
in the same WebAssembly instance and handing the laid-out frame, a
`zui_webgl.DrawnFrame`, to the `FrameDrawer` the page keeps for that
canvas id, through the two imports `frameDrawerImports` gives the module.
Its `init(surface, text)` takes the text the frames were measured with,
or anything `zui_glyphs.Fonts.of` erases, and reserves its memory; it
declares the commands and the corner shapes it draws, with the sokol
renderer's image and material shapes, so a context configured for it carries what it draws:

```zig
const Ui = zui.Context(zui_app.contextConfig(zui_webgl.Renderer, .{ .Text = zui_truetype.Text }));
var renderer: zui_webgl.Renderer = .{};
try renderer.init(.{ .web = .{ .canvas = 0 } }, &text);
defer renderer.deinit();
try renderer.zuiSubmit(.{ .web = .{ .canvas = 0 } }, ui.endFrame());
```

```js
// the page: the module draws canvas 0 on this drawer
import { FrameDrawer, frameDrawerImports } from "./frame_drawer.mjs";
const drawers = new Map();
const { instance } = await WebAssembly.instantiateStreaming(fetch("app.wasm"), frameDrawerImports(drawers, () => instance.exports.memory));
drawers.set(0, new FrameDrawer(canvas)); // or an OffscreenCanvas
```

A canvas whose WebGL cannot render into float textures answers so before
each frame, and its blurs are laid out as their tint alone. The renderer
runs only in WebAssembly: called elsewhere it is a compile error, and a
test draws onto a page of its own with `zui_webgl.RendererOn(Page)`, whose
`Page` declares `blursBackdrops(self, canvas) bool` and `draw(self,
canvas, frame: *const DrawnFrame) void`.

Everything in it compiles for `wasm32-freestanding`.

```zig
// build.zig, with `zui` the dependency from the main README, for a module the browser runs
const browser = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
const zui_webgl = zui.builder.dependency("zui_webgl", .{ .target = browser, .optimize = optimize });
app.root_module.addImport("zui_webgl", zui_webgl.module("zui_webgl"));
```

`zig build test` runs zui's renderer conformance suite on it natively, its
frames handed to a page that draws none, so it checks what the renderer
accepts without reading pixels back. The web host's `test-draw` checks
its drawing against the sokol renderer's, pixel by pixel (see
[hosts/web/](../../hosts/web/README.md)).

## Development

Run from `renderers/webgl/`:

| Command | What it does |
|---|---|
| `zig build test` | run the unit tests, the renderer suite on a page that draws nothing, and the compile errors |
| `zig build check` | compile the unit tests natively and for `wasm32-freestanding` without running them |

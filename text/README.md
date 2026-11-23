# Text

Three packages hold zui's text:

| Package | Holds |
|---|---|
| [`glyphs/`](glyphs/), `zui_glyphs` | what font systems and renderers share, so text is drawn where it was measured: the one layout that places a run's glyphs, the placement a renderer declares (a pixel grid, or the terminal's cells), the handle a renderer draws a text's fonts through, and the glyph atlas. Pure Zig; the root re-exports it |
| [`truetype/`](truetype/), `zui_truetype` | the default font system, `zui_truetype.Text`, on stb_truetype, which its first build fetches. It is reached through `zui.builder.dependency("zui_truetype", …)`, never re-exported |
| [`fonts/`](fonts/), `zui_fonts` | Atkinson Hyperlegible Regular, Bold, Italic and Bold Italic and Liberation Mono, each a `pub const` of its bytes, with their licences. The root re-exports it |

zui measures text through the text contract the application names, and
`zui_truetype.Text` is the default one: TrueType fonts on stb_truetype,
which given no fonts measures and draws in Atkinson Hyperlegible Regular
as font 0, the only font it then embeds. Fonts are added before the
first frame, each `addFont` returning its `FontId`; `zui_fonts` bundles
Atkinson Hyperlegible Regular, Bold, Italic and Bold Italic and
Liberation Mono, and only the ones an application references are
embedded. A font's bytes may also arrive at run time, into memory the
application reserves.

```zig
var text: zui_truetype.Text = .{ .placement = zui_glyphs.placementOf(Renderer) };
const body = try text.addFont(zui_fonts.atkinson_hyperlegible_regular);
const code = try text.addFont(zui_fonts.liberation_mono_regular);
var ui: Ui = try .init(gpa, io, &text);
ui.text("let x = 1;", .{ .font = code, .size = 14 });
```

A run is laid out once, in `zui_glyphs`, and that layout is both what
the text measures and where the renderer draws each glyph: every glyph
advances the pen by its font's advance and the letter spacing, without
kerning, so a run measures as its words do. A renderer declares how it
places glyphs, on the pixel grid or one per terminal cell
(`glyph_placement`), and the text lays out for it, so the same fonts
measure in cells on the terminal. A renderer takes the text as `anytype`
and never names a font system, so another font system plugs in by
providing `zui_glyphs`' few methods (`fontMetrics`, `advance`,
`glyphIndex`, `glyphBox`, `rasterize`) and passing
`zui_glyphs.expectFontsConform`. Its `zuiFingerprint` covers its fonts'
bytes and its placement, so a remote renderer refuses a stream measured
with other fonts.

A font's `zui_glyphs.FontMetrics` give its ascent, descent and line gap,
and its x-height and cap height, in font units, which a design sizes its
text by (`zui.design.FaceMetrics.of`). `zui_truetype` reads the two
heights from the font's OS/2 table, which carries them from its version
2 on. A face whose table is older, or missing, takes them from the tops
of its `x` and `H` glyphs, and a face without those from 0.55 and 0.75
of its ascent. The bundled faces carry them: Atkinson Hyperlegible's are
496 and 668 of 1,240 units from ascent to descent, Liberation Mono's
1,082 and 1,349 of 2,320.

## Development

Run from each package's directory, `zig build test` and
`zig build check`; `check` also compiles the package's tests for
`wasm32-freestanding`.

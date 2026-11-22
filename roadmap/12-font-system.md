# 12-font-system: The font system

A contract with default implementations, through which an application
brings any typeface and any compatible font library, and zui makes it
work on every renderer. The packages already have room for it: what font
systems and renderers share is `zui_glyphs` (`text/glyphs/`), the
default font system is `zui_truetype` (`text/truetype/`), and the
bundled typefaces are `zui_fonts` (`text/fonts/`), so the font system
moves nothing. Measuring and drawing already take their glyphs from one
layout, so it inherits no two loops that must agree. It is not a stage
of SPEC.md §21 and has no items yet; they are numbered here, and given
their Grounding, Plan and Done when, as the owner orders them into the
queue.

**The layers.** Every mature text stack splits text into the same parts:
Skia (typeface, font, shaper, text blob), cosmic-text (fontdb for
discovery, rustybuzz for shaping, swash for rasterization, its own
layout and glyph cache), egui (fonts laid out into a galley of
positioned glyphs, rasterized on demand into one atlas, drawn as
textured triangles), and Dear ImGui 1.92 (a font loader interface with
stb_truetype and FreeType behind it, glyphs loaded on demand into an
atlas that grows, which the renderer backend uploads):

| Layer | Turns | into | Implementations, now or later |
|---|---|---|---|
| source | a name, a file, embedded bytes, a system font | font bytes | `zui_fonts`; a host's system fonts (DirectWrite, fontconfig, CoreText), as a host service |
| face | font bytes | metrics, glyph ids, outlines or bitmaps | `zui_truetype` (stb); FreeType; DirectWrite and CoreText faces; bitmap faces |
| layout | a run and a `MeasureKey` | positioned glyphs and their extent | one per-glyph pen in `zui_glyphs`, additive as SPEC.md §9.4 requires; a shaper (HarfBuzz) and font fallback later |
| raster | a glyph at a size | coverage, SDF, color, or nothing | stb, FreeType, platform rasterizers; nothing for a renderer that draws cells or outlines |
| atlas | rasters | texels in a cache with dirty rectangles | `zui_glyphs`, in the texel layout each renderer asks for |
| draw | positioned glyphs and an atlas | pixels or cells | each renderer |

**The rules it keeps:**

- **One layout, two readers.** A text's `zuiMeasure` and its drawing
  take their glyph positions from the same function, in `zui_glyphs`. A
  renderer places what the layout gives it and advances no pen of its
  own. Commands carry the text and its style, not glyphs, so frames and
  the wire stay as they are; a remote renderer runs the same layout,
  which the text contract's `zuiFingerprint` guards.
- **The renderer declares what it draws, the font system provides it.**
  As a renderer declares `zui_commands` and `zui_output_formats`, it
  declares the glyph placement it can draw (`glyph_placement`): on a
  pixel grid, or one glyph per cell, as the terminal does. The font
  system lays text out for it, so a typeface brought by the application
  works on the terminal, with every glyph one cell wide and measured as
  such, and on a GPU, with its own advances. This is how the terminal
  runs the tour.
- **Core stays out of fonts.** The text contract in `zui_core` (SPEC.md
  §9.4: `zuiMeasure`, `zuiSegment`, `zuiFingerprint`, `FontId`,
  `MeasureKey`) does not import `zui_glyphs`. What font systems and
  renderers agree on lives in `zui_glyphs`, as does its conformance
  suite, since `zui_testing` is part of core.
- **Text looks its best with no setup.** Out of the box, text is drawn
  in `zui_fonts`' typefaces through `zui_truetype`: an application that
  names no fonts gets Atkinson Hyperlegible as font 0. A renderer's or
  library's built-in fonts (sokol's 8×8 bitmap fonts, raylib's default
  font) are never a default and are not part of zui.
- **`text/` is a family,** as `renderers/` and `hosts/` are. A new face,
  shaper or rasterizer is a new package beside `truetype/` (`freetype/`,
  `harfbuzz/`), and a platform's system fonts are its host's. None is
  created ahead of the font system's own items.

**What `zui_glyphs` holds today** is what today's renderers need, and
the font system's items design the contract properly and may change all
of it:

- `Codepoints`, a run's codepoints;
- `Fonts`, the type-erased fonts a renderer draws through, with
  `FontMetrics` and `GlyphBox`, made from any text contract that
  provides `fontMetrics`, `advance`, `glyphIndex`, `glyphBox` and
  `rasterize`;
- `Placement` and `placementOf(Renderer)`, the pixel grid or cells;
- `layOut` and `measure`: the pen that lays a run out from each glyph's
  advance and the letter spacing, without kerning, so measurement stays
  additive, into `PositionedGlyph`s (font, glyph id, position), every
  glyph one cell in cell placement;
- `glyphQuads`, the pixel grid's quads, each half a texel wider than its
  glyph's coverage;
- `Atlas`, which takes coverage from any face on first use into memory
  reserved at `init`, packs it in rows, and lays it out in the
  `TexelLayout` the renderer asks for (sokol's and raylib's RGBA, the
  browser's RG8);
- `expectFontsConform`, the font systems' conformance suite.

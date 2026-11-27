# The test card

`zui_test_card` is a small, fixed application every backend draws, built
for the checks that run it: the picture a station broadcasts so every
receiver can be compared against it and its faults show
([docs/plans/test-card.md](../../docs/plans/test-card.md)).

```zig
const App = zui_test_card.App(.{ .Host = zui_raylib.Host, .Renderer = zui_raylib.Renderer, .Text = zui_truetype.Text, .renderer_name = "raylib" });

pub fn main(init: std.process.Init) !void {
    try zui_app.run(App, init, .{ .title = "zui test card (raylib)", .size = zui_test_card.window_size });
}
```

is an application `zui_app.run` runs. The card is 640×384 units, which
is 80×24 cells of 8×16, so a terminal lays out the same card. It sets
its text in `zui_fonts`' Atkinson Hyperlegible, its bold and Liberation
Mono, laid out for the placement the renderer draws, and takes every
color from the tokens `zui_design` resolves from zui's default design,
light and compact, whatever the environment reports. It imports no
renderer, host or font system, and compiles for `wasm32-freestanding`.
`host_name` names the host in the `identity` region; without it, the
host's type name does.

## The card

Each region has an id, `zui_test_card.Region.id`, and exists to make one
check fail:

| Region | Where | Contents |
|---|---|---|
| `identity` | 0,0, 640×32 | the scene, the renderer, the host, the viewport, the placement and the fonts' fingerprint |
| `swatches` | 0,32, 640×64 | each color role of the default design as a labelled tile, and a ramp of 16 greys |
| `text` | 0,96, 320×208 | a line per type role, `Hxgjpqy WMW 0123456789`, and a line cut short by its clip |
| `geometry` | 0,304, 320×80 | borders 1, 2 and 3 wide, corners at radii 0, 4 and 12, a box at a half-unit offset, and hairlines |
| `clip_and_scroll` | 320,96, 320×96 | a scroll box already scrolled, its rows crossing the clip, one with a bar wider than it |
| `layers` | 320,192, 320×96 | the anchor of a tooltip over the page, and the modal dialog the `dialog` scene opens over it |
| `controls` | 320,288, 320×96 | a button, checkbox, slider and text field, each with its value printed beside it |

A swatch's label is its role's code: `o` for `on_`, `c` for
`_container`, so `oacc` is `on_accent_container`:

| Code | Role | Code | Role | Code | Role |
|---|---|---|---|---|---|
| `bg` | background | `ac` | accent | `wnc` | warning_container |
| `sf` | surface | `oac` | on_accent | `ownc` | on_warning_container |
| `sfr` | surface_raised | `acc` | accent_container | `ok` | success |
| `sfs` | surface_sunken | `oacc` | on_accent_container | `ook` | on_success |
| `sfo` | surface_overlay | `sec` | secondary_container | `okc` | success_container |
| `sfi` | surface_inverse | `osec` | on_secondary_container | `ookc` | on_success_container |
| `on` | on_surface | `dg` | danger | `sel` | selection |
| `onm` | on_surface_muted | `odg` | on_danger | `osel` | on_selection |
| `oni` | on_surface_inverse | `dgc` | danger_container | `ol` | outline |
| `ona` | on_surface_accent | `odgc` | on_danger_container | `olm` | outline_muted |
| `wn` | warning | `own` | on_warning | `fo` | focus |
| `scr` | scrim | `sh` | shadow | `rim` | rim |

A **scene** is the card in one state, `zui_test_card.Scene`:

| Scene | What it shows |
|---|---|
| `rest` | the card with nothing hovered, pressed or focused |
| `hovered` | the pointer over the `controls` region's button |
| `pressed` | the primary button down on that button |
| `focused` | Tab pressed from nothing focused: the `layers` region's anchor focused, with its ring and its tooltip above it |
| `dialog` | the modal dialog open over the page, behind its scrim |
| `scrolled` | the scroll box scrolled further |

Each scene is a pure function of its state: drawn after any other scene,
or held, its frame is the same. The card has no clock and no motion: it
replaces the host's measurements and input with its own in `zuiRecord`
(its size, a clock of 60 frames a second, an environment with reduced
motion, and the pointer, the press and the Tab its scene is in), keeping
only lifecycle events, and clears the focus as it leaves a scene.
`zui_test_card.Card` is the card alone, for a driver that begins and
ends its frames itself, as the terminal's `--dump` and the tests do,
through `declareWithoutHost`.

Its flags:

| Flag | What it does |
|---|---|
| `--scene <name>` | hold one scene; without it, the scenes in turn, a frame each, while `--frames` is given, and `rest` otherwise |
| `--frames <count>` | quit after this many frames, printing the frames drawn, the renderer's overflows where it counts them, and whether every frame's diagnostics were clean: `--frames 6` draws every scene once |
| `--hidden` | for the target: keep the window hidden |
| `--screenshot <path>` | for the target: save the window once the scene settles, then quit (raylib) |

Each renderer's or host's `test-card` target names it with its own host,
renderer and font system:

| Target | Run from |
|---|---|
| raylib's window and renderer | [renderers/raylib/](../../renderers/raylib/README.md#development) |
| a native window, drawn by the sokol renderer | [hosts/native/](../../hosts/native/README.md#the-tour-on-a-native-host) |
| the terminal, and its `--dump` without one | [renderers/terminal/](../../renderers/terminal/README.md#development) |

## Snapshots

`apps/test_card/snapshots/` holds each scene's frame as text,
`<scene>.<placement>.txt`: `rest.pixels.txt` drawn on the pixel grid and
`rest.cells.txt` in cells of 8×16, each on a renderer that draws every
optional command and nothing else, in `zui_truetype`'s text. Each is
`zui_testing.writeFrameSnapshot`'s: four lines of what drew it, its
viewport, its placement, the fonts' fingerprint and, on the pixel grid,
the count and hash of the glyphs it rasterizes into an atlas as a
renderer does, so a change of font or of stb changes one line; then one
line per command, every length to 1/64 unit, the card's regions and the
elements its scenes reach named by id:

```text
viewport 640x384, 1 pixels a unit
placement pixel_grid
fonts df582f8282bf04c6
glyphs 131, coverage 94e0b6798b656dbf
rectangle id=card x=0 y=0 w=640 h=384 color=#f5f8fe
clip_begin id=card x=0 y=0 w=640 h=384
rectangle id=identity x=0 y=0 w=640 h=32 color=#24272a
```

The headless test holds every scene from a card of its own and compares
its snapshot with the approved one exactly. A difference fails it with
the first lines that differ, each named by the region whose rectangle
holds its command, and how many differ in all:

```text
zui_testing: the snapshot differs from line 121, in the `geometry` region:
  expected: rectangle id=geometry x=0 y=304 w=320 h=80 color=#f5f8fe
  actual:   rectangle id=geometry x=0 y=305 w=320 h=80 color=#f5f8fe
...
18 of its lines differ
in snapshots/rest.pixels.txt; `zig build approve` writes every snapshot again
```

When a change to the card, to layout or to the fonts is meant,
`zig build approve` writes every snapshot again as the tests now draw
them, and `git diff snapshots/` shows what changed for review. A new
scene fails to compile the tests until it has been approved.

## Development

Run from `apps/test_card/`; the first build fetches stb, since the tests
measure with `zui_truetype`:

| Command | What it does |
|---|---|
| `zig build test` | declare every scene headlessly, in turn and held, on renderers that draw every optional command and none, in pixels and in cells: each region where the card puts it with its content inside it, each scene's hover, press, focus, dialog and scroll, a scene drawn after another the same as the scene held, clean diagnostics, and the text and focus ring meeting their contrast targets with `zui_design.audit`; compare every scene's snapshot with its approved one in `snapshots/`; run the card through `zui_app`, ignoring the host's input; and check the card's compile errors |
| `zig build check` | compile the tests, natively and for `wasm32-freestanding`, and the program `approve` runs |
| `zig build approve` | write every scene's snapshot, in pixels and in cells, into `snapshots/` |

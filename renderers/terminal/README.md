# The terminal renderer

`zui_terminal` decodes keys, mouse reports and focus reports into the
events of zui's frame records, measures text in cells through zui's text
contract, and paints zui's frames as 24-bit-color cells, as a renderer;
`zui_terminal.Host` is a host on the terminal the process runs in, so
`zui_app` runs an application there.
It declares cell placement (`Renderer.glyph_placement`), so its `Text`,
or any font system laid out for it, measures every glyph one cell wide,
as it is drawn.
It needs no library besides zui, and a terminal with VT sequences, 24-bit
color and SGR mouse reports: Windows Terminal, the Windows 10+ console,
or any xterm-compatible terminal on Linux and macOS.

```zig
// build.zig, with `zui` the dependency from the main README
const zui_terminal = zui.builder.dependency("zui_terminal", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui_terminal", zui_terminal.module("zui_terminal"));
```

```zig
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_terminal = @import("zui_terminal");
const Ui = zui.Context(zui_terminal.config(.{}));

const App = struct {
    pub const Host = zui_terminal.Host;
    pub const Renderer = zui_terminal.Renderer;
    pub const Text = zui_terminal.Text;

    pub fn zuiDeclare(app: *App, ui: *Ui) void {
        // ... declare your UI ...
    }
};

pub fn main(init: std.process.Init) !void {
    try zui_app.run(App, init, .{}); // until Ctrl+C or Ctrl+Q
}
```

The host enters raw mode on the alternate screen, decodes what the
terminal sends into each record, and hands the renderer, in each
`.terminal` surface, the size in cells and its writer on stdout. The
renderer keeps the screen, which `init` sizes to the first surface. A
line written to stdout or stderr meanwhile stays among the
cells until they change, so its targets pass `zui_app` a `notify` that
leaves out the `.started` report. The same parts make a loop of your own:

```zig
var terminal = try zui_terminal.Terminal.enter(io);
defer terminal.leave();
var text: zui_terminal.Text = .{};
var ui = try Ui.init(gpa, io, &text);
var renderer: zui_terminal.Renderer = .{ .gpa = gpa, .background = background };
defer renderer.deinit();
var decoder: zui_terminal.InputDecoder = .{};

while (!decoder.quit_requested) {
    const surface = terminal.surface(stdout); // .terminal: the size in cells and the writer
    ui.beginFrame(&.{ .params = .{ .now = terminal.now(), .viewport = viewportFor(surface) }, .events = decoder.take() });
    // ... declare your UI ...
    const frame = ui.endFrame();
    try renderer.zuiSubmit(surface, frame); // paints the cells and writes what changed
    ui.release(frame);
    terminal.wait(ui.nextFrame());
    decoder.feed(terminal.readAvailable(&read_buffer), terminal.now());
}
```

`zui_terminal.config(...)` builds the `Config` from `Renderer`'s
declarations: it declares no optional commands and no payload types, so
its `switch` over the commands names only the five base commands. To
paint into a `CellBuffer` of your own, call `zui_terminal.render` instead.

`terminal.wait`, and the host's `zuiWait`, sleep as `nextFrame` says: not at all, until a
requested instant, or until input, a resize or a wake, so an idle UI uses
no CPU. `terminal.waker()`, and the host's `zuiWaker`, is a `zui.Waker` for sources' producers: on
Windows it writes a console input record, elsewhere it writes to a pipe,
and either way a wake that arrives before the wait still ends it. On
Linux and macOS a resize does not wake `poll`, so an idle wait looks at
the size every 250 ms and runs a frame only when it changed.

Layout stays in pixel-like units: a cell is `Text.cell_size` units (8×16
by default), so a UI written for a pixel renderer still lays out
sensibly. A cell is painted when its center lies inside a command's
bounds.

| zui | terminal |
|---|---|
| `rectangle` | cell backgrounds; translucent colors blend over what is below |
| `border` | box drawing (`┌─┐`, or `╭─╮` with a corner radius); `[` `]` on a one-row box |
| `text` | one glyph per code point, one line per command, in the cell where `zui_glyphs`' cell placement puts it; letter spacing moves each glyph to the nearest cell |
| `clip_begin` / `clip_end` | a stack of cell rectangles |
| pointer | SGR mouse reports as `pointer_move`, `pointer_down` and `pointer_up`, in the order they arrived |
| wheel | SGR wheel reports, `InputDecoder.wheel_step` units per notch |
| keys | navigation, function and editing keys; letters and digits also as keys, so Ctrl+S and Alt+S are chords |
| focus | focus reports (`CSI I` / `CSI O`) as the environment's `window_focused` |

What a terminal cannot do:
- **One font, one size.** `Text.zuiMeasure` ignores both: every code
  point is one cell, plus the letter spacing after it, and an invalid
  byte one cell of U+FFFD. Wide characters
  (CJK, most emoji) take two cells on screen but are measured as one.
- **Borders never overwrite glyphs.** zui draws borders after their
  children, so a border cell that already holds text keeps it.
- **No cursor shapes or IME window.** The frame's host requests are not
  applied.

Its targets name the terminal's host and
renderer and `zui_truetype.Text`, laid out one glyph per cell: `zig build
tour` runs the whole [tour](../../apps/tour/README.md), less the screens whose commands a terminal
does not draw (Transforms and Materials), which `zui_tour` leaves out as
it does on any renderer, and `zig build showcase` the showcase, its
controls on whole cells. `--dump` draws either into cells without a
terminal and prints the glyphs: the tour's a screen at 180×56 cells
(`--screen <name>`), or every screen it is offered (`--every-screen`),
failing when one cuts text short, the showcase's three frames at 100×30 with the
pointer on "Hover me". `--frames <count>` ends a run after that many
frames, through `Host.close`.

## Development

Run from `renderers/terminal/`; the targets fetch stb for
`zui_truetype`, whose fonts they lay out one glyph per cell:

| Command | What it does |
|---|---|
| `zig build test` | run its unit tests and zui's renderer suite against it |
| `zig build conformance` | run zui's renderer suite alone |
| `zig build check` | compile the renderer and the targets without producing output |
| `zig build tour` | run the tour in this terminal, every screen whose commands a terminal draws; Ctrl+C or Ctrl+Q quits, and `-- --frames <count>` quits after that many frames |
| `zig build tour -- --dump --screen typography` | render a screen offscreen at 180×56 and print its glyphs |
| `zig build tour -- --dump --every-screen` | print every screen a terminal is offered the same way, failing when one cuts a line of text short at the side of its clip (a line in an element that scrolls sideways is scrolled, not cut short) |
| `zig build showcase` | run the showcase in this terminal |
| `zig build showcase -- --dump` | render the showcase offscreen at 100×30 and print its glyphs |

Without `--dump`, the targets take over the terminal they run in.

AaronJClausen/zui · **main** @ 075fbbd · Zig 0.16

# zui Feature Tour

Everything a zui consumer can build with today, one feature at a time, each shown in the code you would write. The examples follow one running application: **Darkroom**, a photo library with albums, a thumbnail grid, a viewer and a settings panel.

- **7** modules beside core
- **3** renderers + 1 native host
- **0** allocations after init
- 4,096 boxes: ~57 µs declare, ~109 µs layout, at 3.7 GHz

> **How to read the snippets.** Every zui name and signature is checked against the source at this commit. Application names (`App`, `Photo`, `Fonts`, `decodeThumbnail` and so on) are made up for the example, and the snippets were not compiled as a whole program.

<a id="core"></a>

## 01. Declaring UI

The core: a context sized at compile time, elements declared as nested calls each frame, layout, text, and a flat list of render commands out.

<a id="context"></a>

### Configuring a context · *shipped*

A `zui.Context` is a type built from a `Config`. Everything that varies between applications goes in the `Config`: the text contract, the payload types the renderer understands, the sources, and every limit. All memory is reserved in `init`, and nothing allocates after it.

Payload types that stay `void` remove their API. If `ImageHandle` is `void`, then `ui.image` doesn't exist and the render command union has no `image` variant. `initBuffer` runs the same context in memory you provide, with no allocator.

- `zui.Context(config)`
- `Config.limits`
- `Ui.init`
- `Ui.initBuffer`
- `frames_in_flight`

`src/main.zig`

```zig
const std = @import("std");
const zui = @import("zui");
const Fonts = @import("fonts.zig").Fonts;
const Texture = @import("gpu.zig").Texture;
const AppSources = @import("sources.zig").AppSources;

pub const Ui = zui.Context(.{
    .Text = Fonts,
    .Sources = AppSources,
    .ImageHandle = Texture,
    .FontId = Fonts.Face,
    .limits = .{
        .max_elements = 8192,
        .max_render_commands = 16384,
        .max_text_bytes = 128 * 1024,
        .state_slots = 2048,
    },
    .frames_in_flight = 2,
});

pub fn main(init: std.process.Init) !void {
    var fonts: Fonts = try .load(init.gpa, init.io, "assets/fonts");
    defer fonts.deinit(init.gpa);

    var ui: Ui = try .init(init.gpa, init.io, &fonts);
    defer ui.deinit(init.gpa);

    try runLoop(&ui);
}
```

Limits are validated at compile time. For example, `state_slots` must be a power of two, and the message says so (see [compile errors](#compile-errors)).

<a id="elements"></a>

### Elements, layout and decoration · *shipped*

Each frame you declare a tree. `open` and `close` bracket a container, `box` is a leaf, and `text` is a leaf with content. An element is a struct literal: `layout` sets direction, sizing, padding, gap and alignment, and `decoration` sets background, border and corner radius. A border's `between_children` draws a divider between each two children, centered in the gap, over the children and under the border; with no `widths` it draws the dividers alone. Because `defer ui.close()` keeps the tree balanced, a helper function reads like markup.

`src/ui/shell.zig`

```zig
const zui = @import("zui");
const Ui = @import("../main.zig").Ui;
const App = @import("../app.zig").App;

pub fn declareShell(app: *App, ui: *Ui) void {
    ui.open(.{
        .id = .of("window"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both },
        .decoration = .{ .background = .rgb(0x15161b) },
    });
    defer ui.close();

    toolbar(app, ui);

    ui.open(.{ .layout = .{ .sizing = .grow_both } });
    defer ui.close();
    albumSidebar(app, ui);
    photoGrid(app, ui);
}

fn toolbar(app: *App, ui: *Ui) void {
    ui.open(.{
        .id = .of("toolbar"),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .width = .grow, .height = .fixed(44) },
            .padding = .symmetric(12, 6),
            .child_gap = 8,
            .child_alignment = .{ .y = .center },
        },
        .decoration = .{
            .background = .rgb(0x202028),
            .border = .{ .color = .rgb(0x2c2c38), .widths = .{ .bottom = 1 } },
        },
    });
    defer ui.close();

    ui.text("Darkroom", .{ .size = 15, .color = .white });
    ui.text(app.currentAlbum().name, .{ .size = 13, .color = .rgb(0x9a9aae) });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
    importButton(app, ui);
}

fn settingsList(app: *App, ui: *Ui) void {
    ui.open(.{
        .id = .of("settings"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 9 },
        .decoration = .{ .border = .{ .color = .rgb(0x2c2c38), .between_children = 1 } },
    });
    defer ui.close();
    for (app.settings.items) |setting| settingRow(ui, setting);
}
```

Elements without an `id` get an internal one. Give an element an id when you want to query it, keep state on it, scroll it, or focus it.

<a id="sizing"></a>

### Sizing rules · *shipped*

Each axis takes one `Sizing` rule, with optional `min` and `max`. The grow basis landed in `06-text-and-layout:07-grow-basis`: `grow` starts from the content and adds a share of the free space, and `grow_equal` shares the whole width, so columns come out equal whatever they hold.

| Rule | Behaves like | Use it for |
|---|---|---|
| `.fit` | shrink-wrap | buttons, labels, the default |
| `.fixed(44)` | a fixed length | toolbars, icons, thumbnails |
| `.percent(0.3)` | a share of the parent | split panes |
| `.grow` | CSS `flex: auto` | spacers, a content area |
| `.grow_equal` | CSS `flex: 1` | equal columns |
| `.growWeighted(3)` | `flex-grow: 3` | uneven splits |
| `.fitBetween(180, 320)` | fit, clamped | a sidebar that respects its content |
| `.aspectRatio(16.0 / 9.0)` | CSS `aspect-ratio`, on the height | a video frame at whatever width it gets |

`src/ui/library.zig`

```zig
fn albumSidebar(app: *App, ui: *Ui) void {
    ui.open(.{
        .id = .of("albums"),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .width = .fitBetween(180, 320), .height = .grow },
            .padding = .all(8),
            .child_gap = 2,
        },
    });
    defer ui.close();
    for (app.albums.items, 0..) |album, index| albumRow(app, ui, album, index);
}

fn photoInfoColumns(ui: *Ui, photo: *const Photo) void {
    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 16 } });
    defer ui.close();

    const columns = [_][]const u8{ photo.camera, photo.lens, photo.exposure };
    for (columns, 0..) |value, column| {
        ui.open(.{ .id = .indexed("info_column", column), .layout = .{ .sizing = .{ .width = .grow_equal } } });
        ui.text(value, .{ .size = 13 });
        ui.close();
    }
}
```

<a id="right-to-left"></a>

### Right-to-left layout · *shipped*

When the host reports a right-to-left language, the whole layout mirrors: rows flow from the right, `.start` alignment is the right edge, a padding's `left` is its start side and lands on the right, floating anchors and offsets flip, text lines align to the right, and a horizontal scroller starts at its right edge. You write the layout once, in logical terms. `.mirrored = .yes` or `.no` sets a subtree either way whatever its parent, and `direction = .right_to_left` reverses one row alone, as CSS `row-reverse` does. Positions in the frame are physical, so hit testing and `rectOf` need nothing. Borders stay physical too.

`src/ui/compose.zig`

```zig
fn composeHeader(app: *App, ui: *Ui) void {
    ui.open(.{ .layout = .{
        .sizing = .{ .width = .grow, .height = .fixed(40) },
        .padding = .{ .left = 12, .right = 4 },
        .child_gap = 8,
        .child_alignment = .{ .y = .center },
    } });
    defer ui.close();
    ui.text(app.strings.to, .{ .size = 13 });

    ui.open(.{ .layout = .{ .mirrored = .no } });
    ui.text(app.draft.recipient_phone, .{ .size = 13 });
    ui.close();

    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
    sendButton(app, ui);
}
```

In Arabic or Hebrew the label sits on the right, 12 units in, the send button on the left, and the phone number still reads left to right.

<a id="wrap"></a>

### Wrapping rows · *shipped*

With `.features = .{ .flex_wrap = true }`, calling `ui.wrapChildren()` right after a row's `open` moves each child that would overflow the row onto a new line, as CSS `flex-wrap` does. Each line grows and shrinks its own children, so a `.grow` chip fills the rest of its line, and a child wider than the row gets a line to itself and shrinks to fit. A line is as tall as its tallest child, lines are `child_gap` apart, and `child_alignment.y` places the lines as a group and each child within its line. The row's fit width is one line, but it narrows to its widest child, and its height follows its lines, so it scrolls like any other content. Dividers go between the children of a line and between lines. Breakpoints need nothing more: branch on `ui.viewport()` or `rectOf` in your own code. Without the feature, `wrapChildren` fails to compile, and none of this is in your binary.

`src/ui/tags.zig`

```zig
fn tagBar(app: *App, ui: *Ui) void {
    ui.open(.{ .layout = .{
        .sizing = .{ .width = .grow },
        .padding = .all(8),
        .child_gap = 6,
    } });
    defer ui.close();
    ui.wrapChildren();
    for (app.tags, 0..) |tag, index| tagChip(ui, .indexed("tag", @intCast(index)), tag);
}
```

In a wide window the tags sit on one line; narrow it and they flow onto as many lines as they need, each line starting at the left edge (the right, in Arabic).

<a id="static-styles"></a>

### Static styles · *shipped*

`zui.static` builds a `Style` at comptime and stores it in read-only memory. Elements reference it instead of copying it, so it costs one pointer per element. A `layout` or `decoration` set beside `style` replaces the style's. This is what brought 4,096 styled boxes down to about 28 µs to declare.

`src/ui/styles.zig`

```zig
const zui = @import("zui");

pub const card = zui.static(zui.Style{
    .layout = .{ .direction = .top_to_bottom, .padding = .all(10), .child_gap = 6 },
    .decoration = .{ .background = .rgb(0x23232d), .corner_radius = .all(8) },
});

pub const selected_card = zui.static(zui.Style{
    .layout = .{ .direction = .top_to_bottom, .padding = .all(10), .child_gap = 6 },
    .decoration = .{
        .background = .rgb(0x2b3350),
        .border = .{ .color = .rgb(0x5b8cff), .widths = .all(2) },
        .corner_radius = .all(8),
    },
});

fn photoCard(app: *App, ui: *Ui, photo: *const Photo, index: usize) void {
    const id: zui.Id = .indexed("photo", index);
    ui.open(.{
        .id = id,
        .interactive = true,
        .style = if (app.selection.contains(index)) selected_card else card,
    });
    defer ui.close();
    thumbnail(app, ui, photo);
    ui.text(photo.file_name, .{ .size = 12, .wrap = .none });
}
```

<a id="effects"></a>

### Gradients, shadows, glow and backdrop blur · *shipped*

`effects` points at a `zui.Effects`: a linear `gradient`, interpolated in OKLab, and a `shadow`, which with no offset is a glow. They take the shape of the element's decoration and its corner radius, and paint from the bottom up as shadow, background, gradient, then the element's content. A `backdrop_blur` is frosted glass: it blurs what zui drew beneath the element, within its rounded box, and lays its `tint` over it, painted between the shadow and the background. A renderer that does not declare `.backdrop_blur` draws the tint alone, so pick a tint that reads well unblurred. The sokol renderer blurs it; the raylib and terminal renderers draw the tint. The effects are copied when the element is declared, so a pointer to a local works, and an element without effects pays nothing for them, nor does a frame without any. Up to `limits.max_effects` elements a frame keep their effects, 256 by default; past it, an element is drawn without them and the diagnostics name the limit. A renderer that declares `.gradient` and `.shadow` in `zui_commands` gets those commands. For any other renderer, a gradient is lowered to a rectangle in its middle color and a shadow to nothing, and `frame.diagnostics.lowered` names what was lowered. The sokol renderer draws both and the backdrop blur, and its tour shows them on its Light & Depth screen; the raylib and terminal renderers draw the lowered forms.

`src/ui/viewer.zig`

```zig
const std = @import("std");
const zui = @import("zui");

const raised: zui.Effects = .{ .shadow = .{ .color = .rgba(0x00000060), .offset = .{ 0, 4 }, .blur = 12 } };

fn exposureBar(ui: *Ui, selected: bool) void {
    const highlight: zui.Effects = .{
        .gradient = .{ .from = .rgb(0x1c1c24), .to = .rgb(0xffaf7b), .angle = std.math.pi / 2.0 },
        .shadow = if (selected) .glow(.rgba(0x5b8cff80), 8) else null,
    };
    ui.box(.{
        .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(24) } },
        .decoration = .{ .corner_radius = .all(6) },
        .effects = &highlight,
    });
}

const frosted: zui.Effects = .{ .backdrop_blur = .{ .radius = 12, .tint = .rgba(0x1c1c24c0) } };

fn filmstripOverlay(ui: *Ui) void {
    ui.open(.{
        .floating = .{ .attach_point = .bottom_left, .anchor = .bottom_left },
        .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(72) } },
        .decoration = .{ .corner_radius = .all(8) },
        .effects = &frosted,
    });
    defer ui.close();
}

fn photoCard(ui: *Ui, photo: *const Photo) void {
    ui.open(.{ .style = styles.card, .effects = &raised });
    defer ui.close();
    ui.text(photo.file_name, .{ .size = 12, .wrap = .none });
}
```

<a id="transforms"></a>

### Transforms · *shipped*

`effects` can also hold a `transform`: a translation, a scale and a rotation about an `origin` inside the element's box, applied to the element, its other effects and everything inside it as they are painted. Layout ignores it, so `rectOf` is still the box the element was laid out in and its neighbours stay put, which suits animation: a dialog that grows in, a card that tilts while dragged. A pointer hits a transformed element where it is drawn, through nested transforms and the clips around them. A renderer that declares `.transform` gets `transform_begin` and `transform_end` around the element's commands, and `affine(bounds)` maps its units to its parent's; for any other, the element is drawn and hit as laid out, and `frame.diagnostics.lowered` names `.transform`. The sokol renderer draws transforms, on its tour's Transforms screen; the raylib and terminal renderers draw the element as laid out.

`src/ui/import.zig`

```zig
const std = @import("std");
const zui = @import("zui");

fn importDialog(app: *App, ui: *Ui) void {
    const appearing = app.dialog_shown.progress(app.now);
    const grow_in: zui.Effects = .{ .transform = .{ .scale = @splat(0.92 + 0.08 * appearing), .origin = .{ 0.5, 0 } } };
    ui.open(.{ .id = ids.import, .floating = .{ .attach_to = .root, .attach_point = .center, .anchor = .center }, .style = styles.dialog, .effects = &grow_in });
    defer ui.close();
    ui.text("Import photos", .{ .size = 16 });
}

fn draggedCard(ui: *Ui, photo: *const Photo, drag: zui.Drag) void {
    const tilted: zui.Effects = .{ .transform = .{ .rotation = std.math.clamp(drag.translation[0] / 400, -0.1, 0.1) } };
    ui.open(.{ .style = styles.card, .effects = &tilted });
    defer ui.close();
    ui.text(photo.file_name, .{ .size = 12, .wrap = .none });
}
```

<a id="materials"></a>

### Materials · *shipped*

A renderer with shaders of its own names them in `MaterialHandle`, an enum or an id, and the context's decoration gains a `material`: drawn over the element's box, in its corners, in place of its `background`. The background is the material's fallback, so a renderer that does not declare `.material` draws the background instead and `frame.diagnostics.lowered` names `.material`. A material sits under the gradient and over the shadow and backdrop blur, and a static style can carry one. Without a `MaterialHandle` the field is `void` and `Ui.Element`, `Ui.Decoration` and `Ui.Style` are `zui.Element`, `zui.Decoration` and `zui.Style`; with one they are the context's own, so a helper that returns an element names `Ui.Element`. The sokol renderer draws its own, `zui_sokol.Material`: a pattern between two colors (`solid`, `sheen`, `aurora`) drawn by its shader and moved by a phase the application turns, on its tour's Materials screen. the raylib and terminal renderers draw the fallback.

`src/ui/panels.zig`

```zig
const Ui = zui.Context(zui_app.contextConfig(Renderer, .{}));

const sidebar_style = zui.static(Ui.Style{
    .layout = .{ .sizing = .{ .width = .fixed(240), .height = .grow }, .direction = .top_to_bottom },
    .decoration = .{ .background = .rgb(0x1c1c24), .material = .brushed_metal },
});

fn histogramPanel(ui: *Ui, photo: *const Photo) void {
    ui.open(panelFor(.of("histogram")));
    defer ui.close();
    ui.text(photo.file_name, .{ .size = 12, .wrap = .none });
}

fn panelFor(id: zui.Id) Ui.Element {
    return .{ .id = id, .decoration = .{ .background = .rgba(0x1c1c24e0), .material = .frosted_glass, .corner_radius = .all(8) } };
}
```

<a id="extended-color"></a>

### HDR and wide-gamut color · *shipped*

`Config.Color = zui.ExtendedColor` declares colors in linear scRGB, where 1.0 is SDR white: above it for HDR, outside 0 to 1 for wide gamut, written `.linear(4, 4, 4, 1)` or with `Color`'s own `.rgb(0x3366ff)`. Every type that holds a color follows it: `Ui.Decoration`, `Ui.Border`, `Ui.Effects`, `Ui.TextStyle`. For a renderer that draws only `zui.Color`, each is clamped as it is emitted, and `frame.diagnostics.clamped_colors` says when that changed one; `zui_wire` carries them unclamped when its context's renderer draws them. A host and a renderer that both declare `.scrgb_fp16` in `zui_output_formats` open the window with it in `WindowOptions.output_formats`, and the host picks it while its display shows HDR; `surface.outputFormat()` says which it chose. the native Windows host picks it on a monitor in HDR and reports `ui.environment().hdr_headroom`, the monitor's peak over SDR white (1 in SDR), so a theme can tell how bright a highlight may go. The sokol renderer draws that window into a half-float scRGB swapchain, with SDR white where other windows show theirs, and the native hosts'`zig build hdr` shows two and four times SDR white beside it, measured off the desktop at 2.00× and 4.00×. The renderer suite reads an FP16 target back and expects HDR white there at four times SDR white.

`src/ui/exposure.zig`

```zig
const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .Color = zui.ExtendedColor }));

const caption: zui.ExtendedColor = .rgb(0xe0e0e0);

fn highlightSwatch(ui: *Ui, photo: *const Photo) void {
    const brightest = @min(ui.environment().hdr_headroom, photo.peak_over_white);
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_gap = 6 } });
    defer ui.close();
    ui.box(.{
        .id = .of("highlight"),
        .layout = .{ .sizing = .{ .width = .fixed(96), .height = .fixed(96) } },
        .decoration = .{ .background = .linear(brightest, brightest, brightest, 1), .corner_radius = .all(6) },
    });
    ui.text("Highlights", .{ .size = 12, .color = caption });
}
```

<a id="ids"></a>

### Ids · *shipped*

Ids are hashes, built at comptime where they can be. `.of` names one element, `.indexed` names one per list item, `child` and `indexedChild` scope ids under a parent so two dropdowns' options never collide, and `.dynamic` hashes a runtime string. `zui.ids` builds a struct of ids and fails to compile on a repeated name or a hash collision. Build with `-Dzui-debug=true` and duplicate-id panics name the element.

`src/ui/ids.zig`

```zig
pub const ids = zui.ids(.{ "window", "toolbar", "albums", "grid", "viewer", "import" });

fn albumRow(app: *App, ui: *Ui, album: Album, index: usize) void {
    const row: zui.Id = .indexed("album", index);
    ui.open(.{ .id = row, .interactive = true, .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 6 } });
    defer ui.close();
    ui.text(album.name, .{});
    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
    ui.box(.{ .id = row.child("pin"), .interactive = true, .layout = .{ .sizing = .{ .width = .fixed(16), .height = .fixed(16) } } });

    if (ui.clicked(row.child("pin"))) app.togglePinned(index);
    if (ui.clicked(row)) app.openAlbum(index);
}

fn tagChip(ui: *Ui, tag: []const u8) void {
    ui.open(.{ .id = .dynamic(tag), .interactive = true });
    ui.text(tag, .{ .size = 12 });
    ui.close();
}
```

<a id="text"></a>

### Text · *shipped*

`ui.text` copies its bytes into the frame, so the caller's buffer can be reused immediately. A `TextStyle` carries font, size, letter spacing, line height, color, wrap mode and alignment. Measurements go through two caches, one per segment and one per whole string, so warm text costs one lookup. Text that fits on one line is laid out without walking its words. With a thread-safe text contract, a cold frame with many misses measures them in parallel, which is 4.3× as fast on 10 cores.

- `ui.text`
- `Ui.TextStyle`
- `TextWrap`
- `ui.measureText`
- `ui.measureCalls`

`src/ui/viewer.zig`

```zig
const caption_style: Ui.TextStyle = .{ .font = .serif, .size = 15, .line_height = 22, .color = .rgb(0xdcdce4) };
const label_style: Ui.TextStyle = .{ .font = .sans, .size = 11, .letter_spacing = 1.2, .color = .rgb(0x8a8a9c) };

fn photoDetails(ui: *Ui, photo: *const Photo) void {
    ui.open(.{
        .id = .of("details"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(320) }, .padding = .all(16), .child_gap = 8 },
    });
    defer ui.close();

    ui.text("CAPTION", label_style);
    ui.text(photo.caption, caption_style);

    ui.text("FILE", label_style);
    ui.text(photo.path, .{ .size = 12, .wrap = .none, .color = .rgb(0x9a9aae) });

    var buffer: [64]u8 = undefined;
    const dimensions = std.fmt.bufPrint(&buffer, "{d} × {d}", .{ photo.width, photo.height }) catch "";
    ui.text(dimensions, .{ .size = 12, .alignment = .end });
}

fn truncatedWidth(ui: *Ui, name: []const u8) f32 {
    return ui.measureText(name, .{ .size = 12 })[0];
}
```

In a test, `ui.measureCalls()` confirms that a steady-state frame never reaches the text contract.

<a id="text-contract"></a>

### The text contract you implement · *shipped*

zui's core never touches fonts. You give it a type with `zuiMeasure`, and optionally `zui_thread_safe` to allow parallel measurement and `zuiSegment` to report where a paragraph may break. Without `zuiSegment`, text breaks after spaces. With it, CJK and Thai wrap between characters. A misspelled declaration such as `zui_threadsafe` is a compile error rather than silently ignored.

`src/fonts.zig`

```zig
const std = @import("std");
const zui = @import("zui");

pub const Fonts = struct {
    pub const Face = enum(u8) { sans, serif, mono };
    pub const zui_thread_safe = true;

    faces: std.EnumArray(Face, Atlas),
    breaker: LineBreaker,

    pub fn zuiMeasure(self: *Fonts, text: []const u8, key: zui.MeasureKey(Face)) [2]f32 {
        const atlas = self.faces.getPtr(key.font);
        const advance = atlas.advance(text, key.size) + key.letter_spacing * @as(f32, @floatFromInt(text.len));
        return .{ advance, atlas.lineHeight(key.size) };
    }

    pub fn zuiSegment(self: *Fonts, paragraph: []const u8, sink: *zui.BreakSink) void {
        var opportunities = self.breaker.iterate(paragraph);
        while (opportunities.next()) |offset| sink.add(offset);
    }
};
```

<a id="fonts"></a>

### Fonts out of the box · *shipped*

`zui_truetype.Text` is a text contract you do not write: TrueType fonts on stb_truetype, laid out through `zui_glyphs`, whose one layout both measures a run and tells every renderer where to draw each glyph, so text is drawn where it was measured. Given no fonts it draws in Atkinson Hyperlegible Regular as font 0; `zui_fonts` bundles that, its bold and Liberation Mono, and only the ones you reference are embedded. Each renderer declares how it places glyphs, on the pixel grid or one per terminal cell, and the text lays out for it; a renderer has no fonts of its own, so the same typefaces draw on raylib, sokol, the browser and the terminal, and text in a font the text lacks is not drawn. Its fingerprint covers its fonts and placement, so a remote renderer with other fonts refuses your stream. Reach it through the `zui` dependency: `zui.builder.dependency("zui_truetype", .{})`.

`src/typefaces.zig`

```zig
const std = @import("std");
const zui = @import("zui");
const zui_glyphs = @import("zui_glyphs");
const zui_truetype = @import("zui_truetype");
const zui_fonts = @import("zui_fonts");
const zui_raylib = @import("zui_raylib");

pub const Ui = zui.Context(.{ .Text = zui_truetype.Text });

pub const Typefaces = struct {
    body: u16,
    code: u16,

    /// Before the first frame: measuring may run on other threads.
    pub fn add(text: *zui_truetype.Text) !Typefaces {
        text.placement = zui_glyphs.placementOf(zui_raylib.Renderer);
        return .{
            .body = try text.addFont(zui_fonts.atkinson_hyperlegible_regular),
            .code = try text.addFont(zui_fonts.liberation_mono_regular),
        };
    }
};

fn snippet(ui: *Ui, typefaces: Typefaces) void {
    ui.text("Measured and drawn by one layout:", .{ .font = typefaces.body, .size = 16 });
    ui.text("const x = 1;", .{ .font = typefaces.code, .size = 14 });
}
```

<a id="images"></a>

### Images and self-drawn elements · *shipped*

`ui.image` places the renderer's own image handle. `ui.custom` places a payload your renderer draws itself, such as a 3D viewport or a histogram. Both are leaves that take an `Element`, so they size, clip and hit-test like any box. Give an image its `natural_size` and a `fit` image takes it, keeping its proportions when its width grows or is squeezed. Its `tint` is multiplied into its pixels and its `corner_radius` rounds each corner; both reach the renderer in the `image` command, and the raylib and sokol renderers draw them.

`src/ui/viewer.zig`

```zig
const HistogramPayload = struct { photo_id: u64, channel: Channel };

pub const Ui = zui.Context(.{ .Text = Fonts, .ImageHandle = Texture, .CustomData = HistogramPayload });

fn viewer(app: *App, ui: *Ui, photo: *const Photo, texture: Texture) void {
    ui.open(.{ .id = .of("viewer"), .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_alignment = .{ .x = .center } } });
    defer ui.close();

    ui.image(.{
        .handle = texture,
        .natural_size = .{ photo.width, photo.height },
        .tint = if (photo.rejected) .rgba(0xffffff66) else .white,
        .corner_radius = .all(6),
    }, .{
        .id = .of("full_image"),
        .layout = .{ .sizing = .{ .width = .grow } },
    });
    ui.custom(.{ .photo_id = photo.id, .channel = app.histogram_channel }, .{
        .id = .of("histogram"),
        .layout = .{ .sizing = .{ .width = .fixed(256), .height = .fixed(80) } },
    });
}
```

<a id="input"></a>

## 02. Input, interaction and state

Pointer, keyboard, focus, scrolling, floating layers and per-element memory, all queried by id during declaration.

<a id="interaction"></a>

### Hover, press, click, disabled and cursor · *shipped*

An element with `interactive` or `focusable` is hit-tested. Querying by id answers for the frame being declared: `clicked`, `hovered`, `pressed`, `focused`, and `widgetState`, which folds them into one enum for styling. A disabled element still blocks what is beneath it but is never pressed, clicked or focused. `cursor` picks the pointer shape while the element is hot.

Without the widgets module, this is the whole recipe for a button:

`src/ui/controls.zig`

```zig
const tool_colors = std.EnumArray(zui.WidgetState, zui.Color).init(.{
    .idle = .rgb(0x2c2c3c),
    .hovered = .rgb(0x3a3a50),
    .pressed = .rgb(0x4a6ad0),
    .focused = .rgb(0x2c2c3c),
    .disabled = .rgb(0x24242e),
});

fn toolButton(ui: *Ui, id: zui.Id, label: []const u8, enabled: bool) bool {
    const state = ui.widgetState(id);
    ui.open(.{
        .id = id,
        .focusable = true,
        .disabled = !enabled,
        .cursor = if (enabled) .pointer else .not_allowed,
        .layout = .{ .padding = .symmetric(12, 6), .child_alignment = .{ .y = .center } },
        .decoration = .{
            .background = tool_colors.get(state),
            .border = if (ui.focused(id)) .{ .color = .rgb(0xffc65c), .widths = .all(2) } else null,
            .corner_radius = .all(5),
        },
    });
    ui.text(label, .{ .size = 13, .color = if (enabled) .white else .rgb(0x5c5c6e) });
    ui.close();
    return ui.clicked(id);
}

fn importButton(app: *App, ui: *Ui) void {
    if (toolButton(ui, .of("import"), "Import…", !app.importing)) app.startImport();
}
```

There's no built-in keyboard activation here. [zui_widgets](#widgets) adds Enter and Space activation on top of this.

<a id="focus"></a>

### Focus, tab order and focus scopes · *shipped*

`focusable` puts an element in the tab order, which follows declaration order. `focus_scope` keeps Tab cycling inside a subtree, as a dialog needs. `requestFocus` moves focus programmatically.

`src/ui/rename_dialog.zig`

```zig
fn renameDialog(app: *App, ui: *Ui) void {
    if (!app.rename.open) return;
    const dialog = ui.state(.of("rename_dialog"), struct { focused_once: bool });
    if (!dialog.focused_once) {
        ui.requestFocus(.of("rename_field"));
        dialog.focused_once = true;
    }

    ui.open(.{
        .id = .of("rename_dialog"),
        .focus_scope = true,
        .floating = .{ .attach_to = .root, .anchor = .center, .attach_point = .center, .z = 200 },
        .layout = .{ .direction = .top_to_bottom, .padding = .all(16), .child_gap = 10, .sizing = .{ .width = .fixed(360) } },
        .decoration = .{ .background = .rgb(0x262634), .corner_radius = .all(10) },
    });
    defer ui.close();

    ui.text("Rename photo", .{ .size = 15 });
    _ = widgets.textField(ui, .of("rename_field"), &app.rename.text, .{});
    if (toolButton(ui, .of("rename_ok"), "Rename", app.rename.text.slice().len > 0)) app.commitRename();
    if (toolButton(ui, .of("rename_cancel"), "Cancel", true) or ui.keyPressed(.escape)) app.rename.open = false;
}
```

<a id="keyboard"></a>

### Keyboard and typed text · *shipped*

Input arrives as an ordered event log in each frame record. You can ask about a key, about a chord (a key with exactly those modifiers), for the raw key events with repeat flags and scancodes, or for the committed UTF-8 typed this frame.

`src/ui/shortcuts.zig`

```zig
fn shortcuts(app: *App, ui: *Ui) void {
    if (ui.chordPressed(.{ .key = .i, .modifiers = .{ .control = true } })) app.startImport();
    if (ui.chordPressed(.{ .key = .a, .modifiers = .{ .control = true } })) app.selection.selectAll();
    if (ui.chordPressed(.{ .key = .z, .modifiers = .{ .control = true, .shift = true } })) app.history.redo();
    if (ui.keyPressed(.delete) and !app.selection.isEmpty()) app.confirmDelete();

    for (ui.keyEvents()) |event| switch (event.key) {
        .left => app.viewer.previous(),
        .right => app.viewer.next(),
        else => {},
    };

    if (ui.focused(.of("search"))) app.search.appendSlice(ui.typedText());
}
```

<a id="scroll"></a>

### Clipping, culling and wheel scrolling · *shipped*

`scroll` makes a container scroll with the wheel on the axes it names and clips them. `clip` clips without scrolling. Content outside a clip is culled, so it emits no render commands. The offset lives in the state table under the container's id, so you can read it and set it.

`src/ui/library.zig`

```zig
fn photoGrid(app: *App, ui: *Ui) void {
    const grid = ids.grid;
    if (app.jump_to_top) {
        ui.setScrollOffset(grid, .{ 0, 0 });
        app.jump_to_top = false;
    }

    ui.open(.{
        .id = grid,
        .scroll = .{ .vertical = true },
        .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(12), .child_gap = 12 },
    });
    defer ui.close();

    const photos = app.currentAlbum().photos;
    var row_start: usize = 0;
    while (row_start < photos.len) : (row_start += app.columns) {
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12 } });
        defer ui.close();
        const row_end = @min(row_start + app.columns, photos.len);
        for (photos[row_start..row_end], row_start..) |*photo, index| photoCard(app, ui, photo, index);
    }

    app.scrolled_past_header = ui.scrollOffset(grid)[1] > 48;
}
```

<a id="gestures"></a>

### Gestures and intents · *shipped*

An element declares what it accepts from pointers with `gestures`. Once a pointer moves 8 units from where it pressed (`zui.Gestures.touch_slop`), its axis locks, and it goes to the innermost element under the press that pans on that axis and can still move that way. So a vertical swipe on a horizontal filmstrip scrolls the page around it, a swipe past the strip's end does too, and the button it started on loses the press: no click. Scroll containers pan by touch and pen on their scrolled axes; the mouse keeps the wheel, so a mouse drag in a list stays with what it pressed. `ui.manipulation(id)` reports what pans and the wheel did to an element this frame. Declaring a gesture makes the element interactive, and without `features.gestures` it is ignored, so widgets declare it for every context: `zui_widgets`' slider keeps a horizontal drag. Two pointers pressed inside an element with `.gestures.zoom` zoom the innermost one, even when the pinch starts on a list inside it, and `manipulation` adds their scale, rotation and pivot. An element with `.long_press` turns a press held still for half a second into `contextRequested`, as a right click and the menu key do, and one with `.double_tap` reports `doubleTapped`, delaying only its own single tap until the window passes. `dismissed`, `adjusted` and `navigated` read Escape and the arrows on the focused element. A flick coasts on after the finger lifts, slowing down, through the same `manipulation` and scrolling, with `nextFrame` asking for each frame until it stops. An element with `.custom` runs your own recognizer: `ui.pointerEvents(id)` gives it the pointers pressed on it, and every other gesture waits until it calls `ui.claim(pointer)` or `ui.decline(pointer)`, which apply a frame later, a declined pointer keeping all its motion. `zui_widgets`' `lasso` is one, drawing with a pen over a map that fingers still pan.

`src/ui/album.zig`

```zig
fn albumPage(app: *App, ui: *Ui) void {
    ui.open(.{ .id = ids.album_page, .scroll = .{ .vertical = true }, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both } });
    defer ui.close();

    // A vertical swipe on the filmstrip scrolls the page; a horizontal one the strip.
    ui.open(.{ .id = ids.filmstrip, .scroll = .{ .horizontal = true, .vertical = false }, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(96) }, .child_gap = 4 } });
    for (app.currentAlbum().photos, 0..) |*photo, index| thumbnail(app, ui, photo, index);
    ui.close();

    viewer(app, ui);
}

fn viewer(app: *App, ui: *Ui) void {
    const id = ids.viewer;
    if (ui.manipulation(id)) |moved| {
        app.viewer.offset[0] += moved.translation[0];
        app.viewer.offset[1] += moved.translation[1];
        app.viewer.zoomBy(moved.scale, moved.pivot);
    }
    if (ui.clicked(id)) app.viewer.toggleChrome(); // a tap, not the end of a pan
    if (ui.doubleTapped(id)) app.viewer.zoomToFit();
    if (ui.contextRequested(id)) app.openPhotoMenu(ui.primaryPointer());
    if (ui.dismissed(id)) app.closeViewer();

    ui.open(.{ .id = id, .gestures = .{ .pan = .both, .zoom = true, .long_press = true, .double_tap = true, .custom = true }, .focusable = true, .cursor = .grab, .clip = .both, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(480) } } });
    defer ui.close();
    if (widgets.lasso(ui, id, &app.viewer.selection)) app.selectFacesInside(app.viewer.selection.points());
    ui.image(.{ .handle = app.viewer.texture, .natural_size = app.viewer.size }, .{ .floating = .{ .offset = app.viewer.offset, .clip = .target } });
}
```

<a id="drag-and-drop"></a>

### Drag and drop · *shipped*

A card that declares `.gestures.drag` is arbitrated with every other gesture: once the pointer passes the touch slop, the card takes it on the axes no element around it pans on, so in a list that scrolls vertically a sideways swipe drags the card and a vertical one scrolls the list, while the mouse, which scrolls lists with its wheel, drags on both. `ui.dragging(id)` reports the pointer and how far it has moved, and you draw what follows it, a floating element with `.capture = false` so the hit test sees what lies beneath. `ui.startDrag(id, payload)` gives the drag a payload of your own type, kept in the state table under the card while the drag lasts, even if the card leaves its list meanwhile; called on a card still pressed, after a long press say, it lifts the card itself. A target asks `ui.dropped(id, Payload)` in the frame of the release, and `ui.draggedOver(id, Payload)` while a drag is over it: any element with a hit region, the list and the card under the pointer alike, receives it, and a payload of another type is `null`, never reinterpreted. Files dropped from the OS are `filesDropped`, not this.

`src/ui/board.zig`

```zig
const CardRef = struct { column: u8, index: u16 };

fn board(app: *App, ui: *Ui) void {
    ui.open(.{ .layout = .{ .child_gap = 16, .sizing = .grow_both } });
    defer ui.close();
    for (app.columns, 0..) |*column, column_index| {
        const column_id: zui.Id = .indexed("column", column_index);
        if (ui.dropped(column_id, CardRef)) |moved| app.moveCard(moved, column_index);
        const highlight = ui.draggedOver(column_id, CardRef) != null;
        ui.open(.{ .id = column_id, .scroll = .{}, .decoration = .{ .background = if (highlight) theme.drop_target else theme.column }, .layout = .{ .direction = .top_to_bottom, .child_gap = 8, .sizing = .{ .width = .fixed(280), .height = .grow } } });
        defer ui.close();
        for (column.cards(), 0..) |card, index| {
            const card_id: zui.Id = .indexed("card", card.key);
            ui.open(.{ .id = card_id, .gestures = .{ .drag = true }, .cursor = .grab, .decoration = .{ .background = theme.card }, .layout = theme.card_layout });
            defer ui.close();
            if (ui.dragging(card_id)) |drag| {
                ui.startDrag(card_id, CardRef{ .column = @intCast(column_index), .index = @intCast(index) });
                ui.open(.{ .floating = .{ .offset = drag.translation, .z = 10, .capture = false }, .decoration = .{ .background = theme.card_lifted }, .layout = theme.card_layout });
                cardContent(ui, card);
                ui.close();
            }
            cardContent(ui, card);
        }
    }
}
```

<a id="floating"></a>

### Floating elements in paint layers · *shipped*

A floating element takes no space in its parent's flow. It attaches to its parent, the viewport, or any element in the frame, declared before or after it, by matching an anchor point on itself to a point on the target, plus an offset. It paints in layer `z`, escaping its ancestors' clips, or with `.clip = .target` cut off where its target's children are, so a badge on a row scrolls out of sight with the row. It takes the pointer from whatever it covers, unless `.capture = false` lets the pointer through, as a tooltip should. Tooltips, popups, menus and dialogs are all built this way.

`src/ui/tooltips.zig`

```zig
fn tooltipFor(ui: *Ui, target: zui.Id, content: []const u8) void {
    if (!ui.hovered(target)) return;
    ui.open(.{
        .floating = .{
            .attach_to = .{ .element = target },
            .anchor = .top_center,
            .attach_point = .bottom_center,
            .offset = .{ 0, 6 },
            .z = 50,
            .capture = false,
        },
        .layout = .{ .padding = .symmetric(8, 4) },
        .decoration = .{ .background = .rgb(0x0f0f14), .corner_radius = .all(4) },
    });
    ui.text(content, .{ .size = 12, .color = .white });
    ui.close();
}

fn contextMenu(app: *App, ui: *Ui) void {
    const menu = app.context_menu orelse return;
    ui.open(.{
        .id = .of("context_menu"),
        .floating = .{ .attach_to = .root, .offset = menu.position, .z = 120 },
        .layout = .{ .direction = .top_to_bottom, .padding = .all(4) },
        .decoration = .{ .background = .rgb(0x262634), .corner_radius = .all(6) },
    });
    defer ui.close();
    if (toolButton(ui, .of("menu_rename"), "Rename", true)) app.beginRename(menu.photo);
    if (toolButton(ui, .of("menu_reveal"), "Show in folder", true)) app.reveal(menu.photo);
}

// after declaring the import button:
tooltipFor(ui, .of("import"), "Import photos (Ctrl+I)");

// Declared before the photo card it marks, and cut off where the grid scrolls it away:
fn unsavedBadge(ui: *Ui, index: usize) void {
    ui.box(.{
        .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } },
        .decoration = .{ .background = .rgb(0xffc65c), .corner_radius = .all(5) },
        .floating = .{
            .attach_to = .{ .element = .indexed("photo", index) },
            .anchor = .center,
            .attach_point = .top_right,
            .clip = .target,
        },
    });
}
```

<a id="state"></a>

### Per-element state across frames · *shipped*

`ui.state(id, T)` returns a zeroed `*T` keyed by id and type that persists while the element keeps being declared. It is evicted a couple of frames after the element stops being declared. A slot holds at most 64 bytes, and a larger type is a compile error that tells you to store an index instead. When the table is full you get scratch memory and a diagnostic. Nothing is corrupted.

`src/ui/album_header.zig`

```zig
const HeaderState = struct {
    expanded: bool,
    hover_started_at: zui.Instant,
};

fn albumHeader(app: *App, ui: *Ui, album: *const Album) void {
    const id: zui.Id = .of("album_header");
    const header = ui.state(id, HeaderState);
    if (ui.clicked(id)) header.expanded = !header.expanded;

    ui.open(.{ .id = id, .interactive = true, .layout = .{ .direction = .top_to_bottom, .padding = .all(12) } });
    defer ui.close();
    ui.text(album.name, .{ .size = 20 });
    if (header.expanded) ui.text(album.description, .{ .size = 13, .color = .rgb(0x9a9aae) });
    _ = app;
}

fn wasEverOpened(ui: *Ui) bool {
    const header = ui.stateIfPresent(.of("album_header"), HeaderState) orelse return false;
    return header.expanded;
}
```

<a id="environment"></a>

### The environment · *shipped*

The host reports the user's settings as events, and `ui.environment()` holds the current values: theme, contrast, reduced motion and transparency, text scale, locale, reading direction, HDR headroom, power, window focus, and whether the system material (Mica) shows behind the window. the native Windows host reads them from the system, and the native Linux host reads the theme, contrast and reduced motion from the XDG desktop portal and power from UPower and power-profiles-daemon, over D-Bus; where no portal answers, they stay at their defaults.

`src/ui/palette.zig`

```zig
const Palette = struct { window: ?zui.Color, panel: zui.Color, text: zui.Color, accent: zui.Color };

fn paletteFor(ui: *const Ui) Palette {
    const environment = ui.environment();
    const dark = environment.theme == .dark;
    const high_contrast = environment.contrast == .high;
    return .{
        .window = if (environment.system_material) null else if (dark) .rgb(0x15161b) else .rgb(0xf4f4f7),
        .panel = if (dark) .rgba(0x20202880) else .rgba(0xffffffcc),
        .text = if (high_contrast) (if (dark) .white else .black) else if (dark) .rgb(0xe0e0ea) else .rgb(0x23232b),
        .accent = .rgb(0x5b8cff),
    };
}

fn shouldAnimate(ui: *const Ui) bool {
    const environment = ui.environment();
    return !environment.reduced_motion and environment.power != .saver and environment.window_focused;
}
```

<a id="drops"></a>

### Dropped files and lifecycle events · *shipped*

Files dropped onto the window arrive with their drop position and paths. Lifecycle events cover suspend, resume, a termination request (Ctrl+C, a closing console, the session ending) and low memory. the native Windows host reports all of them; the native Linux host reports dropped files, SIGINT, SIGTERM and SIGHUP as termination requests, and the system sleeping and waking as suspend and resume.

`src/ui/system.zig`

```zig
fn handleSystemEvents(app: *App, ui: *Ui) void {
    for (ui.filesDropped()) |drop| {
        const onto_album = app.albumAt(drop.position);
        var paths = drop.paths();
        while (paths.next()) |path| app.queueImport(path, onto_album);
    }

    const lifecycle = ui.lifecycle();
    if (lifecycle.contains(.low_memory)) app.thumbnail_cache.shrinkTo(64);
    if (lifecycle.contains(.@"suspend")) app.pauseBackgroundIndexing();
    if (lifecycle.contains(.@"resume")) app.resumeBackgroundIndexing();
    if (lifecycle.contains(.terminate_requested)) app.saveSession();
}
```

<a id="host-requests"></a>

### Requests to the host: cursor and text input · *shipped*

A frame asks the host for things the renderer doesn't handle. The pointer shape comes from the hot element's `cursor`. The text-input area comes from `requestTextInput`, which an editable calls each frame with the element it draws as its caret, so the host can place the IME window and show an on-screen keyboard. The host reads them with `frame.requests()`.

`src/ui/search.zig`

```zig
fn searchField(app: *App, ui: *Ui) void {
    const field: zui.Id = .of("search");
    ui.requestTextInput(field, field.child("caret"));

    ui.open(.{ .id = field, .focusable = true, .cursor = .text, .layout = .{ .padding = .symmetric(8, 4), .sizing = .{ .width = .fixed(220) } } });
    defer ui.close();
    ui.text(app.search.slice(), .{ .size = 13 });
    if (ui.focused(field)) ui.box(.{ .id = field.child("caret"), .layout = .{ .sizing = .{ .width = .fixed(2), .height = .fixed(16) } }, .decoration = .{ .background = .white } });
}

// in the loop:
const frame = ui.endFrame();
const requests = frame.requests();
host.zuiApply(.main, requests);
```

<a id="semantics"></a>

### Semantics and accessibility actions · *shipped*

With `features.semantics`, an element's `semantics` says what it is to an assistive technology: a role, a label, a value (text, or a position in a range), a state (checked, expanded, selected), and the actions it takes beyond those its flags and gestures already report. `frame.semantics()` lists every element that declares it, in tree order, each with its id, its laid-out bounds and the index of the node around it, its labels copied into the frame. A host bridges the list to the platform's accessibility API and reports what the screen reader asks as `action` events; each one is answered by the query of the input it stands in for, so `invoke` is a `clicked`, `adjust` an `adjusted`, `scroll` a `manipulation` and a scroll, `show_menu` a `contextRequested` and `dismiss` a `dismissed`. Every `zui_widgets` control declares its own. Without the feature, `semantics` is ignored and none of it is compiled. A host that declares `zuiSemantics` is handed the list with each frame, on the UI thread, and copies what fits into room it took when the window opened. the native Windows host bridges it to UI Automation, so Narrator reads each control's name, role, bounds and state, hears it change, and acts on it through the control's own pattern: Toggle on a checkbox, Expand and Collapse on a dropdown or disclosure, SetValue on a slider, Select on an option, and Invoke on a button, each arriving as the `action` event that answers it. A scroll container scrolls by a notch, a page or to a place in its content, as `SemanticScroll` says where its view lies; a dialog closes as a `dismiss`; an element's context menu is a `show_menu`; and a heading tells its `level`. A text field's text reads through its Value pattern and is typed with the keyboard.

`src/ui/toolbar.zig`

```zig
fn saveButton(app: *App, ui: *Ui) void {
    const save: zui.Id = .of("save");
    ui.open(.{
        .id = save,
        .focusable = true,
        .disabled = !app.dirty,
        .semantics = .{ .role = .button, .label = "Save" },
    });
    defer ui.close();
    ui.text("Save", .{ .size = 13 });
    if (ui.clicked(save)) app.save(); // a click, Enter, or an invoke action
}

fn zoomSlider(app: *App, ui: *Ui) void {
    const zoom: zui.Id = .of("zoom");
    if (ui.adjusted(zoom)) |steps| app.zoom_percent +|= 10 * steps; // arrows, or adjust actions
    ui.box(.{
        .id = zoom,
        .focusable = true,
        .semantics = .{
            .role = .slider,
            .label = "Zoom",
            .value = .{ .range = .{ .value = @floatFromInt(app.zoom_percent), .min = 10, .max = 400, .step = 10 } },
            .actions = .initOne(.adjust),
        },
    });
}

// a host's accessibility bridge, which zui_app calls after endFrame:
pub fn zuiSemantics(host: *MyHost, window: zui.WindowId, nodes: []const zui.SemanticNode) zui.SemanticsDropped {
    return host.bridge(window).copy(nodes); // keep what fits: the nodes go when the call returns
}
// and when the screen reader asks, in the next record:
builder.append(.{ .action = .{ .target = node_id, .action = .invoke } });
```

<a id="title-bar"></a>

### A custom title bar · *shipped*

With `features.chrome_regions`, a window opened with `.title_bar = .custom` leaves its title bar to you, and `ui.environment().custom_title_bar` says whether it did. Mark each part you draw with `chrome`: a `.title_bar`, which the OS drags, maximizes on a double click and opens the window menu on; `.minimize_button`, `.maximize_button` and `.close_button`, which the host works when a press and its release land on them, as the system's own (hovering maximize shows snap layouts); and `.resize_*` edges and grips. `frame.chromeRegions()` lists them in tree order, and every interactive element inside a title bar, a search field or a tab, stays yours as a `.client` region. `zui_app` hands the list to the host's `zuiChromeRegions` each frame. The pointer still reaches the caption buttons, so they show hover and press, but the host ends a press it works as `pointer_cancel`, so `clicked` comes only from the keyboard and Narrator: act on it through the host's `minimize`, `toggleMaximized` and `close`, and each button works once. `ui.environment().window_maximized` picks the restore glyph. The native Windows host does all of it, keeping the system's border, rounded corners and shadow; there `zuiMenus.setBar` is `error.Unavailable`, so draw your menus in the title bar. The Wayland host asks the compositor for client-side decorations and hands presses on the title bar and the edges to it; it draws no border, so declare the `.resize_*` grips you want resized from. A compositor that insists on drawing its own title bar, as Hyprland does, gets it, and `custom_title_bar` is false.

`src/ui/title_bar.zig`

```zig
fn titleBar(app: *App, ui: *Ui) void {
    if (!ui.environment().custom_title_bar) return; // the system draws one
    ui.open(.{ .id = .of("title bar"), .chrome = .title_bar, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(32) }, .child_alignment = .{ .y = .center } } });
    defer ui.close();
    ui.text("Notes", .{ .size = 12 });
    _ = app.widgets.textField(ui, .of("search"), &app.search, .{ .label = "Search" }); // stays the application's
    const maximized = ui.environment().window_maximized;
    if (captionButton(ui, .of("maximize"), .maximize_button, if (maximized) "Restore" else "Maximize")) app.host.toggleMaximized();
    if (captionButton(ui, .of("close"), .close_button, "Close")) app.host.close();
}

fn captionButton(ui: *Ui, id: zui.Id, kind: zui.ChromeKind, label: []const u8) bool {
    ui.box(.{ .id = id, .chrome = kind, .focusable = true, .semantics = .{ .role = .button, .label = label }, .layout = .{ .sizing = .{ .width = .fixed(46), .height = .grow } } });
    return ui.clicked(id); // the keyboard's or Narrator's; a pointer's is the host's
}

// opening the window:
try zui_app.run(App, init, .{ .title = "Notes", .material = .window, .title_bar = .custom });
```

<a id="loop"></a>

## 03. The frame loop, timing and diagnostics

How a frame starts and ends, how an idle app sleeps, and how limits and mistakes are reported.

<a id="loop-by-hand"></a>

### The loop by hand · *shipped*

The host fills a `RecordBuilder` with the time, viewport, scale and events. `beginFrame` applies the record and swaps in the sources. You declare, `endFrame` lays out and always returns a frame, the renderer draws it, and the host applies its requests. `release` hands the frame back, which lets a render thread hold one while the next is declared. Finally `nextFrame` tells the host whether to draw immediately, at a time, or only on the next event. [zui_app](#zui-app) runs all of this for you.

`src/loop.zig`

```zig
pub fn runLoop(app: *App, ui: *Ui, host: *Host, renderer: *Renderer) !void {
    comptime zui.checkHostAndRenderer(Host, Renderer);

    var events: [256]zui.Event = undefined;
    var text: [1024]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text);

    while (host.zuiPoll(.main, &builder)) {
        const record = builder.recordWith(Ui.Deliveries);
        ui.beginFrame(&record, &app.sources);

        declareShell(app, ui);
        renameDialog(app, ui);
        shortcuts(app, ui);

        const frame = ui.endFrame();
        try renderer.zuiSubmit(host.zuiSurface(.main), frame);
        host.zuiApply(.main, frame.requests());
        ui.release(frame);

        runLoader(app, ui, host.zuiWaker());
        host.zuiWait(ui.nextFrame(&app.sources));
    }
}
```

Without sources, the record is `builder.record()`, and `beginFrame` and `nextFrame` drop the sources argument. A host that can't block uses `tryBeginFrame`.

<a id="timing"></a>

### Timing, animation and idling at 0% CPU · *shipped*

Each record carries a timestamp, so `ui.now()` and `ui.dt()` are deterministic and replay identically. An app animates by asking for frames. `requestFrame` asks for the next one immediately, and `requestFrameAt` schedules a wake-up. When nothing asks, `nextFrame` returns `.on_event` and the host sleeps until input arrives or a source publishes.

`src/ui/import_progress.zig`

```zig
const Fade = struct { opacity: f32 };

fn importToast(app: *App, ui: *Ui) void {
    const fade = ui.state(.of("import_toast"), Fade);
    const target: f32 = if (app.importing) 1 else 0;
    if (fade.opacity != target) {
        const step = ui.dt() * 4;
        fade.opacity = if (target > fade.opacity) @min(target, fade.opacity + step) else @max(target, fade.opacity - step);
        ui.requestFrame();
    }
    if (fade.opacity == 0) return;

    const alpha: u8 = @intFromFloat(fade.opacity * 255);
    ui.open(.{
        .floating = .{ .attach_to = .root, .anchor = .bottom_right, .attach_point = .bottom_right, .offset = .{ -16, -16 }, .z = 80 },
        .layout = .{ .padding = .all(10) },
        .decoration = .{ .background = .{ .r = 0x26, .g = 0x26, .b = 0x34, .a = alpha }, .corner_radius = .all(6) },
    });
    ui.text("Importing…", .{ .size = 13, .color = .{ .r = 255, .g = 255, .b = 255, .a = alpha } });
    ui.close();
}

fn blinkCaret(ui: *Ui, app: *App) bool {
    ui.requestFrameAt(app.next_caret_blink);
    return app.caret_visible;
}
```

<a id="zui-motion"></a>

### `zui_motion`: tweens and springs · *shipped*

`zui_motion.tween(ui, id, T, target, options)` eases a value toward `target` over `duration` seconds with an `Easing` (`linear`, or cubic `ease_in`, `ease_out` and `ease_in_out`) and returns this frame's value. `zui_motion.spring` follows `target` with a critically damped spring instead, keeping its velocity when the target moves, which suits a value chasing a drag. The value is an `f32`, a `[N]f32`, a `zui.Color` (mixed per sRGB channel, as `Color.mix` and CSS transitions do), a `zui.ExtendedColor`, or a struct of them; anything else is a compile error. Each keeps its state in `ui.state`, so the first target it sees is where it starts, and a target that changes mid-flight starts again from the current value. While it moves it asks for the next frame, a `delay` asks for the instant it starts, and at rest it asks for nothing, so the app still idles. Under the environment's `reduced_motion` it lands on the target in the frame the target changes. When the state table is full it reports `.state_slots` and returns the target.

`src/ui/import_progress.zig`

```zig
const zui_motion = @import("zui_motion");

fn importToast(app: *App, ui: *Ui) void {
    // Every tween is called each frame, even while hidden, so none forgets where it was.
    const opacity = zui_motion.tween(ui, .of("import_toast"), f32, if (app.importing) 1 else 0, .{ .duration = 0.25 });
    const slide = zui_motion.spring(ui, .of("import_toast slide"), f32, if (app.importing) 0 else 24, .{});
    const background = zui_motion.tween(ui, .of("import_toast color"), zui.Color, if (app.import_failed) .rgb(0x8a2030) else .rgb(0x262634), .{});
    if (opacity == 0) return;

    const alpha: u8 = @intFromFloat(opacity * 255);
    ui.open(.{
        .floating = .{ .attach_to = .root, .anchor = .bottom_right, .attach_point = .bottom_right, .offset = .{ -16, -16 + slide }, .z = 80 },
        .layout = .{ .padding = .all(10) },
        .decoration = .{ .background = background, .corner_radius = .all(6) },
    });
    ui.text("Importing…", .{ .size = 13, .color = .{ .r = 255, .g = 255, .b = 255, .a = alpha } });
    ui.close();
}
```

<a id="exit-animations"></a>

### Exit animations · *shipped*

An element declared with `.exit = .{ .seconds = 0.25 }` keeps drawing for a quarter of a second after the frame it was last declared in, so a toast or a closed dialog leaves without the app declaring it any longer. Its ghost is the commands its subtree emitted in that frame, inside the clip and transforms around it, drawn at the end of its layer; it takes no space, so what was below it moves up at once, and it is never hit. `fade` is `.linear` by default, or a cubic `.ease_in`, `.ease_out` or `.ease_in_out`, which multiply the alpha of every color it draws; `.none` holds it unchanged, then drops it, asking only for a frame at that instant. A fade asks for the next frame while it lasts and for nothing after. The ghost is dropped when its element is declared again, and every ghost at once under `reduced_motion`. It needs an id, and `limits.exit_ghost_commands` set to the commands to keep, with up to `max_text_bytes` of their text; at 0, the default, `exit` is ignored and costs nothing, so a widget can declare it for every context. A ghost that does not fit is not drawn, and the frame reports `.exit_ghost_commands`.

`src/ui/saved_toast.zig`

```zig
pub const Ui = zui.Context(.{ .limits = .{ .exit_ghost_commands = 64 }, .Text = Text });

fn savedToast(app: *App, ui: *Ui) void {
    if (!app.just_saved) return;
    ui.open(.{
        .id = .of("saved_toast"),
        .floating = .{ .attach_to = .root, .anchor = .bottom_right, .attach_point = .bottom_right, .offset = .{ -16, -16 }, .z = 80 },
        .layout = .{ .padding = .all(10) },
        .decoration = .{ .background = .rgb(0x262634), .corner_radius = .all(6) },
        .exit = .{ .seconds = 0.3, .fade = .ease_out },
    });
    defer ui.close();
    ui.text("Saved", .{ .size = 13, .color = .white });
}
```

<a id="zui-color"></a>

### `zui_color`: color spaces and palettes · *shipped*

`zui_color` builds palettes from a few colors, at comptime, so a theme's shades are constants. `Oklab`, `Oklch` and `Hsl` convert to and from `zui.Color` (`fromColor`, `toColor`), and `Oklab` and `Oklch` to and from a linear `zui.ExtendedColor` as well, each with a straight `alpha`. OKLab is where equal distances look equally different, so `zui_color.mix(from, to, amount)` mixes in it and its middle is neither muddy nor too dark; `mixOklch` keeps the chroma and takes the shorter way around the hue circle. `ramp(steps, from, to)` gives evenly spaced colors from one to the other, both ends included. `shiftLightness(color, change)` and `withLightness(color, lightness)` move a color's OKLCH lightness for a hovered or pressed shade, and `lightnessScale(steps, color, darkest, lightest)` gives a tonal scale of its hue. A color sRGB cannot show is brought in by reducing its chroma, keeping its lightness and hue, rather than by clipping each channel. `Hsl` follows CSS's `hsl()`. A ramp or scale of fewer than two steps is a compile error.

`src/theme/palette.zig`

```zig
const zui_color = @import("zui_color");

pub const accent: zui.Color = .rgb(0x3366ff);
pub const accent_hovered = zui_color.shiftLightness(accent, 0.06);
pub const accent_pressed = zui_color.shiftLightness(accent, -0.08);
pub const surfaces = zui_color.ramp(5, .rgb(0x15151c), .rgb(0x3a3a48));
pub const accent_tones = zui_color.lightnessScale(10, accent, 0.25, 0.97);
pub const warning: zui.Color = (zui_color.Oklch{ .lightness = 0.8, .chroma = 0.16, .hue_degrees = 85 }).toColor();
pub const focus_ring = zui_color.mix(accent, .white, 0.35);
```

<a id="diagnostics"></a>

### Limits that fail softly: diagnostics · *shipped*

Every limit fails the same way. zui keeps and draws what fits, and records in `frame.diagnostics` which limit was exceeded, how much the frame needed, and the first element dropped. Duplicate ids, unbalanced trees and publishes refused by full sources are reported here too. Apps that would rather stop call `check()`.

`src/loop.zig`

```zig
const log = std.log.scoped(.darkroom);

fn reportDiagnostics(frame: *const Ui.Frame) void {
    const diagnostics = frame.diagnostics;
    if (diagnostics.ok()) return;

    var exceeded = diagnostics.exceeded.iterator();
    while (exceeded.next()) |limit| {
        log.warn("limits.{t} was too small: this frame needed {d}", .{ limit, diagnostics.needed.get(limit) });
    }
    if (diagnostics.duplicate_ids > 0) log.warn("{d} duplicate ids", .{diagnostics.duplicate_ids});
    if (diagnostics.refused_publishes > 0) log.warn("source `{s}` is full", .{diagnostics.first_refusing_source});
}

fn strictFrame(ui: *Ui) !*const Ui.Frame {
    const frame = ui.endFrame();
    try frame.diagnostics.check();
    return frame;
}
```

<a id="queries"></a>

### Frame queries · *shipped*

Layout results from the previous frame are available while you declare: an element's rectangle, the pointer in an element's local coordinates, the viewport, and the primary pointer. This is how a canvas maps clicks to cells or a widget sizes a popup.

`src/ui/viewer.zig`

```zig
fn cropOverlay(app: *App, ui: *Ui) void {
    const image_rect = ui.rectOf(.of("full_image")) orelse return;
    if (ui.pointerLocal(.of("full_image"))) |local| {
        app.crop.hover = .{ local[0] / image_rect.width, local[1] / image_rect.height };
    }

    const viewport = ui.viewport();
    app.columns = @max(2, @as(usize, @intFromFloat(viewport[0] / 220)));
}
```

After `endFrame`, the frame has its own `rectOf`, `commands()` and `elementCount()`, and `inspect(index)` reports everything it kept of one element, in declaration order from the root at 0: its id and debug name, parent, laid-out rectangle, flags, layout, decoration, effects, floating and its text, image or custom content. That is enough to build your own inspector or a debug overlay.

`src/debug/outline.zig`

```zig
fn outlineHovered(frame: *const Ui.Frame, pointer: [2]f32) ?zui.Rect {
    var hovered: ?zui.Rect = null;
    for (0..frame.elementCount()) |index| {
        const element = frame.inspect(@intCast(index));
        if (element.content != .none and element.rect.contains(pointer)) hovered = element.rect;
    }
    return hovered;
}
```

<a id="sweeps"></a>

### Safety sweeps · *shipped*

`frame.sweep()` checks what every laid-out frame must keep: sizes and positions finite and not negative, child lists that agree with their parents, free space and overflow shared as the sizing rules say, children starting inside their parent's content box, and commands in nondecreasing layers with balanced clips. It returns the first invariant broken, as a `zui.SweepFailure` naming the invariant and the element or command, or null. With `features.safety_sweeps`, on by default in Debug and ReleaseSafe, `endFrame` sweeps every frame and panics on a failure, naming the frame and the element, so a layout bug stops where it happens instead of drawing wrong.

`src/tests/layout_test.zig`

```zig
test "the album grid keeps every layout invariant at any width" {
    var ui = try Ui.init(std.testing.allocator, std.testing.io, &fonts);
    defer ui.deinit(std.testing.allocator);
    for ([_]f32{ 1, 320, 800, 2560 }) |width| {
        ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ width, 900 } } });
        albumGrid(&ui, &app);
        const frame = ui.endFrame();
        defer ui.release(frame);
        try std.testing.expectEqual(null, frame.sweep());
    }
}
```

<a id="compile-errors"></a>

### Features and compile errors · *shipped*

`Config.features` turns capabilities on or off. A feature that is off generates no code and no memory, and calling its API fails to compile with a message naming the field to set. The same discipline runs through every contract. Each message below is pinned by a compile-error test.

`src/main.zig`

```zig
const zui_tracy = @import("zui_tracy");

pub const Ui = zui.Context(.{
    .Text = Fonts,
    .features = .{
        .gestures = false,
        .safety_sweeps = false,
        .Tracer = zui_tracy.Tracer,
    },
});
```

Some of the messages you'll see:

```text
error: zui: manipulation() needs Config.features.gestures = true
error: zui: wrapChildren() needs Config.features.flex_wrap = true
error: zui: limits.state_slots must be a power of two, got 1000
error: zui: text_unknown_declaration.Text declares unknown `zui_threadsafe`
error: zui: state type state_type_too_large.History is 80 bytes, but a state slot holds at most 64; store an index into your own storage instead
error: zui: host_and_renderer_share_no_surface.Host and host_and_renderer_share_no_surface.Renderer share no surface kind: the host gives .library, the renderer draws into .offscreen, .terminal
error: zui: sources_unknown_declaration.AppSources.quotes declares unknown `zuiPendng`
error: zui_async: Stream capacity must be a power of two, got 100
error: zui_widgets: slider needs a pointer to an integer or float, got *bool
error: no field named 'volum' in struct 'zui_reflect.FieldOptionsOf(reflect_misspelled_option.Settings)'
```

<a id="async"></a>

## 04. Sources and `zui_async`

Getting data from other threads into an immediate-mode UI without locks in declaration. Producers publish from any thread, `beginFrame` swaps each source once, declaration reads a stable view, and a loader starts work for what the UI asked for. Every source is checked under ThreadSanitizer by `expectSourceConforms`.

<a id="sources"></a>

### Declaring sources · *shipped*

`Config.Sources` is a struct whose fields are sources. Each is named by field in `ui.source(.field)`, and that field name also appears in diagnostics when a source fills up. `framesSinceRead` tells a loader whether anyone is still watching. It counts frames rather than time, so a sleeping UI never looks abandoned.

`src/sources.zig`

```zig
const zui_async = @import("zui_async");

pub const AppSources = struct {
    battery: zui_async.Latest(f32) = .{},
    import_log: zui_async.Stream(ImportEvent, .{ .capacity = 256, .producers = .many }) = .{},
    library_scan: LibraryScan = .{},
    thumbnails: Thumbnails = .{},
    theme_files: zui_async.Stream(zui.FileChange, .{ .capacity = 32 }) = .{},
};

pub const LibraryScan = zui_async.Task(ScanError!*const Library, .{ .Progress = f32 });
pub const Thumbnails = zui_async.KeyedLoads(u64, DecodeError!Texture, .{
    .capacity = 256,
    .owns_resources = true,
    .unread_frames_before_release = 120,
});
```

<a id="latest"></a>

### `Latest`: the newest value only · *shipped*

A triple buffer for state where only the newest value matters, such as battery level, sync state or a download rate. A publish never waits. `publish` returns whether the host needs waking, so a hundred publishes between frames cost one wake.

`src/power_monitor.zig`

```zig
fn powerMonitor(sources: *AppSources, waker: zui.Waker, io: std.Io) void {
    while (true) {
        const level = readBatteryLevel() catch continue;
        waker.wakeIf(sources.battery.publish(level));
        sleepSeconds(io, 30) catch return;
    }
}

fn batteryIndicator(ui: *Ui) void {
    const battery = ui.source(.battery);
    const level = battery.get() orelse return;
    var buffer: [8]u8 = undefined;
    ui.text(std.fmt.bufPrint(&buffer, "{d:.0}%", .{level * 100}) catch "", .{
        .size = 12,
        .color = if (level < 0.15) .rgb(0xff6b6b) else .rgb(0x9a9aae),
    });
    if (battery.changed()) ui.requestFrame();
}
```

<a id="stream"></a>

### `Stream`: every item, in order · *shipped*

A bounded ring for messages and log lines. Each frame sees the items published since the last swap, read in place. When it's full, `publish` refuses with `error.Full` rather than waiting, the item stays with its producer, and the refusal shows up in diagnostics.

`src/importer.zig`

```zig
fn importWorker(sources: *AppSources, waker: zui.Waker, paths: []const []const u8) void {
    for (paths) |path| {
        const event: ImportEvent = if (importOne(path)) |photo| .{ .imported = photo.id } else |err| .{ .failed = .{ .path = path, .reason = err } };
        waker.wakeIf(sources.import_log.publish(event) catch .already_pending);
    }
}

fn importLog(app: *App, ui: *Ui) void {
    var events = ui.source(.import_log).items();
    while (events.next()) |event| switch (event.*) {
        .imported => |photo_id| app.recent_imports.append(photo_id),
        .failed => |failure| app.import_errors.append(failure),
    };
}
```

<a id="task"></a>

### `Task`: one piece of work with a status · *shipped*

One run at a time, with optional progress. The UI switches on a `Status` union: `idle`, `running` (carrying the progress value), `ready`, `failed` and `canceled`. `failed` exists only when the result can fail with something other than `Canceled`, so an infallible task has no prong to handle. `publishing` adapts a plain function into a producer for `Io.Group.async`.

`src/library.zig`

```zig
fn scanLibrary(io: std.Io, root: []const u8) ScanError!*const Library {
    return Library.scan(io, root);
}

fn startScanIfNeeded(app: *App, io: std.Io) void {
    if (!app.wants_rescan) return;
    if (app.sources.library_scan.begin(app.waker)) |run| {
        app.work.async(io, LibraryScan.publishing(scanLibrary), .{ run, .{ io, app.library_root } });
        app.wants_rescan = false;
    } else |_| {}
}

fn libraryStatus(app: *App, ui: *Ui) void {
    switch (ui.source(.library_scan).status()) {
        .idle => {},
        .running => |fraction| progressBar(ui, fraction, "Scanning library…"),
        .ready => |library| app.library = library,
        .failed => |err| errorBanner(ui, "Couldn't scan the library", @errorName(err)),
        .canceled => {},
    }
}
```

<a id="keyed-loads"></a>

### `KeyedLoads` and the loader · *shipped*

This source handles many loads driven by what the UI asks for. Declaration calls `get(key)`, which records demand and returns a status, and starts nothing. After `endFrame`, the loader takes the wanted keys from `toStart` and starts their work. Keys that stop being read are abandoned, and with `owns_resources` their results come back through `toRelease` to free. Scroll a grid of 10,000 photos and only the visible thumbnails load. The UI thread never waits.

`src/thumbnails.zig`

```zig
fn thumbnail(app: *App, ui: *Ui, photo: *const Photo) void {
    const element: zui.Element = .{ .layout = .{ .sizing = .{ .width = .fixed(200), .height = .fixed(150) } } };
    switch (ui.source(.thumbnails).get(photo.id)) {
        .ready => |texture| ui.image(.{ .handle = texture }, element),
        .failed => ui.box(.{ .layout = element.layout, .decoration = .{ .background = .rgb(0x3a2020) } }),
        .idle, .running, .canceled => ui.box(.{ .layout = element.layout, .decoration = .{ .background = .rgb(0x23232d) } }),
    }
    _ = app;
}

fn decodeThumbnail(load: Thumbnails.Load, io: std.Io, library: *const Library) void {
    if (load.abandoned()) return load.finish(error.Canceled);
    load.finish(library.decodeThumbnail(io, load.key, .{ 200, 150 }));
}

pub fn runLoader(app: *App, ui: *const Ui, io: std.Io) void {
    var to_start = app.sources.thumbnails.toStart(app.waker);
    while (to_start.next()) |load| app.work.async(io, decodeThumbnail, .{ load, io, app.library });

    var to_release = app.sources.thumbnails.toRelease();
    while (to_release.next()) |released| if (released) |texture| texture.unload() else |_| {};

    if (ui.framesSinceRead(.library_scan) > 600) app.sources.library_scan.abandon();
}
```

The raylib renderer's tour loads its thumbnail grid this way and idles at 0% CPU.

<a id="file-watch"></a>

### Watching files · *shipped*

File watching is a host service. A host that offers it declares `zuiFileWatch`, and you point it at any source that takes `zui.FileChange`. the native hosts'`zig build theme` restyles its window a few milliseconds after the theme file is saved.

`src/theme.zig`

```zig
pub fn init(app: *App, start: zui_app.Start(App)) !void {
    if (@hasDecl(App.Host, "zuiFileWatch")) {
        try App.Host.zuiFileWatch.watch(start.host, "themes", .of(&app.sources.theme_files));
    }
}

fn reloadThemeOnSave(app: *App, ui: *Ui) void {
    var changes = ui.source(.theme_files).items();
    while (changes.next()) |change| switch (change.kind) {
        .modified, .added, .renamed_to => if (std.mem.endsWith(u8, change.path.slice(), ".theme")) app.reloadTheme(change.path.slice()),
        .rescan => app.reloadTheme(app.theme_path),
        else => {},
    };
}
```

<a id="services"></a>

### Host services · *shipped*

Services are what the system does for an application: the clipboard, notifications, file dialogs, opening a URL, menus. Each is an optional host declaration with a checked shape. They are work, so declaration only notes that you want one, and you call it between frames, from `zuiLoader`, through `zui_app.ServicesOf(Host)`, whose `has_*` guards are known at compile time. Every call returns at once, and its answer is published into a source you choose, so a replay sees what the user chose without opening a dialog. the native Windows host reads and writes the clipboard, opens URLs, refusing paths and `file:` URLs, shows notifications as toasts, shows the shell's file dialogs, answering the paths chosen, and shows Windows' own context menus and menu bars, answering the item chosen. The native Linux host reads and writes the clipboard through the compositor's selection, shows notifications through the desktop's notification daemon, shows the desktop portal's file dialogs and hands URLs to the portal; Wayland has no native menus, so it declares none. the native hosts'`zig build services` calls every one of them from a button and shows each answer beside it.

`src/app.zig`

```zig
const services = zui_app.ServicesOf(App.Host);
const paste: zui.ServiceRequest = .of("paste");
const photo_menu: zui.ServiceRequest = .of("photo menu");
const rename: zui.MenuItemId = @enumFromInt(1);
const reveal: zui.MenuItemId = @enumFromInt(2);

pub fn zuiDeclare(app: *App, ui: *Ui) void {
    if (ui.chordPressed(.{ .key = .v, .modifiers = .{ .control = true } })) app.wants_paste = true;
    if (ui.contextRequested(.of("photo"))) if (ui.primaryPointer()) |pointer| {
        app.menu_at = pointer.position;
    };
    var replies = ui.source(.replies).items();
    while (replies.next()) |reply| {
        if (reply.request == paste and reply.kind == .clipboard_text) app.insert(reply.text());
        if (reply.request == photo_menu and reply.kind == .menu_item_chosen and reply.menu_item == rename) app.beginRename();
    }
}

pub fn zuiLoader(app: *App, _: *const Ui, _: std.Io) void {
    if (services.has_clipboard and app.wants_paste) {
        app.wants_paste = false;
        services.clipboard.read(app.host, paste, .of(&app.sources.replies)) catch {};
    }
    if (services.has_menus) if (app.menu_at) |position| {
        app.menu_at = null;
        const items = [_]zui.MenuItem{ .{ .id = rename, .label = "Rename", .shortcut = .{ .key = .f2 } }, .separator, .{ .id = reveal, .label = "Show in folder" } };
        services.menus.popup(app.host, .main, photo_menu, &items, position, .of(&app.sources.replies)) catch {};
    };
}
```

<a id="modules"></a>

## 05. Widgets, the inspector and `zui_app`

Optional modules built only on the public API. Each one is a separate import.

<a id="widgets"></a>

### `zui_widgets` · *shipped*

Button, checkbox, slider (for any integer or float, with step snapping and keyboard control), single-line text field with caret and IME support, dropdown (from a list of labels or straight from an enum), disclosure, labeled row and labels. Each takes the context and an id and returns what changed this frame.

`src/ui/settings.zig`

```zig
const zui_widgets = @import("zui_widgets");

pub const widgets: zui_widgets.Widgets(Ui, zui_widgets.DefaultSkin(Ui)) = .{ .skin = .{} };

pub const Settings = struct {
    grid_columns: u8 = 5,
    thumbnail_quality: Quality = .balanced,
    show_hidden: bool = false,
    export_scale: f32 = 1,
    library_name: zui_widgets.EditableText,
    library_name_buffer: [64]u8 = undefined,

    pub const Quality = enum { fast, balanced, sharp };
};

fn settingsPanel(app: *App, ui: *Ui) void {
    const settings = &app.settings;
    ui.open(.{ .id = .of("settings"), .layout = .{ .direction = .top_to_bottom, .padding = .all(16), .child_gap = 10, .sizing = .{ .width = .fixed(420) } } });
    defer ui.close();

    widgets.labeledRow(ui, "Library name");
    const name = widgets.textField(ui, .of("library_name"), &settings.library_name, .{ .placeholder = "My photos" });
    ui.close();
    if (name.submitted) app.renameLibrary(settings.library_name.slice());

    widgets.labeledRow(ui, "Columns");
    if (widgets.slider(ui, .of("columns"), &settings.grid_columns, .{ .min = 2, .max = 10 })) app.columns = settings.grid_columns;
    ui.close();

    widgets.labeledRow(ui, "Thumbnails");
    if (widgets.dropdownEnum(ui, .of("quality"), &settings.thumbnail_quality, .{})) app.invalidateThumbnails();
    ui.close();

    _ = widgets.checkbox(ui, .of("show_hidden"), "Show hidden files", &settings.show_hidden, .{});

    if (widgets.disclosure(ui, .of("export_section"), "Export", &app.export_open)) {}
    if (app.export_open) {
        widgets.labeledRow(ui, "Scale");
        _ = widgets.slider(ui, .of("export_scale"), &settings.export_scale, .{ .min = 0.25, .max = 4, .step = 0.25 });
        ui.close();
    }

    if (widgets.button(ui, .of("save_settings"), "Save", .{ .disabled = !app.settings_dirty })) app.saveSettings();
}
```

`labeledRow` opens a row that you close yourself after declaring the control. That's flexible, but it's an easy thing to forget, and an unbalanced tree is caught only at the end of the frame.

<a id="widget-theme"></a>

### Theming widgets · *shipped*

A widget set is styled by a skin: any struct that declares `zuiStyle(part, state, environment)` and returns a `zui_widgets.Style(Ui)` for each element a widget draws, so a theme pack restyles every widget without forking it. The skin reads the environment, so it follows dark mode, contrast and text size, and the style's `focus_ring` is drawn while a control has focus. A mistake in a skin fails to compile with a message naming it. `zui_widgets.DefaultSkin(Ui)` is zui's own skin: a `Theme` and an optional `dark_theme`, chosen from the environment each frame.

`src/ui/settings.zig`

```zig
const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DefaultSkin(Ui));

const light: Widgets.Skin.Theme = .{
    .text = .{ .color = .rgb(0x23232b) },
    .muted_text_color = .rgb(0x6a6a7a),
    .control = .init(.{
        .idle = .rgb(0xe8e8ee),
        .hovered = .rgb(0xdcdce6),
        .pressed = .rgb(0x4a6ad0),
        .focused = .rgb(0xe8e8ee),
        .disabled = .rgb(0xf0f0f3),
    }),
    .field_background = .white,
    .border_color = .rgb(0xc8c8d4),
    .popup_background = .white,
    .corner_radius = 6,
    .control_height = 32,
    .label_width = 120,
};

pub const widgets: Widgets = .{ .skin = .{ .theme = light, .dark_theme = .{} } };
```

Or bring your own look:

`src/ui/flat_skin.zig`

```zig
const FlatSkin = struct {
    accent: zui.Color = .rgb(0x2f6fed),

    pub fn zuiStyle(skin: *const FlatSkin, part: zui_widgets.Part, state: zui.WidgetState, environment: *const zui.Environment) zui_widgets.Style(Ui) {
        const dark = environment.theme == .dark;
        const ink: zui.Color = if (state == .disabled) .rgb(0x808080) else if (dark) .rgb(0xf0f0f0) else .rgb(0x202020);
        const scale = environment.text_scale;
        const base: zui_widgets.Style(Ui) = .{
            .text = .{ .size = 15 * scale, .color = ink },
            .focus_ring = .{ .color = skin.accent, .widths = .all(2) },
            .size = .{ 16, 28 * scale },
            .padding = .symmetric(10, 0),
            .gap = 6,
        };
        return switch (part) {
            .button, .dropdown => style: {
                var control = base;
                control.background = if (state == .pressed) skin.accent else if (dark) .rgb(0x303030) else .rgb(0xe6e6e6);
                break :style control;
            },
            .slider_filled, .checkbox_box_checked => style: {
                var filled = base;
                filled.background = skin.accent;
                break :style filled;
            },
            else => base,
        };
    }
};

pub const widgets: zui_widgets.Widgets(Ui, FlatSkin) = .{ .skin = .{} };
```

<a id="reflect"></a>

### `zui_reflect`: an editor from any struct · *shipped*

`inspector` walks a struct with `@typeInfo` and declares an editor per field. A `bool` gets a checkbox, a number with min and max gets a slider, other numbers get − and + buttons, an enum gets a dropdown, `EditableText` gets a text field, a string is shown read-only, and a nested struct gets a collapsible section. Options live beside the type in `zui_inspector`, and a misspelled field name there fails to compile.

`src/debug_panel.zig`

```zig
const zui_reflect = @import("zui_reflect");

const RenderTuning = struct {
    exposure: f32 = 0,
    contrast: f32 = 1,
    tone_map: enum { linear, reinhard, aces } = .aces,
    show_clipping: bool = false,
    preview_size: u16 = 1024,
    cache: CacheTuning = .{},
    frames_rendered: u64 = 0,

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
        .exposure = .{ .min = -4, .max = 4, .step = 0.1 },
        .contrast = .{ .min = 0.5, .max = 2 },
        .preview_size = .{ .label = "Preview edge (px)", .step = 256 },
        .frames_rendered = .{ .hidden = true },
    } };
};

const CacheTuning = struct {
    max_thumbnails: u32 = 256,
    evict_after_frames: u32 = 120,
};

fn debugPanel(app: *App, ui: *Ui) void {
    if (zui_reflect.inspector(widgets, ui, .of("render_tuning"), &app.render_tuning)) {
        app.renderer_settings_changed = true;
    }
}
```

<a id="zui-debug"></a>

### `zui_debug`: the element tree and what's under the pointer · *shipped*

`zui_debug.Inspector(Ui)` is a panel over `Frame.inspect`, floating at the right edge of the window. It opens with the frame's diagnostics: each limit exceeded, named by its `limits` field with what the frame needed, the first element past it, repeated ids, an unbalanced tree and refused publishes. Then come the fallbacks in effect: each optional command the renderer does not draw and what was drawn instead, colors clamped for a renderer without `zui_extended_color`, and whatever you hand `reportRun`, such as `zui_app`'s `Report` of what the host and renderer lack. Below them it lists the element tree, one row per element, indented by depth, with its name (its id in a build without `-Dzui-debug`), kind and size, and above it the element under the pointer: its rectangle, flags, and each field of its layout, decoration, effects, floating and text style that differs from the default. `observe` copies what it shows out of a frame after `endFrame`, so the frame is released as usual, and `declare` declares the panel in the next frame. Its own rows never appear in the tree, and while the pointer is over the panel, the element it showed stays. It sits in your application's state, sized by `limits.max_elements`, and allocates nothing. Make `zui_debug.ZoneTimer(Inner)` the context's tracer and hand it a clock with `useClock(io)`, and the panel adds a *Performance* section: each zone that ran, the steps of `beginFrame` and `endFrame` indented under them, with its time in the last frame and its mean and peak over the last 60, in milliseconds. The timer passes every zone on to `Inner`, so `zui_tracy.Tracer` still sees them, or to nothing for `void`; with any other tracer the inspector keeps no times. On `zui_app`, the `zuiObserve` hook hands you each frame on the UI thread before it is submitted; in a loop of your own, call `observe` after `endFrame`.

`src/app.zig`

```zig
const zui_debug = @import("zui_debug");

const ZoneTimer = zui_debug.ZoneTimer(zui_tracy.Tracer);
const Ui = zui.Context(zui_app.contextConfig(zui_sokol.Renderer, .{ .Text = Fonts, .features = .{ .Tracer = ZoneTimer } }));

const App = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = zui_sokol.Renderer;
    pub const Text = Fonts;

    inspector: zui_debug.Inspector(Ui) = .{},
    inspecting: bool = false,

    pub fn init(app: *App, start: zui_app.Start(App)) !void {
        app.* = .{};
        ZoneTimer.useClock(start.io);
    }

    pub fn zuiDeclare(app: *App, ui: *Ui) void {
        if (ui.chordPressed(.{ .key = .f12 })) app.inspecting = !app.inspecting;
        declareDocuments(app, ui);
        if (app.inspecting) app.inspector.declare(ui);
    }

    pub fn zuiObserve(app: *App, ui: *const Ui, frame: *const Ui.Frame) void {
        if (app.inspecting) app.inspector.observe(frame, if (ui.primaryPointer()) |pointer| pointer.position else null);
    }
};
```

The panel's theme is a `zui_debug.PanelTheme(FontId, Color)`, and it reloads from a ZON file while the application runs. Set the inspector's `theme_file` to a directory and a file name within it, have the host's file watch publish that directory's changes into a `zui_async.Stream(zui.FileChange, ...)` among your sources, and keep a `zui_async.Latest` of the theme beside it. `declareWithThemeFrom` takes their field names: it notes a change to the file, or a `.rescan`, and draws the panel in the theme the `Latest` last delivered. Between frames, `loadTheme(io)` reads and parses the file when it changed and hands you the theme to publish, with no allocation; a file that does not parse, as one caught half written, is an error you can log, and the panel keeps its theme until the file changes again. In the file each color is a `0xrrggbbaa` and every field is optional. A replay restyles from the delivered theme without reading a file.

`src/debug_theme.zig`

```zig
const DebugTheme = zui_debug.PanelTheme(u16, zui.Color);

const Sources = struct {
    debug_theme_files: zui_async.Stream(zui.FileChange, .{ .capacity = 32 }) = .{},
    debug_theme: zui_async.Latest(DebugTheme) = .{},
};

fn watchDebugTheme(app: *App, io: std.Io) !void {
    app.inspector.theme_file = .{ .directory = try std.Io.Dir.cwd().openDir(io, "themes", .{}), .name = "debug.zon" };
    try Host.zuiFileWatch.watch(app.host, "themes", .of(&app.sources.debug_theme_files));
}

fn declareInspector(app: *App, ui: *Ui) void {
    app.inspector.declareWithThemeFrom(ui, .{ .file_changes = .debug_theme_files, .theme = .debug_theme });
}

fn loadBetweenFrames(app: *App, io: std.Io, waker: zui.Waker) void {
    if (app.inspector.loadTheme(io)) |loaded| {
        if (loaded) |theme| waker.wakeIf(app.sources.debug_theme.publish(theme));
    } else |err| std.log.warn("themes/debug.zon did not load: {t}", .{err});
}
```

`themes/debug.zon`

```zig
.{ .width = 420, .background = 0x101820e8, .heading = 0xffcc66ff }
```

<a id="zui-app"></a>

### `zui_app`: the whole loop from one call · *shipped*

You name a host and a renderer and write `zuiDeclare`, and `zui_app.run` does the rest. It opens the window, builds records, submits on a render thread when the renderer allows it, paces frames, sleeps when idle, and reports once what it's running with and each limit exceeded. The optional hooks are `init`, `deinit`, `zuiLoader` after each frame, `zuiObserve` with each frame before it is submitted, for an inspector, and `zuiRecord` for your own zoom and synthetic events. `contextConfig` derives the `Config` from the renderer's declarations.

`src/app.zig`

```zig
const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_sokol = @import("zui_sokol");
const zui_host = @import("zui_host");

pub const App = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = zui_sokol.Renderer;
    pub const Text = Fonts;
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .Text = Fonts, .Sources = AppSources }));

    sources: AppSources = .{},
    waker: zui.Waker = undefined,
    work: std.Io.Group = .init,
    settings: Settings = .{},
    zoom: f32 = 1,

    pub fn init(app: *App, start: zui_app.Start(App)) !void {
        app.waker = start.waker;
        try App.Host.zuiFileWatch.watch(start.host, "themes", .of(&app.sources.theme_files));
    }

    pub fn zuiDeclare(app: *App, ui: *Ui) void {
        declareShell(app, ui);
        renameDialog(app, ui);
        shortcuts(app, ui);
        handleSystemEvents(app, ui);
    }

    pub fn zuiLoader(app: *App, ui: *const Ui, io: std.Io) void {
        runLoader(app, ui, io);
    }

    pub fn zuiRecord(app: *App, record: *zui.RecordBuilder) void {
        record.params.zoom = app.zoom;
    }
};

pub fn main(init: std.process.Init) !void {
    try zui_app.run(App, init, .{
        .title = "Darkroom",
        .size = .{ 1440, 900 },
        .material = .window,
        .notify = zui_app.logNotice,
    });
}
```

Some of the notices it logs: *"limits.max_elements is 4096, but a frame needed 5210; what fit was drawn"*, and *"the full source `import_log` refused 12 publishes; raise its capacity"*. On raylib, the first frame appears about 290 ms after the process starts, and all but 5 ms of that is raylib opening its window.

<a id="many-windows"></a>

### Many windows · *shipped*

Declare `zuiDeclare(app, ui, window)` and every window gets a context of its own: each hook takes the window, `zuiSources(app, window)` gives each window its sources, and data shared between windows is published into each. `Start(App).windows` opens and closes windows between frames, never in declaration, and on a host with one window `open` is a compile error unless guarded by `has_many_windows`. Each turn declares only the windows with input or a frame due, then waits once for all; the run ends with the last window. A renderer that keeps a swapchain per window declares `zuiAttachSurface` and `zuiDetachSurface`.

`src/app.zig`

```zig
const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_async = @import("zui_async");
const zui_sokol = @import("zui_sokol");
const zui_host = @import("zui_host");

const WindowSources = struct { selection: zui_async.Latest(PhotoId) = .{} };

pub const App = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = zui_sokol.Renderer;
    pub const Text = Fonts;
    pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .Text = Fonts, .Sources = WindowSources }));

    windows: zui_app.Windows(App) = undefined,
    waker: zui.Waker = undefined,
    main_sources: WindowSources = .{},
    loupe_sources: WindowSources = .{},
    loupe: ?zui.WindowId = null,
    wants_loupe: bool = false,
    selected: ?PhotoId = null,

    pub fn init(app: *App, start: zui_app.Start(App)) !void {
        app.* = .{ .windows = start.windows, .waker = start.waker };
    }

    pub fn zuiSources(app: *App, window: zui.WindowId) *WindowSources {
        return if (window == app.loupe) &app.loupe_sources else &app.main_sources;
    }

    pub fn zuiDeclare(app: *App, ui: *Ui, window: zui.WindowId) void {
        if (window == app.loupe) return declareLoupe(ui, ui.source(.selection).get());
        if (declareLibrary(ui)) |photo| app.selected = photo;
        if (app.loupe == null and openLoupeClicked(ui)) app.wants_loupe = true;
    }

    pub fn zuiLoader(app: *App, _: *const Ui, window: zui.WindowId, _: std.Io) void {
        if (window != .main) return;
        if (app.wants_loupe and zui_app.Windows(App).has_many_windows) {
            app.wants_loupe = false;
            app.loupe = app.windows.open(.{ .title = "Loupe", .size = .{ 640, 640 } }) catch null;
        }
        if (app.selected) |photo| app.waker.wakeIf(app.loupe_sources.selection.publish(photo));
    }

    pub fn zuiWindowClosed(app: *App, window: zui.WindowId) void {
        if (window == app.loupe) {
            app.loupe = null;
            app.loupe_sources = .{};
        }
    }
};
```

On the native Windows and Linux hosts, up to four windows open at once, and the sokol renderer draws each through its own swapchain on one Direct3D 11 device, or its own EGL surface on one OpenGL context: two windows animating at once each draw at the rate one alone does, a 144 Hz display's on Windows, and two idle windows use next to no CPU.

<a id="own-loop"></a>

### Your own loop: stepping a `Session` · *shipped*

When an editor, a game engine or an existing app already owns the loop and the window, step a `zui_app.Session(App)` from its frame instead of calling `run`. Each `step` polls the host, declares and submits only the windows that are due, and returns when it next wants to run, or null once the window has closed. It never blocks, so you get `zui_app`'s render thread, host requests and notices without handing it your loop. The host is a small one over the window you already have: it declares the window half (`zuiPoll`, `zuiWaker`, `zuiSurface`, `zuiApply`) and neither `zuiWait` nor `zuiRun`. Calling `run` with it, or `wait`, is a compile error that tells you to step a `Session`.

`src/panel.zig`

```zig
const zui_app = @import("zui_app");

pub fn runPanel(editor: *Editor, gpa: std.mem.Allocator, io: std.Io) !void {
    var session: zui_app.Session(PanelApp) = undefined;
    try session.start(.{ .gpa = gpa, .io = io }, .{ .title = "Outline" });
    defer session.stop();

    while (editor.running()) {
        editor.beginFrame();
        if (try session.step()) |next| editor.redrawAt(next) else break;
        editor.endFrame();
    }
}
```

A host whose platform owns the loop, as AppKit's or a browser page's does, declares `zuiRun` instead, and `run` hands it a `zui.Driver` to call from the platform's callbacks.

<a id="contracts"></a>

## 06. The backend contracts

zui draws nothing and opens no windows itself. Renderers and hosts are plain types checked at compile time, with conformance suites each runs in its package's CI job. Today there are the raylib renderer and adapter host in `renderers/raylib/`, the sokol renderer in `renderers/sokol/`, the terminal renderer and host in `renderers/terminal/`, and, in `hosts/native/`, the native Windows host (message loop on its own thread, per-monitor DPI, Mica, IME, clipboard, opening URLs, dropped files, file watching), and the native Linux host, on Wayland so far (many windows, fractional and buffer scale, pointer, wheel, keys through the compositor's keymap with their repeats, typed text, focus, cursor shapes, clipboard, dropped files, file watching through inotify, notifications, the portal's file dialogs and opening URLs, the environment from the desktop portal and UPower over D-Bus, and signals, sleep and waking as lifecycle events); and, in `hosts/web/`, the web host, which runs an application in a Web Worker and draws its frames over `zui_wire` through the WebGL renderer in `renderers/webgl/`.

<a id="renderer"></a>

### Writing a renderer · *shipped*

A renderer declares `zuiSubmit`, the surface kinds it draws into, and optionally the extra commands it supports and its payload types. `RenderCommand` is generated from exactly those declarations, so an exhaustive `switch` names only what this renderer draws. A terminal renderer handles five variants. A renderer declaring `zui_render_thread` is submitted from a thread of its own by zui_app.

`zui-d3d11/src/renderer.zig`

```zig
const zui = @import("zui");

pub const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.win32);
    pub const zui_render_thread = true;
    pub const ImageHandle = TextureId;

    device: Device,
    batch: QuadBatch,
    scissors: ScissorStack,

    pub fn init(self: *Renderer, surface: zui.Surface) !void {
        self.device = try .create(surface.win32.hwnd);
    }

    pub fn zuiSubmit(self: *Renderer, surface: zui.Surface, frame: anytype) !void {
        _ = surface;
        self.batch.begin(&self.device);
        for (frame.commands()) |command| switch (command.payload) {
            .rectangle => |rectangle| self.batch.roundedRect(command.bounds, rectangle.color, rectangle.corner_radius),
            .border => |border| self.batch.roundedOutline(command.bounds, border.color, border.widths, border.corner_radius),
            .text => |text| self.batch.glyphs(command.bounds, text.content, text.style),
            .image => |image| self.batch.roundedTexturedQuad(command.bounds, image.handle, image.tint, image.corner_radius),
            .clip_begin => |rect| self.batch.pushScissor(self.scissors.push(rect)),
            .clip_end => self.batch.pushScissor(self.scissors.pop()),
        };
        try self.batch.present();
    }
};

pub fn config(overrides: zui.Config) zui.Config {
    comptime zui.checkRenderer(Renderer);
    var result = overrides;
    result.ImageHandle = Renderer.ImageHandle;
    return result;
}
```

Declaring `pub const zui_commands: zui.CommandSet = .initMany(&.{ .gradient, .shadow, .backdrop_blur })` adds `gradient`, `shadow` and `backdrop_blur` arms to that switch, for the [effects](#effects) elements declare. A backdrop blur averages the pixels as the target stores them, sampling only inside its bounds. A gradient's `colorAt` gives its color at any point, in OKLab, for a renderer that draws it in strips. A renderer with shaders of its own sets `pub const MaterialHandle` and declares `.material`; its `material` arm gets the handle, the fallback color and the corner radius, for the [materials](#materials) elements declare.

<a id="host"></a>

### Writing a host · *shipped*

A host polls the OS into a `RecordBuilder` without blocking, gives a waker that producers call from any thread, hands out a surface, and applies a frame's requests. Then it says who turns the loop: `zuiWait`, to sleep as `NextFrame` says while `zui_app.run` loops; `zuiRun`, when the platform owns the loop and the host calls the `zui.Driver` it is handed from its callbacks; or neither, for a window whose application steps a `Session` itself. A library that reports input as state rather than events, as raylib does, uses `InputSampler` to turn snapshots into the event log. `checkHostAndRenderer` fails to compile when a host and renderer share no surface kind.

`zui-glfw/src/host.zig`

```zig
pub const Host = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.library);
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .one };

    window: *glfw.Window,
    sampler: zui.InputSampler = .{},
    sampled: [128]zui.Event = undefined,
    clock: Clock,

    pub fn init(self: *Host, io: std.Io, window: zui.WindowOptions) !void {
        self.window = try glfw.createWindow(window.size, window.title);
        self.clock = .start(io);
    }

    pub fn deinit(self: *Host) void {
        self.window.destroy();
    }

    pub fn zuiPoll(self: *Host, window: zui.WindowId, record: *zui.RecordBuilder) bool {
        _ = window;
        glfw.pollEvents();
        if (self.window.shouldClose()) return false;

        const now = self.clock.now();
        record.begin(.{ .now = now, .viewport = self.window.logicalSize(), .scale = self.window.contentScale() });
        const sample: zui.InputSampler.Sample = .{
            .pointer = self.window.cursorPosition(),
            .buttons = self.window.pressedButtons(),
            .wheel = self.window.takeScroll(),
            .keys_pressed = self.window.takeKeysPressed(),
            .modifiers = self.window.modifiers(),
            .text = self.window.takeTypedText(),
        };
        for (self.sampler.sample(now, sample, &self.sampled)) |event| record.append(event);
        return true;
    }

    pub fn zuiWaker(self: *Host) zui.Waker {
        return .{ .context = self, .wakeFn = postEmptyEvent };
    }

    pub fn zuiWait(self: *Host, next: zui.NextFrame) void {
        switch (next) {
            .immediately => {},
            .at => |instant| glfw.waitEventsTimeout(self.clock.secondsUntil(instant)),
            .on_event => glfw.waitEvents(),
        }
    }

    pub fn zuiSurface(_: *Host, _: zui.WindowId) zui.Surface {
        return .library;
    }

    pub fn zuiApply(self: *Host, _: zui.WindowId, requests: zui.HostRequests) void {
        self.window.setCursor(requests.cursor);
        if (requests.text_input) |area| self.window.setImePosition(area.caret);
    }

    fn postEmptyEvent(_: *anyopaque) void {
        glfw.postEmptyEvent();
    }
};
```

<a id="conformance"></a>

### Conformance suites · *shipped*

A backend proves its contract by running zui's suite in its package's CI job, through a harness that does what only the backend knows how to do. The renderer suite draws a reference scene, deep clips and out-of-bounds commands, then reads the pixels back. The host suite checks event order, sticky and cross-thread wakes, and waits. A host whose platform owns the loop runs the pushed suite, which hands its `zuiRun` a scripted `zui.Driver` and checks that each step is scheduled as the one before asked and that a lost surface is reported and given back; a host its application steps runs the stepped suite, which checks that a poll never blocks. All three renderers pass. `findRendererViolation` and `findHostViolation` return the first violation instead of failing.

`zui-d3d11/src/conformance.zig`

```zig
const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const Renderer = @import("renderer.zig").Renderer;

const Harness = struct {
    pub const config = Renderer.config;
    renderer: Renderer,
    target: OffscreenTarget,

    pub fn beginDraw(self: *Harness) zui.Surface { return self.target.surface(); }
    pub fn pixel(self: *Harness, point: [2]u32) zui.Color { return self.target.readPixel(point); }
};

test "the D3D11 renderer passes zui's renderer suite" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();
    try zui_testing.expectRendererConforms(Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io });
}
```

The harness method signatures above are simplified. The exact set of declarations a harness needs is listed in the doc comments of `expectRendererConforms` and `expectHostConforms`. `renderers/raylib/`, `renderers/sokol/` and `renderers/terminal/` each have a `src/conformance.zig` you can copy.

<a id="tooling"></a>

## 07. Testing, remote rendering and profiling

The strongest part of the developer experience today. UIs are tested by id and independent of fonts, sessions record and replay, frames travel over a socket, and every step of a frame shows up in Tracy.

<a id="driver"></a>

### Driver tests by element id · *shipped*

`FixedMetricsText` makes every character 8×16 at size 16, so layout assertions hold on any machine. `Driver` runs frames of your declare function and synthesizes input aimed at elements by id: `click`, `clickAt`, `tap`, `hover`, `drag`, multi-finger `dragFingers` and `pinch`, `pressKeys`, `typeText`, `focus`, and `frameDelivering` to inject source deliveries.

`tests/rename.zig`

```zig
const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");

const TestUi = zui.Context(.{ .Text = zui_testing.FixedMetricsText(u16) });

test "renaming a photo from the context menu" {
    var text: zui_testing.FixedMetricsText(u16) = .{};
    var ui: TestUi = try .init(std.testing.allocator, std.testing.io, &text);
    defer ui.deinit(std.testing.allocator);
    var driver: zui_testing.Driver(TestUi) = .{ .ui = &ui };

    var app: TestApp = try .withPhotos(std.testing.allocator, &.{ "IMG_0001.jpg", "IMG_0002.jpg" });
    defer app.deinit();

    _ = try driver.frame(&app, TestApp.declare, &.{});
    app.context_menu = .{ .photo = 1, .position = .{ 100, 100 } };
    _ = try driver.click(&app, TestApp.declare, .of("menu_rename"));
    _ = try driver.typeText(&app, TestApp.declare, "Harbour at dusk");
    const frame = try driver.pressKeys(&app, TestApp.declare, &.{.enter});

    try std.testing.expectEqualStrings("Harbour at dusk", app.photos[1].file_name);
    try std.testing.expect(frame.rectOf(.of("rename_dialog")) == null);
}

test "the column slider snaps to whole columns" {
    var text: zui_testing.FixedMetricsText(u16) = .{};
    var ui: TestUi = try .init(std.testing.allocator, std.testing.io, &text);
    defer ui.deinit(std.testing.allocator);
    var driver: zui_testing.Driver(TestUi) = .{ .ui = &ui };
    var app: TestApp = .{};

    _ = try driver.frame(&app, TestApp.declare, &.{});
    _ = try driver.drag(&app, TestApp.declare, .of("columns"), .{ 0, 0.5 }, .{ 1, 0.5 });
    try std.testing.expectEqual(@as(u8, 10), app.settings.grid_columns);
}
```

<a id="snapshots"></a>

### Golden snapshots and command checks · *shipped*

`expectSnapshot` renders a frame's commands to one line each, naming only the elements in the id set you pass, so unrelated internal ids never break the golden output. `checkCommands` asserts structural invariants: bounds are valid, z never decreases, and clips are balanced.

`tests/toolbar.zig`

```zig
test "the toolbar's layout" {
    var text: zui_testing.FixedMetricsText(u16) = .{};
    var ui: TestUi = try .init(std.testing.allocator, std.testing.io, &text);
    defer ui.deinit(std.testing.allocator);
    var driver: zui_testing.Driver(TestUi) = .{ .ui = &ui };
    var app: TestApp = .{ .album_name = "Iceland" };

    const frame = try driver.frame(&app, TestApp.declareToolbar, &.{});
    try zui_testing.checkCommands(frame.commands());
    try zui_testing.expectSnapshot(frame.commands(), zui.ids(.{ "toolbar", "import" }),
        \\rectangle id=toolbar x=0 y=0 w=800 h=44 color=#202028
        \\border id=toolbar x=0 y=0 w=800 h=44 color=#2c2c38
        \\text x=12 y=14 w=60 h=15 size=15 color=#ffffff "Darkroom"
        \\text x=80 y=15 w=42 h=13 size=13 color=#9a9aae "Iceland"
        \\rectangle id=import x=693 y=6 w=95 h=32 color=#2c2c3c
        \\text x=705 y=15 w=52 h=13 size=13 color=#ffffff "Import…"
        \\
    );
}
```

The golden text above is illustrative. The format, one line per command in paint order, matches what `snapshot` writes.

<a id="replay"></a>

### Record and replay · *shipped*

`ui.relayTo(listener)` hands a listener each record as it is applied, together with what each source delivered. `Recording` keeps them, and `driver.replay` runs them again with no loader. A recorded session of the sokol renderer's tour replays to identical commands without starting any work. This makes a bug report a file you can step through.

`tests/replay.zig`

```zig
test "a recorded import session replays to the same frames" {
    const gpa = std.testing.allocator;
    var recording: zui_testing.Recording(TestUi) = try .init(gpa, .{ .records = 600 });
    defer recording.deinit(gpa);

    var text: zui_testing.FixedMetricsText(u16) = .{};
    var live_ui: TestUi = try .init(gpa, std.testing.io, &text);
    defer live_ui.deinit(gpa);
    live_ui.relayTo(recording.listener());
    var live: zui_testing.Driver(TestUi) = .{ .ui = &live_ui };
    var live_app: TestApp = .{};
    _ = try live.click(&live_app, TestApp.declare, .of("import"));
    const last_live = try live.typeText(&live_app, TestApp.declare, "~/Pictures/Iceland");
    const expected_count = last_live.commands().len;

    var replay_ui: TestUi = try .init(gpa, std.testing.io, &text);
    defer replay_ui.deinit(gpa);
    var replay: zui_testing.Driver(TestUi) = .{ .ui = &replay_ui };
    var replay_app: TestApp = .{};
    var last_replayed: *const TestUi.Frame = undefined;
    for (recording.records()) |*record| last_replayed = try replay.replay(&replay_app, TestApp.declare, record);

    try std.testing.expectEqual(expected_count, last_replayed.commands().len);
}
```

<a id="wire"></a>

### `zui_wire`: sessions as bytes · *shipped*

`zui_wire` writes records in and frames out as bytes, with each frame encoded as the changes from the one before. The sokol renderer's tour averages 240 bytes a frame against 24 KB for full frames. The header carries a fingerprint of the fonts, so a reader that measures with other fonts refuses the stream instead of drawing misplaced text.

`src/session_recorder.zig`

```zig
const zui_wire = @import("zui_wire");

const SessionRecorder = struct {
    encoder: zui_wire.Encoder(Ui),
    file_writer: *std.Io.Writer,

    fn start(self: *SessionRecorder, gpa: std.mem.Allocator, fonts: *const Fonts) !void {
        self.encoder = try .init(gpa);
        try zui_wire.writeHeader(self.file_writer, zui_wire.fingerprintOf(fonts));
    }

    fn onRecord(self: *SessionRecorder, record: *const Ui.FrameRecord) void {
        self.encoder.writeRecord(self.file_writer, record) catch {};
    }

    fn onFrame(self: *SessionRecorder, frame: *const Ui.Frame) void {
        self.encoder.writeFrame(self.file_writer, frame) catch {};
    }
};

fn playBack(gpa: std.mem.Allocator, reader: *std.Io.Reader, renderer: *Renderer, surface: zui.Surface) !void {
    var decoder: zui_wire.Decoder(Ui) = try .init(gpa, .of(Ui));
    defer decoder.deinit(gpa);
    try zui_wire.readHeader(reader, zui_wire.fingerprintOf(renderer));
    while (try decoder.next(reader)) |message| switch (message) {
        .record => {},
        .frame => |frame| try renderer.zuiSubmit(surface, frame),
    };
}
```

<a id="remote"></a>

### Running in one process, drawing in another · *shipped*

`zui_wire.Host(Ui)` is a host whose surface is a socket, and `zui_wire.Renderer(Ui)` writes frames into it. On the other end, `zui_wire.Client(Ui)` joins any real host and renderer to the socket, sending input one way and drawing frames that come back. the native hosts'`zig build remote` runs the sokol renderer's tour this way. The wire renderer declares `Ui`'s commands, colors and payload types, so an application with images, custom payloads or materials runs over the wire unchanged. The wire host passes the host conformance suite.

`tools/remote_viewer.zig`

```zig
pub fn main(init: std.process.Init) !void {
    var host: NativeHost = undefined;
    try host.init(init.io, .{ .title = "Darkroom (remote)", .size = .{ 1440, 900 } });
    defer host.deinit();
    var renderer: Renderer = undefined;
    try renderer.init(host.zuiSurface(.main));
    defer renderer.deinit();

    const stream = try connectTo(init.io, "127.0.0.1:7420");
    var client: zui_wire.Client(Ui) = undefined;
    try client.init(init.gpa, init.io, stream, .{
        .waker = host.zuiWaker(),
        .fingerprint = zui_wire.fingerprintOf(&renderer),
    });
    defer client.deinit();

    while (try client.frame(&host, &renderer)) {}
}

// On the application side, zui_app runs it unchanged:
const RemoteApp = struct {
    pub const Host = zui_wire.Host(Ui);
    pub const Renderer = zui_wire.Renderer(Ui);
    // ...the same zuiDeclare as App
};
```

<a id="browser"></a>

### Running in a browser · *shipped*

The web host, in `hosts/web/`, runs an application in a browser over `zui_wire`, as the tour runs on the published page. The application is built for `wasm32-freestanding` and runs in a Web Worker on an `Io` that steps to the page's clock. The page sleeps between frames as a native host does: it steps the application when its `ui.nextFrame()` says, at once or at a deadline, or when the canvas's input, a resize or a change of `devicePixelRatio` arrives, sending it that instant and the records its canvas's input wrote, and draws the frame bytes it answers with through WebGL 2, with four samples per pixel, as a native window with `sample_count = 4` smooths its edges, and with the cursor the frame asks for. A worker shares its memory with its threads only on a cross-origin isolated page, so the published page isolates itself with a service worker. Durations inside a frame are timed on the worker's `performance.now()`, imported by the module, since the stepped `Io` holds one instant for the whole frame. Its tasks run only while a frame waits for them, so the page also wakes when the earliest of their sleeps ends, where a native host is woken by a task's thread.

`src/browser_worker.zig`

```zig
// Built for wasm32-freestanding and run in a Web Worker: the web host's page
// passes the instant it woke at and its canvas's records, draws the bytes
// this writes, and sleeps until `darkroomNextWake`.
var ui: Ui = undefined;
var app: App = undefined;
var fonts: Fonts = .{};
var decoder: zui_wire.Decoder(Ui) = undefined;
var encoder: zui_wire.Encoder(Ui) = undefined;
var builder: zui.RecordBuilder = undefined;
var canvas: zui.RecordBuilder.HostParams = .{ .now = .zero, .viewport = .{ 0, 0 } };
var header_written = false;

export fn darkroomFrame(now_milliseconds: f64, records: [*]const u8, record_count: usize, frame_bytes: [*]u8, frame_room: usize) usize {
    const now: zui.Instant = .fromNanoseconds(@intFromFloat(now_milliseconds * std.time.ns_per_ms));
    builder.begin(.{ .now = now, .viewport = canvas.viewport, .scale = canvas.scale });
    var reader: std.Io.Reader = .fixed(records[0..record_count]);
    while (decoder.next(&reader) catch null) |message| switch (message) {
        .record => |record| {
            canvas = .{ .now = now, .viewport = record.params.viewport, .scale = record.params.scale };
            builder.params.viewport = canvas.viewport;
            builder.params.scale = canvas.scale;
            for (record.events) |event| builder.append(event);
        },
        .frame => {},
    };

    ui.beginFrame(&.{ .params = builder.params, .events = builder.events() }, &app.sources);
    app.declare(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);

    var writer: std.Io.Writer = .fixed(frame_bytes[0..frame_room]);
    if (!header_written) zui_wire.writeHeader(&writer, zui_wire.fingerprintOf(&fonts)) catch return 0;
    encoder.writeFrame(&writer, frame) catch return 0;
    header_written = true;
    return writer.end;
}

/// On the page's clock, in milliseconds: 0 for at once, infinity for on input.
export fn darkroomNextWake() f64 {
    return switch (ui.nextFrame(&app.sources)) {
        .immediately => 0,
        .at => |deadline| @as(f64, @floatFromInt(deadline.nanoseconds)) / std.time.ns_per_ms,
        .on_event => std.math.inf(f64),
    };
}
```

A module of your own can also draw its frames in the same WebAssembly instance, with no wire between: `zui_webgl.Renderer` draws into a `.web` surface, laying each frame out and handing it to the page's `FrameDrawer` for that canvas id, through the imports `frameDrawerImports` gives the module.

`src/sketchpad.zig`

```zig
const Ui = zui.Context(zui_app.contextConfig(zui_webgl.Renderer, .{ .Text = zui_truetype.Text }));
var renderer: zui_webgl.Renderer = .{};

export fn sketchpadInit() bool {
    renderer.init(.{ .web = .{ .canvas = 0 } }, &text) catch return false;
    return true;
}

export fn sketchpadDraw() void {
    ui.beginFrame(&.{ .params = params }, &app.sources);
    app.declare(&ui);
    const frame = ui.endFrame();
    defer ui.release(frame);
    renderer.zuiSubmit(.{ .web = .{ .canvas = 0 } }, frame) catch {};
}

// On the page:
//   const drawers = new Map();
//   const { instance } = await WebAssembly.instantiateStreaming(fetch("sketchpad.wasm"), frameDrawerImports(drawers, () => instance.exports.memory));
//   drawers.set(0, new FrameDrawer(canvas));
```

<a id="tracy"></a>

### Profiling with Tracy · *shipped*

A tracer is a type with `zuiBegin` and `zuiEnd` that sees every step of `beginFrame` and `endFrame` as a zone. `zui_tracy.Tracer` sends them to Tracy. Without a tracer, zones are zero-sized and compile to nothing. Behind it, CI counts instructions per benchmark under Callgrind and fails on more than 2% growth over the parent commit.

`src/main.zig`

```zig
const zui_tracy = @import("zui_tracy");

pub const Ui = zui.Context(.{
    .Text = Fonts,
    .features = .{ .Tracer = zui_tracy.Tracer },
});

fn present(renderer: *Renderer, surface: zui.Surface, frame: *const Ui.Frame) !void {
    try renderer.zuiSubmit(surface, frame);
    zui_tracy.frameMark();
}
```

Build with `-Dzui-tracy=true` to link Tracy's client, then connect profiler 0.14.1.

<a id="gaps"></a>

## 08. Declared but not working yet

These names compile, but they don't do anything yet. This list is from `ARCHITECTURE.md` §7 and the roadmap.

- **A host that runs its own loop**: `zuiRun` and the `zui.Driver` it is handed, with `suspendSurfaces` and `resumeSurfaces` for a surface the platform takes away, compile and pass `zui_app`'s tests against a scripted host, but no shipped host declares `zuiRun` yet; macOS, iOS and Android's are to come.
- **Still to come**: Multi-line text editing, the design system (roles, tokens from seeds, density, a type scale, corner shapes and nested corners, and a review of every permutation), theme packs, the inspector over the wire, and more hosts (Linux and web; macOS later).

<a id="dx"></a>

## 09. How the DX is coming along

### Working well

- The declaration API is small: four calls and struct literals cover most layouts, and `defer ui.close()` keeps helpers tidy.
- Mistakes surface at compile time with exact, actionable messages, down to a misspelled inspector option.
- No surprises at run time: no allocation after init, limits that draw what fits and say which number to raise, and zui_app reports each one once.
- Sources are a clean answer to async data in immediate mode. Reading records demand, the loader starts work, and nobody blocks.
- Testing is unusually strong: tests by id that don't depend on fonts, golden snapshots, record and replay, and conformance suites for backends.

### Rough edges

- Writing UI by hand in core is verbose. Nested `.layout = .{ .sizing = .{ .width = ... } }` literals pile up, and static styles are the main relief today.
- Interactive elements take three steps: declare, query by id, then pick colors from the state yourself. Widgets hide it, but there is nothing in between.
- `labeledRow` leaves you to close the row, an asymmetry that's easy to get wrong.
- Only the sokol renderer draws gradients and shadows so far; the raylib and terminal renderers show a gradient as one flat color and no shadow. Only the sokol renderer blurs a backdrop; the others draw its tint. Only the sokol renderer draws a transform; the others draw the element as laid out. Only the sokol renderer draws a material; the others draw its fallback background.
- There's no template project or samples yet. The best reference is the tour, in `apps/tour/`, which every renderer and host runs.

AaronJClausen/zui · **main** @ 075fbbd · Zig 0.16

# zui Feature Tour

Everything a zui consumer can build with today, one feature at a time, each shown in the code you would write. The examples follow one running application: **Darkroom**, a photo library with albums, a thumbnail grid, a viewer and a settings panel.

- **7** modules beside core
- **3** renderers + 1 native host
- **0** allocations after init
- 4,096 boxes: ~50 µs declare, ~90 µs layout

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

Each frame you declare a tree. `open` and `close` bracket a container, `box` is a leaf, and `text` is a leaf with content. An element is a struct literal: `layout` sets direction, sizing, padding, gap and alignment, and `decoration` sets background, border and corner radius. Because `defer ui.close()` keeps the tree balanced, a helper function reads like markup.

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
```

Elements without an `id` get an internal one. Give an element an id when you want to query it, keep state on it, scroll it, or focus it.

<a id="sizing"></a>

### Sizing rules · *shipped*

Each axis takes one `Sizing` rule, with optional `min` and `max`. The grow basis landed in L1: `grow` starts from the content and adds a share of the free space, and `grow_equal` shares the whole width, so columns come out equal whatever they hold.

| Rule | Behaves like | Use it for |
|---|---|---|
| `.fit` | shrink-wrap | buttons, labels, the default |
| `.fixed(44)` | a fixed length | toolbars, icons, thumbnails |
| `.percent(0.3)` | a share of the parent | split panes |
| `.grow` | CSS `flex: auto` | spacers, a content area |
| `.grow_equal` | CSS `flex: 1` | equal columns |
| `.growWeighted(3)` | `flex-grow: 3` | uneven splits |
| `.fitBetween(180, 320)` | fit, clamped | a sidebar that respects its content |

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

zui never touches fonts. You give it a type with `zuiMeasure`, and optionally `zui_thread_safe` to allow parallel measurement and `zuiSegment` to report where a paragraph may break. Without `zuiSegment`, text breaks after spaces. With it, CJK and Thai wrap between characters. A misspelled declaration such as `zui_threadsafe` is a compile error rather than silently ignored.

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

<a id="images"></a>

### Images and self-drawn elements · *shipped*

`ui.image` places the renderer's own image handle. `ui.custom` places a payload your renderer draws itself, such as a 3D viewport or a histogram. Both are leaves that take an `Element`, so they size, clip and hit-test like any box.

`src/ui/viewer.zig`

```zig
const HistogramPayload = struct { photo_id: u64, channel: Channel };

pub const Ui = zui.Context(.{ .Text = Fonts, .ImageHandle = Texture, .CustomData = HistogramPayload });

fn viewer(app: *App, ui: *Ui, photo: *const Photo, texture: Texture) void {
    ui.open(.{ .id = .of("viewer"), .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_alignment = .{ .x = .center } } });
    defer ui.close();

    ui.image(.{ .handle = texture }, .{
        .id = .of("full_image"),
        .layout = .{ .sizing = .{ .width = .grow, .height = .grow } },
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

<a id="floating"></a>

### Floating elements in paint layers · *shipped*

A floating element takes no space in its parent's flow. It attaches to its parent, the viewport, or any element declared earlier in the frame, by matching an anchor point on itself to a point on the target, plus an offset. It paints in layer `z`, escaping its parent's clip. Tooltips, popups, menus and dialogs are all built this way.

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

The host reports the user's settings as events, and `ui.environment()` holds the current values: theme, contrast, reduced motion and transparency, text scale, locale, reading direction, HDR headroom, power, window focus, and whether the system material (Mica) shows behind the window.

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

Files dropped onto the window arrive with their drop position and paths. Lifecycle events cover suspend, resume, a termination request (Ctrl+C, a closing console, the session ending) and low memory. zui-host's Windows host reports all of them.

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

After `endFrame`, the frame has its own `rectOf`, `commands()` and `elementCount()`.

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

zui-raylib's demo loads its thumbnail grid this way and idles at 0% CPU.

<a id="file-watch"></a>

### Watching files · *shipped*

File watching is a host service. A host that offers it declares `zuiFileWatch`, and you point it at any source that takes `zui.FileChange`. zui-host's `zig build theme` restyles its window a few milliseconds after the theme file is saved.

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

<a id="modules"></a>

## 05. Widgets, the inspector and `zui_app`

Optional modules built only on the public API. Each one is a separate import.

<a id="widgets"></a>

### `zui_widgets` · *shipped*

Button, checkbox, slider (for any integer or float, with step snapping and keyboard control), single-line text field with caret and IME support, dropdown (from a list of labels or straight from an enum), disclosure, labeled row and labels. Each takes the context and an id and returns what changed this frame.

`src/ui/settings.zig`

```zig
const zui_widgets = @import("zui_widgets");

pub const widgets: zui_widgets.Widgets(Ui) = .{};

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

A widget set carries a `Theme` and an optional `dark_theme`, chosen from the environment each frame. The theme sets colors per `WidgetState`, metrics, popup layer and indicator glyphs.

`src/ui/settings.zig`

```zig
const Widgets = zui_widgets.Widgets(Ui);

const light: Widgets.Theme = .{
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

pub const widgets: Widgets = .{ .theme = light, .dark_theme = .{} };
```

Skins (`Widgets(Ui, Skin)`) are planned to replace this struct (item K5).

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

<a id="zui-app"></a>

### `zui_app`: the whole loop from one call · *shipped*

You name a host and a renderer and write `zuiDeclare`, and `zui_app.run` does the rest. It opens the window, builds records, submits on a render thread when the renderer allows it, paces frames, sleeps when idle, and reports once what it's running with and each limit exceeded. The optional hooks are `init`, `deinit`, `zuiLoader` after each frame and `zuiRecord` for your own zoom and synthetic events. `contextConfig` derives the `Config` from the renderer's declarations.

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

<a id="contracts"></a>

## 06. The backend contracts

zui draws nothing and opens no windows itself. Renderers and hosts are plain types checked at compile time, with conformance suites they run in their own CI. Today there are zui-raylib (a renderer and adapter host), zui-sokol, zui-terminal, and zui-host's Windows host (message loop on its own thread, per-monitor DPI, Mica, IME, clipboard, dropped files, file watching).

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
            .image => |image| self.batch.texturedQuad(command.bounds, image.handle),
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

Declaring `pub const zui_commands: zui.CommandSet = .initMany(&.{ .gradient, .shadow })` adds `gradient` and `shadow` arms to that switch. Nothing in declaration produces them yet, though (see [what isn't working yet](#gaps)).

<a id="host"></a>

### Writing a host · *shipped*

A host polls the OS into a `RecordBuilder`, gives a waker that producers call from any thread, waits as `NextFrame` says, hands out a surface, and applies a frame's requests. A library that reports input as state rather than events, as raylib does, uses `InputSampler` to turn snapshots into the event log. `checkHostAndRenderer` fails to compile when a host and renderer share no surface kind.

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

A backend proves its contract by running zui's suite in its own CI, through a harness that does what only the backend knows how to do. The renderer suite draws a reference scene, deep clips and out-of-bounds commands, then reads the pixels back. The host suite checks event order, sticky and cross-thread wakes, and waits. All three renderers pass. `findRendererViolation` and `findHostViolation` return the first violation instead of failing.

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

The harness method signatures above are simplified. The exact set of declarations a harness needs is listed in the doc comments of `expectRendererConforms` and `expectHostConforms`. zui-raylib, zui-sokol and zui-terminal each have a `src/conformance.zig` you can copy.

<a id="tooling"></a>

## 07. Testing, remote rendering and profiling

The strongest part of the developer experience today. UIs are tested by id and independent of fonts, sessions record and replay, frames travel over a socket, and every step of a frame shows up in Tracy.

<a id="driver"></a>

### Driver tests by element id · *shipped*

`FixedMetricsText` makes every character 8×16 at size 16, so layout assertions hold on any machine. `Driver` runs frames of your declare function and synthesizes input aimed at elements by id: `click`, `clickAt`, `tap`, `hover`, `drag`, multi-finger `dragFingers`, `pressKeys`, `typeText`, `focus`, and `frameDelivering` to inject source deliveries.

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

`ui.relayTo(listener)` hands a listener each record as it is applied, together with what each source delivered. `Recording` keeps them, and `driver.replay` runs them again with no loader. A recorded session of zui-sokol's tour replays to identical commands without starting any work. This makes a bug report a file you can step through.

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

`zui_wire` writes records in and frames out as bytes, with each frame encoded as the changes from the one before. zui-sokol's tour averages 240 bytes a frame against 24 KB for full frames. The header carries a fingerprint of the fonts, so a reader that measures with other fonts refuses the stream instead of drawing misplaced text.

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

`zui_wire.Host(Ui)` is a host whose surface is a socket, and `zui_wire.Renderer(Ui)` writes frames into it. On the other end, `zui_wire.Client(Ui)` joins any real host and renderer to the socket, sending input one way and drawing frames that come back. zui-host's `zig build remote` runs zui-sokol's tour this way. The wire host passes the host conformance suite.

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

- **Gradients, shadows, backdrop blur, transforms, materials** *(declared only)*: The variants exist in `RenderCommand` when a renderer declares them, but `Decoration` has no field that produces them, so nothing is emitted or lowered. Items G1–G6, stage 8.
- **`features.semantics` and `features.gestures`** *(declared only)*: `Frame.semantics()` is always empty and `ui.manipulation` always returns null. Accessibility is V2; gestures (arbitration, momentum, custom recognizers) are I5.
- **`features.flex_wrap` and `features.safety_sweeps`** *(declared only)*: The flags exist and gate their API, but they don't change behaviour yet. Wrap is L7; sweeps are V3.
- **Extended color**: Colors are RGBA8 only. `zui.ExtendedColor` for HDR is G6.
- **Still to come**: Aspect ratio and natural sizes (L2), dividers (L3), more floating options (L4), right-to-left layout (L6), drag and drop between elements (I1), a visual inspector `zui_debug` (V1), motion, multi-line text editing, skins, and more hosts (macOS, Linux, web).

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
- The visuals are flat until the effects stage lands: rectangles, borders, text and images only.
- There's no examples repository or template yet. The best references are zui-sokol's tour and zui-raylib's demo.

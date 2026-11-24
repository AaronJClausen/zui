const std = @import("std");
const zui = @import("zui");
const zui_widgets = @import("zui_widgets");
const zui_design = @import("zui_design");
const zui_glyphs = @import("zui_glyphs");

/// The card's size in layout units: 80×24 cells of 8×16, so a terminal
/// lays out the same card.
pub const size: [2]f32 = .{ 640, 384 };

/// The card in one state. Each is a pure function of its state: drawn
/// after any other scene, or held, its frame is the same.
pub const Scene = enum {
    rest,
    /// The pointer over the `controls` region's button.
    hovered,
    /// The primary button down on that button.
    pressed,
    /// Tab pressed from nothing focused: the `layers` region's anchor has
    /// focus, its ring and its tooltip.
    focused,
    /// The modal dialog open over the page.
    dialog,
    /// The `clip_and_scroll` region's box scrolled further.
    scrolled,

    pub const count = std.enums.values(Scene).len;

    /// The scene of frame `index` of a run that draws the scenes in turn.
    pub fn inTurn(index: u64) Scene {
        return @enumFromInt(index % count);
    }
};

/// The parts of the card, each there to make one check fail, each with
/// its id.
pub const Region = enum {
    identity,
    swatches,
    geometry,
    text,
    clip_and_scroll,
    layers,
    controls,

    pub fn id(region: Region) zui.Id {
        return switch (region) {
            inline else => |named| .of("test_card." ++ @tagName(named)),
        };
    }
};

/// The card's elements its scenes and checks reach by id, besides its
/// regions.
pub const ids = zui.ids(.{ "card", "scroll_box", "tooltip_anchor", "dialog", "dialog_cancel", "dialog_confirm", "button", "checkbox", "slider", "text_field" });

/// The preferences the card's tokens are resolved for: zui's default
/// design, light and compact, whatever the environment reports.
pub const preferences: zui_design.Preferences = .{ .theme = .light, .density = .compact };

/// What the `identity` region says the card was drawn by.
pub const Identity = struct {
    renderer_name: []const u8,
    host_name: []const u8,
    fonts_fingerprint: u64,
    placement: zui_glyphs.Placement,
};

/// What the `controls` region's controls hold, each printed beside it.
pub const Values = struct {
    clicks: u32 = 0,
    checked: bool = true,
    level: f32 = 0.5,
};

/// Where the pointer rests in every scene that does not use it: over the
/// `identity` region, which takes no input.
const resting_pointer: [2]f32 = .{ 4, 4 };

/// The environment every record carries from the card's first frame on,
/// so no setting of the host's changes the card: no motion, so every
/// overlay lands in the frame it opens.
const pinned_environment = [_]zui.EnvironmentChange{
    .{ .theme = preferences.theme },
    .{ .contrast = preferences.contrast },
    .{ .text_scale = preferences.text_scale },
    .{ .reduced_motion = true },
    .{ .reduced_transparency = false },
    .{ .direction = .left_to_right },
    .{ .accent = null },
};

const frame_nanoseconds = std.time.ns_per_s / 60;

/// The test card declared through `Ui`, a `zui.Context`. It makes each
/// scene's input itself: `prepareRecord` replaces the host's input with
/// the scene's, and `declare` declares the scene.
///
/// ```zig
/// var card: Card(Ui) = undefined;
/// card.init(&tokens, identity);
/// const frame = card.declareWithoutHost(&ui, &builder, .focused, .dialog);
/// defer ui.release(frame);
/// ```
pub fn Card(comptime Ui: type) type {
    return struct {
        const Self = @This();

        pub const Tokens = zui.design.Tokens(Ui, void);
        pub const Widgets = zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui));

        tokens: *const Tokens,
        widgets: Widgets,
        identity: Identity,
        values: Values = .{},
        field_buffer: [32]u8 = undefined,
        field: zui_widgets.EditableText,

        frames_recorded: u64 = 0,
        environment_pinned: bool = false,
        pointer_position: ?[2]f32 = null,
        pointer_down: bool = false,
        button_center: ?[2]f32 = null,
        anchor_focused: bool = false,

        /// The card styled by `tokens`, which outlive it, in place: the card
        /// keeps pointers into itself.
        pub fn init(card: *Self, tokens: *const Tokens, identity: Identity) void {
            card.* = .{ .tokens = tokens, .widgets = .{ .skin = .{ .tokens = tokens } }, .identity = identity, .field = undefined };
            card.field = .init(&card.field_buffer, "zui");
        }

        /// Writes the card's tokens: `preferences` over zui's default
        /// design, set in `fonts`, a `Text`'s `fonts`.
        pub fn resolveTokens(tokens: *Tokens, fonts: anytype) void {
            var design = zui_design.default;
            design.type.fonts = .{
                .regular = fontIndex(fonts.regular),
                .strong = fontIndex(fonts.bold),
                .monospace = fontIndex(fonts.mono),
            };
            _ = zui_design.resolve(design, preferences, tokens);
        }

        fn fontIndex(font: Ui.FontId) u32 {
            return switch (@typeInfo(Ui.FontId)) {
                .@"enum" => @intFromEnum(font),
                else => font,
            };
        }

        /// The color the card's page is drawn on, for a renderer to clear to.
        pub fn background(card: *const Self) zui.Color {
            return encoded(card.color(.background));
        }

        fn encoded(color_value: Ui.Color) zui.Color {
            return if (Ui.Color == zui.Color) color_value else color_value.toColor();
        }

        fn color(card: *const Self, role: zui.design.ColorRole) Ui.Color {
            return card.tokens.colors.get(.idle).get(role);
        }

        /// Replaces what the host measured and the input it gathered with
        /// the card's: the card's size, a clock of 60 frames a second from
        /// its first record, the pinned environment, and the input `scene`
        /// is in. A lifecycle event is kept.
        pub fn prepareRecord(card: *Self, scene: Scene, record: *zui.RecordBuilder) void {
            const at: zui.Instant = .fromNanoseconds(card.frames_recorded * frame_nanoseconds);
            card.frames_recorded += 1;
            record.params.now = at;
            record.params.viewport = size;
            record.params.zoom = 1;
            keepOnlyLifecycle(record);
            if (!card.environment_pinned) {
                for (pinned_environment) |change| record.append(.{ .environment = change });
                card.environment_pinned = true;
            }

            const over_button = scene == .hovered or scene == .pressed;
            const position = if (over_button) card.button_center orelse resting_pointer else resting_pointer;
            const pointer: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = position, .at = at };
            if (card.pointer_position == null or !std.meta.eql(card.pointer_position.?, position)) {
                record.append(.{ .pointer_move = .{ .pointer = pointer } });
                card.pointer_position = position;
            }
            const wants_down = scene == .pressed and card.button_center != null;
            if (wants_down != card.pointer_down) {
                record.append(if (wants_down) .{ .pointer_down = .{ .pointer = pointer } } else .{ .pointer_up = .{ .pointer = pointer } });
                card.pointer_down = wants_down;
            }
            if (scene == .focused and !card.anchor_focused) {
                record.append(.{ .key_down = .{ .key = .tab, .at = at } });
                record.append(.{ .key_up = .{ .key = .tab, .at = at } });
            }
        }

        fn keepOnlyLifecycle(record: *zui.RecordBuilder) void {
            var kept: usize = 0;
            for (record.event_buffer[0..record.event_count]) |event| {
                if (event != .lifecycle) continue;
                record.event_buffer[kept] = event;
                kept += 1;
            }
            record.event_count = kept;
        }

        /// Declares `scene`. When the next frame shows another scene,
        /// `leaving` clears the focus for it, since a scene starts from
        /// nothing focused.
        pub fn declare(card: *Self, ui: *Ui, scene: Scene, leaving: bool) void {
            {
                ui.open(.{
                    .id = ids.card,
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(size[0]), .height = .fixed(size[1]) } },
                    .decoration = .{ .background = card.color(.background) },
                    .clip = .both,
                });
                defer ui.close();
                card.declareIdentity(ui, scene);
                card.declareSwatches(ui);
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(size[0]), .height = .grow } } });
                defer ui.close();
                {
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(size[0] / 2), .height = .grow } } });
                    defer ui.close();
                    card.declareText(ui);
                    card.declareGeometry(ui);
                }
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(size[0] / 2), .height = .grow } } });
                defer ui.close();
                card.declareClipAndScroll(ui, scene);
                card.declareLayers(ui, scene);
                card.declareControls(ui);
            }
            if (leaving) ui.requestFocus(.none);
        }

        /// Reads where the frame placed what the next record's input aims at.
        pub fn observe(card: *Self, ui: *const Ui, frame: *const Ui.Frame) void {
            card.button_center = if (frame.rectOf(ids.button)) |rect| .{ rect.x + rect.width / 2, rect.y + rect.height / 2 } else null;
            card.anchor_focused = ui.focused(ids.tooltip_anchor);
        }

        /// One frame of `scene` without a host, as a test or a dump draws
        /// one, with `next` the scene of the frame after it. The caller
        /// releases it.
        pub fn declareWithoutHost(card: *Self, ui: *Ui, builder: *zui.RecordBuilder, scene: Scene, next: Scene) *const Ui.Frame {
            builder.begin(.{ .now = .zero, .viewport = size });
            card.prepareRecord(scene, builder);
            ui.beginFrame(&builder.record());
            card.declare(ui, scene, next != scene);
            const frame = ui.endFrame();
            card.observe(ui, frame);
            return frame;
        }

        fn textStyle(card: *const Self, role: zui.design.TypeRole, color_role: zui.design.ColorRole) Ui.TextStyle {
            var text_style = card.tokens.text_styles.get(role);
            text_style.color = card.color(color_role);
            text_style.wrap = .none;
            // A cell holds one glyph, so tracking would add up to a skipped cell within a line.
            if (card.identity.placement == .cells) text_style.letter_spacing = 0;
            return text_style;
        }

        fn print(card: *const Self, ui: *Ui, role: zui.design.TypeRole, color_role: zui.design.ColorRole, comptime format: []const u8, arguments: anytype) void {
            var buffer: [128]u8 = undefined;
            ui.text(std.fmt.bufPrint(&buffer, format, arguments) catch format, card.textStyle(role, color_role));
        }

        fn openRegion(card: *const Self, ui: *Ui, region: Region, extent: [2]f32, layout: zui.Layout, background_role: zui.design.ColorRole) void {
            var region_layout = layout;
            region_layout.sizing = .{ .width = .fixed(extent[0]), .height = .fixed(extent[1]) };
            ui.open(.{ .id = region.id(), .layout = region_layout, .decoration = .{ .background = card.color(background_role) }, .clip = .both });
        }

        fn declareIdentity(card: *const Self, ui: *Ui, scene: Scene) void {
            card.openRegion(ui, .identity, .{ size[0], 32 }, .{ .direction = .top_to_bottom, .padding = .symmetric(8, 0) }, .surface_inverse);
            defer ui.close();
            const identity = card.identity;
            card.print(ui, .caption, .on_surface_inverse, "zui test card   scene: {t}   renderer: {s}   host: {s}", .{ scene, identity.renderer_name, identity.host_name });
            const viewport = ui.viewport();
            switch (identity.placement) {
                .pixel_grid => card.print(ui, .caption, .on_surface_inverse, "viewport: {d:.0}x{d:.0}   placement: pixel grid   fonts: {x:0>16}", .{ viewport[0], viewport[1], identity.fonts_fingerprint }),
                .cells => |cell| card.print(ui, .caption, .on_surface_inverse, "viewport: {d:.0}x{d:.0}   placement: cells {d:.0}x{d:.0}   fonts: {x:0>16}", .{ viewport[0], viewport[1], cell[0], cell[1], identity.fonts_fingerprint }),
            }
        }

        const swatches_per_row = 11;
        const grey_count = 16;

        fn declareSwatches(card: *const Self, ui: *Ui) void {
            card.openRegion(ui, .swatches, .{ size[0], 64 }, .{ .direction = .top_to_bottom, .padding = .symmetric(8, 0) }, .surface);
            defer ui.close();
            const roles = std.enums.values(zui.design.ColorRole);
            var first: usize = 0;
            while (first < roles.len) : (first += swatches_per_row) {
                const row = roles[first..@min(first + swatches_per_row, roles.len)];
                ui.open(.{ .layout = .{ .sizing = .{ .height = .fixed(16) }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                for (row) |role| card.declareSwatch(ui, card.color(role), swatchCode(role));
                if (row.len < swatches_per_row) card.declareGreys(ui);
            }
        }

        fn declareSwatch(card: *const Self, ui: *Ui, fill: Ui.Color, code: []const u8) void {
            ui.open(.{ .layout = .{ .child_alignment = .{ .y = .center } } });
            defer ui.close();
            ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(16), .height = .fixed(16) } }, .decoration = .{ .background = fill } });
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(32) } } });
            ui.text(code, card.textStyle(.caption, .on_surface));
            ui.close();
        }

        fn declareGreys(card: *const Self, ui: *Ui) void {
            ui.open(.{ .layout = .{ .child_alignment = .{ .y = .center } } });
            defer ui.close();
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(40) } } });
            ui.text("grey", card.textStyle(.caption, .on_surface));
            ui.close();
            for (0..grey_count) |step| {
                const level: u8 = @intCast(step * 255 / (grey_count - 1));
                const grey: zui.Color = .{ .r = level, .g = level, .b = level };
                ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(16), .height = .fixed(16) } }, .decoration = .{ .background = if (Ui.Color == zui.Color) grey else .fromColor(grey) } });
            }
        }

        fn declareText(card: *const Self, ui: *Ui) void {
            card.openRegion(ui, .text, .{ size[0] / 2, 208 }, .{ .direction = .top_to_bottom, .padding = .symmetric(8, 0) }, .surface_sunken);
            defer ui.close();
            {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                defer ui.close();
                const columns = [_][]const zui.design.TypeRole{
                    &.{ .display, .headline, .title, .body, .body_strong },
                    &.{ .code, .numeric, .label, .label_strong, .caption },
                };
                for (columns) |column| {
                    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow } } });
                    defer ui.close();
                    for (column) |role| ui.text(@tagName(role), card.textStyle(role, .on_surface));
                }
            }
            ui.text("Hxgjpqy WMW 0123456789", card.textStyle(.body, .on_surface));
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(192) } }, .clip = .horizontal });
            ui.text("This line is longer than the clip that cuts it short", card.textStyle(.body, .on_surface));
            ui.close();
        }

        fn declareGeometry(card: *const Self, ui: *Ui) void {
            card.openRegion(ui, .geometry, .{ size[0] / 2, 80 }, .{ .direction = .top_to_bottom, .padding = .{ .left = 8, .right = 8, .top = 16 }, .child_gap = 16 }, .background);
            defer ui.close();
            const ink = card.color(.on_surface);
            const fill = card.color(.accent);
            const square: zui.Sizing2 = .{ .width = .fixed(32), .height = .fixed(32) };
            {
                ui.open(.{ .layout = .{ .child_gap = 8 } });
                defer ui.close();
                for ([_]f32{ 1, 2, 3 }) |width| {
                    ui.box(.{ .layout = .{ .sizing = square }, .decoration = .{ .border = .{ .color = ink, .widths = .all(width) } } });
                }
                for ([_]f32{ 0, 4, 12 }) |radius| {
                    ui.box(.{ .layout = .{ .sizing = square }, .decoration = .{ .background = fill, .corner_radius = .all(radius) } });
                }
                ui.open(.{ .layout = .{ .sizing = square, .padding = .{ .left = 0.5, .top = 0.5 } } });
                ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(31), .height = .fixed(31) } }, .decoration = .{ .background = card.color(.on_surface_muted) } });
                ui.close();
            }
            ui.open(.{ .layout = .{ .sizing = .{ .height = .fixed(16) }, .child_gap = 3, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(120), .height = .fixed(1) } }, .decoration = .{ .background = ink } });
            for (0..8) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(1), .height = .fixed(16) } }, .decoration = .{ .background = ink } });
        }

        const scroll_rows = 10;
        const wide_row = 3;

        fn scrollOffsetOf(scene: Scene) f32 {
            return if (scene == .scrolled) 52 else 20;
        }

        fn declareClipAndScroll(card: *const Self, ui: *Ui, scene: Scene) void {
            card.openRegion(ui, .clip_and_scroll, .{ size[0] / 2, 96 }, .{ .padding = .{ .left = 8, .right = 8, .top = 16 } }, .background);
            defer ui.close();
            ui.setScrollOffset(ids.scroll_box, .{ 0, scrollOffsetOf(scene) });
            ui.open(.{
                .id = ids.scroll_box,
                .scroll = .{},
                .clip = .both,
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(size[0] / 2 - 16), .height = .fixed(64) } },
                .decoration = .{ .background = card.color(.surface) },
            });
            defer ui.close();
            for (0..scroll_rows) |row| {
                ui.open(.{
                    .layout = .{ .sizing = .{ .width = .grow }, .padding = .symmetric(8, 0), .child_gap = 8, .child_alignment = .{ .y = .center } },
                    .decoration = .{ .background = card.color(if (row % 2 == 0) .surface else .surface_sunken) },
                });
                defer ui.close();
                card.print(ui, .body, .on_surface, "row {d}", .{row + 1});
                if (row + 1 == wide_row) ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(400), .height = .fixed(8) } }, .decoration = .{ .background = card.color(.accent) } });
            }
        }

        fn declareLayers(card: *Self, ui: *Ui, scene: Scene) void {
            card.openRegion(ui, .layers, .{ size[0] / 2, 96 }, .{ .direction = .top_to_bottom, .padding = .{ .left = 8, .right = 8, .top = 16 }, .child_gap = 8 }, .surface);
            defer ui.close();
            ui.text("Tab: a tooltip over the page", card.textStyle(.caption, .on_surface));
            _ = card.widgets.button(ui, ids.tooltip_anchor, "Anchor", .{ .variant = .secondary });
            card.widgets.tooltip(ui, ids.tooltip_anchor, "A tooltip over the page", .{ .placement = .above });

            var dialog_open = scene == .dialog;
            const options: Widgets.DialogOptions = .{ .title = "A modal dialog", .description = "Over the page, behind its scrim.", .dismissible = false };
            if (card.widgets.dialog(ui, ids.dialog, &dialog_open, options)) |opened| {
                opened.actions(ui);
                _ = card.widgets.button(ui, ids.dialog_cancel, "Cancel", .{ .variant = .secondary });
                _ = card.widgets.button(ui, ids.dialog_confirm, "Confirm", .{});
                ui.close();
                opened.end(ui);
            }
        }

        fn declareControls(card: *Self, ui: *Ui) void {
            card.openRegion(ui, .controls, .{ size[0] / 2, 96 }, .{ .direction = .top_to_bottom, .padding = .{ .left = 8, .right = 8, .top = 16 }, .child_gap = 8 }, .background);
            defer ui.close();
            const row: zui.Layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } };
            {
                ui.open(.{ .layout = row });
                defer ui.close();
                if (card.widgets.button(ui, ids.button, "Button", .{})) card.values.clicks += 1;
                card.print(ui, .body, .on_surface, "clicks {d}", .{card.values.clicks});
                _ = card.widgets.checkbox(ui, ids.checkbox, "Checkbox", &card.values.checked, .{});
                ui.text(if (card.values.checked) "on" else "off", card.textStyle(.body, .on_surface));
            }
            ui.open(.{ .layout = row });
            defer ui.close();
            _ = card.widgets.slider(ui, ids.slider, &card.values.level, .{ .width = .fixed(96), .label = "Level" });
            card.print(ui, .body, .on_surface, "{d:.2}", .{card.values.level});
            _ = card.widgets.textField(ui, ids.text_field, &card.field, .{ .width = .fixed(112), .label = "Text" });
            ui.text(card.field.slice(), card.textStyle(.body, .on_surface));
        }
    };
}

/// The label of `role`'s swatch: `o` for `on_`, `c` for `_container`.
pub fn swatchCode(role: zui.design.ColorRole) []const u8 {
    return switch (role) {
        .background => "bg",
        .surface => "sf",
        .surface_raised => "sfr",
        .surface_sunken => "sfs",
        .surface_overlay => "sfo",
        .surface_inverse => "sfi",
        .on_surface => "on",
        .on_surface_muted => "onm",
        .on_surface_inverse => "oni",
        .on_surface_accent => "ona",
        .accent => "ac",
        .on_accent => "oac",
        .accent_container => "acc",
        .on_accent_container => "oacc",
        .secondary_container => "sec",
        .on_secondary_container => "osec",
        .danger => "dg",
        .on_danger => "odg",
        .danger_container => "dgc",
        .on_danger_container => "odgc",
        .warning => "wn",
        .on_warning => "own",
        .warning_container => "wnc",
        .on_warning_container => "ownc",
        .success => "ok",
        .on_success => "ook",
        .success_container => "okc",
        .on_success_container => "ookc",
        .selection => "sel",
        .on_selection => "osel",
        .outline => "ol",
        .outline_muted => "olm",
        .focus => "fo",
        .scrim => "scr",
        .shadow => "sh",
        .rim => "rim",
    };
}

//! Reference widgets, built only on zui's public API and styled by a skin.
//!
//! ```zig
//! const widgets: zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui)) = .{ .skin = .{ .tokens = &app.tokens } };
//!
//! if (widgets.button(ui, .of("save"), "Save", .{})) save();
//! _ = widgets.checkbox(ui, .of("autosave"), "Autosave", &settings.autosave, .{});
//! _ = widgets.slider(ui, .of("volume"), &settings.volume, .{ .min = 0, .max = 100 });
//! _ = widgets.textField(ui, .of("name"), &settings.name, .{ .placeholder = "Name" });
//! _ = widgets.dropdownEnum(ui, .of("quality"), &settings.quality, .{});
//! ```

const std = @import("std");
const zui = @import("zui");

/// Text a `textField` edits in place, in a caller-owned buffer.
///
/// ```zig
/// var name_bytes: [64]u8 = undefined;
/// var name: zui_widgets.EditableText = .init(&name_bytes, "Ada");
/// ```
pub const EditableText = struct {
    buffer: []u8,
    len: usize = 0,

    /// Copies `initial`, cut at a character boundary if the buffer is smaller.
    pub fn init(buffer: []u8, initial: []const u8) EditableText {
        var text: EditableText = .{ .buffer = buffer };
        _ = text.insert(0, initial);
        return text;
    }

    pub fn slice(self: *const EditableText) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Inserts as much of `bytes` as fits, cut at a character boundary, and
    /// returns how many bytes that was.
    pub fn insert(self: *EditableText, position: usize, bytes: []const u8) usize {
        var count = @min(bytes.len, self.buffer.len - self.len);
        while (count > 0 and count < bytes.len and isContinuationByte(bytes[count])) count -= 1;
        std.mem.copyBackwards(u8, self.buffer[position + count .. self.len + count], self.buffer[position..self.len]);
        @memcpy(self.buffer[position..][0..count], bytes[0..count]);
        self.len += count;
        return count;
    }

    pub fn remove(self: *EditableText, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.buffer[start .. self.len - (end - start)], self.buffer[end..self.len]);
        self.len -= end - start;
    }

    pub fn set(self: *EditableText, content: []const u8) void {
        self.len = 0;
        _ = self.insert(0, content);
    }
};

/// `"max_fps"` becomes `"Max fps"`.
pub fn labelFromIdentifier(comptime identifier: []const u8) []const u8 {
    return &LabelFromIdentifier(identifier).label;
}

fn LabelFromIdentifier(comptime identifier: []const u8) type {
    return struct {
        const label = blk: {
            var bytes: [identifier.len]u8 = identifier[0..identifier.len].*;
            for (&bytes) |*byte| {
                if (byte.* == '_') byte.* = ' ';
            }
            if (bytes.len != 0) bytes[0] = std.ascii.toUpper(bytes[0]);
            break :blk bytes;
        };
    };
}

/// The path a `lasso` draws, in the application's memory: a state slot
/// is too small for it. Points beyond its capacity are dropped.
pub const Lasso = struct {
    buffer: [capacity][2]f32 = undefined,
    len: usize = 0,
    /// The pen drawing it, while one is.
    pen: ?zui.PointerId = null,

    pub const capacity = 256;

    /// In layout units, from the surface's top-left.
    pub fn points(self: *const Lasso) []const [2]f32 {
        return self.buffer[0..self.len];
    }

    fn add(self: *Lasso, point: [2]f32) void {
        if (self.len == capacity) return;
        self.buffer[self.len] = point;
        self.len += 1;
    }
};

/// Every element a widget asks its skin to style. A state-dependent look is
/// chosen by `zui.WidgetState`; a checked box and the selected option are
/// parts of their own, since they are not states of the pointer or focus.
/// Each tag lists the `Style` fields its widget reads.
pub const Part = enum {
    /// `label`: `text`.
    label,
    /// `mutedLabel`: `text`.
    muted_label,
    /// `labeledRow`'s label: `text`, `size[0]` for the label's column and
    /// `gap` between the label and the control.
    row_label,
    /// `disclosure`'s header: `background`, `border`, `focus_ring`,
    /// `corner_radius`, `size[1]`, `padding`, `gap` and `text`.
    disclosure,
    /// The header's indicator while expanded: `glyph` and `text`.
    disclosure_expanded,
    /// The header's indicator while collapsed: `glyph` and `text`.
    disclosure_collapsed,
    /// `button`, a primary action: `background`, `border`, `focus_ring`,
    /// `corner_radius`, `size[1]`, `padding`, `gap` and `text`.
    button,
    /// A button of `.variant = .secondary`, read as `button`.
    button_secondary,
    /// A button of `.variant = .tonal`, read as `button`.
    button_tonal,
    /// A button of `.variant = .tertiary`, read as `button`.
    button_tertiary,
    /// A button of `.variant = .danger`, read as `button`.
    button_danger,
    /// `checkbox`'s row: `size[1]`, `gap` and its label's `text`.
    checkbox,
    /// The box while unchecked: `background`, `border`, `focus_ring`,
    /// `corner_radius` and `size`.
    checkbox_box,
    /// The box while checked, read as `checkbox_box`.
    checkbox_box_checked,
    /// The mark in a checked box: `background`, `corner_radius` and `size`.
    checkbox_mark,
    /// `slider`: `size[1]`.
    slider,
    /// The track before the thumb: `background`, `corner_radius` and
    /// `size[1]`.
    slider_filled,
    /// The track after the thumb, read as `slider_filled`.
    slider_empty,
    /// The thumb: `background`, `border`, `focus_ring`, `corner_radius` and
    /// `size`.
    slider_thumb,
    /// `textField`: `background`, `border`, `focus_ring`, `corner_radius`,
    /// `size[1]`, `padding` and `text`.
    text_field,
    /// The placeholder of an empty field: `text`.
    text_field_placeholder,
    /// The caret, as tall as the field's text: `background` and `size[0]`.
    text_field_caret,
    /// `dropdown`'s button: `background`, `border`, `focus_ring`,
    /// `corner_radius`, `size[1]`, `padding`, `gap` and `text`.
    dropdown,
    /// The button's indicator: `glyph` and `text`.
    dropdown_indicator,
    /// The open list: `background`, `border`, `corner_radius`, `padding`,
    /// `gap` between it and the button, and `layer`.
    dropdown_popup,
    /// An option in the list: `background`, `border`, `focus_ring`,
    /// `corner_radius`, `size[1]`, `padding` and `text`.
    dropdown_option,
    /// The selected option, read as `dropdown_option`.
    dropdown_option_selected,
};

/// What a skin's `zuiStyle` returns for one `Part` in one state, in the
/// context's own color and text types. A part reads only the fields its
/// `Part` tag lists; the rest are ignored.
pub fn Style(comptime Ui: type) type {
    return struct {
        /// None when null.
        background: ?Ui.Color = null,
        /// Drawn while the element does not have keyboard focus.
        border: ?Ui.Border = null,
        /// Drawn in place of `border` while the element has keyboard focus,
        /// which it keeps while hovered or pressed.
        focus_ring: ?Ui.Border = null,
        corner_radius: zui.CornerRadius = .zero,
        corner_shape: zui.CornerShape = .round,
        /// Drawn beneath a popup.
        shadow: ?Ui.Shadow = null,
        /// Always laid out on one line.
        text: Ui.TextStyle = .{},
        /// Width and height in layout units, where the part is a fixed size.
        size: [2]f32 = .{ 0, 0 },
        padding: zui.Edges = .zero,
        gap: f32 = 0,
        /// An indicator's text, such as a dropdown's arrow.
        glyph: []const u8 = "",
        /// The layer a popup paints in; its content paints in the next one up.
        layer: i16 = 0,
    };
}

/// Fails to compile unless `Skin` implements the skin contract for `Ui`:
/// a struct declaring
///
/// ```zig
/// pub fn zuiStyle(skin: *const Skin, part: zui_widgets.Part, state: zui.WidgetState, environment: *const zui.Environment) zui_widgets.Style(Ui)
/// ```
///
/// and no other `zui`-prefixed declaration.
pub fn expectSkin(comptime Ui: type, comptime Skin: type) void {
    const name = @typeName(Skin);
    if (@typeInfo(Skin) != .@"struct") @compileError("zui_widgets: a skin must be a struct type, got " ++ name);
    for (@typeInfo(Skin).@"struct".decls) |declaration| {
        if (std.mem.startsWith(u8, declaration.name, "zui") and !std.mem.eql(u8, declaration.name, "zuiStyle"))
            @compileError("zui_widgets: " ++ name ++ " declares unknown `" ++ declaration.name ++ "`");
    }
    if (!@hasDecl(Skin, "zuiStyle")) @compileError("zui_widgets: " ++ name ++ " does not implement the skin contract: missing `zuiStyle`");
    const Expected = fn (*const Skin, Part, zui.WidgetState, *const zui.Environment) Style(Ui);
    const Found = @TypeOf(Skin.zuiStyle);
    if (Found != Expected) @compileError("zui_widgets: " ++ name ++ ".zuiStyle must be fn (*const " ++ name ++
        ", zui_widgets.Part, zui.WidgetState, *const zui.Environment) zui_widgets.Style(Ui), found " ++ @typeName(Found));
}

/// zui's own skin, every part styled from `tokens`, which the application
/// resolves again when a preference changes, so the widgets follow the
/// theme, contrast, density, text scale and color vision it was resolved
/// for.
///
/// ```zig
/// var tokens: zui.design.Tokens(Ui, void) = .{};
/// _ = zui_design.resolve(zui_design.default, .from(ui.environment(), choices), &tokens);
/// const widgets: zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui)) = .{ .skin = .{ .tokens = &tokens } };
/// ```
pub fn DesignSkin(comptime Ui: type) type {
    return DesignSkinWith(Ui, void);
}

/// `DesignSkin` over tokens with the application's own `ExtraRoles`.
pub fn DesignSkinWith(comptime Ui: type, comptime ExtraRoles: type) type {
    return struct {
        const Skin = @This();

        tokens: *const zui.design.Tokens(Ui, ExtraRoles),

        pub fn zuiStyle(skin: *const Skin, part: Part, state: zui.WidgetState, _: *const zui.Environment) Style(Ui) {
            const tokens = skin.tokens;
            const medium_height = tokens.control_heights.get(.medium);
            return switch (part) {
                .label => skin.styled(.label, state),
                .muted_label => skin.styled(.muted_label, state),
                .row_label => sized(skin.styled(.row_label, state), .{ label_column_width * tokens.text_padding_scale, 0 }),
                .disclosure => sized(skin.styled(.disclosure, state), .{ 0, medium_height }),
                .disclosure_expanded => withGlyph(skin.styled(.disclosure_indicator, state), "v"),
                .disclosure_collapsed => withGlyph(skin.styled(.disclosure_indicator, state), ">"),
                .button => sized(skin.styled(.button, state), .{ 0, medium_height }),
                .button_secondary => sized(skin.styled(.button_secondary, state), .{ 0, medium_height }),
                .button_tonal => sized(skin.styled(.button_tonal, state), .{ 0, medium_height }),
                .button_tertiary => sized(skin.styled(.button_tertiary, state), .{ 0, medium_height }),
                .button_danger => sized(skin.styled(.button_danger, state), .{ 0, medium_height }),
                .checkbox => sized(skin.styled(.checkbox, state), .{ 0, tokens.control_heights.get(.small) }),
                .checkbox_box => skin.checkboxBox(.checkbox_box, state),
                .checkbox_box_checked => skin.checkboxBox(.checkbox_box_checked, state),
                .checkbox_mark => mark: {
                    const side = @round(skin.checkboxSide() * check_mark_share);
                    const icon = skin.styled(.checkbox_mark, state);
                    break :mark .{ .background = icon.text.color, .corner_radius = .all(check_mark_corner_radius), .size = .{ side, side } };
                },
                .slider => .{ .size = .{ 0, medium_height } },
                .slider_filled => sized(skin.styled(.slider_filled, state), .{ 0, slider_track_thickness }),
                .slider_empty => sized(skin.styled(.slider_empty, state), .{ 0, slider_track_thickness }),
                .slider_thumb => thumb: {
                    var thumb = sized(skin.styled(.slider_thumb, state), @splat(slider_thumb_side));
                    if (thumb.border) |*border| border.widths = .all(slider_thumb_border_width);
                    break :thumb thumb;
                },
                .text_field => sized(skin.styled(.text_field, state), .{ 0, medium_height }),
                .text_field_placeholder => skin.styled(.text_field_placeholder, state),
                .text_field_caret => sized(skin.styled(.text_field_caret, state), .{ caret_width, 0 }),
                .dropdown => sized(skin.styled(.dropdown, state), .{ 0, medium_height }),
                .dropdown_indicator => withGlyph(skin.styled(.dropdown_indicator, state), "v"),
                .dropdown_popup => popup: {
                    var list = skin.styled(.dropdown_popup, state);
                    const lift = tokens.elevations.get(.floating);
                    list.background = tokens.colors.get(state).get(lift.surface);
                    list.border = if (lift.rim) |rim| .{ .color = rim, .widths = .all(tokens.outline_width) } else null;
                    list.shadow = lift.shadow;
                    list.layer = popup_layer;
                    break :popup list;
                },
                .dropdown_option => sized(skin.styled(.dropdown_option, state), .{ 0, medium_height }),
                .dropdown_option_selected => sized(skin.styled(.dropdown_option_selected, state), .{ 0, medium_height }),
            };
        }

        /// The approved checkbox is 16, 18 and 20 at the three densities.
        fn checkboxSide(skin: *const Skin) f32 {
            return skin.tokens.control_heights.get(.small) / 2 + 4;
        }

        fn checkboxBox(skin: *const Skin, comptime designed: Designed.Part, state: zui.WidgetState) Style(Ui) {
            var box = sized(skin.styled(designed, state), @splat(skin.checkboxSide()));
            box.corner_radius = .all(checkbox_corner_radius);
            if (box.border) |*border| border.widths = .all(checkbox_border_width);
            return box;
        }

        fn styled(skin: *const Skin, comptime designed: Designed.Part, state: zui.WidgetState) Style(Ui) {
            const tokens = skin.tokens;
            const look = tokens.look(Designed, designed, state);
            const declared = comptime Designed.zuiAppearance.of(designed);
            const resting = if (state == .focused) tokens.look(Designed, designed, .idle) else look;
            return .{
                .background = look.decoration.background,
                .border = resting.decoration.border,
                .focus_ring = if (declared.target == .none) null else focusRingOf(tokens.look(Designed, designed, .focused).decoration.border, tokens.focus_ring_width),
                .corner_radius = look.decoration.corner_radius,
                .corner_shape = look.decoration.corner_shape,
                .text = look.text,
                .padding = look.padding,
                .gap = look.gap,
            };
        }

        fn focusRingOf(border: ?Ui.Border, width: f32) ?Ui.Border {
            var ring = border orelse return null;
            ring.widths = .all(width);
            return ring;
        }

        fn sized(style: Style(Ui), size: [2]f32) Style(Ui) {
            var with_size = style;
            with_size.size = size;
            return with_size;
        }

        fn withGlyph(style: Style(Ui), glyph: []const u8) Style(Ui) {
            var with_glyph = style;
            with_glyph.glyph = glyph;
            return with_glyph;
        }
    };
}

const label_column_width = 160;
const checkbox_corner_radius = 4;
const checkbox_border_width = 1.5;
const check_mark_share = 0.45;
const check_mark_corner_radius = 2;
const slider_track_thickness = 4;
const slider_thumb_side = 20;
const slider_thumb_border_width = 2;
const caret_width = 2;
/// Popups paint in this layer and the next one up.
const popup_layer = 100;

/// The roles and tiers each part of `DesignSkin` is drawn in. Text on the
/// page is drawn `.on` `page`, the surface beneath every widget.
const Designed = struct {
    pub const Part = enum {
        page,
        label,
        muted_label,
        row_label,
        disclosure,
        disclosure_indicator,
        button,
        button_secondary,
        button_tonal,
        button_tertiary,
        button_danger,
        checkbox,
        checkbox_box,
        checkbox_box_checked,
        checkbox_mark,
        slider_filled,
        slider_empty,
        slider_thumb,
        text_field,
        text_field_placeholder,
        text_field_caret,
        dropdown,
        dropdown_indicator,
        dropdown_popup,
        dropdown_option,
        dropdown_option_selected,
    };

    const on_hover: zui.design.PartAppearance(void).Colors = .{ .surface = .secondary_container, .text = .on_secondary_container };

    pub const zuiAppearance = zui.design.Appearance(@This().Part, .{
        .page = .{ .surface = .surface },
        .label = .{ .text = .on_surface, .type = .body, .on = .page },
        .muted_label = .{ .text = .on_surface_muted, .type = .body, .on = .page },
        .row_label = .{ .text = .on_surface, .type = .body, .on = .page, .gap = .l },
        .disclosure = .{
            .text = .on_surface,
            .type = .body_strong,
            .on = .page,
            .shape = .control,
            .padding = .{ .x = .s },
            .gap = .s,
            .target = .pointer,
            .states = .{ .hovered = on_hover, .pressed = on_hover },
        },
        .disclosure_indicator = .{ .text = .on_surface_muted, .type = .body, .on = .page },
        .button = filledButton(.accent, .on_accent),
        .button_secondary = filledButton(.secondary_container, .on_secondary_container),
        .button_tonal = filledButton(.accent_container, .on_accent_container),
        .button_tertiary = .{
            .text = .on_surface_accent,
            .type = .body_strong,
            .on = .page,
            .shape = .control,
            .padding = .{ .x = .l },
            .gap = .s,
            .target = .pointer,
            .states = .{ .hovered = .{ .surface = .secondary_container }, .pressed = .{ .surface = .secondary_container } },
        },
        .button_danger = filledButton(.danger, .on_danger),
        .checkbox = .{ .text = .on_surface, .type = .body, .on = .page, .gap = .s },
        .checkbox_box = .{ .surface = .surface, .outline = .outline, .target = .pointer },
        .checkbox_box_checked = .{ .surface = .accent, .target = .pointer, .cue = "its check mark" },
        .checkbox_mark = .{ .icon = .on_accent, .on = .checkbox_box_checked },
        .slider_filled = .{ .surface = .accent, .shape = .indicator },
        .slider_empty = .{ .surface = .outline_muted, .shape = .indicator },
        // Not `accent`, which high contrast draws in the focus ring's color,
        // so a focused thumb would look like an idle one.
        .slider_thumb = .{ .surface = .surface_raised, .outline = .outline, .shape = .indicator, .target = .pointer },
        .text_field = .{
            .surface = .surface_sunken,
            .text = .on_surface,
            .type = .body,
            .on = .text_field,
            .shape = .control,
            .padding = .{ .x = .m },
            .target = .pointer,
            .states = .{ .hovered = .{ .outline = .outline_muted }, .focused = .{ .surface = .surface, .outline = .accent } },
        },
        .text_field_placeholder = .{ .text = .on_surface_muted, .type = .body, .on = .text_field },
        .text_field_caret = .{ .surface = .accent },
        .dropdown = .{ .surface = .surface_sunken, .text = .on_surface, .type = .body, .on = .dropdown, .shape = .control, .padding = .{ .x = .m }, .gap = .s, .target = .pointer },
        .dropdown_indicator = .{ .text = .on_surface_muted, .type = .body, .on = .dropdown },
        .dropdown_popup = .{ .surface = .surface_overlay, .shape = .popup, .padding = .{ .x = .xs, .y = .xs }, .gap = .xs },
        .dropdown_option = option(.body),
        .dropdown_option_selected = selected: {
            var selected = option(.body_strong);
            selected.cue = "its label in the strong font";
            break :selected selected;
        },
    });

    fn filledButton(comptime surface: zui.design.ColorChoice(void), comptime text: zui.design.ColorChoice(void)) zui.design.PartAppearance(void) {
        return .{
            .surface = surface,
            .text = text,
            .type = .body_strong,
            .on = .button,
            .shape = .control,
            .padding = .{ .x = .l },
            .gap = .s,
            .target = .pointer,
        };
    }

    fn option(comptime type_role: zui.design.TypeRole) zui.design.PartAppearance(void) {
        return .{
            .text = .on_surface,
            .type = type_role,
            .on = .dropdown_popup,
            .shape = .control,
            .padding = .{ .x = .m },
            .target = .pointer,
            .states = .{ .hovered = on_hover, .pressed = on_hover },
        };
    }
};

/// How much a button stands out: `primary` for the one main action,
/// `secondary` and `tonal` for the others, `tertiary` with no fill until
/// hovered, and `danger` for one that destroys.
pub const ButtonVariant = enum {
    primary,
    secondary,
    tonal,
    tertiary,
    danger,

    pub fn part(variant: ButtonVariant) Part {
        return switch (variant) {
            .primary => .button,
            .secondary => .button_secondary,
            .tonal => .button_tonal,
            .tertiary => .button_tertiary,
            .danger => .button_danger,
        };
    }
};

/// Controls declared into a `*Ui` and styled by `Skin`, any type that
/// implements the skin contract (`expectSkin`).
pub fn Widgets(comptime UiType: type, comptime SkinType: type) type {
    expectSkin(UiType, SkinType);
    return struct {
        const Self = @This();
        pub const Ui = UiType;
        pub const Skin = SkinType;
        pub const TextStyle = Ui.TextStyle;
        pub const SkinStyle = Style(Ui);

        skin: Skin,

        /// The skin's style for `part` in `state`, under the environment
        /// `ui` last reported, for an element that should match a widget.
        ///
        /// ```zig
        /// .decoration = .{ .background = widgets.style(ui, .button, ui.widgetState(id)).background },
        /// ```
        pub fn style(self: *const Self, ui: *const Ui, part: Part, state: zui.WidgetState) SkinStyle {
            return self.skin.zuiStyle(part, state, ui.environment());
        }

        pub fn label(self: Self, ui: *Ui, content: []const u8) void {
            ui.text(content, singleLine(self.style(ui, .label, .idle).text));
        }

        pub fn mutedLabel(self: Self, ui: *Ui, content: []const u8) void {
            ui.text(content, singleLine(self.style(ui, .muted_label, .idle).text));
        }

        /// Opens a row with `content` in a column as wide as the skin's
        /// `row_label`. Declare the control, then close the row:
        ///
        /// ```zig
        /// widgets.labeledRow(ui, "Volume");
        /// _ = widgets.slider(ui, .of("volume"), &volume, .{ .max = 100 });
        /// ui.close();
        /// ```
        pub fn labeledRow(self: Self, ui: *Ui, content: []const u8) void {
            const row_label = self.style(ui, .row_label, .idle);
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = row_label.gap, .child_alignment = .{ .y = .center } } });
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(row_label.size[0]) } } });
            ui.text(content, singleLine(row_label.text));
            ui.close();
        }

        /// A full-width header that toggles `expanded` when clicked, for
        /// collapsible sections. Returns whether it toggled.
        ///
        /// ```zig
        /// if (widgets.disclosure(ui, .of("advanced"), "Advanced", &advanced_open)) {}
        /// if (advanced_open) advancedSettings(ui);
        /// ```
        pub fn disclosure(self: Self, ui: *Ui, id: zui.Id, content: []const u8, expanded: *bool) bool {
            const toggled = ui.clicked(id);
            if (toggled) expanded.* = !expanded.*;
            const state = ui.widgetState(id);
            const header = self.style(ui, .disclosure, state);
            const indicator = self.style(ui, if (expanded.*) .disclosure_expanded else .disclosure_collapsed, state);
            ui.open(.{
                .id = id,
                .focusable = true,
                .cursor = .pointer,
                .semantics = .{ .role = .button, .label = content, .state = .{ .expanded = expanded.* } },
                .decoration = decorationOf(header, ui.focused(id)),
                .layout = .{
                    .sizing = .{ .width = .grow, .height = .fixed(header.size[1]) },
                    .padding = header.padding,
                    .child_gap = header.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
            ui.text(indicator.glyph, singleLine(indicator.text));
            ui.text(content, singleLine(header.text));
            ui.close();
            return toggled;
        }

        pub const ButtonOptions = struct {
            disabled: bool = false,
            width: zui.Sizing = .fit,
            variant: ButtonVariant = .primary,
        };

        /// True in the frame the button is clicked, or activated with Enter
        /// or Space while focused.
        pub fn button(self: Self, ui: *Ui, id: zui.Id, content: []const u8, options: ButtonOptions) bool {
            const look = self.style(ui, options.variant.part(), stateOf(ui, id, options.disabled));
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .semantics = .{ .role = .button, .label = content },
                .decoration = decorationOf(look, ui.focused(id)),
                .layout = .{
                    .sizing = .{ .width = options.width, .height = .fixed(look.size[1]) },
                    .padding = look.padding,
                    .child_gap = look.gap,
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            });
            ui.text(content, singleLine(look.text));
            ui.close();
            return ui.clicked(id);
        }

        pub const CheckboxOptions = struct {
            disabled: bool = false,
            /// Its name to an assistive technology; `content` when empty.
            label: []const u8 = "",
        };

        /// Toggles `checked` when clicked; returns whether it did. An empty
        /// `content` draws the box alone.
        pub fn checkbox(self: Self, ui: *Ui, id: zui.Id, content: []const u8, checked: *bool, options: CheckboxOptions) bool {
            const toggled = ui.clicked(id);
            if (toggled) checked.* = !checked.*;

            const state = stateOf(ui, id, options.disabled);
            const row = self.style(ui, .checkbox, state);
            const box = self.style(ui, if (checked.*) .checkbox_box_checked else .checkbox_box, state);
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .semantics = .{ .role = .checkbox, .label = if (options.label.len != 0) options.label else content, .state = .{ .checked = checked.* } },
                .layout = .{ .sizing = .{ .height = .fixed(row.size[1]) }, .child_gap = row.gap, .child_alignment = .{ .y = .center } },
            });
            ui.open(.{
                .decoration = decorationOf(box, ui.focused(id)),
                .layout = .{
                    .sizing = .{ .width = .fixed(box.size[0]), .height = .fixed(box.size[1]) },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            });
            if (checked.*) {
                const mark = self.style(ui, .checkbox_mark, state);
                ui.box(.{
                    .decoration = decorationOf(mark, false),
                    .layout = .{ .sizing = .{ .width = .fixed(mark.size[0]), .height = .fixed(mark.size[1]) } },
                });
            }
            ui.close();
            if (content.len != 0) ui.text(content, singleLine(row.text));
            ui.close();
            return toggled;
        }

        /// A recognizer on `id`, an element that declares
        /// `.gestures.custom`: a pen pressed on it draws `path`, and it
        /// declines every other pointer, so fingers and the mouse pan and
        /// zoom the element as they would without it. Returns true in the
        /// frame the pen lifts.
        ///
        /// ```zig
        /// ui.open(.{ .id = map_id, .gestures = .{ .pan = .both, .zoom = true, .custom = true } });
        /// if (widgets.lasso(ui, map_id, &app.selection)) app.selectInside(app.selection.points());
        /// ```
        pub fn lasso(self: Self, ui: *Ui, id: zui.Id, path: *Lasso) bool {
            _ = self;
            var finished = false;
            var events = ui.pointerEvents(id);
            while (events.next()) |event| switch (event) {
                .pointer_down => |down| {
                    if (down.pointer.kind != .pen or path.pen != null) {
                        ui.decline(down.pointer.id);
                        continue;
                    }
                    ui.claim(down.pointer.id);
                    path.pen = down.pointer.id;
                    path.len = 0;
                    path.add(down.pointer.position);
                },
                .pointer_move => |moved| if (path.pen == moved.pointer.id) path.add(moved.pointer.position),
                .pointer_up => |lifted| if (path.pen == lifted.pointer.id) {
                    path.add(lifted.pointer.position);
                    path.pen = null;
                    finished = true;
                },
                .pointer_cancel => |pointer_id| if (path.pen == pointer_id) {
                    path.pen = null;
                    path.len = 0;
                },
                else => {},
            };
            return finished;
        }

        pub const SliderOptions = struct {
            min: f64 = 0,
            max: f64 = 1,
            /// Values snap to `min + n * step`. Integer values always
            /// round to whole numbers.
            step: ?f64 = null,
            disabled: bool = false,
            width: zui.Sizing = .grow,
            /// Its name to an assistive technology; the slider draws no text.
            label: []const u8 = "",
        };

        /// Edits the integer or float behind `value` by dragging, with the
        /// arrow keys, Page Up/Down, Home and End while focused, or by
        /// `adjust` actions. Returns whether the value changed. It keeps a
        /// horizontal drag, so a list it is in scrolls only with a vertical
        /// one.
        pub fn slider(self: Self, ui: *Ui, id: zui.Id, value: anytype, options: SliderOptions) bool {
            const Value = NumberPointee(@TypeOf(value), "slider");
            const state = stateOf(ui, id, options.disabled);
            const thumb = self.style(ui, .slider_thumb, state);
            const range = options.max - options.min;
            const previous: f64 = numberToFloat(value.*);
            var proposed = previous;
            const key_step = options.step orelse if (@typeInfo(Value) == .int) 1 else range / 100;

            if (!options.disabled) {
                if (pointerActivated(ui, id)) if (ui.pointerLocal(id)) |local| if (ui.rectOf(id)) |rect| {
                    const travel = rect.width - thumb.size[0];
                    if (travel > 0) proposed = options.min + range * (local[0] - thumb.size[0] / 2) / travel;
                };
                if (ui.focused(id)) for (ui.keyEvents()) |key_event| switch (key_event.key) {
                    .page_down => proposed -= key_step * 10,
                    .page_up => proposed += key_step * 10,
                    .home => proposed = options.min,
                    .end => proposed = options.max,
                    else => {},
                };
                if (ui.adjusted(id)) |steps| proposed += key_step * @as(f64, @floatFromInt(steps));
            }

            var changed = false;
            if (proposed != previous) {
                const stored = floatToNumber(Value, snap(proposed, options));
                changed = stored != value.*;
                value.* = stored;
            }

            const current: f64 = numberToFloat(value.*);
            const fraction: f32 = if (range > 0) @floatCast(std.math.clamp((current - options.min) / range, 0, 1)) else 0;
            const filled = self.style(ui, .slider_filled, state);
            const empty = self.style(ui, .slider_empty, state);
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .gestures = .{ .pan = .horizontal },
                .semantics = .{
                    .role = .slider,
                    .label = options.label,
                    .value = .{ .range = .{ .value = current, .min = options.min, .max = options.max, .step = key_step } },
                    .actions = .initOne(.adjust),
                },
                .layout = .{ .sizing = .{ .width = options.width, .height = .fixed(self.style(ui, .slider, state).size[1]) }, .child_alignment = .{ .y = .center } },
            });
            // The grow weights split the track's free space at the value,
            // so the thumb lands in place without last frame's width.
            ui.box(.{
                .decoration = decorationOf(filled, false),
                .layout = .{ .sizing = .{ .width = .growWeighted(fraction), .height = .fixed(filled.size[1]) } },
            });
            ui.box(.{
                .decoration = decorationOf(thumb, ui.focused(id)),
                .layout = .{ .sizing = .{ .width = .fixed(thumb.size[0]), .height = .fixed(thumb.size[1]) } },
            });
            ui.box(.{
                .decoration = decorationOf(empty, false),
                .layout = .{ .sizing = .{ .width = .growWeighted(1 - fraction), .height = .fixed(empty.size[1]) } },
            });
            ui.close();
            return changed;
        }

        fn snap(proposed: f64, options: SliderOptions) f64 {
            var snapped = proposed;
            if (options.step) |step| if (step > 0) {
                snapped = options.min + @round((proposed - options.min) / step) * step;
            };
            return std.math.clamp(snapped, @min(options.min, options.max), @max(options.min, options.max));
        }

        pub const TextFieldOptions = struct {
            placeholder: []const u8 = "",
            /// Its name to an assistive technology; the placeholder when empty.
            label: []const u8 = "",
            disabled: bool = false,
            width: zui.Sizing = .grow,
        };

        pub const TextFieldResult = struct {
            changed: bool = false,
            /// Enter was pressed while the field was focused.
            submitted: bool = false,
        };

        const Caret = struct {
            position: u32,
            was_focused: bool,
        };

        /// One line of editable text. Clicking places the caret; typing
        /// inserts at it; Left, Right, Home, End, Backspace and Delete move
        /// and delete by character. Focusing with Tab puts the caret at
        /// the end.
        pub fn textField(self: Self, ui: *Ui, id: zui.Id, text: *EditableText, options: TextFieldOptions) TextFieldResult {
            const state = stateOf(ui, id, options.disabled);
            const field = self.style(ui, .text_field, state);
            const caret_look = self.style(ui, .text_field_caret, state);
            const text_style = singleLine(field.text);
            const scroll_id = id.child("scroll");
            const caret = ui.state(id, Caret);
            const focused = ui.focused(id) and !options.disabled;
            var result: TextFieldResult = .{};

            var position = boundaryAtOrBefore(text.slice(), caret.position);
            if (focused and !caret.was_focused) position = text.len;
            caret.was_focused = focused;

            if (!options.disabled and pointerActivated(ui, id)) if (ui.pointerLocal(scroll_id)) |local| {
                position = positionAt(ui, text.slice(), text_style, local[0] + ui.scrollOffset(scroll_id)[0]);
            };

            if (focused) {
                for (ui.keyEvents()) |key_event| switch (key_event.key) {
                    .left => position = previousBoundary(text.slice(), position),
                    .right => position = nextBoundary(text.slice(), position),
                    .home => position = 0,
                    .end => position = text.len,
                    .backspace => if (position > 0) {
                        const start = previousBoundary(text.slice(), position);
                        text.remove(start, position);
                        position = start;
                        result.changed = true;
                    },
                    .delete => if (position < text.len) {
                        text.remove(position, nextBoundary(text.slice(), position));
                        result.changed = true;
                    },
                    .enter => result.submitted = true,
                    else => {},
                };

                var printable: [Ui.limits.max_text_input_bytes]u8 = undefined;
                var printable_len: usize = 0;
                for (ui.typedText()) |byte| {
                    if (byte < 0x20 or byte == 0x7f) continue;
                    printable[printable_len] = byte;
                    printable_len += 1;
                }
                const inserted = text.insert(position, printable[0..printable_len]);
                position += inserted;
                if (inserted != 0) result.changed = true;
            }
            caret.position = @intCast(position);

            const before = text.slice()[0..position];
            const after = text.slice()[position..];
            if (focused) if (ui.rectOf(scroll_id)) |visible| {
                const caret_left = if (before.len == 0) 0 else ui.measureText(before, text_style)[0];
                const caret_right = caret_left + caret_look.size[0];
                var offset = ui.scrollOffset(scroll_id);
                if (caret_left < offset[0]) offset[0] = caret_left;
                if (caret_right > offset[0] + visible.width) offset[0] = caret_right - visible.width;
                ui.setScrollOffset(scroll_id, offset);
            };

            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .text,
                .semantics = .{ .role = .text_field, .label = if (options.label.len != 0) options.label else options.placeholder, .value = .{ .text = text.slice() } },
                .decoration = decorationOf(field, ui.focused(id)),
                .layout = .{
                    .sizing = .{ .width = options.width, .height = .fixed(field.size[1]) },
                    .padding = field.padding,
                    .child_alignment = .{ .y = .center },
                },
            });
            ui.open(.{
                .id = scroll_id,
                .scroll = .{ .horizontal = true, .vertical = false },
                .layout = .{ .sizing = .{ .width = .grow }, .child_alignment = .{ .y = .center } },
            });
            if (text.len == 0 and !focused) {
                if (options.placeholder.len != 0) ui.text(options.placeholder, singleLine(self.style(ui, .text_field_placeholder, state).text));
            } else {
                if (before.len != 0) ui.text(before, text_style);
                ui.box(.{
                    .id = id.child("caret"),
                    .decoration = .{
                        .background = if (focused) caret_look.background else null,
                    },
                    .layout = .{ .sizing = .{ .width = .fixed(caret_look.size[0]), .height = .fixed(text_style.size) } },
                });
                if (after.len != 0) ui.text(after, text_style);
            }
            ui.close();
            ui.close();
            ui.requestTextInput(id, id.child("caret"));
            return result;
        }

        /// The character boundary nearest to `x` units from the text's start.
        fn positionAt(ui: *Ui, text: []const u8, text_style: TextStyle, x: f32) usize {
            var nearest: usize = 0;
            var nearest_distance = @abs(x);
            var boundary: usize = 0;
            while (boundary < text.len) {
                boundary = nextBoundary(text, boundary);
                const width = ui.measureText(text[0..boundary], text_style)[0];
                const distance = @abs(width - x);
                if (distance < nearest_distance) {
                    nearest = boundary;
                    nearest_distance = distance;
                } else if (width > x) break;
            }
            return nearest;
        }

        pub const DropdownOptions = struct {
            disabled: bool = false,
            /// Its name to an assistive technology.
            label: []const u8 = "",
            /// `.fit` is at least as wide as the widest label, so the
            /// control keeps its size when the selection changes.
            width: zui.Sizing = .fit,
        };

        const Popup = struct { open: bool };

        /// A button showing `labels[selected.*]` that opens a list of
        /// `labels` below it. Choosing one sets `selected` and returns
        /// true. With the list closed, Up and Down change the selection.
        /// Escape, a click outside or a `dismiss` action closes the list.
        pub fn dropdown(self: Self, ui: *Ui, id: zui.Id, selected: *usize, labels: []const []const u8, options: DropdownOptions) bool {
            const popup = ui.state(id, Popup);
            const backdrop_id = id.child("backdrop");
            var changed = false;

            if (options.disabled) {
                popup.open = false;
            } else if (ui.clicked(id)) {
                popup.open = !popup.open;
                if (popup.open and selected.* < labels.len) ui.requestFocus(id.indexedChild("option", selected.*));
            } else if (popup.open) {
                if (ui.clicked(backdrop_id)) popup.open = false;
                if (ui.keyPressed(.escape) or ui.dismissed(id.child("popup"))) {
                    popup.open = false;
                    ui.requestFocus(id);
                }
                for (0..labels.len) |index| {
                    if (!ui.clicked(id.indexedChild("option", index))) continue;
                    changed = selected.* != index;
                    selected.* = index;
                    popup.open = false;
                    ui.requestFocus(id);
                }
            } else if (ui.focused(id) and labels.len != 0) {
                const previous = selected.*;
                if (ui.keyPressed(.down)) selected.* = if (selected.* + 1 < labels.len) selected.* + 1 else @min(selected.*, labels.len - 1);
                if (ui.keyPressed(.up) and selected.* > 0) selected.* = @min(selected.*, labels.len) - 1;
                changed = selected.* != previous;
            }

            const state = stateOf(ui, id, options.disabled);
            const look = self.style(ui, .dropdown, state);
            const indicator = self.style(ui, .dropdown_indicator, state);
            const text_style = singleLine(look.text);
            const indicator_style = singleLine(indicator.text);
            var width = options.width;
            if (width.rule == .fit) {
                var widest_label: f32 = 0;
                for (labels) |option_label| widest_label = @max(widest_label, ui.measureText(option_label, text_style)[0]);
                const indicator_width = ui.measureText(indicator.glyph, indicator_style)[0];
                width.min = @max(width.min, widest_label + indicator_width + look.gap + look.padding.total(.x));
            }
            const selected_label = if (selected.* < labels.len) labels[selected.*] else "";
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .semantics = .{ .role = .combo_box, .label = options.label, .value = .{ .text = selected_label }, .state = .{ .expanded = popup.open } },
                .decoration = decorationOf(look, ui.focused(id)),
                .layout = .{
                    .sizing = .{ .width = width, .height = .fixed(look.size[1]) },
                    .padding = look.padding,
                    .child_gap = look.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
            ui.text(selected_label, text_style);
            ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
            ui.text(indicator.glyph, indicator_style);
            ui.close();

            if (popup.open) self.declarePopup(ui, id, backdrop_id, selected.*, labels);
            return changed;
        }

        fn declarePopup(self: Self, ui: *Ui, id: zui.Id, backdrop_id: zui.Id, selected: usize, labels: []const []const u8) void {
            const list = self.style(ui, .dropdown_popup, .idle);
            const viewport = ui.viewport();
            ui.box(.{
                .id = backdrop_id,
                .interactive = true,
                .floating = .{ .attach_to = .root, .z = list.layer },
                .layout = .{ .sizing = .{ .width = .fixed(viewport[0]), .height = .fixed(viewport[1]) } },
            });
            const button_width = if (ui.rectOf(id)) |rect| rect.width else 0;
            const effects: Ui.Effects = .{ .shadow = list.shadow };
            ui.open(.{
                .id = id.child("popup"),
                .effects = if (list.shadow != null) &effects else null,
                .focus_scope = true,
                .semantics = .{ .role = .list_box, .actions = .initOne(.dismiss) },
                .floating = .{ .attach_to = .{ .element = id }, .attach_point = .bottom_left, .offset = .{ 0, list.gap }, .z = list.layer + 1 },
                .decoration = decorationOf(list, false),
                .layout = .{
                    .direction = .top_to_bottom,
                    .padding = list.padding,
                    .sizing = .{ .width = .fitBetween(button_width, std.math.inf(f32)) },
                },
            });
            for (labels, 0..) |option_label, index| {
                const option_id = id.indexedChild("option", index);
                const option = self.style(ui, if (index == selected) .dropdown_option_selected else .dropdown_option, ui.widgetState(option_id));
                ui.open(.{
                    .id = option_id,
                    .focusable = true,
                    .cursor = .pointer,
                    .semantics = .{ .role = .option, .label = option_label, .state = .{ .selected = index == selected } },
                    .decoration = decorationOf(option, ui.focused(option_id)),
                    .layout = .{
                        .sizing = .{ .width = .grow, .height = .fixed(option.size[1]) },
                        .padding = option.padding,
                        .child_alignment = .{ .y = .center },
                    },
                });
                ui.text(option_label, singleLine(option.text));
                ui.close();
            }
            ui.close();
        }

        /// `dropdown` over an enum's named tags, labeled with
        /// `labelFromIdentifier`.
        pub fn dropdownEnum(self: Self, ui: *Ui, id: zui.Id, value: anytype, options: DropdownOptions) bool {
            const Enum = EnumPointee(@TypeOf(value));
            const tags = @typeInfo(Enum).@"enum".fields;
            const labels = comptime blk: {
                var tag_labels: [tags.len][]const u8 = undefined;
                for (tags, 0..) |tag, index| tag_labels[index] = labelFromIdentifier(tag.name);
                break :blk tag_labels;
            };
            var selected: usize = tags.len;
            inline for (tags, 0..) |tag, index| {
                if (@intFromEnum(value.*) == tag.value) selected = index;
            }
            if (!self.dropdown(ui, id, &selected, &labels, options)) return false;
            inline for (tags, 0..) |tag, index| {
                if (index == selected) value.* = @enumFromInt(tag.value);
            }
            return true;
        }

        /// A control disabled this frame is styled as disabled at once;
        /// `widgetState` learns of it a frame later.
        fn stateOf(ui: *const Ui, id: zui.Id, disabled: bool) zui.WidgetState {
            if (disabled) return .disabled;
            return ui.widgetState(id);
        }

        fn singleLine(text_style: TextStyle) TextStyle {
            var single_line = text_style;
            single_line.wrap = .none;
            return single_line;
        }

        fn decorationOf(look: SkinStyle, focused: bool) Ui.Decoration {
            return .{
                .background = look.background,
                .border = if (focused) look.focus_ring else look.border,
                .corner_radius = look.corner_radius,
                .corner_shape = look.corner_shape,
            };
        }

        /// Held down, or pressed and released within this frame by a
        /// pointer that is still over it. Not a keyboard activation, which
        /// says nothing about where the pointer is.
        fn pointerActivated(ui: *const Ui, id: zui.Id) bool {
            if (ui.pressed(id)) return true;
            if (!ui.clicked(id)) return false;
            const local = ui.pointerLocal(id) orelse return false;
            const rect = ui.rectOf(id) orelse return false;
            return local[0] >= 0 and local[1] >= 0 and local[0] < rect.width and local[1] < rect.height;
        }
    };
}

fn NumberPointee(comptime Pointer: type, comptime widget: []const u8) type {
    const info = @typeInfo(Pointer);
    if (info == .pointer and info.pointer.size == .one and !info.pointer.is_const) {
        switch (@typeInfo(info.pointer.child)) {
            .int, .float => return info.pointer.child,
            else => {},
        }
    }
    @compileError("zui_widgets: " ++ widget ++ " needs a pointer to an integer or float, got " ++ @typeName(Pointer));
}

fn EnumPointee(comptime Pointer: type) type {
    const info = @typeInfo(Pointer);
    if (info == .pointer and info.pointer.size == .one and !info.pointer.is_const and @typeInfo(info.pointer.child) == .@"enum") {
        if (@typeInfo(info.pointer.child).@"enum".fields.len == 0) @compileError("zui_widgets: dropdownEnum needs an enum with at least one named tag, got " ++ @typeName(info.pointer.child));
        return info.pointer.child;
    }
    @compileError("zui_widgets: dropdownEnum needs a pointer to an enum, got " ++ @typeName(Pointer));
}

fn numberToFloat(number: anytype) f64 {
    return switch (@typeInfo(@TypeOf(number))) {
        .int => @floatFromInt(number),
        .float => @floatCast(number),
        else => comptime unreachable,
    };
}

fn floatToNumber(comptime Number: type, float: f64) Number {
    return switch (@typeInfo(Number)) {
        .int => std.math.lossyCast(Number, @round(float)),
        .float => @floatCast(float),
        else => comptime unreachable,
    };
}

fn isContinuationByte(byte: u8) bool {
    return byte & 0b1100_0000 == 0b1000_0000;
}

fn previousBoundary(text: []const u8, position: usize) usize {
    if (position == 0) return 0;
    var index = position - 1;
    while (index > 0 and isContinuationByte(text[index])) index -= 1;
    return index;
}

fn nextBoundary(text: []const u8, position: usize) usize {
    if (position >= text.len) return text.len;
    var index = position + 1;
    while (index < text.len and isContinuationByte(text[index])) index += 1;
    return index;
}

/// Positions are kept across frames while the application may change the
/// text, so a stale one is pulled back inside and onto a character start.
fn boundaryAtOrBefore(text: []const u8, position: usize) usize {
    var index = @min(position, text.len);
    while (index > 0 and index < text.len and isContinuationByte(text[index])) index -= 1;
    return index;
}

test {
    _ = @import("tests.zig");
}

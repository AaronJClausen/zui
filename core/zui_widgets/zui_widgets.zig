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
    /// `label`, and `labelWith` in the `body` role and the `default` tone:
    /// `text`.
    label,
    /// `mutedLabel`, and the `muted` tone's color: `text`.
    muted_label,
    /// The `accent` tone's color: `text`.
    label_accent,
    /// `labelWith` in each other type role: `text`.
    label_display,
    label_headline,
    label_title,
    label_body_strong,
    label_label,
    label_label_strong,
    label_caption,
    label_code,
    label_numeric,
    /// `labeledRow`'s label: `text`, `size[0]` for the label's column and
    /// `gap` between the label and the control.
    row_label,
    /// The description under a row's label: `text`.
    row_description,
    /// `disclosure`'s header: `background`, `border`, `focus_ring`,
    /// `corner_radius`, `size[1]`, `padding`, `gap` and `text`.
    disclosure,
    /// The header's chevron while expanded: `glyph`, `text`, `size[0]` for
    /// the icon's side, and `motion` for its turn.
    disclosure_expanded,
    /// The header's chevron while collapsed, read as `disclosure_expanded`.
    disclosure_collapsed,
    /// A control of `ControlSize.small`: `size[0]` for its icon's side,
    /// `size[1]` for its height, and `text` for its label's type.
    control_small,
    /// A control of `ControlSize.medium`, read as `control_small`.
    control_medium,
    /// A control of `ControlSize.large`, read as `control_small`.
    control_large,
    /// `button`, a primary action: `background`, `border`, `focus_ring`,
    /// `corner_radius`, `padding`, `gap`, `text` for its color, and `scale`
    /// and `motion` while pressed. Its size is its `ControlSize`'s part.
    button,
    /// A button of `.variant = .secondary`, read as `button`.
    button_secondary,
    /// A button of `.variant = .tonal`, read as `button`.
    button_tonal,
    /// A button of `.variant = .tertiary`, read as `button`.
    button_tertiary,
    /// A button of `.variant = .danger`, read as `button`.
    button_danger,
    /// `checkbox`'s row: `size[0]` for its least width, `size[1]`, `gap` and its
    /// label's `text`.
    checkbox,
    /// The box while unchecked: `background`, `border`, `focus_ring`,
    /// `corner_radius` and `size`.
    checkbox_box,
    /// The box while checked, read as `checkbox_box`.
    checkbox_box_checked,
    /// The mark in a checked box: `background`, `corner_radius`, `size`,
    /// and `motion` as it grows in.
    checkbox_mark,
    /// `slider`: `size[1]`.
    slider,
    /// The track before the thumb: `background`, `corner_radius` and
    /// `size[1]`.
    slider_filled,
    /// The track after the thumb, read as `slider_filled`.
    slider_empty,
    /// The thumb: `background`, `border`, `corner_radius` and `size`; its
    /// `focus_ring` is drawn round the whole slider, clear of the track.
    slider_thumb,
    /// The value shown above the thumb while it is dragged: `background`,
    /// `corner_radius`, `padding`, `text`, and `gap` between it and the
    /// thumb.
    slider_bubble,
    /// A step's tick on the track before the thumb: `background`,
    /// `corner_radius` and `size`.
    slider_tick_filled,
    /// A tick after the thumb, read as `slider_tick_filled`.
    slider_tick_empty,
    /// `textField`: `background`, `border`, `focus_ring`, `corner_radius`,
    /// `size[1]`, `padding` and `text`.
    text_field,
    /// The placeholder of an empty field: `text`.
    text_field_placeholder,
    /// The caret, as tall as the field's text: `background` and `size[0]`.
    text_field_caret,
    /// A field with an error, read as `text_field`.
    text_field_error,
    /// The label shown above a field: `text`, and `gap` below it.
    text_field_label,
    /// The help below a field: `text`, and `gap` above it.
    text_field_help,
    /// The error below a field in place of its help: `text`, and `gap`
    /// above it and after its icon.
    text_field_error_message,
    /// The error's alert icon: `text` and `size[0]`.
    text_field_error_icon,
    /// The icon at a field's start: `text` and `size[0]`.
    text_field_icon,
    /// The text at a field's end, such as a unit: `text`.
    text_field_trailing,
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
    /// The check at the selected option's end: `text` and `size[0]`.
    dropdown_check,
    /// `card`: `background`, `border`, `focus_ring`, `corner_radius`,
    /// `shadow`, `padding`, `gap`, and `scale` and `motion` while pressed.
    /// A card that is not interactive is asked only `.idle`.
    card,
    /// `cardTitle`: `text`.
    card_title,
    /// `cardBody`: `text`.
    card_body,
    /// `divider`'s line: `background`, `size[0]` for its thickness and
    /// `padding.left` for how far an inset pulls it in.
    divider,
    /// A divider's label: `text`, and `gap` between it and the line.
    divider_label,
    /// `scrollArea` while it is focused: `focus_ring` and `corner_radius`.
    scroll_area,
    /// The track a scrollbar's thumb runs in, which takes the pointer:
    /// `background` and `size[0]`, its width across the scrolling axis.
    scroll_track,
    /// The thumb: `background`, `corner_radius`, `size[0]` for its
    /// thickness, `size[1]` for its least length, `padding.top` for its
    /// inset from the track's ends and side, and `motion`. The track's
    /// hover asks it `.hovered`, a drag `.pressed`.
    scroll_thumb,
    /// The fade at an edge with more content beyond it: `background`, the
    /// surface it fades into, and `size[1]`, how deep it is.
    scroll_edge_fade,
    /// The fade over a card's surface, read as `scroll_edge_fade`.
    scroll_edge_fade_raised,
    /// `groupBox`'s title: `text`, `padding`, and `gap` below it.
    group_box_title,
    /// The box its rows sit in: `background`, `border`, `corner_radius`,
    /// `shadow`, `padding` and `gap`.
    group_box_body,
    /// The description below the box: `text`, `padding`, and `gap` above it.
    group_box_description,
    /// `tabs` of `.style = .underline`, the bar: `border` along its bottom
    /// and `gap` between the tabs.
    tabs,
    /// A tab: `background`, `border`, `focus_ring`, `corner_radius`,
    /// `size[1]`, `padding` and `text`.
    tab,
    /// The selected tab, read as `tab`.
    tab_selected,
    /// The line under the selected tab's label: `background`,
    /// `corner_radius`, `size[1]` for its thickness, and `motion`.
    tab_indicator,
    /// `tabs` of `.style = .pill`, the groove: `background`,
    /// `corner_radius`, `size[1]` and `padding`.
    tabs_groove,
    /// A tab in the groove, read as `tab`.
    tab_pill,
    /// The selected tab in the groove, read as `tab`.
    tab_pill_selected,
    /// The thumb behind the selected tab in the groove: `background`,
    /// `border`, `corner_radius`, `shadow` and `motion`.
    tab_pill_thumb,
    /// `navigationList` itself: `gap` between its rows and headings.
    navigation_list,
    /// A row of `navigationList`: `background`, `border`, `focus_ring`,
    /// `corner_radius`, `size[1]`, `padding`, `gap` and `text`.
    navigation_item,
    /// The selected row, read as `navigation_item`.
    navigation_item_selected,
    /// A section's heading: `text`, `padding`, and `gap` above it.
    navigation_heading,
    /// A row's count and shortcut at its end: `text`.
    navigation_count,
    /// The selected row's count and shortcut: `text`.
    navigation_count_selected,
    /// A crumb of `breadcrumbs` that leads back: `background`, `border`,
    /// `focus_ring`, `corner_radius`, `size[1]`, `padding` and `text`.
    crumb,
    /// The page the trail ends at, read as `crumb`.
    crumb_current,
    /// Between two crumbs: `glyph`, `text`, and `gap` either side.
    crumb_separator,
    /// `radioGroup` itself: `gap` between options stacked in a column.
    radio_group,
    /// A `radioGroup` laid out in a row, read as `radio_group`.
    radio_group_horizontal,
    /// An option of a radio group: `focus_ring`, `corner_radius`, `size[0]`
    /// for its least width, `size[1]`, `gap` and its label's `text`.
    radio,
    /// The circle of an option not chosen: `background`, `border`,
    /// `corner_radius` and `size`.
    radio_circle,
    /// The chosen option's circle, its ring the border, read as
    /// `radio_circle`.
    radio_circle_selected,
    /// `segmented`'s groove: `background`, `corner_radius`, `size[1]` and
    /// `padding`.
    segmented,
    /// A segment: `background`, `border`, `focus_ring`, `corner_radius`,
    /// `size[1]`, `padding` and `text`.
    segment,
    /// The selected segment, read as `segment`.
    segment_selected,
    /// The thumb behind the selected segment: `background`, `border`,
    /// `corner_radius`, `shadow` and `motion`.
    segmented_thumb,
    /// Between two unselected segments: `background`, and `size`, its width
    /// and its share of the groove's height.
    segmented_separator,
    /// `numberStepper`'s container: `background`, `border`, `focus_ring`,
    /// `corner_radius` and `size[1]`.
    number_stepper,
    /// Its value: `text`, and `padding` either side.
    number_stepper_value,
    /// The unit after its value: `text`.
    number_stepper_unit,
    /// The button that steps down: `background`, `corner_radius`, `size[1]`
    /// for its side, `glyph` and `text`.
    number_stepper_decrement,
    /// The button that steps up, read as `number_stepper_decrement`.
    number_stepper_increment,
    /// `searchField`: read as `text_field`.
    search_field,
    /// Its search icon: `text` and `size[0]`.
    search_field_icon,
    /// The shortcut shown while it is empty and unfocused: `background`,
    /// `corner_radius`, `padding` and `text`.
    search_field_shortcut,
    /// The button that clears it: `background`, `corner_radius`, `size`,
    /// for its side and its icon's, `glyph` and `text`.
    search_field_clear,
    /// `iconButton` of `.variant = .tertiary`: `background`, `border`,
    /// `focus_ring`, `corner_radius`, `text` for its icon's color, and
    /// `scale` and `motion` while pressed. Its size is its `ControlSize`'s
    /// part.
    icon_button,
    /// An icon button of `.variant = .filled`, read as `icon_button`.
    icon_button_filled,
    /// An icon button of `.variant = .tonal`, read as `icon_button`.
    icon_button_tonal,
    /// `link`: `focus_ring`, `corner_radius`, `size[1]` for its least
    /// height, and `text`.
    link,
    /// The line under a link's text: `background` and `size[1]`.
    link_underline,
    /// `chip`: `background`, `border`, `focus_ring`, `corner_radius`,
    /// `size[1]`, `padding`, `gap` and `text`.
    chip,
    /// A selected chip, read as `chip`.
    chip_selected,
    /// The check a selected chip leads with: `text`, `size[0]`, and
    /// `motion` as it grows in.
    chip_check,
    /// The icon a chip leads with: `text` and `size[0]`.
    chip_icon,
    /// A closable chip's close button: `background`, `corner_radius`,
    /// `size` for its side and its icon's, `glyph` and `text`.
    chip_close,
    /// `toggle`'s row: `size[1]`, `gap` and its label's `text`.
    toggle,
    /// The track while off: `background`, `border`, `focus_ring`,
    /// `corner_radius` and `size`.
    toggle_track,
    /// The track while on, read as `toggle_track`.
    toggle_track_on,
    /// The thumb while off: `background`, `corner_radius`, `shadow`,
    /// `size`, `gap` for how much it widens while pressed, and `motion`.
    toggle_thumb,
    /// The thumb while on, read as `toggle_thumb`.
    toggle_thumb_on,
    /// `tooltip`'s bubble: `background`, `corner_radius`, `shadow`,
    /// `padding`, `text`, `size[0]` for its greatest width, `gap` from its
    /// anchor, `layer`, `motion` as it enters and `exit` as it leaves.
    tooltip,
    /// The shortcut after a tooltip's text: `text`, and `gap` before it.
    tooltip_shortcut,
    /// `menu`'s panel: `background`, `border`, `corner_radius`, `shadow`,
    /// `padding`, `size` for its least and greatest width, `gap` from its
    /// anchor, `layer`, `motion` and `exit`.
    menu,
    /// A menu's item: `background`, `border`, `focus_ring`,
    /// `corner_radius`, `size[1]`, `padding`, `gap` and `text`.
    menu_item,
    /// An item that destroys, read as `menu_item`.
    menu_item_danger,
    /// The icon in an item's leading column: `text` and `size[0]`.
    menu_icon,
    /// The shortcut at an item's end: `text`, and `gap` before it.
    menu_shortcut,
    /// The check of a checked item: `glyph`, `text`, and `size[0]` for the
    /// leading column's width.
    menu_check,
    /// The line between groups of items: `background`, `size[1]` for its
    /// thickness and `padding` round it.
    menu_separator,
    /// A group's label: `text` and `padding`.
    menu_section,
    /// `popover`'s panel: `background`, `border`, `corner_radius`,
    /// `shadow`, `padding`, `size[0]` for its greatest width, `gap` from its
    /// anchor, `layer`, `motion` and `exit`.
    popover,
    /// The scrim beneath a dialog: `background`, `layer`, `motion` and
    /// `exit`.
    dialog_scrim,
    /// `dialog`'s panel: `background`, `border`, `corner_radius`, `shadow`,
    /// `padding`, `gap`, `size[0]` for its greatest width, `layer`, `motion`
    /// and `exit`.
    dialog,
    /// Its title: `text`.
    dialog_title,
    /// Its description: `text`.
    dialog_description,
    /// The row of its actions: `gap`.
    dialog_actions,
    /// The button at its top trailing corner that closes it: `background`,
    /// `corner_radius`, `size[1]` for its side, `padding` for its inset from
    /// the corner, `glyph` and `text`.
    dialog_close,
    /// The stack of toasts: `padding.bottom` from the window's edge, `gap`
    /// by which each older toast shows above the next, and `layer`.
    toast_stack,
    /// A toast: `background`, `border`, `corner_radius`, `shadow`,
    /// `padding`, `gap`, `text`, `size[0]` for its greatest width, `scale`
    /// each older one shrinks by, `motion` and `exit`.
    toast,
    /// A toast's action: `focus_ring`, `corner_radius`, `size[1]` for its
    /// least height, and `text`.
    toast_action,
    /// The line under the action: `background` and `size[1]`.
    toast_action_underline,
    /// The icon of a toast of `.tone = .neutral`: `text` and `size[0]`.
    toast_icon,
    /// The icon of a toast of `.tone = .success`, read as `toast_icon`.
    toast_icon_success,
    /// The icon of a toast of `.tone = .danger`, read as `toast_icon`.
    toast_icon_danger,
};

/// How a widget moves a value it draws toward the skin's next one: at once,
/// or through `zui.motion.tween` or `zui.motion.spring`, which land at once
/// under reduced motion.
pub const Motion = union(enum) {
    none,
    tween: zui.motion.TweenOptions,
    spring: zui.motion.SpringOptions,
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
        /// Drawn at this scale about its center, where the context draws
        /// transforms.
        scale: f32 = 1,
        /// How a part that moves or fades follows this style.
        motion: Motion = .none,
        /// How a part that leaves keeps drawing as it fades, where the
        /// context keeps exit ghosts; null leaves at once.
        exit: ?zui.Exit = null,
    };
}

/// Fails to compile unless `Skin` implements the skin contract for `Ui`:
/// a struct declaring
///
/// ```zig
/// pub fn zuiStyle(skin: *const Skin, part: zui_widgets.Part, state: zui.WidgetState, environment: *const zui.Environment) zui_widgets.Style(Ui)
/// ```
///
/// and, to draw icons, optionally
///
/// ```zig
/// pub fn zuiIcon(skin: *const Skin, name: zui.design.Icon) ?zui.design.IconGlyph
/// ```
///
/// and no other `zui`-prefixed declaration. A skin without `zuiIcon`, or
/// one that returns null, has no icon font.
pub fn expectSkin(comptime Ui: type, comptime Skin: type) void {
    const name = @typeName(Skin);
    if (@typeInfo(Skin) != .@"struct") @compileError("zui_widgets: a skin must be a struct type, got " ++ name);
    for (@typeInfo(Skin).@"struct".decls) |declaration| {
        const known = std.mem.eql(u8, declaration.name, "zuiStyle") or std.mem.eql(u8, declaration.name, "zuiIcon");
        if (std.mem.startsWith(u8, declaration.name, "zui") and !known)
            @compileError("zui_widgets: " ++ name ++ " declares unknown `" ++ declaration.name ++ "`");
    }
    if (!@hasDecl(Skin, "zuiStyle")) @compileError("zui_widgets: " ++ name ++ " does not implement the skin contract: missing `zuiStyle`");
    const Expected = fn (*const Skin, Part, zui.WidgetState, *const zui.Environment) Style(Ui);
    const Found = @TypeOf(Skin.zuiStyle);
    if (Found != Expected) @compileError("zui_widgets: " ++ name ++ ".zuiStyle must be fn (*const " ++ name ++
        ", zui_widgets.Part, zui.WidgetState, *const zui.Environment) zui_widgets.Style(Ui), found " ++ @typeName(Found));
    if (@hasDecl(Skin, "zuiIcon")) {
        const FoundIcon = @TypeOf(Skin.zuiIcon);
        if (FoundIcon != fn (*const Skin, zui.design.Icon) ?zui.design.IconGlyph) @compileError("zui_widgets: " ++ name ++
            ".zuiIcon must be fn (*const " ++ name ++ ", zui.design.Icon) ?zui.design.IconGlyph, found " ++ @typeName(FoundIcon));
    }
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

        pub fn zuiIcon(skin: *const Skin, name: zui.design.Icon) ?zui.design.IconGlyph {
            return skin.tokens.icon(name);
        }

        pub fn zuiStyle(skin: *const Skin, part: Part, state: zui.WidgetState, _: *const zui.Environment) Style(Ui) {
            const tokens = skin.tokens;
            const medium_height = tokens.control_heights.get(.medium);
            const small_icon = tokens.icon_sizes.get(.small);
            return switch (part) {
                .label => skin.styled(.label, state),
                .muted_label => skin.styled(.muted_label, state),
                .label_accent => skin.styled(.label_accent, state),
                .label_display => skin.styled(.label_display, state),
                .label_headline => skin.styled(.label_headline, state),
                .label_title => skin.styled(.label_title, state),
                .label_body_strong => skin.styled(.label_body_strong, state),
                .label_label => skin.styled(.label_label, state),
                .label_label_strong => skin.styled(.label_label_strong, state),
                .label_caption => skin.styled(.label_caption, state),
                .label_code => skin.styled(.label_code, state),
                .label_numeric => skin.styled(.label_numeric, state),
                .row_label => sized(skin.styled(.row_label, state), .{ label_column_width * tokens.text_padding_scale, 0 }),
                .row_description => skin.styled(.row_description, state),
                .disclosure => sized(skin.styled(.disclosure, state), .{ 0, medium_height }),
                .disclosure_expanded, .disclosure_collapsed => chevron: {
                    var chevron = sized(withGlyph(skin.styled(.disclosure_indicator, state), if (part == .disclosure_expanded) "v" else ">"), .{ small_icon, 0 });
                    chevron.motion = .{ .tween = tokens.motion.disclosure };
                    break :chevron chevron;
                },
                .control_small => skin.controlOfSize(.control_small, .small, state),
                .control_medium => skin.controlOfSize(.control_medium, .medium, state),
                .control_large => skin.controlOfSize(.control_large, .large, state),
                .button => skin.button(.button, state),
                .button_secondary => skin.button(.button_secondary, state),
                .button_tonal => skin.button(.button_tonal, state),
                .button_tertiary => skin.button(.button_tertiary, state),
                .button_danger => skin.button(.button_danger, state),
                .checkbox => sized(skin.styled(.checkbox, state), .{ tokens.target_floors.get(.pointer), tokens.control_heights.get(.small) }),
                .checkbox_box => skin.checkboxBox(.checkbox_box, state),
                .checkbox_box_checked => skin.checkboxBox(.checkbox_box_checked, state),
                .checkbox_mark => mark: {
                    const side = @round(skin.checkboxSide() * check_mark_share);
                    const icon = skin.styled(.checkbox_mark, state);
                    break :mark .{ .background = icon.text.color, .corner_radius = .all(check_mark_corner_radius), .size = .{ side, side }, .motion = .{ .tween = tokens.motion.check } };
                },
                .slider => .{ .size = .{ 0, medium_height } },
                .slider_filled => sized(skin.styled(.slider_filled, state), .{ 0, slider_track_thickness }),
                .slider_empty => sized(skin.styled(.slider_empty, state), .{ 0, slider_track_thickness }),
                .slider_thumb => thumb: {
                    var thumb = sized(skin.styled(.slider_thumb, state), @splat(slider_thumb_side));
                    if (thumb.border) |*border| border.widths = .all(slider_thumb_border_width);
                    break :thumb thumb;
                },
                .slider_bubble => bubble: {
                    var bubble = skin.styled(.slider_bubble, state);
                    bubble.gap = slider_bubble_offset;
                    break :bubble bubble;
                },
                .slider_tick_filled => tick: {
                    const tick = skin.styled(.slider_tick_filled, state);
                    break :tick .{ .background = tick.text.color, .corner_radius = .all(slider_tick_side / 2), .size = @splat(slider_tick_side) };
                },
                .slider_tick_empty => tick: {
                    const tick = skin.styled(.slider_tick_empty, state);
                    break :tick .{ .background = tick.text.color, .corner_radius = .all(slider_tick_side / 2), .size = @splat(slider_tick_side) };
                },
                .text_field => sized(skin.styled(.text_field, state), .{ 0, medium_height }),
                .text_field_error => field: {
                    var field = sized(skin.styled(.text_field_error, state), .{ 0, medium_height });
                    if (field.border) |*border| border.widths = .all(text_field_error_border_width);
                    break :field field;
                },
                .text_field_placeholder => skin.styled(.text_field_placeholder, state),
                .text_field_caret => sized(skin.styled(.text_field_caret, state), .{ caret_width, 0 }),
                .text_field_label => skin.styled(.text_field_label, state),
                .text_field_help => skin.styled(.text_field_help, state),
                .text_field_error_message => skin.styled(.text_field_error_message, state),
                .text_field_error_icon => sized(skin.styled(.text_field_error_icon, state), .{ error_icon_side, 0 }),
                .text_field_icon => sized(skin.styled(.text_field_icon, state), .{ small_icon, 0 }),
                .text_field_trailing => skin.styled(.text_field_trailing, state),
                .dropdown => sized(skin.styled(.dropdown, state), .{ 0, medium_height }),
                .dropdown_indicator => sized(withGlyph(skin.styled(.dropdown_indicator, state), "v"), .{ small_icon, 0 }),
                .dropdown_popup => skin.lifted(.dropdown_popup, state, .floating),
                .dropdown_option => sized(skin.styled(.dropdown_option, state), .{ 0, medium_height }),
                .dropdown_option_selected => sized(skin.styled(.dropdown_option_selected, state), .{ 0, medium_height }),
                .dropdown_check => sized(skin.styled(.dropdown_check, state), .{ small_icon, 0 }),
                .card => card: {
                    var card = skin.raised(.card, state, if (state == .hovered) .floating else .raised);
                    card.motion = .{ .tween = tokens.motion.press };
                    if (state == .pressed) card.scale = card_pressed_scale;
                    break :card card;
                },
                .card_title => skin.styled(.card_title, state),
                .card_body => skin.styled(.card_body, state),
                .divider => sized(skin.styled(.divider, state), .{ divider_thickness, 0 }),
                .divider_label => skin.styled(.divider_label, state),
                .scroll_area => skin.styled(.scroll_area, state),
                .scroll_track => track: {
                    var track = sized(skin.styled(.scroll_track, state), .{ tokens.target_floors.get(.pointer), 0 });
                    if (track.background) |color| track.background = faded(color, scroll_track_hovered_share);
                    break :track track;
                },
                .scroll_thumb => skin.scrollThumb(state),
                .scroll_edge_fade => sized(skin.styled(.scroll_edge_fade, state), .{ 0, scroll_edge_fade_depth }),
                .scroll_edge_fade_raised => sized(skin.styled(.scroll_edge_fade_raised, state), .{ 0, scroll_edge_fade_depth }),
                .group_box_title => skin.styled(.group_box_title, state),
                .group_box_body => skin.raised(.group_box_body, state, .raised),
                .group_box_description => skin.styled(.group_box_description, state),
                .tabs => bar: {
                    var bar = skin.styled(.tabs, state);
                    if (bar.border) |*border| border.widths = .{ .bottom = tokens.outline_width };
                    break :bar bar;
                },
                .tab => sized(skin.styled(.tab, state), .{ 0, medium_height }),
                .tab_selected => sized(skin.styled(.tab_selected, state), .{ 0, medium_height }),
                .tab_indicator => indicator: {
                    var indicator = sized(skin.styled(.tab_indicator, state), .{ 0, tab_indicator_thickness });
                    indicator.motion = .{ .spring = tokens.motion.toggle };
                    break :indicator indicator;
                },
                .tabs_groove => sized(skin.styled(.tabs_groove, state), .{ 0, medium_height }),
                .tab_pill => sized(skin.styled(.tab_pill, state), .{ 0, skin.pillHeight() }),
                .tab_pill_selected => sized(skin.styled(.tab_pill_selected, state), .{ 0, skin.pillHeight() }),
                .tab_pill_thumb => thumb: {
                    var thumb = sized(skin.raised(.tab_pill_thumb, state, .raised), .{ 0, skin.pillHeight() });
                    thumb.corner_radius = skin.nestedInGroove();
                    thumb.motion = .{ .spring = tokens.motion.toggle };
                    break :thumb thumb;
                },
                .navigation_list => skin.styled(.navigation_list, state),
                .navigation_item => sized(skin.styled(.navigation_item, state), .{ 0, medium_height }),
                .navigation_item_selected => sized(skin.styled(.navigation_item_selected, state), .{ 0, medium_height }),
                .navigation_heading => skin.styled(.navigation_heading, state),
                .navigation_count => skin.styled(.navigation_count, state),
                .navigation_count_selected => skin.styled(.navigation_count_selected, state),
                .crumb => sized(skin.styled(.crumb, state), .{ 0, tokens.control_heights.get(.small) }),
                .crumb_current => sized(skin.styled(.crumb_current, state), .{ 0, tokens.control_heights.get(.small) }),
                .crumb_separator => withGlyph(skin.styled(.crumb_separator, state), "›"),
                .radio_group => skin.styled(.radio_group, state),
                .radio_group_horizontal => skin.styled(.radio_group_horizontal, state),
                .radio => sized(skin.styled(.radio, state), .{ tokens.target_floors.get(.pointer), tokens.control_heights.get(.small) }),
                .radio_circle => skin.radioCircle(.radio_circle, checkbox_border_width, state),
                .radio_circle_selected => skin.radioCircle(.radio_circle_selected, radio_ring_width, state),
                .segmented => sized(skin.styled(.segmented, state), .{ 0, medium_height }),
                .segment => sized(skin.styled(.segment, state), .{ 0, skin.pillHeight() }),
                .segment_selected => sized(skin.styled(.segment_selected, state), .{ 0, skin.pillHeight() }),
                .segmented_thumb => thumb: {
                    var thumb = sized(skin.raised(.segmented_thumb, state, .raised), .{ 0, skin.pillHeight() });
                    thumb.corner_radius = skin.nestedInGroove();
                    thumb.motion = .{ .spring = tokens.motion.toggle };
                    break :thumb thumb;
                },
                .segmented_separator => sized(skin.styled(.segmented_separator, state), .{ divider_thickness, segmented_separator_share }),
                .number_stepper => sized(skin.styled(.number_stepper, state), .{ 0, medium_height }),
                .number_stepper_value => skin.styled(.number_stepper_value, state),
                .number_stepper_unit => skin.styled(.number_stepper_unit, state),
                .number_stepper_decrement => sized(withGlyph(skin.styled(.number_stepper_decrement, state), "-"), .{ small_icon, medium_height }),
                .number_stepper_increment => sized(withGlyph(skin.styled(.number_stepper_increment, state), "+"), .{ small_icon, medium_height }),
                .search_field => sized(skin.styled(.search_field, state), .{ 0, medium_height }),
                .search_field_icon => sized(skin.styled(.search_field_icon, state), .{ small_icon, 0 }),
                .search_field_shortcut => skin.styled(.search_field_shortcut, state),
                .search_field_clear => sized(withGlyph(skin.styled(.search_field_clear, state), "×"), .{ small_icon, tokens.control_heights.get(.small) }),
                .icon_button => skin.button(.icon_button, state),
                .icon_button_filled => skin.button(.icon_button_filled, state),
                .icon_button_tonal => skin.button(.icon_button_tonal, state),
                .link => sized(skin.styled(.link, state), .{ 0, tokens.target_floors.get(.pointer) }),
                .link_underline => underline: {
                    var underline = sized(skin.styled(.link_underline, state), .{ 0, link_underline_thickness });
                    const hovered = state == .hovered or state == .pressed;
                    if (!hovered) if (underline.background) |line| {
                        underline.background = faded(line, link_underline_resting_share);
                    };
                    break :underline underline;
                },
                .chip => sized(skin.styled(.chip, state), .{ 0, tokens.control_heights.get(.small) }),
                .chip_selected => sized(skin.styled(.chip_selected, state), .{ 0, tokens.control_heights.get(.small) }),
                .chip_check => check: {
                    var check = sized(skin.styled(.chip_check, state), .{ small_icon, 0 });
                    check.motion = .{ .tween = tokens.motion.check };
                    break :check check;
                },
                .chip_icon => sized(skin.styled(.chip_icon, state), .{ small_icon, 0 }),
                .chip_close => sized(withGlyph(skin.styled(.chip_close, state), "×"), .{ small_icon, tokens.target_floors.get(.pointer) }),
                .toggle => sized(skin.styled(.toggle, state), .{ 0, tokens.control_heights.get(.small) }),
                .toggle_track => skin.toggleTrack(.toggle_track, state),
                .toggle_track_on => skin.toggleTrack(.toggle_track_on, state),
                .toggle_thumb => skin.toggleThumb(.toggle_thumb, state),
                .toggle_thumb_on => skin.toggleThumb(.toggle_thumb_on, state),
                .tooltip => bubble: {
                    var bubble = sized(skin.styled(.tooltip, state), .{ tooltip_greatest_width, 0 });
                    bubble.shadow = tokens.elevations.get(.floating).shadow;
                    bubble.layer = tooltip_layer;
                    bubble.motion = .{ .tween = tokens.motion.popover_enter };
                    bubble.exit = exitThrough(tokens.motion.popover_exit);
                    break :bubble bubble;
                },
                .tooltip_shortcut => skin.styled(.tooltip_shortcut, state),
                .menu => panel: {
                    var panel = sized(skin.lifted(.menu, state, .floating), .{ menu_least_width, menu_greatest_width });
                    panel.motion = .{ .tween = tokens.motion.popover_enter };
                    panel.exit = exitThrough(tokens.motion.popover_exit);
                    break :panel panel;
                },
                .menu_item => skin.menuItem(.menu_item, state),
                .menu_item_danger => skin.menuItem(.menu_item_danger, state),
                .menu_icon => sized(skin.styled(.menu_icon, state), .{ small_icon, 0 }),
                .menu_shortcut => skin.styled(.menu_shortcut, state),
                .menu_check => sized(withGlyph(skin.styled(.menu_check, state), "•"), .{ small_icon, 0 }),
                .menu_separator => sized(skin.styled(.menu_separator, state), .{ 0, divider_thickness }),
                .menu_section => skin.styled(.menu_section, state),
                .popover => panel: {
                    var panel = sized(skin.lifted(.popover, state, .floating), .{ popover_greatest_width, 0 });
                    panel.motion = .{ .tween = tokens.motion.popover_enter };
                    panel.exit = exitThrough(tokens.motion.popover_exit);
                    break :panel panel;
                },
                .dialog_scrim => scrim: {
                    var scrim = skin.styled(.dialog_scrim, state);
                    scrim.layer = dialog_layer;
                    scrim.motion = .{ .tween = tokens.motion.dialog_enter };
                    scrim.exit = exitThrough(tokens.motion.dialog_exit);
                    break :scrim scrim;
                },
                .dialog => panel: {
                    var panel = sized(skin.lifted(.dialog, state, .modal), .{ dialog_greatest_width, 0 });
                    panel.layer = dialog_layer + 1;
                    panel.motion = .{ .tween = tokens.motion.dialog_enter };
                    panel.exit = exitThrough(tokens.motion.dialog_exit);
                    break :panel panel;
                },
                .dialog_title => skin.styled(.dialog_title, state),
                .dialog_description => skin.styled(.dialog_description, state),
                .dialog_actions => skin.styled(.dialog_actions, state),
                .dialog_close => sized(withGlyph(skin.styled(.dialog_close, state), "×"), .{ small_icon, tokens.control_heights.get(.small) }),
                .toast_stack => stack: {
                    var stack = skin.styled(.toast_stack, state);
                    stack.layer = toast_layer;
                    break :stack stack;
                },
                .toast => toast: {
                    var toast = sized(skin.styled(.toast, state), .{ toast_greatest_width, 0 });
                    toast.shadow = tokens.elevations.get(.modal).shadow;
                    toast.scale = toast_tucked_scale;
                    toast.motion = .{ .spring = tokens.motion.toast_enter };
                    toast.exit = exitThrough(tokens.motion.toast_exit);
                    break :toast toast;
                },
                .toast_action => sized(skin.styled(.toast_action, state), .{ 0, tokens.target_floors.get(.pointer) }),
                .toast_action_underline => underline: {
                    var underline = sized(skin.styled(.toast_action_underline, state), .{ 0, link_underline_thickness });
                    const hovered = state == .hovered or state == .pressed;
                    if (!hovered) if (underline.background) |line| {
                        underline.background = faded(line, link_underline_resting_share);
                    };
                    break :underline underline;
                },
                .toast_icon => sized(skin.styled(.toast_icon, state), .{ tokens.icon_sizes.get(.medium), 0 }),
                .toast_icon_success => sized(skin.styled(.toast_icon_success, state), .{ tokens.icon_sizes.get(.medium), 0 }),
                .toast_icon_danger => sized(skin.styled(.toast_icon_danger, state), .{ tokens.icon_sizes.get(.medium), 0 }),
            };
        }

        /// A popup standing at `elevation`: that level's surface, rim and
        /// shadow.
        fn lifted(skin: *const Skin, comptime designed: Designed.Part, state: zui.WidgetState, elevation: zui.design.Elevation) Style(Ui) {
            const tokens = skin.tokens;
            const lift = tokens.elevations.get(elevation);
            var panel = skin.styled(designed, state);
            panel.background = tokens.colors.get(state).get(lift.surface);
            panel.border = if (lift.rim) |rim| .{ .color = rim, .widths = .all(tokens.outline_width) } else null;
            panel.shadow = lift.shadow;
            panel.layer = popup_layer;
            return panel;
        }

        /// The approved item is as tall as a medium control, its corners
        /// the panel's less the panel's padding.
        fn menuItem(skin: *const Skin, comptime designed: Designed.Part, state: zui.WidgetState) Style(Ui) {
            const tokens = skin.tokens;
            var item = sized(skin.styled(designed, state), .{ 0, tokens.control_heights.get(.medium) });
            item.corner_radius = nestedCorner(tokens.corner_radii.get(.popup), tokens.space(.xs));
            return item;
        }

        fn exitThrough(tween: zui.motion.TweenOptions) zui.Exit {
            return .{ .seconds = tween.duration, .fade = switch (tween.easing) {
                inline else => |easing| @field(zui.ExitFade, @tagName(easing)),
            } };
        }

        fn radioCircle(skin: *const Skin, comptime designed: Designed.Part, ring_width: f32, state: zui.WidgetState) Style(Ui) {
            var circle = sized(skin.styled(designed, state), @splat(skin.checkboxSide()));
            if (circle.border) |*border| border.widths = .all(ring_width);
            return circle;
        }

        /// The approved switch is 32 by 20, 40 by 24 and 48 by 28 at the
        /// three densities.
        fn toggleTrack(skin: *const Skin, comptime designed: Designed.Part, state: zui.WidgetState) Style(Ui) {
            const height = skin.toggleTrackHeight();
            var track = sized(skin.styled(designed, state), .{ 2 * height - 8, height });
            track.corner_radius = .all(height / 2);
            return track;
        }

        fn toggleThumb(skin: *const Skin, comptime designed: Designed.Part, state: zui.WidgetState) Style(Ui) {
            const side = skin.toggleTrackHeight() - 2 * toggle_thumb_inset;
            var thumb = sized(skin.styled(designed, state), @splat(side));
            thumb.corner_radius = .all(side / 2);
            thumb.shadow = skin.tokens.elevations.get(.raised).shadow;
            thumb.gap = toggle_thumb_pressed_widening;
            thumb.motion = .{ .spring = skin.tokens.motion.toggle };
            return thumb;
        }

        fn toggleTrackHeight(skin: *const Skin) f32 {
            return skin.tokens.control_heights.get(.small) - 4;
        }

        /// The groove's control corner, less its padding, for what sits in it.
        fn nestedInGroove(skin: *const Skin) zui.CornerRadius {
            return nestedCorner(skin.tokens.corner_radii.get(.control), skin.tokens.space(.hair));
        }

        fn nestedCorner(outer: zui.CornerRadius, padding: f32) zui.CornerRadius {
            return .{
                .top_left = @max(outer.top_left - padding, 0),
                .top_right = @max(outer.top_right - padding, 0),
                .bottom_left = @max(outer.bottom_left - padding, 0),
                .bottom_right = @max(outer.bottom_right - padding, 0),
            };
        }

        /// A part standing at `elevation`: the rim and the shadow of that
        /// level, on the raised surface at rest. A state lifts or presses
        /// the part rather than tinting it, so the muted text on it keeps
        /// its contrast.
        fn raised(skin: *const Skin, comptime designed: Designed.Part, state: zui.WidgetState, elevation: zui.design.Elevation) Style(Ui) {
            const tokens = skin.tokens;
            const resting = tokens.elevations.get(.raised);
            const lift = tokens.elevations.get(elevation);
            var part = skin.styled(designed, state);
            part.background = tokens.colors.get(.idle).get(resting.surface);
            part.border = if (resting.rim) |rim| .{ .color = rim, .widths = .all(tokens.outline_width) } else null;
            part.shadow = lift.shadow;
            return part;
        }

        /// The approved thumb is 6, 8 and 10 thick at rest at the three
        /// densities, and 4 more while the pointer is over its track.
        fn scrollThumb(skin: *const Skin, state: zui.WidgetState) Style(Ui) {
            const tokens = skin.tokens;
            const resting_thickness = (tokens.control_heights.get(.medium) - 4) / 4;
            const widened = state == .hovered or state == .pressed;
            const least_length = @max(scroll_thumb_least_length, tokens.target_floors.get(.pointer));
            var thumb = sized(skin.styled(.scroll_thumb, state), .{ if (widened) resting_thickness + scroll_thumb_widening else resting_thickness, least_length });
            thumb.padding = .all(scroll_thumb_inset);
            thumb.motion = .{ .tween = tokens.motion.state };
            const share: f32 = switch (state) {
                .hovered => scroll_thumb_hovered_share,
                .pressed => scroll_thumb_dragged_share,
                else => scroll_thumb_resting_share,
            };
            if (thumb.background) |color| thumb.background = faded(color, share);
            return thumb;
        }

        fn controlOfSize(skin: *const Skin, comptime designed: Designed.Part, size: zui.design.ControlSize, state: zui.WidgetState) Style(Ui) {
            return sized(skin.styled(designed, state), .{ skin.tokens.icon_sizes.get(size), skin.tokens.control_heights.get(size) });
        }

        /// A pressed control shrinks to the design's press scale.
        fn button(skin: *const Skin, comptime designed: Designed.Part, state: zui.WidgetState) Style(Ui) {
            var pressable = skin.styled(designed, state);
            pressable.motion = .{ .tween = skin.tokens.motion.press };
            if (state == .pressed) pressable.scale = skin.tokens.motion.press_scale;
            return pressable;
        }

        fn pillHeight(skin: *const Skin) f32 {
            return skin.tokens.control_heights.get(.medium) - 2 * skin.tokens.space(.hair);
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
const slider_bubble_offset = 8;
const slider_tick_side = 4;
/// A slider of more steps draws no ticks, which would run together.
const slider_ticks_most = 64;
const text_field_error_border_width = 2;
const radio_ring_width = 5.5;
const segmented_separator_share = 0.5;
const link_underline_thickness = 1;
const link_underline_resting_share = 0.4;
const toggle_thumb_inset = 2;
const toggle_thumb_pressed_widening = 4;
/// A number stepper's value is at least as wide as these digits.
const stepper_value_widest = "0000";
/// How far the pointer moves along a number stepper's value per step it
/// scrubs.
const stepper_scrub_distance = 4;
const error_icon_side = 12;
/// Popups paint in this layer and the next one up, over toasts and dialogs,
/// so a menu or a dropdown opened in a dialog shows above it; tooltips paint
/// over them all.
const popup_layer = 100;
const dialog_layer = 50;
const toast_layer = 60;
const tooltip_layer = 120;
const tooltip_greatest_width = 240;
const tooltip_delay_seconds = 0.5;
/// A tooltip shows at once within this long of another closing, as the
/// pointer moves along a toolbar.
const tooltip_warm_seconds = 0.3;
const menu_least_width = 200;
const menu_greatest_width = 320;
/// Up and Down skip the disabled ones among a menu's first this many items.
const menu_items_tracked = 64;
const popover_greatest_width = 360;
const dialog_greatest_width = 480;
/// A dialog in a window narrower than this is a sheet along its bottom.
const bottom_sheet_below_width = 600;
const toast_greatest_width = 420;
const toast_tucked_scale = 0.96;
const toast_seconds = 5;
/// Shown at once; the rest wait their turn.
const toasts_shown_most = 3;
const toast_message_capacity = 160;
const toast_action_capacity = 32;
/// How far an overlay slides as it enters, toward where it settles.
const enter_slide = 8;
const toast_enter_slide = 24;
const enter_scale = 0.96;
/// An overlay kept inside the window stays this far from its edges.
const viewport_margin = 8;
const card_pressed_scale = 0.985;
const divider_thickness = 1;
const scroll_thumb_widening = 4;
const scroll_thumb_least_length = 32;
const scroll_thumb_inset = 2;
const scroll_thumb_resting_share = 0.28;
const scroll_thumb_hovered_share = 0.44;
const scroll_thumb_dragged_share = 0.56;
const scroll_track_hovered_share = 0.06;
const scroll_edge_fade_depth = 16;
const tab_indicator_thickness = 2;

const keyboard_scroll_step = 40;
/// Of the view, so a line of the last page stays in sight on the next.
const page_share = 0.9;
const scrollbar_idle_seconds = 0.8;
const most_crumbs_shown = 4;
const collapsed_crumbs_glyph = "…";

/// `color` with its alpha scaled by `share`, in any context's color type.
fn faded(color: anytype, share: f32) @TypeOf(color) {
    var clear = color;
    clear.a = 0;
    return clear.mix(color, share);
}

/// The roles and tiers each part of `DesignSkin` is drawn in. Text on the
/// page is drawn `.on` `page`, the surface beneath every widget.
const Designed = struct {
    pub const Part = enum {
        page,
        label,
        muted_label,
        label_accent,
        label_display,
        label_headline,
        label_title,
        label_body_strong,
        label_label,
        label_label_strong,
        label_caption,
        label_code,
        label_numeric,
        row_label,
        row_description,
        disclosure,
        disclosure_indicator,
        control_small,
        control_medium,
        control_large,
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
        slider_bubble,
        slider_tick_filled,
        slider_tick_empty,
        text_field,
        text_field_error,
        text_field_placeholder,
        text_field_caret,
        text_field_label,
        text_field_help,
        text_field_error_message,
        text_field_error_icon,
        text_field_icon,
        text_field_trailing,
        dropdown,
        dropdown_indicator,
        dropdown_popup,
        dropdown_option,
        dropdown_option_selected,
        dropdown_check,
        card,
        card_title,
        card_body,
        divider,
        divider_label,
        scroll_area,
        scroll_track,
        scroll_thumb,
        scroll_edge_fade,
        scroll_edge_fade_raised,
        group_box_title,
        group_box_body,
        group_box_description,
        tabs,
        tab,
        tab_selected,
        tab_indicator,
        tabs_groove,
        tab_pill,
        tab_pill_selected,
        tab_pill_thumb,
        navigation_list,
        navigation_item,
        navigation_item_selected,
        navigation_heading,
        navigation_count,
        navigation_count_selected,
        crumb,
        crumb_current,
        crumb_separator,
        radio_group,
        radio_group_horizontal,
        radio,
        radio_circle,
        radio_circle_selected,
        segmented,
        segment,
        segment_selected,
        segmented_thumb,
        segmented_separator,
        number_stepper,
        number_stepper_value,
        number_stepper_unit,
        number_stepper_decrement,
        number_stepper_increment,
        search_field,
        search_field_icon,
        search_field_shortcut,
        search_field_clear,
        icon_button,
        icon_button_filled,
        icon_button_tonal,
        link,
        link_underline,
        chip,
        chip_selected,
        chip_check,
        chip_icon,
        chip_close,
        toggle,
        toggle_track,
        toggle_track_on,
        toggle_thumb,
        toggle_thumb_on,
        tooltip,
        tooltip_shortcut,
        menu,
        menu_item,
        menu_item_danger,
        menu_icon,
        menu_shortcut,
        menu_check,
        menu_separator,
        menu_section,
        popover,
        dialog_scrim,
        dialog,
        dialog_title,
        dialog_description,
        dialog_actions,
        dialog_close,
        toast_stack,
        toast,
        toast_action,
        toast_action_underline,
        toast_icon,
        toast_icon_success,
        toast_icon_danger,
    };

    const on_hover: zui.design.PartAppearance(void).Colors = .{ .surface = .secondary_container, .text = .on_secondary_container };

    pub const zuiAppearance = zui.design.Appearance(@This().Part, .{
        .page = .{ .surface = .surface },
        .label = .{ .text = .on_surface, .type = .body, .on = .page },
        .muted_label = .{ .text = .on_surface_muted, .type = .body, .on = .page },
        .label_accent = .{ .text = .on_surface_accent, .type = .body, .on = .page },
        .label_display = onPage(.display),
        .label_headline = onPage(.headline),
        .label_title = onPage(.title),
        .label_body_strong = onPage(.body_strong),
        .label_label = onPage(.label),
        .label_label_strong = onPage(.label_strong),
        .label_caption = onPage(.caption),
        .label_code = onPage(.code),
        .label_numeric = onPage(.numeric),
        .row_label = .{ .text = .on_surface, .type = .body, .on = .page, .gap = .l },
        .row_description = .{ .text = .on_surface_muted, .type = .caption, .on = .page },
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
        .control_small = .{ .type = .label_strong },
        .control_medium = .{ .type = .body_strong },
        .control_large = .{ .type = .body_strong },
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
        .slider_bubble = .{ .surface = .surface_inverse, .text = .on_surface_inverse, .type = .label_strong, .on = .slider_bubble, .shape = .chip, .padding = .{ .x = .s, .y = .xs } },
        .slider_tick_filled = .{ .icon = .on_accent, .on = .slider_filled },
        .slider_tick_empty = .{ .icon = .outline, .on = .slider_empty },
        .text_field = textField(false),
        .text_field_error = textField(true),
        .text_field_placeholder = .{ .text = .on_surface_muted, .type = .body, .on = .text_field },
        .text_field_caret = .{ .surface = .accent },
        .text_field_label = .{ .text = .on_surface, .type = .label_strong, .on = .page, .gap = .xs },
        .text_field_help = .{ .text = .on_surface_muted, .type = .caption, .on = .page, .gap = .xs },
        .text_field_error_message = .{ .text = .on_danger_container, .type = .caption, .on = .page, .gap = .xs },
        .text_field_error_icon = .{ .icon = .danger, .on = .page },
        .text_field_icon = .{ .icon = .on_surface_muted, .on = .text_field },
        .text_field_trailing = .{ .text = .on_surface_muted, .type = .body, .on = .text_field },
        .dropdown = .{ .surface = .surface_sunken, .text = .on_surface, .type = .body, .on = .dropdown, .shape = .control, .padding = .{ .x = .m }, .gap = .s, .target = .pointer },
        // Muted only at rest: a focused or pressed button's layer leaves muted
        // text short of its contrast.
        .dropdown_indicator = .{ .text = .on_surface_muted, .type = .body, .on = .dropdown, .states = .{ .focused = .{ .text = .on_surface }, .pressed = .{ .text = .on_surface } } },
        .dropdown_popup = .{ .surface = .surface_overlay, .shape = .popup, .padding = .{ .x = .xs, .y = .xs }, .gap = .xs },
        .dropdown_option = option(.body),
        .dropdown_option_selected = selected: {
            var selected = option(.body_strong);
            selected.cue = "its label in the strong font and its check";
            break :selected selected;
        },
        .dropdown_check = .{ .icon = .on_surface_accent, .on = .dropdown_popup },
        .card = .{ .surface = .surface_raised, .shape = .container, .padding = .{ .x = .l, .y = .l }, .gap = .m, .target = .pointer },
        .card_title = .{ .text = .on_surface, .type = .title, .on = .card },
        .card_body = .{ .text = .on_surface_muted, .type = .body, .on = .card },
        .divider = .{ .surface = .outline_muted, .padding = .{ .x = .l } },
        .divider_label = .{ .text = .on_surface_muted, .type = .caption, .on = .page, .gap = .m },
        .scroll_area = .{ .shape = .control, .target = .pointer },
        .scroll_track = .{ .states = .{ .hovered = .{ .surface = .on_surface }, .pressed = .{ .surface = .on_surface } } },
        .scroll_thumb = .{ .surface = .on_surface, .shape = .indicator },
        .scroll_edge_fade = .{ .surface = .surface },
        .scroll_edge_fade_raised = .{ .surface = .surface_raised },
        .group_box_title = .{ .text = .on_surface_muted, .type = .label_strong, .on = .page, .padding = .{ .x = .l }, .gap = .s },
        .group_box_body = .{ .surface = .surface_raised, .shape = .container, .padding = .{ .x = .l, .y = .s }, .gap = .s },
        .group_box_description = .{ .text = .on_surface_muted, .type = .caption, .on = .page, .padding = .{ .x = .l }, .gap = .s },
        .tabs = .{ .outline = .outline_muted, .gap = .xs },
        .tab = tab(.on_surface_muted, .page),
        .tab_selected = selected: {
            var selected = tab(.on_surface_accent, .page);
            selected.states = .{};
            selected.cue = "the line beneath its label";
            break :selected selected;
        },
        .tab_indicator = .{ .surface = .accent, .shape = .indicator },
        .tabs_groove = .{ .surface = .surface_sunken, .shape = .control, .padding = .{ .x = .hair, .y = .hair } },
        .tab_pill = tab(.on_surface_muted, .tabs_groove),
        .tab_pill_selected = selected: {
            var selected = tab(.on_surface, .tab_pill_thumb);
            selected.cue = "the raised thumb behind it";
            break :selected selected;
        },
        .tab_pill_thumb = .{ .surface = .surface_raised, .shape = .control },
        .navigation_list = .{ .gap = .xs },
        .navigation_item = .{
            .text = .on_surface,
            .type = .body,
            .on = .page,
            .shape = .control,
            .padding = .{ .x = .m },
            .gap = .m,
            .target = .pointer,
            .states = .{ .hovered = on_hover, .pressed = on_hover },
        },
        .navigation_item_selected = .{
            .surface = .accent_container,
            .text = .on_accent_container,
            .type = .body_strong,
            .on = .navigation_item_selected,
            .shape = .control,
            .padding = .{ .x = .m },
            .gap = .m,
            .target = .pointer,
            .cue = "its fill and its label in the strong font",
        },
        .navigation_heading = .{ .text = .on_surface_muted, .type = .label_strong, .on = .page, .padding = .{ .x = .m, .y = .s }, .gap = .l },
        .navigation_count = .{ .text = .on_surface_muted, .type = .label, .on = .page, .states = .{ .hovered = .{ .text = .on_secondary_container }, .pressed = .{ .text = .on_secondary_container } } },
        .navigation_count_selected = .{ .text = .on_accent_container, .type = .label, .on = .navigation_item_selected },
        .crumb = .{
            .text = .on_surface_muted,
            .type = .label,
            .on = .page,
            .shape = .control,
            .padding = .{ .x = .xs },
            .target = .pointer,
            .states = .{ .hovered = .{ .text = .on_surface }, .pressed = .{ .text = .on_surface } },
        },
        .crumb_current = .{ .text = .on_surface, .type = .label_strong, .on = .page, .padding = .{ .x = .xs } },
        .crumb_separator = .{ .text = .on_surface_muted, .type = .label, .on = .page, .gap = .xs },
        .radio_group = .{ .gap = .s },
        .radio_group_horizontal = .{ .gap = .l },
        .radio = .{ .text = .on_surface, .type = .body, .on = .page, .shape = .control, .gap = .s, .target = .pointer },
        .radio_circle = .{ .surface = .surface, .outline = .outline, .shape = .indicator },
        .radio_circle_selected = .{ .surface = .on_accent, .outline = .accent, .shape = .indicator, .cue = "its ring" },
        .segmented = .{ .surface = .surface_sunken, .shape = .control, .padding = .{ .x = .hair, .y = .hair } },
        .segment = .{
            .text = .on_surface_muted,
            .type = .label_strong,
            .on = .segmented,
            .shape = .control,
            .padding = .{ .x = .m },
            .target = .pointer,
            .states = .{ .hovered = .{ .text = .on_surface }, .pressed = .{ .text = .on_surface } },
        },
        .segment_selected = .{ .text = .on_surface, .type = .label_strong, .on = .segmented_thumb, .shape = .control, .padding = .{ .x = .m }, .target = .pointer, .cue = "the raised thumb behind it" },
        .segmented_thumb = .{ .surface = .surface_raised, .shape = .control },
        .segmented_separator = .{ .surface = .outline_muted },
        .number_stepper = .{ .surface = .surface_sunken, .shape = .control, .target = .pointer },
        .number_stepper_value = .{ .text = .on_surface, .type = .numeric, .on = .number_stepper, .padding = .{ .x = .s } },
        .number_stepper_unit = .{ .text = .on_surface_muted, .type = .body, .on = .number_stepper, .states = .{ .focused = .{ .text = .on_surface }, .pressed = .{ .text = .on_surface } } },
        .number_stepper_decrement = stepperButton(),
        .number_stepper_increment = stepperButton(),
        .search_field = field: {
            var search = textField(false);
            search.shape = .chip;
            search.gap = .s;
            break :field search;
        },
        .search_field_icon = .{ .icon = .on_surface_muted, .on = .search_field },
        .search_field_shortcut = .{ .surface = .surface, .text = .on_surface_muted, .type = .label, .on = .search_field_shortcut, .shape = .control, .padding = .{ .x = .xs } },
        .search_field_clear = .{
            .icon = .on_surface_muted,
            .on = .search_field,
            .shape = .indicator,
            .target = .pointer,
            .states = .{ .hovered = .{ .surface = .secondary_container, .icon = .on_secondary_container }, .pressed = .{ .surface = .secondary_container, .icon = .on_secondary_container }, .focused = .{ .icon = .on_surface } },
        },
        .icon_button = .{
            .icon = .on_surface_muted,
            .on = .page,
            .shape = .indicator,
            .target = .pointer,
            .states = .{ .hovered = on_hover_icon, .pressed = on_hover_icon },
        },
        .icon_button_filled = .{ .surface = .accent, .icon = .on_accent, .on = .icon_button_filled, .shape = .indicator, .target = .pointer },
        .icon_button_tonal = .{ .surface = .secondary_container, .icon = .on_secondary_container, .on = .icon_button_tonal, .shape = .indicator, .target = .pointer },
        .link = .{ .text = .on_surface_accent, .type = .body, .on = .page, .shape = .control, .target = .pointer },
        .link_underline = .{ .surface = .on_surface_accent },
        .chip = .{
            .surface = .surface_sunken,
            .text = .on_surface,
            .type = .label_strong,
            .on = .chip,
            .shape = .chip,
            .padding = .{ .x = .m },
            .gap = .xs,
            .target = .pointer,
        },
        .chip_selected = .{
            .surface = .accent_container,
            .text = .on_accent_container,
            .type = .label_strong,
            .on = .chip_selected,
            .shape = .chip,
            .padding = .{ .x = .m },
            .gap = .xs,
            .target = .pointer,
            .cue = "its check",
        },
        .chip_check = .{ .icon = .on_accent_container, .on = .chip_selected },
        .chip_icon = .{ .icon = .on_surface, .on = .chip },
        .chip_close = .{
            .icon = .on_surface_muted,
            .on = .chip,
            .shape = .indicator,
            .target = .pointer,
            .states = .{ .hovered = .{ .surface = .secondary_container, .icon = .on_secondary_container }, .pressed = .{ .surface = .secondary_container, .icon = .on_secondary_container }, .focused = .{ .icon = .on_surface } },
        },
        .toggle = .{ .text = .on_surface, .type = .body, .on = .page, .gap = .m },
        .toggle_track = .{ .surface = .outline_muted, .outline = .outline, .target = .pointer },
        .toggle_track_on = .{ .surface = .accent, .target = .pointer, .cue = "its thumb at the far end" },
        .toggle_thumb = .{ .surface = .outline },
        .toggle_thumb_on = .{ .surface = .surface_raised },
        .tooltip = .{ .surface = .surface_inverse, .text = .on_surface_inverse, .type = .label, .on = .tooltip, .shape = .control, .padding = .{ .x = .s, .y = .xs }, .gap = .xs },
        .tooltip_shortcut = .{ .text = .on_surface_inverse, .type = .label, .on = .tooltip, .gap = .s },
        .menu = .{ .surface = .surface_overlay, .shape = .popup, .padding = .{ .x = .xs, .y = .xs }, .gap = .xs },
        .menu_item = .{
            .text = .on_surface,
            .type = .body,
            .on = .menu,
            .shape = .control,
            .padding = .{ .x = .s },
            .gap = .m,
            .target = .pointer,
            .states = .{ .hovered = on_hover, .pressed = on_hover },
        },
        .menu_item_danger = .{
            .text = .on_danger_container,
            .type = .body,
            .on = .menu,
            .shape = .control,
            .padding = .{ .x = .s },
            .gap = .m,
            .target = .pointer,
            .states = .{ .hovered = on_danger_hover, .pressed = on_danger_hover },
        },
        .menu_icon = .{ .icon = .on_surface_muted, .on = .menu, .states = .{ .hovered = .{ .icon = .on_secondary_container }, .pressed = .{ .icon = .on_secondary_container } } },
        .menu_shortcut = .{ .text = .on_surface_muted, .type = .label, .on = .menu, .gap = .xl, .states = .{ .hovered = .{ .text = .on_secondary_container }, .pressed = .{ .text = .on_secondary_container } } },
        .menu_check = .{ .icon = .on_surface_accent, .on = .menu, .states = .{ .hovered = .{ .icon = .on_secondary_container }, .pressed = .{ .icon = .on_secondary_container } } },
        .menu_separator = .{ .surface = .outline_muted, .padding = .{ .x = .s, .y = .xs } },
        .menu_section = .{ .text = .on_surface_muted, .type = .caption, .on = .menu, .padding = .{ .x = .s, .y = .xs } },
        .popover = .{ .surface = .surface_overlay, .shape = .popup, .padding = .{ .x = .l, .y = .l }, .gap = .s },
        .dialog_scrim = .{ .surface = .scrim },
        .dialog = .{ .surface = .surface_overlay, .shape = .popup, .padding = .{ .x = .xl, .y = .xl }, .gap = .l },
        .dialog_title = .{ .text = .on_surface, .type = .headline, .on = .dialog },
        .dialog_description = .{ .text = .on_surface_muted, .type = .body, .on = .dialog },
        .dialog_actions = .{ .gap = .s },
        .dialog_close = .{
            .icon = .on_surface_muted,
            .on = .dialog,
            .shape = .indicator,
            .padding = .{ .x = .m, .y = .m },
            .target = .pointer,
            .states = .{ .hovered = .{ .surface = .secondary_container, .icon = .on_secondary_container }, .pressed = .{ .surface = .secondary_container, .icon = .on_secondary_container }, .focused = .{ .icon = .on_surface } },
        },
        .toast_stack = .{ .padding = .{ .y = .xl }, .gap = .s },
        .toast = .{ .surface = .surface_inverse, .text = .on_surface_inverse, .type = .body, .on = .toast, .shape = .popup, .padding = .{ .x = .l, .y = .m }, .gap = .m },
        // The accent's focus ring falls short of its contrast on the
        // inverse surface, so the ring is drawn in the inverse surface's text.
        .toast_action = .{ .text = .on_surface_inverse, .type = .body_strong, .on = .toast, .shape = .control, .target = .pointer, .states = .{ .focused = .{ .outline = .on_surface_inverse } } },
        .toast_action_underline = .{ .surface = .on_surface_inverse },
        .toast_icon = .{ .icon = .on_surface_inverse, .on = .toast },
        .toast_icon_success = .{ .icon = .success, .on = .toast },
        .toast_icon_danger = .{ .icon = .danger, .on = .toast },
    });

    const on_danger_hover: zui.design.PartAppearance(void).Colors = .{ .surface = .danger_container, .text = .on_danger_container };

    const on_hover_icon: zui.design.PartAppearance(void).Colors = .{ .surface = .secondary_container, .icon = .on_surface };

    fn stepperButton() zui.design.PartAppearance(void) {
        return .{
            .text = .on_surface,
            .type = .body_strong,
            .on = .number_stepper,
            .shape = .control,
            .states = .{ .hovered = on_hover, .pressed = on_hover, .disabled = .{ .text = .on_surface_muted } },
        };
    }

    fn onPage(comptime type_role: zui.design.TypeRole) zui.design.PartAppearance(void) {
        return .{ .text = .on_surface, .type = type_role, .on = .page };
    }

    fn textField(comptime errored: bool) zui.design.PartAppearance(void) {
        return .{
            .surface = .surface_sunken,
            .outline = if (errored) .danger else null,
            .text = .on_surface,
            .type = .body,
            .on = .text_field,
            .shape = .control,
            .padding = .{ .x = .m },
            .target = .pointer,
            .states = if (errored)
                .{ .focused = .{ .surface = .surface } }
            else
                .{ .hovered = .{ .outline = .outline_muted }, .focused = .{ .surface = .surface, .outline = .accent } },
            .cue = if (errored) "its error message below it" else null,
        };
    }

    fn tab(comptime text: zui.design.ColorChoice(void), comptime on: @EnumLiteral()) zui.design.PartAppearance(void) {
        return .{
            .text = text,
            .type = .label_strong,
            .on = on,
            .shape = .control,
            .padding = .{ .x = .m },
            .target = .pointer,
            .states = .{ .hovered = .{ .text = .on_surface }, .pressed = .{ .text = .on_surface } },
        };
    }

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

/// An icon button with no fill until hovered, `tertiary`; filled in the
/// accent for the main action, `filled`; or in a soft fill, `tonal`.
pub const IconButtonVariant = enum {
    tertiary,
    filled,
    tonal,

    pub fn part(variant: IconButtonVariant) Part {
        return switch (variant) {
            .tertiary => .icon_button,
            .filled => .icon_button_filled,
            .tonal => .icon_button_tonal,
        };
    }
};

/// The color of a label's text: the page's, muted for what is secondary, or
/// the accent's.
pub const LabelTone = enum {
    default,
    muted,
    accent,

    pub fn part(tone: LabelTone) Part {
        return switch (tone) {
            .default => .label,
            .muted => .muted_label,
            .accent => .label_accent,
        };
    }
};

/// The part a control of `size` reads its height, its icon's side and its
/// label's type from.
pub fn controlSizePart(size: zui.design.ControlSize) Part {
    return switch (size) {
        .small => .control_small,
        .medium => .control_medium,
        .large => .control_large,
    };
}

pub const DividerAxis = enum { horizontal, vertical };

/// Where a divider stops short of its parent's edges: at the leading one, as
/// between rows that start with an inset label, or at both.
pub const DividerInset = enum { none, leading, both };

pub const ScrollAxis = enum { vertical, horizontal, both };

/// The surface an edge of a scroll area fades into where more content lies
/// beyond it.
pub const EdgeFade = enum { none, page, card };

/// `.underline` for a page's sections, `.pill` for views of one thing in a
/// groove, as a segmented control.
pub const TabsStyle = enum { underline, pill };

/// A row of `navigationList`, or a section's heading above the rows after
/// it.
pub const NavigationItem = struct {
    label: []const u8,
    /// Shown at the row's end, such as how many items are unread; none when
    /// empty.
    count: []const u8 = "",
    /// The keys that reach the place, shown at the row's end after its
    /// count, such as "Ctrl+1"; none when empty.
    shortcut: []const u8 = "",
    /// A heading, which is never selected.
    heading: bool = false,
};

/// The side of its anchor an overlay opens on: below or above it, or
/// beside it at the reading direction's start or end. Where the window
/// has no room on that side and has it on the opposite one, it flips.
pub const Placement = enum { below, above, leading, trailing };

pub const ToastTone = enum { neutral, success, danger };

/// What `ToastQueue.push` shows.
pub const Toast = struct {
    /// Copied, cut at a character past 160 bytes.
    message: []const u8,
    /// A button's label, such as "Undo"; none when empty. Copied, cut at a
    /// character past 32 bytes.
    action: []const u8 = "",
    tone: ToastTone = .neutral,
    /// What `toasts` returns when its action is chosen, so the application
    /// knows which toast it was.
    tag: u32 = 0,
};

/// One toast in a `ToastQueue`'s storage.
pub const ToastEntry = struct {
    message_bytes: [toast_message_capacity]u8,
    message_len: u8,
    action_bytes: [toast_action_capacity]u8,
    action_len: u8,
    tone: ToastTone,
    tag: u32,
    key: u32,
    shown: bool,
    paused: bool,
    /// Declared one last time, so its exit fade starts from this frame.
    leaving: bool,
    deadline: zui.Instant,
    /// Seconds still to show while paused.
    left: f32,

    pub fn message(entry: *const ToastEntry) []const u8 {
        return entry.message_bytes[0..entry.message_len];
    }

    pub fn action(entry: *const ToastEntry) []const u8 {
        return entry.action_bytes[0..entry.action_len];
    }
};

/// The toasts waiting and showing, oldest first, in storage the
/// application owns.
///
/// ```zig
/// var toast_storage: [8]zui_widgets.ToastEntry = undefined;
/// var notices: zui_widgets.ToastQueue = .init(&toast_storage);
/// _ = notices.push(.{ .message = "Booking confirmed", .action = "Undo", .tone = .success, .tag = booking.id });
/// ```
pub const ToastQueue = struct {
    entries: []ToastEntry,
    len: usize = 0,
    next_key: u32 = 0,

    pub fn init(storage: []ToastEntry) ToastQueue {
        return .{ .entries = storage };
    }

    /// Queues `toast` after those already waiting; a full queue keeps the
    /// toasts it has and returns false.
    pub fn push(queue: *ToastQueue, toast: Toast) bool {
        if (queue.len == queue.entries.len) return false;
        const entry = &queue.entries[queue.len];
        entry.* = .{
            .message_bytes = undefined,
            .message_len = @intCast(copyCut(&entry.message_bytes, toast.message)),
            .action_bytes = undefined,
            .action_len = @intCast(copyCut(&entry.action_bytes, toast.action)),
            .tone = toast.tone,
            .tag = toast.tag,
            .key = queue.next_key,
            .shown = false,
            .paused = false,
            .leaving = false,
            .deadline = .zero,
            .left = 0,
        };
        queue.next_key +%= 1;
        queue.len += 1;
        return true;
    }

    /// Oldest first.
    pub fn waiting(queue: *const ToastQueue) []const ToastEntry {
        return queue.entries[0..queue.len];
    }

    fn remove(queue: *ToastQueue, index: usize) void {
        std.mem.copyForwards(ToastEntry, queue.entries[index .. queue.len - 1], queue.entries[index + 1 .. queue.len]);
        queue.len -= 1;
    }
};

/// Copies as much of `bytes` as fits, cut at a character boundary, and
/// returns how many bytes that was.
fn copyCut(buffer: []u8, bytes: []const u8) usize {
    var count = @min(bytes.len, buffer.len);
    while (count > 0 and count < bytes.len and isContinuationByte(bytes[count])) count -= 1;
    @memcpy(buffer[0..count], bytes[0..count]);
    return count;
}

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
        const FontId = @FieldType(TextStyle, "font");

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

        pub const LabelOptions = struct {
            role: zui.design.TypeRole = .body,
            tone: LabelTone = .default,
            /// `.none` keeps it on one line.
            wrap: zui.TextWrap = .none,
        };

        /// Text in any type role, in the page's text color, muted or
        /// accented.
        ///
        /// ```zig
        /// widgets.labelWith(ui, "Storage", .{ .role = .title });
        /// widgets.labelWith(ui, "12 GB of 50 GB used", .{ .role = .caption, .tone = .muted });
        /// ```
        pub fn labelWith(self: Self, ui: *Ui, content: []const u8, options: LabelOptions) void {
            var text_style = self.style(ui, labelPartOf(options.role), .idle).text;
            if (options.tone != .default) text_style.color = self.style(ui, options.tone.part(), .idle).text.color;
            text_style.wrap = options.wrap;
            ui.text(content, text_style);
        }

        fn labelPartOf(role: zui.design.TypeRole) Part {
            return switch (role) {
                .body => .label,
                .display => .label_display,
                .headline => .label_headline,
                .title => .label_title,
                .body_strong => .label_body_strong,
                .label => .label_label,
                .label_strong => .label_label_strong,
                .caption => .label_caption,
                .code => .label_code,
                .numeric => .label_numeric,
            };
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
            self.labeledRowWith(ui, content, .{});
        }

        pub const LabeledRowOptions = struct {
            /// Below the label, wrapped to its column; none when empty.
            description: []const u8 = "",
            /// A divider above the row, inset at its leading edge, for
            /// every row of a list on one card but the first.
            divider_above: bool = false,
        };

        /// `labeledRow` with a description under its label, and a divider
        /// above it between the rows of a settings list:
        ///
        /// ```zig
        /// const sync = widgets.groupBox(ui, .of("sync"), "Sync", .{});
        /// widgets.labeledRowWith(ui, "Wi-Fi only", .{ .description = "Waits for Wi-Fi before uploading." });
        /// _ = widgets.toggle(ui, .of("wifi_only"), "", &app.wifi_only, .{ .label = "Wi-Fi only" });
        /// ui.close();
        /// widgets.labeledRowWith(ui, "Photos", .{ .divider_above = true });
        /// _ = widgets.toggle(ui, .of("photos"), "", &app.sync_photos, .{ .label = "Photos" });
        /// ui.close();
        /// sync.end(ui);
        /// ```
        pub fn labeledRowWith(self: Self, ui: *Ui, content: []const u8, options: LabeledRowOptions) void {
            if (options.divider_above) self.divider(ui, .{ .inset = .leading });
            const row_label = self.style(ui, .row_label, .idle);
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = row_label.gap, .child_alignment = .{ .y = .center } } });
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(row_label.size[0]) } } });
            ui.text(content, singleLine(row_label.text));
            if (options.description.len != 0) ui.text(options.description, self.style(ui, .row_description, .idle).text);
            ui.close();
        }

        /// A full-width header that toggles `expanded` when clicked, for
        /// collapsible sections. Its chevron points right while collapsed
        /// and turns down as it expands, where the context draws
        /// transforms. Returns whether it toggled.
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
            if (Ui.draws_transforms) {
                const collapsed = self.style(ui, .disclosure_collapsed, state);
                const quarter_turns = animate(ui, id.child("chevron"), f32, if (expanded.*) 1 else 0, collapsed.motion);
                const effects: Ui.Effects = .{ .transform = .{ .rotation = quarter_turns * std.math.pi / 2.0 } };
                ui.open(.{ .effects = if (quarter_turns != 0) &effects else null, .layout = .{ .child_alignment = .{ .x = .center, .y = .center } } });
                self.icon(ui, .chevron_right, collapsed);
                ui.close();
            } else {
                const indicator = self.style(ui, if (expanded.*) .disclosure_expanded else .disclosure_collapsed, state);
                self.icon(ui, if (expanded.*) .chevron_down else .chevron_right, indicator);
            }
            ui.text(content, singleLine(header.text));
            ui.close();
            return toggled;
        }

        /// The skin's `name` in its icon font, in `look`'s text color and
        /// `look.size[0]` across. Without one, `look.glyph` in its text, or,
        /// when it has none either, nothing, counted in
        /// `Diagnostics.missing_icons`.
        fn icon(self: Self, ui: *Ui, name: zui.design.Icon, look: SkinStyle) void {
            if (self.iconGlyph(name)) |glyph| {
                var icon_style = singleLine(look.text);
                icon_style.font = fontOf(glyph.font);
                if (look.size[0] > 0) icon_style.size = look.size[0];
                ui.text(glyph.utf8(), icon_style);
            } else if (look.glyph.len != 0) {
                ui.text(look.glyph, singleLine(look.text));
            } else ui.countMissingIcon();
        }

        fn iconGlyph(self: Self, name: zui.design.Icon) ?zui.design.IconGlyph {
            return if (@hasDecl(Skin, "zuiIcon")) self.skin.zuiIcon(name) else null;
        }

        fn fontOf(index: u32) FontId {
            return switch (@typeInfo(FontId)) {
                .int => @intCast(index),
                .@"enum" => @enumFromInt(index),
                else => @compileError("zui_widgets: icons need a FontId that is an integer or an enum, got " ++ @typeName(FontId)),
            };
        }

        pub const ButtonOptions = struct {
            disabled: bool = false,
            /// `.fit` is at least twice as wide as the button is tall.
            width: zui.Sizing = .fit,
            variant: ButtonVariant = .primary,
            size: zui.design.ControlSize = .medium,
            /// Drawn before the label in its color.
            leading_icon: ?zui.design.Icon = null,
        };

        /// True in the frame the button is clicked, or activated with Enter
        /// or Space while focused. A pressed button shrinks a little, where
        /// the context draws transforms.
        ///
        /// ```zig
        /// if (widgets.button(ui, .of("export"), "Export", .{ .variant = .secondary, .size = .small, .leading_icon = .arrow_down })) app.exportReport();
        /// ```
        pub fn button(self: Self, ui: *Ui, id: zui.Id, content: []const u8, options: ButtonOptions) bool {
            const state = stateOf(ui, id, options.disabled);
            const look = self.style(ui, options.variant.part(), state);
            const control = self.style(ui, controlSizePart(options.size), state);
            var label_style = singleLine(control.text);
            label_style.color = look.text.color;
            var width = options.width;
            if (width.rule == .fit) width.min = @max(width.min, control.size[1] * 2);
            const scale = pressScale(ui, id, look);
            const effects: Ui.Effects = .{ .transform = .{ .scale = @splat(scale) } };
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .semantics = .{ .role = .button, .label = content },
                .decoration = decorationOf(look, ui.focused(id)),
                .effects = if (scale != 1) &effects else null,
                .layout = .{
                    .sizing = .{ .width = width, .height = .fixed(control.size[1]) },
                    .padding = look.padding,
                    .child_gap = look.gap,
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            });
            if (options.leading_icon) |name| {
                var icon_look = look;
                icon_look.size[0] = control.size[0];
                icon_look.glyph = "";
                self.icon(ui, name, icon_look);
            }
            ui.text(content, label_style);
            ui.close();
            return ui.clicked(id);
        }

        /// `look.scale` reached through `look.motion`, where the context
        /// draws transforms.
        fn pressScale(ui: *Ui, id: zui.Id, look: SkinStyle) f32 {
            if (!Ui.draws_transforms) return 1;
            return animate(ui, id.child("press"), f32, look.scale, look.motion);
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
                .layout = .{ .sizing = .{ .width = .fitBetween(row.size[0], std.math.inf(f32)), .height = .fixed(row.size[1]) }, .child_gap = row.gap, .child_alignment = .{ .y = .center } },
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
                const grown = animate(ui, id.child("mark"), f32, 1, mark.motion);
                ui.box(.{
                    .decoration = decorationOf(mark, false),
                    .layout = .{ .sizing = .{ .width = .fixed(mark.size[0] * grown), .height = .fixed(mark.size[1] * grown) } },
                });
            } else _ = animate(ui, id.child("mark"), f32, 0, .{ .tween = .{ .duration = 0 } });
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
            /// Its name to an assistive technology.
            label: []const u8 = "",
            /// A tick at each `step`, where there are at most 64 of them.
            ticks: bool = false,
            /// The value above the thumb while it is dragged.
            bubble: bool = true,
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
                .decoration = .{ .border = if (ui.focused(id)) thumb.focus_ring else null, .corner_radius = thumb.corner_radius, .corner_shape = thumb.corner_shape },
                .layout = .{ .sizing = .{ .width = options.width, .height = .fixed(self.style(ui, .slider, state).size[1]) }, .child_alignment = .{ .y = .center } },
            });
            // The grow weights split the track's free space at the value,
            // so the thumb lands in place without last frame's width.
            ui.box(.{
                .decoration = decorationOf(filled, false),
                .layout = .{ .sizing = .{ .width = .growWeighted(fraction), .height = .fixed(filled.size[1]) } },
            });
            const thumb_id = id.child("thumb");
            ui.box(.{
                .id = thumb_id,
                .decoration = decorationOf(thumb, false),
                .layout = .{ .sizing = .{ .width = .fixed(thumb.size[0]), .height = .fixed(thumb.size[1]) } },
            });
            ui.box(.{
                .decoration = decorationOf(empty, false),
                .layout = .{ .sizing = .{ .width = .growWeighted(1 - fraction), .height = .fixed(empty.size[1]) } },
            });
            if (options.ticks) if (options.step) |step| self.sliderTicks(ui, id, thumb.size[0], fraction, step, options, state);
            if (options.bubble and !options.disabled and ui.pressed(id)) self.sliderBubble(ui, thumb_id, Value, current, key_step);
            ui.close();
            return changed;
        }

        /// Placed from the slider's rectangle in the previous frame, so
        /// its first frame draws none.
        fn sliderTicks(self: Self, ui: *Ui, id: zui.Id, thumb_side: f32, fraction: f32, step: f64, options: SliderOptions, state: zui.WidgetState) void {
            const range = options.max - options.min;
            if (step <= 0 or range <= 0) return;
            const intervals = @floor(range / step + 1e-9);
            if (intervals < 1 or intervals > slider_ticks_most) return;
            const rect = ui.rectOf(id) orelse return ui.requestFrame();
            const filled = self.style(ui, .slider_tick_filled, state);
            const empty = self.style(ui, .slider_tick_empty, state);
            const travel = rect.width - thumb_side;
            const count: usize = @intFromFloat(intervals);
            for (0..count + 1) |index| {
                const at: f32 = @floatCast(@as(f64, @floatFromInt(index)) * step / range);
                if (@abs(at - fraction) * travel < thumb_side / 2) continue;
                const tick = if (at < fraction) filled else empty;
                ui.box(.{
                    .floating = .{ .attach_to = .parent, .anchor = .center_left, .attach_point = .center_left, .offset = .{ thumb_side / 2 + at * travel - tick.size[0] / 2, 0 }, .capture = false },
                    .decoration = decorationOf(tick, false),
                    .layout = .{ .sizing = .{ .width = .fixed(tick.size[0]), .height = .fixed(tick.size[1]) } },
                });
            }
        }

        fn sliderBubble(self: Self, ui: *Ui, thumb_id: zui.Id, comptime Value: type, value: f64, key_step: f64) void {
            const bubble = self.style(ui, .slider_bubble, .idle);
            var digits: [32]u8 = undefined;
            const shown = if (@typeInfo(Value) == .int or @round(key_step) == key_step)
                std.fmt.bufPrint(&digits, "{d}", .{@round(value)}) catch ""
            else
                std.fmt.bufPrint(&digits, "{d:.2}", .{value}) catch "";
            ui.open(.{
                .floating = .{ .attach_to = .{ .element = thumb_id }, .anchor = .bottom_center, .attach_point = .top_center, .offset = .{ 0, -bubble.gap }, .z = popup_layer, .capture = false },
                .decoration = decorationOf(bubble, false),
                .layout = .{ .padding = bubble.padding, .child_alignment = .{ .x = .center, .y = .center } },
            });
            ui.text(shown, singleLine(bubble.text));
            ui.close();
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
            /// Shows `label` above the field.
            show_label: bool = false,
            /// Below the field, wrapped to its width; none when empty.
            help: []const u8 = "",
            /// Below the field in place of `help`, and outlines the field in
            /// the danger color; none when empty.
            error_message: []const u8 = "",
            leading_icon: ?zui.design.Icon = null,
            /// At the field's end, such as a unit; none when empty.
            trailing: []const u8 = "",
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
        ///
        /// ```zig
        /// _ = widgets.textField(ui, .of("email"), &app.email, .{
        ///     .label = "Email",
        ///     .show_label = true,
        ///     .help = "We send the receipt here.",
        ///     .error_message = if (app.email_valid) "" else "Enter an address like ada@example.com.",
        /// });
        /// ```
        pub fn textField(self: Self, ui: *Ui, id: zui.Id, text: *EditableText, options: TextFieldOptions) TextFieldResult {
            const errored = options.error_message.len != 0;
            const framed = options.show_label or options.help.len != 0 or errored;
            if (framed) {
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = options.width }, .child_gap = self.style(ui, .text_field_label, .idle).gap } });
                if (options.show_label) ui.text(options.label, singleLine(self.style(ui, .text_field_label, .idle).text));
            }
            const result = self.editableLine(ui, id, text, .{
                .field = if (errored) .text_field_error else .text_field,
                .placeholder = options.placeholder,
                .label = options.label,
                .leading_icon = options.leading_icon,
                .trailing = options.trailing,
                .disabled = options.disabled,
                .width = if (framed) .grow else options.width,
            });
            if (framed) {
                if (errored) {
                    const message = self.style(ui, .text_field_error_message, .idle);
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = message.gap } });
                    self.icon(ui, .alert, self.style(ui, .text_field_error_icon, .idle));
                    ui.text(options.error_message, message.text);
                    ui.close();
                } else if (options.help.len != 0) {
                    ui.text(options.help, self.style(ui, .text_field_help, .idle).text);
                }
                ui.close();
            }
            return result;
        }

        const Line = struct {
            field: Part,
            placeholder: []const u8,
            label: []const u8,
            leading_icon: ?zui.design.Icon,
            leading_part: Part = .text_field_icon,
            trailing: []const u8 = "",
            /// Shown at the end while the field is empty and unfocused.
            shortcut: []const u8 = "",
            /// A button at the end that empties the field, while it has text.
            clearable: bool = false,
            disabled: bool,
            width: zui.Sizing,
        };

        fn editableLine(self: Self, ui: *Ui, id: zui.Id, text: *EditableText, options: Line) TextFieldResult {
            const state = stateOf(ui, id, options.disabled);
            const field = self.style(ui, options.field, state);
            const caret_look = self.style(ui, .text_field_caret, state);
            const clear_id = id.child("clear");
            var cleared = false;
            if (options.clearable and !options.disabled and text.len != 0 and ui.clicked(clear_id)) {
                text.set("");
                cleared = true;
                ui.requestFocus(id);
            }
            const text_style = singleLine(field.text);
            const scroll_id = id.child("scroll");
            const caret = ui.state(id, Caret);
            const focused = ui.focused(id) and !options.disabled;
            var result: TextFieldResult = .{ .changed = cleared };

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
                    .child_gap = if (options.field == .search_field) field.gap else if (options.leading_icon != null or options.trailing.len != 0) field.padding.left else 0,
                    .child_alignment = .{ .y = .center },
                },
            });
            if (options.leading_icon) |name| self.icon(ui, name, self.style(ui, options.leading_part, state));
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
            if (options.trailing.len != 0) ui.text(options.trailing, singleLine(self.style(ui, .text_field_trailing, state).text));
            if (options.shortcut.len != 0 and text.len == 0 and !focused) {
                const hint = self.style(ui, .search_field_shortcut, state);
                ui.open(.{ .decoration = decorationOf(hint, false), .layout = .{ .padding = hint.padding, .child_alignment = .{ .y = .center } } });
                ui.text(options.shortcut, singleLine(hint.text));
                ui.close();
            }
            if (options.clearable and text.len != 0 and !options.disabled) {
                const clear = self.style(ui, .search_field_clear, nestedState(ui, clear_id, state));
                ui.open(.{
                    .id = clear_id,
                    .interactive = true,
                    .cursor = .pointer,
                    .semantics = .{ .role = .button, .label = "Clear" },
                    .decoration = decorationOf(clear, false),
                    .layout = .{ .sizing = .{ .width = .fixed(clear.size[1]), .height = .fixed(clear.size[1]) }, .child_alignment = .{ .x = .center, .y = .center } },
                });
                self.icon(ui, .close, clear);
                ui.close();
            }
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
                const indicator_width = if (self.iconGlyph(.chevron_down) != null) indicator.size[0] else ui.measureText(indicator.glyph, indicator_style)[0];
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
            self.icon(ui, .chevron_down, indicator);
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
                if (index == selected) {
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                    self.icon(ui, .check, self.style(ui, .dropdown_check, ui.widgetState(option_id)));
                }
                ui.close();
            }
            ui.close();
        }

        /// `dropdown` over an enum's named tags, labeled with
        /// `labelFromIdentifier`.
        pub fn dropdownEnum(self: Self, ui: *Ui, id: zui.Id, value: anytype, options: DropdownOptions) bool {
            const Enum = EnumPointee(@TypeOf(value), "dropdownEnum");
            const tags = @typeInfo(Enum).@"enum".fields;
            const labels = comptime tagLabels(Enum);
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

        pub const CardOptions = struct {
            /// Focusable and clickable as a button, lifted while hovered
            /// and pressed in while pressed.
            interactive: bool = false,
            /// Its name to an assistive technology, when it is interactive.
            label: []const u8 = "",
            width: zui.Sizing = .grow,
            height: zui.Sizing = .fit,
        };

        /// Opens a card at the `raised` elevation, its content in a
        /// column; declare it, then close the card with `ui.close()`. An
        /// interactive card returns true in the frame it is clicked, or
        /// activated with Enter or Space while focused; one that is not
        /// returns false.
        ///
        /// ```zig
        /// if (widgets.card(ui, .of("notes"), .{ .interactive = true, .label = "Release notes" })) app.open(.release_notes);
        /// widgets.cardTitle(ui, "Release notes");
        /// widgets.cardBody(ui, "Version 2.4 adds offline sync.");
        /// ui.close();
        /// ```
        pub fn card(self: Self, ui: *Ui, id: zui.Id, options: CardOptions) bool {
            const interactive = options.interactive;
            const look = self.style(ui, .card, if (interactive) ui.widgetState(id) else .idle);
            const scale = if (interactive and Ui.draws_transforms) animate(ui, id.child("press"), f32, look.scale, look.motion) else 1;
            const effects: Ui.Effects = .{ .shadow = look.shadow, .transform = if (scale != 1) .{ .scale = @splat(scale) } else null };
            ui.open(.{
                .id = id,
                .focusable = interactive,
                .cursor = if (interactive) .pointer else null,
                .semantics = if (interactive) .{ .role = .button, .label = options.label } else null,
                .decoration = decorationOf(look, interactive and ui.focused(id)),
                .effects = if (look.shadow != null or scale != 1) &effects else null,
                .layout = .{
                    .direction = .top_to_bottom,
                    .sizing = .{ .width = options.width, .height = options.height },
                    .padding = look.padding,
                    .child_gap = look.gap,
                },
            });
            return interactive and ui.clicked(id);
        }

        /// A card's title, wrapped to its width.
        pub fn cardTitle(self: Self, ui: *Ui, content: []const u8) void {
            ui.text(content, self.style(ui, .card_title, .idle).text);
        }

        /// A card's text, wrapped to its width.
        pub fn cardBody(self: Self, ui: *Ui, content: []const u8) void {
            ui.text(content, self.style(ui, .card_body, .idle).text);
        }

        pub const DividerOptions = struct {
            axis: DividerAxis = .horizontal,
            inset: DividerInset = .none,
            /// Centered, breaking the line.
            label: ?[]const u8 = null,
        };

        /// A line across its parent, or down it, between groups of content.
        ///
        /// ```zig
        /// widgets.divider(ui, .{ .label = "or" });
        /// ```
        pub fn divider(self: Self, ui: *Ui, options: DividerOptions) void {
            const line = self.style(ui, .divider, .idle);
            const label_look = if (options.label != null) self.style(ui, .divider_label, .idle) else line;
            const leading: f32 = if (options.inset == .none) 0 else line.padding.left;
            const trailing: f32 = if (options.inset == .both) line.padding.left else 0;
            const horizontal = options.axis == .horizontal;
            ui.open(.{ .layout = .{
                .direction = if (horizontal) .left_to_right else .top_to_bottom,
                .sizing = if (horizontal) .{ .width = .grow } else .{ .height = .grow },
                .padding = if (horizontal) .{ .left = leading, .right = trailing } else .{ .top = leading, .bottom = trailing },
                .child_gap = label_look.gap,
                .child_alignment = .{ .x = .center, .y = .center },
            } });
            dividerLine(ui, line, horizontal);
            if (options.label) |content| {
                ui.text(content, singleLine(label_look.text));
                dividerLine(ui, line, horizontal);
            }
            ui.close();
        }

        fn dividerLine(ui: *Ui, line: SkinStyle, horizontal: bool) void {
            ui.box(.{
                .decoration = .{ .background = line.background },
                .layout = .{ .sizing = if (horizontal) .{ .width = .grow, .height = .fixed(line.size[0]) } else .{ .width = .fixed(line.size[0]), .height = .grow } },
            });
        }

        pub const ScrollAreaOptions = struct {
            axis: ScrollAxis = .vertical,
            width: zui.Sizing = .grow,
            height: zui.Sizing = .grow,
            /// How the content is laid out.
            direction: zui.Direction = .top_to_bottom,
            padding: zui.Edges = .zero,
            child_gap: f32 = 0,
            /// Its name to an assistive technology.
            label: []const u8 = "",
            /// Drawn only where the context draws gradients.
            edge_fade: EdgeFade = .page,
            /// The floating layer the area is in, which its scrollbars and
            /// fades paint in too: 0 on the page.
            layer: i16 = 0,
        };

        /// What `scrollArea` opened, which `end` closes.
        pub const ScrollArea = struct {
            widgets: Self,
            id: zui.Id,
            options: ScrollAreaOptions,

            /// Closes the content and declares the scrollbars and fades
            /// over it.
            pub fn end(area: ScrollArea, ui: *Ui) void {
                ui.close();
                const axes = scrolledAxes(area.options.axis);
                for ([_]zui.Axis{ .x, .y }) |axis| {
                    if (!axes[@intFromEnum(axis)]) continue;
                    area.widgets.scrollbar(ui, area.id, contentId(area.id), axis, area.options.layer);
                    area.widgets.edgeFades(ui, area.id, axis, area.options);
                }
                ui.close();
            }
        };

        /// Opens a view that scrolls its content with the wheel, a drag,
        /// the scrollbar's thumb, or, while it is focused, the arrow keys,
        /// Page Up and Down, Home and End. Its scrollbar is thin at rest,
        /// wider while the pointer is over it, and fades once scrolling
        /// stops. Declare the content, then call `end` on what it returns:
        ///
        /// ```zig
        /// const history = widgets.scrollArea(ui, .of("history"), .{ .height = .fixed(240), .child_gap = 4 });
        /// for (app.events) |event| widgets.label(ui, event.summary);
        /// history.end(ui);
        /// ```
        pub fn scrollArea(self: Self, ui: *Ui, id: zui.Id, options: ScrollAreaOptions) ScrollArea {
            const axes = scrolledAxes(options.axis);
            const view = ui.rectOf(id);
            const overflow = overflowOf(ui, id);
            const overflows = (axes[0] and overflow[0] > 0) or (axes[1] and overflow[1] > 0);
            if (ui.focused(id)) if (view) |rect| scrollByKeys(ui, id, axes, .{ rect.width, rect.height }, overflow);

            const look = self.style(ui, .scroll_area, ui.widgetState(id));
            const gutter = self.style(ui, .scroll_track, .idle).size[0];
            var padding = options.padding;
            if (axes[1] and overflow[1] > 0) padding.right += gutter;
            if (axes[0] and overflow[0] > 0) padding.bottom += gutter;
            ui.open(.{
                .id = id,
                .interactive = true,
                .focusable = overflows,
                .scroll = .{ .horizontal = axes[0], .vertical = axes[1] },
                .semantics = .{ .role = .scroll_area, .label = options.label },
                .decoration = .{ .border = if (ui.focused(id)) look.focus_ring else null, .corner_radius = look.corner_radius, .corner_shape = look.corner_shape },
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = options.width, .height = options.height } },
            });
            ui.open(.{
                .id = contentId(id),
                .layout = .{
                    .direction = options.direction,
                    .sizing = .{ .width = if (axes[0]) .fit else .grow, .height = if (axes[1]) .fit else .grow },
                    .padding = padding,
                    .child_gap = options.child_gap,
                },
            });
            return .{ .widgets = self, .id = id, .options = options };
        }

        fn contentId(area_id: zui.Id) zui.Id {
            return area_id.child("content");
        }

        fn scrolledAxes(axis: ScrollAxis) [2]bool {
            return .{ axis != .vertical, axis != .horizontal };
        }

        /// How far the area's content reached past its view on each axis
        /// in the previous frame.
        fn overflowOf(ui: *const Ui, id: zui.Id) [2]f32 {
            const view = ui.rectOf(id) orelse return .{ 0, 0 };
            const content = ui.rectOf(contentId(id)) orelse return .{ 0, 0 };
            return .{ @max(content.width - view.width, 0), @max(content.height - view.height, 0) };
        }

        fn scrollByKeys(ui: *Ui, id: zui.Id, axes: [2]bool, view: [2]f32, overflow: [2]f32) void {
            const paged: usize = if (axes[1]) 1 else 0;
            const previous = ui.scrollOffset(id);
            var offset = previous;
            for (ui.keyEvents()) |key_event| switch (key_event.key) {
                .up => offset[1] -= keyboard_scroll_step,
                .down => offset[1] += keyboard_scroll_step,
                .left => offset[0] -= keyboard_scroll_step,
                .right => offset[0] += keyboard_scroll_step,
                .page_up => offset[paged] -= view[paged] * page_share,
                .page_down => offset[paged] += view[paged] * page_share,
                .home => offset[paged] = 0,
                .end => offset[paged] = overflow[paged],
                else => {},
            };
            for (0..2) |axis| offset[axis] = if (axes[axis]) std.math.clamp(offset[axis], 0, overflow[axis]) else 0;
            if (!std.meta.eql(offset, previous)) ui.setScrollOffset(id, offset);
        }

        const ScrollbarMotion = struct {
            last_offset: f32,
            scrolled_at: zui.Instant,
            /// Where along the thumb the pointer took hold of it.
            grab: f32,
            seen: bool,
            dragging: bool,
        };

        /// The scrollbar along `axis` of `scroll_id`, a scroll container
        /// whose one child, `content_id`, holds what it scrolls over.
        /// Declare it inside the container, after the content; it draws
        /// from both rectangles in the previous frame, and draws nothing
        /// while the content fits. The thumb follows the offset, drags it,
        /// and a click on the track beside it pages toward the pointer.
        ///
        /// ```zig
        /// ui.open(.{ .id = table_id, .scroll = .{}, .layout = .{ .sizing = .grow_both } });
        /// ui.open(.{ .id = table_id.child("rows"), .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow } } });
        /// declareRows(ui);
        /// ui.close();
        /// widgets.scrollbar(ui, table_id, table_id.child("rows"), .y, 0);
        /// ui.close();
        /// ```
        pub fn scrollbar(self: Self, ui: *Ui, scroll_id: zui.Id, content_id: zui.Id, axis: zui.Axis, layer: i16) void {
            const along = @intFromEnum(axis);
            const vertical = axis == .y;
            const view = ui.rectOf(scroll_id) orelse return;
            const content = ui.rectOf(content_id) orelse return;
            const view_length = if (vertical) view.height else view.width;
            const content_length = if (vertical) content.height else content.width;
            const overflow = content_length - view_length;
            if (overflow < 0.5 or view_length <= 0) return;

            const track_id = if (vertical) scroll_id.child("vertical_track") else scroll_id.child("horizontal_track");
            const thumb_id = track_id.child("thumb");
            const motion = ui.state(track_id, ScrollbarMotion);
            const dragging = ui.pressed(thumb_id);
            const over_track = ui.hovered(track_id);
            const thumb = self.style(ui, .scroll_thumb, if (dragging) .pressed else if (over_track) .hovered else .idle);
            const track = self.style(ui, .scroll_track, if (dragging or over_track) .hovered else .idle);
            const inset = wholePixels(ui, thumb.padding.top);
            const track_length = @max(view_length - 2 * inset, 0);
            const thumb_length = std.math.clamp(track_length * view_length / content_length, @min(thumb.size[1], track_length), track_length);
            const travel = track_length - thumb_length;
            const view_start = if (vertical) view.y else view.x;

            var offset = ui.scrollOffset(scroll_id);
            const thumb_start_before = inset + travel * offset[along] / overflow;
            if (dragging) {
                if (ui.primaryPointer()) |pointer| {
                    const pointer_along = pointer.position[along] - view_start;
                    if (!motion.dragging) motion.grab = pointer_along - thumb_start_before;
                    motion.dragging = true;
                    if (travel > 0) offset[along] = std.math.clamp((pointer_along - motion.grab - inset) / travel * overflow, 0, overflow);
                    ui.setScrollOffset(scroll_id, offset);
                }
            } else {
                motion.dragging = false;
                if (ui.clicked(track_id)) if (ui.pointerLocal(track_id)) |local| {
                    const page = view_length * page_share;
                    offset[along] = std.math.clamp(if (local[along] < thumb_start_before) offset[along] - page else offset[along] + page, 0, overflow);
                    ui.setScrollOffset(scroll_id, offset);
                };
            }

            const now = ui.now();
            if (!motion.seen or offset[along] != motion.last_offset) {
                motion.seen = true;
                motion.last_offset = offset[along];
                motion.scrolled_at = now;
            }
            const fades_at = motion.scrolled_at.addSeconds(scrollbar_idle_seconds);
            const recently_scrolled = now.isBefore(fades_at);
            if (recently_scrolled) ui.requestFrameAt(fades_at);
            const shown = recently_scrolled or over_track or dragging or ui.focused(scroll_id);
            const opacity = animate(ui, thumb_id.child("opacity"), f32, if (shown) 1 else 0, thumb.motion);
            const thickness = wholePixels(ui, animate(ui, thumb_id.child("thickness"), f32, thumb.size[0], thumb.motion));
            const thumb_start = inset + travel * offset[along] / overflow;

            const corner: zui.AnchorPoint = if (vertical) .top_right else .bottom_left;
            ui.open(.{
                .id = track_id,
                .interactive = true,
                .floating = .{ .attach_to = .parent, .anchor = corner, .attach_point = corner, .z = layer, .clip = .target },
                .decoration = .{ .background = if (track.background) |color| faded(color, opacity) else null },
                .layout = .{
                    .direction = if (vertical) .top_to_bottom else .left_to_right,
                    .sizing = if (vertical)
                        .{ .width = .fixed(track.size[0]), .height = .fixed(view_length) }
                    else
                        .{ .width = .fixed(view_length), .height = .fixed(track.size[0]) },
                    .padding = if (vertical) .{ .top = thumb_start } else .{ .left = thumb_start },
                },
            });
            ui.open(.{
                .id = thumb_id,
                .interactive = true,
                .gestures = .{ .pan = if (vertical) .vertical else .horizontal },
                .layout = .{
                    .sizing = if (vertical) .{ .width = .grow, .height = .fixed(thumb_length) } else .{ .width = .fixed(thumb_length), .height = .grow },
                    .padding = if (vertical) .{ .right = inset } else .{ .bottom = inset },
                    .child_alignment = if (vertical) .{ .x = .end } else .{ .y = .end },
                },
            });
            ui.box(.{
                .decoration = .{
                    .background = if (thumb.background) |color| faded(color, opacity) else null,
                    .corner_radius = thumb.corner_radius,
                    .corner_shape = thumb.corner_shape,
                },
                .layout = .{ .sizing = if (vertical) .{ .width = .fixed(thickness), .height = .grow } else .{ .width = .grow, .height = .fixed(thickness) } },
            });
            ui.close();
            ui.close();
        }

        fn edgeFades(self: Self, ui: *Ui, id: zui.Id, axis: zui.Axis, options: ScrollAreaOptions) void {
            if (comptime !Ui.RenderCommand.commands.contains(.gradient)) return;
            if (options.edge_fade == .none) return;
            const look = self.style(ui, if (options.edge_fade == .card) .scroll_edge_fade_raised else .scroll_edge_fade, .idle);
            const surface = look.background orelse return;
            const along = @intFromEnum(axis);
            const overflow = overflowOf(ui, id)[along];
            const offset = ui.scrollOffset(id)[along];
            if (offset > 0.5) edgeFade(ui, axis, false, surface, faded(surface, 0), look.size[1], options.layer);
            if (offset < overflow - 0.5) edgeFade(ui, axis, true, faded(surface, 0), surface, look.size[1], options.layer);
        }

        fn edgeFade(ui: *Ui, axis: zui.Axis, at_end: bool, from: Ui.Color, to: Ui.Color, depth: f32, layer: i16) void {
            const effects: Ui.Effects = .{ .gradient = .{ .from = from, .to = to, .angle = if (axis == .y) std.math.pi / 2.0 else 0 } };
            const point: zui.AnchorPoint = if (!at_end) .top_left else if (axis == .y) .bottom_left else .top_right;
            ui.box(.{
                .effects = &effects,
                .floating = .{ .attach_to = .parent, .anchor = point, .attach_point = point, .z = layer, .capture = false, .clip = .target },
                .layout = .{ .sizing = if (axis == .y) .{ .width = .grow, .height = .fixed(depth) } else .{ .width = .fixed(depth), .height = .grow } },
            });
        }

        pub const GroupBoxOptions = struct {
            /// Below the box, wrapped to its width; none when empty.
            description: []const u8 = "",
            width: zui.Sizing = .grow,
        };

        /// What `groupBox` opened, which `end` closes.
        pub const GroupBox = struct {
            widgets: Self,
            description: []const u8,

            /// Closes the box and declares the description below it.
            pub fn end(group: GroupBox, ui: *Ui) void {
                ui.close();
                if (group.description.len != 0) {
                    const description = group.widgets.style(ui, .group_box_description, .idle);
                    var padding = description.padding;
                    padding.top = description.gap;
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .padding = padding } });
                    ui.text(group.description, description.text);
                    ui.close();
                }
                ui.close();
            }
        };

        /// Opens a titled box of related rows, such as a page of settings;
        /// declare the rows, with dividers between them, then call `end`
        /// on what it returns:
        ///
        /// ```zig
        /// const account = widgets.groupBox(ui, .of("account"), "Account", .{ .description = "Your team sees your name." });
        /// widgets.labeledRow(ui, "Name");
        /// _ = widgets.textField(ui, .of("name"), &app.name, .{ .label = "Name" });
        /// ui.close();
        /// account.end(ui);
        /// ```
        pub fn groupBox(self: Self, ui: *Ui, id: zui.Id, title: []const u8, options: GroupBoxOptions) GroupBox {
            const title_look = self.style(ui, .group_box_title, .idle);
            const body = self.style(ui, .group_box_body, .idle);
            ui.open(.{
                .id = id,
                .semantics = .{ .role = .group, .label = title },
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = options.width } },
            });
            var title_padding = title_look.padding;
            title_padding.bottom = title_look.gap;
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .padding = title_padding } });
            ui.text(title, singleLine(title_look.text));
            ui.close();
            const effects: Ui.Effects = .{ .shadow = body.shadow };
            ui.open(.{
                .decoration = decorationOf(body, false),
                .effects = if (body.shadow != null) &effects else null,
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = body.padding, .child_gap = body.gap },
            });
            return .{ .widgets = self, .description = options.description };
        }

        pub const TabsOptions = struct {
            style: TabsStyle = .underline,
            /// Its name to an assistive technology.
            label: []const u8 = "",
        };

        /// A tab for each named tag of the enum behind `selected`, labeled
        /// with `labelFromIdentifier`. Clicking one selects it; the arrow
        /// keys move the selection and the focus with it, wrapping, and
        /// Home and End reach the first and the last. Only the selected tab
        /// is in the Tab order. Returns whether the selection changed.
        ///
        /// ```zig
        /// _ = widgets.tabs(ui, .of("project.tabs"), &app.project_tab, .{});
        /// switch (app.project_tab) { ... }
        /// ```
        pub fn tabs(self: Self, ui: *Ui, id: zui.Id, selected: anytype, options: TabsOptions) bool {
            const Enum = EnumPointee(@TypeOf(selected), "tabs");
            const tags = comptime std.enums.values(Enum);
            const labels = comptime tagLabels(Enum);
            const current = std.mem.indexOfScalar(Enum, tags, selected.*) orelse 0;
            var chosen = current;
            for (0..tags.len) |index| {
                if (ui.clicked(id.indexedChild("tab", index))) chosen = index;
            }
            if (ui.navigated(id.indexedChild("tab", current))) |direction| {
                const forward = (direction == .right) != (ui.environment().direction == .right_to_left);
                if (direction == .left or direction == .right) chosen = if (forward) (current + 1) % tags.len else (current + tags.len - 1) % tags.len;
            }
            if (ui.focused(id.indexedChild("tab", current))) {
                if (ui.keyPressed(.home)) chosen = 0;
                if (ui.keyPressed(.end)) chosen = tags.len - 1;
            }
            const changed = chosen != current;
            if (changed) {
                selected.* = tags[chosen];
                ui.requestFocus(id.indexedChild("tab", chosen));
            }

            const pill = options.style == .pill;
            const bar = self.style(ui, if (pill) .tabs_groove else .tabs, .idle);
            ui.open(.{
                .id = id,
                .semantics = .{ .role = .group, .label = options.label },
                .decoration = decorationOf(bar, false),
                .layout = .{
                    .sizing = if (pill) .{ .height = .fixed(bar.size[1]) } else .{ .width = .grow },
                    .padding = bar.padding,
                    .child_gap = bar.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
            self.tabIndicator(ui, id, id.indexedChild("tab", chosen), pill);
            for (labels, 0..) |tab_label, index| {
                const tab_id = id.indexedChild("tab", index);
                const is_selected = index == chosen;
                const part: Part = if (pill) (if (is_selected) .tab_pill_selected else .tab_pill) else if (is_selected) .tab_selected else .tab;
                const look = self.style(ui, part, ui.widgetState(tab_id));
                ui.open(.{
                    .id = tab_id,
                    .interactive = true,
                    .focusable = is_selected,
                    .cursor = .pointer,
                    .semantics = .{ .role = .radio, .label = tab_label, .state = .{ .checked = is_selected, .selected = is_selected } },
                    .decoration = decorationOf(look, ui.focused(tab_id)),
                    .layout = .{ .sizing = .{ .height = .fixed(look.size[1]) }, .padding = look.padding, .child_alignment = .{ .x = .center, .y = .center } },
                });
                ui.text(tab_label, singleLine(look.text));
                ui.close();
            }
            ui.close();
            return changed;
        }

        /// The selected tab's underline, or the thumb behind it in a
        /// groove, sliding from tab to tab. It is placed from the previous
        /// frame's rectangles, so the first frame draws none.
        fn tabIndicator(self: Self, ui: *Ui, bar_id: zui.Id, tab_id: zui.Id, pill: bool) void {
            if (pill) return self.slidingIndicator(ui, bar_id, tab_id, .tab_pill_thumb, 0, .center_left);
            self.slidingIndicator(ui, bar_id, tab_id, .tab_indicator, self.style(ui, .tab, .idle).padding.left, .bottom_left);
        }

        /// `part` under or behind `tab_id`, inset `label_inset` at either
        /// side, sliding through the part's motion when the tab changes.
        fn slidingIndicator(self: Self, ui: *Ui, bar_id: zui.Id, tab_id: zui.Id, part: Part, label_inset: f32, point: zui.AnchorPoint) void {
            const bar_rect = ui.rectOf(bar_id) orelse return ui.requestFrame();
            const tab_rect = ui.rectOf(tab_id) orelse return ui.requestFrame();
            const look = self.style(ui, part, .idle);
            const from_start = if (ui.environment().direction == .right_to_left)
                (bar_rect.x + bar_rect.width) - (tab_rect.x + tab_rect.width)
            else
                tab_rect.x - bar_rect.x;
            const placed = animate(ui, bar_id.child("indicator"), [2]f32, .{ from_start + label_inset, @max(tab_rect.width - 2 * label_inset, 0) }, look.motion);
            const effects: Ui.Effects = .{ .shadow = look.shadow };
            ui.box(.{
                .floating = .{ .attach_to = .parent, .anchor = point, .attach_point = point, .offset = .{ placed[0], 0 }, .z = 0, .capture = false },
                .decoration = decorationOf(look, false),
                .effects = if (look.shadow != null) &effects else null,
                .layout = .{ .sizing = .{ .width = .fixed(placed[1]), .height = .fixed(look.size[1]) } },
            });
        }

        pub const NavigationListOptions = struct {
            /// Its name to an assistive technology.
            label: []const u8 = "",
            width: zui.Sizing = .grow,
        };

        /// A sidebar's list of places, `selected` indexing `items`.
        /// Clicking a row selects it; Up and Down move the selection and
        /// the focus with it past the headings, and Home and End reach the
        /// first and the last row. Only the selected row is in the Tab
        /// order. The rows stand the `navigation_list` part's gap apart,
        /// in `DesignSkin` the `xs` spacing tier, which grows with the
        /// density. Returns whether the selection changed.
        ///
        /// ```zig
        /// const places = [_]zui_widgets.NavigationItem{
        ///     .{ .label = "Mail", .heading = true },
        ///     .{ .label = "Inbox", .count = "12", .shortcut = "Ctrl+1" },
        ///     .{ .label = "Sent", .shortcut = "Ctrl+2" },
        /// };
        /// _ = widgets.navigationList(ui, .of("places"), &places, &app.place, .{ .label = "Places" });
        /// ```
        pub fn navigationList(self: Self, ui: *Ui, id: zui.Id, items: []const NavigationItem, selected: *usize, options: NavigationListOptions) bool {
            const focus_row = if (selected.* < items.len and !items[selected.*].heading) selected.* else nextRow(items, 0, .forward);
            var chosen = selected.*;
            for (items, 0..) |item, index| {
                if (!item.heading and ui.clicked(id.indexedChild("item", index))) chosen = index;
            }
            if (focus_row) |row| if (ui.focused(id.indexedChild("item", row))) {
                if (ui.navigated(id.indexedChild("item", row))) |direction| switch (direction) {
                    .up => if (row > 0) if (nextRow(items, row - 1, .backward)) |previous| {
                        chosen = previous;
                    },
                    .down => if (nextRow(items, row + 1, .forward)) |next| {
                        chosen = next;
                    },
                    else => {},
                };
                if (ui.keyPressed(.home)) chosen = nextRow(items, 0, .forward) orelse chosen;
                if (ui.keyPressed(.end)) chosen = nextRow(items, items.len - 1, .backward) orelse chosen;
            };
            const changed = chosen != selected.*;
            if (changed) {
                selected.* = chosen;
                ui.requestFocus(id.indexedChild("item", chosen));
            }
            const focusable_row = if (changed) chosen else focus_row;

            ui.open(.{
                .id = id,
                .semantics = .{ .role = .list_box, .label = options.label },
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = options.width }, .child_gap = self.style(ui, .navigation_list, .idle).gap },
            });
            for (items, 0..) |item, index| {
                if (item.heading) {
                    const heading = self.style(ui, .navigation_heading, .idle);
                    var padding = heading.padding;
                    if (index != 0) padding.top += heading.gap;
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .padding = padding } });
                    ui.text(item.label, singleLine(heading.text));
                    ui.close();
                    continue;
                }
                const row_id = id.indexedChild("item", index);
                const is_selected = index == chosen;
                const state = ui.widgetState(row_id);
                const look = self.style(ui, if (is_selected) .navigation_item_selected else .navigation_item, state);
                ui.open(.{
                    .id = row_id,
                    .interactive = true,
                    .focusable = focusable_row == index,
                    .cursor = .pointer,
                    .semantics = .{ .role = .option, .label = item.label, .state = .{ .selected = is_selected } },
                    .decoration = decorationOf(look, ui.focused(row_id)),
                    .layout = .{
                        .sizing = .{ .width = .grow, .height = .fixed(look.size[1]) },
                        .padding = look.padding,
                        .child_gap = look.gap,
                        .child_alignment = .{ .y = .center },
                    },
                });
                ui.text(item.label, singleLine(look.text));
                if (item.count.len != 0 or item.shortcut.len != 0) {
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                    const trailing = singleLine(self.style(ui, if (is_selected) .navigation_count_selected else .navigation_count, state).text);
                    if (item.count.len != 0) ui.text(item.count, trailing);
                    if (item.shortcut.len != 0) ui.text(item.shortcut, trailing);
                }
                ui.close();
            }
            ui.close();
            return changed;
        }

        const Toward = enum { forward, backward };

        /// The first row at or past `from` going `toward`, skipping headings.
        fn nextRow(items: []const NavigationItem, from: usize, toward: Toward) ?usize {
            var index = from;
            while (index < items.len) {
                if (!items[index].heading) return index;
                if (toward == .backward) {
                    if (index == 0) return null;
                    index -= 1;
                } else index += 1;
            }
            return null;
        }

        pub const BreadcrumbsOptions = struct {
            /// Its name to an assistive technology.
            label: []const u8 = "",
        };

        const Trail = struct { folded_open: bool };

        /// The way back from the current page, `crumbs` from the top: each
        /// crumb but the last is a link, focusable and activated with Enter
        /// or Space. Past four crumbs the middle ones fold into a "…"
        /// crumb, which opens a menu of them. Returns the index of the
        /// crumb chosen this frame.
        ///
        /// ```zig
        /// if (widgets.breadcrumbs(ui, .of("path"), app.path(), .{ .label = "Location" })) |depth| app.goUp(depth);
        /// ```
        pub fn breadcrumbs(self: Self, ui: *Ui, id: zui.Id, crumbs: []const []const u8, options: BreadcrumbsOptions) ?usize {
            if (crumbs.len == 0) return null;
            const last = crumbs.len - 1;
            const folded = crumbs.len > most_crumbs_shown;
            var chosen: ?usize = null;
            for (0..last) |index| {
                if (ui.clicked(id.indexedChild("crumb", index))) chosen = index;
            }

            const separator = self.style(ui, .crumb_separator, .idle);
            ui.open(.{
                .id = id,
                .semantics = .{ .role = .group, .label = options.label },
                .layout = .{ .child_gap = separator.gap, .child_alignment = .{ .y = .center } },
            });
            for (crumbs, 0..) |crumb, index| {
                if (folded and index > 0 and index < last - 1) {
                    if (index == 1) {
                        const more_id = id.child("more");
                        self.crumbLink(ui, more_id, collapsed_crumbs_glyph, "Show the hidden levels");
                        const trail = ui.state(id, Trail);
                        if (self.menu(ui, id.child("folded"), more_id, &trail.folded_open, .{ .label = "Hidden levels" })) |hidden| {
                            for (crumbs[1 .. last - 1], 1..) |hidden_crumb, hidden_index| {
                                if (hidden.item(ui, hidden_crumb, .{})) chosen = hidden_index;
                            }
                            hidden.end(ui);
                        }
                        self.icon(ui, .chevron_right, separator);
                    }
                    continue;
                }
                if (index == last) {
                    const current = self.style(ui, .crumb_current, .idle);
                    ui.open(.{
                        .semantics = .{ .role = .label, .label = crumb, .state = .{ .selected = true } },
                        .layout = .{ .sizing = .{ .height = .fixed(current.size[1]) }, .padding = current.padding, .child_alignment = .{ .y = .center } },
                    });
                    ui.text(crumb, singleLine(current.text));
                    ui.close();
                } else {
                    self.crumbLink(ui, id.indexedChild("crumb", index), crumb, crumb);
                    self.icon(ui, .chevron_right, separator);
                }
            }
            ui.close();
            return chosen;
        }

        fn crumbLink(self: Self, ui: *Ui, crumb_id: zui.Id, content: []const u8, accessible_name: []const u8) void {
            const look = self.style(ui, .crumb, ui.widgetState(crumb_id));
            ui.open(.{
                .id = crumb_id,
                .focusable = true,
                .cursor = .pointer,
                .semantics = .{ .role = .link, .label = accessible_name },
                .decoration = decorationOf(look, ui.focused(crumb_id)),
                .layout = .{
                    .sizing = .{ .width = .fitBetween(look.size[1], std.math.inf(f32)), .height = .fixed(look.size[1]) },
                    .padding = look.padding,
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            });
            ui.text(content, singleLine(look.text));
            ui.close();
        }

        pub const RadioGroupOptions = struct {
            /// Its name to an assistive technology.
            label: []const u8 = "",
            /// `.top_to_bottom` stacks the options; `.left_to_right` puts
            /// them in a row.
            direction: zui.Direction = .top_to_bottom,
            disabled: bool = false,
        };

        /// An option for each named tag of the enum behind `selected`,
        /// labeled with `labelFromIdentifier`. Clicking one chooses it; the
        /// arrow keys move the choice and the focus with it, wrapping, and
        /// only the chosen option is in the Tab order. Returns whether the
        /// choice changed.
        ///
        /// ```zig
        /// _ = widgets.radioGroup(ui, .of("delivery"), &order.delivery, .{ .label = "Delivery" });
        /// ```
        pub fn radioGroup(self: Self, ui: *Ui, id: zui.Id, selected: anytype, options: RadioGroupOptions) bool {
            const Enum = EnumPointee(@TypeOf(selected), "radioGroup");
            const tags = comptime std.enums.values(Enum);
            const labels = comptime tagLabels(Enum);
            const current = std.mem.indexOfScalar(Enum, tags, selected.*) orelse 0;
            var chosen = current;
            if (!options.disabled) {
                for (0..tags.len) |index| {
                    if (ui.clicked(id.indexedChild("option", index))) chosen = index;
                }
                if (ui.navigated(id.indexedChild("option", current))) |direction| {
                    const mirrored = ui.environment().direction == .right_to_left;
                    const forward = switch (direction) {
                        .down => true,
                        .up => false,
                        .right => !mirrored,
                        .left => mirrored,
                    };
                    chosen = if (forward) (current + 1) % tags.len else (current + tags.len - 1) % tags.len;
                }
            }
            const changed = chosen != current;
            if (changed) {
                selected.* = tags[chosen];
                ui.requestFocus(id.indexedChild("option", chosen));
            }

            const horizontal = options.direction == .left_to_right;
            const group = self.style(ui, if (horizontal) .radio_group_horizontal else .radio_group, .idle);
            ui.open(.{
                .id = id,
                .semantics = .{ .role = .group, .label = options.label },
                .layout = .{ .direction = options.direction, .child_gap = group.gap },
            });
            for (labels, 0..) |option_label, index| {
                const option_id = id.indexedChild("option", index);
                const is_selected = index == chosen;
                const state = stateOf(ui, option_id, options.disabled);
                const row = self.style(ui, .radio, state);
                const circle = self.style(ui, if (is_selected) .radio_circle_selected else .radio_circle, state);
                ui.open(.{
                    .id = option_id,
                    .interactive = true,
                    .focusable = is_selected,
                    .disabled = options.disabled,
                    .cursor = if (options.disabled) null else .pointer,
                    .semantics = .{ .role = .radio, .label = option_label, .state = .{ .checked = is_selected } },
                    .decoration = .{ .border = if (ui.focused(option_id)) row.focus_ring else null, .corner_radius = row.corner_radius, .corner_shape = row.corner_shape },
                    .layout = .{
                        .sizing = .{ .width = .fitBetween(row.size[0], std.math.inf(f32)), .height = .fixed(row.size[1]) },
                        .child_gap = row.gap,
                        .child_alignment = .{ .y = .center },
                    },
                });
                ui.box(.{
                    .decoration = decorationOf(circle, false),
                    .layout = .{ .sizing = .{ .width = .fixed(circle.size[0]), .height = .fixed(circle.size[1]) } },
                });
                ui.text(option_label, singleLine(row.text));
                ui.close();
            }
            ui.close();
            return changed;
        }

        pub const SegmentedOptions = struct {
            /// Its name to an assistive technology.
            label: []const u8 = "",
        };

        /// A segment for each named tag of the enum behind `selected`, in a
        /// groove, the selected one on a raised thumb that slides through
        /// the toggle spring. Clicking a segment selects it; the arrow
        /// keys move the selection and the focus with it, wrapping, and
        /// only the selected segment is in the Tab order. Returns whether
        /// the selection changed.
        ///
        /// ```zig
        /// _ = widgets.segmented(ui, .of("layout"), &app.layout, .{ .label = "Layout" });
        /// ```
        pub fn segmented(self: Self, ui: *Ui, id: zui.Id, selected: anytype, options: SegmentedOptions) bool {
            const Enum = EnumPointee(@TypeOf(selected), "segmented");
            const tags = comptime std.enums.values(Enum);
            const labels = comptime tagLabels(Enum);
            const current = std.mem.indexOfScalar(Enum, tags, selected.*) orelse 0;
            var chosen = current;
            for (0..tags.len) |index| {
                if (ui.clicked(id.indexedChild("segment", index))) chosen = index;
            }
            if (ui.navigated(id.indexedChild("segment", current))) |direction| {
                const forward = (direction == .right) != (ui.environment().direction == .right_to_left);
                if (direction == .left or direction == .right) chosen = if (forward) (current + 1) % tags.len else (current + tags.len - 1) % tags.len;
            }
            const changed = chosen != current;
            if (changed) {
                selected.* = tags[chosen];
                ui.requestFocus(id.indexedChild("segment", chosen));
            }

            const groove = self.style(ui, .segmented, .idle);
            const separator = self.style(ui, .segmented_separator, .idle);
            ui.open(.{
                .id = id,
                .semantics = .{ .role = .group, .label = options.label },
                .decoration = decorationOf(groove, false),
                .layout = .{ .sizing = .{ .height = .fixed(groove.size[1]) }, .padding = groove.padding, .child_alignment = .{ .y = .center } },
            });
            self.slidingIndicator(ui, id, id.indexedChild("segment", chosen), .segmented_thumb, 0, .center_left);
            for (labels, 0..) |segment_label, index| {
                if (index != 0) {
                    const between_unselected = index != chosen and index - 1 != chosen;
                    ui.box(.{
                        .decoration = .{ .background = if (between_unselected) separator.background else null },
                        .layout = .{ .sizing = .{ .width = .fixed(separator.size[0]), .height = .fixed(@round((groove.size[1] - groove.padding.total(.y)) * separator.size[1])) } },
                    });
                }
                const segment_id = id.indexedChild("segment", index);
                const is_selected = index == chosen;
                const look = self.style(ui, if (is_selected) .segment_selected else .segment, ui.widgetState(segment_id));
                ui.open(.{
                    .id = segment_id,
                    .interactive = true,
                    .focusable = is_selected,
                    .cursor = .pointer,
                    .semantics = .{ .role = .radio, .label = segment_label, .state = .{ .checked = is_selected, .selected = is_selected } },
                    .decoration = decorationOf(look, ui.focused(segment_id)),
                    .layout = .{ .sizing = .{ .height = .fixed(look.size[1]) }, .padding = look.padding, .child_alignment = .{ .x = .center, .y = .center } },
                });
                ui.text(segment_label, singleLine(look.text));
                ui.close();
            }
            ui.close();
            return changed;
        }

        pub const NumberStepperOptions = struct {
            min: f64 = -std.math.inf(f64),
            max: f64 = std.math.inf(f64),
            /// What the buttons, the arrow keys and a scrub step by.
            step: f64 = 1,
            /// After the value, such as "nights"; none when empty.
            unit: []const u8 = "",
            /// Its name to an assistive technology.
            label: []const u8 = "",
            disabled: bool = false,
        };

        const StepperEntry = struct {
            typed: [stepper_typed_capacity]u8,
            typed_len: u8,
            was_focused: bool,
            scrubbing: bool,
            scrub_start_x: f32,
            scrub_start_value: f64,
        };

        const stepper_typed_capacity = 24;

        /// Edits the integer or float behind `value` between − and +
        /// buttons, each disabled at its limit. While focused, Up and Down
        /// step and typing replaces the value; dragging the value sideways
        /// scrubs it a step for every few units. Returns whether the value
        /// changed.
        ///
        /// ```zig
        /// _ = widgets.numberStepper(ui, .of("nights"), &booking.nights, .{ .min = 1, .max = 30, .unit = "nights", .label = "Nights" });
        /// ```
        pub fn numberStepper(self: Self, ui: *Ui, id: zui.Id, value: anytype, options: NumberStepperOptions) bool {
            const Value = NumberPointee(@TypeOf(value), "numberStepper");
            const entry = ui.state(id, StepperEntry);
            const value_id = id.child("value");
            const decrement_id = id.child("decrement");
            const increment_id = id.child("increment");
            const focused = ui.focused(id);
            const previous: f64 = numberToFloat(value.*);
            var proposed = previous;

            if (!focused or !entry.was_focused) entry.typed_len = 0;
            entry.was_focused = focused;
            if (!options.disabled) {
                if (ui.clicked(decrement_id)) proposed -= options.step;
                if (ui.clicked(increment_id)) proposed += options.step;
                if (ui.adjusted(id)) |steps| {
                    proposed += options.step * @as(f64, @floatFromInt(steps));
                    entry.typed_len = 0;
                }
                if (focused) {
                    var edited = false;
                    for (ui.keyEvents()) |key_event| switch (key_event.key) {
                        .backspace => if (entry.typed_len > 0) {
                            entry.typed_len -= 1;
                            edited = true;
                        },
                        .enter, .escape => entry.typed_len = 0,
                        else => {},
                    };
                    for (ui.typedText()) |byte| {
                        const numeric = std.ascii.isDigit(byte) or byte == '-' or (byte == '.' and @typeInfo(Value) == .float);
                        if (!numeric or entry.typed_len == stepper_typed_capacity) continue;
                        entry.typed[entry.typed_len] = byte;
                        entry.typed_len += 1;
                        edited = true;
                    }
                    if (edited and entry.typed_len != 0) if (std.fmt.parseFloat(f64, entry.typed[0..entry.typed_len])) |typed| {
                        proposed = typed;
                    } else |_| {};
                }
                if (ui.pressed(value_id)) {
                    if (ui.primaryPointer()) |pointer| {
                        if (!entry.scrubbing) {
                            entry.scrubbing = true;
                            entry.scrub_start_x = pointer.position[0];
                            entry.scrub_start_value = previous;
                        }
                        const steps: f64 = @trunc((pointer.position[0] - entry.scrub_start_x) / stepper_scrub_distance);
                        proposed = entry.scrub_start_value + steps * options.step;
                    }
                } else entry.scrubbing = false;
            }

            var changed = false;
            if (proposed != previous) {
                const stored = floatToNumber(Value, std.math.clamp(proposed, options.min, options.max));
                changed = stored != value.*;
                value.* = stored;
            }
            const current: f64 = numberToFloat(value.*);

            const state = stateOf(ui, id, options.disabled);
            const container = self.style(ui, .number_stepper, state);
            const shown = self.style(ui, .number_stepper_value, state);
            const value_style = singleLine(shown.text);
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .semantics = .{
                    .role = .slider,
                    .label = options.label,
                    .value = .{ .range = .{ .value = current, .min = options.min, .max = options.max, .step = options.step } },
                    .actions = .initOne(.adjust),
                },
                .decoration = decorationOf(container, ui.focused(id)),
                .layout = .{ .sizing = .{ .height = .fixed(container.size[1]) }, .child_alignment = .{ .y = .center } },
            });
            self.stepperButton(ui, decrement_id, .number_stepper_decrement, options.disabled or current <= options.min, "Decrease");
            var digits: [32]u8 = undefined;
            const text = if (entry.typed_len != 0) entry.typed[0..entry.typed_len] else formatNumber(&digits, value.*);
            ui.open(.{
                .id = value_id,
                .interactive = !options.disabled,
                .cursor = if (options.disabled) null else .resize_horizontal,
                .gestures = .{ .pan = .horizontal },
                .layout = .{
                    .sizing = .{ .width = .fitBetween(ui.measureText(stepper_value_widest, value_style)[0] + shown.padding.total(.x), std.math.inf(f32)), .height = .grow },
                    .padding = shown.padding,
                    .child_gap = shown.padding.left,
                    .child_alignment = .{ .x = .center, .y = .center },
                },
            });
            ui.text(text, value_style);
            if (options.unit.len != 0) ui.text(options.unit, singleLine(self.style(ui, .number_stepper_unit, state).text));
            ui.close();
            self.stepperButton(ui, increment_id, .number_stepper_increment, options.disabled or current >= options.max, "Increase");
            ui.close();
            return changed;
        }

        fn stepperButton(self: Self, ui: *Ui, id: zui.Id, part: Part, disabled: bool, accessible_name: []const u8) void {
            const look = self.style(ui, part, stateOf(ui, id, disabled));
            ui.open(.{
                .id = id,
                .interactive = true,
                .disabled = disabled,
                .cursor = if (disabled) null else .pointer,
                .semantics = .{ .role = .button, .label = accessible_name },
                .decoration = decorationOf(look, false),
                .layout = .{ .sizing = .{ .width = .fixed(look.size[1]), .height = .fixed(look.size[1]) }, .child_alignment = .{ .x = .center, .y = .center } },
            });
            ui.text(look.glyph, singleLine(look.text));
            ui.close();
        }

        pub const SearchFieldOptions = struct {
            placeholder: []const u8 = "Search",
            /// The keys that reach the field, shown while it is empty and
            /// unfocused; none when empty. The application handles them.
            shortcut: []const u8 = "",
            /// Its name to an assistive technology; the placeholder when empty.
            label: []const u8 = "",
            disabled: bool = false,
            width: zui.Sizing = .grow,
        };

        /// A text field for a query, with a search icon at its start, its
        /// shortcut while empty and unfocused, and a button that clears it
        /// while it has text. Escape clears it, and a second Escape leaves
        /// it.
        ///
        /// ```zig
        /// if (ui.chordPressed(.{ .key = .k, .modifiers = .{ .control = true } })) ui.requestFocus(.of("search"));
        /// if (widgets.searchField(ui, .of("search"), &app.query, .{ .shortcut = "Ctrl K" }).changed) app.refilter();
        /// ```
        pub fn searchField(self: Self, ui: *Ui, id: zui.Id, text: *EditableText, options: SearchFieldOptions) TextFieldResult {
            var escaped = false;
            if (!options.disabled and ui.focused(id) and ui.keyPressed(.escape)) {
                if (text.len != 0) {
                    text.set("");
                    escaped = true;
                } else ui.requestFocus(.none);
            }
            var result = self.editableLine(ui, id, text, .{
                .field = .search_field,
                .placeholder = options.placeholder,
                .label = options.label,
                .leading_icon = .search,
                .leading_part = .search_field_icon,
                .shortcut = options.shortcut,
                .clearable = true,
                .disabled = options.disabled,
                .width = options.width,
            });
            result.changed = result.changed or escaped;
            return result;
        }

        pub const IconButtonOptions = struct {
            /// Its name to an assistive technology, and its tooltip.
            label: []const u8,
            variant: IconButtonVariant = .tertiary,
            size: zui.design.ControlSize = .medium,
            disabled: bool = false,
        };

        /// A square button showing `name`, true in the frame it is clicked,
        /// or activated with Enter or Space while focused. Its accessible
        /// label is required, since it shows no text, and is its tooltip.
        /// Under a design without an icon font it draws no icon, counted in
        /// `Diagnostics.missing_icons`.
        ///
        /// ```zig
        /// if (widgets.iconButton(ui, .of("close"), .close, .{ .label = "Close" })) app.closePanel();
        /// ```
        pub fn iconButton(self: Self, ui: *Ui, id: zui.Id, name: zui.design.Icon, options: IconButtonOptions) bool {
            const state = stateOf(ui, id, options.disabled);
            const look = self.style(ui, options.variant.part(), state);
            const control = self.style(ui, controlSizePart(options.size), state);
            const scale = pressScale(ui, id, look);
            const effects: Ui.Effects = .{ .transform = .{ .scale = @splat(scale) } };
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .semantics = .{ .role = .button, .label = options.label },
                .decoration = decorationOf(look, ui.focused(id)),
                .effects = if (scale != 1) &effects else null,
                .layout = .{ .sizing = .{ .width = .fixed(control.size[1]), .height = .fixed(control.size[1]) }, .child_alignment = .{ .x = .center, .y = .center } },
            });
            var icon_look = look;
            icon_look.size[0] = control.size[0];
            icon_look.glyph = "";
            self.icon(ui, name, icon_look);
            ui.close();
            self.tooltip(ui, id, options.label, .{});
            return ui.clicked(id);
        }

        /// Text that leads elsewhere, underlined, true in the frame it is
        /// clicked or activated with Enter or Space. Opening `url` is the
        /// application's, through its host's `open_url` service; the link
        /// reports it to an assistive technology.
        ///
        /// ```zig
        /// if (widgets.link(ui, .of("policy"), "Cancellation policy", "https://example.com/cancellation")) try services.open_url(url);
        /// ```
        pub fn link(self: Self, ui: *Ui, id: zui.Id, content: []const u8, url: []const u8) bool {
            const state = ui.widgetState(id);
            const look = self.style(ui, .link, state);
            const underline = self.style(ui, .link_underline, state);
            ui.open(.{
                .id = id,
                .focusable = true,
                .cursor = .pointer,
                .semantics = .{ .role = .link, .label = content, .value = .{ .text = url } },
                .decoration = .{ .border = if (ui.focused(id)) look.focus_ring else null, .corner_radius = look.corner_radius, .corner_shape = look.corner_shape },
                .layout = .{
                    .direction = .top_to_bottom,
                    .sizing = .{ .height = .fitBetween(look.size[1], std.math.inf(f32)) },
                    .child_alignment = .{ .y = .center },
                },
            });
            ui.text(content, singleLine(look.text));
            ui.box(.{ .decoration = .{ .background = underline.background }, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(underline.size[1]) } } });
            ui.close();
            return ui.clicked(id);
        }

        pub const ChipOptions = struct {
            /// A filter chip, toggled when clicked; null for one that is
            /// not selectable.
            selected: ?*bool = null,
            /// A close button at its end, and Delete or Backspace while it
            /// is focused, close it.
            closable: bool = false,
            leading_icon: ?zui.design.Icon = null,
            /// Its name to an assistive technology; `content` when empty.
            label: []const u8 = "",
            disabled: bool = false,
        };

        pub const ChipResult = struct {
            /// Its selection changed.
            toggled: bool = false,
            /// It asked to be closed; the application removes it.
            closed: bool = false,
        };

        /// A compact choice, filter or tag. A selected chip leads with a
        /// check that grows in through the check motion.
        ///
        /// ```zig
        /// for (app.filters, 0..) |*filter, index| {
        ///     if (widgets.chip(ui, .indexed("filter", index), filter.name, .{ .selected = &filter.on }).toggled) app.refilter();
        /// }
        /// if (widgets.chip(ui, .of("tag.urgent"), "Urgent", .{ .closable = true }).closed) app.removeTag(.urgent);
        /// ```
        pub fn chip(self: Self, ui: *Ui, id: zui.Id, content: []const u8, options: ChipOptions) ChipResult {
            const close_id = id.child("close");
            var result: ChipResult = .{};
            if (!options.disabled) {
                if (options.closable and (ui.clicked(close_id) or ui.dismissed(id) or
                    (ui.focused(id) and (ui.keyPressed(.delete) or ui.keyPressed(.backspace)))))
                {
                    result.closed = true;
                } else if (options.selected) |selected| if (ui.clicked(id)) {
                    selected.* = !selected.*;
                    result.toggled = true;
                };
            }
            const is_selected = if (options.selected) |selected| selected.* else false;
            const state = stateOf(ui, id, options.disabled);
            const look = self.style(ui, if (is_selected) .chip_selected else .chip, state);
            const accessible_name = if (options.label.len != 0) options.label else content;
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .semantics = .{
                    .role = if (options.selected != null) .checkbox else .button,
                    .label = accessible_name,
                    .state = .{ .checked = if (options.selected != null) is_selected else null },
                    .actions = if (options.closable) .initOne(.dismiss) else .initEmpty(),
                },
                .decoration = decorationOf(look, ui.focused(id)),
                .layout = .{
                    .sizing = .{ .height = .fixed(look.size[1]) },
                    .padding = look.padding,
                    .child_gap = look.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
            if (options.selected != null) {
                const check = self.style(ui, .chip_check, state);
                const grown = animate(ui, id.child("check"), f32, if (is_selected) 1 else 0, if (is_selected) check.motion else .{ .tween = .{ .duration = 0 } });
                if (is_selected) {
                    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(check.size[0] * grown) }, .child_alignment = .{ .x = .center } }, .clip = .both });
                    self.icon(ui, .check, check);
                    ui.close();
                }
            }
            if (options.leading_icon) |name| self.icon(ui, name, self.style(ui, .chip_icon, state));
            ui.text(content, singleLine(look.text));
            if (options.closable) {
                const close = self.style(ui, .chip_close, if (options.disabled) .disabled else nestedState(ui, close_id, state));
                ui.open(.{
                    .id = close_id,
                    .interactive = !options.disabled,
                    .cursor = if (options.disabled) null else .pointer,
                    .semantics = .{ .role = .button, .label = "Remove" },
                    .decoration = decorationOf(close, false),
                    .layout = .{ .sizing = .{ .width = .fixed(close.size[1]), .height = .fixed(close.size[1]) }, .child_alignment = .{ .x = .center, .y = .center } },
                });
                self.icon(ui, .close, close);
                ui.close();
            }
            ui.close();
            return result;
        }

        pub const ToggleOptions = struct {
            disabled: bool = false,
            /// Its name to an assistive technology; `content` when empty.
            label: []const u8 = "",
        };

        /// A switch after its label, turning `on` on or off when clicked or
        /// with Space; returns whether it did. Its thumb slides through the
        /// toggle spring and widens while pressed. An empty `content` draws
        /// the switch alone, for the end of a settings row.
        ///
        /// ```zig
        /// widgets.labeledRowWith(ui, "Breakfast", .{ .description = "Served from 7 to 10." });
        /// _ = widgets.toggle(ui, .of("breakfast"), "", &booking.breakfast, .{ .label = "Breakfast" });
        /// ui.close();
        /// ```
        pub fn toggle(self: Self, ui: *Ui, id: zui.Id, content: []const u8, on: *bool, options: ToggleOptions) bool {
            const toggled = !options.disabled and ui.clicked(id);
            if (toggled) on.* = !on.*;
            const state = stateOf(ui, id, options.disabled);
            const row = self.style(ui, .toggle, state);
            const track = self.style(ui, if (on.*) .toggle_track_on else .toggle_track, state);
            const thumb = self.style(ui, if (on.*) .toggle_thumb_on else .toggle_thumb, state);
            const inset = (track.size[1] - thumb.size[1]) / 2;
            const widening = if (state == .pressed) thumb.gap else 0;
            const travel = track.size[0] - 2 * inset - thumb.size[0] - widening;
            const placed = animate(ui, id.child("thumb"), [2]f32, .{ if (on.*) travel else 0, thumb.size[0] + widening }, thumb.motion);
            ui.open(.{
                .id = id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .semantics = .{ .role = .toggle, .label = if (options.label.len != 0) options.label else content, .state = .{ .checked = on.* } },
                .layout = .{ .sizing = .{ .height = .fixed(row.size[1]) }, .child_gap = row.gap, .child_alignment = .{ .y = .center } },
            });
            if (content.len != 0) ui.text(content, singleLine(row.text));
            ui.open(.{
                .decoration = decorationOf(track, ui.focused(id)),
                .layout = .{ .sizing = .{ .width = .fixed(track.size[0]), .height = .fixed(track.size[1]) } },
            });
            const effects: Ui.Effects = .{ .shadow = thumb.shadow };
            ui.box(.{
                .floating = .{ .attach_to = .parent, .anchor = .center_left, .attach_point = .center_left, .offset = .{ inset + placed[0], 0 }, .capture = false },
                .decoration = decorationOf(thumb, false),
                .effects = if (thumb.shadow != null) &effects else null,
                .layout = .{ .sizing = .{ .width = .fixed(placed[1]), .height = .fixed(thumb.size[1]) } },
            });
            ui.close();
            ui.close();
            return toggled;
        }

        pub const TooltipOptions = struct {
            /// The keys that do the same, shown after the text; none when
            /// empty.
            shortcut: []const u8 = "",
            placement: Placement = .below,
        };

        const TooltipState = struct {
            waiting: bool,
            shown: bool,
            /// Focus came with a press, so the tooltip shows only while
            /// hovered.
            pointer_focus: bool,
            escaped: bool,
            hovered_since: zui.Instant,
        };

        const TooltipWarmth = struct { closed: bool, closed_at: zui.Instant };
        const tooltip_warmth_id: zui.Id = .of("zui_widgets.tooltip_warmth");

        /// `content` beside `anchor_id`, an element declared before it:
        /// after half a second of hover, at once when another tooltip closed
        /// within the last 0.3 s, and at once when the anchor takes focus
        /// other than by a press. It takes no pointer, and Escape hides it
        /// until the pointer and the focus leave. While one is due, an idle
        /// application asks only for a frame at the instant it is.
        ///
        /// ```zig
        /// if (widgets.button(ui, .of("share"), "Share", .{})) app.share();
        /// widgets.tooltip(ui, .of("share"), "Copy a link to this page", .{ .shortcut = "Ctrl+Shift+S" });
        /// ```
        pub fn tooltip(self: Self, ui: *Ui, anchor_id: zui.Id, content: []const u8, options: TooltipOptions) void {
            const bubble_id = anchor_id.child("tooltip");
            const tip = ui.state(bubble_id, TooltipState);
            const warmth = ui.state(tooltip_warmth_id, TooltipWarmth);
            const now = ui.now();
            const focused = ui.focused(anchor_id);
            const pressed = ui.pressed(anchor_id);
            if (pressed or ui.clicked(anchor_id)) {
                tip.pointer_focus = true;
            } else if (!focused) tip.pointer_focus = false;
            const hovering = ui.hovered(anchor_id) and !pressed;
            const keyboard_focus = focused and !tip.pointer_focus;
            if (!hovering and !keyboard_focus) {
                tip.escaped = false;
            } else if (ui.keyPressed(.escape)) tip.escaped = true;
            if (!(hovering or keyboard_focus) or tip.escaped) {
                if (tip.shown) warmth.* = .{ .closed = true, .closed_at = now };
                tip.shown = false;
                tip.waiting = false;
                return;
            }
            const opening = !tip.shown;
            if (opening) {
                const warm = warmth.closed and now.isBefore(warmth.closed_at.addSeconds(tooltip_warm_seconds));
                if (!keyboard_focus and !warm) {
                    if (!tip.waiting) {
                        tip.waiting = true;
                        tip.hovered_since = now;
                    }
                    const due = tip.hovered_since.addSeconds(tooltip_delay_seconds);
                    if (now.isBefore(due)) return ui.requestFrameAt(due);
                }
                tip.shown = true;
            }

            const look = self.style(ui, .tooltip, .idle);
            const shortcut = self.style(ui, .tooltip_shortcut, .idle);
            const placed = placeBeside(ui, anchor_id, bubble_id, options.placement, look.gap, .center);
            const entered = entrance(ui, bubble_id.child("enter"), opening, look.motion);
            const effects = overlayEffects(look, enteredScale(entered), placed.origin);
            ui.open(.{
                .id = bubble_id,
                .floating = slid(placed, entered, look.layer, false),
                .semantics = .{ .role = .tooltip, .label = content },
                .decoration = decorationOf(look, false),
                .effects = effectsOrNull(&effects),
                .exit = look.exit,
                .layout = .{
                    .sizing = .{ .width = .fitBetween(0, look.size[0]) },
                    .padding = look.padding,
                    .child_gap = shortcut.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
            ui.text(content, look.text);
            if (options.shortcut.len != 0) ui.text(options.shortcut, singleLine(shortcut.text));
            ui.close();
        }

        pub const MenuOptions = struct {
            /// Its name to an assistive technology.
            label: []const u8 = "",
            /// Where a menu opened from an anchor opens; a context menu
            /// opens at the pointer.
            placement: Placement = .below,
        };

        pub const MenuItemOptions = struct {
            /// The keys that do the same, at the item's end; none when empty.
            shortcut: []const u8 = "",
            /// Drawn in the leading column of an item that is not checkable.
            icon: ?zui.design.Icon = null,
            /// Null for an item that is not checkable; true draws its check.
            checked: ?bool = null,
            /// An item that destroys, in the danger colors.
            danger: bool = false,
            disabled: bool = false,
        };

        const MenuState = struct {
            was_open: bool,
            at_point: bool,
            /// Where a context menu opened, from the window's top-left.
            point: [2]f32,
            /// What focus goes back to when it closes.
            opener: u64,
            item_count: u8,
            disabled_items: u64,
            leading_column: bool,
            declared: u8,
            declared_disabled: u64,
            declared_leading: bool,
            focused_item: u8,
            typed: u8,
            typed_after_focus: u8,
            typed_first: u8,
        };

        const no_item = std.math.maxInt(u8);

        /// What `menu` and `contextMenu` opened: declare its items, then call
        /// `end`.
        pub const Menu = struct {
            widgets: Self,
            id: zui.Id,
            open: *bool,
            state: *MenuState,

            /// True in the frame the item is chosen, by a click, Enter or
            /// Space, which closes the menu and gives focus back to what
            /// opened it.
            pub fn item(opened: Menu, ui: *Ui, content: []const u8, options: MenuItemOptions) bool {
                return opened.widgets.menuItem(ui, opened, content, options);
            }

            /// A line between two groups of items.
            pub fn separator(opened: Menu, ui: *Ui) void {
                const line = opened.widgets.style(ui, .menu_separator, .idle);
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .padding = line.padding } });
                ui.box(.{ .decoration = .{ .background = line.background }, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(line.size[1]) } } });
                ui.close();
            }

            /// A label above the group of items after it.
            pub fn section(opened: Menu, ui: *Ui, content: []const u8) void {
                const heading = opened.widgets.style(ui, .menu_section, .idle);
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .padding = heading.padding } });
                ui.text(content, singleLine(heading.text));
                ui.close();
            }

            /// Closes the panel.
            pub fn end(opened: Menu, ui: *Ui) void {
                ui.close();
                const state = opened.state;
                if (state.declared_leading != state.leading_column) ui.requestFrame();
                state.item_count = state.declared;
                state.disabled_items = state.declared_disabled;
                state.leading_column = state.declared_leading;
                const jump = if (state.typed_after_focus != no_item) state.typed_after_focus else state.typed_first;
                if (jump != no_item) ui.requestFocus(menuItemId(opened.id, jump));
            }
        };

        /// A menu beside `anchor_id`, an element declared before it, while
        /// `open` is true; clicking the anchor opens it and focuses its first
        /// item. Up and Down move through the items, wrapping past the
        /// disabled ones, Home and End reach the first and the last, and a
        /// letter jumps to the next item that starts with it. Choosing an
        /// item, Escape, a click outside or a `dismiss` action closes it and
        /// gives focus back to the anchor. It opens below the anchor unless
        /// `placement` says otherwise, flipped where the window has no room.
        /// Returns the menu to declare items in while it is open, and in the
        /// frame it closes, so it fades out from where it was.
        ///
        /// ```zig
        /// _ = widgets.button(ui, .of("file"), "File", .{ .variant = .tertiary });
        /// if (widgets.menu(ui, .of("file.menu"), .of("file"), &app.file_menu_open, .{ .label = "File" })) |file| {
        ///     if (file.item(ui, "Open", .{ .shortcut = "Ctrl+O" })) app.open();
        ///     if (file.item(ui, "Autosave", .{ .checked = app.autosave })) app.autosave = !app.autosave;
        ///     file.separator(ui);
        ///     if (file.item(ui, "Delete", .{ .danger = true })) app.delete();
        ///     file.end(ui);
        /// }
        /// ```
        pub fn menu(self: Self, ui: *Ui, id: zui.Id, anchor_id: zui.Id, open: *bool, options: MenuOptions) ?Menu {
            const state = ui.state(id, MenuState);
            if (ui.clicked(anchor_id)) {
                open.* = !open.*;
                state.at_point = false;
            }
            return self.openMenu(ui, id, anchor_id, open, state, options);
        }

        /// A menu at the pointer when the user asks for `region_id`'s context
        /// menu: a right click on it, the menu key while it is focused, or a
        /// long press on one that declares `.gestures.long_press`. The region
        /// must take the pointer, by being interactive or focusable or
        /// declaring a gesture. The menu opens toward the side of the pointer
        /// with room, and otherwise works as `menu` does, giving focus back
        /// to what had it.
        ///
        /// ```zig
        /// _ = widgets.card(ui, row_id, .{ .interactive = true, .label = file.name });
        /// ui.close();
        /// if (widgets.contextMenu(ui, row_id.child("menu"), row_id, &app.row_menu_open, .{ .label = file.name })) |row_menu| {
        ///     if (row_menu.item(ui, "Rename", .{ .shortcut = "F2" })) app.rename(file);
        ///     row_menu.end(ui);
        /// }
        /// ```
        pub fn contextMenu(self: Self, ui: *Ui, id: zui.Id, region_id: zui.Id, open: *bool, options: MenuOptions) ?Menu {
            const state = ui.state(id, MenuState);
            if (ui.contextRequested(region_id)) {
                open.* = true;
                state.at_point = true;
                state.point = contextPoint(ui, region_id, ui.keyPressed(.menu));
            }
            return self.openMenu(ui, id, region_id, open, state, options);
        }

        /// The pointer, when it is over the region and the menu key did not
        /// ask; the region's center otherwise.
        fn contextPoint(ui: *const Ui, region_id: zui.Id, from_key: bool) [2]f32 {
            const rect = ui.rectOf(region_id) orelse return .{ 0, 0 };
            if (!from_key) if (ui.primaryPointer()) |pointer| {
                const at = pointer.position;
                if (at[0] >= rect.x and at[1] >= rect.y and at[0] < rect.x + rect.width and at[1] < rect.y + rect.height) return at;
            };
            return .{ rect.x + rect.width / 2, rect.y + rect.height / 2 };
        }

        fn openMenu(self: Self, ui: *Ui, id: zui.Id, opener_id: zui.Id, open: *bool, state: *MenuState, options: MenuOptions) ?Menu {
            const panel_id = id.child("panel");
            const backdrop_id = id.child("backdrop");
            const opening = open.* and !state.was_open;
            const closing = open.* and !opening and (ui.clicked(backdrop_id) or ui.dismissed(panel_id));
            if (closing) open.* = false;
            if (!open.* and !closing) {
                if (state.was_open) ui.requestFocus(.{ .hash = state.opener });
                state.was_open = false;
                return null;
            }
            if (closing) {
                state.was_open = false;
                ui.requestFocus(.{ .hash = state.opener });
            } else if (opening) {
                const focused_before = ui.focusedId();
                state.was_open = true;
                state.opener = if (state.at_point and !focused_before.isNone()) focused_before.hash else opener_id.hash;
                ui.requestFocus(menuItemId(id, if (state.item_count != 0) enabledItem(state, 0, .forward) else 0));
            }
            state.declared = 0;
            state.declared_disabled = 0;
            state.declared_leading = false;
            state.focused_item = no_item;
            state.typed_after_focus = no_item;
            state.typed_first = no_item;
            state.typed = 0;
            if (!opening and !closing) {
                for (0..state.item_count) |index| {
                    if (ui.focused(menuItemId(id, index))) state.focused_item = @intCast(index);
                }
                if (state.focused_item != no_item) menuKeys(ui, id, state);
                for (ui.typedText()) |byte| if (std.ascii.isAlphanumeric(byte)) {
                    state.typed = std.ascii.toLower(byte);
                    break;
                };
            }

            const look = self.style(ui, .menu, .idle);
            const viewport = ui.viewport();
            if (!closing) ui.box(.{
                .id = backdrop_id,
                .interactive = true,
                .floating = .{ .attach_to = .root, .z = look.layer },
                .layout = .{ .sizing = .{ .width = .fixed(viewport[0]), .height = .fixed(viewport[1]) } },
            });
            const placed = if (state.at_point) placeAtPoint(ui, panel_id, state.point) else placeBeside(ui, opener_id, panel_id, options.placement, look.gap, .start);
            const entered = entrance(ui, panel_id.child("enter"), opening, look.motion);
            const effects = overlayEffects(look, enteredScale(entered), placed.origin);
            ui.open(.{
                .id = panel_id,
                .focus_scope = true,
                .semantics = .{ .role = .menu, .label = options.label, .actions = .initOne(.dismiss) },
                .floating = slid(placed, entered, look.layer + 1, true),
                .decoration = decorationOf(look, false),
                .effects = effectsOrNull(&effects),
                .exit = look.exit,
                .layout = .{
                    .direction = .top_to_bottom,
                    .padding = look.padding,
                    .sizing = .{ .width = .fitBetween(look.size[0], look.size[1]) },
                },
            });
            return .{ .widgets = self, .id = id, .open = open, .state = state };
        }

        fn menuItemId(menu_id: zui.Id, index: usize) zui.Id {
            return menu_id.indexedChild("item", index);
        }

        fn menuKeys(ui: *Ui, id: zui.Id, state: *const MenuState) void {
            const count: usize = state.item_count;
            var target: usize = state.focused_item;
            for (ui.keyEvents()) |key_event| switch (key_event.key) {
                .down => target = enabledItem(state, target + 1, .forward),
                .up => target = enabledItem(state, target + count - 1, .backward),
                .home => target = enabledItem(state, 0, .forward),
                .end => target = enabledItem(state, count - 1, .backward),
                else => {},
            };
            if (target != state.focused_item) ui.requestFocus(menuItemId(id, target));
        }

        /// The first item at or past `start` going `toward`, wrapping, that
        /// was not disabled in the previous frame.
        fn enabledItem(state: *const MenuState, start: usize, toward: Toward) usize {
            const count: usize = state.item_count;
            var index = start % count;
            for (0..count) |_| {
                const disabled = index < menu_items_tracked and state.disabled_items & (@as(u64, 1) << @intCast(index)) != 0;
                if (!disabled) return index;
                index = if (toward == .forward) (index + 1) % count else (index + count - 1) % count;
            }
            return start % count;
        }

        fn menuItem(self: Self, ui: *Ui, opened: Menu, content: []const u8, options: MenuItemOptions) bool {
            const state = opened.state;
            const index: usize = state.declared;
            if (state.declared < no_item - 1) state.declared += 1;
            const item_id = menuItemId(opened.id, index);
            if (options.disabled and index < menu_items_tracked) state.declared_disabled |= @as(u64, 1) << @intCast(index);
            const leading = options.checked != null or options.icon != null;
            if (leading) state.declared_leading = true;
            if (state.typed != 0 and !options.disabled and content.len != 0 and std.ascii.toLower(content[0]) == state.typed) {
                if (state.typed_first == no_item) state.typed_first = @intCast(index);
                if (state.typed_after_focus == no_item and (state.focused_item == no_item or index > state.focused_item)) state.typed_after_focus = @intCast(index);
            }
            const chosen = !options.disabled and ui.clicked(item_id);
            if (chosen) {
                opened.open.* = false;
                state.was_open = false;
                ui.requestFocus(.{ .hash = state.opener });
            }

            const item_state = stateOf(ui, item_id, options.disabled);
            const look = self.style(ui, if (options.danger) .menu_item_danger else .menu_item, item_state);
            ui.open(.{
                .id = item_id,
                .focusable = true,
                .disabled = options.disabled,
                .cursor = if (options.disabled) null else .pointer,
                .semantics = .{ .role = .menu_item, .label = content, .state = .{ .checked = options.checked } },
                .decoration = decorationOf(look, ui.focused(item_id)),
                .layout = .{
                    .sizing = .{ .width = .grow, .height = .fixed(look.size[1]) },
                    .padding = look.padding,
                    .child_gap = look.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
            if (state.leading_column or leading) {
                const check = self.style(ui, .menu_check, item_state);
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(check.size[0]) }, .child_alignment = .{ .x = .center, .y = .center } } });
                if (options.checked orelse false) {
                    self.icon(ui, .check, check);
                } else if (options.checked == null) {
                    if (options.icon) |name| self.icon(ui, name, self.style(ui, .menu_icon, item_state));
                }
                ui.close();
            }
            ui.text(content, singleLine(look.text));
            if (options.shortcut.len != 0) {
                const shortcut = self.style(ui, .menu_shortcut, item_state);
                var room: zui.Sizing = .grow;
                room.min = shortcut.gap;
                ui.box(.{ .layout = .{ .sizing = .{ .width = room } } });
                var shortcut_style = singleLine(shortcut.text);
                if (options.danger) shortcut_style.color = look.text.color;
                ui.text(options.shortcut, shortcut_style);
            }
            ui.close();
            return chosen;
        }

        pub const PopoverOptions = struct {
            placement: Placement = .below,
            /// Its name to an assistive technology.
            label: []const u8 = "",
            /// Stays open beside a page that still takes the pointer, as a
            /// panel pinned in place: a click outside does not close it, and
            /// Tab moves in and out of it. Its anchor, Escape, a `dismiss`
            /// action or the application closes it.
            pinned: bool = false,
        };

        /// What `popover` opened: declare its content, then call `end`.
        pub const Popover = struct {
            pub fn end(_: Popover, ui: *Ui) void {
                ui.close();
            }
        };

        const PopoverState = struct { was_open: bool };

        /// A panel beside `anchor_id`, an element declared before it, while
        /// `open` is true, its content in a column; clicking the anchor
        /// toggles it. It opens on `placement`'s side of the anchor and flips
        /// to the opposite one where the window has no room, kept inside the
        /// window along the other axis. Escape, a click outside or a
        /// `dismiss` action closes it and gives focus back to the anchor; Tab
        /// stays inside it unless it is pinned. Returns the popover to
        /// declare content in while it is open, and in the frame it closes
        /// itself, so it fades out from where it was.
        ///
        /// ```zig
        /// _ = widgets.button(ui, .of("filters"), "Filters", .{ .variant = .secondary });
        /// if (widgets.popover(ui, .of("filters.panel"), .of("filters"), &app.filters_open, .{ .label = "Filters" })) |panel| {
        ///     _ = widgets.checkbox(ui, .of("filters.unread"), "Unread only", &app.unread_only, .{});
        ///     panel.end(ui);
        /// }
        /// ```
        pub fn popover(self: Self, ui: *Ui, id: zui.Id, anchor_id: zui.Id, open: *bool, options: PopoverOptions) ?Popover {
            const state = ui.state(id, PopoverState);
            const panel_id = id.child("panel");
            const backdrop_id = id.child("backdrop");
            if (ui.clicked(anchor_id)) open.* = !open.*;
            var closed_itself = false;
            if (open.* and state.was_open) {
                const outside = !options.pinned and ui.clicked(backdrop_id);
                if (outside or ui.dismissed(panel_id) or (ui.focused(anchor_id) and ui.keyPressed(.escape))) {
                    open.* = false;
                    closed_itself = true;
                }
            }
            if (!open.*) {
                if (state.was_open and (closed_itself or !options.pinned)) ui.requestFocus(anchor_id);
                state.was_open = false;
                if (!closed_itself) return null;
            }
            const opening = open.* and !state.was_open;
            if (open.*) state.was_open = true;

            const look = self.style(ui, .popover, .idle);
            if (!options.pinned and !closed_itself) {
                const viewport = ui.viewport();
                ui.box(.{
                    .id = backdrop_id,
                    .interactive = true,
                    .floating = .{ .attach_to = .root, .z = look.layer },
                    .layout = .{ .sizing = .{ .width = .fixed(viewport[0]), .height = .fixed(viewport[1]) } },
                });
            }
            const placed = placeBeside(ui, anchor_id, panel_id, options.placement, look.gap, .start);
            const entered = entrance(ui, panel_id.child("enter"), opening, look.motion);
            const effects = overlayEffects(look, enteredScale(entered), placed.origin);
            ui.open(.{
                .id = panel_id,
                .focus_scope = !options.pinned,
                .semantics = .{ .role = .dialog, .label = options.label, .actions = .initOne(.dismiss) },
                .floating = slid(placed, entered, look.layer + 1, true),
                .decoration = decorationOf(look, false),
                .effects = effectsOrNull(&effects),
                .exit = look.exit,
                .layout = .{
                    .direction = .top_to_bottom,
                    .sizing = .{ .width = .fitBetween(0, look.size[0]) },
                    .padding = look.padding,
                    .child_gap = look.gap,
                },
            });
            return .{};
        }

        pub const DialogOptions = struct {
            title: []const u8,
            /// Below the title, wrapped to the panel; none when empty.
            description: []const u8 = "",
            /// Escape, a click on the scrim, a `dismiss` action and its close
            /// button close it; false for one the user must answer.
            dismissible: bool = true,
            /// Focused as it opens, such as its first field or its confirm
            /// button; when none, its close button. A dialog that is not
            /// dismissible names one, or nothing inside it is focused.
            initial_focus: zui.Id = .none,
        };

        /// What `dialog` opened: declare its content, its `actions`, then
        /// call `end`.
        pub const Dialog = struct {
            widgets: Self,

            /// Opens the row of its actions, at the panel's trailing edge:
            /// declare cancel and then confirm, and close the row with
            /// `ui.close()`.
            pub fn actions(opened: Dialog, ui: *Ui) void {
                const row = opened.widgets.style(ui, .dialog_actions, .idle);
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = row.gap, .child_alignment = .{ .x = .end, .y = .center } } });
            }

            pub fn end(_: Dialog, ui: *Ui) void {
                ui.close();
            }
        };

        const DialogState = struct { was_open: bool, opener: u64 };

        /// A panel at the window's center while `open` is true, over a scrim
        /// that takes the pointer from the page, at the `modal` elevation. It
        /// keeps Tab inside it, focuses `initial_focus` as it opens, and when
        /// it closes, by the application or as it is dismissed, gives focus
        /// back to what had it before. In a window narrower than 600 units
        /// it is a sheet along the window's bottom. Returns the dialog to
        /// declare content in while it is open, and in the frame it is
        /// dismissed, so it fades out from where it was.
        ///
        /// ```zig
        /// if (widgets.dialog(ui, .of("delete"), &app.confirming_delete, .{ .title = "Delete the project?", .description = "Its 12 boards go too.", .initial_focus = .of("delete.confirm") })) |confirm| {
        ///     confirm.actions(ui);
        ///     if (widgets.button(ui, .of("delete.cancel"), "Cancel", .{ .variant = .secondary })) app.confirming_delete = false;
        ///     if (widgets.button(ui, .of("delete.confirm"), "Delete", .{ .variant = .danger })) app.deleteProject();
        ///     ui.close();
        ///     confirm.end(ui);
        /// }
        /// ```
        pub fn dialog(self: Self, ui: *Ui, id: zui.Id, open: *bool, options: DialogOptions) ?Dialog {
            const state = ui.state(id, DialogState);
            const panel_id = id.child("panel");
            const scrim_id = id.child("scrim");
            const close_id = id.child("close");
            const dismissed = open.* and state.was_open and options.dismissible and
                (ui.clicked(scrim_id) or ui.clicked(close_id) or ui.dismissed(panel_id));
            if (dismissed) open.* = false;
            if (!open.*) {
                if (state.was_open) ui.requestFocus(.{ .hash = state.opener });
                state.was_open = false;
                if (!dismissed) return null;
            }
            const opening = open.* and !state.was_open;
            if (opening) {
                state.* = .{ .was_open = true, .opener = ui.focusedId().hash };
                ui.requestFocus(if (!options.initial_focus.isNone()) options.initial_focus else if (options.dismissible) close_id else .none);
            }

            const viewport = ui.viewport();
            const scrim = self.style(ui, .dialog_scrim, .idle);
            const look = self.style(ui, .dialog, .idle);
            const scrim_shown = entrance(ui, scrim_id.child("enter"), opening, scrim.motion);
            ui.box(.{
                .id = scrim_id,
                .interactive = !dismissed,
                .floating = .{ .attach_to = .root, .z = scrim.layer },
                .decoration = .{ .background = if (scrim.background) |color| (if (scrim_shown < 1) faded(color, scrim_shown) else color) else null },
                .exit = scrim.exit,
                .layout = .{ .sizing = .{ .width = .fixed(viewport[0]), .height = .fixed(viewport[1]) } },
            });
            const sheet = viewport[0] < bottom_sheet_below_width;
            const margin = look.padding.left;
            var decoration = decorationOf(look, false);
            if (sheet) decoration.corner_radius = .{ .top_left = look.corner_radius.top_left, .top_right = look.corner_radius.top_right };
            const point: zui.AnchorPoint = if (sheet) .bottom_center else .center;
            const entered = entrance(ui, panel_id.child("enter"), opening, look.motion);
            const rise: f32 = if (sheet) toast_enter_slide else enter_slide;
            const effects = overlayEffects(look, enteredScale(entered), .{ 0.5, if (sheet) 1 else 0.5 });
            ui.open(.{
                .id = panel_id,
                .focus_scope = true,
                .semantics = .{ .role = .dialog, .label = options.title, .actions = if (options.dismissible) .initOne(.dismiss) else .initEmpty() },
                .floating = .{ .attach_to = .root, .anchor = point, .attach_point = point, .offset = .{ 0, (1 - entered) * rise }, .z = look.layer },
                .decoration = decoration,
                .effects = effectsOrNull(&effects),
                .exit = look.exit,
                .layout = .{
                    .direction = .top_to_bottom,
                    .sizing = .{ .width = .fixed(if (sheet) viewport[0] else @min(look.size[0], @max(viewport[0] - 2 * margin, 0))) },
                    .padding = look.padding,
                    .child_gap = look.gap,
                },
            });
            const close = self.style(ui, .dialog_close, ui.widgetState(close_id));
            if (options.dismissible) self.dialogClose(ui, close_id, close, look.layer);
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .padding = .{ .right = if (options.dismissible) close.size[1] else 0 } } });
            ui.text(options.title, self.style(ui, .dialog_title, .idle).text);
            ui.close();
            if (options.description.len != 0) ui.text(options.description, self.style(ui, .dialog_description, .idle).text);
            return .{ .widgets = self };
        }

        fn dialogClose(self: Self, ui: *Ui, close_id: zui.Id, close: SkinStyle, layer: i16) void {
            const corner: zui.AnchorPoint = if (ui.environment().direction == .right_to_left) .top_left else .top_right;
            const inward: f32 = if (corner == .top_left) close.padding.left else -close.padding.right;
            ui.open(.{
                .id = close_id,
                .focusable = true,
                .cursor = .pointer,
                .semantics = .{ .role = .button, .label = "Close" },
                .floating = .{ .attach_to = .parent, .anchor = corner, .attach_point = corner, .offset = .{ inward, close.padding.top }, .z = layer },
                .decoration = decorationOf(close, ui.focused(close_id)),
                .layout = .{ .sizing = .{ .width = .fixed(close.size[1]), .height = .fixed(close.size[1]) }, .child_alignment = .{ .x = .center, .y = .center } },
            });
            self.icon(ui, .close, close);
            ui.close();
        }

        /// The toasts of `queue` at the window's bottom center, the newest
        /// in front and up to two older ones tucked behind it, each 4%
        /// smaller where the context draws transforms; the rest wait their
        /// turn. Each stays five seconds from when it shows, paused while
        /// the pointer is over one or focus is on an action, then leaves.
        /// Choosing its action, or Escape on it or a `dismiss` action, takes
        /// it away at once. Each is announced to an assistive technology as
        /// it shows. While one counts down, an idle application asks only
        /// for a frame at the instant it leaves. Returns the `tag` of the
        /// toast whose action was chosen this frame.
        ///
        /// ```zig
        /// if (widgets.toasts(ui, .of("notices"), &app.notices)) |booking_id| app.undoBooking(booking_id);
        /// ```
        pub fn toasts(self: Self, ui: *Ui, id: zui.Id, queue: *ToastQueue) ?u32 {
            var index: usize = 0;
            while (index < queue.len) {
                if (queue.entries[index].leaving) queue.remove(index) else index += 1;
            }
            var chosen: ?u32 = null;
            for (queue.entries[0..@min(queue.len, toasts_shown_most)]) |*entry| {
                const toast_id = id.indexedChild("toast", entry.key);
                const action_id = toast_id.child("action");
                const acted = entry.action_len != 0 and ui.clicked(action_id);
                if (acted) chosen = entry.tag;
                if (acted or ui.dismissed(toast_id) or (ui.focused(action_id) and ui.keyPressed(.escape))) leave(ui, entry);
            }

            const now = ui.now();
            var held = false;
            for (queue.entries[0..@min(queue.len, toasts_shown_most)]) |*entry| {
                const toast_id = id.indexedChild("toast", entry.key);
                if (ui.hovered(toast_id) or ui.focused(toast_id.child("action"))) held = true;
            }
            for (queue.entries[0..@min(queue.len, toasts_shown_most)]) |*entry| {
                if (!entry.shown or entry.leaving) continue;
                if (held) {
                    if (!entry.paused) entry.left = @max(entry.deadline.secondsSince(now), 0);
                    entry.paused = true;
                } else {
                    if (entry.paused) entry.deadline = now.addSeconds(entry.left);
                    entry.paused = false;
                    if (!now.isBefore(entry.deadline)) leave(ui, entry);
                }
            }

            const shown_count = @min(queue.len, toasts_shown_most);
            if (shown_count == 0) return chosen;
            const stack = self.style(ui, .toast_stack, .idle);
            for (queue.entries[0..shown_count], 0..) |*entry, position| {
                const opening = !entry.shown;
                if (opening) {
                    entry.shown = true;
                    entry.deadline = now.addSeconds(toast_seconds);
                }
                if (!entry.paused and !entry.leaving) ui.requestFrameAt(entry.deadline);
                const z = stack.layer + @as(i16, @intCast(position));
                self.declareToast(ui, id.indexedChild("toast", entry.key), entry, shown_count - 1 - position, stack, z, opening);
            }
            return chosen;
        }

        fn leave(ui: *Ui, entry: *ToastEntry) void {
            entry.leaving = true;
            ui.requestFrame();
        }

        fn declareToast(self: Self, ui: *Ui, toast_id: zui.Id, entry: *const ToastEntry, behind: usize, stack: SkinStyle, z: i16, opening: bool) void {
            const look = self.style(ui, .toast, .idle);
            const risen = entrance(ui, toast_id.child("enter"), opening, look.motion);
            const depth: f32 = @floatFromInt(behind);
            const scale = if (Ui.draws_transforms) std.math.pow(f32, look.scale, depth) else 1;
            const effects = overlayEffects(look, scale, .{ 0.5, 0 });
            const viewport = ui.viewport();
            ui.open(.{
                .id = toast_id,
                .interactive = true,
                .semantics = .{ .role = .status, .label = entry.message(), .actions = .initOne(.dismiss) },
                .floating = .{
                    .attach_to = .root,
                    .anchor = .bottom_center,
                    .attach_point = .bottom_center,
                    .offset = .{ 0, (1 - risen) * toast_enter_slide - stack.padding.bottom - depth * stack.gap },
                    .z = z,
                },
                .decoration = decorationOf(look, false),
                .effects = effectsOrNull(&effects),
                .exit = look.exit,
                .layout = .{
                    .sizing = .{ .width = .fitBetween(0, @min(look.size[0], @max(viewport[0] - 2 * viewport_margin, 0))) },
                    .padding = look.padding,
                    .child_gap = look.gap,
                    .child_alignment = .{ .y = .center },
                },
            });
            const tone_icon: zui.design.Icon, const tone_part: Part = switch (entry.tone) {
                .neutral => .{ .info, .toast_icon },
                .success => .{ .success, .toast_icon_success },
                .danger => .{ .danger, .toast_icon_danger },
            };
            self.icon(ui, tone_icon, self.style(ui, tone_part, .idle));
            ui.text(entry.message(), look.text);
            if (entry.action_len != 0) self.toastAction(ui, toast_id.child("action"), entry.action());
            ui.close();
        }

        fn toastAction(self: Self, ui: *Ui, action_id: zui.Id, content: []const u8) void {
            const state = ui.widgetState(action_id);
            const look = self.style(ui, .toast_action, state);
            const underline = self.style(ui, .toast_action_underline, state);
            ui.open(.{
                .id = action_id,
                .focusable = true,
                .cursor = .pointer,
                .semantics = .{ .role = .button, .label = content },
                .decoration = .{ .border = if (ui.focused(action_id)) look.focus_ring else null, .corner_radius = look.corner_radius, .corner_shape = look.corner_shape },
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .height = .fitBetween(look.size[1], std.math.inf(f32)) }, .child_alignment = .{ .y = .center } },
            });
            ui.text(content, singleLine(look.text));
            ui.box(.{ .decoration = .{ .background = underline.background }, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(underline.size[1]) } } });
            ui.close();
        }

        const Alignment = enum { start, center };
        const Side = enum { below, above, left, right };

        /// Where an overlay goes beside its anchor, the way it slides as it
        /// enters, and the point it grows from.
        const Beside = struct {
            floating: zui.Floating,
            /// Away from the anchor.
            away: [2]f32,
            origin: [2]f32,
        };

        /// `panel_id` on `placement`'s side of `anchor_id`, or on the
        /// opposite one where the window has room for it there and not on
        /// that side, moved along the other axis to stay inside the window.
        /// Its size is known from the previous frame, so in the frame it
        /// opens it takes the side with more room.
        fn placeBeside(ui: *const Ui, anchor_id: zui.Id, panel_id: zui.Id, placement: Placement, gap: f32, alignment: Alignment) Beside {
            const viewport = ui.viewport();
            const mirrored = ui.environment().direction == .right_to_left;
            const preferred: Side = switch (placement) {
                .below => .below,
                .above => .above,
                .leading => if (mirrored) .right else .left,
                .trailing => if (mirrored) .left else .right,
            };
            const panel = ui.rectOf(panel_id);
            const anchor = ui.rectOf(anchor_id);
            const side = if (anchor) |rect| sideWithRoom(rect, panel, viewport, preferred, gap) else preferred;
            const vertical = side == .below or side == .above;
            const at_end = vertical and mirrored and alignment == .start;
            const panel_point: zui.AnchorPoint, const anchor_point: zui.AnchorPoint = switch (side) {
                .below => if (alignment == .center) .{ .top_center, .bottom_center } else if (at_end) .{ .top_right, .bottom_right } else .{ .top_left, .bottom_left },
                .above => if (alignment == .center) .{ .bottom_center, .top_center } else if (at_end) .{ .bottom_right, .top_right } else .{ .bottom_left, .top_left },
                .right => if (alignment == .center) .{ .center_left, .center_right } else .{ .top_left, .top_right },
                .left => if (alignment == .center) .{ .center_right, .center_left } else .{ .top_right, .top_left },
            };
            var shift: f32 = 0;
            if (anchor) |rect| if (panel) |size| {
                const axis: usize = if (vertical) 0 else 1;
                const anchor_start = if (vertical) rect.x else rect.y;
                const anchor_length = if (vertical) rect.width else rect.height;
                const length = if (vertical) size.width else size.height;
                const start = switch (alignment) {
                    .center => anchor_start + (anchor_length - length) / 2,
                    .start => if (at_end) anchor_start + anchor_length - length else anchor_start,
                };
                const kept = @max(@min(start, viewport[axis] - viewport_margin - length), viewport_margin);
                shift = kept - start;
            };
            const along: f32 = switch (side) {
                .below, .right => gap,
                .above, .left => -gap,
            };
            const away: [2]f32 = switch (side) {
                .below => .{ 0, 1 },
                .above => .{ 0, -1 },
                .right => .{ 1, 0 },
                .left => .{ -1, 0 },
            };
            return .{
                .floating = .{
                    .attach_to = .{ .element = anchor_id },
                    .anchor = panel_point,
                    .attach_point = anchor_point,
                    .offset = if (vertical) .{ shift, along } else .{ along, shift },
                },
                .away = away,
                .origin = panel_point.fractions(),
            };
        }

        fn sideWithRoom(anchor: zui.Rect, panel: ?zui.Rect, viewport: [2]f32, preferred: Side, gap: f32) Side {
            const opposite: Side = switch (preferred) {
                .below => .above,
                .above => .below,
                .left => .right,
                .right => .left,
            };
            const preferred_room = roomOn(preferred, anchor, viewport, gap);
            const opposite_room = roomOn(opposite, anchor, viewport, gap);
            const roomier = if (opposite_room > preferred_room) opposite else preferred;
            const rect = panel orelse return roomier;
            const needed = if (preferred == .below or preferred == .above) rect.height else rect.width;
            if (preferred_room >= needed) return preferred;
            if (opposite_room >= needed) return opposite;
            return roomier;
        }

        fn roomOn(side: Side, anchor: zui.Rect, viewport: [2]f32, gap: f32) f32 {
            const room = switch (side) {
                .below => viewport[1] - (anchor.y + anchor.height),
                .above => anchor.y,
                .right => viewport[0] - (anchor.x + anchor.width),
                .left => anchor.x,
            };
            return room - gap - viewport_margin;
        }

        /// A context menu's corner at `point`, opening right and down unless
        /// the window has room only the other way.
        fn placeAtPoint(ui: *const Ui, panel_id: zui.Id, point: [2]f32) Beside {
            const viewport = ui.viewport();
            var flips: [2]bool = .{ point[0] > viewport[0] / 2, point[1] > viewport[1] / 2 };
            if (ui.rectOf(panel_id)) |rect| {
                const size: [2]f32 = .{ rect.width, rect.height };
                for (0..2) |axis| {
                    const after = viewport[axis] - viewport_margin - point[axis];
                    const before = point[axis] - viewport_margin;
                    flips[axis] = size[axis] > after and (size[axis] <= before or before > after);
                }
            }
            const corner: zui.AnchorPoint = if (flips[1])
                (if (flips[0]) .bottom_right else .bottom_left)
            else
                (if (flips[0]) .top_right else .top_left);
            return .{
                .floating = .{ .attach_to = .root, .anchor = corner, .attach_point = .top_left, .offset = point },
                .away = .{ 0, if (flips[1]) -1 else 1 },
                .origin = corner.fractions(),
            };
        }

        /// `beside`, still `enter_slide` short of it toward its anchor until
        /// it has `entered`.
        fn slid(beside: Beside, entered: f32, z: i16, capture: bool) zui.Floating {
            var floating = beside.floating;
            const short = (1 - entered) * enter_slide;
            floating.offset = .{ floating.offset[0] - beside.away[0] * short, floating.offset[1] - beside.away[1] * short };
            floating.z = z;
            floating.capture = capture;
            return floating;
        }

        /// How far an overlay has entered through `motion`: 0 in the frame it
        /// opens, then toward 1.
        fn entrance(ui: *Ui, id: zui.Id, opening: bool, motion: Motion) f32 {
            if (opening) _ = switch (motion) {
                .spring => animate(ui, id, f32, 0, motion),
                .none, .tween => animate(ui, id, f32, 0, .{ .tween = .{ .duration = 0 } }),
            };
            return animate(ui, id, f32, 1, motion);
        }

        fn enteredScale(entered: f32) f32 {
            return if (Ui.draws_transforms) enter_scale + (1 - enter_scale) * entered else 1;
        }

        fn overlayEffects(look: SkinStyle, scale: f32, origin: [2]f32) Ui.Effects {
            return .{ .shadow = look.shadow, .transform = if (scale != 1) .{ .scale = @splat(scale), .origin = origin } else null };
        }

        fn effectsOrNull(effects: *const Ui.Effects) ?*const Ui.Effects {
            return if (effects.shadow != null or effects.transform != null) effects else null;
        }

        fn animate(ui: *Ui, id: zui.Id, comptime T: type, target: T, motion: Motion) T {
            return switch (motion) {
                .none => target,
                .tween => |options| zui.motion.tween(ui, id, T, target, options),
                .spring => |options| zui.motion.spring(ui, id, T, target, options),
            };
        }

        /// A control disabled this frame is styled as disabled at once;
        /// `widgetState` learns of it a frame later.
        fn stateOf(ui: *const Ui, id: zui.Id, disabled: bool) zui.WidgetState {
            if (disabled) return .disabled;
            return ui.widgetState(id);
        }

        /// A button inside a control sits on the control's fill, which
        /// focus changes, so while the pointer is not on it, it takes the
        /// control's focus.
        fn nestedState(ui: *const Ui, id: zui.Id, outer: zui.WidgetState) zui.WidgetState {
            const own = ui.widgetState(id);
            return if (own == .idle and outer == .focused) outer else own;
        }

        /// A length one box is inset in another by, rounded to whole
        /// pixels, so the inset is as wide on every side wherever the
        /// boxes land.
        fn wholePixels(ui: *const Ui, units: f32) f32 {
            const pixels_per_unit = ui.pixelsPerUnit();
            return @round(units * pixels_per_unit) / pixels_per_unit;
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

/// Each component as review shows it: its `zuiPreviews`, the content it
/// is seen with, and `declare`, which declares it with one of them through
/// any `Widgets`. An overlay's preview declares it open.
///
/// ```zig
/// const Glance = zui_design.Permutations(zui_widgets.previews.Tabs, .glance);
/// const permutation = Glance.at(index);
/// zui_widgets.previews.Tabs.declare(widgets, ui, Glance.preview(permutation));
/// ```
pub const previews = struct {
    pub const Card = struct {
        pub const Content = struct { title: []const u8, body: []const u8, interactive: bool = false };

        pub const zuiPreviews = .{
            .short = Content{ .title = "Storage", .body = "12 GB of 50 GB used." },
            .long = Content{
                .title = "Every deployment this week, in every region",
                .body = "Each service rolled out without a failed health check, and two rolled themselves back when their error rate rose.",
            },
            .interactive = Content{ .title = "Release notes", .body = "Version 2.4 adds offline sync.", .interactive = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            _ = widgets.card(ui, .of("preview.card"), .{ .interactive = content.interactive, .label = content.title });
            widgets.cardTitle(ui, content.title);
            widgets.cardBody(ui, content.body);
            ui.close();
        }
    };

    pub const Divider = struct {
        pub const Content = struct { label: ?[]const u8 = null, axis: DividerAxis = .horizontal, inset: DividerInset = .none };

        pub const zuiPreviews = .{
            .plain = Content{},
            .labeled = Content{ .label = "or continue with" },
            .inset = Content{ .inset = .leading },
            .vertical = Content{ .axis = .vertical },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            ui.open(.{ .layout = .{
                .direction = if (content.axis == .horizontal) .top_to_bottom else .left_to_right,
                .sizing = .{ .width = .grow, .height = .fixed(preview_height) },
                .child_gap = 8,
                .child_alignment = .{ .x = .center, .y = .center },
            } });
            widgets.label(ui, "Above");
            widgets.divider(ui, .{ .axis = content.axis, .inset = content.inset, .label = content.label });
            widgets.label(ui, "Below");
            ui.close();
        }
    };

    pub const ScrollArea = struct {
        pub const Content = struct { rows: []const []const u8 };

        pub const zuiPreviews = .{
            .overflowing = Content{ .rows = &preview_rows },
            .fitting = Content{ .rows = preview_rows[0..2] },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            const area = widgets.scrollArea(ui, .of("preview.scroll_area"), .{ .height = .fixed(preview_height), .child_gap = 8, .label = "Messages" });
            for (content.rows) |row| widgets.label(ui, row);
            area.end(ui);
        }
    };

    pub const GroupBox = struct {
        pub const Content = struct { title: []const u8, description: []const u8 = "" };

        pub const zuiPreviews = .{
            .plain = Content{ .title = "Account" },
            .described = Content{ .title = "Notifications", .description = "Sent to the address on your account, at most once a day." },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            const group = widgets.groupBox(ui, .of("preview.group_box"), content.title, .{ .description = content.description });
            widgets.label(ui, "Display name");
            widgets.divider(ui, .{});
            widgets.label(ui, "Email");
            group.end(ui);
        }
    };

    pub const Tabs = struct {
        pub const Section = enum { overview, activity, settings };
        pub const Content = struct { style: TabsStyle, selected: Section };

        pub const zuiPreviews = .{
            .underline = Content{ .style = .underline, .selected = .overview },
            .pill = Content{ .style = .pill, .selected = .activity },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var selected = content.selected;
            _ = widgets.tabs(ui, .of("preview.tabs"), &selected, .{ .style = content.style, .label = "Sections" });
        }
    };

    pub const NavigationList = struct {
        pub const Content = struct { items: []const NavigationItem, selected: usize };

        pub const zuiPreviews = .{
            .sections = Content{ .items = &.{
                .{ .label = "Mail", .heading = true },
                .{ .label = "Inbox", .count = "12" },
                .{ .label = "Drafts", .count = "2" },
                .{ .label = "Sent" },
                .{ .label = "Labels", .heading = true },
                .{ .label = "Receipts" },
            }, .selected = 1 },
            .flat = Content{ .items = &.{ .{ .label = "General" }, .{ .label = "Appearance" }, .{ .label = "Privacy and security" } }, .selected = 2 },
            .shortcuts = Content{ .items = &.{
                .{ .label = "Inbox", .count = "12", .shortcut = "Ctrl+1" },
                .{ .label = "Drafts", .shortcut = "Ctrl+2" },
                .{ .label = "Sent", .shortcut = "Ctrl+3" },
            }, .selected = 0 },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var selected = content.selected;
            _ = widgets.navigationList(ui, .of("preview.navigation_list"), content.items, &selected, .{ .label = "Places" });
        }
    };

    pub const Breadcrumbs = struct {
        pub const Content = struct { crumbs: []const []const u8 };

        pub const zuiPreviews = .{
            .short = Content{ .crumbs = &.{ "Home", "Projects", "Harbor" } },
            .collapsed = Content{ .crumbs = &.{ "Home", "Projects", "Harbor", "Services", "Orders", "Settings" } },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            _ = widgets.breadcrumbs(ui, .of("preview.breadcrumbs"), content.crumbs, .{ .label = "Location" });
        }
    };

    pub const Label = struct {
        pub const Content = struct { text: []const u8, role: zui.design.TypeRole = .body, tone: LabelTone = .default };

        pub const zuiPreviews = .{
            .body = Content{ .text = "Your changes are saved." },
            .title = Content{ .text = "Storage", .role = .title },
            .muted_caption = Content{ .text = "Updated 2 minutes ago", .role = .caption, .tone = .muted },
            .accent = Content{ .text = "3 new", .role = .label_strong, .tone = .accent },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            widgets.labelWith(ui, content.text, .{ .role = content.role, .tone = content.tone });
        }
    };

    pub const LabeledRow = struct {
        pub const Content = struct { label: []const u8, description: []const u8 = "" };

        pub const zuiPreviews = .{
            .plain = Content{ .label = "Volume" },
            .described = Content{ .label = "Wi-Fi only", .description = "Waits for Wi-Fi before uploading photos." },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            const group = widgets.groupBox(ui, .of("preview.labeled_row"), "Sync", .{});
            widgets.labeledRowWith(ui, content.label, .{ .description = content.description });
            var on = true;
            _ = widgets.toggle(ui, .of("preview.labeled_row.first"), "", &on, .{ .label = content.label });
            ui.close();
            widgets.labeledRowWith(ui, "Photos", .{ .divider_above = true });
            _ = widgets.toggle(ui, .of("preview.labeled_row.second"), "", &on, .{ .label = "Photos" });
            ui.close();
            group.end(ui);
        }
    };

    pub const Disclosure = struct {
        pub const Content = struct { title: []const u8, expanded: bool };

        pub const zuiPreviews = .{
            .collapsed = Content{ .title = "Advanced", .expanded = false },
            .expanded = Content{ .title = "Advanced", .expanded = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var expanded = content.expanded;
            _ = widgets.disclosure(ui, .of("preview.disclosure"), content.title, &expanded);
            if (expanded) widgets.label(ui, "Proxy and certificates");
        }
    };

    pub const Button = struct {
        pub const Content = struct {
            label: []const u8,
            variant: ButtonVariant = .primary,
            size: zui.design.ControlSize = .medium,
            leading_icon: ?zui.design.Icon = null,
            disabled: bool = false,
        };

        pub const zuiPreviews = .{
            .primary = Content{ .label = "Save" },
            .secondary = Content{ .label = "Cancel", .variant = .secondary },
            .tonal = Content{ .label = "Share", .variant = .tonal },
            .tertiary = Content{ .label = "Learn more", .variant = .tertiary },
            .danger = Content{ .label = "Delete project", .variant = .danger },
            .small_with_icon = Content{ .label = "Export", .variant = .secondary, .size = .small, .leading_icon = .arrow_down },
            .large = Content{ .label = "Continue to payment", .size = .large },
            .disabled = Content{ .label = "Save", .disabled = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            _ = widgets.button(ui, .of("preview.button"), content.label, .{ .variant = content.variant, .size = content.size, .leading_icon = content.leading_icon, .disabled = content.disabled });
        }
    };

    pub const Checkbox = struct {
        pub const Content = struct { label: []const u8, checked: bool };

        pub const zuiPreviews = .{
            .unchecked = Content{ .label = "Send me a weekly summary", .checked = false },
            .checked = Content{ .label = "Remember this device", .checked = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var checked = content.checked;
            _ = widgets.checkbox(ui, .of("preview.checkbox"), content.label, &checked, .{});
        }
    };

    pub const Slider = struct {
        pub const Content = struct { value: f32, step: ?f64 = null, ticks: bool = false };

        pub const zuiPreviews = .{
            .continuous = Content{ .value = 0.4 },
            .ticked = Content{ .value = 0.5, .step = 0.125, .ticks = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var value = content.value;
            _ = widgets.slider(ui, .of("preview.slider"), &value, .{ .step = content.step, .ticks = content.ticks, .label = "Volume" });
        }
    };

    pub const TextField = struct {
        pub const Content = struct {
            text: []const u8 = "",
            placeholder: []const u8 = "",
            label: []const u8,
            help: []const u8 = "",
            error_message: []const u8 = "",
            trailing: []const u8 = "",
        };

        pub const zuiPreviews = .{
            .empty = Content{ .placeholder = "ada@example.com", .label = "Email" },
            .labeled = Content{ .text = "Ada Lovelace", .label = "Name", .help = "As it appears on your card." },
            .errored = Content{ .text = "ada@", .label = "Email", .error_message = "Enter an address like ada@example.com." },
            .unit = Content{ .text = "72", .label = "Weight", .trailing = "kg" },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var bytes: [64]u8 = undefined;
            var text: EditableText = .init(&bytes, content.text);
            _ = widgets.textField(ui, .of("preview.text_field"), &text, .{
                .placeholder = content.placeholder,
                .label = content.label,
                .show_label = true,
                .help = content.help,
                .error_message = content.error_message,
                .trailing = content.trailing,
            });
        }
    };

    pub const Dropdown = struct {
        pub const Content = struct { options: []const []const u8, selected: usize };

        pub const zuiPreviews = .{
            .short = Content{ .options = &.{ "Low", "Medium", "High" }, .selected = 1 },
            .long = Content{ .options = &.{ "Every hour", "Every day at 9:00", "Every Monday morning" }, .selected = 2 },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var selected = content.selected;
            _ = widgets.dropdown(ui, .of("preview.dropdown"), &selected, content.options, .{ .label = "Frequency" });
        }
    };

    pub const RadioGroup = struct {
        pub const Room = enum { single, double, family_suite };
        pub const Content = struct { selected: Room, direction: zui.Direction = .top_to_bottom };

        pub const zuiPreviews = .{
            .stacked = Content{ .selected = .double },
            .row = Content{ .selected = .single, .direction = .left_to_right },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var selected = content.selected;
            _ = widgets.radioGroup(ui, .of("preview.radio_group"), &selected, .{ .label = "Room", .direction = content.direction });
        }
    };

    pub const Segmented = struct {
        pub const View = enum { list, grid, map };
        pub const Content = struct { selected: View };

        pub const zuiPreviews = .{
            .first = Content{ .selected = .list },
            .middle = Content{ .selected = .grid },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var selected = content.selected;
            _ = widgets.segmented(ui, .of("preview.segmented"), &selected, .{ .label = "View" });
        }
    };

    pub const NumberStepper = struct {
        pub const Content = struct { value: i32, unit: []const u8 = "" };

        pub const zuiPreviews = .{
            .nights = Content{ .value = 3, .unit = "nights" },
            .at_limit = Content{ .value = 1 },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var value = content.value;
            _ = widgets.numberStepper(ui, .of("preview.number_stepper"), &value, .{ .min = 1, .max = 30, .unit = content.unit, .label = "Nights" });
        }
    };

    pub const SearchField = struct {
        pub const Content = struct { query: []const u8 = "", shortcut: []const u8 = "Ctrl K" };

        pub const zuiPreviews = .{
            .empty = Content{},
            .typed = Content{ .query = "lisbon" },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var bytes: [64]u8 = undefined;
            var query: EditableText = .init(&bytes, content.query);
            _ = widgets.searchField(ui, .of("preview.search_field"), &query, .{ .shortcut = content.shortcut, .label = "Search stays" });
        }
    };

    pub const IconButton = struct {
        pub const Content = struct { icon: zui.design.Icon, label: []const u8, variant: IconButtonVariant = .tertiary, size: zui.design.ControlSize = .medium };

        pub const zuiPreviews = .{
            .tertiary = Content{ .icon = .close, .label = "Close" },
            .filled = Content{ .icon = .check, .label = "Done", .variant = .filled },
            .tonal_small = Content{ .icon = .info, .label = "About", .variant = .tonal, .size = .small },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            _ = widgets.iconButton(ui, .of("preview.icon_button"), content.icon, .{ .label = content.label, .variant = content.variant, .size = content.size });
        }
    };

    pub const Link = struct {
        pub const Content = struct { text: []const u8, url: []const u8 };

        pub const zuiPreviews = .{
            .short = Content{ .text = "Help", .url = "https://example.com/help" },
            .long = Content{ .text = "Read the cancellation policy", .url = "https://example.com/cancellation" },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            _ = widgets.link(ui, .of("preview.link"), content.text, content.url);
        }
    };

    pub const Chip = struct {
        pub const Content = struct { label: []const u8, selected: ?bool = null, closable: bool = false };

        pub const zuiPreviews = .{
            .filter = Content{ .label = "Sea view", .selected = false },
            .selected = Content{ .label = "Breakfast", .selected = true },
            .tag = Content{ .label = "Lisbon", .closable = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var selected = content.selected orelse false;
            _ = widgets.chip(ui, .of("preview.chip"), content.label, .{ .selected = if (content.selected != null) &selected else null, .closable = content.closable });
        }
    };

    pub const Toggle = struct {
        pub const Content = struct { label: []const u8, on: bool };

        pub const zuiPreviews = .{
            .off = Content{ .label = "Pets allowed", .on = false },
            .on = Content{ .label = "Free cancellation", .on = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var on = content.on;
            _ = widgets.toggle(ui, .of("preview.toggle"), content.label, &on, .{});
        }
    };

    /// Shown once its anchor has focus, as after Tab.
    pub const Tooltip = struct {
        pub const Content = struct { text: []const u8, shortcut: []const u8 = "" };

        pub const zuiPreviews = .{
            .short = Content{ .text = "Copy a link" },
            .shortcut = Content{ .text = "Copy a link to this page", .shortcut = "Ctrl+Shift+S" },
            .long = Content{ .text = "Shares the board with everyone in the workspace, who can comment but not edit it." },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            const anchor: zui.Id = .of("preview.tooltip.anchor");
            _ = widgets.button(ui, anchor, "Share", .{ .variant = .secondary });
            widgets.tooltip(ui, anchor, content.text, .{ .shortcut = content.shortcut });
        }
    };

    pub const Menu = struct {
        pub const Content = struct { section: []const u8 = "", checkable: bool = false, shortcuts: bool = true, danger: bool = true, icons: bool = false };

        pub const zuiPreviews = .{
            .actions = Content{},
            .checkable = Content{ .section = "Show", .checkable = true, .shortcuts = false, .danger = false },
            .icons = Content{ .icons = true, .danger = false },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            const anchor: zui.Id = .of("preview.menu.anchor");
            _ = widgets.button(ui, anchor, "Actions", .{ .variant = .secondary });
            var open = true;
            const shown = widgets.menu(ui, .of("preview.menu"), anchor, &open, .{ .label = "Actions" }) orelse return;
            if (content.section.len != 0) shown.section(ui, content.section);
            _ = shown.item(ui, "Copy link", .{ .shortcut = if (content.shortcuts) "Ctrl+C" else "", .checked = if (content.checkable) true else null, .icon = if (content.icons) .arrow_up else null });
            _ = shown.item(ui, "Duplicate", .{ .shortcut = if (content.shortcuts) "Ctrl+D" else "", .checked = if (content.checkable) false else null, .icon = if (content.icons) .arrow_down else null });
            _ = shown.item(ui, "Archive", .{ .disabled = true });
            if (content.danger) {
                shown.separator(ui);
                _ = shown.item(ui, "Delete", .{ .danger = true });
            }
            shown.end(ui);
        }
    };

    pub const Popover = struct {
        pub const Content = struct { title: []const u8, body: []const u8, placement: Placement = .below };

        pub const zuiPreviews = .{
            .below = Content{ .title = "Filters", .body = "Show only the stays you can cancel for free." },
            .beside = Content{ .title = "About this cabin", .body = "Sleeps four, with a wood stove and a view of the bay.", .placement = .trailing },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            const anchor: zui.Id = .of("preview.popover.anchor");
            _ = widgets.button(ui, anchor, content.title, .{ .variant = .secondary });
            var open = true;
            const shown = widgets.popover(ui, .of("preview.popover"), anchor, &open, .{ .placement = content.placement, .label = content.title }) orelse return;
            widgets.labelWith(ui, content.title, .{ .role = .title });
            widgets.labelWith(ui, content.body, .{ .wrap = .words });
            _ = widgets.button(ui, .of("preview.popover.apply"), "Apply", .{ .size = .small });
            shown.end(ui);
        }
    };

    pub const Dialog = struct {
        pub const Content = struct { title: []const u8, description: []const u8, confirm: []const u8, danger: bool = false };

        pub const zuiPreviews = .{
            .confirm = Content{ .title = "Book this cabin?", .description = "Three nights from Friday, for two guests.", .confirm = "Book" },
            .destructive = Content{ .title = "Delete the project?", .description = "Its 12 boards and their history go too. This cannot be undone.", .confirm = "Delete", .danger = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var open = true;
            const shown = widgets.dialog(ui, .of("preview.dialog"), &open, .{ .title = content.title, .description = content.description, .initial_focus = .of("preview.dialog.confirm") }) orelse return;
            shown.actions(ui);
            _ = widgets.button(ui, .of("preview.dialog.cancel"), "Cancel", .{ .variant = .secondary });
            _ = widgets.button(ui, .of("preview.dialog.confirm"), content.confirm, .{ .variant = if (content.danger) .danger else .primary });
            ui.close();
            shown.end(ui);
        }
    };

    pub const Toasts = struct {
        pub const Content = struct { message: []const u8, action: []const u8 = "", tone: ToastTone = .neutral, stacked: bool = false };

        pub const zuiPreviews = .{
            .neutral = Content{ .message = "Link copied" },
            .undo = Content{ .message = "Booking confirmed for three nights", .action = "Undo", .tone = .success },
            .failed = Content{ .message = "Could not reach the server", .action = "Retry", .tone = .danger },
            .stacked = Content{ .message = "Two cabins saved", .action = "View", .stacked = true },
        };

        pub fn declare(widgets: anytype, ui: anytype, content: Content) void {
            var storage: [toasts_shown_most]ToastEntry = undefined;
            var queue: ToastQueue = .init(&storage);
            if (content.stacked) {
                _ = queue.push(.{ .message = "Lisbon cabin saved" });
                _ = queue.push(.{ .message = "Porto loft saved" });
            }
            _ = queue.push(.{ .message = content.message, .action = content.action, .tone = content.tone });
            _ = widgets.toasts(ui, .of("preview.toasts"), &queue);
        }
    };

    /// The containers and navigation, for a review or an audit to step
    /// through.
    pub const containers = .{ Card, Divider, ScrollArea, GroupBox, Tabs, NavigationList, Breadcrumbs };
    /// The essential inputs and the text they sit beside.
    pub const inputs = .{ Label, LabeledRow, Disclosure, Button, Checkbox, Slider, TextField, Dropdown, RadioGroup, Segmented, NumberStepper, SearchField, IconButton, Link, Chip, Toggle };
    /// What floats over the page.
    pub const overlays = .{ Tooltip, Menu, Popover, Dialog, Toasts };
    /// Every component above.
    pub const all = containers ++ inputs ++ overlays;

    const preview_height = 160;
    const preview_rows = [_][]const u8{
        "Invoice 2041 was paid",
        "Ada commented on the release plan",
        "The nightly build passed",
        "Grace joined the design team",
        "Storage is 80% full",
        "Backup finished in 4 minutes",
        "Two new sign-ins from Lisbon",
        "The quarterly report is ready",
        "A reviewer approved your change",
        "Your trial ends in 9 days",
    };
};

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

fn EnumPointee(comptime Pointer: type, comptime widget: []const u8) type {
    const info = @typeInfo(Pointer);
    if (info == .pointer and info.pointer.size == .one and !info.pointer.is_const and @typeInfo(info.pointer.child) == .@"enum") {
        if (@typeInfo(info.pointer.child).@"enum".fields.len == 0) @compileError("zui_widgets: " ++ widget ++ " needs an enum with at least one named tag, got " ++ @typeName(info.pointer.child));
        return info.pointer.child;
    }
    @compileError("zui_widgets: " ++ widget ++ " needs a pointer to an enum, got " ++ @typeName(Pointer));
}

fn tagLabels(comptime Enum: type) [@typeInfo(Enum).@"enum".fields.len][]const u8 {
    const tags = @typeInfo(Enum).@"enum".fields;
    var labels: [tags.len][]const u8 = undefined;
    for (tags, &labels) |tag, *label| label.* = labelFromIdentifier(tag.name);
    return labels;
}

fn numberToFloat(number: anytype) f64 {
    return switch (@typeInfo(@TypeOf(number))) {
        .int => @floatFromInt(number),
        .float => @floatCast(number),
        else => comptime unreachable,
    };
}

/// Whole numbers without a fraction, the rest to two places.
fn formatNumber(buffer: []u8, number: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(number))) {
        .int => std.fmt.bufPrint(buffer, "{d}", .{number}) catch "",
        .float => if (@round(number) == number)
            std.fmt.bufPrint(buffer, "{d}", .{number}) catch ""
        else
            std.fmt.bufPrint(buffer, "{d:.2}", .{number}) catch "",
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
    _ = @import("containers_tests.zig");
    _ = @import("inputs_tests.zig");
    _ = @import("overlays_tests.zig");
}

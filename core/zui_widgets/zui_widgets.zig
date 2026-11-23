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
    /// A row of `navigationList`: `background`, `border`, `focus_ring`,
    /// `corner_radius`, `size[1]`, `padding`, `gap` and `text`.
    navigation_item,
    /// The selected row, read as `navigation_item`.
    navigation_item_selected,
    /// A section's heading: `text`, `padding`, and `gap` above it.
    navigation_heading,
    /// A row's count at its end: `text`.
    navigation_count,
    /// The selected row's count: `text`.
    navigation_count_selected,
    /// A crumb of `breadcrumbs` that leads back: `background`, `border`,
    /// `focus_ring`, `corner_radius`, `size[1]`, `padding` and `text`.
    crumb,
    /// The page the trail ends at, read as `crumb`.
    crumb_current,
    /// Between two crumbs: `glyph`, `text`, and `gap` either side.
    crumb_separator,
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
                    const groove_corner = tokens.corner_radii.get(.control);
                    const groove_padding = tokens.space(.hair);
                    thumb.corner_radius = .{
                        .top_left = @max(groove_corner.top_left - groove_padding, 0),
                        .top_right = @max(groove_corner.top_right - groove_padding, 0),
                        .bottom_left = @max(groove_corner.bottom_left - groove_padding, 0),
                        .bottom_right = @max(groove_corner.bottom_right - groove_padding, 0),
                    };
                    thumb.motion = .{ .spring = tokens.motion.toggle };
                    break :thumb thumb;
                },
                .navigation_item => sized(skin.styled(.navigation_item, state), .{ 0, medium_height }),
                .navigation_item_selected => sized(skin.styled(.navigation_item_selected, state), .{ 0, medium_height }),
                .navigation_heading => skin.styled(.navigation_heading, state),
                .navigation_count => skin.styled(.navigation_count, state),
                .navigation_count_selected => skin.styled(.navigation_count_selected, state),
                .crumb => sized(skin.styled(.crumb, state), .{ 0, tokens.control_heights.get(.small) }),
                .crumb_current => sized(skin.styled(.crumb_current, state), .{ 0, tokens.control_heights.get(.small) }),
                .crumb_separator => withGlyph(skin.styled(.crumb_separator, state), "›"),
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
/// Popups paint in this layer and the next one up.
const popup_layer = 100;
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
        navigation_item,
        navigation_item_selected,
        navigation_heading,
        navigation_count,
        navigation_count_selected,
        crumb,
        crumb_current,
        crumb_separator,
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
    });

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
    /// A heading, which is never selected.
    heading: bool = false,
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
            const inset = thumb.padding.top;
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
            const thickness = animate(ui, thumb_id.child("thickness"), f32, thumb.size[0], thumb.motion);
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
            const bar_rect = ui.rectOf(bar_id) orelse return ui.requestFrame();
            const tab_rect = ui.rectOf(tab_id) orelse return ui.requestFrame();
            const look = self.style(ui, if (pill) .tab_pill_thumb else .tab_indicator, .idle);
            const label_inset = if (pill) 0 else self.style(ui, .tab, .idle).padding.left;
            const from_start = if (ui.environment().direction == .right_to_left)
                (bar_rect.x + bar_rect.width) - (tab_rect.x + tab_rect.width)
            else
                tab_rect.x - bar_rect.x;
            const placed = animate(ui, bar_id.child("indicator"), [2]f32, .{ from_start + label_inset, @max(tab_rect.width - 2 * label_inset, 0) }, look.motion);
            const point: zui.AnchorPoint = if (pill) .center_left else .bottom_left;
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
        /// order. Returns whether the selection changed.
        ///
        /// ```zig
        /// const places = [_]zui_widgets.NavigationItem{
        ///     .{ .label = "Mail", .heading = true },
        ///     .{ .label = "Inbox", .count = "12" },
        ///     .{ .label = "Sent" },
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
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = options.width } },
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
                if (item.count.len != 0) {
                    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
                    ui.text(item.count, singleLine(self.style(ui, if (is_selected) .navigation_count_selected else .navigation_count, state).text));
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

        const Trail = struct { expanded: bool };

        /// The way back from the current page, `crumbs` from the top: each
        /// crumb but the last is a link, focusable and activated with Enter
        /// or Space. Past four crumbs the middle ones collapse into a "…"
        /// crumb, which shows them when chosen. Returns the index of the
        /// crumb chosen this frame.
        ///
        /// ```zig
        /// if (widgets.breadcrumbs(ui, .of("path"), app.path(), .{ .label = "Location" })) |depth| app.goUp(depth);
        /// ```
        pub fn breadcrumbs(self: Self, ui: *Ui, id: zui.Id, crumbs: []const []const u8, options: BreadcrumbsOptions) ?usize {
            if (crumbs.len == 0) return null;
            const last = crumbs.len - 1;
            const trail = ui.state(id, Trail);
            const more_id = id.child("more");
            if (crumbs.len > most_crumbs_shown and !trail.expanded and ui.clicked(more_id)) {
                trail.expanded = true;
                ui.requestFocus(id.indexedChild("crumb", 1));
            }
            const collapsed = crumbs.len > most_crumbs_shown and !trail.expanded;
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
                if (collapsed and index > 0 and index < last - 1) {
                    if (index == 1) {
                        self.crumbLink(ui, more_id, collapsed_crumbs_glyph, "Show the hidden levels");
                        ui.text(separator.glyph, singleLine(separator.text));
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
                    ui.text(separator.glyph, singleLine(separator.text));
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

/// The containers and navigation as review shows them: each component's
/// `zuiPreviews`, the content it is seen with, and `declare`, which
/// declares it with one of them through any `Widgets`.
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

    /// Every component above, for a review or an audit to step through.
    pub const all = .{ Card, Divider, ScrollArea, GroupBox, Tabs, NavigationList, Breadcrumbs };

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
}

const zui = @import("zui");

/// GNOME's design language as libadwaita draws it, for an application
/// that looks at home on GNOME. The system's accent, which GNOME's accent
/// setting gives the Linux host, replaces the accent seed at run time.
///
/// - **Accent:** #3584E4, libadwaita's `--accent-blue` and the default
///   `--accent-bg-color` (its `_colors.scss`, `_palette.scss`), in OKLCH.
/// - **Neutral:** `--window-bg-color`, #FAFAFB light and #222226 dark: a
///   cool grey of hue 286, its chroma taken from the dark one.
/// - **Status hues:** `--destructive-bg-color` and `--error-bg-color`
///   #E01B24 (`red_3`), `--warning-bg-color` #E5A50A (`yellow_5`) and
///   `--success-bg-color` #2EC27E (`green_4`).
/// - **Type:** GNOME's interface font, Adwaita Sans 11 pt, 14.67 px
///   (`font-name` in `org.gnome.desktop.interface`). libadwaita's
///   `_labels.scss` sets `.title-4` at 118%, `.title-2` at 136% and
///   `.title-1` at 181%, and a ratio of 1.18 puts `title`, `headline` and
///   `display` at 118%, 139% and 194%. The x-height is Adwaita Sans' at
///   that size: 1118 of 1984 + 494 units of ascent and descent.
/// - **Shapes:** `_common.scss`: `$button_radius` and `$menu_radius` 9 px
///   (`smooth`, 8), `$card_radius` 12 px and `$popover_radius` and
///   `$dialog_radius` 15 px (`soft`, 16, so a card stays rounder than its
///   buttons, as libadwaita's are), and `.pill` chips.
/// - **Density:** the 6 px margins and spacing of libadwaita's toolbars
///   and menus (`$menu_margin`), 12 px of padding (`$menu_padding`), on a
///   grid of 6 for the comfortable column; compact and roomy are it at 2/3
///   and 4/3, as the default's are of its own.
/// - **Motion:** `$button_transition` and `$focus_transition`, 200 ms
///   eased out, for a hover, a focus or a press. No control scales when
///   pressed. The rest is the default's.
///
/// ```zig
/// var app_design = zui_themes.libadwaita;
/// app_design.type.fonts = .{
///     .regular = @intFromEnum(FontId.atkinson_regular),
///     .strong = @intFromEnum(FontId.atkinson_bold),
///     .monospace = @intFromEnum(FontId.liberation_mono),
/// };
/// app_design.type.faces.regular = .of(text.fontMetrics(fonts.atkinson_regular).?);
/// ```
pub const libadwaita: zui.design.Design = .{
    .name = "zui_themes.libadwaita",
    .seeds = .{
        .accent = .{ .lightness = 0.6137, .chroma = 0.1643, .hue = 255.34 },
        .neutral = .{ .lightness = 0.2536, .chroma = 0.0075, .hue = 285.86 },
        .danger_hue = 26.62,
        .warning_hue = 80.30,
        .success_hue = 157.74,
    },
    .type = .{ .ratio = 1.18, .body_size = 14.67, .x_height = 6.62 },
    .shapes = .init(.{ .control = .smooth, .container = .soft, .popup = .soft, .chip = .bubble, .image = .smooth, .indicator = .bubble }),
    .corner_shape = .round,
    .density = .init(.{
        .compact = .init(.{ .none = 0, .hair = 1, .xs = 2, .s = 4, .m = 8, .l = 12, .xl = 16, .xxl = 24 }),
        .comfortable = .init(.{ .none = 0, .hair = 1, .xs = 3, .s = 6, .m = 12, .l = 18, .xl = 24, .xxl = 36 }),
        .roomy = .init(.{ .none = 0, .hair = 2, .xs = 4, .s = 8, .m = 16, .l = 24, .xl = 32, .xxl = 48 }),
    }),
    .motion = .{
        .state = .{ .duration = 0.2, .easing = .ease_out },
        .press = .{ .duration = 0.2, .easing = .ease_out },
        .toggle = .{ .angular_frequency = 28 },
        .check = .{ .duration = 0.16, .easing = .ease_out },
        .popover_enter = .{ .duration = 0.16, .easing = .ease_out },
        .popover_exit = .{ .duration = 0.1, .easing = .ease_in },
        .dialog_enter = .{ .duration = 0.22, .easing = .ease_out },
        .dialog_exit = .{ .duration = 0.14, .easing = .ease_in },
        .toast_enter = .{ .angular_frequency = 22 },
        .toast_exit = .{ .duration = 0.16, .easing = .ease_in },
        .drawer = .{ .angular_frequency = 20 },
        .reorder = .{ .angular_frequency = 30 },
        .disclosure = .{ .duration = 0.2, .easing = .ease_in_out },
        .press_scale = 1,
    },
};

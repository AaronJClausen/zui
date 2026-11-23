const zui = @import("zui");

/// Windows 11's design language, Fluent 2 as WinUI 3 draws it, for an
/// application that looks at home on Windows. The system's accent, which
/// the Windows host reports, replaces the accent seed at run time.
///
/// - **Accent:** #0078D4, Windows' default `SystemAccentColor`, in OKLCH.
/// - **Neutral:** WinUI's base layer, #F3F3F3 light and #202020 dark, a
///   grey with no chroma.
/// - **Status hues:** WinUI's light `SystemFillColorCritical` #C42B1C,
///   `SystemFillColorCaution` #9D5D00 and `SystemFillColorSuccess` #0F7B0F,
///   whose hue of 143 is moved to 148: at the default's tones it would be
///   too near danger in lightness under tritanopia.
/// - **Type:** the Windows type ramp (learn.microsoft.com, "Typography in
///   Windows"): Body 14, Subtitle 20, Title 28. A ratio of 1.2 from 14 puts
///   `headline` at Subtitle and `display` at Title. The x-height is Segoe
///   UI's at 14: half its 2048-unit em over its 2210 + 514 units of
///   ascent and descent.
/// - **Shapes:** "Geometry in Windows 11": 4 px for in-page controls,
///   cards, chips and list backplates (`sharp`), 8 px for flyouts, menus
///   and dialogs (`smooth`), and bars and lines as pills.
/// - **Density:** "Content layout and spacing": 8 between buttons, 12
///   between content areas and 16 from a surface's edge to its text, which
///   is the default's comfortable column, so the density is the default's.
/// - **Motion:** "Timing and easing": `ControlFasterAnimationDuration`
///   83 ms for a hover or a press, `ControlFastAnimationDuration` 167 ms for
///   a check and an exit, `ControlNormalAnimationDuration` 250 ms for an
///   entrance, entering fast out and slow in and leaving slow out and fast
///   in. No control scales when pressed. The springs are the default's.
///
/// ```zig
/// var app_design = zui_themes.fluent;
/// app_design.type.fonts = .{
///     .regular = @intFromEnum(FontId.atkinson_regular),
///     .strong = @intFromEnum(FontId.atkinson_bold),
///     .monospace = @intFromEnum(FontId.liberation_mono),
/// };
/// app_design.type.faces.regular = .of(text.fontMetrics(fonts.atkinson_regular).?);
/// ```
pub const fluent: zui.design.Design = .{
    .name = "zui_themes.fluent",
    .seeds = .{
        .accent = .{ .lightness = 0.5677, .chroma = 0.1665, .hue = 251.31 },
        .neutral = .{ .lightness = 0.9642, .chroma = 0, .hue = 251.31 },
        .danger_hue = 30.07,
        .warning_hue = 65.22,
        .success_hue = 148,
    },
    .type = .{ .ratio = 1.2, .body_size = 14, .x_height = 5.26 },
    .shapes = .init(.{ .control = .sharp, .container = .sharp, .popup = .smooth, .chip = .sharp, .image = .sharp, .indicator = .bubble }),
    .corner_shape = .round,
    .motion = .{
        .state = .{ .duration = 0.083, .easing = .ease_out },
        .press = .{ .duration = 0.083, .easing = .ease_out },
        .toggle = .{ .angular_frequency = 28 },
        .check = .{ .duration = 0.167, .easing = .ease_out },
        .popover_enter = .{ .duration = 0.25, .easing = .ease_out },
        .popover_exit = .{ .duration = 0.167, .easing = .ease_in },
        .dialog_enter = .{ .duration = 0.25, .easing = .ease_out },
        .dialog_exit = .{ .duration = 0.167, .easing = .ease_in },
        .toast_enter = .{ .angular_frequency = 22 },
        .toast_exit = .{ .duration = 0.167, .easing = .ease_in },
        .drawer = .{ .angular_frequency = 20 },
        .reorder = .{ .angular_frequency = 30 },
        .disclosure = .{ .duration = 0.25, .easing = .ease_out },
        .press_scale = 1,
    },
};

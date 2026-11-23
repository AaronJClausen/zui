const zui = @import("zui");

/// KDE Plasma's design language, Breeze, for an application that looks at
/// home on KDE. The system's accent replaces the accent seed at run time.
///
/// - **Accent:** #3DAEE9, `DecorationFocus` and the selection's
///   `BackgroundNormal` in Breeze's `BreezeLight.colors` and
///   `BreezeDark.colors` (invent.kde.org, plasma/breeze), in OKLCH.
/// - **Neutral:** the window's `BackgroundNormal`, #EFF0F1 light and
///   #202326 dark: a cool grey of hue 248, its chroma taken from the dark
///   one.
/// - **Status hues:** `ForegroundNegative` #DA4453, `ForegroundNeutral`
///   #F67400 and `ForegroundPositive` #27AE60.
/// - **Type:** Plasma's default font, Noto Sans 10 pt, 13.33 px
///   (plasma-integration's `kfontsettingsdata.cpp`). Kirigami's `Heading`
///   sets level 3 at 1.15 and level 1 at 1.35 times it, and a ratio of
///   1.16 puts `title` at 1.16 and `headline` at 1.35. The x-height is Noto
///   Sans' at that size: 536 of 1069 + 293 units of ascent and descent.
/// - **Shapes:** Breeze's `Frame_FrameRadius` and Kirigami's
///   `Units.cornerRadius`, 5 px, and its checkbox's 4 px, for every shape
///   (`sharp`, 4), with grooves and bars as pills.
/// - **Density:** Breeze's `breezemetrics.h` and Kirigami's `Units`: 2 px
///   between a menu's items, `smallSpacing` 4, `mediumSpacing` and
///   `Layout_DefaultSpacing` 6, `largeSpacing` 8, a window's margin of 10
///   and `gridUnit` 18, the comfortable column; compact and roomy are it at
///   2/3 and 4/3, as the default's are of its own.
/// - **Motion:** Breeze's `AnimationsDuration`, 100 ms, for a hover, a
///   press and a check; Kirigami's `longDuration`, 200 ms, for an entrance
///   or a disclosure and `shortDuration`, 100 ms, for an exit. No control
///   scales when pressed. The springs are the default's.
///
/// ```zig
/// var app_design = zui_themes.breeze;
/// app_design.type.fonts = .{
///     .regular = @intFromEnum(FontId.atkinson_regular),
///     .strong = @intFromEnum(FontId.atkinson_bold),
///     .monospace = @intFromEnum(FontId.liberation_mono),
/// };
/// app_design.type.faces.regular = .of(text.fontMetrics(fonts.atkinson_regular).?);
/// ```
pub const breeze: zui.design.Design = .{
    .name = "zui_themes.breeze",
    .seeds = .{
        .accent = .{ .lightness = 0.7131, .chroma = 0.1313, .hue = 236.01 },
        .neutral = .{ .lightness = 0.2543, .chroma = 0.0072, .hue = 248.11 },
        .danger_hue = 19.16,
        .warning_hue = 49.96,
        .success_hue = 152.37,
    },
    .type = .{ .ratio = 1.16, .body_size = 13.33, .x_height = 5.25 },
    .shapes = .init(.{ .control = .sharp, .container = .sharp, .popup = .sharp, .chip = .sharp, .image = .sharp, .indicator = .bubble }),
    .corner_shape = .round,
    .density = .init(.{
        .compact = .init(.{ .none = 0, .hair = 1, .xs = 1, .s = 3, .m = 4, .l = 5, .xl = 7, .xxl = 12 }),
        .comfortable = .init(.{ .none = 0, .hair = 1, .xs = 2, .s = 4, .m = 6, .l = 8, .xl = 10, .xxl = 18 }),
        .roomy = .init(.{ .none = 0, .hair = 2, .xs = 3, .s = 5, .m = 8, .l = 11, .xl = 13, .xxl = 24 }),
    }),
    .motion = .{
        .state = .{ .duration = 0.1, .easing = .ease_out },
        .press = .{ .duration = 0.1, .easing = .ease_out },
        .toggle = .{ .angular_frequency = 28 },
        .check = .{ .duration = 0.1, .easing = .ease_out },
        .popover_enter = .{ .duration = 0.2, .easing = .ease_out },
        .popover_exit = .{ .duration = 0.1, .easing = .ease_in },
        .dialog_enter = .{ .duration = 0.2, .easing = .ease_out },
        .dialog_exit = .{ .duration = 0.1, .easing = .ease_in },
        .toast_enter = .{ .angular_frequency = 22 },
        .toast_exit = .{ .duration = 0.1, .easing = .ease_in },
        .drawer = .{ .angular_frequency = 20 },
        .reorder = .{ .angular_frequency = 30 },
        .disclosure = .{ .duration = 0.2, .easing = .ease_in_out },
        .press_scale = 1,
    },
};

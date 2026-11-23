const zui = @import("zui");

/// zui's default design, for consumer apps first: one accent on cool
/// neutrals, Atkinson Hyperlegible at 16 on a 1.2 scale, smooth controls
/// and soft containers with continuous corners, and short eased tweens
/// and springs that press a control to 97%. Its fonts are the
/// application's to fill from its `FontId`s.
///
/// ```zig
/// var app_design = zui_design.default;
/// app_design.type.fonts = .{
///     .regular = @intFromEnum(FontId.atkinson_regular),
///     .strong = @intFromEnum(FontId.atkinson_bold),
///     .monospace = @intFromEnum(FontId.liberation_mono),
///     .italic = @intFromEnum(FontId.atkinson_italic),
///     .strong_italic = @intFromEnum(FontId.atkinson_bold_italic),
/// };
/// app_design.type.faces.regular = .of(text.fontMetrics(fonts.atkinson_regular).?);
/// ```
pub const default: zui.design.Design = .{
    .name = "zui_design.default",
    .seeds = .{
        .accent = .{ .lightness = 0.55, .chroma = 0.17, .hue = 258 },
        .neutral = .{ .lightness = 0.5, .chroma = 0.008, .hue = 258 },
        .danger_hue = 27,
        .warning_hue = 75,
        .success_hue = 150,
    },
    .type = .{ .ratio = 1.2, .body_size = 16, .x_height = 6.4 },
    .shapes = .init(.{ .control = .smooth, .container = .soft, .popup = .soft, .chip = .bubble, .image = .smooth, .indicator = .bubble }),
    .corner_shape = .continuous,
    .motion = .{
        .state = .{ .duration = 0.12, .easing = .ease_out },
        .press = .{ .duration = 0.08, .easing = .ease_out },
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
        .press_scale = 0.97,
    },
};

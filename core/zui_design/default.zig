const zui = @import("zui");

/// zui's default design, for consumer apps first: one accent on cool
/// neutrals, Atkinson Hyperlegible at 16 on a 1.2 scale, smooth controls
/// and soft containers with continuous corners. Its fonts are the
/// application's to fill from its `FontId`s.
///
/// ```zig
/// var app_design = zui_design.default;
/// app_design.type.fonts = .{ .regular = @intFromEnum(FontId.atkinson_regular), .strong = @intFromEnum(FontId.atkinson_bold), .monospace = @intFromEnum(FontId.liberation_mono) };
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
};

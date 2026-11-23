const std = @import("std");
const zui_themes = @import("zui_themes");
const checks = @import("design_checks.zig");

const language = zui_themes.fluent;
const winui_success = 0x0f7b0f;

test "Fluent resolves at comptime in every scheme and density with nothing repaired" {
    try std.testing.expectEqual(0, checks.repairsAtComptime(language));
}

test "Fluent meets every contrast target, keeps the default's tones, and follows the system's accent" {
    const accent_from_the_theming_guide = 0x107c10;
    try checks.expectAll(language, .{
        .accent = 0x0078d4,
        .neutral = 0xf3f3f3,
        .danger = 0xc42b1c,
        .warning = 0x9d5d00,
        .success = null,
    }, accent_from_the_theming_guide);
}

test "Fluent's success hue is WinUI's, moved toward the default's until tritanopes tell it from danger" {
    try checks.expectHueMovedFrom(winui_success, language.seeds.success_hue.?, 6);
}

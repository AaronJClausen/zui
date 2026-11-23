const std = @import("std");
const zui_themes = @import("zui_themes");
const checks = @import("design_checks.zig");

const language = zui_themes.breeze;

test "Breeze resolves at comptime in every scheme and density with nothing repaired" {
    try std.testing.expectEqual(0, checks.repairsAtComptime(language));
}

test "Breeze meets every contrast target, keeps the default's tones, and follows the system's accent" {
    const accent_from_a_users_color_scheme = 0xe93d58;
    try checks.expectAll(language, .{
        .accent = 0x3daee9,
        .neutral = 0x202326,
        .danger = 0xda4453,
        .warning = 0xf67400,
        .success = 0x27ae60,
    }, accent_from_a_users_color_scheme);
}

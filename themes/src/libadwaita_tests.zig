const std = @import("std");
const zui_themes = @import("zui_themes");
const checks = @import("design_checks.zig");

const language = zui_themes.libadwaita;

test "libadwaita resolves at comptime in every scheme and density with nothing repaired" {
    try std.testing.expectEqual(0, checks.repairsAtComptime(language));
}

test "libadwaita meets every contrast target, keeps the default's tones, and follows the system's accent" {
    const accent_purple = 0x9141ac;
    try checks.expectAll(language, .{
        .accent = 0x3584e4,
        .neutral = 0x222226,
        .danger = 0xe01b24,
        .warning = 0xe5a50a,
        .success = 0x2ec27e,
    }, accent_purple);
}

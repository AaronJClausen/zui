//! Icons by name, drawn as text in Tabler Icons, whose glyphs `zui_fonts`
//! bundles as `tabler_icons`: each `Name` is a codepoint in that font.
//!
//! ```zig
//! const tabler_icons = try text.addFont(zui_fonts.tabler_icons);
//! ui.text(zui_icons.utf8(.settings), .{ .font = tabler_icons, .size = 20 });
//!
//! var app_design = zui_design.default;
//! app_design.icons = zui_icons.tabler;
//! app_design.type.fonts.icons = @intFromEnum(tabler_icons);
//! ```

const std = @import("std");
const zui = @import("zui");

/// Every icon in the bundled subset, by its name in Tabler Icons with `_`
/// for `-`; each tag's value is its codepoint.
pub const Name = enum(u21) {
    chevron_down = 0xea5f,
    chevron_right = 0xea61,
    chevron_up = 0xea62,
    chevron_left = 0xea60,
    check = 0xea5e,
    x = 0xeb55,
    search = 0xeb1c,
    alert_circle = 0xea05,
    info_circle = 0xeac5,
    circle_check = 0xea67,
    alert_triangle = 0xea06,
    alert_octagon = 0xecc6,
    arrow_up = 0xea25,
    arrow_down = 0xea16,
    arrow_left = 0xea19,
    arrow_right = 0xea1f,
    photo_off = 0xecf6,
    loader_2 = 0xf226,
    plus = 0xeb0b,
    minus = 0xeaf2,
    menu_2 = 0xec42,
    dots = 0xea95,
    dots_vertical = 0xea94,
    settings = 0xeb20,
    trash = 0xeb41,
    edit = 0xea98,
    pencil = 0xeb04,
    copy = 0xea7a,
    share = 0xeb21,
    link = 0xeade,
    external_link = 0xea99,
    download = 0xea96,
    upload = 0xeb47,
    refresh = 0xeb13,
    home = 0xeac1,
    user = 0xeb4d,
    logout = 0xeba8,
    folder = 0xeaad,
    file = 0xeaa4,
    eye = 0xea9a,
    eye_off = 0xecf0,
    star = 0xeb2e,
    heart = 0xeabe,
    filter = 0xeaa5,
    calendar = 0xea53,
    clock = 0xea70,
    bell = 0xea35,
    lock = 0xeae2,
    lock_open = 0xeae1,
    player_play = 0xed46,
    player_pause = 0xed45,
};

/// `name`'s codepoint in Tabler Icons, as `zui_fonts.tabler_icons` maps it.
pub fn codepoint(name: Name) u21 {
    return @intFromEnum(name);
}

/// The text that draws `name` in Tabler Icons.
pub fn utf8(name: Name) []const u8 {
    return switch (name) {
        inline else => |known| comptime encoded(known),
    };
}

fn encoded(comptime name: Name) []const u8 {
    var bytes: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint(name), &bytes) catch unreachable;
    const frozen = bytes[0..length].*;
    return &frozen;
}

/// The icons zui's components draw, in Tabler Icons: an octagon for
/// danger, so each status glyph differs from the others in shape and not
/// only in color, as a circle with a cross would beside the circled check.
pub const tabler: zui.design.IconSet = .{ .codepoints = .init(.{
    .chevron_down = codepoint(.chevron_down),
    .chevron_right = codepoint(.chevron_right),
    .check = codepoint(.check),
    .close = codepoint(.x),
    .search = codepoint(.search),
    .alert = codepoint(.alert_circle),
    .info = codepoint(.info_circle),
    .success = codepoint(.circle_check),
    .warning = codepoint(.alert_triangle),
    .danger = codepoint(.alert_octagon),
    .arrow_up = codepoint(.arrow_up),
    .arrow_down = codepoint(.arrow_down),
    .broken_image = codepoint(.photo_off),
    .spinner = codepoint(.loader_2),
}) };

test {
    _ = @import("tests.zig");
}

const std = @import("std");
const zui = @import("zui");
const zui_icons = @import("zui_icons.zig");

const testing = std.testing;
const Tokens = zui.design.Tokens(zui.Context(.{ .limits = .{ .max_elements = 8 } }), void);

test "every name's text decodes to its codepoint" {
    for (std.enums.values(zui_icons.Name)) |name| {
        const text = zui_icons.utf8(name);
        try testing.expectEqual(zui_icons.codepoint(name), try std.unicode.utf8Decode(text));
    }
    const settings = comptime zui_icons.utf8(.settings);
    try testing.expectEqualStrings("\u{eb20}", settings);
}

test "the subset stays small and its codepoints distinct" {
    const names = std.enums.values(zui_icons.Name);
    try testing.expect(names.len <= 64);
    for (names, 0..) |name, index| {
        for (names[index + 1 ..]) |other| try testing.expect(zui_icons.codepoint(name) != zui_icons.codepoint(other));
    }
}

test "tabler gives every component icon a codepoint of the subset" {
    for (std.enums.values(zui.design.Icon)) |icon| {
        const named = std.enums.fromInt(zui_icons.Name, zui_icons.tabler.codepoints.get(icon));
        try testing.expect(named != null);
    }
    try testing.expectEqual(zui_icons.codepoint(.x), zui_icons.tabler.codepoints.get(.close));
}

test "tabler resolves into tokens beside the application's font" {
    var tokens: Tokens = .{ .icon_font = 3, .icon_codepoints = zui_icons.tabler.codepoints };
    const spinner = tokens.icon(.spinner).?;
    try testing.expectEqual(3, spinner.font);
    try testing.expectEqualStrings(zui_icons.utf8(.loader_2), spinner.utf8());
    tokens.icon_font = null;
    try testing.expectEqual(null, tokens.icon(.spinner));
}

const std = @import("std");
const zui = @import("zui");
const zui_icons = @import("zui_icons");
const zui_fonts = @import("zui_fonts");
const zui_truetype = @import("zui_truetype");

const missing_glyph = 0;

test "every icon name has a glyph in the bundled Tabler Icons" {
    var text: zui_truetype.Text = .{};
    const tabler_icons = try text.addFont(zui_fonts.tabler_icons);
    for (std.enums.values(zui_icons.Name)) |name| {
        std.testing.expect(text.glyphIndex(tabler_icons, zui_icons.codepoint(name)) != missing_glyph) catch |failure| {
            std.debug.print("zui_icons.Name.{t} has no glyph in zui_fonts.tabler_icons\n", .{name});
            return failure;
        };
    }
}

test "an icon is drawn as text in the application's icon font" {
    var text: zui_truetype.Text = .{};
    const tabler_icons = try text.addFont(zui_fonts.tabler_icons);
    const Ui = zui.Context(.{ .limits = .{ .max_elements = 16 }, .Text = zui_truetype.Text });
    var tokens: zui.design.Tokens(Ui, void) = .{ .icon_font = tabler_icons, .icon_codepoints = zui_icons.tabler.codepoints };
    const search = tokens.icon(.search).?;
    try std.testing.expectEqualStrings(zui_icons.utf8(.search), search.utf8());
    try std.testing.expect(text.glyphIndex(@intCast(search.font), search.codepoint) != missing_glyph);
    tokens.icon_font = null;
    try std.testing.expectEqual(null, tokens.icon(.search));
}

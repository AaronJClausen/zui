const zui = @import("zui");
const zui_design = @import("zui_design");

const icon_font_without_icons: zui.design.Design = .{
    .name = "demo.design",
    .seeds = .{
        .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 },
        .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 },
    },
    .type = .{ .fonts = .{ .icons = 4 } },
};

comptime {
    var tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = zui_design.resolve(icon_font_without_icons, .{}, &tokens);
}

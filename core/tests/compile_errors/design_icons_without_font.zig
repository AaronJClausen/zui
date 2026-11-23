const zui = @import("zui");
const zui_design = @import("zui_design");

const icons_without_font: zui.design.Design = .{
    .name = "demo.design",
    .seeds = .{
        .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 },
        .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 },
    },
    .icons = .{ .codepoints = .initFill(0xea5e) },
};

comptime {
    var tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = zui_design.resolve(icons_without_font, .{}, &tokens);
}

const zui = @import("zui");
const zui_design = @import("zui_design");

const green_danger: zui.design.Design = .{
    .name = "demo.design",
    .seeds = .{
        .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 },
        .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 },
        .danger_hue = 150,
    },
};

comptime {
    var tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = zui_design.resolve(green_danger, .{}, &tokens);
}

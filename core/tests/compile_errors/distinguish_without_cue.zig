const zui = @import("zui");
const zui_design = @import("zui_design");

const design: zui.design.Design = .{
    .name = "demo.design",
    .seeds = .{ .accent = .{ .lightness = 0.55, .chroma = 0.14, .hue = 250 }, .neutral = .{ .lightness = 0.5, .chroma = 0.01, .hue = 250 } },
};

const Chip = struct {
    pub const Part = enum { container, container_selected };

    pub const zuiAppearance = zui.design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container },
        .container_selected = .{ .surface = .accent_container },
    });

    pub const zuiDistinguish = .{
        .{ .container, .container_selected },
    };
};

comptime {
    zui_design.checkDistinguished(design, .{Chip});
}

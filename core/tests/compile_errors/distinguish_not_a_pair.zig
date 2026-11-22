const zui = @import("zui");

const Chip = struct {
    pub const Part = enum { container, container_selected };

    pub const zuiAppearance = zui.design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container },
        .container_selected = .{ .surface = .accent_container },
    });

    pub const zuiDistinguish = .{
        .{.container},
    };
};

comptime {
    const tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = tokens.look(Chip, .container, .idle);
}

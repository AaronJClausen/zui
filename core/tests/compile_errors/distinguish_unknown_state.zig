const zui = @import("zui");

const Chip = struct {
    pub const Part = enum { container };

    pub const zuiAppearance = zui.design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container, .target = .pointer },
    });

    pub const zuiDistinguish = .{
        .{ .container, .normal, .hovered },
    };
};

comptime {
    const tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = tokens.look(Chip, .container, .idle);
}

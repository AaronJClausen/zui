const zui = @import("zui");

const Chip = struct {
    pub const Part = enum { container, close };

    pub const zuiAppearance = zui.design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container, .shape = .chip },
        .close = .{ .icon = .on_secondary_container, .target = .touch },
    });
};

comptime {
    const tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = tokens.look(Chip, .container, .idle);
}

const zui = @import("zui");

const Chip = struct {
    pub const Part = enum { container, close };

    pub const zuiAppearance = zui.design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container, .shape = .chip },
        .close = .{ .text = .on_secondary_container, .icon = .on_secondary_container, .on = .container },
    });
};

comptime {
    const tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = tokens.look(Chip, .close, .idle);
}

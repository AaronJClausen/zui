const zui = @import("zui");

const Chip = struct {
    pub const zuiAppearance = zui.design.Appearance(enum { container }, .{
        .container = .{ .surface = .secondary_container },
    });
};

comptime {
    const tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = tokens.look(Chip, .container, .idle);
}

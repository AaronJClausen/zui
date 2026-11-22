const zui = @import("zui");

const Chip = struct {
    pub const Part = enum { container, label };

    pub const zuiAppearance = zui.design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container, .shape = .chip },
        .label = .{ .text = .on_secondary_container, .type = .label },
    });
};

comptime {
    const tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = tokens.look(Chip, .container, .idle);
}

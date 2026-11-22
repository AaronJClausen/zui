const zui = @import("zui");

const Chip = struct {
    pub const Part = enum { container, label, close };

    pub const zuiAppearance = zui.design.Appearance(Part, .{
        .container = .{ .surface = .secondary_container, .shape = .chip },
        .label = .{ .text = .on_secondary_container, .type = .label, .on = .close },
        .close = .{ .icon = .on_secondary_container, .on = .container, .target = .touch },
    });
};

comptime {
    const tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = tokens.look(Chip, .label, .idle);
}

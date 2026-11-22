const zui = @import("zui");

const Chip = struct {
    pub const Part = enum { container, label };

    pub const zuiAppearance = zui.design.Appearance(Part, .{
        .label = .{ .text = .on_secondary_container, .type = .label, .on = .container },
    });
};

comptime {
    const tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = tokens.look(Chip, .label, .idle);
}

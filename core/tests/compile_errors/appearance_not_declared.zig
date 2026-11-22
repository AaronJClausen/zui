const zui = @import("zui");

const Chip = struct {
    pub const Part = enum { container };
};

comptime {
    const tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = tokens.look(Chip, .container, .idle);
}

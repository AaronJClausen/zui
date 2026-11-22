const zui = @import("zui");

const Roles = enum {
    brand,

    pub const zuiPairs = .{ .brand = .on_surface };
};

const Badge = struct {
    pub const Part = enum { body };

    pub const zuiAppearance = zui.design.AppearanceWith(Part, Roles, .{
        .body = .{ .surface = .extra(.brand) },
    });
};

comptime {
    const tokens: zui.design.Tokens(zui.Context(.{}), void) = .{};
    _ = tokens.look(Badge, .body, .idle);
}

const zui = @import("zui");

const Roles = enum {
    brand,
    accent,

    pub const zuiPairs = .{ .brand = .on_surface, .accent = .surface };
};

comptime {
    _ = zui.design.Tokens(zui.Context(.{}), Roles);
}

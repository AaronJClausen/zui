const zui = @import("zui");

const Roles = enum {
    brand,

    pub const zuiPairs = .{ .brand = .on_surface, .logo = .surface };
};

comptime {
    _ = zui.design.Tokens(zui.Context(.{}), Roles);
}

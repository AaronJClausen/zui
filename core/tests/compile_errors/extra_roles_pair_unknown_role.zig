const zui = @import("zui");

const Roles = enum {
    brand,

    pub const zuiPairs = .{ .brand = .logo };
};

comptime {
    _ = zui.design.Tokens(zui.Context(.{}), Roles);
}

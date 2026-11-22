const zui = @import("zui");

const Roles = enum { brand, on_brand };

comptime {
    _ = zui.design.Tokens(zui.Context(.{}), Roles);
}

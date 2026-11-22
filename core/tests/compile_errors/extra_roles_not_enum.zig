const zui = @import("zui");

comptime {
    _ = zui.design.Tokens(zui.Context(.{}), u8);
}

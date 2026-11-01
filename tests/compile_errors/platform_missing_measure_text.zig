const zui = @import("zui");

const Platform = struct {
    pub fn measure(_: *Platform, _: []const u8, _: u16, _: f32) [2]f32 {
        return .{ 0, 0 };
    }
};

comptime {
    _ = zui.Context(.{}, Platform);
}

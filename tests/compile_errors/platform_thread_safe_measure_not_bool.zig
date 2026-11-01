const zui = @import("zui");

const Platform = struct {
    pub const thread_safe_measure = 1;

    pub fn measureText(_: *Platform, _: []const u8, _: u16, _: f32) [2]f32 {
        return .{ 0, 0 };
    }
};

export fn entry(ui: *zui.Context(.{}, Platform)) void {
    ui.beginFrame(.{ .viewport = .{ 100, 100 } });
}

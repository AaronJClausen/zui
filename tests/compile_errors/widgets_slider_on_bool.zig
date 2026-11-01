const zui = @import("zui");
const zui_widgets = @import("zui_widgets");

const Platform = struct {
    pub fn measureText(_: *Platform, _: []const u8, _: u16, _: f32) [2]f32 {
        return .{ 0, 0 };
    }
};

const Ui = zui.Context(.{}, Platform);
const widgets: zui_widgets.Widgets(Ui) = .{};

export fn entry(ui: *Ui, enabled: *bool) void {
    _ = widgets.slider(ui, .of("enabled"), enabled, .{});
}

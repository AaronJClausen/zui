const zui = @import("zui");
const zui_widgets = @import("zui_widgets");
const zui_reflect = @import("zui_reflect");

const Platform = struct {
    pub fn measureText(_: *Platform, _: []const u8, _: u16, _: f32) [2]f32 {
        return .{ 0, 0 };
    }
};

const Ui = zui.Context(.{}, Platform);
const widgets: zui_widgets.Widgets(Ui) = .{};

const Settings = struct {
    max_fps: u16 = 60,

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
        .max_fps = .{ .min = 240, .max = 30 },
    } };
};

export fn entry(ui: *Ui, settings: *Settings) void {
    _ = zui_reflect.inspector(widgets, ui, .of("settings"), settings);
}

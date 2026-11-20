const zui = @import("zui");
const zui_widgets = @import("zui_widgets");
const zui_reflect = @import("zui_reflect");

const Text = struct {
    pub fn zuiMeasure(_: *Text, _: []const u8, _: zui.MeasureKey(u16)) [2]f32 {
        return .{ 0, 0 };
    }
};

const Ui = zui.Context(.{ .Text = Text });
const widgets: zui_widgets.Widgets(Ui) = .{};

const Settings = struct {
    volume: f32 = 0.8,
    on_change: *const fn () void,
};

export fn entry(ui: *Ui, settings: *Settings) void {
    _ = zui_reflect.inspector(widgets, ui, .of("settings"), settings);
}

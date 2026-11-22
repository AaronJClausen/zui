const zui = @import("zui");
const zui_widgets = @import("zui_widgets");

const Text = struct {
    pub fn zuiMeasure(_: *Text, _: []const u8, _: zui.MeasureKey(u16)) [2]f32 {
        return .{ 0, 0 };
    }
};

const Ui = zui.Context(.{ .Text = Text });

const Skin = struct {
    pub fn zuiStyle(_: *const Skin, _: zui_widgets.Part, _: zui.WidgetState) zui_widgets.Style(Ui) {
        return .{};
    }
};

export fn entry(ui: *Ui) void {
    const widgets: zui_widgets.Widgets(Ui, Skin) = .{ .skin = .{} };
    widgets.label(ui, "label");
}

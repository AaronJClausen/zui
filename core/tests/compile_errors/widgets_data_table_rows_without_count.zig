const zui = @import("zui");
const zui_widgets = @import("zui_widgets");
const zui_widgets_data = @import("zui_widgets_data");

const Text = struct {
    pub fn zuiMeasure(_: *Text, _: []const u8, _: zui.MeasureKey(u16)) [2]f32 {
        return .{ 0, 0 };
    }
};

const Ui = zui.Context(.{ .Text = Text });
var tokens: zui.design.Tokens(Ui, void) = .{};
const widgets: zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui)) = .{ .skin = .{ .tokens = &tokens } };

const Row = struct { name: []const u8 };

export fn entry(ui: *Ui) void {
    _ = zui_widgets_data.of(widgets).table(ui, .of("files"), Row, @as(u32, 3), .{ .columns = &.{} });
}

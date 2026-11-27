const zui = @import("zui");
const zui_widgets = @import("zui_widgets");

const Text = struct {
    pub fn zuiMeasure(_: *Text, _: []const u8, _: zui.MeasureKey(u16)) [2]f32 {
        return .{ 0, 0 };
    }
};

const Ui = zui.Context(.{ .Text = Text, .ImageHandle = u32 });
var tokens: zui.design.Tokens(Ui, void) = .{};
const widgets: zui_widgets.Widgets(Ui, zui_widgets.DesignSkin(Ui)) = .{ .skin = .{ .tokens = &tokens } };

export fn entry(ui: *Ui, handle: u32) void {
    widgets.asyncImage(ui, .of("cover"), handle, .{});
}

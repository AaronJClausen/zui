const zui = @import("zui");
const zui_async = @import("zui_async");
const zui_debug = @import("zui_debug");

const Fonts = struct {
    pub fn zuiMeasure(_: *Fonts, _: []const u8, _: zui.MeasureKey(u16)) [2]f32 {
        return .{ 0, 0 };
    }
};

const Sources = struct {
    theme_files: zui_async.Stream(zui.FileChange, .{ .capacity = 4 }) = .{},
    theme: zui_async.Latest(zui.Color) = .{},
};

const Ui = zui.Context(.{ .Text = Fonts, .Sources = Sources });

export fn entry(ui: *Ui, inspector: *zui_debug.Inspector(Ui)) void {
    inspector.declareWithThemeFrom(ui, .{ .file_changes = .theme_files, .theme = .theme });
}

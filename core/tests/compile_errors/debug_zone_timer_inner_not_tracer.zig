const zui = @import("zui");
const zui_debug = @import("zui_debug");

const Fonts = struct {};

const Ui = zui.Context(.{ .features = .{ .Tracer = zui_debug.ZoneTimer(Fonts) } });

export fn entry(ui: *Ui) void {
    ui.release(ui.endFrame());
}

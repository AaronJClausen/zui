const zui = @import("zui");

const Ui = zui.Context(.{ .features = .{ .gestures = false } });

export fn entry(ui: *const Ui) bool {
    return ui.manipulation(.of("map")) != null;
}

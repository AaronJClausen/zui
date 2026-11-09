const zui = @import("zui");

const Ui = zui.Context(.{ .features = .{ .gestures = false } });

export fn entry(ui: *const Ui) bool {
    var events = ui.pointerEvents(.of("map"));
    return events.next() != null;
}

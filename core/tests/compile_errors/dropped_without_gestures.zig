const zui = @import("zui");

const Ui = zui.Context(.{ .features = .{ .gestures = false } });

const Card = struct { index: u32 };

export fn entry(ui: *Ui) bool {
    return ui.dropped(.of("column"), Card) != null;
}

const zui = @import("zui");
const zui_motion = @import("zui_motion");

const Ui = zui.Context(.{});

export fn entry(ui: *Ui) u32 {
    return zui_motion.tween(ui, .of("count"), u32, 3, .{});
}

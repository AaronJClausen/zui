const zui = @import("zui");

const Ui = zui.Context(.{});

export fn entry(ui: *Ui) void {
    ui.text("hello", .{});
}

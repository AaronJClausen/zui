const zui = @import("zui");

const Ui = zui.Context(.{});

export fn declare(ui: *Ui) void {
    _ = ui.source(.quotes);
}

const zui = @import("zui");
const zui_debug = @import("zui_debug");

const Ui = zui.Context(.{});

export fn entry(ui: *Ui) void {
    const inspector: zui_debug.Inspector(Ui) = .{};
    inspector.declare(ui);
}

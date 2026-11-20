const zui = @import("zui");

const Ui = zui.Context(.{});

const Document = struct { title: [72]u8 };

export fn entry(ui: *Ui) void {
    ui.startDrag(.of("document"), Document{ .title = @splat(0) });
}

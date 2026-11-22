const zui = @import("zui");

const Ui = zui.Context(.{});

export fn entry(ui: *Ui) void {
    ui.box(.{ .decoration = .{ .background = .white, .nested_corners = .{ .minimum = 2 } } });
}

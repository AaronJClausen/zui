const zui = @import("zui");

const Ui = zui.Context(.{});

const History = struct { entries: [20]u32 };

export fn entry(ui: *Ui) void {
    _ = ui.state(.of("history"), History);
}

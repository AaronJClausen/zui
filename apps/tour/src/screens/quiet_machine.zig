const std = @import("std");
const zui = @import("zui");
const zui_async = @import("zui_async");

pub const Reading = struct {
    value: f32 = 0,
    sample: u64 = 0,
};

pub const ReadingSource = zui_async.Latest(Reading);

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        pub const QuietMachine = struct {
            pub fn declare(_: *QuietMachine, ui: *Ui, shell: *const Shell) void {
                shell.pageHeading(ui, "SPECTACLE", "Quiet Machine", "Not built yet.");
                ui.open(.{ .layout = .{ .child_gap = 4 } });
                defer ui.close();
                for (0..24) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = shell.palette.border } });
            }
        };
    };
}

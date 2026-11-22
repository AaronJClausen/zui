pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        pub const TimeMachine = struct {
            pub fn declare(_: *TimeMachine, ui: *Ui, shell: *const Shell) void {
                shell.pageHeading(ui, "SPECTACLE", "Time Machine", "Not built yet.");
                ui.open(.{ .layout = .{ .child_gap = 4 } });
                defer ui.close();
                for (0..24) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = shell.palette.border } });
            }
        };
    };
}

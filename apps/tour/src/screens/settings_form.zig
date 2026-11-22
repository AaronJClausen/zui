pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        pub const SettingsForm = struct {
            pub fn declare(_: *SettingsForm, ui: *Ui, shell: *const Shell) void {
                shell.pageHeading(ui, "FIELD CASE", "Settings Form", "Not built yet.");
                ui.open(.{ .layout = .{ .child_gap = 4 } });
                defer ui.close();
                for (0..24) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = shell.palette.border } });
            }
        };
    };
}

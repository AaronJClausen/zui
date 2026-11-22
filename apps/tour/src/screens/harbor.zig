const std = @import("std");
const zui = @import("zui");
const zui_async = @import("zui_async");

pub const Metrics = struct {
    requests_per_second: f32 = 0,
    error_percent: f32 = 0,
    p95_milliseconds: f32 = 0,
    sample: u64 = 0,
};

pub const MetricsSource = zui_async.Latest(Metrics);

pub const Event = struct {
    bytes: [96]u8 = undefined,
    len: u8 = 0,
};

pub const EventSource = zui_async.Stream(Event, .{ .capacity = 64, .producers = .many });

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        pub const Harbor = struct {
            pub fn declare(_: *Harbor, ui: *Ui, shell: *const Shell) void {
                shell.pageHeading(ui, "FLAGSHIP", "Harbor", "Not built yet.");
                ui.open(.{ .layout = .{ .child_gap = 4 } });
                defer ui.close();
                for (0..24) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = shell.palette.border } });
            }

            pub fn declareXray(self: *Harbor, ui: *Ui, shell: *const Shell) void {
                self.declare(ui, shell);
            }
        };
    };
}

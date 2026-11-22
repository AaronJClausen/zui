const std = @import("std");
const zui = @import("zui");
const zui_async = @import("zui_async");

pub const Rate = struct {
    lines_per_second: f32 = 0,
    sample: u64 = 0,
};

pub const RateSource = zui_async.Latest(Rate);

pub const Line = struct {
    bytes: [120]u8 = undefined,
    len: u8 = 0,
};

pub const LineSource = zui_async.Stream(Line, .{ .capacity = 256, .producers = .many });

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        pub const LogTail = struct {
            pub fn declare(_: *LogTail, ui: *Ui, shell: *const Shell) void {
                shell.pageHeading(ui, "FIELD CASE", "Log Tail", "Not built yet.");
                ui.open(.{ .layout = .{ .child_gap = 4 } });
                defer ui.close();
                for (0..24) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = shell.palette.border } });
            }
        };
    };
}

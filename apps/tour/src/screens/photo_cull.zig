const std = @import("std");
const zui = @import("zui");
const zui_async = @import("zui_async");

pub const Photo = struct {
    first: zui.Color,
    second: zui.Color,
};

pub const PhotoError = error{ Canceled, NoThreadAvailable };

pub const PhotoLoads = zui_async.KeyedLoads(u32, PhotoError!Photo, .{ .capacity = 512, .unread_frames_before_release = 20, .Progress = f32 });

pub const PhotoOutcomes = struct {
    loaded: u32 = 0,
    abandoned: u32 = 0,
};

pub const PhotoOutcomesSource = zui_async.Latest(PhotoOutcomes);

pub fn Using(comptime kit: type) type {
    const Ui = kit.Ui;
    const Shell = kit.Shell;
    return struct {
        pub const PhotoCull = struct {
            pub fn declare(_: *PhotoCull, ui: *Ui, shell: *const Shell) void {
                shell.pageHeading(ui, "FIELD CASE", "Photo Culling", "Not built yet.");
                ui.open(.{ .layout = .{ .child_gap = 4 } });
                defer ui.close();
                for (0..24) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .fixed(8) } }, .decoration = .{ .background = shell.palette.border } });
            }
        };
    };
}

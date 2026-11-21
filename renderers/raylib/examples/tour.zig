//! zui's tour, run by `zui_app` on raylib's window, in TrueType fonts.
//!
//! ```sh
//! zig build tour                                     # interactive window
//! zig build tour -- --screen box_storm               # start on one screen
//! zig build tour -- --hidden --frames 600 --cycle 50 # visit every screen, 50 frames each, then quit
//! zig build tour -- --screenshot $PWD/tour.png --screen gallery  # render offscreen, save a PNG and quit
//! zig build tour -- --measure-idle                   # report the CPU time used over 10 idle seconds
//! zig build tour -- --measure-startup                # report the time from process start to the first presented frame
//! zig build tour -- --zui-debug                      # open zui_debug's inspector, which F12 toggles
//! ```

const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_raylib = @import("zui_raylib");
const zui_truetype = @import("zui_truetype");
const zui_tour = @import("zui_tour");

const Tour = zui_tour.App(.{ .Host = zui_raylib.Host, .Renderer = zui_raylib.Renderer, .Text = zui_truetype.Text, .renderer_name = "raylib" });

pub fn main(init: std.process.Init) !void {
    const options = try zui_tour.Options.parse(try init.minimal.args.toSlice(init.arena.allocator()));
    try zui_app.run(TourOnRaylib, init, .{ .title = "zui tour (raylib)", .size = .{ 1440, 900 }, .visible = !options.hidden, .resizable = !options.hidden, .notify = logAndKeepRunReport });
}

/// What `zui_app` started with, for `zui_debug`'s panel to list among the
/// fallbacks. A notice carries no application, so it waits here.
var run_report: ?zui_app.Report = null;

fn logAndKeepRunReport(notice: zui_app.Notice) void {
    if (notice == .started) run_report = notice.started;
    zui_app.logNotice(notice);
}

/// Frames drawn before a screenshot, in live mode, so it shows a settled
/// layout and the gallery's first tiles.
const screenshot_after_frames = 45;

/// The tour, with what raylib's window adds: screenshots drawn offscreen,
/// the startup measurement, and the run's report in `zui_debug`'s panel.
const TourOnRaylib = struct {
    pub const Host = Tour.Host;
    pub const Renderer = Tour.Renderer;
    pub const Text = Tour.Text;

    tour: Tour,
    sources: *zui_tour.Sources,

    pub fn init(app: *TourOnRaylib, start: zui_app.Start(TourOnRaylib)) !void {
        app.sources = &app.tour.tour.sources;
        try app.tour.init(Tour.startOf(start));
        if (app.tour.options.screenshot_path != null) start.renderer.drawOffscreen();
    }

    pub fn deinit(app: *TourOnRaylib) void {
        app.tour.deinit();
    }

    pub fn zuiRecord(app: *TourOnRaylib, record: *zui.RecordBuilder) void {
        app.tour.zuiRecord(record);
    }

    pub fn zuiDeclare(app: *TourOnRaylib, ui: *Tour.Ui) void {
        if (app.tour.options.measure_startup) {
            if (app.tour.frames == 1) {
                reportStartup(app.tour.host, app.tour.renderer);
                app.tour.closeHost();
            }
            ui.requestFrame();
        }
        app.tour.zuiDeclare(ui);
    }

    pub fn zuiObserve(app: *TourOnRaylib, ui: *const Tour.Ui, frame: *const Tour.Ui.Frame) void {
        if (run_report) |report| {
            app.tour.tour.zui_debug_inspector.reportRun(report);
            run_report = null;
        }
        app.tour.zuiObserve(ui, frame);
    }

    /// Takes the screenshot once the tour has settled.
    pub fn zuiLoader(app: *TourOnRaylib, ui: *const Tour.Ui, io: std.Io) void {
        app.tour.zuiLoader(ui, io);
        const path = app.tour.options.screenshot_path orelse return;
        if (app.tour.frames != screenshot_after_frames) return;
        app.tour.renderer.saveScreenshot(path) catch |err| {
            std.debug.print("could not save {s}: {t}\n", .{ path, err });
            std.process.exit(1);
        };
        std.debug.print("saved {s}\n", .{path});
        app.tour.closeHost();
    }
};

const windows = std.os.windows;
extern "kernel32" fn GetProcessTimes(process: windows.HANDLE, creation: *windows.FILETIME, exit: *windows.FILETIME, kernel: *windows.FILETIME, user: *windows.FILETIME) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetSystemTimePreciseAsFileTime(time: *windows.FILETIME) callconv(.winapi) void;

/// `--measure-startup`: from the moment the OS created the process to the
/// moment the first frame was presented, read in the second frame.
fn reportStartup(host: *const zui_raylib.Host, renderer: *const zui_raylib.Renderer) void {
    const presented_seconds = renderer.first_present_seconds orelse return std.debug.print("startup: no frame was presented\n", .{});
    const presented = host.opened_at.addSeconds(presented_seconds);
    if (builtin.os.tag != .windows) return std.debug.print("startup: not measured on this system\n", .{});
    var times: [4]windows.FILETIME = undefined;
    if (GetProcessTimes(windows.GetCurrentProcess(), &times[0], &times[1], &times[2], &times[3]) == .FALSE) return std.debug.print("startup: the process's times are unavailable\n", .{});
    var wall_now: windows.FILETIME = undefined;
    GetSystemTimePreciseAsFileTime(&wall_now);
    const since_creation_ns = (fileTimeTicks(wall_now) - fileTimeTicks(times[0])) * 100;
    const created = host.now().nanoseconds -| since_creation_ns;
    std.debug.print("startup: first frame presented {d:.1} ms after the process was created; the window was open at {d:.1} ms\n", .{
        milliseconds(presented.nanoseconds -| created),
        milliseconds(host.opened_at.nanoseconds -| created),
    });
}

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}

fn fileTimeTicks(time: windows.FILETIME) u64 {
    return @as(u64, time.dwHighDateTime) << 32 | time.dwLowDateTime;
}

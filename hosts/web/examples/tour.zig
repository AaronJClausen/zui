//! zui's tour in the browser: on `zui_web.Host`, in a dedicated worker
//! that draws through `zui_webgl.Renderer` on the canvas its page
//! transferred, in TrueType fonts. The worker calls `zuiWebRun` once.
//!
//! ```sh
//! zig build tour     # writes the page to zig-out/tour; serve it cross-origin isolated
//! zig build site     # writes the same page to zig-out/site, as GitHub Pages publishes it
//! ```

const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_web = @import("zui_web");
const zui_webgl = @import("zui_webgl");
const zui_truetype = @import("zui_truetype");
const zui_tour = @import("zui_tour");

const Tour = zui_tour.App(.{ .Host = zui_web.Host, .Renderer = zui_webgl.Renderer, .Text = zui_truetype.Text, .renderer_name = "WebGL 2" });

pub const std_options = zui_web.worker.std_options;
pub const os = zui_web.worker.os;

/// The tour's tasks take turns on as many threads wherever it runs, since
/// how many run at once changes what it draws.
const task_threads = 16;

export fn zuiWebRun() void {
    const setup = zui_web.worker.setup(.{ .task_threads = task_threads }) catch |err| return zui_web.worker.fail(err);
    zui_app.runWith(TourInWorker, setup, .{ .title = "zui tour" }) catch |err| zui_web.worker.fail(err);
}

var running_tour: ?*Tour = null;

/// What the tour's strip shows for its newest frame: the microseconds of
/// its beginFrame, declaration and layout together.
export fn zuiTourNewestFrameMicroseconds() f64 {
    const tour = running_tour orelse return 0;
    return tour.tour.perf.latest().totalMicroseconds();
}

/// The tour, its frames timed on the worker's clock: the `SteppedIo`'s
/// stands still for all of a turn, so the strip would show 0 µs.
const TourInWorker = struct {
    pub const Host = Tour.Host;
    pub const Renderer = Tour.Renderer;
    pub const Text = Tour.Text;

    tour: Tour,
    sources: *zui_tour.Sources,

    pub fn init(app: *TourInWorker, start: zui_app.Start(TourInWorker)) !void {
        app.sources = &app.tour.tour.sources;
        try app.tour.init(Tour.startOf(start));
        app.tour.stopwatch = .{ .clock = zui_web.worker.millisecondsNow };
        running_tour = &app.tour;
    }

    pub fn deinit(app: *TourInWorker) void {
        running_tour = null;
        app.tour.deinit();
    }

    pub fn zuiRecord(app: *TourInWorker, record: *zui.RecordBuilder) void {
        app.tour.zuiRecord(record);
    }

    pub fn zuiDeclare(app: *TourInWorker, ui: *Tour.Ui) void {
        app.tour.zuiDeclare(ui);
    }

    pub fn zuiObserve(app: *TourInWorker, ui: *const Tour.Ui, frame: *const Tour.Ui.Frame) void {
        app.tour.zuiObserve(ui, frame);
    }

    pub fn zuiLoader(app: *TourInWorker, ui: *const Tour.Ui, io: std.Io) void {
        app.tour.zuiLoader(ui, io);
    }
};

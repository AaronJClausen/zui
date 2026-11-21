//! zui's tour on this host, drawn by the sokol renderer in TrueType fonts:
//! on Windows through a Direct3D 11 swapchain composed over the window's
//! backdrop, on Linux with OpenGL through EGL.
//!
//! ```sh
//! zig build tour                               # interactive window
//! zig build tour -- --screen box_storm         # start on one screen
//! zig build tour -- --frames 300 --cycle 30    # visit every screen, 30 frames each, then quit
//! zig build tour -- --measure-idle             # report the CPU time used over 10 idle seconds
//! zig build tour -- --screenshot tour.bmp      # save the window after a few frames, then quit (Windows)
//! ```

const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_host = @import("zui_host");
const zui_truetype = @import("zui_truetype");
const zui_tour = @import("zui_tour");
const SokolRenderer = @import("sokol_renderer.zig").SokolRenderer;
const capture = @import("capture.zig");

const Tour = zui_tour.App(.{ .Host = zui_host.Host, .Renderer = SokolRenderer, .Text = zui_truetype.Text, .renderer_name = "sokol" });

/// The window is always shown: the sokol renderer draws only into a window
/// the compositor shows.
pub fn main(init: std.process.Init) !void {
    try zui_app.run(TourOnHost, init, .{ .title = "zui tour (zui_host, sokol)", .size = .{ 1440, 900 } });
}

/// Frames drawn before a screenshot, so it shows a settled layout.
const screenshot_after_frames = 5;

/// The tour, with the screenshot this host's window can give.
const TourOnHost = struct {
    pub const Host = Tour.Host;
    pub const Renderer = Tour.Renderer;
    pub const Text = Tour.Text;

    tour: Tour,
    sources: *zui_tour.Sources,
    gpa: std.mem.Allocator,

    pub fn init(app: *TourOnHost, start: zui_app.Start(TourOnHost)) !void {
        app.sources = &app.tour.tour.sources;
        app.gpa = start.gpa;
        try app.tour.init(Tour.startOf(start));
    }

    pub fn deinit(app: *TourOnHost) void {
        app.tour.deinit();
    }

    pub fn zuiRecord(app: *TourOnHost, record: *zui.RecordBuilder) void {
        app.tour.zuiRecord(record);
    }

    pub fn zuiDeclare(app: *TourOnHost, ui: *Tour.Ui) void {
        app.tour.zuiDeclare(ui);
    }

    pub fn zuiObserve(app: *TourOnHost, ui: *const Tour.Ui, frame: *const Tour.Ui.Frame) void {
        app.tour.zuiObserve(ui, frame);
    }

    pub fn zuiLoader(app: *TourOnHost, ui: *const Tour.Ui, io: std.Io) void {
        app.tour.zuiLoader(ui, io);
        const path = app.tour.options.screenshot_path orelse return;
        if (app.tour.frames != screenshot_after_frames) return;
        if (comptime builtin.os.tag == .windows) {
            capture.saveClientArea(app.gpa, io, app.tour.host.hwnd, path) catch |err| std.log.err("could not save {s}: {t}", .{ path, err });
        } else {
            std.log.err("could not save {s}: this host does not capture its window yet", .{path});
        }
        app.tour.closeHost();
    }
};

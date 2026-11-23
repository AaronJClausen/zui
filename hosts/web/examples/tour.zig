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

/// The text the tour's records carried, in order, for a check to read:
/// what fits of it.
var text_received: [256]u8 = undefined;
var text_received_len: usize = 0;

export fn zuiTourTextReceived() usize {
    return @intFromPtr(&text_received);
}

export fn zuiTourTextReceivedBytes() usize {
    return text_received_len;
}

fn keepTextReceived(record: *const zui.RecordBuilder) void {
    for (record.events()) |event| switch (event) {
        .text => |typed| {
            const kept = @min(typed.len, text_received.len - text_received_len);
            @memcpy(text_received[text_received_len..][0..kept], typed[0..kept]);
            text_received_len += kept;
        },
        else => {},
    };
}

const PastedForCheck = zui.ServiceReply(256);

/// The answers to `zuiTourPasteForCheck`, for a check to read.
const PastesForCheck = struct {
    newest: ?PastedForCheck = null,

    pub fn publish(self: *PastesForCheck, reply: PastedForCheck) zui.Wake {
        self.newest = reply;
        return .needed;
    }
};

var pastes_for_check: PastesForCheck = .{};
const text_copied_for_check = "zui \u{2713} copied from the worker";

/// Copies `text_copied_for_check` through the host, as a check asks: false
/// if the host refused.
export fn zuiTourCopyForCheck() bool {
    const tour = running_tour orelse return false;
    Tour.Host.zuiClipboard.write(tour.host, text_copied_for_check) catch return false;
    return true;
}

/// Reads the clipboard through the host, as a check asks; its answer
/// arrives later, as `zuiTourPastedForCheck` says.
export fn zuiTourPasteForCheck() bool {
    const tour = running_tour orelse return false;
    pastes_for_check.newest = null;
    Tour.Host.zuiClipboard.read(tour.host, .of("check paste"), .of(&pastes_for_check)) catch return false;
    return true;
}

/// The newest paste's text, as a C string, its kind's name if it is not
/// text, or an empty string before it arrives.
export fn zuiTourPastedForCheck() [*:0]const u8 {
    const State = struct {
        var text: [PastedForCheck.capacity + 1]u8 = undefined;
    };
    const pasted = pastes_for_check.newest orelse return "";
    if (pasted.kind != .clipboard_text) return if (pasted.kind == .failed) @tagName(pasted.failure) else @tagName(pasted.kind);
    @memcpy(State.text[0..pasted.len], pasted.text());
    State.text[pasted.len] = 0;
    return State.text[0..pasted.len :0];
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
        keepTextReceived(record);
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

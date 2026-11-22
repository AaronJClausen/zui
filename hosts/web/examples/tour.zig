//! zui's tour in the browser: on `zui_web.Host`, in a dedicated worker
//! that draws through `zui_webgl.Renderer` on the canvas its page
//! transferred, in TrueType fonts. The worker calls `zuiWebRun` once.
//!
//! ```sh
//! zig build tour     # writes the page to zig-out/tour; serve it cross-origin isolated
//! ```

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
    zui_app.runWith(Tour, setup, .{ .title = "zui tour" }) catch |err| zui_web.worker.fail(err);
}

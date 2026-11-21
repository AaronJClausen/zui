//! zui's showcase on this host, drawn by the sokol renderer in TrueType
//! fonts.
//!
//! ```sh
//! zig build showcase                    # interactive window
//! zig build showcase -- --frames 60     # draw 60 frames, then quit
//! ```

const std = @import("std");
const zui_app = @import("zui_app");
const zui_host = @import("zui_host");
const zui_truetype = @import("zui_truetype");
const zui_showcase = @import("zui_showcase");
const SokolRenderer = @import("sokol_renderer.zig").SokolRenderer;

const App = zui_showcase.App(.{ .Host = zui_host.Host, .Renderer = SokolRenderer, .Text = zui_truetype.Text, .title = "zui + sokol" });

/// The window is always shown: the sokol renderer draws only into a window
/// the compositor shows.
pub fn main(init: std.process.Init) !void {
    try zui_app.run(App, init, .{ .title = "zui showcase (zui_host, sokol)" });
}

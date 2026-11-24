//! zui's test card on this host, drawn by the sokol renderer in TrueType
//! fonts, as the tour is.
//!
//! ```sh
//! zig build test-card                          # interactive window, at rest
//! zig build test-card -- --scene focused       # hold one scene
//! zig build test-card -- --frames 6            # draw every scene once, then quit
//! ```

const std = @import("std");
const zui_app = @import("zui_app");
const zui_host = @import("zui_host");
const zui_truetype = @import("zui_truetype");
const zui_test_card = @import("zui_test_card");
const SokolRenderer = @import("sokol_renderer.zig").SokolRenderer;

const App = zui_test_card.App(.{ .Host = zui_host.Host, .Renderer = SokolRenderer, .Text = zui_truetype.Text, .renderer_name = "sokol", .host_name = "zui_host" });

/// The window is always shown, `--hidden` or not: the sokol renderer
/// draws only into a window the compositor shows.
pub fn main(init: std.process.Init) !void {
    const options = try zui_test_card.Options.parse(try init.minimal.args.toSlice(init.arena.allocator()));
    if (options.screenshot_path != null) {
        std.log.err("this host's test card saves no screenshot; raylib's does", .{});
        return error.UnknownArgument;
    }
    try zui_app.run(App, init, .{ .title = "zui test card (zui_host, sokol)", .size = zui_test_card.window_size, .resizable = false });
}

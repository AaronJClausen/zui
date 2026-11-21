//! zui's showcase, run by `zui_app` on raylib's window, in TrueType fonts.
//!
//! ```sh
//! zig build showcase                             # interactive window
//! zig build showcase -- --hidden --frames 60     # draw 60 frames in a hidden window, then quit
//! ```

const std = @import("std");
const zui_app = @import("zui_app");
const zui_raylib = @import("zui_raylib");
const zui_truetype = @import("zui_truetype");
const zui_showcase = @import("zui_showcase");

const App = zui_showcase.App(.{ .Host = zui_raylib.Host, .Renderer = zui_raylib.Renderer, .Text = zui_truetype.Text, .title = "zui + raylib" });

pub fn main(init: std.process.Init) !void {
    const options = try zui_showcase.Options.parse(try init.minimal.args.toSlice(init.arena.allocator()));
    try zui_app.run(App, init, .{ .title = "zui showcase (raylib)", .visible = !options.hidden, .resizable = !options.hidden });
}

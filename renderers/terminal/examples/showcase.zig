//! zui's showcase in this terminal, drawn one glyph per cell.
//!
//! ```sh
//! zig build showcase                  # in this terminal; Ctrl+C or Ctrl+Q quits
//! zig build showcase -- --frames 60   # quit after 60 frames
//! zig build showcase -- --dump        # print three frames' glyphs, with no terminal
//! ```

const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_terminal = @import("zui_terminal");
const zui_truetype = @import("zui_truetype");
const zui_showcase = @import("zui_showcase");
const dump = @import("dump.zig");

const App = zui_showcase.App(.{ .Host = zui_terminal.Host, .Renderer = zui_terminal.Renderer, .Text = zui_truetype.Text, .title = "zui + terminal" });

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (try dump.dumpArguments(init.arena.allocator(), arguments)) |others| {
        if (others.len > 1) {
            std.log.err("--dump takes no other argument", .{});
            return error.UnknownArgument;
        }
        return dumpFrames(init);
    }
    try zui_app.run(App, init, .{ .title = "zui + terminal", .notify = dump.noticeAfterStarting });
}

/// Three frames at 100×30 cells, with the pointer on "Hover me" so the
/// tooltip shows.
fn dumpFrames(init: std.process.Init) !void {
    var text: zui_truetype.Text = .{ .placement = zui_terminal.Renderer.glyph_placement };
    var ui: App.Ui = try .init(init.gpa, init.io, &text);
    defer ui.deinit(init.gpa);
    var showcase = App.newShowcase();
    var cells: dump.Cells = try .init(init.gpa, .{ 100, 30 });
    defer cells.deinit(init.gpa);

    var sampler: zui.InputSampler = .{};
    for (0..3) |frame_index| {
        const now: zui.Instant = .fromNanoseconds(frame_index * std.time.ns_per_s / 60);
        const hover_target = if (ui.rectOf(App.ShowcaseOnUi.ids.hover_me)) |rect| [2]f32{ rect.x + rect.width / 2, rect.y + rect.height / 2 } else null;
        var events: [4]zui.Event = undefined;
        ui.beginFrame(&.{
            .params = .{ .now = now, .viewport = cells.viewport() },
            .events = sampler.sample(now, .{ .pointer = hover_target }, &events),
        });
        showcase.declare(&ui);
        const frame = ui.endFrame();
        defer ui.release(frame);
        cells.draw(showcase.palette.background, frame.commands());
    }
    try cells.print(init.io);
}

//! zui's test card in this terminal, in TrueType fonts laid out one glyph
//! per cell: 80×24 cells.
//!
//! ```sh
//! zig build test-card                            # in this terminal, at rest; Ctrl+C or Ctrl+Q quits
//! zig build test-card -- --scene dialog          # hold one scene
//! zig build test-card -- --dump --frames 6       # print every scene's glyphs once, in turn, with no terminal
//! zig build test-card -- --dump --scene focused  # print one scene's glyphs once it has settled
//! ```

const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_terminal = @import("zui_terminal");
const zui_truetype = @import("zui_truetype");
const zui_test_card = @import("zui_test_card");
const dump = @import("dump.zig");

const App = zui_test_card.App(.{ .Host = zui_terminal.Host, .Renderer = zui_terminal.Renderer, .Text = zui_truetype.Text, .renderer_name = "terminal", .host_name = "terminal" });

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (try dump.dumpArguments(init.arena.allocator(), arguments)) |others| {
        const options = zui_test_card.Options.parse(others) catch |err| {
            std.log.err("{t}; --dump takes --scene <name> and --frames <count>", .{err});
            return err;
        };
        return dumpScenes(init, options);
    }
    try zui_app.run(App, init, .{ .title = "zui test card (terminal)", .notify = dump.noticeAfterStarting });
}

/// Draws the frames `options` ask for into cells without a terminal,
/// printing each scene's glyphs as it leaves it: every scene once, in
/// turn, unless `--scene` holds one, until it settles.
fn dumpScenes(init: std.process.Init, options: zui_test_card.Options) !void {
    const gpa = init.gpa;
    var run = options;
    if (run.frame_limit == null) run.frame_limit = if (run.scene != null) zui_test_card.settling_frames else zui_test_card.Scene.count;
    const frame_count = run.frame_limit.?;

    const text = try gpa.create(App.Text);
    defer gpa.destroy(text);
    try text.init();
    defer text.deinit();
    var ui: App.Ui = try .init(gpa, init.io, text);
    defer ui.deinit(gpa);
    var tokens: App.CardOnUi.Tokens = .{};
    App.CardOnUi.resolveTokens(&tokens, text.fonts);
    var card: App.CardOnUi = undefined;
    card.init(&tokens, .{
        .renderer_name = "terminal",
        .host_name = "none (--dump)",
        .fonts_fingerprint = text.zuiFingerprint(),
        .placement = zui_terminal.Renderer.glyph_placement,
    });
    var cells: dump.Cells = try .init(gpa, .{ 80, 24 });
    defer cells.deinit(gpa);
    var events: [64]zui.Event = undefined;
    var text_bytes: [256]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text_bytes);

    var diagnostics_ok = true;
    for (0..frame_count) |index| {
        const scene = run.sceneOf(index);
        const next = run.sceneOf(index + 1);
        const frame = card.declareWithoutHost(&ui, &builder, scene, next);
        defer ui.release(frame);
        diagnostics_ok = diagnostics_ok and frame.diagnostics.ok();
        cells.draw(card.background(), frame.commands());
        if (index + 1 == frame_count or next != scene) {
            std.log.info("{t}:", .{scene});
            try cells.print(init.io);
        }
    }
    std.log.info("drew {d} frames, diagnostics ok: {}", .{ frame_count, diagnostics_ok });
}

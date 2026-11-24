//! zui's test card, run by `zui_app` on raylib's window, in TrueType fonts.
//!
//! ```sh
//! zig build test-card                                   # interactive window, at rest
//! zig build test-card -- --scene focused                # hold one scene
//! zig build test-card -- --hidden --frames 6            # draw every scene once, in a hidden window, then quit
//! zig build test-card -- --screenshot $PWD/dialog.png --scene dialog  # render offscreen, save a PNG and quit
//! ```

const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_raylib = @import("zui_raylib");
const zui_truetype = @import("zui_truetype");
const zui_test_card = @import("zui_test_card");

const Card = zui_test_card.App(.{ .Host = zui_raylib.Host, .Renderer = zui_raylib.Renderer, .Text = zui_truetype.Text, .renderer_name = "raylib", .host_name = "raylib" });

pub fn main(init: std.process.Init) !void {
    const options = try zui_test_card.Options.parse(try init.minimal.args.toSlice(init.arena.allocator()));
    try zui_app.run(CardOnRaylib, init, .{ .title = "zui test card (raylib)", .size = zui_test_card.window_size, .visible = !options.hidden, .resizable = false });
}

/// The card, with the screenshot raylib's window can give, drawn offscreen.
const CardOnRaylib = struct {
    pub const Host = Card.Host;
    pub const Renderer = Card.Renderer;
    pub const Text = Card.Text;

    card: Card,

    pub fn init(app: *CardOnRaylib, start: zui_app.Start(CardOnRaylib)) !void {
        try app.card.init(Card.startOf(start));
        if (app.card.options.screenshot_path != null) start.renderer.drawOffscreen();
    }

    pub fn deinit(app: *CardOnRaylib) void {
        app.card.deinit();
    }

    pub fn zuiRecord(app: *CardOnRaylib, record: *zui.RecordBuilder) void {
        app.card.zuiRecord(record);
    }

    pub fn zuiDeclare(app: *CardOnRaylib, ui: *Card.Ui) void {
        app.card.zuiDeclare(ui);
    }

    pub fn zuiObserve(app: *CardOnRaylib, ui: *const Card.Ui, frame: *const Card.Ui.Frame) void {
        app.card.zuiObserve(ui, frame);
    }

    /// Takes the screenshot once the scene has settled.
    pub fn zuiLoader(app: *CardOnRaylib, ui: *const Card.Ui, io: std.Io) void {
        app.card.zuiLoader(ui, io);
        const path = app.card.options.screenshot_path orelse return;
        if (app.card.frames != zui_test_card.settling_frames) return;
        app.card.renderer.saveScreenshot(path) catch |err| {
            std.debug.print("could not save {s}: {t}\n", .{ path, err });
            std.process.exit(1);
        };
        std.debug.print("saved {s}\n", .{path});
        app.card.closeHost();
    }
};

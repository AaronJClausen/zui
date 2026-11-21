//! zui's tour in this terminal, in TrueType fonts laid out one glyph per
//! cell. Screens whose commands a terminal does not draw are left out.
//!
//! ```sh
//! zig build tour                                 # in this terminal; Ctrl+C or Ctrl+Q quits
//! zig build tour -- --screen box_storm           # start on one screen
//! zig build tour -- --frames 300 --cycle 30      # visit every screen, 30 frames each, then quit
//! zig build tour -- --dump --screen typography   # print a screen's glyphs, with no terminal
//! zig build tour -- --dump --every-screen        # print every offered screen's, failing on text cut short
//! ```

const std = @import("std");
const zui_app = @import("zui_app");
const zui_terminal = @import("zui_terminal");
const zui_truetype = @import("zui_truetype");
const zui_tour = @import("zui_tour");
const dump = @import("dump.zig");

const App = zui_tour.App(.{ .Host = zui_terminal.Host, .Renderer = zui_terminal.Renderer, .Text = zui_truetype.Text, .renderer_name = "terminal" });

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (try dump.dumpArguments(init.arena.allocator(), arguments)) |others| {
        if (try dump.withoutFlag(init.arena.allocator(), others, "--every-screen")) |program_and_others| {
            if (program_and_others.len > 1) {
                std.log.err("--dump --every-screen takes no other argument", .{});
                return error.UnknownArgument;
            }
            return dumpEveryScreen(init);
        }
        const options = zui_tour.Options.parse(others) catch |err| {
            std.log.err("{t}; --dump takes --screen <name> or --every-screen", .{err});
            return err;
        };
        const screen = options.screen orelse .welcome;
        if (std.mem.indexOfScalar(zui_tour.Screen, App.kit.offered_screens, screen) == null) {
            std.log.err("a terminal does not draw everything {t} needs, so the tour does not offer it", .{screen});
            return error.ScreenNotOffered;
        }
        const lines_cut_short = try dumpScreen(init, screen);
        if (lines_cut_short > 0) {
            logCutShort(screen, lines_cut_short);
            return error.TextCutShort;
        }
        return;
    }
    try zui_app.run(App, init, .{ .title = "zui tour (terminal)", .notify = dump.noticeAfterStarting });
}

/// Frames drawn before the glyphs are printed, so the screen has settled.
const settling_frames = 10;

fn dumpEveryScreen(init: std.process.Init) !void {
    var any_cut_short = false;
    for (App.kit.offered_screens) |screen| {
        std.log.info("{t}:", .{screen});
        const lines_cut_short = try dumpScreen(init, screen);
        if (lines_cut_short > 0) {
            logCutShort(screen, lines_cut_short);
            any_cut_short = true;
        }
    }
    if (any_cut_short) return error.TextCutShort;
}

fn logCutShort(screen: zui_tour.Screen, lines_cut_short: usize) void {
    std.log.err("{t} cuts {d} line(s) of text short at the side of its clip", .{ screen, lines_cut_short });
}

/// Prints `screen` at 180×56 cells, the default window's size in layout
/// units, and returns how many of its last frame's text lines were cut short.
fn dumpScreen(init: std.process.Init, screen: zui_tour.Screen) !usize {
    const gpa = init.gpa;
    const text = try gpa.create(App.Text);
    defer gpa.destroy(text);
    try text.init();
    defer text.deinit();
    var ui: App.Ui = try .init(gpa, init.io, text);
    defer ui.deinit(gpa);
    const tour = try gpa.create(zui_tour.Tour(App.kit));
    defer gpa.destroy(tour);
    tour.init(init.io, .zero, text.fonts);
    defer tour.deinit();
    tour.show(screen);
    var cells: dump.Cells = try .init(gpa, .{ 180, 56 });
    defer cells.deinit(gpa);

    var lines_cut_short: usize = 0;
    for (0..settling_frames) |frame_index| {
        ui.beginFrame(&.{ .params = .{ .now = .fromNanoseconds(frame_index * std.time.ns_per_s / 60), .viewport = cells.viewport() } }, &tour.sources);
        tour.declare(&ui);
        const frame = ui.endFrame();
        defer ui.release(frame);
        tour.observe(&ui, frame);
        tour.afterFrame(&ui);
        cells.draw(zui_tour.Palette.forEnvironment(ui.environment()).background, frame.commands());
        lines_cut_short = cells.countTextLinesCutShort(frame);
    }
    try cells.print(init.io);
    return lines_cut_short;
}

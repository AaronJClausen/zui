//! zui's test card in this terminal, in TrueType fonts laid out one glyph
//! per cell: 80×24 cells.
//!
//! ```sh
//! zig build test-card                            # in this terminal, at rest; Ctrl+C or Ctrl+Q quits
//! zig build test-card -- --scene dialog          # hold one scene
//! zig build test-card -- --dump --frames 6       # print every scene's glyphs once, in turn, with no terminal
//! zig build test-card -- --dump --scene focused  # print one scene's glyphs once it has settled
//! zig build test-card -- --dump --check          # compare every scene's cells with its approved snapshot
//! zig build test-card -- --dump --approve        # write every scene's snapshot again
//! ```
//!
//! The build step names the card's `snapshots/` directory in
//! `--snapshots <dir>` when `--check` or `--approve` is given.

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
    const arena = init.arena.allocator();
    if (try dump.dumpArguments(arena, arguments)) |dump_arguments| {
        var others = dump_arguments;
        var action: ?SnapshotAction = null;
        inline for (comptime std.enums.values(SnapshotAction)) |candidate| {
            if (try dump.withoutFlag(arena, others, "--" ++ @tagName(candidate))) |rest| {
                others = rest;
                action = candidate;
            }
        }
        var snapshots_path: ?[]const u8 = null;
        if (try dump.withoutOption(arena, others, "--snapshots")) |found| {
            snapshots_path = found.value;
            others = found.others;
        }
        const options = zui_test_card.Options.parse(others) catch |err| {
            std.log.err("{t}; --dump takes --scene <name>, --frames <count>, --check or --approve, and --snapshots <dir>", .{err});
            return err;
        };
        if (action) |snapshot_action| {
            const path = snapshots_path orelse {
                std.log.err("--{t} needs --snapshots <dir>, the test card's snapshots/ directory, which zig build test-card passes", .{snapshot_action});
                return error.MissingSnapshotsDirectory;
            };
            return checkOrApproveSnapshots(init, options, snapshot_action, path);
        }
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
    card.init(&tokens, dumpIdentity(text));
    var cells: dump.Cells = try .init(gpa, .{ columns, rows });
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

fn dumpIdentity(text: *App.Text) zui_test_card.Identity {
    return .{
        .renderer_name = "terminal",
        .host_name = "none (--dump)",
        .fonts_fingerprint = text.zuiFingerprint(),
        .placement = zui_terminal.Renderer.glyph_placement,
    };
}

const SnapshotAction = enum { check, approve };

const columns = 80;
const rows = 24;

/// The card's regions by their rectangles in a frame, which a differing
/// cell is named by.
pub const Regions = [std.enums.values(zui_test_card.Region).len]zui_terminal.SnapshotRegion;

/// Checks the cells of every scene, or of `options.scene`, each drawn from
/// a card of its own once it settles, against its approved snapshot in
/// `snapshots_path`, or writes them there.
fn checkOrApproveSnapshots(init: std.process.Init, options: zui_test_card.Options, action: SnapshotAction, snapshots_path: []const u8) !void {
    const gpa = init.gpa;
    var directory = try std.Io.Dir.cwd().openDir(init.io, snapshots_path, .{});
    defer directory.close(init.io);
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const text = try gpa.create(App.Text);
    defer gpa.destroy(text);
    try text.init();
    defer text.deinit();
    var cells: dump.Cells = try .init(gpa, .{ columns, rows });
    defer cells.deinit(gpa);
    var approved: zui_terminal.CellBuffer = .{};
    defer approved.deinit(gpa);
    try approved.resize(gpa, columns, rows);
    var written: std.Io.Writer.Allocating = .init(gpa);
    defer written.deinit();

    const scenes: []const zui_test_card.Scene = if (options.scene) |held| &.{held} else std.enums.values(zui_test_card.Scene);
    var diagnostics_ok = true;
    var differing_scenes: usize = 0;
    for (scenes) |scene| {
        var regions: Regions = undefined;
        diagnostics_ok = try drawSettledScene(init, text, scene, &cells, &regions) and diagnostics_ok;
        var name_buffer: [64]u8 = undefined;
        const name = try snapshotFileName(&name_buffer, scene);
        switch (action) {
            .approve => {
                written.clearRetainingCapacity();
                try zui_terminal.writeSnapshot(&cells.buffer, &written.writer);
                try directory.writeFile(init.io, .{ .sub_path = name, .data = written.written() });
                try stdout.print("wrote {s}\n", .{name});
            },
            .check => if (!try matchesApprovedSnapshot(init.io, gpa, directory, scene, &cells, &regions, &approved, stdout)) {
                differing_scenes += 1;
            },
        }
    }
    try stdout.flush();
    if (differing_scenes != 0) {
        std.log.err("{d} of {d} scenes differ from their snapshots in {s}; zig build test-card -- --dump --approve writes them again", .{ differing_scenes, scenes.len, snapshots_path });
        return error.SnapshotsDiffer;
    }
    if (action == .check) std.log.info("the cells of {d} of {d} scenes match their snapshots in {s}", .{ scenes.len, scenes.len, snapshots_path });
    std.log.info("drew {d} frames, diagnostics ok: {}", .{ scenes.len * zui_test_card.settling_frames, diagnostics_ok });
}

/// The file the card's `snapshots/` holds `scene`'s cells in: `rest.terminal.txt`.
pub fn snapshotFileName(buffer: []u8, scene: zui_test_card.Scene) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "{t}.terminal.txt", .{scene});
}

/// Draws `scene` into `cells` from a card and a context of its own, held
/// until it settles, and fills `regions` from its last frame. Returns
/// whether every frame's diagnostics were clean.
pub fn drawSettledScene(init: std.process.Init, text: *App.Text, scene: zui_test_card.Scene, cells: *dump.Cells, regions: *Regions) !bool {
    var ui: App.Ui = try .init(init.gpa, init.io, text);
    defer ui.deinit(init.gpa);
    var tokens: App.CardOnUi.Tokens = .{};
    App.CardOnUi.resolveTokens(&tokens, text.fonts);
    var card: App.CardOnUi = undefined;
    card.init(&tokens, dumpIdentity(text));
    var events: [64]zui.Event = undefined;
    var text_bytes: [256]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text_bytes);

    var diagnostics_ok = true;
    for (1..zui_test_card.settling_frames) |_| {
        const frame = card.declareWithoutHost(&ui, &builder, scene, scene);
        diagnostics_ok = diagnostics_ok and frame.diagnostics.ok();
        ui.release(frame);
    }
    const frame = card.declareWithoutHost(&ui, &builder, scene, scene);
    defer ui.release(frame);
    cells.draw(card.background(), frame.commands());
    for (regions, std.enums.values(zui_test_card.Region)) |*region, card_region| {
        region.* = .{ .name = @tagName(card_region), .rect = frame.rectOf(card_region.id()) orelse .{} };
    }
    return diagnostics_ok and frame.diagnostics.ok();
}

/// Compares `drawn`, `scene`'s cells, with its approved snapshot in
/// `directory`, read into `approved`, a buffer of their size. Writes to
/// `writer` the cells that differ, each with the region of `regions`
/// holding it, and returns whether every cell looks alike.
pub fn matchesApprovedSnapshot(
    io: std.Io,
    gpa: std.mem.Allocator,
    directory: std.Io.Dir,
    scene: zui_test_card.Scene,
    drawn: *const dump.Cells,
    regions: *const Regions,
    approved: *zui_terminal.CellBuffer,
    writer: *std.Io.Writer,
) !bool {
    var name_buffer: [64]u8 = undefined;
    const name = try snapshotFileName(&name_buffer, scene);
    const approved_text = directory.readFileAlloc(io, name, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.print("{t}: no approved snapshot {s}\n", .{ scene, name });
            return false;
        },
        else => return err,
    };
    defer gpa.free(approved_text);
    zui_terminal.readSnapshot(approved, approved_text) catch |err| {
        try writer.print("{t}: {s} is not a snapshot of {d}x{d} cells ({t})\n", .{ scene, name, drawn.buffer.columns, drawn.buffer.rows, err });
        return false;
    };
    var differences: std.Io.Writer.Allocating = .init(gpa);
    defer differences.deinit();
    const differing = try zui_terminal.writeSnapshotDifferences(&differences.writer, approved, &drawn.buffer, drawn.cell_size, regions, shown_differences);
    if (differing == 0) return true;
    try writer.print("{t}: {d} cells differ from {s}:\n{s}", .{ scene, differing, name, differences.written() });
    return false;
}

const shown_differences = 20;

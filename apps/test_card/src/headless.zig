const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_glyphs = @import("zui_glyphs");
const zui_testing = @import("zui_testing");
const zui_truetype = @import("zui_truetype");
const test_card = @import("zui_test_card");

pub const cells: zui_glyphs.Placement = .{ .cells = .{ 8, 16 } };

/// Draws nothing, and declares that it draws every optional command and
/// corner shape, or none of them but round corners, in `placement`.
pub fn FakeRenderer(comptime draws_every_command: bool, comptime placement: zui_glyphs.Placement) type {
    return struct {
        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const zui_commands: zui.CommandSet = if (draws_every_command) .initFull() else .initEmpty();
        pub const zui_corner_shapes: zui.CornerShapeSet = if (draws_every_command) .initFull() else .initOne(.round);
        pub const MaterialHandle = if (draws_every_command) FlatMaterial else void;
        pub const glyph_placement = placement;

        clear_color: zui.Color = .black,

        pub fn zuiSubmit(_: *@This(), _: zui.Surface, _: anytype) !void {}
    };
}

/// A renderer's own material, which the card never draws.
const FlatMaterial = struct { color: zui.Color };

/// The card without a host: its text measures, and nothing is drawn. It
/// keeps pointers into itself, so it is initialized where it stays.
pub fn Harness(comptime Renderer: type) type {
    return struct {
        const Self = @This();
        pub const Text = test_card.Text(zui_truetype.Text, Renderer);
        pub const Ui = zui.Context(zui_app.contextConfig(Renderer, .{ .Text = Text }));
        const CardOnUi = test_card.Card(Ui);

        gpa: std.mem.Allocator = undefined,
        text: Text = .{},
        ui: Ui = undefined,
        tokens: CardOnUi.Tokens = .{},
        card: CardOnUi = undefined,
        events: [64]zui.Event = undefined,
        text_bytes: [256]u8 = undefined,
        builder: zui.RecordBuilder = undefined,

        pub fn init(harness: *Self, gpa: std.mem.Allocator, io: std.Io) !void {
            harness.gpa = gpa;
            try harness.text.init();
            harness.ui = try .init(gpa, io, &harness.text);
            CardOnUi.resolveTokens(&harness.tokens, harness.text.fonts);
            harness.card.init(&harness.tokens, .{
                .renderer_name = "a fake renderer",
                .host_name = "no host",
                .fonts_fingerprint = harness.text.zuiFingerprint(),
                .placement = zui_glyphs.placementOf(Renderer),
            });
            harness.builder = .init(&harness.events, &harness.text_bytes);
        }

        pub fn deinit(harness: *Self) void {
            harness.ui.deinit(harness.gpa);
            harness.text.deinit();
        }

        pub fn frame(harness: *Self, scene: test_card.Scene, next: test_card.Scene) *const Ui.Frame {
            return harness.card.declareWithoutHost(&harness.ui, &harness.builder, scene, next);
        }

        /// `scene` held for the frames it takes to settle; the caller
        /// releases the last.
        pub fn heldFrame(harness: *Self, scene: test_card.Scene) *const Ui.Frame {
            for (1..test_card.settling_frames) |_| harness.ui.release(harness.frame(scene, scene));
            return harness.frame(scene, scene);
        }

        /// `drawn`, a scene held from the card's first frame, as
        /// `zig build approve` writes it to `snapshots/`: in
        /// `zui_truetype`'s text, its glyphs rasterized into an atlas as a
        /// renderer on the pixel grid does.
        pub fn writeSnapshot(harness: *Self, writer: *std.Io.Writer, drawn: *const Ui.Frame) !void {
            const placement = zui_glyphs.placementOf(Renderer);
            try zui_testing.writeFrameSnapshot(writer, drawn, snapshot_names, .{
                .placement = .of(placement),
                .fonts_fingerprint = harness.text.zuiFingerprint(),
                .glyph_coverage = if (placement == .pixel_grid) try glyphCoverage(harness.gpa, harness.text.glyphFonts(), drawn) else null,
            });
        }
    };
}

/// Where the card's snapshots are taken, each on a renderer that draws
/// every optional command, and the middle of each snapshot's name.
pub const SnapshotPlacement = enum {
    pixels,
    cells,

    pub fn Renderer(comptime placement: SnapshotPlacement) type {
        return switch (placement) {
            .pixels => FakeRenderer(true, .pixel_grid),
            .cells => FakeRenderer(true, cells),
        };
    }
};

/// The file `snapshots/` holds `scene`'s snapshot in: `rest.pixels.txt`.
pub fn snapshotFileName(buffer: []u8, scene: test_card.Scene, placement: SnapshotPlacement) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "{t}.{t}.txt", .{ scene, placement });
}

/// The card's regions, by their rectangles in `frame`, which a snapshot's
/// differences are named by.
pub fn regionsOf(frame: anytype) [std.enums.values(test_card.Region).len]zui_testing.SnapshotRegion {
    var regions: [std.enums.values(test_card.Region).len]zui_testing.SnapshotRegion = undefined;
    for (&regions, std.enums.values(test_card.Region)) |*region, card_region| {
        region.* = .{ .name = @tagName(card_region), .rect = frame.rectOf(card_region.id()) orelse .{} };
    }
    return regions;
}

/// The card's regions and the elements its scenes reach, by name.
const snapshot_names = names: {
    const regions = std.enums.values(test_card.Region);
    const element_fields = @typeInfo(@TypeOf(test_card.ids)).@"struct".fields;
    const overlays = .{
        .{ "tooltip", test_card.ids.tooltip_anchor.child("tooltip") },
        .{ "dialog_panel", test_card.ids.dialog.child("panel") },
    };
    const count = regions.len + element_fields.len + overlays.len;
    var field_names: [count][]const u8 = undefined;
    var ids: [count]zui.Id = undefined;
    for (regions, 0..) |region, index| {
        field_names[index] = @tagName(region);
        ids[index] = region.id();
    }
    for (element_fields, regions.len..) |field, index| {
        field_names[index] = field.name;
        ids[index] = @field(test_card.ids, field.name);
    }
    for (overlays, regions.len + element_fields.len..) |overlay, index| {
        field_names[index] = overlay[0];
        ids[index] = overlay[1];
    }
    const types: [count]type = @splat(zui.Id);
    var attributes: [count]std.builtin.Type.StructField.Attributes = undefined;
    for (&attributes, ids) |*attribute, id| {
        const default: zui.Id = id;
        attribute.* = .{ .default_value_ptr = &default };
    }
    break :names @as(@Struct(.auto, null, &field_names, &types, &attributes), .{});
};

/// Every glyph `frame`'s text needs, rasterized from `fonts` into an atlas
/// in the order a renderer adds them, and the hash of the atlas.
fn glyphCoverage(gpa: std.mem.Allocator, fonts: zui_glyphs.Fonts, frame: anytype) !zui_testing.GlyphCoverage {
    const atlas = try zui_glyphs.Atlas(.rg8).create(gpa);
    defer atlas.destroy(gpa);
    atlas.addFrameGlyphs(fonts, frame.commands(), frame.params.scale * frame.params.zoom);
    if (atlas.overflows != 0 or atlas.raster_refusals != 0) return error.GlyphsLeftOut;
    return .{ .glyph_count = atlas.glyph_count, .hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&atlas.texels)) };
}

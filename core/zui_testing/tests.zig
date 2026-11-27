const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing.zig");

const testing = std.testing;

test "a frame read back bottom row first is read from the top left" {
    const ReadBack = zui_testing.ReadBack(.sdr);
    const read_back = try testing.allocator.create(ReadBack);
    defer testing.allocator.destroy(read_back);
    read_back.* = .{ .rows = .bottom_up };
    @memset(read_back.bytes(), 0);
    read_back.texels[(ReadBack.height - 1) * ReadBack.width + 3] = .{ 0x10, 0x20, 0x30, 0x40 };

    try testing.expectEqual(zui.Color{ .r = 0x10, .g = 0x20, .b = 0x30, .a = 0x40 }, read_back.pixel(3, 0));
    try testing.expectEqual(zui.Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, read_back.pixel(3, ReadBack.height - 1));

    read_back.rows = .top_down;
    try testing.expectEqual(zui.Color{ .r = 0x10, .g = 0x20, .b = 0x30, .a = 0x40 }, read_back.pixel(3, ReadBack.height - 1));
}

test "a frame read back in floats is read as linear extended colors, its bytes covering every texel" {
    const ReadBack = zui_testing.ReadBack(.scrgb_fp16);
    const read_back = try testing.allocator.create(ReadBack);
    defer testing.allocator.destroy(read_back);
    read_back.* = .{ .rows = .top_down };
    try testing.expectEqual(@as(usize, ReadBack.width * ReadBack.height * 4 * @sizeOf(f32)), read_back.bytes().len);
    read_back.texels[2 * ReadBack.width + 5] = .{ 4, 2, 1, 0.5 };

    try testing.expectEqual(zui.ExtendedColor.linear(4, 2, 1, 0.5), read_back.pixel(5, 2));
}

const TwoWindowHost = struct {
    second_window_open: bool = true,

    pub fn zuiPoll(self: *TwoWindowHost, window: zui.WindowId, record: *zui.RecordBuilder) bool {
        if (window != .main and !self.second_window_open) return false;
        record.begin(.{ .now = .zero, .viewport = .{ 320, 240 } });
        record.append(.{ .key_down = .{ .key = if (window == .main) .h else .i, .at = .zero } });
        record.appendText("hi");
        record.append(.{ .key_down = .{ .key = .enter, .at = .zero } });
        return true;
    }
};

test "a polled record finds the first event of each kind from the window it polled" {
    var host: TwoWindowHost = .{};
    var polled: zui_testing.PolledRecord = .{};
    polled.init();

    try testing.expect(polled.poll(&host));
    try testing.expectEqual(zui.Key.h, polled.find(.key_down).?.key);
    try testing.expectEqualStrings("hi", polled.find(.text).?);
    try testing.expectEqual(null, polled.find(.pointer_move));

    const second: zui.WindowId = @enumFromInt(1);
    try testing.expect(polled.pollWindow(&host, second));
    try testing.expectEqual(zui.Key.i, polled.find(.key_down).?.key);

    host.second_window_open = false;
    try testing.expect(!polled.pollWindow(&host, second));
}

const SnapshotUi = zui.Context(.{ .Text = zui_testing.FixedMetricsText(u16) });

const Toolbar = struct {
    const ids = zui.ids(.{ "toolbar", "save" });

    fn declare(_: *Toolbar, ui: *SnapshotUi) void {
        ui.open(.{ .id = ids.toolbar, .decoration = .{ .background = .rgb(0x202028) }, .layout = .{ .padding = .all(8) } });
        ui.box(.{ .id = ids.save, .decoration = .{ .background = .rgb(0x3366ff) }, .layout = .{ .sizing = .{ .width = .fixed(40.3), .height = .fixed(20) } } });
        ui.close();
    }
};

test "a frame snapshot heads its commands with its viewport, placement, fonts and glyphs" {
    var text: zui_testing.FixedMetricsText(u16) = .{};
    var ui: SnapshotUi = try .init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);
    var driver: zui_testing.Driver(SnapshotUi) = .{ .ui = &ui, .viewport = .{ 640, 384 }, .scale = 2 };
    var toolbar: Toolbar = .{};
    const frame = try driver.frame(&toolbar, Toolbar.declare, &.{});

    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    try zui_testing.writeFrameSnapshot(&written.writer, frame, Toolbar.ids, .{
        .placement = .pixel_grid,
        .fonts_fingerprint = 0x0123456789abcdef,
        .glyph_coverage = .{ .glyph_count = 87, .hash = 0xfeed },
    });
    try testing.expectEqualStrings(
        \\viewport 640x384, 2 pixels a unit
        \\placement pixel_grid
        \\fonts 0123456789abcdef
        \\glyphs 87, coverage 000000000000feed
        \\rectangle id=toolbar x=0 y=0 w=56.5 h=36 color=#202028
        \\rectangle id=save x=8 y=8 w=40.5 h=20 color=#3366ff
        \\
    , written.written());

    written.clearRetainingCapacity();
    try zui_testing.writeFrameSnapshot(&written.writer, frame, .{}, .{
        .placement = .{ .cells = .{ 8, 16 } },
        .fonts_fingerprint = 0xabc,
        .glyph_coverage = null,
    });
    try testing.expect(std.mem.startsWith(u8, written.written(),
        \\viewport 640x384, 2 pixels a unit
        \\placement cells 8x16
        \\fonts 0000000000000abc
        \\glyphs not rasterized
        \\rectangle x=0 y=0
    ));
}

test "a snapshot rounds to 1/64 unit, and never writes negative zero" {
    const Command = zui.Context(.{ .limits = .{ .max_elements = 8 } }).RenderCommand;
    const commands = [_]Command{
        .{ .bounds = .{ .x = 0.3, .y = -0.001, .width = 10.01, .height = 1.0 / 3.0 }, .id = 1, .payload = .{ .rectangle = .{ .color = .white, .corner_radius = .all(2.01) } } },
    };
    try zui_testing.expectSnapshot(&commands, .{},
        \\rectangle x=0.296875 y=0 w=10.015625 h=0.328125 color=#ffffff radius=2.015625
        \\
    );
}

test "a placement with a pixel grid and cells is a snapshot's placement" {
    const Placement = union(enum) { pixel_grid, cells: [2]f32 };
    try testing.expectEqual(zui_testing.SnapshotPlacement.pixel_grid, zui_testing.SnapshotPlacement.of(@as(Placement, .pixel_grid)));
    try testing.expectEqual(zui_testing.SnapshotPlacement{ .cells = .{ 8, 16 } }, zui_testing.SnapshotPlacement.of(Placement{ .cells = .{ 8, 16 } }));
}

const card_regions = [_]zui_testing.SnapshotRegion{
    .{ .name = "text", .rect = .{ .x = 0, .y = 96, .width = 320, .height = 208 } },
    .{ .name = "geometry", .rect = .{ .x = 0, .y = 304, .width = 320, .height = 80 } },
    .{ .name = "heading", .rect = .{ .x = 8, .y = 112, .width = 100, .height = 32 } },
};

const approved_card =
    \\viewport 640x384, 1 pixels a unit
    \\rectangle x=0 y=0 w=640 h=384 color=#ffffff
    \\text x=12 y=120 w=40 h=16 size=16 color=#000000 "Hxgjpqy"
    \\border x=8 y=300 w=40 h=10 color=#000000 widths=1
    \\clip_end
    \\
;

test "snapshots that differ name each differing line and the smallest region holding it, else the one holding its center" {
    const drawn =
        \\viewport 640x384, 2 pixels a unit
        \\rectangle x=0 y=0 w=640 h=384 color=#ffffff
        \\text x=12 y=121 w=40 h=16 size=16 color=#000000 "Hxgjpqy"
        \\border x=8 y=301 w=40 h=10 color=#000000 widths=1
        \\clip_end
        \\rectangle x=700 y=0 w=8 h=8 color=#ffffff
        \\
    ;
    var differences = zui_testing.snapshotDifferences(approved_card, drawn, &card_regions);
    const header = differences.next().?;
    try testing.expectEqual(1, header.line_number);
    try testing.expectEqual(zui_testing.SnapshotDifference.Place.no_bounds, header.place);
    const text_line = differences.next().?;
    try testing.expectEqual(3, text_line.line_number);
    try testing.expectEqualStrings("heading", text_line.place.region);
    try testing.expectEqualStrings(
        \\text x=12 y=120 w=40 h=16 size=16 color=#000000 "Hxgjpqy"
    , text_line.expected.?);
    try testing.expectEqualStrings("geometry", differences.next().?.place.region);
    const added = differences.next().?;
    try testing.expectEqual(6, added.line_number);
    try testing.expectEqualStrings("", added.expected.?);
    try testing.expectEqual(zui_testing.SnapshotDifference.Place.outside_every_region, added.place);
    const past_the_end = differences.next().?;
    try testing.expectEqual(null, past_the_end.expected);
    try testing.expectEqualStrings("", past_the_end.actual.?);
    try testing.expectEqual(null, differences.next());
}

test "a snapshot that matches passes, and one that differs fails" {
    try zui_testing.expectSnapshotMatches(approved_card, approved_card, &card_regions);
    var written: [256]u8 = undefined;
    const moved = try std.fmt.bufPrint(&written, "{s}", .{approved_card});
    moved[std.mem.indexOf(u8, moved, "y=120").? + 4] = '1';
    var differences = zui_testing.snapshotDifferences(approved_card, moved, &card_regions);
    var line: [256]u8 = undefined;
    try testing.expectEqualStrings(
        \\line 3, in the `heading` region:
        \\  expected: text x=12 y=120 w=40 h=16 size=16 color=#000000 "Hxgjpqy"
        \\  actual:   text x=12 y=121 w=40 h=16 size=16 color=#000000 "Hxgjpqy"
        \\
    , try std.fmt.bufPrint(&line, "{f}", .{differences.next().?}));
    try testing.expectEqual(null, differences.next());
}

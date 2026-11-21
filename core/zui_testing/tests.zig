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

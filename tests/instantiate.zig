//! `zig build check` compiles this for the selected target. zui's code is
//! generic, and generic code is only type-checked once instantiated, so
//! this drives one full frame through every declaration function.

const std = @import("std");
const zui = @import("zui");

const CheckPlatform = struct {
    pub fn measureText(_: *CheckPlatform, text: []const u8, _: u16, size: f32) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * size / 2, size };
    }
    pub fn scale(_: *const CheckPlatform) f32 {
        return 2;
    }
};

const Ui = zui.Context(.{ .max_elements = 64, .CustomData = u32, .ImageHandle = u32 }, CheckPlatform);

var platform: CheckPlatform = .{};
var memory: [Ui.required_bytes]u8 align(16) = undefined;

export fn zuiCheckFrame(width: f32, height: f32) usize {
    var ui = Ui.initBuffer(&memory, undefined, &platform) catch return 0;
    ui.beginFrame(.{ .viewport = .{ width, height } });
    ui.open(.{ .id = .of("root"), .layout = .{ .sizing = .grow_both, .padding = .all(4), .child_gap = 2 }, .background = .white, .border = .{ .color = .black, .widths = .all(1) } });
    ui.text("check every pass", .{ .wrap = .words, .alignment = .center });
    ui.image(1, .{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .percent(0.5) } } });
    ui.custom(2, .{ .id = .indexed("cell", 3) });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .growBetween(0, 40) } } });
    ui.close();
    const frame = ui.endFrame() catch ui.lastFrame();
    defer ui.release(frame);
    return frame.commands().len;
}

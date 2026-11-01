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

const Expanded = struct { open: bool };

export fn zuiCheckFrame(width: f32, height: f32, pointer_x: f32, pointer_y: f32) usize {
    var ui = Ui.initBuffer(&memory, undefined, &platform) catch return 0;
    ui.beginFrame(.{
        .viewport = .{ width, height },
        .pointer = .{ pointer_x, pointer_y },
        .buttons = .initOne(.primary),
        .wheel = .{ 0, 10 },
        .keys_pressed = &.{ .tab, .enter },
        .modifiers = .{ .shift = true },
        .text_input = "x",
    });
    const save: zui.Id = .of("save");
    const list: zui.Id = .of("list");
    ui.open(.{ .id = .of("root"), .layout = .{ .sizing = .grow_both, .padding = .all(4), .child_gap = 2 }, .background = .white, .border = .{ .color = .black, .widths = .all(1) } });
    ui.text("check every pass", .{ .wrap = .words, .alignment = .center });
    ui.image(1, .{ .layout = .{ .sizing = .{ .width = .fixed(8), .height = .percent(0.5) } } });
    ui.custom(2, .{ .id = .indexed("cell", 3) });
    ui.box(.{ .id = save, .focusable = true, .background = if (ui.widgetState(save) == .hovered) .black else .white, .layout = .{ .sizing = .{ .width = .growBetween(0, 40) } } });
    ui.open(.{ .id = list, .scroll = .both, .focus_scope = true, .layout = .{ .sizing = .{ .width = .fixed(50), .height = .fixed(20) } } });
    ui.box(.{ .clip = .both, .disabled = ui.clicked(save) or ui.pressed(save) or ui.focused(save), .layout = .{ .sizing = .{ .width = .fixed(80), .height = .fixed(80) } } });
    ui.box(.{ .floating = .{ .attach_to = .{ .element = save }, .anchor = .center, .z = 2 }, .interactive = true });
    ui.close();
    ui.close();
    ui.state(save, Expanded).open = ui.keyPressed(.enter) and ui.modifiers().shift and ui.typedText().len == 1;
    ui.setScrollOffset(list, ui.scrollOffset(list));
    ui.requestFocus(save);
    _ = ui.pointerLocal(save);
    _ = ui.rectOf(list);
    _ = ui.stateIfPresent(list, Expanded);
    const frame = ui.endFrame() catch ui.lastFrame();
    defer ui.release(frame);
    return frame.commands().len;
}

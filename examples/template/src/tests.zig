const std = @import("std");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_truetype = @import("zui_truetype");
const Counter = @import("counter.zig").Counter;

const testing = std.testing;
const Ui = zui.Context(.{ .Text = zui_truetype.Text });
const App = Counter(Ui);

fn drawsText(frame: *const Ui.Frame, content: []const u8) bool {
    for (frame.commands()) |command| {
        if (command.payload == .text and std.mem.eql(u8, command.payload.text.content, content)) return true;
    }
    return false;
}

test "clicking the button counts the click, and Reset clears the count" {
    var text: zui_truetype.Text = .{};
    var app: App = .{};
    try app.addFonts(&text);
    var ui: Ui = try .init(testing.allocator, testing.io, &text);
    defer ui.deinit(testing.allocator);
    var driver: zui_testing.Driver(Ui) = .{ .ui = &ui };

    try testing.expect(drawsText(try driver.frame(&app, App.declare, &.{}), "0 clicks"));
    _ = try driver.click(&app, App.declare, App.increment_id);
    try testing.expectEqual(1, app.count);
    try testing.expect(drawsText(try driver.frame(&app, App.declare, &.{}), "1 click"));

    _ = try driver.click(&app, App.declare, App.reset_id);
    try testing.expectEqual(0, app.count);
}

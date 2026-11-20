const std = @import("std");
const zui_terminal = @import("zui_terminal");
const zui = @import("zui");
const zui_testing = @import("zui_testing");
const zui_app = @import("zui_app");

/// Draws into a screen it never shows, and reads each pixel back as the
/// cell that covers it: a cell holding a glyph shows its foreground, an
/// empty one its background.
const ScreenHarness = struct {
    pub const config = zui_terminal.config(.{});

    discarded: std.Io.Writer.Discarding,
    drawn: zui_terminal.Renderer,
    text_contract: zui_terminal.Text = .{},

    fn init(self: *ScreenHarness, gpa: std.mem.Allocator, buffer: []u8) void {
        self.* = .{ .discarded = .init(buffer), .drawn = .{ .gpa = gpa } };
    }

    fn deinit(self: *ScreenHarness) void {
        self.drawn.deinit();
    }

    pub fn renderer(self: *ScreenHarness) *zui_terminal.Renderer {
        return &self.drawn;
    }

    pub fn text(self: *ScreenHarness) *zui_terminal.Text {
        return &self.text_contract;
    }

    pub fn beginDraw(self: *ScreenHarness, size: [2]u32) zui.Surface {
        const cell_size = self.drawn.cell_size;
        return .{ .terminal = .{
            .columns = @intFromFloat(@as(f32, @floatFromInt(size[0])) / cell_size[0]),
            .rows = @intFromFloat(@as(f32, @floatFromInt(size[1])) / cell_size[1]),
            .output = &self.discarded.writer,
        } };
    }

    pub fn pixel(self: *ScreenHarness, x: u32, y: u32) zui.Color {
        const cell_size = self.drawn.cell_size;
        const column: i32 = @intFromFloat(@as(f32, @floatFromInt(x)) / cell_size[0]);
        const row: i32 = @intFromFloat(@as(f32, @floatFromInt(y)) / cell_size[1]);
        const cell = self.drawn.screen.back.at(column, row);
        return if (cell.codepoint == ' ') cell.background else cell.foreground;
    }
};

test "the renderer passes zui's renderer suite" {
    var discard_buffer: [256]u8 = undefined;
    var harness: ScreenHarness = undefined;
    harness.init(std.testing.allocator, &discard_buffer);
    defer harness.deinit();
    try zui_testing.expectRendererConforms(zui_terminal.Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io, .tolerance = 0 });
}

test "the host, its renderer and its text make a zui_app application" {
    const App = struct {
        pub const Host = zui_terminal.Host;
        pub const Renderer = zui_terminal.Renderer;
        pub const Text = zui_terminal.Text;
        const Ui = zui.Context(zui_terminal.config(.{ .limits = .{ .max_elements = 8 } }));

        pub fn zuiDeclare(_: *@This(), _: *Ui) void {}
    };
    comptime zui_app.checkApp(App);
    _ = zui_app.Runner(App);
}

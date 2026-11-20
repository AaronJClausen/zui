const std = @import("std");
const zui = @import("zui");
const Terminal = @import("terminal.zig").Terminal;
const InputDecoder = @import("input.zig").InputDecoder;

/// zui's host contract on the terminal the process runs in: raw mode on
/// the alternate screen, input decoded from the bytes the terminal sends,
/// waits until input, a resize, a wake or the instant `nextFrame` names.
/// Its surface is `.terminal`: the window's size in cells and a writer on
/// stdout, which `zui_terminal.Renderer` draws through. Ctrl+C and Ctrl+Q
/// close it. The window's title, size and visibility are the terminal's
/// own.
///
/// ```zig
/// const App = struct {
///     pub const Host = zui_terminal.Host;
///     pub const Renderer = zui_terminal.Renderer;
///     pub const Text = zui_terminal.Text;
///     // ...
/// };
/// ```
pub const Host = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.terminal);
    pub const zui_capabilities: zui.HostCapabilities = .{};

    io: std.Io,
    terminal: Terminal,
    /// Its `cell_size`, the layout units of a cell, must be `Text.cell_size`:
    /// set it from the application's `init` when that is not the default.
    decoder: InputDecoder = .{},
    output: std.Io.File.Writer,
    output_buffer: [64 * 1024]u8 = undefined,
    read_buffer: [4096]u8 = undefined,

    pub fn init(self: *Host, io: std.Io, window: zui.WindowOptions) !void {
        _ = window;
        self.* = .{ .io = io, .terminal = try Terminal.enter(io), .output = undefined };
        self.output = std.Io.File.stdout().writer(io, &self.output_buffer);
    }

    pub fn deinit(self: *Host) void {
        self.terminal.leave();
        self.* = undefined;
    }

    pub fn zuiPoll(self: *Host, window: zui.WindowId, record: *zui.RecordBuilder) bool {
        std.debug.assert(window == .main);
        const at = self.terminal.now();
        self.decoder.feed(self.terminal.readAvailable(&self.read_buffer), at);
        return self.recordDecoded(at, self.terminal.size(), record);
    }

    /// Ends a wait from any thread; a wake while the loop is not waiting
    /// ends its next one.
    pub fn zuiWaker(self: *Host) zui.Waker {
        return self.terminal.waker();
    }

    pub fn zuiWait(self: *Host, next: zui.NextFrame) void {
        self.terminal.wait(next);
    }

    pub fn zuiSurface(self: *Host, window: zui.WindowId) zui.Surface {
        std.debug.assert(window == .main);
        return self.terminal.surface(&self.output.interface);
    }

    /// A terminal has no cursor shapes and no IME window to place.
    pub fn zuiApply(_: *Host, window: zui.WindowId, _: zui.HostRequests) void {
        std.debug.assert(window == .main);
    }

    fn recordDecoded(self: *Host, at: zui.Instant, size_in_cells: [2]u16, record: *zui.RecordBuilder) bool {
        if (self.decoder.quit_requested) return false;
        const cell_size = self.decoder.cell_size;
        record.begin(.{ .now = at, .viewport = .{
            @as(f32, @floatFromInt(size_in_cells[0])) * cell_size[0],
            @as(f32, @floatFromInt(size_in_cells[1])) * cell_size[1],
        } });
        record.dropped_events +|= self.decoder.dropped_events;
        for (self.decoder.take()) |event| switch (event) {
            .text => |text| record.appendText(text),
            else => record.append(event),
        };
        return true;
    }
};

fn testHost() Host {
    return .{ .io = std.testing.io, .terminal = undefined, .output = undefined };
}

test "a poll records what was typed in a viewport of whole cells" {
    var host = testHost();
    var events: [8]zui.Event = undefined;
    var text: [8]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text);
    host.decoder.feed("hé", .zero);
    try std.testing.expect(host.recordDecoded(.fromNanoseconds(5), .{ 10, 3 }, &builder));
    try std.testing.expectEqual([2]f32{ 80, 48 }, builder.params.viewport);
    try std.testing.expectEqual(zui.Instant.fromNanoseconds(5), builder.params.now);
    const recorded = builder.events();
    try std.testing.expectEqual(zui.Key.h, recorded[0].key_down.key);
    try std.testing.expectEqualStrings("hé", recorded[recorded.len - 1].text);
    try std.testing.expect(recorded[recorded.len - 1].text.ptr == builder.text_buffer.ptr);
}

test "Ctrl+Q closes the window" {
    var host = testHost();
    var events: [8]zui.Event = undefined;
    var text: [8]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text);
    host.decoder.feed("\x11", .zero);
    try std.testing.expect(!host.recordDecoded(.zero, .{ 10, 3 }, &builder));
}

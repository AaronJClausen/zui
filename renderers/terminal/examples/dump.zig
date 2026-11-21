//! What the terminal targets share: `--dump`, which draws frames into
//! cells without a terminal and prints their glyphs, and the notices they
//! keep off the screen.

const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_terminal = @import("zui_terminal");

/// The arguments without `--dump`, when `--dump` is among them.
pub fn dumpArguments(arena: std.mem.Allocator, arguments: []const [:0]const u8) !?[]const [:0]const u8 {
    var others: std.ArrayList([:0]const u8) = .empty;
    var dumps = false;
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "--dump")) dumps = true else try others.append(arena, argument);
    }
    return if (dumps) others.items else null;
}

/// The terminal is the screen: a line logged on it would stay among the
/// cells until they change.
pub fn noticeAfterStarting(notice: zui_app.Notice) void {
    if (notice != .started) zui_app.logNotice(notice);
}

/// A terminal of `size` cells that is not there: frames are drawn into its
/// cells, and `print` writes their glyphs to stdout.
pub const Cells = struct {
    buffer: zui_terminal.CellBuffer = .{},
    size: [2]u16,
    cell_size: [2]f32 = zui_terminal.default_cell_size,

    pub fn init(gpa: std.mem.Allocator, size: [2]u16) !Cells {
        var cells: Cells = .{ .size = size };
        try cells.buffer.resize(gpa, size[0], size[1]);
        return cells;
    }

    pub fn deinit(self: *Cells, gpa: std.mem.Allocator) void {
        self.buffer.deinit(gpa);
    }

    /// The terminal's size in layout units.
    pub fn viewport(self: *const Cells) [2]f32 {
        return .{ @as(f32, @floatFromInt(self.size[0])) * self.cell_size[0], @as(f32, @floatFromInt(self.size[1])) * self.cell_size[1] };
    }

    pub fn draw(self: *Cells, background: zui.Color, commands: anytype) void {
        self.buffer.fill(.{ .foreground = background, .background = background });
        zui_terminal.render(&self.buffer, self.cell_size, commands);
    }

    pub fn print(self: *const Cells, io: std.Io) !void {
        var stdout_buffer: [16 * 1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        try self.buffer.writeGlyphs(&stdout_writer.interface);
        try stdout_writer.interface.flush();
    }
};

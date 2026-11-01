const std = @import("std");
const zui = @import("../root.zig");

/// Deterministic metrics: every byte is `size / 2` wide and `size` tall,
/// so at the default size of 16 a character is 8×16.
pub const TestPlatform = struct {
    pub fn measureText(_: *TestPlatform, text: []const u8, _: u16, size: f32) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * size / 2, size };
    }
};

pub const Ui = zui.Context(.{
    .max_elements = 256,
    .max_text_bytes = 4096,
    .max_depth = 16,
    .max_render_commands = 512,
    .measure_cache_entries = 256,
}, TestPlatform);

pub const Harness = struct {
    platform: TestPlatform = .{},
    ui: Ui = undefined,

    pub fn init(self: *Harness) !void {
        self.ui = try Ui.init(std.testing.allocator, std.testing.io, &self.platform);
    }

    pub fn deinit(self: *Harness) void {
        self.ui.deinit(std.testing.allocator);
    }

    pub fn begin(self: *Harness) *Ui {
        return self.beginWith(.{});
    }

    /// Begins a frame with input; the viewport is always 800×600.
    pub fn beginWith(self: *Harness, input: InputWithoutViewport) *Ui {
        var full: zui.Input = .{ .viewport = .{ 800, 600 } };
        inline for (@typeInfo(InputWithoutViewport).@"struct".fields) |field| @field(full, field.name) = @field(input, field.name);
        self.ui.beginFrame(full);
        return &self.ui;
    }

    /// Ends the frame, expects success, and releases it so the next frame
    /// can start. The returned frame stays readable until two more frames
    /// have begun.
    pub fn end(self: *Harness) !*const Ui.Frame {
        const frame = try self.ui.endFrame();
        self.ui.release(frame);
        return frame;
    }
};

pub const InputWithoutViewport = struct {
    pointer: ?[2]f32 = null,
    buttons: std.EnumSet(zui.Button) = .initEmpty(),
    wheel: [2]f32 = .{ 0, 0 },
    keys_pressed: []const zui.Key = &.{},
    modifiers: zui.Modifiers = .{},
    text_input: []const u8 = "",
};

pub fn primaryDown() std.EnumSet(zui.Button) {
    return .initOne(.primary);
}

pub fn expectRect(frame: *const Ui.Frame, id: zui.Id, x: f32, y: f32, width: f32, height: f32) !void {
    const rect = frame.rectOf(id) orelse return error.ElementNotFound;
    try std.testing.expectEqual(zui.Rect{ .x = x, .y = y, .width = width, .height = height }, rect);
}

/// One line per command: `kind x y w h [detail]`, in paint order.
pub fn snapshot(frame: *const Ui.Frame, buffer: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (frame.commands()) |command| {
        const bounds = command.bounds;
        switch (command.payload) {
            .rectangle => |rectangle| try writer.print("rect {d} {d} {d} {d} #{x:0>2}{x:0>2}{x:0>2}\n", .{ bounds.x, bounds.y, bounds.width, bounds.height, rectangle.color.r, rectangle.color.g, rectangle.color.b }),
            .border => |border| try writer.print("border {d} {d} {d} {d} #{x:0>2}{x:0>2}{x:0>2}\n", .{ bounds.x, bounds.y, bounds.width, bounds.height, border.color.r, border.color.g, border.color.b }),
            .text => |text| try writer.print("text {d} {d} {d} {d} \"{s}\"\n", .{ bounds.x, bounds.y, bounds.width, bounds.height, text.content }),
            .image => |handle| try writer.print("image {d} {d} {d} {d} {d}\n", .{ bounds.x, bounds.y, bounds.width, bounds.height, handle }),
            .custom => try writer.print("custom {d} {d} {d} {d}\n", .{ bounds.x, bounds.y, bounds.width, bounds.height }),
            .clip_begin => |clip| try writer.print("clip {d} {d} {d} {d}\n", .{ clip.x, clip.y, clip.width, clip.height }),
            .clip_end => try writer.writeAll("clip_end\n"),
        }
    }
    return writer.buffered();
}

const std = @import("std");
const zui = @import("zui");
const zui_glyphs = @import("zui_glyphs");

const cells = @import("cells.zig");
pub const Cell = cells.Cell;
pub const CellBuffer = cells.CellBuffer;
pub const CellRect = cells.CellRect;
pub const render = cells.render;

pub const Screen = @import("screen.zig").Screen;
pub const InputDecoder = @import("input.zig").InputDecoder;
pub const Terminal = @import("terminal.zig").Terminal;
pub const Host = @import("host.zig").Host;

/// Layout units per terminal cell. Layout stays in pixel-like units so that
/// UIs written for pixel renderers lay out sensibly in a terminal too.
pub const default_cell_size: [2]f32 = .{ 8, 16 };

/// A `zui.Config` for `Renderer`: text measured in cells, and only the
/// base commands, which are all a terminal draws. Override any other field:
/// `zui.Context(zui_terminal.config(.{ .limits = .{ .max_elements = 8192 } }))`.
pub fn config(overrides: zui.Config) zui.Config {
    comptime zui.checkRenderer(Renderer);
    var result = overrides;
    result.Text = Text;
    result.commands = .initEmpty();
    result.ImageHandle = void;
    result.CustomData = void;
    result.MaterialHandle = void;
    return result;
}

/// The renderer contract for a terminal: paints each frame into its
/// screen's cells and writes what changed to the surface's output. Its
/// surface is `.terminal`, which carries the terminal's size in cells and
/// that writer. `zui_app` calls `init`; on a loop of your own, call it too,
/// or set `cell_size` and let the first frame size the screen:
///
/// ```zig
/// var renderer: zui_terminal.Renderer = .{ .gpa = gpa };
/// defer renderer.deinit();
/// const frame = ui.endFrame();
/// try renderer.zuiSubmit(terminal.surface(&stdout_writer.interface), frame);
/// ui.release(frame);
/// ```
pub const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.terminal);
    /// Every glyph one cell, whatever its font: text laid out in
    /// `zui_glyphs`' cells of `cell_size` is drawn where it was measured.
    pub const glyph_placement: zui_glyphs.Placement = .{ .cells = default_cell_size };

    /// Holds the screen's cells, which grow when the terminal does.
    gpa: std.mem.Allocator = std.heap.page_allocator,
    screen: Screen = .{},
    /// `Text.cell_size`.
    cell_size: [2]f32 = default_cell_size,
    /// The color of cells no command paints.
    background: zui.Color = .black,

    /// Sizes the screen to `surface`, so frames at that size allocate
    /// nothing, and paints in the cells `text` measures.
    pub fn init(self: *Renderer, surface: zui.Surface, text: *const Text) !void {
        const terminal = switch (surface) {
            .terminal => |terminal| terminal,
            else => return error.UnsupportedSurface,
        };
        self.cell_size = text.cell_size;
        _ = try self.screen.begin(self.gpa, .{ terminal.columns, terminal.rows }, self.background);
    }

    pub fn deinit(self: *Renderer) void {
        self.screen.deinit(self.gpa);
    }

    pub fn zuiSubmit(self: *Renderer, surface: zui.Surface, frame: anytype) !void {
        const terminal = switch (surface) {
            .terminal => |terminal| terminal,
            else => return error.UnsupportedSurface,
        };
        render(try self.screen.begin(self.gpa, .{ terminal.columns, terminal.rows }, self.background), self.cell_size, frame.commands());
        try self.screen.present(terminal.output);
    }
};

/// The text contract of a terminal, which has one font at one size: text
/// laid out in `zui_glyphs`' cells, every code point one cell wide, plus the
/// letter spacing after it, and one cell tall.
pub const Text = struct {
    cell_size: [2]f32 = default_cell_size,

    pub fn zuiMeasure(self: *Text, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return zui_glyphs.measure({}, run, key, .{ .cells = self.cell_size }).?;
    }
};

fn measure(text: *Text, run: []const u8, size: f32, letter_spacing: f32) [2]f32 {
    return text.zuiMeasure(run, .{ .font = 0, .size = size, .letter_spacing = letter_spacing });
}

test "measurement is additive and ignores the font size" {
    var text: Text = .{};
    const one = measure(&text, "one", 16, 0);
    const space = measure(&text, " ", 16, 0);
    const two = measure(&text, "two", 40, 0);
    try std.testing.expectEqual(measure(&text, "one two", 16, 0)[0], one[0] + space[0] + two[0]);
    try std.testing.expectEqual(@as(f32, 16), two[1]);
}

test "the renderer draws the base commands only, into a terminal" {
    const Ui = zui.Context(config(.{ .limits = .{ .max_elements = 8 }, .ImageHandle = u32 }));
    try std.testing.expectEqual(5, @typeInfo(Ui.RenderCommand.Payload).@"union".fields.len);
    var text: Text = .{};
    var ui = try Ui.init(std.testing.allocator, std.testing.io, &text);
    defer ui.deinit(std.testing.allocator);
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 32, 16 } } });
    ui.text("zui", .{ .color = .white });
    const frame = ui.endFrame();
    defer ui.release(frame);

    var written: [256]u8 = undefined;
    var output: std.Io.Writer = .fixed(&written);
    var renderer: Renderer = .{ .gpa = std.testing.allocator };
    defer renderer.deinit();
    try std.testing.expectError(error.UnsupportedSurface, renderer.zuiSubmit(.library, frame));
    try renderer.zuiSubmit(.{ .terminal = .{ .columns = 4, .rows = 1, .output = &output } }, frame);
    try std.testing.expect(std.mem.indexOf(u8, output.buffered(), "zui") != null);
}

test "init sizes the screen to the surface and paints in the text's cells" {
    var discarding: std.Io.Writer.Discarding = .init(&.{});
    var renderer: Renderer = .{ .gpa = std.testing.allocator };
    defer renderer.deinit();
    const text: Text = .{ .cell_size = .{ 10, 20 } };
    try std.testing.expectError(error.UnsupportedSurface, renderer.init(.library, &text));
    try renderer.init(.{ .terminal = .{ .columns = 6, .rows = 2, .output = &discarding.writer } }, &text);
    try std.testing.expectEqual([2]f32{ 10, 20 }, renderer.cell_size);
    try std.testing.expectEqual(@as(usize, 12), renderer.screen.back.cells.len);
}

test "letter spacing follows every code point, so measurement stays additive" {
    var text: Text = .{};
    try std.testing.expectEqual(@as(f32, 4 * 8), measure(&text, "café", 16, 0)[0]);
    try std.testing.expectEqual(@as(f32, 4 * 16), measure(&text, "café", 16, 8)[0]);
    try std.testing.expectEqual(measure(&text, "ab", 16, 8)[0], measure(&text, "a", 16, 8)[0] + measure(&text, "b", 16, 8)[0]);
}

test "an invalid byte measures as the one cell it is drawn in" {
    var text: Text = .{};
    try std.testing.expectEqual(@as(f32, 3 * 8), measure(&text, "a\xffb", 16, 0)[0]);
}

test {
    std.testing.refAllDecls(@This());
    _ = cells;
    _ = @import("screen.zig");
    _ = @import("input.zig");
    _ = @import("terminal.zig");
    _ = @import("host.zig");
}

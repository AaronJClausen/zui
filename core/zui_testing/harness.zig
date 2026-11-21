const std = @import("std");
const zui = @import("zui");
const renderer_viewport = @import("renderer_conformance.zig").renderer_viewport;

/// The order a graphics API stores a target's rows in when it reads them
/// back: OpenGL's `glReadPixels` and a raylib render texture give the
/// bottom row first.
pub const RowOrder = enum { top_down, bottom_up };

/// A frame of the renderer suite read back from its target, one RGBA texel
/// for each pixel of `renderer_viewport`, which answers a harness's
/// `pixel` (`ReadBack(.sdr)`, 8 bits a channel) or `extendedPixel`
/// (`ReadBack(.scrgb_fp16)`, read back as 32-bit floats).
///
/// ```zig
/// read_back: zui_testing.ReadBack(.sdr) = .{ .rows = .bottom_up },
///
/// pub fn endDraw(self: *WindowHarness) void {
///     glReadPixels(0, 0, width, height, gl_rgba, gl_unsigned_byte, self.read_back.bytes().ptr);
/// }
///
/// pub fn pixel(self: *WindowHarness, x: u32, y: u32) zui.Color {
///     return self.read_back.pixel(x, y);
/// }
/// ```
pub fn ReadBack(comptime format: zui.OutputFormat) type {
    return struct {
        const Self = @This();

        pub const Channel = switch (format) {
            .sdr => u8,
            .scrgb_fp16 => f32,
        };
        pub const Pixel = switch (format) {
            .sdr => zui.Color,
            .scrgb_fp16 => zui.ExtendedColor,
        };
        pub const width = renderer_viewport[0];
        pub const height = renderer_viewport[1];

        rows: RowOrder,
        texels: [width * height][4]Channel = undefined,

        /// Where the graphics API writes the frame, in the order `rows` says.
        pub fn bytes(self: *Self) []u8 {
            return std.mem.sliceAsBytes(&self.texels);
        }

        /// The pixel at `x`, `y`, counted from the top left whatever the
        /// order of the rows.
        pub fn pixel(self: *const Self, x: u32, y: u32) Pixel {
            const row = switch (self.rows) {
                .top_down => y,
                .bottom_up => height - 1 - y,
            };
            const rgba = self.texels[row * width + x];
            return switch (format) {
                .sdr => .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] },
                .scrgb_fp16 => .linear(rgba[0], rgba[1], rgba[2], rgba[3]),
            };
        }
    };
}

/// A record for a host's own tests to poll into, with room for 64 events
/// and 8 KiB of text.
///
/// ```zig
/// var polled: zui_testing.PolledRecord = .{};
/// polled.init();
/// _ = polled.poll(&window_host);
/// try std.testing.expectEqual(zui.Key.h, polled.find(.key_down).?.key);
/// ```
pub const PolledRecord = struct {
    events: [64]zui.Event = undefined,
    text: [8192]u8 = undefined,
    builder: zui.RecordBuilder = undefined,

    /// Points the builder at the record's own storage, so it is called
    /// once the record is where it stays.
    pub fn init(self: *PolledRecord) void {
        self.builder = .init(&self.events, &self.text);
    }

    /// Polls the main window, returning what `zuiPoll` returns.
    pub fn poll(self: *PolledRecord, host: anytype) bool {
        return self.pollWindow(host, .main);
    }

    pub fn pollWindow(self: *PolledRecord, host: anytype, window: zui.WindowId) bool {
        return host.zuiPoll(window, &self.builder);
    }

    /// The first event of the last poll with this tag.
    pub fn find(self: *const PolledRecord, comptime tag: std.meta.Tag(zui.Event)) ?@FieldType(zui.Event, @tagName(tag)) {
        for (self.builder.events()) |event| if (event == tag) return @field(event, @tagName(tag));
        return null;
    }
};

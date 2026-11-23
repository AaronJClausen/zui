//! A consumer's module importing `zui` and the tour from the aggregator:
//! the tour runs on a host and renderer declared with this `zui`, which
//! compiles only while the tour is built on it.

const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");
const zui_tour = @import("zui_tour");

const OffscreenHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn init(_: *OffscreenHost, _: std.Io, _: zui.WindowOptions) !void {}
    pub fn deinit(_: *OffscreenHost) void {}
    pub fn zuiPoll(_: *OffscreenHost, _: zui.WindowId, _: *zui.RecordBuilder) bool {
        return false;
    }
    pub fn zuiWaker(self: *OffscreenHost) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }
    pub fn zuiWait(_: *OffscreenHost, _: zui.NextFrame) void {}
    pub fn zuiSurface(_: *OffscreenHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 1, 1 } } };
    }
    pub fn zuiApply(_: *OffscreenHost, _: zui.WindowId, _: zui.HostRequests) void {}
    fn wake(_: *anyopaque) void {}
};

const OffscreenRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiSubmit(_: *OffscreenRenderer, _: zui.Surface, _: anytype) !void {}
};

/// Every glyph half as wide as it is tall, in one font.
const HalfWidthFonts = struct {
    pub fn addFont(_: *HalfWidthFonts, _: []const u8) error{}!u16 {
        return 0;
    }

    pub fn zuiMeasure(_: *HalfWidthFonts, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(run.len)) * key.size / 2, key.size };
    }

    pub fn zuiFingerprint(_: *const HalfWidthFonts) u64 {
        return 0;
    }
};

comptime {
    const Tour = zui_tour.App(.{ .Host = OffscreenHost, .Renderer = OffscreenRenderer, .Text = HalfWidthFonts, .renderer_name = "an offscreen renderer" });
    _ = zui_app.Session(Tour);
}

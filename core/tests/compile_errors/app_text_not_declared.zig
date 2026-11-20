const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");

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

const Fonts = struct {
    pub fn zuiMeasure(_: *Fonts, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(run.len)) * key.size, key.size };
    }
};

const Ui = zui.Context(zui_app.contextConfig(OffscreenRenderer, .{ .Text = Fonts }));

const App = struct {
    pub const Host = OffscreenHost;
    pub const Renderer = OffscreenRenderer;

    pub fn zuiDeclare(_: *App, _: *Ui) void {}
};

comptime {
    _ = zui_app.Runner(App);
}

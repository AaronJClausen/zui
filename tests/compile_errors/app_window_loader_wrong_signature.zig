const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");

const Host = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .many };

    pub fn zuiPoll(_: *Host, _: zui.WindowId, _: *zui.RecordBuilder) bool {
        return false;
    }
    pub fn zuiWaker(self: *Host) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }
    pub fn zuiWait(_: *Host, _: zui.NextFrame) void {}
    pub fn zuiSurface(_: *Host, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 1, 1 } } };
    }
    pub fn zuiApply(_: *Host, _: zui.WindowId, _: zui.HostRequests) void {}
    fn wake(_: *anyopaque) void {}
    pub fn init(_: *Host, _: std.Io, _: zui.WindowOptions) !void {}
    pub fn deinit(_: *Host) void {}
    pub fn zuiOpenWindow(_: *Host, _: zui.WindowOptions) zui.OpenWindowError!zui.WindowId {
        return error.TooManyWindows;
    }
    pub fn zuiCloseWindow(_: *Host, _: zui.WindowId) void {}
};

const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiSubmit(_: *Renderer, _: zui.Surface, _: anytype) !void {}
};

const Ui = zui.Context(zui_app.contextConfig(Renderer, .{}));

const App = struct {
    pub const Host = Host_;
    pub const Renderer = Renderer_;

    pub fn zuiDeclare(_: *App, _: *Ui, _: zui.WindowId) void {}
    pub fn zuiLoader(_: *App, _: zui.WindowId) void {}
};
const Host_ = Host;
const Renderer_ = Renderer;

comptime {
    _ = zui_app.Runner(App);
}

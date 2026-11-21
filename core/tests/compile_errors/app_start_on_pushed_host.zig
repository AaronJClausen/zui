const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");

const PageHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiRun(_: *PageHost, _: std.Io, _: zui.WindowOptions, _: zui.Driver) !void {}
    pub fn zuiPoll(_: *PageHost, _: zui.WindowId, _: *zui.RecordBuilder) bool {
        return false;
    }
    pub fn zuiWaker(self: *PageHost) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }
    pub fn zuiSurface(_: *PageHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 1, 1 } } };
    }
    pub fn zuiApply(_: *PageHost, _: zui.WindowId, _: zui.HostRequests) void {}
    fn wake(_: *anyopaque) void {}
};

const OffscreenRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiSubmit(_: *OffscreenRenderer, _: zui.Surface, _: anytype) !void {}
};

const Ui = zui.Context(zui_app.contextConfig(OffscreenRenderer, .{}));

const App = struct {
    pub const Host = PageHost;
    pub const Renderer = OffscreenRenderer;

    pub fn zuiDeclare(_: *App, _: *Ui) void {}
};

export fn startSession(session: *zui_app.Session(App), setup: *const zui_app.Setup) void {
    session.start(setup.*, .{}) catch {};
}

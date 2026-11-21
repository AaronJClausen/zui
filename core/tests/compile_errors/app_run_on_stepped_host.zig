const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");

const PanelHost = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn init(_: *PanelHost, _: std.Io, _: zui.WindowOptions) !void {}
    pub fn deinit(_: *PanelHost) void {}
    pub fn zuiPoll(_: *PanelHost, _: zui.WindowId, _: *zui.RecordBuilder) bool {
        return false;
    }
    pub fn zuiWaker(self: *PanelHost) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }
    pub fn zuiSurface(_: *PanelHost, _: zui.WindowId) zui.Surface {
        return .{ .offscreen = .{ .size = .{ 1, 1 } } };
    }
    pub fn zuiApply(_: *PanelHost, _: zui.WindowId, _: zui.HostRequests) void {}
    fn wake(_: *anyopaque) void {}
};

const OffscreenRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiSubmit(_: *OffscreenRenderer, _: zui.Surface, _: anytype) !void {}
};

const Ui = zui.Context(zui_app.contextConfig(OffscreenRenderer, .{}));

const App = struct {
    pub const Host = PanelHost;
    pub const Renderer = OffscreenRenderer;

    pub fn zuiDeclare(_: *App, _: *Ui) void {}
};

export fn runApp(setup: *const zui_app.Setup) void {
    zui_app.runWith(App, setup.*, .{}) catch {};
}

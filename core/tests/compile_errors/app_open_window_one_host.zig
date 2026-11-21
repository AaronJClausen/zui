const std = @import("std");
const zui = @import("zui");
const zui_app = @import("zui_app");

const Host = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

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
};

const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    pub fn zuiSubmit(_: *Renderer, _: zui.Surface, _: anytype) !void {}
};

const Ui = zui.Context(zui_app.contextConfig(Renderer, .{}));

const App = struct {
    pub const Host = Host_;
    pub const Renderer = Renderer_;

    pub fn init(_: *App, start: zui_app.Start(App)) !void {
        _ = try start.windows.open(.{});
    }
    pub fn zuiDeclare(_: *App, _: *Ui, _: zui.WindowId) void {}
};
const Host_ = Host;
const Renderer_ = Renderer;

export fn startSession(session: *zui_app.Session(App), setup: *const zui_app.Setup) void {
    session.start(setup.*, .{}) catch {};
}

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

const Counter = struct {
    pub const Delivery = ?u32;
    pub const View = ?u32;

    value: ?u32 = null,

    pub fn zuiSwap(_: *Counter) void {}
    pub fn zuiView(self: *Counter) View {
        return self.value;
    }
    pub fn zuiDelivery(self: *const Counter, delivery: *Delivery) void {
        delivery.* = self.value;
    }
    pub fn zuiInject(self: *Counter, delivery: *const Delivery) void {
        self.value = delivery.*;
    }
};

const AppSources = struct { counter: Counter = .{} };
const Ui = zui.Context(zui_app.contextConfig(OffscreenRenderer, .{ .Sources = AppSources }));

const App = struct {
    pub const Host = OffscreenHost;
    pub const Renderer = OffscreenRenderer;

    pub fn zuiDeclare(_: *App, _: *Ui) void {}
};

comptime {
    _ = zui_app.Runner(App);
}

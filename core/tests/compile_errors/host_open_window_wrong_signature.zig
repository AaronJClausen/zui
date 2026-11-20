const zui = @import("zui");

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
    pub fn zuiOpenWindow(_: *Host, _: zui.WindowOptions) ?zui.WindowId {
        return null;
    }
    pub fn zuiCloseWindow(_: *Host, _: zui.WindowId) void {}
};

comptime {
    zui.checkHost(Host);
}

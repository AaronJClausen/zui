const zui = @import("zui");

const Host = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.library);

    pub fn zuiPoll(_: *Host, _: zui.WindowId, _: *zui.RecordBuilder) bool {
        return false;
    }

    pub fn zuiWaker(_: *Host) zui.Waker {
        return undefined;
    }

    pub fn zuiWait(_: *Host, _: zui.NextFrame) void {}

    pub fn zuiSurface(_: *Host, _: zui.WindowId) zui.Surface {
        return .library;
    }

    pub fn zuiApply(_: *Host, _: zui.WindowId, _: zui.HostRequests) void {}

    pub const zuiMenus = struct {
        pub fn popup(_: *Host, _: zui.WindowId, _: zui.ServiceRequest, _: []const zui.MenuItem, _: [2]f32, _: zui.ServiceSink) zui.ServiceError!void {}

        pub fn setBar(_: *Host) void {}
    };
};

comptime {
    zui.checkHost(Host);
}

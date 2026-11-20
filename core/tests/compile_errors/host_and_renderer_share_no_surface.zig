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
};

const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initMany(&.{ .terminal, .offscreen });

    pub fn zuiSubmit(_: *Renderer, _: zui.Surface, _: anytype) !void {}
};

comptime {
    zui.checkHostAndRenderer(Host, Renderer);
}

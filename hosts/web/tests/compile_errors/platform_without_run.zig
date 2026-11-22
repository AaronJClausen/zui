const zui = @import("zui");
const zui_web = @import("zui_web");

const PlatformWithoutRun = struct {
    pub fn now(_: *PlatformWithoutRun) zui.Instant {
        return .zero;
    }

    pub fn schedule(_: *PlatformWithoutRun, _: zui_web.Schedule) void {}

    pub fn wake(_: *PlatformWithoutRun) void {}

    pub fn showCursor(_: *PlatformWithoutRun, _: zui.Cursor) void {}
};

comptime {
    _ = zui_web.HostOn(PlatformWithoutRun);
}

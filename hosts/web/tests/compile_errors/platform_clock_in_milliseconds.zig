const zui = @import("zui");
const zui_web = @import("zui_web");

const PlatformClockInMilliseconds = struct {
    pub fn now(_: *PlatformClockInMilliseconds) f64 {
        return 0;
    }

    pub fn schedule(_: *PlatformClockInMilliseconds, _: zui_web.Schedule) void {}

    pub fn wake(_: *PlatformClockInMilliseconds) void {}

    pub fn showCursor(_: *PlatformClockInMilliseconds, _: zui.Cursor) void {}

    pub fn run(_: *PlatformClockInMilliseconds, _: zui_web.Turns) noreturn {
        unreachable;
    }
};

comptime {
    _ = zui_web.HostOn(PlatformClockInMilliseconds);
}

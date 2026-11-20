const zui = @import("zui");
const zui_app = @import("zui_app");

const Host = struct {};

export fn notify() void {
    zui_app.ServicesOf(Host).notifications.show(undefined, .of("saved"), .{ .title = "Saved" }, undefined) catch {};
}

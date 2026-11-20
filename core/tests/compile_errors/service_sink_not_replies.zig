const zui = @import("zui");
const zui_async = @import("zui_async");

var numbers: zui_async.Stream(u64, .{ .capacity = 4 }) = .{};

comptime {
    _ = zui.ServiceSink.of(&numbers);
}

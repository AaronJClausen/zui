const zui_async = @import("zui_async");

comptime {
    _ = zui_async.Stream(u32, .{ .capacity = 100 });
}

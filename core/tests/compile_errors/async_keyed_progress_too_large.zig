const zui_async = @import("zui_async");

comptime {
    _ = zui_async.KeyedLoads(u64, u32, .{ .capacity = 8, .Progress = [3]f64 });
}

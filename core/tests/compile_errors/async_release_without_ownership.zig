const zui_async = @import("zui_async");

const Thumbnails = zui_async.KeyedLoads(u64, u32, .{ .capacity = 8 });

export fn releaseThumbnails(thumbnails: *Thumbnails) void {
    var to_release = thumbnails.toRelease();
    _ = to_release.next();
}

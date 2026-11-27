const zui_testing = @import("zui_testing");

export fn placementOfAnInteger() void {
    _ = zui_testing.SnapshotPlacement.of(@as(u8, 1));
}

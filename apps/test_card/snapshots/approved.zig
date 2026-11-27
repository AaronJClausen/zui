/// The snapshot `zig build approve` wrote of `scene`, a
/// `zui_test_card.Scene`, in `placement`, `.pixels` or `.cells`.
pub fn of(comptime scene: anytype, comptime placement: anytype) []const u8 {
    return @embedFile(@tagName(scene) ++ "." ++ @tagName(placement) ++ ".txt");
}

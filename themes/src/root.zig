const std = @import("std");
const zui = @import("zui");

test "the pinned zui initializes a context in a buffer" {
    const Ui = zui.Context(.{ .limits = .{ .max_elements = 16 } });
    var memory: [Ui.required_bytes]u8 align(Ui.buffer_alignment) = undefined;
    _ = try Ui.initBuffer(&memory, std.testing.io);
}

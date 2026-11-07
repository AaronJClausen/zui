const zui = @import("zui");

const Ui = zui.Context(.{ .limits = .{ .max_elements = 16 } });

var memory: [Ui.required_bytes]u8 align(Ui.buffer_alignment) = undefined;

export fn zuiWebCheckContext() bool {
    _ = Ui.initBuffer(&memory, undefined) catch return false;
    return true;
}

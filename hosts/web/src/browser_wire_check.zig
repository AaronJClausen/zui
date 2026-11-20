const std = @import("std");
const zui_wire = @import("zui_wire");
const browser = @import("browser.zig");
const DemoUi = @import("demo_ui.zig").DemoUi;

comptime {
    _ = browser;
}

var encoder: zui_wire.Encoder(DemoUi) = undefined;

/// Reserves what `zuiWebNewestFrameDigest` writes with, beside the client.
export fn zuiWebCheckInit() bool {
    encoder = zui_wire.Encoder(DemoUi).init(std.heap.wasm_allocator) catch return false;
    return true;
}

/// A hash of the newest frame written whole, which equals the hash of the
/// frame the application drew written whole only when every value decoded
/// is the value drawn.
export fn zuiWebNewestFrameDigest() u64 {
    const frame = browser.newest orelse return 0;
    var buffer: [4096]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.hash.Wyhash) = .initHasher(.init(0), &buffer);
    encoder.writeKeyFrame(&hashing.writer, frame) catch unreachable;
    hashing.writer.flush() catch unreachable;
    return hashing.hasher.final();
}

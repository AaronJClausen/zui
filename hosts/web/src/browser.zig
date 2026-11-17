const std = @import("std");
const DemoUi = @import("demo_ui.zig").DemoUi;

pub const DemoStream = @import("frame_stream.zig").FrameStream(DemoUi);

pub var stream: DemoStream = undefined;
/// The frame decoded last, which is the one to draw.
pub var newest: ?*const DemoStream.Frame = null;
var last_error: ?anyerror = null;

/// Reserves the client's memory. False when the browser has too little.
///
/// ```js
/// wasm.zuiWebInit();
/// socket.onmessage = ({ data }) => {
///   const bytes = new Uint8Array(data);
///   const room = wasm.zuiWebRoomFor(bytes.length);
///   new Uint8Array(wasm.memory.buffer, room, bytes.length).set(bytes);
///   wasm.zuiWebReceived(bytes.length);
///   while (wasm.zuiWebNextFrame() > 0) {}
/// };
/// ```
export fn zuiWebInit() bool {
    stream = DemoStream.init(std.heap.wasm_allocator, .{}) catch |err| {
        last_error = err;
        return false;
    };
    return true;
}

/// Where to write the next `count` bytes of the stream, or 0 when they do
/// not fit until frames are taken with `zuiWebNextFrame`.
export fn zuiWebRoomFor(count: usize) usize {
    const room = stream.roomFor(count) catch |err| {
        last_error = err;
        return 0;
    };
    return @intFromPtr(room.ptr);
}

export fn zuiWebReceived(count: usize) void {
    stream.received(count);
}

/// 1 when another frame was decoded, 0 until more of the stream arrives,
/// -1 when the stream cannot be read, as `zuiWebErrorName` says.
export fn zuiWebNextFrame() i32 {
    newest = (stream.nextFrame() catch |err| {
        last_error = err;
        return -1;
    }) orelse return 0;
    return 1;
}

export fn zuiWebFrameNumber() u64 {
    return if (newest) |frame| frame.number else 0;
}

export fn zuiWebCommandCount() usize {
    return if (newest) |frame| frame.commands().len else 0;
}

/// The last failure, as a C string, or an empty one.
export fn zuiWebErrorName() [*:0]const u8 {
    return if (last_error) |err| @errorName(err) else "";
}

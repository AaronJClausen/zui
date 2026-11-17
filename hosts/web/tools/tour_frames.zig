//! ```sh
//! tour-frames <ticks path> <stream path>
//! ```
//! Runs zui-sokol's tour natively as the browser's worker runs it, on each
//! tick the page gave the worker: its instant on the page's clock (f64,
//! milliseconds) and the records it sent since the one before (a u32
//! count, then the bytes), little-endian. Writes the wire bytes of every
//! frame, and prints how many tasks the tour started, finished and was
//! refused.

const std = @import("std");
const tour_session = @import("tour_session");
const TourSession = tour_session.TourSession;
const SteppedIo = tour_session.SteppedIo;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 3) {
        std.debug.print("expected <ticks path> <stream path>\n", .{});
        return error.UnknownArgument;
    }
    const io = init.io;
    const gpa = init.gpa;

    var stepped: SteppedIo = try .init(gpa, io, .{ .thread_count = TourSession.thread_count });
    defer stepped.deinit(gpa);
    var threads: [TourSession.thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try .spawn(.{}, SteppedIo.runThread, .{ &stepped, index });
    defer {
        stepped.stopThreads();
        for (threads) |thread| thread.join();
    }
    var session: TourSession = undefined;
    try session.init(gpa, &stepped, .{});
    defer session.deinit();

    const ticks_file = try std.Io.Dir.cwd().openFile(io, arguments[1], .{});
    defer ticks_file.close(io);
    var ticks_buffer: [64 * 1024]u8 = undefined;
    var ticks_reader = ticks_file.reader(io, &ticks_buffer);
    const ticks = &ticks_reader.interface;

    const stream_file = try std.Io.Dir.cwd().createFile(io, arguments[2], .{});
    defer stream_file.close(io);
    var stream_buffer: [64 * 1024]u8 = undefined;
    var stream_writer = stream_file.writer(io, &stream_buffer);

    while (true) {
        const now_milliseconds: f64 = @bitCast(ticks.takeInt(u64, .little) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |other| return other,
        });
        const record_count = try ticks.takeInt(u32, .little);
        try ticks.readSliceAll(try session.roomForRecords(record_count));
        session.receivedRecords(record_count);
        if (try session.frame(now_milliseconds)) |wire_bytes| try stream_writer.interface.writeAll(wire_bytes);
    }
    try stream_writer.interface.flush();
    std.debug.print("{d} {d} {d}\n", .{ stepped.counts.started, stepped.counts.finished, stepped.counts.refused });
}

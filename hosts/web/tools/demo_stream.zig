//! ```sh
//! demo-stream <stream path> <expected path>
//! ```
//! Writes the tour's frames as the wire renderer sends them, and for each
//! what the browser must decode it to, little-endian: its number (u64),
//! its command count (u32) and the Wyhash of it written whole (u64).

const std = @import("std");
const zui = @import("zui");
const zui_sokol = @import("zui_sokol");
const zui_wire = @import("zui_wire");
const tour = @import("zui_sokol_tour");
const Ui = tour.kit.Ui;

const frames_per_screen = 24;
const window: [2]f32 = .{ 1440, 900 };

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 3) {
        std.debug.print("expected <stream path> <expected path>\n", .{});
        return error.UnknownArgument;
    }
    const io = init.io;
    const gpa = init.gpa;

    var text: zui_sokol.Text = .{};
    try tour.kit.addFonts(&text);
    var ui: Ui = try .init(gpa, io, &text);
    defer ui.deinit(gpa);
    const app = try gpa.create(tour.App);
    defer gpa.destroy(app);
    app.init(io, .zero);
    defer app.deinit();
    app.heartbeat = false;

    const stream_file = try std.Io.Dir.cwd().createFile(io, arguments[1], .{});
    defer stream_file.close(io);
    var stream_buffer: [64 * 1024]u8 = undefined;
    var stream_writer = stream_file.writer(io, &stream_buffer);
    const expected_file = try std.Io.Dir.cwd().createFile(io, arguments[2], .{});
    defer expected_file.close(io);
    var expected_buffer: [4096]u8 = undefined;
    var expected_writer = expected_file.writer(io, &expected_buffer);

    var encoder: zui_wire.Encoder(Ui) = try .init(gpa);
    defer encoder.deinit(gpa);
    var whole_encoder: zui_wire.Encoder(Ui) = try .init(gpa);
    defer whole_encoder.deinit(gpa);
    try zui_wire.writeHeader(&stream_writer.interface, zui_wire.fingerprintOf(&text));

    var frame_number: u64 = 0;
    for (std.enums.values(tour.kit.Screen)) |screen| {
        app.current = screen;
        for (0..frames_per_screen) |step| {
            frame_number += 1;
            const now: zui.Instant = .fromNanoseconds(frame_number * std.time.ns_per_s / 60);
            var events: [16]zui.Event = undefined;
            var event_count: usize = 0;
            for (app.environment_changes.drain()) |change| {
                events[event_count] = .{ .environment = change };
                event_count += 1;
            }
            const across: f32 = @as(f32, @floatFromInt(step)) / frames_per_screen;
            events[event_count] = .{ .pointer_move = .{ .pointer = .{ .id = .mouse, .kind = .mouse, .position = .{ across * window[0], across * window[1] }, .at = now } } };
            event_count += 1;

            ui.beginFrame(&.{ .params = .{ .now = now, .viewport = window }, .events = events[0..event_count] }, &app.sources);
            app.declare(&ui);
            const frame = ui.endFrame();
            app.afterFrame(&ui);
            defer ui.release(frame);

            try encoder.writeFrame(&stream_writer.interface, frame);
            try expected_writer.interface.writeInt(u64, frame.number, .little);
            try expected_writer.interface.writeInt(u32, @intCast(frame.commands().len), .little);
            try expected_writer.interface.writeInt(u64, try wholeFrameDigest(&whole_encoder, frame), .little);
        }
    }
    try stream_writer.interface.flush();
    try expected_writer.interface.flush();
}

fn wholeFrameDigest(encoder: *zui_wire.Encoder(Ui), frame: *const Ui.Frame) !u64 {
    var buffer: [4096]u8 = undefined;
    var hashing: std.Io.Writer.Hashing(std.hash.Wyhash) = .initHasher(.init(0), &buffer);
    try encoder.writeKeyFrame(&hashing.writer, frame);
    try hashing.writer.flush();
    return hashing.hasher.final();
}

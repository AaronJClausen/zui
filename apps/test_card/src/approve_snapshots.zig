const std = @import("std");
const test_card = @import("zui_test_card");
const headless = @import("headless.zig");

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) {
        std.log.err("approve-snapshots takes the directory to write the snapshots into", .{});
        return error.UnknownArgument;
    }
    var directory = try std.Io.Dir.cwd().createDirPathOpen(init.io, arguments[1], .{});
    defer directory.close(init.io);
    var written: std.Io.Writer.Allocating = .init(init.gpa);
    defer written.deinit();
    inline for (comptime std.enums.values(headless.SnapshotPlacement)) |placement| {
        const Harness = headless.Harness(placement.Renderer());
        for (std.enums.values(test_card.Scene)) |scene| {
            const harness = try init.gpa.create(Harness);
            defer init.gpa.destroy(harness);
            harness.* = .{};
            try harness.init(init.gpa, init.io);
            defer harness.deinit();
            const drawn = harness.heldFrame(scene);
            defer harness.ui.release(drawn);
            written.clearRetainingCapacity();
            try harness.writeSnapshot(&written.writer, drawn);
            var name_buffer: [64]u8 = undefined;
            const name = try headless.snapshotFileName(&name_buffer, scene, placement);
            try directory.writeFile(init.io, .{ .sub_path = name, .data = written.written() });
            std.log.info("wrote {s}", .{name});
        }
    }
}

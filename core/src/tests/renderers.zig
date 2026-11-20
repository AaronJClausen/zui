const std = @import("std");
const zui = @import("../root.zig");
const support = @import("support.zig");

const testing = std.testing;

/// Declares nothing optional and no payload types, so its exhaustive
/// `switch` names the five base commands and nothing else.
const BaseRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);

    painted: [5]u32 = @splat(0),
    pixels_per_unit: f32 = 0,

    pub fn zuiSubmit(self: *BaseRenderer, surface: zui.Surface, frame: anytype) !void {
        if (surface != .offscreen) return error.UnsupportedSurface;
        self.pixels_per_unit = frame.params.scale * frame.params.zoom;
        for (frame.commands()) |command| {
            const slot: usize = switch (command.payload) {
                .rectangle => 0,
                .border => 1,
                .text => 2,
                .clip_begin => 3,
                .clip_end => 4,
            };
            self.painted[slot] += 1;
        }
    }
};

comptime {
    zui.checkRenderer(BaseRenderer);
}

test "a renderer that declares nothing optional draws a frame with a switch over the base commands" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();

    const ui = harness.begin();
    ui.open(.{ .clip = .both, .decoration = .{ .background = .black, .border = .{ .color = .white, .widths = .all(1) } }, .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(40) } } });
    ui.text("base", .{});
    ui.close();
    const frame = try harness.end();

    var renderer: BaseRenderer = .{};
    try renderer.zuiSubmit(.{ .offscreen = .{ .size = .{ 800, 600 } } }, frame);
    try testing.expectEqual([5]u32{ 1, 1, 1, 1, 1 }, renderer.painted);
    try testing.expectEqual(@as(f32, 1), renderer.pixels_per_unit);
    try testing.expectError(error.UnsupportedSurface, renderer.zuiSubmit(.library, frame));
}

test "image and custom commands exist only when their payload types are set" {
    const Payload = support.Ui.RenderCommand.Payload;
    try testing.expect(!@hasField(Payload, "image"));
    try testing.expect(!@hasField(Payload, "custom"));
    const WithPayloads = zui.Context(.{ .limits = .{ .max_elements = 8 }, .ImageHandle = u32, .CustomData = u8 });
    try testing.expect(@hasField(WithPayloads.RenderCommand.Payload, "image"));
    try testing.expect(@hasField(WithPayloads.RenderCommand.Payload, "custom"));
}

test "the frame carries its record's parameters" {
    var harness: support.Harness = .{};
    try harness.init();
    defer harness.deinit();
    _ = harness.begin();
    const frame = try harness.end();
    try testing.expectEqual([2]f32{ 800, 600 }, frame.params.viewport);
    try testing.expectEqual(harness.now, frame.params.now);
}

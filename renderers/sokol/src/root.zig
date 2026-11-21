const std = @import("std");
const zui = @import("zui");
pub const sokol = @import("sokol");

/// Draws zui frames through sokol_gfx. A context drawn by it is configured
/// with `zui_app.contextConfig`, with the font system its text is measured
/// in:
///
/// ```zig
/// const Ui = zui.Context(zui_app.contextConfig(zui_sokol.Renderer, .{ .Text = zui_truetype.Text }));
/// var text: zui_truetype.Text = .{};
/// var renderer: zui_sokol.Renderer = .init(&text);
/// ```
pub const Renderer = @import("renderer.zig").Renderer;
/// The renderer's `MaterialHandle`.
pub const Material = @import("material.zig").Material;

/// The renderer's `ImageHandle`: a texture as sokol_gl samples it, by the
/// ids of a sokol_gfx view and of the sampler to draw it with, which
/// `imageOf` makes from sokol's own handles.
pub const Image = struct {
    view: SokolId,
    sampler: SokolId,

    pub const SokolId = struct { id: u32 = 0 };
};

/// The `Image` for a sokol_gfx view and the sampler to draw it with.
pub fn imageOf(view: sokol.gfx.View, sampler: sokol.gfx.Sampler) Image {
    return .{ .view = .{ .id = view.id }, .sampler = .{ .id = sampler.id } };
}

/// Measures every byte as 8 by 16 units, for a test that draws no glyphs.
const FixedWidthText = struct {
    pub fn zuiMeasure(_: *FixedWidthText, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(run.len)) * 8, key.size };
    }
};

test "the renderer draws the base commands, images, gradients, shadows, backdrop blurs, transforms and materials, into sokol_app's swapchain or an image of its own" {
    const Ui = zui.Context(.{
        .Text = FixedWidthText,
        .commands = Renderer.zui_commands,
        .extended_color = Renderer.zui_extended_color,
        .ImageHandle = Renderer.ImageHandle,
        .MaterialHandle = Renderer.MaterialHandle,
        .limits = .{ .max_elements = 8 },
    });
    comptime zui.checkRenderer(Renderer);
    const Payload = Ui.RenderCommand.Payload;
    try std.testing.expectEqual(12, @typeInfo(Payload).@"union".fields.len);
    inline for (.{ "gradient", "shadow", "backdrop_blur", "transform_begin", "transform_end", "material" }) |optional| try std.testing.expect(@hasField(Payload, optional));
    var text: FixedWidthText = .{};
    var ui = try Ui.init(std.testing.allocator, std.testing.io, &text);
    defer ui.deinit(std.testing.allocator);
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    const frame = ui.endFrame();
    defer ui.release(frame);
    var renderer: Renderer = .{ .pipeline = .{} };
    try std.testing.expectError(error.UnsupportedSurface, renderer.zuiSubmit(.{ .web = .{ .canvas = 0 } }, frame));
}

test {
    _ = @import("renderer.zig");
    _ = @import("backdrop_blur.zig");
    _ = @import("materials.zig");
    _ = @import("material.zig");
    _ = @import("destination.zig");
}

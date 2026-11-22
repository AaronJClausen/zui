const std = @import("std");
const zui = @import("zui");
const zui_glyphs = @import("zui_glyphs");
const zui_testing = @import("zui_testing");
const webgl = @import("renderer.zig");

/// A page that takes every frame and draws none, so the suite checks what
/// the renderer accepts without reading pixels back: no WebGL runs outside
/// a browser.
const UndrawnPage = struct {
    frames: u32 = 0,

    pub fn blursBackdrops(_: *UndrawnPage, _: u32) bool {
        return true;
    }

    pub fn draw(self: *UndrawnPage, _: u32, _: *const webgl.DrawnFrame) void {
        self.frames += 1;
    }
};

const PageRenderer = webgl.RendererOn(UndrawnPage);

const UndrawnHarness = struct {
    pub const config: zui.Config = .{
        .Text = zui_testing.FixedMetricsText(u16),
        .commands = PageRenderer.zui_commands,
        .ImageHandle = PageRenderer.ImageHandle,
        .MaterialHandle = PageRenderer.MaterialHandle,
    };

    measuring: zui_testing.FixedMetricsText(u16) = .{},
    boxes: zui_glyphs.testing.BoxFonts = .{},
    drawn: PageRenderer = .{},

    pub fn renderer(self: *UndrawnHarness) *PageRenderer {
        return &self.drawn;
    }

    pub fn text(self: *UndrawnHarness) *zui_testing.FixedMetricsText(u16) {
        return &self.measuring;
    }

    pub fn beginDraw(_: *UndrawnHarness, _: [2]u32) zui.Surface {
        return .{ .web = .{ .canvas = 0 } };
    }

    pub fn image(_: *UndrawnHarness, _: zui.Color) webgl.Image {
        return .{ .view = .{}, .sampler = .{} };
    }

    pub fn material(_: *UndrawnHarness, color: zui.Color) webgl.Material {
        return .{ .first = color };
    }
};

test "the renderer conforms, its frames handed to a page that draws none" {
    var harness: UndrawnHarness = .{};
    try harness.drawn.init(.{ .web = .{ .canvas = 0 } }, &harness.boxes);
    defer harness.drawn.deinit();
    try zui_testing.expectRendererConforms(PageRenderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io });
    try std.testing.expectEqual(5, harness.drawn.page.frames);
    try std.testing.expectEqual(0, harness.drawn.drawListOverflows());
}

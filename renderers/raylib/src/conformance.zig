const std = @import("std");
const zui_raylib = @import("zui_raylib");
const zui = @import("zui");
const zui_app = @import("zui_app");
const c = zui_raylib.c;
const zui_testing = @import("zui_testing");
const zui_truetype = @import("zui_truetype");

/// Draws into a render texture of a hidden window, and reads each frame
/// back as an image. Its text is `zui_truetype`'s, in its default font.
const RenderTextureHarness = struct {
    pub const config = zui_app.contextConfig(zui_raylib.Renderer, .{ .Text = zui_truetype.Text });

    drawn: zui_raylib.Renderer = .{ .presentation = .draws_into_current_target },
    text_contract: zui_truetype.Text = .{},
    target: c.RenderTexture2D,
    pictures: [4]c.Texture2D = undefined,
    picture_count: usize = 0,
    read_back: zui_testing.ReadBack(.sdr) = .{ .rows = .bottom_up },

    fn init(self: *RenderTextureHarness) !void {
        c.SetTraceLogLevel(c.LOG_WARNING);
        c.SetConfigFlags(c.FLAG_WINDOW_HIDDEN);
        c.InitWindow(zui_testing.renderer_viewport[0], zui_testing.renderer_viewport[1], "zui renderer suite");
        self.* = .{ .target = c.LoadRenderTexture(zui_testing.renderer_viewport[0], zui_testing.renderer_viewport[1]) };
        try self.drawn.init(.library, &self.text_contract);
    }

    fn deinit(self: *RenderTextureHarness) void {
        self.drawn.deinit();
        for (self.pictures[0..self.picture_count]) |picture| c.UnloadTexture(picture);
        c.UnloadRenderTexture(self.target);
        c.CloseWindow();
    }

    pub fn renderer(self: *RenderTextureHarness) *zui_raylib.Renderer {
        return &self.drawn;
    }

    pub fn text(self: *RenderTextureHarness) *zui_truetype.Text {
        return &self.text_contract;
    }

    pub fn beginDraw(self: *RenderTextureHarness, size: [2]u32) zui.Surface {
        std.debug.assert(size[0] == self.target.texture.width and size[1] == self.target.texture.height);
        c.BeginTextureMode(self.target);
        c.ClearBackground(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        return .library;
    }

    pub fn endDraw(self: *RenderTextureHarness) void {
        c.EndTextureMode();
        const frame_pixels = c.LoadImageFromTexture(self.target.texture);
        defer c.UnloadImage(frame_pixels);
        std.debug.assert(frame_pixels.format == c.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
        const read_back = self.read_back.bytes();
        @memcpy(read_back, @as([*]const u8, @ptrCast(frame_pixels.data))[0..read_back.len]);
    }

    pub fn pixel(self: *RenderTextureHarness, x: u32, y: u32) zui.Color {
        return self.read_back.pixel(x, y);
    }

    pub fn image(self: *RenderTextureHarness, color: zui.Color) zui_raylib.Texture {
        const solid = c.GenImageColor(16, 16, .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a });
        defer c.UnloadImage(solid);
        const picture = c.LoadTextureFromImage(solid);
        self.pictures[self.picture_count] = picture;
        self.picture_count += 1;
        return picture;
    }
};

test "the renderer passes zui's renderer suite" {
    const harness = try std.testing.allocator.create(RenderTextureHarness);
    defer std.testing.allocator.destroy(harness);
    try harness.init();
    defer harness.deinit();
    try zui_testing.expectRendererConforms(zui_raylib.Renderer, harness, .{ .gpa = std.testing.allocator, .io = std.testing.io });
}

/// raylib reports state, not events, so each posted event becomes the
/// state that `zui.InputSampler` turns back into that event: the pointer
/// held where it moved, a button down or up, a key pressed, text typed.
const ScriptedInputHarness = struct {
    raylib_host: zui_raylib.Host,
    held: zui.InputSampler.Sample = .{},
    keys: [8][1]zui.Key = undefined,
    key_count: usize = 0,

    fn init(self: *ScriptedInputHarness) !void {
        self.* = .{ .raylib_host = undefined };
        try self.raylib_host.init(std.testing.io, .{ .title = "zui host suite", .size = .{ 320, 240 }, .visible = false });
    }

    fn deinit(self: *ScriptedInputHarness) void {
        self.raylib_host.deinit();
    }

    pub fn host(self: *ScriptedInputHarness) *zui_raylib.Host {
        return &self.raylib_host;
    }

    pub fn post(self: *ScriptedInputHarness, event: zui.Event) bool {
        var sample = self.held;
        switch (event) {
            .pointer_move => |move| sample.pointer = move.pointer.position,
            .pointer_down => |press| sample.buttons.insert(press.button),
            .pointer_up => |release| sample.buttons.remove(release.button),
            .key_down => |key| {
                self.keys[self.key_count] = .{key.key};
                sample.keys_pressed = &self.keys[self.key_count];
                self.key_count += 1;
            },
            .text => |typed| sample.text = typed,
            else => return false,
        }
        self.held = .{ .pointer = sample.pointer, .buttons = sample.buttons };
        self.raylib_host.script(sample) catch return false;
        return true;
    }

    pub fn close(self: *ScriptedInputHarness) void {
        self.raylib_host.close();
    }
};

test "the host passes zui's host suite" {
    var harness: ScriptedInputHarness = undefined;
    try harness.init();
    defer harness.deinit();
    try zui_testing.expectHostConforms(zui_raylib.Host, &harness, .{ .io = std.testing.io });
}

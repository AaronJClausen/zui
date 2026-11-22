const std = @import("std");
const builtin = @import("builtin");
const zui = @import("zui");
const zui_glyphs = @import("zui_glyphs");
const DrawList = @import("draw_list.zig").DrawList;

/// The browser's renderer: it draws a frame on the page's canvas that a
/// `.web` surface names, laying the frame out in a `DrawList` in the same
/// WebAssembly instance and handing it to that canvas's `FrameDrawer`
/// (`web/frame_drawer.mjs`), which draws it through WebGL 2. It draws any
/// text's fonts, from the text its `init` is given. It runs only in
/// WebAssembly; `RendererOn` draws onto a page of a test's own.
///
/// ```zig
/// const Ui = zui.Context(zui_app.contextConfig(zui_webgl.Renderer, .{ .Text = zui_truetype.Text }));
/// var renderer: zui_webgl.Renderer = .{};
/// try renderer.init(.{ .web = .{ .canvas = 0 } }, &text);
/// defer renderer.deinit();
/// try renderer.zuiSubmit(.{ .web = .{ .canvas = 0 } }, ui.endFrame());
/// ```
pub const Renderer = RendererOn(BrowserPage);

/// The renderer, drawing onto `Page`, which declares
/// `fn blursBackdrops(self: *Page, canvas: u32) bool`, whether the canvas
/// can blur, and `fn draw(self: *Page, canvas: u32, frame: *const
/// DrawnFrame) void`, valid only during the call.
pub fn RendererOn(comptime Page: type) type {
    return struct {
        const Self = @This();

        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.web);
        pub const zui_commands: zui.CommandSet = .initMany(&.{ .gradient, .shadow, .backdrop_blur, .transform, .material });
        pub const zui_corner_shapes: zui.CornerShapeSet = .initFull();
        pub const zui_extended_color = true;
        pub const ImageHandle = Image;
        pub const MaterialHandle = Material;

        page: Page = .{},
        draw_list: DrawList = undefined,
        fonts: zui_glyphs.Fonts = .none,
        drawn: DrawnFrame = undefined,

        /// Reserves the draw list. `text` is the frames' text contract, or
        /// anything `zui_glyphs.Fonts.of` erases, and must outlive the
        /// renderer.
        pub fn init(self: *Self, surface: zui.Surface, text: anytype) error{ UnsupportedSurface, OutOfMemory }!void {
            _ = try canvasOf(surface);
            self.draw_list = try .init(std.heap.page_allocator);
            self.fonts = .of(text);
        }

        pub fn deinit(self: *Self) void {
            self.draw_list.deinit(std.heap.page_allocator);
        }

        pub fn zuiSubmit(self: *Self, surface: zui.Surface, frame: anytype) error{UnsupportedSurface}!void {
            const canvas = try canvasOf(surface);
            self.draw_list.blurs_backdrops = self.page.blursBackdrops(canvas);
            self.draw_list.layOut(frame.commands(), frame.params, &self.fonts);
            self.drawn = .of(&self.draw_list, frame.params);
            self.page.draw(canvas, &self.drawn);
        }

        /// A canvas given back, as after a lost WebGL context, whose page
        /// starts again without the glyph atlas: the next frame hands over
        /// all of its texels.
        pub fn zuiAttachSurface(self: *Self, surface: zui.Surface) error{UnsupportedSurface}!void {
            _ = try canvasOf(surface);
            self.draw_list.glyph_atlas.changed = true;
        }

        /// The page keeps nothing of a canvas taken away.
        pub fn zuiDetachSurface(_: *Self, _: zui.Surface) void {}

        /// Since `init`, how often a frame left a shape out, drew a clip or
        /// transform as its parent, or a blur or material as what it lowers
        /// to, because the draw list was full.
        pub fn drawListOverflows(self: *const Self) u32 {
            const list = &self.draw_list;
            return list.vertex_overflows + list.batch_overflows + list.transform_overflows + list.effect_overflows;
        }

        /// Since `init`, how often a frame left glyphs out because the atlas
        /// was full, or a glyph could not be rasterized.
        pub fn glyphOverflows(self: *const Self) u32 {
            return self.draw_list.glyph_atlas.overflows + self.draw_list.glyph_atlas.raster_refusals;
        }

        fn canvasOf(surface: zui.Surface) error{UnsupportedSurface}!u32 {
            return switch (surface) {
                .web => |web| web.canvas,
                else => error.UnsupportedSurface,
            };
        }
    };
}

/// A frame laid out, as the page's `FrameDrawer` reads it from the
/// WebAssembly instance's memory: the draw list's vertices, batches,
/// backdrop blurs, their taps and materials, and the glyph atlas's texels
/// when they changed since the frame before.
pub const DrawnFrame = extern struct {
    vertices: [*]const DrawList.Vertex,
    vertex_count: u32,
    batches: [*]const DrawList.Batch,
    batch_count: u32,
    backdrop_blurs: [*]const DrawList.BackdropBlur,
    backdrop_blur_count: u32,
    blur_taps: [*]const DrawList.BlurTap,
    blur_tap_count: u32,
    materials: [*]const DrawList.Material,
    material_count: u32,
    /// `GlyphAtlas.side` squared pairs of bytes for an RG8 texture sampled
    /// linearly, or null when the page's copy is current.
    changed_glyph_atlas: ?[*]const u8,
    /// In layout units.
    viewport: [2]f32,
    /// The frame's scale times its zoom.
    pixels_per_unit: f32,

    /// Takes the atlas's change, so the next frame hands its texels only if
    /// they change again.
    pub fn of(list: *const DrawList, params: zui.FrameParams) DrawnFrame {
        const atlas = list.glyph_atlas;
        const changed_glyph_atlas: ?[*]const u8 = if (atlas.changed) @ptrCast(&atlas.texels) else null;
        atlas.changed = false;
        return .{
            .vertices = list.vertex_storage.ptr,
            .vertex_count = list.vertex_count,
            .batches = list.batch_storage.ptr,
            .batch_count = list.batch_count,
            .backdrop_blurs = list.backdrop_blur_storage.ptr,
            .backdrop_blur_count = list.backdrop_blur_count,
            .blur_taps = list.blur_tap_storage.ptr,
            .blur_tap_count = list.blur_tap_count,
            .materials = list.material_storage.ptr,
            .material_count = list.material_count,
            .changed_glyph_atlas = changed_glyph_atlas,
            .viewport = params.viewport,
            .pixels_per_unit = params.scale * params.zoom,
        };
    }
};

/// The page that loaded the module, through the imports `FrameDrawer`
/// gives it.
pub const BrowserPage = struct {
    extern "zui_webgl" fn zuiWebglBlursBackdrops(canvas: u32) bool;
    extern "zui_webgl" fn zuiWebglDraw(canvas: u32, frame: *const DrawnFrame) void;

    pub fn blursBackdrops(_: *BrowserPage, canvas: u32) bool {
        requireWebAssembly();
        return zuiWebglBlursBackdrops(canvas);
    }

    pub fn draw(_: *BrowserPage, canvas: u32, frame: *const DrawnFrame) void {
        requireWebAssembly();
        zuiWebglDraw(canvas, frame);
    }

    fn requireWebAssembly() void {
        if (comptime !builtin.cpu.arch.isWasm()) @compileError("zui_webgl: Renderer draws through the page that loaded its WebAssembly, so it draws only there; elsewhere, draw onto a page of your own with zui_webgl.RendererOn(Page)");
    }
};

/// A texture by the ids of a view and a sampler, as the sokol renderer
/// names one. The page does not draw images yet.
pub const Image = struct {
    view: Id,
    sampler: Id,

    pub const Id = struct { id: u32 = 0 };
};

/// A pattern between two colors, drawn by its own shader over the element,
/// in its corners, as the sokol renderer's materials are.
///
/// ```zig
/// ui.open(.{ .decoration = .{
///     .background = .rgb(0x1a3050),
///     .material = .{ .pattern = .aurora, .first = .rgb(0x10304a), .second = .rgb(0x40e0a0), .phase = seconds / 8 },
///     .corner_radius = .all(12),
/// } });
/// ```
pub const Material = struct {
    pattern: Pattern = .solid,
    first: zui.Color,
    second: zui.Color = .transparent,
    /// Where the pattern is in its cycle, in turns; a pattern moves as its
    /// phase grows, and repeats each whole turn.
    phase: f32 = 0,
    /// The width of one wave of `aurora`, in layout units.
    scale: f32 = 48,

    pub const Pattern = enum(u8) {
        /// `first` alone.
        solid,
        /// `first` with a soft band of `second` sweeping across it from the
        /// top left to the bottom right once per turn of the phase.
        sheen,
        /// `first` and `second` flowing into each other in waves.
        aurora,
    };
};

comptime {
    if (@sizeOf(usize) == 4) {
        const expected_offsets = .{
            .{ "vertices", 0 },         .{ "vertex_count", 4 },         .{ "batches", 8 },
            .{ "batch_count", 12 },     .{ "backdrop_blurs", 16 },      .{ "backdrop_blur_count", 20 },
            .{ "blur_taps", 24 },       .{ "blur_tap_count", 28 },      .{ "materials", 32 },
            .{ "material_count", 36 },  .{ "changed_glyph_atlas", 40 }, .{ "viewport", 44 },
            .{ "pixels_per_unit", 52 },
        };
        for (expected_offsets) |field| std.debug.assert(@offsetOf(DrawnFrame, field[0]) == field[1]);
        std.debug.assert(@sizeOf(DrawnFrame) == 56);
    }
}

/// A page that keeps what it was handed, and blurs unless told not to.
const KeptPage = struct {
    blurs: bool = true,
    draws: u32 = 0,
    canvas: u32 = 0,
    frame: DrawnFrame = undefined,

    pub fn blursBackdrops(self: *KeptPage, _: u32) bool {
        return self.blurs;
    }

    pub fn draw(self: *KeptPage, canvas: u32, frame: *const DrawnFrame) void {
        self.draws += 1;
        self.canvas = canvas;
        self.frame = frame.*;
    }
};

const TestRenderer = RendererOn(KeptPage);
const TestUi = zui.Context(.{
    .commands = TestRenderer.zui_commands,
    .extended_color = TestRenderer.zui_extended_color,
    .ImageHandle = TestRenderer.ImageHandle,
    .MaterialHandle = TestRenderer.MaterialHandle,
    .corner_shapes = TestRenderer.zui_corner_shapes,
    .limits = .{ .max_elements = 8 },
});

const ListedFrame = struct {
    params: zui.FrameParams,
    list: []const TestUi.RenderCommand,

    pub fn commands(self: *const ListedFrame) []const TestUi.RenderCommand {
        return self.list;
    }
};

test "a context configured for the renderer declares exactly the commands it draws" {
    const Payload = TestUi.RenderCommand.Payload;
    inline for (.{ "gradient", "shadow", "backdrop_blur", "transform_begin", "transform_end", "material", "image" }) |command| try std.testing.expect(@hasField(Payload, command));
    comptime zui.checkRenderer(Renderer);
    comptime zui.checkRenderer(TestRenderer);
}

test "a frame is laid out and handed to the canvas its surface names, the atlas only when it changed or the canvas came back" {
    const boxes: zui_glyphs.testing.BoxFonts = .{};
    var renderer: TestRenderer = .{};
    try renderer.init(.{ .web = .{ .canvas = 3 } }, &boxes);
    defer renderer.deinit();
    const square = [_]TestUi.RenderCommand{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .id = 1, .payload = .{ .rectangle = .{ .color = .rgb(0x102030), .corner_radius = .zero } } },
        .{ .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 10 }, .id = 2, .payload = .{ .text = .{ .content = "Hi", .style = .{ .size = 10, .color = .white }, .line = 0 } } },
    };
    const frame: ListedFrame = .{ .params = .{ .now = .zero, .viewport = .{ 40, 20 }, .scale = 2 }, .list = &square };

    try renderer.zuiSubmit(.{ .web = .{ .canvas = 3 } }, &frame);
    try std.testing.expectEqual(1, renderer.page.draws);
    try std.testing.expectEqual(3, renderer.page.canvas);
    const drawn = renderer.page.frame;
    try std.testing.expectEqual(renderer.draw_list.vertex_count, drawn.vertex_count);
    try std.testing.expect(drawn.vertex_count >= 6);
    try std.testing.expectEqual(renderer.draw_list.batch_count, drawn.batch_count);
    try std.testing.expectEqualDeep([2]f32{ 40, 20 }, drawn.viewport);
    try std.testing.expectEqual(2, drawn.pixels_per_unit);
    try std.testing.expect(drawn.changed_glyph_atlas != null);

    try renderer.zuiSubmit(.{ .web = .{ .canvas = 3 } }, &frame);
    try std.testing.expectEqual(null, renderer.page.frame.changed_glyph_atlas);
    try std.testing.expectEqual(0, renderer.drawListOverflows());
    try std.testing.expectEqual(0, renderer.glyphOverflows());

    renderer.zuiDetachSurface(.{ .web = .{ .canvas = 3 } });
    try renderer.zuiAttachSurface(.{ .web = .{ .canvas = 3 } });
    try renderer.zuiSubmit(.{ .web = .{ .canvas = 3 } }, &frame);
    try std.testing.expect(renderer.page.frame.changed_glyph_atlas != null);
    try std.testing.expectError(error.UnsupportedSurface, renderer.zuiAttachSurface(.{ .offscreen = .{ .size = .{ 1, 1 } } }));
}

test "a chamfered rectangle is a fan to one cut per corner, a continuous one to as many points as a round one" {
    var renderer: TestRenderer = .{};
    try renderer.init(.{ .web = .{ .canvas = 0 } }, &zui_glyphs.Fonts.none);
    defer renderer.deinit();
    const vertex_counts = [_]struct { zui.CornerShape, u32 }{ .{ .chamfer, 3 * 8 }, .{ .continuous, 3 * 4 * (DrawList.corner_segments + 1) }, .{ .round, 3 * 4 * (DrawList.corner_segments + 1) } };
    for (vertex_counts) |shape_and_count| {
        const shape, const vertex_count = shape_and_count;
        const shaped = [_]TestUi.RenderCommand{
            .{ .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 40 }, .id = 1, .payload = .{ .rectangle = .{ .color = .white, .corner_radius = .all(10), .corner_shape = shape } } },
        };
        try renderer.zuiSubmit(.{ .web = .{ .canvas = 0 } }, &ListedFrame{ .params = .{ .now = .zero, .viewport = .{ 40, 40 } }, .list = &shaped });
        try std.testing.expectEqual(vertex_count, renderer.draw_list.vertex_count);
    }
    renderer.draw_list.layOut(&[_]TestUi.RenderCommand{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 40 }, .id = 1, .payload = .{ .rectangle = .{ .color = .white, .corner_radius = .all(10), .corner_shape = .chamfer } } },
    }, .{ .now = .zero, .viewport = .{ 40, 40 } }, &zui_glyphs.Fonts.none);
    const cut_start = renderer.draw_list.vertices()[1].position;
    const cut_end = renderer.draw_list.vertices()[2].position;
    try std.testing.expectApproxEqAbs(@as(f32, 0), cut_start[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), cut_start[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), cut_end[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cut_end[1], 0.001);
}

test "a canvas that cannot blur has its backdrop blurs laid out as their tint" {
    var renderer: TestRenderer = .{ .page = .{ .blurs = false } };
    try renderer.init(.{ .web = .{ .canvas = 0 } }, &zui_glyphs.Fonts.none);
    defer renderer.deinit();
    const blurred = [_]TestUi.RenderCommand{
        .{ .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .id = 1, .payload = .{ .backdrop_blur = .{ .radius = 4, .tint = .rgba(0xffffff80) } } },
    };
    try renderer.zuiSubmit(.{ .web = .{ .canvas = 0 } }, &ListedFrame{ .params = .{ .now = .zero, .viewport = .{ 10, 10 } }, .list = &blurred });
    try std.testing.expectEqual(0, renderer.page.frame.backdrop_blur_count);
    try std.testing.expect(renderer.page.frame.vertex_count > 0);
}

test "a surface of another kind is refused" {
    var renderer: TestRenderer = .{};
    try std.testing.expectError(error.UnsupportedSurface, renderer.init(.{ .offscreen = .{ .size = .{ 1, 1 } } }, &zui_glyphs.Fonts.none));
    try renderer.init(.{ .web = .{ .canvas = 0 } }, &zui_glyphs.Fonts.none);
    defer renderer.deinit();
    try std.testing.expectError(error.UnsupportedSurface, renderer.zuiSubmit(.{ .offscreen = .{ .size = .{ 1, 1 } } }, &ListedFrame{ .params = .{ .now = .zero, .viewport = .{ 1, 1 } }, .list = &.{} }));
    try std.testing.expectEqual(0, renderer.page.draws);
}

const std = @import("std");
const zui = @import("zui");
const zui_glyphs = @import("zui_glyphs");
const GlyphAtlas = @import("root.zig").GlyphAtlas;
const backdrop_blur = @import("backdrop_blur.zig");
const PixelRegion = backdrop_blur.PixelRegion;
const Taps = backdrop_blur.Taps;
const SplitWeight = backdrop_blur.SplitWeight;

/// A frame's commands laid out as colored triangles in layout units, in
/// paint order, cut into batches that each draw under one scissor
/// rectangle, so the page draws a frame with one vertex buffer and one draw
/// call per batch. The geometry is the sokol renderer's, triangle for
/// triangle: rounded corners in eight segments, borders inside their
/// bounds, gradients in bands of OKLab color, shadows faded in rings, text
/// as a textured quad per glyph, and transforms applied to every vertex.
/// A backdrop blur runs before the batch that samples it, and a material
/// is a batch of its own, drawn by its pattern. Text is drawn where
/// `zui_glyphs` lays it out, from `glyph_atlas`; text in a font the text
/// has no face for is not drawn. Images are not laid out yet. Memory is
/// reserved by `init`.
///
/// ```zig
/// var draw_list: DrawList = try .init(gpa);
/// draw_list.layOut(frame.commands(), frame.params, &text);
/// if (draw_list.glyph_atlas.changed) upload(&draw_list.glyph_atlas.texels);
/// var next_blur: usize = 0;
/// for (draw_list.batches(), 0..) |batch, index| {
///     while (next_blur < draw_list.backdropBlurs().len and draw_list.backdropBlurs()[next_blur].before_batch == index) : (next_blur += 1) {
///         blur(draw_list.backdropBlurs()[next_blur], draw_list.blurTaps());
///     }
///     draw(draw_list.vertices()[batch.first_vertex..][0..batch.vertex_count], batch.scissor, batch.material);
/// }
/// ```
pub const DrawList = struct {
    pub const max_vertices = 1 << 18;
    pub const max_batches = 1024;
    /// As many as the sokol renderer blurs in a frame.
    pub const max_backdrop_blurs = 16;
    pub const max_blur_taps = max_backdrop_blurs * 2 * Taps.max_count;
    /// As many as the sokol renderer draws in a frame.
    pub const max_materials = 256;
    /// Triangles per rounded corner, as the sokol renderer draws them.
    pub const corner_segments = 8;

    /// As the page's WebGL reads it.
    pub const Vertex = extern struct {
        position: [2]f32,
        color: zui.Color,
        texture: Texture = .none,
        /// For `.glyph_atlas`, the texture coordinates at the window's origin, from which
        /// `texture_per_unit` finds each pixel's, the same at every vertex
        /// of a glyph. For `.material`, the vertex's position from the
        /// element's top left, in its layout units, where the pattern is
        /// found.
        texture_coordinates: [2]f32 = .{ 0, 0 },
        /// For `.glyph_atlas`, how the texture coordinates change per
        /// layout unit along the window's x, then its y.
        texture_per_unit: [2][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 } },
        /// For `.glyph_atlas`, the glyph's texels: left, top, right and
        /// bottom. Its triangles reach past them, and a pixel whose
        /// texture coordinates fall outside is left as it was.
        texture_bounds: [4]f32 = .{ 0, 0, 0, 0 },
    };

    /// What a vertex's color is multiplied by.
    pub const Texture = enum(u32) {
        none,
        /// `glyph_atlas`, sampled linearly at texture coordinates the page
        /// finds from each pixel's position, which also decides whether
        /// the pixel is in the glyph. Interpolated between vertices, both
        /// would follow where the rasterizer snaps the vertices, which
        /// SwiftShader does to a sixteenth of a pixel, and a turned glyph
        /// would differ from the sokol renderer's by up to 31 levels.
        glyph_atlas,
        /// The last backdrop blur run, at this pixel, replacing what was
        /// drawn there.
        backdrop_blur,
        /// The batch's material, at `texture_coordinates`.
        material,
    };

    pub const Batch = extern struct {
        first_vertex: u32,
        vertex_count: u32,
        /// In physical pixels from the bottom-left corner, as WebGL's
        /// `scissor` takes it.
        scissor: Scissor,
        /// Which of `materials()` the batch's `.material` vertices draw, or
        /// `no_material`.
        material: u32 = no_material,
    };

    pub const no_material = std.math.maxInt(u32);

    pub const Scissor = extern struct { x: i32, y: i32, width: i32, height: i32 };

    /// Run before batch `before_batch` is drawn: what was drawn so far,
    /// inside `region`, blurred along x by each of its taps into one float
    /// target, then that along y into another, which the batch's
    /// `.backdrop_blur` vertices sample. A sample past the region takes its
    /// edge pixel.
    pub const BackdropBlur = extern struct {
        before_batch: u32,
        first_tap: u32,
        tap_count: u32,
        /// In whole physical pixels from the top-left corner: left, top,
        /// right and bottom.
        region: [4]f32,
    };

    /// One sample of a blur along its axis: `offset` pixels from the pixel
    /// blurred, linearly filtered, scaled by `weight` and added to the
    /// target. Each Gaussian tap is two, as the sokol renderer adds its weight in
    /// two parts.
    pub const BlurTap = extern struct { offset: f32, weight: f32 };

    /// the sokol renderer's material shader's uniforms, colors in sRGB's encoding
    /// from 0 to 1.
    pub const Material = extern struct {
        first_color: [4]f32,
        second_color: [4]f32,
        size_and_scale: [4]f32,
        pattern_and_phase: [4]f32,
    };

    vertex_storage: []Vertex,
    batch_storage: []Batch,
    backdrop_blur_storage: []BackdropBlur,
    blur_tap_storage: []BlurTap,
    material_storage: []Material,
    glyph_atlas: *GlyphAtlas,
    vertex_count: u32 = 0,
    batch_count: u32 = 0,
    backdrop_blur_count: u32 = 0,
    blur_tap_count: u32 = 0,
    material_count: u32 = 0,
    /// False when the page cannot blur, so that blurs draw their tint
    /// alone, as the sokol renderer does on a GPU without float targets.
    blurs_backdrops: bool = true,
    /// Shapes left out of a frame because the vertices were full.
    vertex_overflows: u32 = 0,
    /// Clips that shared the last batch's scissor because the batches were
    /// full.
    batch_overflows: u32 = 0,
    /// Transforms nested deeper than `TransformStack` holds, drawn as
    /// their parent is.
    transform_overflows: u32 = 0,
    /// Blurs drawn as their tint alone, and materials as their fallback,
    /// because the frame had no room left for them.
    effect_overflows: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!DrawList {
        const vertex_storage = try gpa.alloc(Vertex, max_vertices);
        errdefer gpa.free(vertex_storage);
        const batch_storage = try gpa.alloc(Batch, max_batches);
        errdefer gpa.free(batch_storage);
        const backdrop_blur_storage = try gpa.alloc(BackdropBlur, max_backdrop_blurs);
        errdefer gpa.free(backdrop_blur_storage);
        const blur_tap_storage = try gpa.alloc(BlurTap, max_blur_taps);
        errdefer gpa.free(blur_tap_storage);
        const material_storage = try gpa.alloc(Material, max_materials);
        errdefer gpa.free(material_storage);
        const glyph_atlas: *GlyphAtlas = try .create(gpa);
        errdefer glyph_atlas.destroy(gpa);
        return .{
            .vertex_storage = vertex_storage,
            .batch_storage = batch_storage,
            .backdrop_blur_storage = backdrop_blur_storage,
            .blur_tap_storage = blur_tap_storage,
            .material_storage = material_storage,
            .glyph_atlas = glyph_atlas,
        };
    }

    pub fn deinit(self: *DrawList, gpa: std.mem.Allocator) void {
        self.glyph_atlas.destroy(gpa);
        gpa.free(self.material_storage);
        gpa.free(self.blur_tap_storage);
        gpa.free(self.backdrop_blur_storage);
        gpa.free(self.batch_storage);
        gpa.free(self.vertex_storage);
    }

    pub fn vertices(self: *const DrawList) []const Vertex {
        return self.vertex_storage[0..self.vertex_count];
    }

    pub fn batches(self: *const DrawList) []const Batch {
        return self.batch_storage[0..self.batch_count];
    }

    /// In the order they run, which is the order of their batches.
    pub fn backdropBlurs(self: *const DrawList) []const BackdropBlur {
        return self.backdrop_blur_storage[0..self.backdrop_blur_count];
    }

    pub fn blurTaps(self: *const DrawList) []const BlurTap {
        return self.blur_tap_storage[0..self.blur_tap_count];
    }

    pub fn materials(self: *const DrawList) []const Material {
        return self.material_storage[0..self.material_count];
    }

    /// Replaces what was laid out before with `commands`, a frame's,
    /// drawn into a target of `params.viewport` units at
    /// `params.scale × params.zoom` pixels each, its text in the fonts of
    /// `text`, the text contract the frame was measured with, or anything
    /// `zui_glyphs.Fonts.of` erases. The atlas gains the glyphs the frame
    /// needs.
    pub fn layOut(self: *DrawList, commands: anytype, params: zui.FrameParams, text: anytype) void {
        var builder: Builder = .{ .list = self, .viewport = params.viewport, .pixels_per_unit = params.scale * params.zoom };
        const fonts = zui_glyphs.Fonts.of(text);
        self.glyph_atlas.addFrameGlyphs(fonts, commands, builder.pixels_per_unit);
        self.vertex_count = 0;
        self.batch_count = 0;
        self.backdrop_blur_count = 0;
        self.blur_tap_count = 0;
        self.material_count = 0;
        builder.beginBatch(null);
        var clips: ClipStack = .{};
        var transforms: TransformStack = .{};
        for (commands) |command| {
            const bounds = command.bounds;
            builder.to_window = transforms.current();
            builder.beginShape();
            switch (command.payload) {
                .rectangle => |rectangle| builder.fillRectangle(bounds, rectangle.corner_radius, colorOf(rectangle.color)),
                .border => |border| builder.strokeBorder(bounds, border.widths, border.corner_radius, colorOf(border.color)),
                .gradient => |gradient| builder.fillGradient(bounds, gradient),
                .shadow => |shadow| builder.drawShadow(bounds, shadow),
                .backdrop_blur => |blur| builder.drawBackdropBlur(bounds, blur),
                .material => |material| builder.drawMaterial(bounds, material),
                .text => |line| if (fonts.fontMetrics(line.style.font) != null) {
                    builder.drawTrueTypeText(fonts, self.glyph_atlas, line.content, bounds, line.style);
                },
                .clip_begin => |clip| {
                    clips.push(if (transforms.isActive()) transforms.current().boundsOf(clip).intersect(clips.current() orelse wholeViewport(params.viewport)) else clip);
                    builder.beginBatch(clips.current());
                },
                .clip_end => {
                    clips.pop();
                    builder.beginBatch(clips.current());
                },
                .transform_begin => |transform| if (!transforms.push(transform.affine(bounds))) {
                    self.transform_overflows += 1;
                },
                .transform_end => transforms.pop(),
                else => {},
            }
            builder.endShape();
        }
    }
};

const Builder = struct {
    list: *DrawList,
    viewport: [2]f32,
    pixels_per_unit: f32,
    to_window: zui.Affine = .identity,
    shape_start: u32 = 0,
    shape_overflowed: bool = false,

    fn beginShape(self: *Builder) void {
        self.shape_start = self.list.vertex_count;
        self.shape_overflowed = false;
    }

    /// A shape that did not fit whole is left out whole, from every batch
    /// it reached.
    fn endShape(self: *Builder) void {
        if (!self.shape_overflowed) return;
        const list = self.list;
        list.vertex_count = self.shape_start;
        var index = list.batch_count;
        while (index > 0) {
            index -= 1;
            const batch = &list.batch_storage[index];
            if (batch.first_vertex + batch.vertex_count <= self.shape_start) break;
            batch.first_vertex = @min(batch.first_vertex, self.shape_start);
            batch.vertex_count = self.shape_start - batch.first_vertex;
        }
        list.vertex_overflows += 1;
    }

    fn beginBatch(self: *Builder, clip: ?zui.Rect) void {
        if (!self.beginBatchWith(self.scissorOf(clip orelse wholeViewport(self.viewport)), DrawList.no_material)) {
            self.list.batch_overflows += 1;
        }
    }

    /// A batch with nothing in it yet is taken over instead. False, starting
    /// nothing, when the batches are full.
    fn beginBatchWith(self: *Builder, scissor: DrawList.Scissor, material: u32) bool {
        const list = self.list;
        if (list.batch_count > 0) {
            const last = &list.batch_storage[list.batch_count - 1];
            if (last.vertex_count == 0) {
                last.scissor = scissor;
                last.material = material;
                return true;
            }
            if (list.batch_count == DrawList.max_batches) return false;
        }
        list.batch_storage[list.batch_count] = .{ .first_vertex = list.vertex_count, .vertex_count = 0, .scissor = scissor, .material = material };
        list.batch_count += 1;
        return true;
    }

    fn currentBatch(self: *const Builder) *DrawList.Batch {
        return &self.list.batch_storage[self.list.batch_count - 1];
    }

    /// Whether `count` batches more can begin, the current one taken over
    /// if it is empty.
    fn hasRoomForBatches(self: *const Builder, count: u32) bool {
        const reusable: u32 = if (self.currentBatch().vertex_count == 0) 1 else 0;
        return self.list.batch_count + count - reusable <= DrawList.max_batches;
    }

    /// As the sokol renderer blurs: inside the outline, what was drawn
    /// before blurred, then the tint over it. Drawn as the tint alone when
    /// the page cannot blur or the frame has no room left.
    fn drawBackdropBlur(self: *Builder, bounds: zui.Rect, blur: anytype) void {
        if (self.list.blurs_backdrops) {
            if (self.recordBackdropBlur(bounds, blur.radius)) {
                var outline: Outline = .{};
                outline.trace(bounds, blur.corner_radius, .{});
                self.fillOutlineWith(&outline, centerOf(bounds), .{ .position = undefined, .color = .white, .texture = .backdrop_blur }, null);
            }
        }
        self.fillRectangle(bounds, blur.corner_radius, colorOf(blur.tint));
    }

    /// Begins the batch the blur runs before. False when nothing is to be
    /// blurred: the region is empty, or the frame has no room, which is
    /// counted.
    fn recordBackdropBlur(self: *Builder, bounds: zui.Rect, radius: f32) bool {
        const list = self.list;
        const target_size: [2]f32 = .{ @round(self.viewport[0] * self.pixels_per_unit), @round(self.viewport[1] * self.pixels_per_unit) };
        const pixels_per_unit: [2]f32 = .{ target_size[0] / self.viewport[0], target_size[1] / self.viewport[1] };
        const region: PixelRegion = .covering(self.to_window.boundsOf(bounds), pixels_per_unit, target_size);
        if (region.isEmpty()) return false;
        const taps: Taps = .gaussian(radius * pixels_per_unit[0]);
        if (list.backdrop_blur_count == DrawList.max_backdrop_blurs or
            list.blur_tap_count + 2 * taps.count > DrawList.max_blur_taps or
            !self.hasRoomForBatches(1))
        {
            list.effect_overflows += 1;
            return false;
        }
        _ = self.beginBatchWith(self.currentBatch().scissor, DrawList.no_material);
        const first_tap = list.blur_tap_count;
        for (taps.weights[0..taps.count], taps.offsets[0..taps.count]) |weight, offset| {
            const split: SplitWeight = .of(weight);
            for ([2]f32{ split.coarseValue(), split.fineValue() }) |part| if (part > 0) {
                list.blur_tap_storage[list.blur_tap_count] = .{ .offset = offset, .weight = part };
                list.blur_tap_count += 1;
            };
        }
        list.backdrop_blur_storage[list.backdrop_blur_count] = .{
            .before_batch = list.batch_count - 1,
            .first_tap = first_tap,
            .tap_count = list.blur_tap_count - first_tap,
            .region = .{ region.left, region.top, region.right, region.bottom },
        };
        list.backdrop_blur_count += 1;
        return true;
    }

    /// A batch of its own, drawn by the sokol renderer's material shader inside the
    /// outline, and the batch after it begun for what follows. Drawn as its
    /// fallback when the frame has no room left.
    fn drawMaterial(self: *Builder, bounds: zui.Rect, material: anytype) void {
        const list = self.list;
        if (list.material_count == DrawList.max_materials or !self.hasRoomForBatches(2)) {
            list.effect_overflows += 1;
            self.fillRectangle(bounds, material.corner_radius, colorOf(material.fallback));
            return;
        }
        const scissor = self.currentBatch().scissor;
        _ = self.beginBatchWith(scissor, list.material_count);
        const handle = material.handle;
        const first = colorComponents(handle.first);
        list.material_storage[list.material_count] = .{
            .first_color = first,
            .second_color = if (handle.pattern == .solid) first else colorComponents(handle.second),
            .size_and_scale = .{ bounds.width, bounds.height, handle.scale, 0 },
            .pattern_and_phase = .{ @floatFromInt(@intFromEnum(handle.pattern)), handle.phase, 0, 0 },
        };
        list.material_count += 1;
        var outline: Outline = .{};
        outline.trace(bounds, material.corner_radius, .{});
        self.fillOutlineWith(&outline, centerOf(bounds), .{ .position = undefined, .color = .white, .texture = .material }, .{ bounds.x, bounds.y });
        _ = self.beginBatchWith(scissor, DrawList.no_material);
    }

    /// As a fan from `center`, each vertex `template` at its point, and,
    /// given `local_origin`, its texture coordinates the point's position
    /// from there.
    fn fillOutlineWith(self: *Builder, outline: *const Outline, center: [2]f32, template: DrawList.Vertex, local_origin: ?[2]f32) void {
        for (0..outline.count) |index| {
            const next = (index + 1) % outline.count;
            for ([3][2]f32{ center, outline.points[index], outline.points[next] }) |point| {
                var laid_out = template;
                laid_out.position = self.to_window.apply(point);
                if (local_origin) |origin| laid_out.texture_coordinates = .{ point[0] - origin[0], point[1] - origin[1] };
                self.add(laid_out);
            }
        }
    }

    /// Truncated to whole pixels, as sokol_gfx's `applyScissorRectf` does.
    fn scissorOf(self: *const Builder, clip: zui.Rect) DrawList.Scissor {
        const target_height: i32 = @intFromFloat(@round(self.viewport[1] * self.pixels_per_unit));
        const x: i32 = @intFromFloat(clip.x * self.pixels_per_unit);
        const y: i32 = @intFromFloat(clip.y * self.pixels_per_unit);
        const width: i32 = @intFromFloat(@max(0, clip.width * self.pixels_per_unit));
        const height: i32 = @intFromFloat(@max(0, clip.height * self.pixels_per_unit));
        return .{ .x = x, .y = target_height - (y + height), .width = width, .height = height };
    }

    fn vertex(self: *Builder, point: [2]f32, color: zui.Color) void {
        self.add(.{ .position = self.to_window.apply(point), .color = color });
    }

    fn add(self: *Builder, laid_out: DrawList.Vertex) void {
        const list = self.list;
        if (self.shape_overflowed) return;
        if (list.vertex_count == DrawList.max_vertices) {
            self.shape_overflowed = true;
            return;
        }
        list.vertex_storage[list.vertex_count] = laid_out;
        list.vertex_count += 1;
        list.batch_storage[list.batch_count - 1].vertex_count += 1;
    }

    /// As sokol_gl draws a quad: the triangles 0, 1, 2 and 0, 2, 3 of its
    /// corners, clockwise from the top left.
    fn quad(self: *Builder, corners: [4][2]f32, vertex_of_corner: [4]DrawList.Vertex) void {
        for ([_]usize{ 0, 1, 2, 0, 2, 3 }) |corner| {
            var laid_out = vertex_of_corner[corner];
            laid_out.position = self.to_window.apply(corners[corner]);
            self.add(laid_out);
        }
    }

    /// Drawn a pixel wider on every side, since the page decides pixel by
    /// pixel which are in the glyph.
    fn atlasGlyph(self: *Builder, box: Box, texture_box: Box, color: zui.Color) void {
        var window_corners: [4][2]f32 = undefined;
        for (box.corners(), &window_corners) |corner, *window_corner| window_corner.* = self.to_window.apply(corner);
        const mapping = TextureMapping.of(window_corners, texture_box) orelse return;
        const corner: DrawList.Vertex = .{
            .position = undefined,
            .color = color,
            .texture = .glyph_atlas,
            .texture_coordinates = mapping.at_origin,
            .texture_per_unit = mapping.per_unit,
            .texture_bounds = .{ texture_box.left, texture_box.top, texture_box.right, texture_box.bottom },
        };
        const margin = 1 / self.pixels_per_unit;
        const widened: Box = .{ .left = box.left - margin, .top = box.top - margin, .right = box.right + margin, .bottom = box.bottom + margin };
        self.quad(widened.corners(), @splat(corner));
    }

    fn drawTrueTypeText(self: *Builder, fonts: zui_glyphs.Fonts, atlas: *const GlyphAtlas, content: []const u8, bounds: zui.Rect, style: anytype) void {
        var quads = zui_glyphs.glyphQuads(fonts, atlas, content, bounds, style, self.pixels_per_unit) orelse return;
        const color = colorOf(style.color);
        while (quads.next()) |glyph| self.atlasGlyph(boxOf(glyph.position), boxOf(glyph.texture), color);
    }

    fn triangle(self: *Builder, points: [3][2]f32, color: zui.Color) void {
        for (points) |point| self.vertex(point, color);
    }

    fn fillRectangle(self: *Builder, bounds: zui.Rect, radius: zui.CornerRadius, color: zui.Color) void {
        if (!hasRoundedCorners(radius)) {
            const corners = cornersOf(bounds);
            self.triangle(.{ corners[0], corners[1], corners[2] }, color);
            self.triangle(.{ corners[0], corners[2], corners[3] }, color);
            return;
        }
        var outline: Outline = .{};
        outline.trace(bounds, radius, .{});
        self.fillOutline(&outline, centerOf(bounds), color);
    }

    /// As a fan from `center`, which an outline of a rounded rectangle
    /// always surrounds.
    fn fillOutline(self: *Builder, outline: *const Outline, center: [2]f32, color: zui.Color) void {
        self.fillOutlineWith(outline, center, .{ .position = undefined, .color = color }, null);
    }

    /// Inside the bounds, as CSS draws a border: a ring between the
    /// outline and one inset by each edge's width.
    fn strokeBorder(self: *Builder, bounds: zui.Rect, widths: zui.Edges, radius: zui.CornerRadius, color: zui.Color) void {
        var outer: Outline = .{};
        var inner: Outline = .{};
        outer.trace(bounds, radius, .{});
        inner.trace(bounds, radius, widths);
        for (0..outer.count) |index| {
            const next = (index + 1) % outer.count;
            self.triangle(.{ outer.points[index], outer.points[next], inner.points[next] }, color);
            self.triangle(.{ outer.points[index], inner.points[next], inner.points[index] }, color);
        }
    }

    /// WebGL blends vertex colors in sRGB's encoding, so the gradient is
    /// drawn in bands across it, each vertex taking the OKLab color at its
    /// point. A rounded rectangle is convex, so each band is the outline
    /// cut by the two lines that bound it.
    fn fillGradient(self: *Builder, bounds: zui.Rect, gradient: anytype) void {
        const band_length_limit = 4;
        const max_bands = 64;
        var outline: Outline = .{};
        outline.trace(bounds, gradient.corner_radius, .{});
        const direction: [2]f32 = .{ @cos(gradient.angle), @sin(gradient.angle) };
        const length = @abs(bounds.width * direction[0]) + @abs(bounds.height * direction[1]);
        const band_count: usize = @intFromFloat(std.math.clamp(@ceil(length / band_length_limit), 1, max_bands));
        const band_length = length / @as(f32, @floatFromInt(band_count));
        const center = centerOf(bounds);
        const reversed: [2]f32 = .{ -direction[0], -direction[1] };

        for (0..band_count) |band| {
            const start = -length / 2 + band_length * @as(f32, @floatFromInt(band));
            var past_start: ConvexPolygon = .{};
            past_start.cut(outline.points[0..outline.count], center, direction, start);
            var band_polygon: ConvexPolygon = .{};
            band_polygon.cut(past_start.points[0..past_start.count], center, reversed, -(start + band_length));
            if (band_polygon.count < 3) continue;
            const first = band_polygon.points[0];
            for (1..band_polygon.count - 1) |index| {
                for ([3][2]f32{ first, band_polygon.points[index], band_polygon.points[index + 1] }) |point| {
                    self.vertex(point, colorOf(gradient.colorAt(bounds, point)));
                }
            }
        }
    }

    /// The box at the shadow's offset, grown by its spread, in its color;
    /// then rings out to the blur, each fainter, easing out as a blurred
    /// edge does.
    fn drawShadow(self: *Builder, bounds: zui.Rect, shadow: anytype) void {
        const fade_rings = 6;
        const caster: zui.Rect = .{ .x = bounds.x + shadow.offset[0], .y = bounds.y + shadow.offset[1], .width = bounds.width, .height = bounds.height };
        const spread = @max(shadow.spread, -@min(caster.width, caster.height) / 2);
        var inner: Outline = .{};
        inner.trace(caster, shadow.corner_radius, .all(-spread));
        const shadow_color = colorOf(shadow.color);
        self.fillOutline(&inner, centerOf(caster), shadow_color);
        if (shadow.blur <= 0) return;

        var inner_color = shadow_color;
        for (1..fade_rings + 1) |ring| {
            const reached = @as(f32, @floatFromInt(ring)) / fade_rings;
            var outer: Outline = .{};
            outer.trace(caster, shadow.corner_radius, .all(-(spread + shadow.blur * reached)));
            var outer_color = shadow_color;
            outer_color.a = @intFromFloat(@round(@as(f32, @floatFromInt(shadow_color.a)) * (1 - smoothstep(reached))));
            for (0..outer.count) |index| {
                const next = (index + 1) % outer.count;
                self.vertex(inner.points[index], inner_color);
                self.vertex(outer.points[index], outer_color);
                self.vertex(outer.points[next], outer_color);
                self.vertex(inner.points[index], inner_color);
                self.vertex(outer.points[next], outer_color);
                self.vertex(inner.points[next], inner_color);
            }
            inner = outer;
            inner_color = outer_color;
        }
    }
};

/// An 8-bit target holds sRGB's encoding, so an extended color is clamped
/// into it.
fn colorOf(color: anytype) zui.Color {
    return if (@TypeOf(color) == zui.ExtendedColor) color.toColor() else color;
}

fn colorComponents(color: zui.Color) [4]f32 {
    return .{
        @as(f32, @floatFromInt(color.r)) / 255,
        @as(f32, @floatFromInt(color.g)) / 255,
        @as(f32, @floatFromInt(color.b)) / 255,
        @as(f32, @floatFromInt(color.a)) / 255,
    };
}

/// A rectangle by its edges, in layout units or texture coordinates.
const Box = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    /// Clockwise from the top left.
    fn corners(self: Box) [4][2]f32 {
        return .{ .{ self.left, self.top }, .{ self.right, self.top }, .{ self.right, self.bottom }, .{ self.left, self.bottom } };
    }
};

/// The affine map from a window position to the texture coordinates that a
/// quad's interpolation would give there.
const TextureMapping = struct {
    at_origin: [2]f32,
    per_unit: [2][2]f32,

    /// Null for a quad with no area.
    fn of(window_corners: [4][2]f32, texture_box: Box) ?TextureMapping {
        const origin = widen(window_corners[0]);
        const across = difference(widen(window_corners[1]), origin);
        const down = difference(widen(window_corners[3]), origin);
        const determinant = across[0] * down[1] - across[1] * down[0];
        if (determinant == 0) return null;
        const texture_origin: [2]f64 = .{ texture_box.left, texture_box.top };
        const texture_across = @as(f64, texture_box.right) - texture_origin[0];
        const texture_down = @as(f64, texture_box.bottom) - texture_origin[1];
        const per_x: [2]f64 = .{ texture_across * down[1] / determinant, -texture_down * across[1] / determinant };
        const per_y: [2]f64 = .{ -texture_across * down[0] / determinant, texture_down * across[0] / determinant };
        return .{
            .at_origin = .{
                @floatCast(texture_origin[0] - per_x[0] * origin[0] - per_y[0] * origin[1]),
                @floatCast(texture_origin[1] - per_x[1] * origin[0] - per_y[1] * origin[1]),
            },
            .per_unit = .{ .{ @floatCast(per_x[0]), @floatCast(per_x[1]) }, .{ @floatCast(per_y[0]), @floatCast(per_y[1]) } },
        };
    }

    fn widen(point: [2]f32) [2]f64 {
        return .{ point[0], point[1] };
    }

    fn difference(to: [2]f64, from: [2]f64) [2]f64 {
        return .{ to[0] - from[0], to[1] - from[1] };
    }
};

fn boxOf(edges: zui_glyphs.Edges) Box {
    return .{ .left = edges.left, .top = edges.top, .right = edges.right, .bottom = edges.bottom };
}

fn smoothstep(amount: f32) f32 {
    return amount * amount * (3 - 2 * amount);
}

fn hasRoundedCorners(radius: zui.CornerRadius) bool {
    return radius.top_left > 0 or radius.top_right > 0 or radius.bottom_left > 0 or radius.bottom_right > 0;
}

fn cornersOf(bounds: zui.Rect) [4][2]f32 {
    return .{
        .{ bounds.x, bounds.y },
        .{ bounds.x + bounds.width, bounds.y },
        .{ bounds.x + bounds.width, bounds.y + bounds.height },
        .{ bounds.x, bounds.y + bounds.height },
    };
}

fn centerOf(bounds: zui.Rect) [2]f32 {
    return .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 };
}

fn wholeViewport(viewport: [2]f32) zui.Rect {
    return .{ .x = 0, .y = 0, .width = viewport[0], .height = viewport[1] };
}

/// The points around a rounded rectangle, clockwise from the top-left
/// corner, with the same number of points for any radius so that two
/// outlines of one rectangle can be joined point by point.
const Outline = struct {
    const max_points = 4 * (DrawList.corner_segments + 1);

    points: [max_points][2]f32 = undefined,
    count: usize = 0,

    fn trace(self: *Outline, bounds: zui.Rect, radius: zui.CornerRadius, inset: zui.Edges) void {
        const segments = DrawList.corner_segments;
        const left = bounds.x + inset.left;
        const top = bounds.y + inset.top;
        const right = bounds.x + bounds.width - inset.right;
        const bottom = bounds.y + bounds.height - inset.bottom;
        const limit = @max(0, @min(right - left, bottom - top) / 2);
        const corners = [4]struct { center_x: f32, center_y: f32, radius: f32, start_angle: f32 }{
            .{ .center_x = left, .center_y = top, .radius = radius.top_left - @max(inset.left, inset.top), .start_angle = std.math.pi },
            .{ .center_x = right, .center_y = top, .radius = radius.top_right - @max(inset.right, inset.top), .start_angle = 1.5 * std.math.pi },
            .{ .center_x = right, .center_y = bottom, .radius = radius.bottom_right - @max(inset.right, inset.bottom), .start_angle = 0 },
            .{ .center_x = left, .center_y = bottom, .radius = radius.bottom_left - @max(inset.left, inset.bottom), .start_angle = 0.5 * std.math.pi },
        };
        self.count = 0;
        for (corners, 0..) |corner, corner_index| {
            const corner_radius = std.math.clamp(corner.radius, 0, limit);
            const is_left = corner_index == 0 or corner_index == 3;
            const is_top = corner_index < 2;
            const arc_center_x = if (is_left) corner.center_x + corner_radius else corner.center_x - corner_radius;
            const arc_center_y = if (is_top) corner.center_y + corner_radius else corner.center_y - corner_radius;
            for (0..segments + 1) |step| {
                const angle = corner.start_angle + 0.5 * std.math.pi * @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(segments));
                self.points[self.count] = .{ arc_center_x + @cos(angle) * corner_radius, arc_center_y + @sin(angle) * corner_radius };
                self.count += 1;
            }
        }
    }
};

const ConvexPolygon = struct {
    points: [Outline.max_points + 2][2]f32 = undefined,
    count: usize = 0,

    /// Keeps the part of `polygon` at least `distance` along `direction`
    /// from `origin`. Cutting a convex polygon by a line adds at most one
    /// point.
    fn cut(self: *ConvexPolygon, polygon: []const [2]f32, origin: [2]f32, direction: [2]f32, distance: f32) void {
        self.count = 0;
        for (polygon, 0..) |here, index| {
            const next = polygon[(index + 1) % polygon.len];
            const here_beyond = (here[0] - origin[0]) * direction[0] + (here[1] - origin[1]) * direction[1] - distance;
            const next_beyond = (next[0] - origin[0]) * direction[0] + (next[1] - origin[1]) * direction[1] - distance;
            if (here_beyond >= 0) self.add(here);
            if ((here_beyond >= 0) != (next_beyond >= 0)) {
                const along = here_beyond / (here_beyond - next_beyond);
                self.add(.{ here[0] + (next[0] - here[0]) * along, here[1] + (next[1] - here[1]) * along });
            }
        }
    }

    fn add(self: *ConvexPolygon, point: [2]f32) void {
        if (self.count == self.points.len) return;
        self.points[self.count] = point;
        self.count += 1;
    }
};

/// zui's clip rectangles are already intersected with every enclosing clip,
/// so `clip_end` only has to restore the enclosing one.
const ClipStack = struct {
    rects: [64]zui.Rect = undefined,
    depth: usize = 0,
    overflow: usize = 0,

    fn current(self: *const ClipStack) ?zui.Rect {
        return if (self.depth == 0) null else self.rects[self.depth - 1];
    }

    fn push(self: *ClipStack, rect: zui.Rect) void {
        if (self.depth == self.rects.len) {
            self.overflow += 1;
            return;
        }
        self.rects[self.depth] = rect;
        self.depth += 1;
    }

    fn pop(self: *ClipStack) void {
        if (self.overflow > 0) {
            self.overflow -= 1;
        } else if (self.depth > 0) {
            self.depth -= 1;
        }
    }
};

/// Each entry maps the units inside a transform to the window's, through
/// every transform around it.
const TransformStack = struct {
    to_window: [64]zui.Affine = undefined,
    depth: usize = 0,
    overflow: usize = 0,

    fn isActive(self: *const TransformStack) bool {
        return self.depth > 0;
    }

    fn current(self: *const TransformStack) zui.Affine {
        return if (self.depth == 0) .identity else self.to_window[self.depth - 1];
    }

    /// False when the stack is full, leaving `affine` unapplied.
    fn push(self: *TransformStack, affine: zui.Affine) bool {
        if (self.depth == self.to_window.len) {
            self.overflow += 1;
            return false;
        }
        self.to_window[self.depth] = self.current().after(affine);
        self.depth += 1;
        return true;
    }

    fn pop(self: *TransformStack) void {
        if (self.overflow > 0) {
            self.overflow -= 1;
        } else if (self.depth > 0) {
            self.depth -= 1;
        }
    }
};

test "a turned glyph's texture coordinates at each corner are the corner's" {
    const quarter_turn: zui.Affine = .{ .x_axis = .{ 0, 1 }, .y_axis = .{ -1, 0 }, .offset = .{ 100, 20 } };
    const box: Box = .{ .left = 10, .top = 4, .right = 18, .bottom = 16 };
    const texture_box: Box = .{ .left = 0.25, .top = 0.5, .right = 0.375, .bottom = 0.75 };
    var window_corners: [4][2]f32 = undefined;
    for (box.corners(), &window_corners) |corner, *window_corner| window_corner.* = quarter_turn.apply(corner);
    const mapping = TextureMapping.of(window_corners, texture_box).?;
    for (window_corners, texture_box.corners()) |window_corner, texture_corner| {
        const found: [2]f32 = .{
            mapping.at_origin[0] + mapping.per_unit[0][0] * window_corner[0] + mapping.per_unit[1][0] * window_corner[1],
            mapping.at_origin[1] + mapping.per_unit[0][1] * window_corner[0] + mapping.per_unit[1][1] * window_corner[1],
        };
        try std.testing.expectApproxEqAbs(texture_corner[0], found[0], 1e-6);
        try std.testing.expectApproxEqAbs(texture_corner[1], found[1], 1e-6);
    }
    try std.testing.expectEqual(null, TextureMapping.of(@splat(.{ 1, 1 }), texture_box));
}

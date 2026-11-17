const std = @import("std");
const zui = @import("zui");

/// A frame's commands laid out as colored triangles in layout units, in
/// paint order, cut into batches that each draw under one scissor
/// rectangle, so the page draws a frame with one vertex buffer and one draw
/// call per batch. The geometry is zui-sokol's renderer's, triangle for
/// triangle: rounded corners in eight segments, borders inside their
/// bounds, gradients in bands of OKLab color, shadows faded in rings, and
/// transforms applied to every vertex. Text, images, backdrop blurs and
/// materials are not laid out yet. Memory is reserved by `init`.
///
/// ```zig
/// var draw_list: DrawList = try .init(gpa);
/// draw_list.layOut(frame.commands(), frame.params);
/// for (draw_list.batches()) |batch| draw(draw_list.vertices()[batch.first_vertex..][0..batch.vertex_count], batch.scissor);
/// ```
pub const DrawList = struct {
    pub const max_vertices = 1 << 19;
    pub const max_batches = 1024;
    /// Triangles per rounded corner, as zui-sokol's renderer draws them.
    pub const corner_segments = 8;

    /// As the page's WebGL reads it: two floats, then four bytes.
    pub const Vertex = extern struct {
        position: [2]f32,
        color: zui.Color,
    };

    pub const Batch = extern struct {
        first_vertex: u32,
        vertex_count: u32,
        /// In physical pixels from the bottom-left corner, as WebGL's
        /// `scissor` takes it.
        scissor: Scissor,
    };

    pub const Scissor = extern struct { x: i32, y: i32, width: i32, height: i32 };

    vertex_storage: []Vertex,
    batch_storage: []Batch,
    vertex_count: u32 = 0,
    batch_count: u32 = 0,
    /// Shapes left out of a frame because the vertices were full.
    vertex_overflows: u32 = 0,
    /// Clips that shared the last batch's scissor because the batches were
    /// full.
    batch_overflows: u32 = 0,
    /// Transforms nested deeper than `TransformStack` holds, drawn as
    /// their parent is.
    transform_overflows: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!DrawList {
        const vertex_storage = try gpa.alloc(Vertex, max_vertices);
        errdefer gpa.free(vertex_storage);
        return .{ .vertex_storage = vertex_storage, .batch_storage = try gpa.alloc(Batch, max_batches) };
    }

    pub fn deinit(self: *DrawList, gpa: std.mem.Allocator) void {
        gpa.free(self.batch_storage);
        gpa.free(self.vertex_storage);
    }

    pub fn vertices(self: *const DrawList) []const Vertex {
        return self.vertex_storage[0..self.vertex_count];
    }

    pub fn batches(self: *const DrawList) []const Batch {
        return self.batch_storage[0..self.batch_count];
    }

    /// Replaces what was laid out before with `commands`, a frame's,
    /// drawn into a target of `params.viewport` units at
    /// `params.scale × params.zoom` pixels each.
    pub fn layOut(self: *DrawList, commands: anytype, params: zui.FrameParams) void {
        var builder: Builder = .{ .list = self, .viewport = params.viewport, .pixels_per_unit = params.scale * params.zoom };
        self.vertex_count = 0;
        self.batch_count = 0;
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

    /// A shape that did not fit whole is left out whole.
    fn endShape(self: *Builder) void {
        if (!self.shape_overflowed) return;
        const list = self.list;
        list.vertex_count = self.shape_start;
        const batch = &list.batch_storage[list.batch_count - 1];
        batch.vertex_count = list.vertex_count - batch.first_vertex;
        list.vertex_overflows += 1;
    }

    /// A batch with nothing in it yet takes the new scissor instead.
    fn beginBatch(self: *Builder, clip: ?zui.Rect) void {
        const list = self.list;
        const scissor = self.scissorOf(clip orelse wholeViewport(self.viewport));
        if (list.batch_count > 0) {
            const last = &list.batch_storage[list.batch_count - 1];
            if (last.vertex_count == 0) {
                last.scissor = scissor;
                return;
            }
            if (list.batch_count == DrawList.max_batches) {
                list.batch_overflows += 1;
                return;
            }
        }
        list.batch_storage[list.batch_count] = .{ .first_vertex = list.vertex_count, .vertex_count = 0, .scissor = scissor };
        list.batch_count += 1;
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
        const list = self.list;
        if (self.shape_overflowed) return;
        if (list.vertex_count == DrawList.max_vertices) {
            self.shape_overflowed = true;
            return;
        }
        list.vertex_storage[list.vertex_count] = .{ .position = self.to_window.apply(point), .color = color };
        list.vertex_count += 1;
        list.batch_storage[list.batch_count - 1].vertex_count += 1;
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
        for (0..outline.count) |index| {
            const next = (index + 1) % outline.count;
            self.triangle(.{ center, outline.points[index], outline.points[next] }, color);
        }
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

const std = @import("std");
const zui = @import("zui");
const DescribedViolation = @import("violation.zig").DescribedViolation;

pub const RendererConformance = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// How far each color channel read back may be from the color drawn.
    tolerance: u8 = 32,
};

pub const RendererError = error{ SubmitFailed, WrongColor, TextNotDrawn };
pub const RendererViolation = DescribedViolation(RendererError);

/// Every frame the suite draws is this size, in layout units at a scale
/// and zoom of 1, so one unit is one pixel.
pub const renderer_viewport: [2]u32 = .{ 320, 160 };

/// The colors of the reference scene, far enough apart that a renderer
/// within any sensible tolerance tells them apart.
pub const scene_colors = struct {
    pub const background: zui.Color = .rgb(0x203040);
    pub const fill: zui.Color = .rgb(0xff0000);
    pub const border: zui.Color = .rgb(0xff8000);
    pub const inner_clip: zui.Color = .rgb(0x00c000);
    pub const outer_clip: zui.Color = .rgb(0x0040ff);
    pub const after_clips: zui.Color = .rgb(0xff00ff);
    pub const text: zui.Color = .rgb(0xffff00);
    /// `harness.image` is asked for an image of this one color.
    pub const image: zui.Color = .rgb(0x00ffff);
    /// The reference scene's image is declared with this tint, so it
    /// draws as `tinted_image`: `image` multiplied by the tint.
    pub const image_tint: zui.Color = .rgb(0xffff80);
    pub const tinted_image: zui.Color = .rgb(0x00ff80);
};

/// The reference scene's image is rounded by this much, so a pixel just
/// inside its bounding corner lies outside the curve.
pub const image_corner_radius: f32 = 12;

/// Draws frames that every renderer must draw the same way, and fails on
/// the first thing it drew wrong:
/// - a reference scene of the base commands (a fill, a border, text, and
///   a clip inside a clip, each cutting off a child larger than itself),
///   with `image` and `custom` when the renderer has their payload types,
///   the image tinted and with rounded corners;
/// - clips nested 100 deep, then a fill drawn after all of them ended;
/// - commands of no size, and far outside the viewport;
/// - an empty frame;
/// - the reference scene again, which shows that nothing an earlier frame
///   set, such as a clip, outlived it.
///
/// With `pixel`, every frame is read back: each clip cuts off exactly what
/// lies outside it and is restored when the clip inside it ends, the
/// scene's colors are where its layout put them, the image's tint is
/// multiplied into its pixels, and its corners are left undrawn. Without it, the suite
/// checks only that each frame is drawn without an error.
///
/// `harness` is a pointer to a value that declares:
/// - `pub const config: zui.Config`, the backend's own (its `Text`,
///   commands and payload types); the suite sets the limits and `Sources`;
/// - `fn renderer(self) *Renderer`;
/// - `fn text(self) *config.Text`, when `config.Text` is not `void`;
/// - `fn beginDraw(self, size: [2]u32) zui.Surface`: prepare a target of
///   `size` pixels and return the surface to submit into;
/// - optionally `fn endDraw(self) void`, called after each `zuiSubmit`;
/// - optionally `fn pixel(self, x: u32, y: u32) zui.Color`: the color drawn
///   at that pixel, counted from the top left, after `endDraw`;
/// - `fn image(self, color: zui.Color) config.ImageHandle`: an image of one
///   color, when `config.ImageHandle` is not `void`;
/// - `fn custom(self) config.CustomData`, when `config.CustomData` is not `void`.
///
/// ```zig
/// test "the renderer conforms" {
///     var harness: OffscreenHarness = try .init();
///     defer harness.deinit();
///     try zui_testing.expectRendererConforms(zui_raylib.Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io });
/// }
/// ```
pub fn expectRendererConforms(comptime Renderer: type, harness: anytype, conformance: RendererConformance) !void {
    const violation = try findRendererViolation(Renderer, harness, conformance) orelse return;
    std.debug.print("zui_testing.expectRendererConforms: {s} {s}\n", .{ @typeName(Renderer), violation.description() });
    return violation.kind;
}

const Scene = enum {
    reference,
    deep_clips,
    out_of_bounds,
    empty,

    fn description(scene: Scene) []const u8 {
        return switch (scene) {
            .reference => "the reference scene",
            .deep_clips => "clips nested 100 deep",
            .out_of_bounds => "commands of no size or out of bounds",
            .empty => "an empty frame",
        };
    }
};

const scenes = [_]Scene{ .reference, .deep_clips, .out_of_bounds, .empty, .reference };
const deep_clip_count = 100;

const ids = zui.ids(.{ "panel", "fill", "frame", "outer", "inner", "picture", "custom", "nest", "after_nest" });

fn suiteConfig(comptime backend: zui.Config) zui.Config {
    var config = backend;
    config.limits = .{
        .max_elements = 256,
        .max_depth = deep_clip_count + 16,
        .max_text_bytes = 1024,
        .max_render_commands = 1024,
        .state_slots = 64,
        .measure_cache_entries = 64,
        .string_cache_entries = 64,
    };
    config.Sources = void;
    return config;
}

/// `expectRendererConforms` without printing: the first violation, or null.
pub fn findRendererViolation(comptime Renderer: type, harness: anytype, conformance: RendererConformance) !?RendererViolation {
    comptime zui.checkRenderer(Renderer);
    const Harness = @typeInfo(@TypeOf(harness)).pointer.child;
    const config = suiteConfig(Harness.config);
    const Ui = zui.Context(config);
    const Payloads = struct { image: config.ImageHandle, custom: config.CustomData };

    var ui: Ui = if (Ui.has_text) try .init(conformance.gpa, conformance.io, harness.text()) else try .init(conformance.gpa, conformance.io);
    defer ui.deinit(conformance.gpa);
    const payloads: Payloads = .{
        .image = if (config.ImageHandle == void) {} else harness.image(scene_colors.image),
        .custom = if (config.CustomData == void) {} else harness.custom(),
    };
    const renderer: *Renderer = harness.renderer();

    for (scenes, 0..) |scene, frame_number| {
        ui.beginFrame(&.{ .params = .{
            .now = .fromNanoseconds(frame_number * std.time.ns_per_s / 60),
            .viewport = .{ @floatFromInt(renderer_viewport[0]), @floatFromInt(renderer_viewport[1]) },
        } });
        switch (scene) {
            .reference => declareReference(&ui, config, payloads),
            .deep_clips => declareDeepClips(&ui),
            .out_of_bounds => declareOutOfBounds(&ui),
            .empty => {},
        }
        const frame = ui.endFrame();
        defer ui.release(frame);
        try frame.diagnostics.check();

        const surface = harness.beginDraw(renderer_viewport);
        renderer.zuiSubmit(surface, frame) catch |err| {
            return .init(error.SubmitFailed, "returned error.{t} drawing {s}", .{ err, scene.description() });
        };
        if (@hasDecl(Harness, "endDraw")) harness.endDraw();
        if (!@hasDecl(Harness, "pixel")) continue;

        const pixels: PixelCheck(Harness) = .{ .harness = harness, .tolerance = conformance.tolerance, .scene = scene };
        const found = switch (scene) {
            .reference => pixels.reference(frame, config.ImageHandle != void),
            .deep_clips => pixels.deepClips(frame),
            .out_of_bounds, .empty => null,
        };
        if (found) |violation| return violation;
    }
    return null;
}

fn fixedSize(width: f32, height: f32) zui.Sizing2 {
    return .{ .width = .fixed(width), .height = .fixed(height) };
}

/// Laid out at 16-unit steps, so that a renderer drawing cells of 8 by 16,
/// as a terminal does, covers whole cells.
fn declareReference(ui: anytype, comptime config: zui.Config, payloads: anytype) void {
    ui.open(.{ .id = ids.panel, .decoration = .{ .background = scene_colors.background }, .layout = .{
        .sizing = fixedSize(renderer_viewport[0], renderer_viewport[1]),
        .padding = .all(16),
        .child_gap = 16,
        .direction = .top_to_bottom,
    } });
    {
        ui.open(.{ .layout = .{ .child_gap = 16 } });
        ui.box(.{ .id = ids.fill, .decoration = .{ .background = scene_colors.fill }, .layout = .{ .sizing = fixedSize(64, 48) } });
        ui.box(.{ .id = ids.frame, .decoration = .{ .border = .{ .color = scene_colors.border, .widths = .all(4) } }, .layout = .{ .sizing = fixedSize(64, 64) } });
        ui.open(.{ .id = ids.outer, .clip = .both, .layout = .{ .sizing = fixedSize(64, 64), .direction = .top_to_bottom } });
        {
            ui.open(.{ .id = ids.inner, .clip = .both, .layout = .{ .sizing = fixedSize(32, 32) } });
            ui.box(.{ .decoration = .{ .background = scene_colors.inner_clip }, .layout = .{ .sizing = fixedSize(128, 128) } });
            ui.close();
            ui.box(.{ .decoration = .{ .background = scene_colors.outer_clip }, .layout = .{ .sizing = fixedSize(128, 128) } });
        }
        ui.close();
        ui.box(.{ .id = ids.after_nest, .decoration = .{ .background = scene_colors.after_clips }, .layout = .{ .sizing = fixedSize(32, 32) } });
        ui.close();
    }
    {
        ui.open(.{ .layout = .{ .child_gap = 16 } });
        if (config.ImageHandle != void) ui.image(.{
            .handle = payloads.image,
            .tint = scene_colors.image_tint,
            .corner_radius = .all(image_corner_radius),
        }, .{ .id = ids.picture, .layout = .{ .sizing = fixedSize(32, 32) } });
        if (config.CustomData != void) ui.custom(payloads.custom, .{ .id = ids.custom, .layout = .{ .sizing = fixedSize(32, 32) } });
        if (config.Text != void) ui.text("MMMM", .{ .color = scene_colors.text });
        ui.close();
    }
    ui.close();
}

fn declareDeepClips(ui: anytype) void {
    const half: zui.Sizing2 = fixedSize(renderer_viewport[0], renderer_viewport[1] / 2);
    ui.open(.{ .id = ids.panel, .decoration = .{ .background = scene_colors.background }, .layout = .{ .direction = .top_to_bottom } });
    for (0..deep_clip_count) |depth| ui.open(.{ .id = if (depth == 0) ids.nest else .none, .clip = .both, .layout = .{ .sizing = half } });
    ui.box(.{ .decoration = .{ .background = scene_colors.inner_clip }, .layout = .{ .sizing = half } });
    for (0..deep_clip_count) |_| ui.close();
    ui.box(.{ .id = ids.after_nest, .decoration = .{ .background = scene_colors.after_clips }, .layout = .{ .sizing = half } });
    ui.close();
}

fn declareOutOfBounds(ui: anytype) void {
    ui.open(.{ .decoration = .{ .background = scene_colors.background }, .layout = .{ .child_gap = 16 } });
    ui.box(.{ .decoration = .{ .background = scene_colors.fill }, .layout = .{ .sizing = fixedSize(0, 0) } });
    ui.open(.{ .clip = .both, .layout = .{ .sizing = fixedSize(0, 0) } });
    ui.box(.{ .decoration = .{ .background = scene_colors.fill }, .layout = .{ .sizing = fixedSize(48, 48) } });
    ui.close();
    ui.box(.{ .decoration = .{ .background = scene_colors.fill, .border = .{ .color = scene_colors.border, .widths = .all(2) } }, .layout = .{ .sizing = fixedSize(100_000, 24) } });
    ui.box(.{ .decoration = .{ .background = scene_colors.fill }, .layout = .{ .sizing = fixedSize(48, 48) } });
    ui.close();
}

fn PixelCheck(comptime Harness: type) type {
    return struct {
        const Self = @This();

        harness: *Harness,
        tolerance: u8,
        scene: Scene,

        fn reference(self: Self, frame: anytype, has_image: bool) ?RendererViolation {
            const fill = frame.rectOf(ids.fill).?;
            const bordered = frame.rectOf(ids.frame).?;
            const outer = frame.rectOf(ids.outer).?;
            const inner = frame.rectOf(ids.inner).?;
            const after = frame.rectOf(ids.after_nest).?;
            const below_inner = inner.y + inner.height + 16;
            const expectations = [_]Expectation{
                .{ .at = center(fill), .color = scene_colors.fill, .what = "a fill" },
                .{ .at = .{ bordered.x + 2, bordered.y + bordered.height / 2 }, .color = scene_colors.border, .what = "a border's left edge" },
                .{ .at = center(bordered), .color = scene_colors.background, .what = "the inside of a border, which it does not fill," },
                .{ .at = .{ inner.x + 8, inner.y + 8 }, .color = scene_colors.inner_clip, .what = "the inside of both clips" },
                .{ .at = .{ outer.x + outer.width - 16, inner.y + 8 }, .color = scene_colors.background, .what = "what the inner clip cut off" },
                .{ .at = .{ outer.x + outer.width - 16, below_inner }, .color = scene_colors.outer_clip, .what = "the outer clip, restored when the inner one ended," },
                .{ .at = .{ outer.x + outer.width + 8, below_inner }, .color = scene_colors.background, .what = "what the outer clip cut off" },
                .{ .at = .{ outer.x + 24, outer.y + outer.height + 8 }, .color = scene_colors.background, .what = "what the outer clip cut off below it" },
                .{ .at = center(after), .color = scene_colors.after_clips, .what = "a fill drawn after every clip ended" },
            };
            for (expectations) |expectation| {
                if (self.expect(expectation)) |violation| return violation;
            }
            if (has_image) {
                const picture = frame.rectOf(ids.picture).?;
                const image_expectations = [_]Expectation{
                    .{ .at = center(picture), .color = scene_colors.tinted_image, .what = "a tinted image of one color" },
                    .{ .at = .{ picture.x + 1, picture.y + 1 }, .color = scene_colors.background, .what = "an image's rounded top-left corner" },
                    .{ .at = .{ picture.x + picture.width - 2, picture.y + picture.height - 2 }, .color = scene_colors.background, .what = "an image's rounded bottom-right corner" },
                };
                for (image_expectations) |expectation| {
                    if (self.expect(expectation)) |violation| return violation;
                }
            }
            for (frame.commands()) |command| {
                if (command.payload == .text) return self.expectTextDrawn(command.bounds);
            }
            return null;
        }

        fn deepClips(self: Self, frame: anytype) ?RendererViolation {
            const nest = frame.rectOf(ids.nest).?;
            const after = frame.rectOf(ids.after_nest).?;
            if (self.expect(.{ .at = center(nest), .color = scene_colors.inner_clip, .what = "the inside of the innermost clip" })) |violation| return violation;
            return self.expect(.{ .at = center(after), .color = scene_colors.after_clips, .what = "a fill drawn after the hundredth clip ended" });
        }

        fn expect(self: Self, expectation: Expectation) ?RendererViolation {
            const x: u32 = @intFromFloat(expectation.at[0]);
            const y: u32 = @intFromFloat(expectation.at[1]);
            const found = self.harness.pixel(x, y);
            if (near(found, expectation.color, self.tolerance)) return null;
            return .init(error.WrongColor, "drew #{x:0>6} at ({d}, {d}) in {s}, where {s} should be #{x:0>6}", .{
                hex(found), x, y, self.scene.description(), expectation.what, hex(expectation.color),
            });
        }

        /// Glyphs differ between fonts, so this asks only that some pixel
        /// inside the text's bounds has its color.
        fn expectTextDrawn(self: Self, bounds: zui.Rect) ?RendererViolation {
            const left: u32 = @intFromFloat(@max(0, bounds.x));
            const top: u32 = @intFromFloat(@max(0, bounds.y));
            const right: u32 = @min(renderer_viewport[0], @as(u32, @intFromFloat(@max(0, bounds.x + bounds.width))));
            const bottom: u32 = @min(renderer_viewport[1], @as(u32, @intFromFloat(@max(0, bounds.y + bounds.height))));
            for (top..bottom) |y| for (left..right) |x| {
                if (near(self.harness.pixel(@intCast(x), @intCast(y)), scene_colors.text, self.tolerance)) return null;
            };
            return .init(error.TextNotDrawn, "drew no pixel of #{x:0>6} inside the text at ({d}, {d}, {d} by {d}) in {s}", .{
                hex(scene_colors.text), left, top, right - left, bottom - top, self.scene.description(),
            });
        }
    };
}

const Expectation = struct { at: [2]f32, color: zui.Color, what: []const u8 };

fn center(rect: zui.Rect) [2]f32 {
    return .{ rect.x + rect.width / 2, rect.y + rect.height / 2 };
}

fn near(found: zui.Color, expected: zui.Color, tolerance: u8) bool {
    const found_channels = [3]u8{ found.r, found.g, found.b };
    const expected_channels = [3]u8{ expected.r, expected.g, expected.b };
    for (found_channels, expected_channels) |a, b| {
        if (@max(a, b) - @min(a, b) > tolerance) return false;
    }
    return true;
}

fn hex(color: zui.Color) u24 {
    return @as(u24, color.r) << 16 | @as(u24, color.g) << 8 | color.b;
}

const Flaw = enum { none, forgets_enclosing_clip, ignores_image_decoration };

/// A software renderer into its own pixels, the plainest that conforms:
/// fills ignore corner radii, text fills its bounds, and an image is its
/// handle's color times its tint, inside its rounded corners. Each `Flaw`
/// is a mistake the suite must catch.
fn PixelRenderer(comptime flaw: Flaw) type {
    return struct {
        const Self = @This();
        const width = renderer_viewport[0];
        const height = renderer_viewport[1];
        const width_units: f32 = width;
        const height_units: f32 = height;

        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const ImageHandle = zui.Color;

        pixels: [width * height]zui.Color = undefined,

        pub fn zuiSubmit(self: *Self, surface: zui.Surface, frame: anytype) !void {
            if (surface != .offscreen) return error.UnsupportedSurface;
            var clips: [128]zui.Rect = undefined;
            var depth: usize = 0;
            const whole: zui.Rect = .{ .width = width, .height = height };
            for (frame.commands()) |command| {
                const clip = if (depth == 0) whole else clips[depth - 1];
                const bounds = command.bounds;
                switch (command.payload) {
                    .rectangle => |rectangle| self.fill(bounds, clip, rectangle.color),
                    .border => |border| {
                        const widths = border.widths;
                        self.fill(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = widths.top }, clip, border.color);
                        self.fill(.{ .x = bounds.x, .y = bounds.y + bounds.height - widths.bottom, .width = bounds.width, .height = widths.bottom }, clip, border.color);
                        self.fill(.{ .x = bounds.x, .y = bounds.y, .width = widths.left, .height = bounds.height }, clip, border.color);
                        self.fill(.{ .x = bounds.x + bounds.width - widths.right, .y = bounds.y, .width = widths.right, .height = bounds.height }, clip, border.color);
                    },
                    .text => |text| self.fill(bounds, clip, text.style.color),
                    .image => |image| if (flaw == .ignores_image_decoration)
                        self.fill(bounds, clip, image.handle)
                    else
                        self.fillRounded(bounds, clip, multiply(image.handle, image.tint), image.corner_radius),
                    .clip_begin => |rect| {
                        clips[depth] = rect;
                        depth += 1;
                    },
                    .clip_end => depth = if (flaw == .forgets_enclosing_clip) 0 else depth - 1,
                }
            }
        }

        fn fill(self: *Self, rect: zui.Rect, clip: zui.Rect, color: zui.Color) void {
            const left = std.math.clamp(@max(rect.x, clip.x), 0, width_units);
            const top = std.math.clamp(@max(rect.y, clip.y), 0, height_units);
            const right = std.math.clamp(@min(rect.x + rect.width, clip.x + clip.width), 0, width_units);
            const bottom = std.math.clamp(@min(rect.y + rect.height, clip.y + clip.height), 0, height_units);
            if (right <= left or bottom <= top) return;
            for (@intFromFloat(top)..@intFromFloat(bottom)) |y| {
                @memset(self.pixels[y * width ..][@intFromFloat(left)..@intFromFloat(right)], color);
            }
        }

        fn fillRounded(self: *Self, rect: zui.Rect, clip: zui.Rect, color: zui.Color, radius: zui.CornerRadius) void {
            for (0..height) |y| for (0..width) |x| {
                const at: [2]f32 = .{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                if (contains(clip, at) and insideRounded(rect, radius, at)) self.pixels[y * width + x] = color;
            };
        }
    };
}

fn contains(rect: zui.Rect, at: [2]f32) bool {
    return at[0] >= rect.x and at[0] < rect.x + rect.width and at[1] >= rect.y and at[1] < rect.y + rect.height;
}

fn insideRounded(rect: zui.Rect, radius: zui.CornerRadius, at: [2]f32) bool {
    if (!contains(rect, at)) return false;
    const is_left = at[0] < rect.x + rect.width / 2;
    const is_top = at[1] < rect.y + rect.height / 2;
    const declared_radius = if (is_top)
        (if (is_left) radius.top_left else radius.top_right)
    else
        (if (is_left) radius.bottom_left else radius.bottom_right);
    const corner_radius = @min(declared_radius, @min(rect.width, rect.height) / 2);
    const arc_x = if (is_left) rect.x + corner_radius else rect.x + rect.width - corner_radius;
    const arc_y = if (is_top) rect.y + corner_radius else rect.y + rect.height - corner_radius;
    const beyond_x = if (is_left) arc_x - at[0] else at[0] - arc_x;
    const beyond_y = if (is_top) arc_y - at[1] else at[1] - arc_y;
    if (beyond_x <= 0 or beyond_y <= 0) return true;
    return beyond_x * beyond_x + beyond_y * beyond_y <= corner_radius * corner_radius;
}

fn multiply(color: zui.Color, tint: zui.Color) zui.Color {
    return .{
        .r = multiplyChannel(color.r, tint.r),
        .g = multiplyChannel(color.g, tint.g),
        .b = multiplyChannel(color.b, tint.b),
        .a = multiplyChannel(color.a, tint.a),
    };
}

fn multiplyChannel(a: u8, b: u8) u8 {
    return @intCast(@as(u16, a) * b / 255);
}

fn PixelHarness(comptime Renderer: type) type {
    return struct {
        const Self = @This();
        pub const config: zui.Config = .{ .Text = FixedText, .ImageHandle = zui.Color };

        drawn: Renderer = .{},
        text_contract: FixedText = .{},

        pub fn renderer(self: *Self) *Renderer {
            return &self.drawn;
        }

        pub fn text(self: *Self) *FixedText {
            return &self.text_contract;
        }

        pub fn beginDraw(self: *Self, size: [2]u32) zui.Surface {
            @memset(&self.drawn.pixels, .black);
            return .{ .offscreen = .{ .size = size } };
        }

        pub fn pixel(self: *Self, x: u32, y: u32) zui.Color {
            return self.drawn.pixels[y * renderer_viewport[0] + x];
        }

        pub fn image(_: *Self, color: zui.Color) zui.Color {
            return color;
        }
    };
}

const FixedText = struct {
    pub fn zuiMeasure(_: *FixedText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * (key.size / 2 + key.letter_spacing), key.size };
    }
};

test "a renderer that draws every frame right passes the suite" {
    var harness: PixelHarness(PixelRenderer(.none)) = .{};
    try expectRendererConforms(PixelRenderer(.none), &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io, .tolerance = 0 });
}

test "a renderer that forgets the enclosing clip when a clip ends fails the suite" {
    var harness: PixelHarness(PixelRenderer(.forgets_enclosing_clip)) = .{};
    const violation = (try findRendererViolation(PixelRenderer(.forgets_enclosing_clip), &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io })).?;
    try std.testing.expectEqual(error.WrongColor, violation.kind);
    try std.testing.expectEqualStrings(
        "drew #0040ff at (248, 64) in the reference scene, where what the outer clip cut off should be #203040",
        violation.description(),
    );
}

test "a renderer that draws an image untinted and square fails the suite" {
    var harness: PixelHarness(PixelRenderer(.ignores_image_decoration)) = .{};
    const violation = (try findRendererViolation(PixelRenderer(.ignores_image_decoration), &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io })).?;
    try std.testing.expectEqual(error.WrongColor, violation.kind);
    try std.testing.expectEqualStrings(
        "drew #00ffff at (32, 112) in the reference scene, where a tinted image of one color should be #00ff80",
        violation.description(),
    );
}

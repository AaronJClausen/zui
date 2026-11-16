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
pub const renderer_viewport: [2]u32 = .{ 320, 192 };

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
    /// Far enough apart that the gradient's middle in OKLab, #8c53a2, is
    /// beyond any sensible tolerance of sRGB's, #800080.
    pub const gradient_from: zui.Color = .rgb(0xff0000);
    pub const gradient_to: zui.Color = .rgb(0x0000ff);
    pub const raised: zui.Color = .rgb(0xffffff);
    pub const shadow: zui.Color = .rgb(0x000000);
    /// The stripes a backdrop blur is drawn over, alternating, so blurred
    /// they average to their middle.
    pub const stripe_even: zui.Color = .rgb(0x00ff00);
    pub const stripe_odd: zui.Color = .rgb(0xff00ff);
    /// Drawn over the blurred stripes, and alone where the blur is lowered.
    pub const frost: zui.Color = .rgba(0xffffff80);
    /// The two halves of a box turned a quarter clockwise, which brings its
    /// start to the top.
    pub const turned_start: zui.Color = .rgb(0xff8080);
    pub const turned_end: zui.Color = .rgb(0x8080ff);
    /// `harness.material` is asked for a material that draws this one
    /// color, and the box declaring it falls back to `material_fallback`.
    pub const material: zui.Color = .rgb(0xc08000);
    pub const material_fallback: zui.Color = .rgb(0x008080);
};

/// The raised box's shadow is cast this far right and down, unblurred.
pub const shadow_offset: f32 = 16;

/// The reference scene's image is rounded by this much, so a pixel just
/// inside its bounding corner lies outside the curve.
pub const image_corner_radius: f32 = 12;

/// Each stripe beneath the backdrop blur is this wide, and the blur's
/// radius is the same, enough to average them.
pub const stripe_width: f32 = 8;
pub const stripe_count = 8;

/// The turned box's size as laid out, before its quarter turn.
pub const turned_size: [2]f32 = .{ 48, 16 };

/// Draws frames that every renderer must draw the same way, and fails on
/// the first thing it drew wrong:
/// - a reference scene of the base commands (a fill, a border, text, and
///   a clip inside a clip, each cutting off a child larger than itself),
///   with `image` and `custom` when the renderer has their payload types,
///   the image tinted and with rounded corners, and a gradient and a box
///   casting a shadow, a backdrop blur over stripes, and a box of two
///   halves turned a quarter clockwise, which the core lowers unless the
///   renderer declares `.gradient`, `.shadow`, `.backdrop_blur` or
///   `.transform`, and a material when it has a `MaterialHandle`, lowered
///   unless it declares `.material`;
/// - clips nested 100 deep, then a fill drawn after all of them ended;
/// - commands of no size, and far outside the viewport;
/// - an empty frame;
/// - the reference scene again, which shows that nothing an earlier frame
///   set, such as a clip, outlived it.
///
/// With `pixel`, every frame is read back: each clip cuts off exactly what
/// lies outside it and is restored when the clip inside it ends, the
/// scene's colors are where its layout put them, the image's tint is
/// multiplied into its pixels, and its corners are left undrawn; a
/// declared gradient runs from one color to the other through their middle
/// in OKLab and a lowered one is that middle throughout; a declared shadow
/// is drawn and a lowered one is not; a declared backdrop blur averages the
/// stripes beneath it under its tint, a lowered one is its tint over each
/// stripe, and neither reaches beyond its bounds; a declared transform
/// stands the turned box up with its start at the top, and a lowered one
/// leaves it as laid out; a declared material is drawn in place of its
/// fallback background and a lowered one is that background. Without it, the suite
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
/// - `fn custom(self) config.CustomData`, when `config.CustomData` is not `void`;
/// - `fn material(self, color: zui.Color) config.MaterialHandle`: a
///   material that draws one opaque color, when `config.MaterialHandle` is
///   not `void`.
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

const ids = zui.ids(.{ "panel", "fill", "frame", "outer", "inner", "picture", "custom", "gradient", "raised", "stripes", "turned", "material", "nest", "after_nest" });

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
    const Payloads = struct { image: config.ImageHandle, custom: config.CustomData, material: config.MaterialHandle };

    var ui: Ui = if (Ui.has_text) try .init(conformance.gpa, conformance.io, harness.text()) else try .init(conformance.gpa, conformance.io);
    defer ui.deinit(conformance.gpa);
    const payloads: Payloads = .{
        .image = if (config.ImageHandle == void) {} else harness.image(scene_colors.image),
        .custom = if (config.CustomData == void) {} else harness.custom(),
        .material = if (config.MaterialHandle == void) {} else harness.material(scene_colors.material),
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
            .reference => pixels.reference(frame, config),
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
        ui.box(.{ .id = ids.gradient, .layout = .{ .sizing = fixedSize(64, 32) }, .effects = &.{
            .gradient = .{ .from = scene_colors.gradient_from, .to = scene_colors.gradient_to },
        } });
        ui.box(.{
            .id = ids.raised,
            .layout = .{ .sizing = fixedSize(32, 32) },
            .decoration = .{ .background = scene_colors.raised },
            .effects = &.{ .shadow = .{ .color = scene_colors.shadow, .offset = .{ shadow_offset, shadow_offset } } },
        });
        ui.close();
    }
    {
        ui.open(.{ .layout = .{ .child_gap = 16 } });
        const stripes_size = fixedSize(stripe_width * stripe_count, 32);
        ui.open(.{ .id = ids.stripes, .layout = .{ .sizing = stripes_size } });
        for (0..stripe_count) |stripe| ui.box(.{
            .decoration = .{ .background = if (stripe % 2 == 0) scene_colors.stripe_even else scene_colors.stripe_odd },
            .layout = .{ .sizing = fixedSize(stripe_width, 32) },
        });
        ui.box(.{ .floating = .{}, .layout = .{ .sizing = stripes_size }, .effects = &.{
            .backdrop_blur = .{ .radius = stripe_width, .tint = scene_colors.frost },
        } });
        ui.close();
        ui.open(.{ .id = ids.turned, .layout = .{ .sizing = fixedSize(turned_size[0], turned_size[1]) }, .effects = &.{
            .transform = .{ .rotation = std.math.pi / 2.0 },
        } });
        const half = fixedSize(turned_size[0] / 2, turned_size[1]);
        ui.box(.{ .decoration = .{ .background = scene_colors.turned_start }, .layout = .{ .sizing = half } });
        ui.box(.{ .decoration = .{ .background = scene_colors.turned_end }, .layout = .{ .sizing = half } });
        ui.close();
        if (config.MaterialHandle != void) ui.box(.{
            .id = ids.material,
            .layout = .{ .sizing = fixedSize(32, 32) },
            .decoration = .{ .background = scene_colors.material_fallback, .material = payloads.material },
        });
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

        fn reference(self: Self, frame: anytype, comptime config: zui.Config) ?RendererViolation {
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
            if (self.effects(frame, config)) |violation| return violation;
            if (config.ImageHandle != void) {
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

        fn effects(self: Self, frame: anytype, comptime config: zui.Config) ?RendererViolation {
            const gradient = frame.rectOf(ids.gradient).?;
            const raised = frame.rectOf(ids.raised).?;
            const middle = scene_colors.gradient_from.mixOklab(scene_colors.gradient_to, 0.5);
            const draws_gradient = comptime config.commands.contains(.gradient);
            const draws_shadow = comptime config.commands.contains(.shadow);
            const across_gradient = gradient.y + gradient.height / 2;
            const beyond_raised = raised.x + raised.width + shadow_offset / 2;
            const expectations = [_]Expectation{
                .{ .at = center(gradient), .color = middle, .what = "the middle of a gradient, in OKLab," },
                if (draws_gradient)
                    .{ .at = .{ gradient.x + 1, across_gradient }, .color = scene_colors.gradient_from, .what = "the start of a gradient" }
                else
                    .{ .at = .{ gradient.x + 1, across_gradient }, .color = middle, .what = "the start of a lowered gradient, its mean color," },
                if (draws_gradient)
                    .{ .at = .{ gradient.x + gradient.width - 2, across_gradient }, .color = scene_colors.gradient_to, .what = "the end of a gradient" }
                else
                    .{ .at = .{ gradient.x + gradient.width - 2, across_gradient }, .color = middle, .what = "the end of a lowered gradient, its mean color," },
                .{ .at = center(raised), .color = scene_colors.raised, .what = "a box over its own shadow" },
                if (draws_shadow)
                    .{ .at = .{ beyond_raised, raised.y + raised.height + shadow_offset / 2 }, .color = scene_colors.shadow, .what = "a shadow cast right and down" }
                else
                    .{ .at = .{ beyond_raised, raised.y + raised.height + shadow_offset / 2 }, .color = scene_colors.background, .what = "where a lowered shadow draws nothing" },
                .{ .at = .{ beyond_raised, raised.y + shadow_offset / 2 }, .color = scene_colors.background, .what = "above where a shadow is offset to" },
            };
            for (expectations) |expectation| {
                if (self.expect(expectation)) |violation| return violation;
            }
            return self.backdropBlur(frame, config);
        }

        fn backdropBlur(self: Self, frame: anytype, comptime config: zui.Config) ?RendererViolation {
            const stripes = frame.rectOf(ids.stripes).?;
            const across_stripes = stripes.y + stripes.height / 2;
            const odd_stripe = stripes.x + stripe_width * 3.5;
            const even_stripe = stripes.x + stripe_width * 4.5;
            const blurred = blend(scene_colors.stripe_even.mix(scene_colors.stripe_odd, 0.5), scene_colors.frost);
            const expectations = [_]Expectation{
                if (comptime config.commands.contains(.backdrop_blur))
                    .{ .at = .{ odd_stripe, across_stripes }, .color = blurred, .what = "a backdrop blur, the stripes beneath it averaged under its tint," }
                else
                    .{ .at = .{ odd_stripe, across_stripes }, .color = blend(scene_colors.stripe_odd, scene_colors.frost), .what = "a lowered backdrop blur, its tint over a stripe," },
                if (comptime config.commands.contains(.backdrop_blur))
                    .{ .at = .{ even_stripe, across_stripes }, .color = blurred, .what = "a backdrop blur, the stripes beneath it averaged under its tint," }
                else
                    .{ .at = .{ even_stripe, across_stripes }, .color = blend(scene_colors.stripe_even, scene_colors.frost), .what = "a lowered backdrop blur, its tint over a stripe," },
                .{ .at = .{ stripes.x + stripes.width + 8, across_stripes }, .color = scene_colors.background, .what = "beside a backdrop blur, which stays inside its bounds," },
            };
            for (expectations) |expectation| {
                if (self.expect(expectation)) |violation| return violation;
            }
            return self.transform(frame, config);
        }

        fn transform(self: Self, frame: anytype, comptime config: zui.Config) ?RendererViolation {
            const turned = frame.rectOf(ids.turned).?;
            const middle = center(turned);
            const quarter = turned_size[0] / 4;
            const expectations = if (comptime config.commands.contains(.transform)) [_]Expectation{
                .{ .at = .{ middle[0], middle[1] - quarter }, .color = scene_colors.turned_start, .what = "the start of a box turned a quarter clockwise, now at its top," },
                .{ .at = .{ middle[0], middle[1] + quarter }, .color = scene_colors.turned_end, .what = "the end of a box turned a quarter clockwise, now at its bottom," },
                .{ .at = .{ middle[0] - quarter, middle[1] }, .color = scene_colors.background, .what = "where a turned box was laid out, which it no longer covers," },
            } else [_]Expectation{
                .{ .at = .{ middle[0] - quarter, middle[1] }, .color = scene_colors.turned_start, .what = "the start of a box whose lowered transform leaves it as laid out" },
                .{ .at = .{ middle[0] + quarter, middle[1] }, .color = scene_colors.turned_end, .what = "the end of a box whose lowered transform leaves it as laid out" },
                .{ .at = .{ middle[0], middle[1] - quarter }, .color = scene_colors.background, .what = "above a box whose lowered transform leaves it as laid out" },
            };
            for (expectations) |expectation| {
                if (self.expect(expectation)) |violation| return violation;
            }
            return self.material(frame, config);
        }

        fn material(self: Self, frame: anytype, comptime config: zui.Config) ?RendererViolation {
            if (config.MaterialHandle == void) return null;
            const box = frame.rectOf(ids.material).?;
            return self.expect(if (comptime config.commands.contains(.material))
                .{ .at = center(box), .color = scene_colors.material, .what = "a material, drawn in place of its fallback background," }
            else
                .{ .at = center(box), .color = scene_colors.material_fallback, .what = "a lowered material, its fallback background," });
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

/// `above` drawn over `below` by its alpha, as a renderer blends a
/// translucent fill.
fn blend(below: zui.Color, above: zui.Color) zui.Color {
    if (above.a == 255) return above;
    return below.mix(.{ .r = above.r, .g = above.g, .b = above.b }, @as(f32, @floatFromInt(above.a)) / 255);
}

fn hex(color: zui.Color) u24 {
    return @as(u24, color.r) << 16 | @as(u24, color.g) << 8 | color.b;
}

const Flaw = enum { none, forgets_enclosing_clip, ignores_image_decoration, interpolates_gradient_in_srgb, tints_without_blurring, turns_the_wrong_way, draws_material_fallback };

/// A software renderer into its own pixels, the plainest that conforms:
/// fills ignore corner radii, text fills its bounds, an image is its
/// handle's color times its tint, inside its rounded corners, a gradient
/// is each pixel's `colorAt`, a shadow is unblurred, a backdrop blur is a
/// box average as wide as its radius each way, and each pixel is drawn
/// from where its center lies in the transforms' units, and a material is
/// its handle's color. Each `Flaw` is a
/// mistake the suite must catch.
fn PixelRenderer(comptime flaw: Flaw, comptime commands: zui.CommandSet) type {
    return struct {
        const Self = @This();
        const width = renderer_viewport[0];
        const height = renderer_viewport[1];
        const width_units: f32 = width;
        const height_units: f32 = height;

        pub const zui_surfaces: zui.SurfaceKinds = .initOne(.offscreen);
        pub const zui_commands = commands;
        pub const ImageHandle = zui.Color;
        pub const MaterialHandle = zui.Color;

        pixels: [width * height]zui.Color = undefined,
        beneath_blur: [width * height]zui.Color = undefined,
        /// Each clip in effect, with the transforms in effect where it began.
        clips: [128]Clip = undefined,
        clip_depth: usize = 0,
        /// From the window to the units of the innermost transform, and
        /// back, for each transform in effect and the window's own first.
        to_local: [32]zui.Affine = .{zui.Affine.identity} ** 32,
        from_local: [32]zui.Affine = .{zui.Affine.identity} ** 32,
        transform_depth: usize = 0,

        const Clip = struct { rect: zui.Rect, to_local: zui.Affine };

        /// Where a transform that flattens its subtree sends each pixel, so
        /// that none of it is drawn.
        const nowhere: zui.Affine = .{ .x_axis = .{ 0, 0 }, .y_axis = .{ 0, 0 }, .offset = .{ std.math.inf(f32), 0 } };

        pub fn zuiSubmit(self: *Self, surface: zui.Surface, frame: anytype) !void {
            if (surface != .offscreen) return error.UnsupportedSurface;
            self.clip_depth = 0;
            self.transform_depth = 0;
            for (frame.commands()) |command| {
                const bounds = command.bounds;
                switch (command.payload) {
                    .rectangle => |rectangle| self.fill(bounds, rectangle.color),
                    .border => |border| {
                        const widths = border.widths;
                        self.fill(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = widths.top }, border.color);
                        self.fill(.{ .x = bounds.x, .y = bounds.y + bounds.height - widths.bottom, .width = bounds.width, .height = widths.bottom }, border.color);
                        self.fill(.{ .x = bounds.x, .y = bounds.y, .width = widths.left, .height = bounds.height }, border.color);
                        self.fill(.{ .x = bounds.x + bounds.width - widths.right, .y = bounds.y, .width = widths.right, .height = bounds.height }, border.color);
                    },
                    .text => |text| self.fill(bounds, text.style.color),
                    .clip_begin => |rect| {
                        self.clips[self.clip_depth] = .{ .rect = rect, .to_local = self.to_local[self.transform_depth] };
                        self.clip_depth += 1;
                    },
                    .clip_end => self.clip_depth = if (flaw == .forgets_enclosing_clip) 0 else self.clip_depth - 1,
                    inline else => |payload, kind| if (comptime std.mem.eql(u8, @tagName(kind), "transform_begin")) {
                        var turned = payload;
                        if (flaw == .turns_the_wrong_way) turned.rotation = -turned.rotation;
                        const affine = turned.affine(bounds);
                        const depth = self.transform_depth;
                        self.to_local[depth + 1] = (affine.inverse() orelse nowhere).after(self.to_local[depth]);
                        self.from_local[depth + 1] = self.from_local[depth].after(affine);
                        self.transform_depth += 1;
                    } else if (comptime std.mem.eql(u8, @tagName(kind), "transform_end")) {
                        self.transform_depth -= 1;
                    } else if (comptime std.mem.eql(u8, @tagName(kind), "image")) {
                        if (flaw == .ignores_image_decoration)
                            self.fill(bounds, payload.handle)
                        else
                            self.fillRounded(bounds, multiply(payload.handle, payload.tint), payload.corner_radius);
                    } else if (comptime std.mem.eql(u8, @tagName(kind), "gradient")) {
                        self.fillGradient(bounds, payload);
                    } else if (comptime std.mem.eql(u8, @tagName(kind), "shadow")) {
                        const shape: zui.Rect = .{
                            .x = bounds.x + payload.offset[0] - payload.spread,
                            .y = bounds.y + payload.offset[1] - payload.spread,
                            .width = bounds.width + 2 * payload.spread,
                            .height = bounds.height + 2 * payload.spread,
                        };
                        self.fillRounded(shape, payload.color, payload.corner_radius);
                    } else if (comptime std.mem.eql(u8, @tagName(kind), "backdrop_blur")) {
                        if (flaw != .tints_without_blurring) self.blurBeneath(bounds, payload.radius, payload.corner_radius);
                        self.fillRounded(bounds, payload.tint, payload.corner_radius);
                    } else if (comptime std.mem.eql(u8, @tagName(kind), "material")) {
                        self.fillRounded(bounds, if (flaw == .draws_material_fallback) payload.fallback else payload.handle, payload.corner_radius);
                    } else comptime unreachable,
                }
            }
        }

        /// The pixels whose centers may lie in `rect`, in the innermost
        /// transform's units, each with where its center lies in them, if
        /// every clip in effect holds it.
        fn covered(self: *const Self, rect: zui.Rect) Covered {
            const around = self.from_local[self.transform_depth].boundsOf(rect);
            return .{
                .renderer = self,
                .left = @intFromFloat(std.math.clamp(@floor(around.x), 0, width_units)),
                .right = @intFromFloat(std.math.clamp(@ceil(around.x + around.width), 0, width_units)),
                .bottom = @intFromFloat(std.math.clamp(@ceil(around.y + around.height), 0, height_units)),
                .x = @intFromFloat(std.math.clamp(@floor(around.x), 0, width_units)),
                .y = @intFromFloat(std.math.clamp(@floor(around.y), 0, height_units)),
            };
        }

        const Covered = struct {
            renderer: *const Self,
            left: usize,
            right: usize,
            bottom: usize,
            x: usize,
            y: usize,

            const Pixel = struct { index: usize, at: [2]f32 };

            fn next(self: *Covered) ?Pixel {
                while (self.y < self.bottom) {
                    if (self.x >= self.right) {
                        self.x = self.left;
                        self.y += 1;
                        continue;
                    }
                    const x = self.x;
                    self.x += 1;
                    const in_window: [2]f32 = .{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(self.y)) + 0.5 };
                    if (!self.renderer.insideClips(in_window)) continue;
                    return .{ .index = self.y * width + x, .at = self.renderer.to_local[self.renderer.transform_depth].apply(in_window) };
                }
                return null;
            }
        };

        fn insideClips(self: *const Self, in_window: [2]f32) bool {
            for (self.clips[0..self.clip_depth]) |clip| {
                if (!contains(clip.rect, clip.to_local.apply(in_window))) return false;
            }
            return true;
        }

        fn fill(self: *Self, rect: zui.Rect, color: zui.Color) void {
            self.fillRounded(rect, color, .zero);
        }

        fn fillRounded(self: *Self, rect: zui.Rect, color: zui.Color, radius: zui.CornerRadius) void {
            var pixels = self.covered(rect);
            while (pixels.next()) |pixel| {
                if (insideRounded(rect, radius, pixel.at)) self.pixels[pixel.index] = blend(self.pixels[pixel.index], color);
            }
        }

        /// Untransformed, as the reference scene draws it.
        fn blurBeneath(self: *Self, rect: zui.Rect, radius: f32, corner_radius: zui.CornerRadius) void {
            const left: usize = @intFromFloat(std.math.clamp(rect.x, 0, width_units));
            const top: usize = @intFromFloat(std.math.clamp(rect.y, 0, height_units));
            const right: usize = @intFromFloat(std.math.clamp(rect.x + rect.width, 0, width_units));
            const bottom: usize = @intFromFloat(std.math.clamp(rect.y + rect.height, 0, height_units));
            if (right <= left or bottom <= top) return;
            const reach: isize = @intFromFloat(@ceil(radius));
            self.beneath_blur = self.pixels;
            for (top..bottom) |y| for (left..right) |x| {
                const at: [2]f32 = .{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                if (!self.insideClips(at) or !insideRounded(rect, corner_radius, at)) continue;
                var sums: [3]u32 = .{ 0, 0, 0 };
                var count: u32 = 0;
                var dy: isize = -reach;
                while (dy <= reach) : (dy += 1) {
                    var dx: isize = -reach;
                    while (dx <= reach) : (dx += 1) {
                        const sample_x = std.math.clamp(@as(isize, @intCast(x)) + dx, @as(isize, @intCast(left)), @as(isize, @intCast(right - 1)));
                        const sample_y = std.math.clamp(@as(isize, @intCast(y)) + dy, @as(isize, @intCast(top)), @as(isize, @intCast(bottom - 1)));
                        const sample = self.beneath_blur[@as(usize, @intCast(sample_y)) * width + @as(usize, @intCast(sample_x))];
                        sums[0] += sample.r;
                        sums[1] += sample.g;
                        sums[2] += sample.b;
                        count += 1;
                    }
                }
                self.pixels[y * width + x] = .{ .r = @intCast(sums[0] / count), .g = @intCast(sums[1] / count), .b = @intCast(sums[2] / count) };
            };
        }

        fn fillGradient(self: *Self, rect: zui.Rect, gradient: anytype) void {
            var pixels = self.covered(rect);
            while (pixels.next()) |pixel| {
                if (!insideRounded(rect, gradient.corner_radius, pixel.at)) continue;
                self.pixels[pixel.index] = if (flaw == .interpolates_gradient_in_srgb)
                    gradient.from.mix(gradient.to, (zui.Gradient{ .from = gradient.from, .to = gradient.to, .angle = gradient.angle }).amountAt(rect, pixel.at))
                else
                    gradient.colorAt(rect, pixel.at);
            }
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
        pub const config: zui.Config = .{ .Text = FixedText, .ImageHandle = zui.Color, .MaterialHandle = zui.Color, .commands = Renderer.zui_commands };

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

        pub fn material(_: *Self, color: zui.Color) zui.Color {
            return color;
        }
    };
}

const FixedText = struct {
    pub fn zuiMeasure(_: *FixedText, text: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(text.len)) * (key.size / 2 + key.letter_spacing), key.size };
    }
};

const draws_effects: zui.CommandSet = .initMany(&.{ .gradient, .shadow, .backdrop_blur, .transform, .material });

test "a renderer that draws every frame right passes the suite, with gradients, shadows, backdrop blurs, transforms and materials drawn or lowered" {
    inline for (comptime .{ draws_effects, zui.CommandSet.initEmpty() }) |commands| {
        const Renderer = PixelRenderer(.none, commands);
        var harness: PixelHarness(Renderer) = .{};
        try expectRendererConforms(Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io });
    }
}

test "a renderer that forgets the enclosing clip when a clip ends fails the suite" {
    const Renderer = PixelRenderer(.forgets_enclosing_clip, draws_effects);
    var harness: PixelHarness(Renderer) = .{};
    const violation = (try findRendererViolation(Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io })).?;
    try std.testing.expectEqual(error.WrongColor, violation.kind);
    try std.testing.expectEqualStrings(
        "drew #0040ff at (248, 64) in the reference scene, where what the outer clip cut off should be #203040",
        violation.description(),
    );
}

test "a renderer that draws an image untinted and square fails the suite" {
    const Renderer = PixelRenderer(.ignores_image_decoration, draws_effects);
    var harness: PixelHarness(Renderer) = .{};
    const violation = (try findRendererViolation(Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io })).?;
    try std.testing.expectEqual(error.WrongColor, violation.kind);
    try std.testing.expectEqualStrings(
        "drew #00ffff at (32, 112) in the reference scene, where a tinted image of one color should be #00ff80",
        violation.description(),
    );
}

test "a renderer that interpolates a gradient in sRGB fails the suite" {
    const Renderer = PixelRenderer(.interpolates_gradient_in_srgb, draws_effects);
    var harness: PixelHarness(Renderer) = .{};
    const violation = (try findRendererViolation(Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io })).?;
    try std.testing.expectEqual(error.WrongColor, violation.kind);
    try std.testing.expectEqualStrings(
        "drew #7e0081 at (144, 112) in the reference scene, where the middle of a gradient, in OKLab, should be #8c53a2",
        violation.description(),
    );
}

test "a renderer that draws a backdrop blur's tint without blurring fails the suite" {
    const Renderer = PixelRenderer(.tints_without_blurring, draws_effects);
    var harness: PixelHarness(Renderer) = .{};
    const violation = (try findRendererViolation(Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io })).?;
    try std.testing.expectEqual(error.WrongColor, violation.kind);
    try std.testing.expectEqualStrings(
        "drew #ff80ff at (44, 160) in the reference scene, where a backdrop blur, the stripes beneath it averaged under its tint, should be #c0c0c0",
        violation.description(),
    );
}

test "a renderer that turns a transform the wrong way fails the suite" {
    const Renderer = PixelRenderer(.turns_the_wrong_way, draws_effects);
    var harness: PixelHarness(Renderer) = .{};
    const violation = (try findRendererViolation(Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io })).?;
    try std.testing.expectEqual(error.WrongColor, violation.kind);
    try std.testing.expectEqualStrings(
        "drew #8080ff at (120, 140) in the reference scene, where the start of a box turned a quarter clockwise, now at its top, should be #ff8080",
        violation.description(),
    );
}

test "a renderer that draws a material's fallback in its place fails the suite" {
    const Renderer = PixelRenderer(.draws_material_fallback, draws_effects);
    var harness: PixelHarness(Renderer) = .{};
    const violation = (try findRendererViolation(Renderer, &harness, .{ .gpa = std.testing.allocator, .io = std.testing.io })).?;
    try std.testing.expectEqual(error.WrongColor, violation.kind);
    try std.testing.expectEqualStrings(
        "drew #008080 at (176, 160) in the reference scene, where a material, drawn in place of its fallback background, should be #c08000",
        violation.description(),
    );
}

const std = @import("std");
const zui = @import("zui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const builtin = @import("builtin");
const options = @import("zui_sokol_options");
const zui_glyphs = @import("zui_glyphs");
const Image = @import("root.zig").Image;
const GlyphAtlas = zui_glyphs.Atlas(.rgba8);
const BackdropBlurs = @import("backdrop_blur.zig").BackdropBlurs;
const materials = @import("materials.zig");
const Material = @import("material.zig").Material;
const Materials = materials.Materials;
const destination = @import("destination.zig");
const Destination = destination.Destination;
const OffscreenTarget = destination.OffscreenTarget;
const VertexColor = destination.VertexColor;
const ScrgbPresent = @import("scrgb_present.zig").ScrgbPresent;

/// On Windows the renderer draws into a native host's window with a
/// context of its own: a Direct3D 11 swapchain composed into the window,
/// which keeps alpha so a system backdrop shows through, or with
/// `-Dgl=true` an OpenGL context, whose alpha Windows ignores.
pub const draws_into_win32 = builtin.os.tag == .windows;
/// On Linux it draws into a native host's Wayland surfaces with an OpenGL
/// context made through EGL.
pub const draws_into_wayland = builtin.os.tag == .linux;
/// A composed window can hold half-float scRGB; an OpenGL one cannot.
const presents_scrgb = draws_into_win32 and !options.opengl;
/// Composed windows share one Direct3D 11 device, and Wayland surfaces one
/// EGL context, so the renderer draws into many; with WGL, into one.
const draws_into_many_windows = (draws_into_win32 and !options.opengl) or draws_into_wayland;
/// What every window after the first draws with: the composition's
/// Direct3D 11 device, or EGL's display and context.
const SharedDevice = if (draws_into_many_windows) @typeInfo(@TypeOf(native.Context.retainDevice)).@"fn".return_type.? else void;
const native_surface: ?zui.SurfaceKind = if (draws_into_win32) .win32 else if (draws_into_wayland) .wayland else null;
const native = if (draws_into_win32)
    (if (options.opengl) @import("wgl.zig") else @import("composition.zig"))
else if (draws_into_wayland)
    @import("egl.zig")
else
    struct {
        pub const Context = void;
    };

/// The renderer contract, through sokol_gfx: draws zui frames with
/// sokol_gl (shapes, images, and text where `zui_glyphs` lays it out, in
/// the fonts of the text frames are measured with) into sokol_app's
/// swapchain, its `.library` surface, into an image of its own for an
/// `.offscreen` surface, which may be `.scrgb_fp16`, or, into a native
/// host's window: `.win32` on Windows, `.wayland` on Linux. It records
/// into numbered layers that are replayed in order, each drawn under its
/// own scissor rectangle. Corners are traced as outlines, round,
/// continuous or chamfered. A frame with a backdrop blur is drawn offscreen and
/// copied to the surface, so that the blur can sample what is beneath it.
/// A transform is sokol_gl's modelview matrix; a clip inside one is
/// scissored to the box around it in the window, which is larger than a
/// turned clip. A material is drawn by its own shader at the start of a
/// layer, before the layer's shapes. In an `.scrgb_fp16` target every
/// color is drawn in linear light. A `.win32` surface in `.scrgb_fp16` is drawn so into an image, which is then
/// copied into the window's half-float swapchain at the monitor's SDR
/// white. Windows after the first are attached with `zuiAttachSurface`,
/// each a swapchain on the first one's device, or an EGL surface on its
/// context, with targets of its own.
pub const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = if (native_surface) |kind| .initMany(&.{ .library, .offscreen, kind }) else .initMany(&.{ .library, .offscreen });
    pub const zui_commands: zui.CommandSet = .initMany(&.{ .gradient, .shadow, .backdrop_blur, .transform, .material });
    pub const zui_corner_shapes: zui.CornerShapeSet = .initFull();
    pub const zui_extended_color = true;
    pub const zui_output_formats: zui.OutputFormats = if (presents_scrgb) .initMany(&.{ .sdr, .scrgb_fp16 }) else .initOne(.sdr);
    pub const ImageHandle = Image;
    pub const MaterialHandle = Material;

    const max_layers = 1024;
    const present_layer = 2 * max_layers;
    /// Windows drawn into besides the one `initForSurface` was given.
    pub const max_attached_surfaces = 7;

    /// A window attached after the first: its swapchain, and the targets
    /// sized to it, which would be made again every frame if windows of
    /// two sizes shared them.
    const AttachedSurface = struct {
        context: native.Context,
        offscreen: OffscreenTarget = .{},
        backdrop_blurs: BackdropBlurs = .{},
    };

    /// The fonts of the text its frames were measured with; text in a font
    /// id they do not have is not drawn.
    fonts: zui_glyphs.Fonts = .none,
    /// What each frame's pass clears to before drawing.
    clear_color: zui.Color = .black,
    /// Triangles per rounded corner.
    corner_segments: u8 = 8,
    pipeline: sgl.Pipeline,
    /// Paint order breaks once a frame needs more layers than this; zui's
    /// commands then share the last layer.
    layer_overflows: u32 = 0,
    layer_scissors: [max_layers]?zui.Rect = undefined,
    /// The context of the surface `initForSurface` was given, until it is
    /// detached.
    native: ?native.Context = null,
    attached: [max_attached_surfaces]?AttachedSurface = @splat(null),
    /// The device every native window draws with, held from
    /// `initForSurface` to `deinit`, so it outlives the first window.
    shared_device: ?SharedDevice = null,
    /// `initForSurface` set sokol_gfx up, so `deinit` shuts it down.
    owns_gfx: bool = false,
    /// Reserved by `init`; null only when that ran out of memory, and then
    /// TrueType text is not drawn.
    glyphs: ?*GlyphAtlas = null,
    glyph_image: sg.Image = .{},
    glyph_view: sg.View = .{},
    glyph_sampler: sg.Sampler = .{},
    backdrop_blurs: BackdropBlurs = .{},
    /// Times transforms nested deeper than the renderer keeps; the deeper
    /// ones were drawn as their parent is.
    transform_overflows: u32 = 0,
    materials: Materials = .{},
    offscreen: OffscreenTarget = .{},
    /// Samples per pixel of an `.offscreen` surface: 4 smooths its edges as
    /// sokol_app's swapchain does with `sample_count = 4`. Its image is
    /// resolved to one sample per pixel; a count the GPU cannot draw makes
    /// `zuiSubmit` fail with `error.UnsupportedSurface`.
    offscreen_sample_count: i32 = 1,
    /// The format of the frame being recorded.
    format: zui.OutputFormat = .sdr,
    scrgb_present: ScrgbPresent = .{},

    /// Call after `sokol.gfx.setup`. `text` is the text contract frames
    /// are measured with, which must outlive the renderer: a
    /// `zui_truetype.Text`, or any text whose fonts `zui_glyphs.Fonts.of`
    /// erases.
    pub fn init(text: anytype) Renderer {
        sgl.setup(.{ .max_vertices = 1 << 19, .max_commands = 1 << 14, .logger = .{ .func = sokol.log.func } });
        return .{
            .fonts = zui_glyphs.Fonts.of(text),
            .glyphs = GlyphAtlas.create(std.heap.page_allocator) catch null,
            .pipeline = sgl.makePipeline(destination.blendingPipeline()),
        };
    }

    /// For a native host's window: makes its graphics context, sets
    /// sokol_gfx up on it, then does what `init` does. `deinit` then also
    /// shuts sokol_gfx down.
    pub fn initForSurface(text: anytype, surface: zui.Surface) !Renderer {
        var context = switch (surface) {
            .win32 => |window| if (comptime draws_into_win32) try native.Context.init(window.hwnd) else return error.UnsupportedSurface,
            .wayland => |window| if (comptime draws_into_wayland) try native.Context.init(window.display, window.surface, window.transparent) else return error.UnsupportedSurface,
            else => return error.UnsupportedSurface,
        };
        errdefer context.deinit();
        sg.setup(.{ .environment = context.environment(), .logger = .{ .func = sokol.log.func } });
        if (!sg.isvalid()) return error.SokolGfxSetupFailed;
        var renderer: Renderer = .init(text);
        renderer.native = context;
        renderer.owns_gfx = true;
        if (comptime draws_into_many_windows) renderer.shared_device = context.retainDevice();
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        for (&self.attached) |*slot| if (slot.*) |*attached| {
            attached.backdrop_blurs.deinit();
            attached.offscreen.deinit();
        };
        self.backdrop_blurs.deinit();
        self.materials.deinit();
        self.offscreen.deinit();
        self.scrgb_present.deinit();
        self.destroyGlyphTexture();
        if (self.glyph_sampler.id != 0) sg.destroySampler(self.glyph_sampler);
        if (self.glyphs) |atlas| atlas.destroy(std.heap.page_allocator);
        sgl.destroyPipeline(self.pipeline);
        sgl.shutdown();
        if (comptime native_surface != null) if (self.owns_gfx) {
            sg.shutdown();
            if (self.native) |*context| context.deinit();
            if (comptime draws_into_many_windows) {
                for (&self.attached) |*slot| if (slot.*) |*attached| attached.context.deinit();
                if (self.shared_device) |device| native.Context.releaseDevice(device);
            }
        };
    }

    /// Makes a swapchain for another `.win32` window on the first one's
    /// device, or an EGL surface for another `.wayland` surface on the
    /// first one's context, so `zuiSubmit` can draw into it. One already
    /// drawn into is left as it is.
    pub fn zuiAttachSurface(self: *Renderer, surface: zui.Surface) error{ UnsupportedSurface, NoCompositionSwapchain, NoWindowSurface, NoOpenGlContext, TooManySurfaces }!void {
        if (comptime !draws_into_many_windows) return error.UnsupportedSurface;
        const window = nativeWindowOf(surface) orelse return error.UnsupportedSurface;
        if (self.contextOf(window) != null) return;
        const device = self.shared_device orelse return error.UnsupportedSurface;
        const slot = for (&self.attached) |*slot| {
            if (slot.* == null) break slot;
        } else return error.TooManySurfaces;
        const context = switch (surface) {
            .wayland => |wayland| if (comptime draws_into_wayland) try native.Context.initSharing(@ptrFromInt(window), device, wayland.transparent) else unreachable,
            else => if (comptime draws_into_win32) try native.Context.initSharing(@ptrFromInt(window), device) else unreachable,
        };
        slot.* = .{ .context = context };
    }

    /// Frees what the renderer keeps for `surface`'s window, the first one
    /// included, before the window closes.
    pub fn zuiDetachSurface(self: *Renderer, surface: zui.Surface) void {
        if (comptime !draws_into_many_windows) return;
        const window = nativeWindowOf(surface) orelse return;
        if (self.native) |*context| if (windowOfContext(context) == window) {
            context.deinit();
            self.native = null;
            return;
        };
        for (&self.attached) |*slot| if (slot.*) |*attached| if (windowOfContext(&attached.context) == window) {
            attached.backdrop_blurs.deinit();
            attached.offscreen.deinit();
            attached.context.deinit();
            slot.* = null;
            return;
        };
    }

    /// Whether the window `surface` names presents alpha, which a
    /// compositor blends over what is behind it: on Wayland, a surface
    /// the host made `transparent` where the display has an alpha
    /// configuration the context can draw into. False for a window the
    /// renderer does not draw into.
    pub fn presentsAlpha(self: *Renderer, surface: zui.Surface) bool {
        if (comptime !draws_into_wayland) return false;
        const window = nativeWindowOf(surface) orelse return false;
        const context = self.contextOf(window) orelse return false;
        return context.holds_alpha;
    }

    /// The address of the window a native surface names, which finds the
    /// context that draws into it.
    fn nativeWindowOf(surface: zui.Surface) ?usize {
        return switch (surface) {
            .win32 => |window| if (comptime draws_into_win32) @intFromPtr(window.hwnd) else null,
            .wayland => |window| if (comptime draws_into_wayland) @intFromPtr(window.surface) else null,
            else => null,
        };
    }

    fn windowOfContext(context: *const native.Context) usize {
        return if (comptime draws_into_win32) @intFromPtr(context.hwnd) else @intFromPtr(context.wayland_surface);
    }

    fn contextOf(self: *Renderer, window: usize) ?*native.Context {
        if (self.native) |*context| if (windowOfContext(context) == window) return context;
        return if (self.attachedOf(window)) |attached| &attached.context else null;
    }

    fn attachedOf(self: *Renderer, window: usize) ?*AttachedSurface {
        for (&self.attached) |*slot| if (slot.*) |*attached| if (windowOfContext(&attached.context) == window) return attached;
        return null;
    }

    /// Draws `frame` into `surface`, cleared to `clear_color`, and commits
    /// it. An `.offscreen` surface is drawn into `offscreenImage()`.
    ///
    /// ```zig
    /// const frame = ui.endFrame();
    /// try renderer.zuiSubmit(.library, frame);
    /// ui.release(frame);
    /// ```
    pub fn zuiSubmit(self: *Renderer, surface: zui.Surface, frame: anytype) error{UnsupportedSurface}!void {
        if (comptime draws_into_many_windows) if (nativeWindowOf(surface)) |window| if (self.attachedOf(window)) |attached| {
            std.mem.swap(OffscreenTarget, &self.offscreen, &attached.offscreen);
            std.mem.swap(BackdropBlurs, &self.backdrop_blurs, &attached.backdrop_blurs);
            defer {
                std.mem.swap(OffscreenTarget, &self.offscreen, &attached.offscreen);
                std.mem.swap(BackdropBlurs, &self.backdrop_blurs, &attached.backdrop_blurs);
            }
            return self.submitInto(surface, &attached.context, frame);
        };
        return self.submitInto(surface, if (self.native) |*context| context else null, frame);
    }

    fn submitInto(self: *Renderer, surface: zui.Surface, native_context: ?*native.Context, frame: anytype) error{UnsupportedSurface}!void {
        const target: Target = switch (surface) {
            .library => .{ .swapchain = sokol.glue.swapchain() },
            .win32 => |window| if (comptime !draws_into_win32) return error.UnsupportedSurface else if (native_context) |context| try self.win32Target(context, window.format) else return error.UnsupportedSurface,
            .wayland => if (comptime !draws_into_wayland) return error.UnsupportedSurface else if (native_context) |context| blk: {
                context.makeCurrent();
                break :blk .{ .swapchain = context.swapchain(physicalSize(frame.params)) };
            } else return error.UnsupportedSurface,
            .offscreen => |offscreen| if (self.offscreen.prepare(offscreen.size, offscreen.format, self.offscreen_sample_count)) .offscreen else return error.UnsupportedSurface,
            else => return error.UnsupportedSurface,
        };
        const into: Destination, const size: [2]i32, const pipeline = switch (target) {
            .swapchain => |swapchain| .{ .swapchain(), .{ swapchain.width, swapchain.height }, self.pipeline },
            .offscreen, .scrgb_window => .{ self.offscreen.destination(), self.offscreen.size, self.offscreen.pipeline },
        };
        self.format = into.format;
        const clear_value = clearValue(self.clear_color, into.format);
        var action: sg.PassAction = .{};
        action.colors[0] = .{ .load_action = .CLEAR, .clear_value = clear_value };
        const final_pass: sg.Pass = switch (target) {
            .swapchain => |swapchain| .{ .action = action, .swapchain = swapchain },
            .offscreen, .scrgb_window => self.offscreen.pass(action),
        };
        self.backdrop_blurs.prepare(frame.commands(), size, into);
        self.materials.prepare(frame.commands(), into.pixels);
        const layer_count = self.record(frame.commands(), frame.params, into, pipeline);
        self.materials.upload();
        if (self.backdrop_blurs.count == 0) {
            sg.beginPass(final_pass);
            self.replay(layer_count, frame.params, clear_value, into);
            sg.endPass();
        } else {
            sg.beginPass(self.backdrop_blurs.scenePass(.CLEAR, clear_value));
            self.replay(layer_count, frame.params, clear_value, into);
            sg.endPass();
            sg.beginPass(final_pass);
            applyScissor(null, frame.params);
            sgl.contextDrawLayer(into.context, present_layer);
            sg.endPass();
        }
        if (comptime presents_scrgb) if (target == .scrgb_window) self.scrgb_present.draw(target.scrgb_window, self.offscreen.image, native_context.?.sdrWhiteScale());
        sg.commit();
        if (comptime native_surface) |kind| if (surface == kind) native_context.?.present();
    }

    const Target = union(enum) {
        swapchain: sg.Swapchain,
        offscreen,
        /// Drawn into `offscreen` in `.scrgb_fp16`, then copied into this.
        scrgb_window: sg.Swapchain,
    };

    fn win32Target(self: *Renderer, context: *native.Context, format: zui.OutputFormat) error{UnsupportedSurface}!Target {
        if (comptime !presents_scrgb) return .{ .swapchain = context.swapchain() };
        if (format == .sdr) return .{ .swapchain = context.swapchain(.sdr) };
        const swapchain = context.swapchain(.scrgb_fp16);
        const size: [2]u32 = .{ @intCast(swapchain.width), @intCast(swapchain.height) };
        if (!self.offscreen.prepare(size, .scrgb_fp16, context.sampleCount()) or !self.scrgb_present.prepare()) return error.UnsupportedSurface;
        return .{ .scrgb_window = swapchain };
    }

    /// What the last `.offscreen` surface was drawn into, in its format:
    /// `.RGBA8` holding sRGB's encoding for `.sdr`, `.RGBA16F` holding
    /// linear scRGB for `.scrgb_fp16`. Stored bottom row first on OpenGL.
    pub fn offscreenImage(self: *const Renderer) sg.Image {
        return self.offscreen.image;
    }

    /// Records `commands` into numbered layers, returning how many.
    /// `params` are the frame record's: its viewport and the physical
    /// pixels per layout unit (`scale × zoom`).
    fn record(self: *Renderer, commands: anytype, params: zui.FrameParams, into: Destination, pipeline: sgl.Pipeline) usize {
        const viewport = params.viewport;
        const format = into.format;

        sgl.setContext(into.context);
        defer sgl.setContext(sgl.defaultContext());
        sgl.defaults();
        sgl.loadPipeline(pipeline);
        sgl.matrixModeProjection();
        sgl.ortho(0, viewport[0], viewport[1], 0, -1, 1);
        const pixels_per_unit = params.scale * params.zoom;
        self.prepareGlyphs(commands, pixels_per_unit);

        var recorder: LayerRecorder = .{ .renderer = self };
        recorder.begin();
        var clips: ClipStack = .{};
        var transforms: TransformStack = .{};
        for (commands) |command| {
            const bounds = command.bounds;
            switch (command.payload) {
                .rectangle => |rectangle| {
                    recorder.beginShapes();
                    fillRectangle(bounds, .of(rectangle), .of(rectangle.color, format), self.corner_segments);
                },
                .border => |border| {
                    recorder.beginShapes();
                    strokeBorder(bounds, border.widths, .of(border), .of(border.color, format), self.corner_segments);
                },
                .text => |line| if (self.glyphs) |atlas| {
                    recorder.beginShapes();
                    drawText(self.fonts, atlas, self.glyph_view, self.glyph_sampler, line.content, bounds, line.style, .of(line.style.color, format), pixels_per_unit);
                },
                .image => |image| {
                    recorder.beginShapes();
                    drawImage(image.handle, bounds, .of(image.tint, format), .of(image), self.corner_segments);
                },
                .gradient => |gradient| {
                    recorder.beginShapes();
                    fillGradient(bounds, gradient, format, self.corner_segments);
                },
                .shadow => |shadow| {
                    recorder.beginShapes();
                    drawShadow(bounds, shadow, format, self.corner_segments);
                },
                .backdrop_blur => |blur| {
                    if (self.backdrop_blurs.ready) if (recorder.beginBackdropBlur()) |layer| {
                        const to_window = transforms.current();
                        if (self.backdrop_blurs.record(to_window.boundsOf(bounds), blur.radius, viewport, layer)) {
                            var outline: Outline = .{};
                            outline.trace(bounds, .of(blur), .{}, self.corner_segments);
                            self.backdrop_blurs.drawBlurred(outline.points[0..outline.count], centerOf(bounds), to_window, viewport);
                        }
                    };
                    recorder.beginShapes();
                    fillRectangle(bounds, .of(blur), .of(blur.tint, format), self.corner_segments);
                },
                .material => |material| if (!self.recordMaterial(&recorder, material, bounds, transforms.current(), viewport)) {
                    recorder.beginShapes();
                    fillRectangle(bounds, .of(material), .of(material.fallback, format), self.corner_segments);
                },
                .clip_begin => |clip| {
                    clips.push(if (transforms.isActive()) transforms.current().boundsOf(clip).intersect(clips.current() orelse wholeViewport(viewport)) else clip);
                    recorder.beginLayer(clips.current());
                },
                .clip_end => {
                    clips.pop();
                    recorder.beginLayer(clips.current());
                },
                .transform_begin => |transform| {
                    if (!transforms.push(transform.affine(bounds))) self.transform_overflows += 1;
                    loadModelview(transforms.current());
                },
                .transform_end => {
                    transforms.pop();
                    loadModelview(transforms.current());
                },
            }
        }

        if (self.backdrop_blurs.count > 0) self.backdrop_blurs.recordPresent(viewport, present_layer);
        return recorder.layer + 1;
    }

    /// False when the material is to be drawn as its fallback: the backend
    /// cannot draw it, or the frame has no layer or room left for it.
    fn recordMaterial(self: *Renderer, recorder: *LayerRecorder, material: anytype, bounds: zui.Rect, to_window: zui.Affine, viewport: [2]f32) bool {
        if (!self.materials.isReady()) {
            self.materials.lowered += 1;
            return false;
        }
        const layer = recorder.beginMaterial() orelse {
            self.materials.lowered += 1;
            return false;
        };
        var outline: Outline = .{};
        outline.trace(bounds, .of(material), .{}, self.corner_segments);
        return self.materials.record(material.handle, outline.points[0..outline.count], bounds, to_window, viewport, layer, self.format);
    }

    /// Draws the recorded layers in the current pass, which is the scene's
    /// when the frame has backdrop blurs: it ends before each blur's
    /// passes, and the scene's resumes after them.
    fn replay(self: *Renderer, layer_count: usize, params: zui.FrameParams, clear_value: sg.Color, into: Destination) void {
        const scissors = self.layer_scissors[0..layer_count];
        var next_blur: usize = 0;
        for (scissors, 0..) |scissor, layer| {
            while (next_blur < self.backdrop_blurs.count and self.backdrop_blurs.layers_after[next_blur] == layer) : (next_blur += 1) {
                sg.endPass();
                self.backdrop_blurs.runPasses(next_blur);
                sg.beginPass(self.backdrop_blurs.scenePass(.LOAD, clear_value));
            }
            applyScissor(scissor, params);
            self.materials.replayBefore(layer);
            sgl.contextDrawLayer(into.context, @intCast(layer));
        }
    }

    fn applyScissor(scissor: ?zui.Rect, params: zui.FrameParams) void {
        const dpi_scale = params.scale * params.zoom;
        const rect = scissor orelse wholeViewport(params.viewport);
        sg.applyScissorRectf(rect.x * dpi_scale, rect.y * dpi_scale, rect.width * dpi_scale, rect.height * dpi_scale, true);
    }

    /// Times a frame needed more glyphs than the atlas holds, or a glyph
    /// could not be rasterized; those were not drawn.
    pub fn glyphOverflows(self: *const Renderer) u32 {
        const atlas = self.glyphs orelse return 0;
        return atlas.overflows + atlas.raster_refusals;
    }

    /// Rasterizes every glyph the frame's TrueType text needs before any is
    /// drawn, so the texture is made at most once per frame.
    fn prepareGlyphs(self: *Renderer, commands: anytype, pixels_per_unit: f32) void {
        const atlas = self.glyphs orelse return;
        atlas.addFrameGlyphs(self.fonts, commands, pixels_per_unit);
        if (atlas.changed) self.uploadGlyphs(atlas);
    }

    /// sokol_gfx images are immutable once made, so a changed atlas is a
    /// new image.
    fn uploadGlyphs(self: *Renderer, atlas: *GlyphAtlas) void {
        self.destroyGlyphTexture();
        self.glyph_image = sg.makeImage(.{
            .width = GlyphAtlas.side,
            .height = GlyphAtlas.side,
            .pixel_format = .RGBA8,
            .data = sg.asRange(&atlas.texels),
        });
        self.glyph_view = sg.makeView(.{ .texture = .{ .image = self.glyph_image } });
        if (self.glyph_sampler.id == 0) self.glyph_sampler = sg.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
        });
        atlas.changed = false;
    }

    fn destroyGlyphTexture(self: *Renderer) void {
        if (self.glyph_view.id != 0) sg.destroyView(self.glyph_view);
        if (self.glyph_image.id != 0) sg.destroyImage(self.glyph_image);
        self.glyph_view = .{};
        self.glyph_image = .{};
    }
};

const LayerRecorder = struct {
    renderer: *Renderer,
    layer: usize = 0,
    has_materials: bool = false,
    has_shapes: bool = false,

    fn begin(self: *LayerRecorder) void {
        self.renderer.layer_scissors[0] = null;
        sgl.layer(0);
    }

    fn beginShapes(self: *LayerRecorder) void {
        self.has_shapes = true;
    }

    /// A backdrop blur samples everything painted before it, so it starts a
    /// layer that its passes run before. Returns that layer, or null when
    /// no layer is left.
    fn beginBackdropBlur(self: *LayerRecorder) ?usize {
        if (self.isUsed()) {
            if (self.layer + 1 == Renderer.max_layers) return null;
            self.beginLayer(self.renderer.layer_scissors[self.layer]);
        }
        self.has_shapes = true;
        return self.layer;
    }

    /// Materials replay before their layer's shapes, so one that follows
    /// them starts a layer. Returns that layer, or null when no layer is
    /// left.
    fn beginMaterial(self: *LayerRecorder) ?usize {
        if (self.has_shapes) {
            if (self.layer + 1 == Renderer.max_layers) return null;
            self.beginLayer(self.renderer.layer_scissors[self.layer]);
        }
        self.has_materials = true;
        return self.layer;
    }

    fn isUsed(self: *const LayerRecorder) bool {
        return self.has_materials or self.has_shapes;
    }

    fn beginLayer(self: *LayerRecorder, scissor: ?zui.Rect) void {
        if (!self.isUsed()) {
            self.renderer.layer_scissors[self.layer] = scissor;
            return;
        }
        if (self.layer + 1 == Renderer.max_layers) {
            self.renderer.layer_overflows += 1;
            return;
        }
        self.layer += 1;
        self.has_materials = false;
        self.has_shapes = false;
        self.renderer.layer_scissors[self.layer] = scissor;
        sgl.layer(@intCast(self.layer));
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

fn loadModelview(affine: zui.Affine) void {
    sgl.matrixModeModelview();
    sgl.loadMatrix(&columnMajor(affine)[0]);
}

fn columnMajor(affine: zui.Affine) [16]f32 {
    return .{
        affine.x_axis[0], affine.x_axis[1], 0, 0,
        affine.y_axis[0], affine.y_axis[1], 0, 0,
        0,                0,                1, 0,
        affine.offset[0], affine.offset[1], 0, 1,
    };
}

fn wholeViewport(viewport: [2]f32) zui.Rect {
    return .{ .x = 0, .y = 0, .width = viewport[0], .height = viewport[1] };
}

/// The frame's viewport in physical pixels.
fn physicalSize(params: zui.FrameParams) [2]i32 {
    const pixels_per_unit = params.scale * params.zoom;
    return .{ @intFromFloat(@round(params.viewport[0] * pixels_per_unit)), @intFromFloat(@round(params.viewport[1] * pixels_per_unit)) };
}

/// An `.scrgb_fp16` target is cleared in linear light.
fn clearValue(color: zui.Color, format: zui.OutputFormat) sg.Color {
    return switch (format) {
        .sdr => .{
            .r = @as(f32, @floatFromInt(color.r)) / 255,
            .g = @as(f32, @floatFromInt(color.g)) / 255,
            .b = @as(f32, @floatFromInt(color.b)) / 255,
            .a = @as(f32, @floatFromInt(color.a)) / 255,
        },
        .scrgb_fp16 => linear: {
            const linear: zui.ExtendedColor = .fromColor(color);
            break :linear .{ .r = linear.r, .g = linear.g, .b = linear.b, .a = linear.a };
        },
    };
}

fn hasRoundedCorners(radius: zui.CornerRadius) bool {
    return radius.top_left > 0 or radius.top_right > 0 or radius.bottom_left > 0 or radius.bottom_right > 0;
}

fn fillRectangle(bounds: zui.Rect, corners: Corners, color: VertexColor, corner_segments: u8) void {
    color.apply();
    if (!hasRoundedCorners(corners.radius)) {
        sgl.beginQuads();
        sgl.v2f(bounds.x, bounds.y);
        sgl.v2f(bounds.x + bounds.width, bounds.y);
        sgl.v2f(bounds.x + bounds.width, bounds.y + bounds.height);
        sgl.v2f(bounds.x, bounds.y + bounds.height);
        sgl.end();
        return;
    }
    var outline: Outline = .{};
    outline.trace(bounds, corners, .{}, corner_segments);
    fillOutline(&outline, centerOf(bounds));
}

fn centerOf(bounds: zui.Rect) [2]f32 {
    return .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 };
}

/// In the current color, as a fan from `center`, which the outline of a
/// rectangle with corners of any shape always surrounds.
fn fillOutline(outline: *const Outline, center: [2]f32) void {
    sgl.beginTriangles();
    for (0..outline.count) |index| {
        const next = (index + 1) % outline.count;
        sgl.v2f(center[0], center[1]);
        sgl.v2f(outline.points[index][0], outline.points[index][1]);
        sgl.v2f(outline.points[next][0], outline.points[next][1]);
    }
    sgl.end();
}

/// The longest a gradient's band may be, along it, in layout units.
/// sokol_gl blends vertex colors in sRGB, so the gradient is drawn in bands
/// across it, each vertex taking the OKLab color at its point; over a short
/// band the two blends differ by less than a step of 8-bit color.
const gradient_band_length = 4;
const max_gradient_bands = 64;

/// A rectangle with corners of any shape is convex, so each band of it is
/// a convex polygon: the outline cut by the two lines that bound the band.
fn fillGradient(bounds: zui.Rect, gradient: anytype, format: zui.OutputFormat, corner_segments: u8) void {
    var outline: Outline = .{};
    outline.trace(bounds, .of(gradient), .{}, corner_segments);
    const direction: [2]f32 = .{ @cos(gradient.angle), @sin(gradient.angle) };
    const length = @abs(bounds.width * direction[0]) + @abs(bounds.height * direction[1]);
    const band_count: usize = @intFromFloat(std.math.clamp(@ceil(length / gradient_band_length), 1, max_gradient_bands));
    const band_length = length / @as(f32, @floatFromInt(band_count));
    const center = centerOf(bounds);
    const reversed: [2]f32 = .{ -direction[0], -direction[1] };

    sgl.beginTriangles();
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
                VertexColor.of(gradient.colorAt(bounds, point), format).apply();
                sgl.v2f(point[0], point[1]);
            }
        }
    }
    sgl.end();
}

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

/// How many rings a shadow's blur fades through, from its color to clear.
const shadow_fade_rings = 6;

/// The box at the shadow's offset, grown by its spread, in its color; then
/// rings out to the blur, each fainter, easing out as a blurred edge does.
fn drawShadow(bounds: zui.Rect, shadow: anytype, format: zui.OutputFormat, corner_segments: u8) void {
    const caster: zui.Rect = .{ .x = bounds.x + shadow.offset[0], .y = bounds.y + shadow.offset[1], .width = bounds.width, .height = bounds.height };
    const spread = @max(shadow.spread, -@min(caster.width, caster.height) / 2);
    var inner: Outline = .{};
    const corners: Corners = .of(shadow);
    inner.trace(caster, corners, .all(-spread), corner_segments);
    const shadow_color: VertexColor = .of(shadow.color, format);
    shadow_color.apply();
    fillOutline(&inner, centerOf(caster));
    if (shadow.blur <= 0) return;

    var inner_alpha = shadow_color.rgba.a;
    sgl.beginTriangles();
    for (1..shadow_fade_rings + 1) |ring| {
        const reached = @as(f32, @floatFromInt(ring)) / shadow_fade_rings;
        var outer: Outline = .{};
        outer.trace(caster, corners, .all(-(spread + shadow.blur * reached)), corner_segments);
        const outer_alpha: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(shadow_color.rgba.a)) * (1 - smoothstep(reached))));
        const inner_color = shadow_color.withAlpha(inner_alpha);
        const outer_color = shadow_color.withAlpha(outer_alpha);
        for (0..outer.count) |index| {
            const next = (index + 1) % outer.count;
            for ([6]struct { [2]f32, VertexColor }{
                .{ inner.points[index], inner_color },
                .{ outer.points[index], outer_color },
                .{ outer.points[next], outer_color },
                .{ inner.points[index], inner_color },
                .{ outer.points[next], outer_color },
                .{ inner.points[next], inner_color },
            }) |vertex| {
                const point, const color = vertex;
                color.apply();
                sgl.v2f(point[0], point[1]);
            }
        }
        inner = outer;
        inner_alpha = outer_alpha;
    }
    sgl.end();
}

fn smoothstep(amount: f32) f32 {
    return amount * amount * (3 - 2 * amount);
}

/// Borders are drawn inside the bounds, as CSS draws them: a ring between
/// the outer outline and one inset by each edge's width.
fn strokeBorder(bounds: zui.Rect, widths: zui.Edges, corners: Corners, color: VertexColor, corner_segments: u8) void {
    var outer: Outline = .{};
    var inner: Outline = .{};
    outer.trace(bounds, corners, .{}, corner_segments);
    inner.trace(bounds, corners, widths, corner_segments);
    color.apply();
    sgl.beginTriangles();
    for (0..outer.count) |index| {
        const next = (index + 1) % outer.count;
        const outer_here = outer.points[index];
        const outer_next = outer.points[next];
        const inner_here = inner.points[index];
        const inner_next = inner.points[next];
        sgl.v2f(outer_here[0], outer_here[1]);
        sgl.v2f(outer_next[0], outer_next[1]);
        sgl.v2f(inner_next[0], inner_next[1]);
        sgl.v2f(outer_here[0], outer_here[1]);
        sgl.v2f(inner_next[0], inner_next[1]);
        sgl.v2f(inner_here[0], inner_here[1]);
    }
    sgl.end();
}

/// A command's corners, round for one that carries no shape.
const Corners = struct {
    radius: zui.CornerRadius,
    shape: zui.CornerShape,

    fn of(payload: anytype) Corners {
        return .{ .radius = payload.corner_radius, .shape = zui.cornerShapeOf(payload) };
    }
};

/// The points around a rectangle with shaped corners, clockwise from the
/// top-left corner, with the same number of points for any radius of one
/// shape, so that two outlines of one rectangle can be joined point by
/// point: `corner_segments + 1` points along each round or continuous
/// corner, and the two ends of each chamfer's cut.
const Outline = struct {
    const max_segments = 32;
    const max_points = 4 * (max_segments + 1);
    /// A chamfer's cut, moved in by an inset, keeps its 45° when its two
    /// ends move toward the corner by this much of the inset.
    const chamfer_inset_shortening = 2 - std.math.sqrt2;

    points: [max_points][2]f32 = undefined,
    count: usize = 0,

    fn trace(self: *Outline, bounds: zui.Rect, corners: Corners, inset: zui.Edges, corner_segments: u8) void {
        const segments = std.math.clamp(corner_segments, 1, max_segments);
        const radius = corners.radius;
        const left = bounds.x + inset.left;
        const top = bounds.y + inset.top;
        const right = bounds.x + bounds.width - inset.right;
        const bottom = bounds.y + bounds.height - inset.bottom;
        const limit = @max(0, @min(right - left, bottom - top) / 2);
        const inset_shortening: f32 = if (corners.shape == .chamfer) chamfer_inset_shortening else 1;
        const shape_corners = [4]struct { center_x: f32, center_y: f32, radius: f32, inset: f32, start_angle: f32 }{
            .{ .center_x = left, .center_y = top, .radius = radius.top_left, .inset = @max(inset.left, inset.top), .start_angle = std.math.pi },
            .{ .center_x = right, .center_y = top, .radius = radius.top_right, .inset = @max(inset.right, inset.top), .start_angle = 1.5 * std.math.pi },
            .{ .center_x = right, .center_y = bottom, .radius = radius.bottom_right, .inset = @max(inset.right, inset.bottom), .start_angle = 0 },
            .{ .center_x = left, .center_y = bottom, .radius = radius.bottom_left, .inset = @max(inset.left, inset.bottom), .start_angle = 0.5 * std.math.pi },
        };
        const step_count: f32 = if (corners.shape == .chamfer) 1 else @floatFromInt(segments);
        const point_count: usize = if (corners.shape == .chamfer) 2 else segments + 1;
        self.count = 0;
        for (shape_corners, 0..) |corner, corner_index| {
            const corner_radius = std.math.clamp(corner.radius - corner.inset * inset_shortening, 0, limit);
            const is_left = corner_index == 0 or corner_index == 3;
            const is_top = corner_index < 2;
            const arc_center_x = if (is_left) corner.center_x + corner_radius else corner.center_x - corner_radius;
            const arc_center_y = if (is_top) corner.center_y + corner_radius else corner.center_y - corner_radius;
            for (0..point_count) |step| {
                const angle = corner.start_angle + 0.5 * std.math.pi * @as(f32, @floatFromInt(step)) / step_count;
                const toward = towardCurve(corners.shape, angle);
                self.points[self.count] = .{ arc_center_x + toward[0] * corner_radius, arc_center_y + toward[1] * corner_radius };
                self.count += 1;
            }
        }
    }

    /// From a corner's center, the point of its curve at `angle`, for a
    /// radius of 1. A continuous corner is the superellipse
    /// |x|⁴ + |y|⁴ = 1, whose curvature falls to the side's, none, where
    /// it meets it: the circle's point with each coordinate's square root.
    fn towardCurve(shape: zui.CornerShape, angle: f32) [2]f32 {
        const on_circle: [2]f32 = .{ @cos(angle), @sin(angle) };
        if (shape != .continuous) return on_circle;
        return .{
            std.math.copysign(@sqrt(@abs(on_circle[0])), on_circle[0]),
            std.math.copysign(@sqrt(@abs(on_circle[1])), on_circle[1]),
        };
    }
};

fn drawText(fonts: zui_glyphs.Fonts, atlas: *const GlyphAtlas, view: sg.View, sampler: sg.Sampler, content: []const u8, bounds: zui.Rect, style: anytype, color: VertexColor, pixels_per_unit: f32) void {
    var quads = zui_glyphs.glyphQuads(fonts, atlas, content, bounds, style, pixels_per_unit) orelse return;
    sgl.enableTexture();
    sgl.texture(view, sampler);
    color.apply();
    sgl.beginQuads();
    while (quads.next()) |quad| {
        const position = quad.position;
        const texture = quad.texture;
        sgl.v2fT2f(position.left, position.top, texture.left, texture.top);
        sgl.v2fT2f(position.right, position.top, texture.right, texture.top);
        sgl.v2fT2f(position.right, position.bottom, texture.right, texture.bottom);
        sgl.v2fT2f(position.left, position.bottom, texture.left, texture.bottom);
    }
    sgl.end();
    sgl.disableTexture();
}

/// sokol_gl multiplies each texel by the vertex color, which is the tint.
/// A rounded image is a fan of textured triangles from its center.
fn drawImage(image: Image, bounds: zui.Rect, tint: VertexColor, corners: Corners, corner_segments: u8) void {
    sgl.enableTexture();
    sgl.texture(.{ .id = image.view.id }, .{ .id = image.sampler.id });
    tint.apply();
    if (!hasRoundedCorners(corners.radius) or bounds.width <= 0 or bounds.height <= 0) {
        sgl.beginQuads();
        sgl.v2fT2f(bounds.x, bounds.y, 0, 0);
        sgl.v2fT2f(bounds.x + bounds.width, bounds.y, 1, 0);
        sgl.v2fT2f(bounds.x + bounds.width, bounds.y + bounds.height, 1, 1);
        sgl.v2fT2f(bounds.x, bounds.y + bounds.height, 0, 1);
    } else {
        var outline: Outline = .{};
        outline.trace(bounds, corners, .{}, corner_segments);
        const center: [2]f32 = .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 };
        sgl.beginTriangles();
        for (0..outline.count) |index| {
            const next = (index + 1) % outline.count;
            for ([3][2]f32{ center, outline.points[index], outline.points[next] }) |point| {
                sgl.v2fT2f(point[0], point[1], (point[0] - bounds.x) / bounds.width, (point[1] - bounds.y) / bounds.height);
            }
        }
    }
    sgl.end();
    sgl.disableTexture();
}

test "a band of a square is the strip between its two cuts" {
    const square = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    var past_start: ConvexPolygon = .{};
    past_start.cut(&square, .{ 5, 5 }, .{ 1, 0 }, -1);
    var band: ConvexPolygon = .{};
    band.cut(past_start.points[0..past_start.count], .{ 5, 5 }, .{ -1, 0 }, -1);
    try std.testing.expectEqual(4, band.count);
    for (band.points[0..band.count]) |point| try std.testing.expect(point[0] == 4 or point[0] == 6);
}

test "an scRGB target is cleared in linear light" {
    try std.testing.expectEqual(sg.Color{ .r = 1, .g = 1, .b = 1, .a = 1 }, clearValue(.white, .scrgb_fp16));
    const gray = clearValue(.rgb(0x808080), .scrgb_fp16);
    try std.testing.expectApproxEqAbs(@as(f32, 0.216), gray.r, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), clearValue(.rgb(0x808080), .sdr).r, 1e-6);
}

test "a shadow's fade starts at its color and ends clear" {
    try std.testing.expectEqual(0, smoothstep(0));
    try std.testing.expectEqual(1, smoothstep(1));
    try std.testing.expectEqual(0.5, smoothstep(0.5));
}

test "nested transforms map to the window innermost first" {
    var transforms: TransformStack = .{};
    try std.testing.expect(transforms.push(.{ .offset = .{ 10, 0 } }));
    try std.testing.expect(transforms.push(.{ .x_axis = .{ 0, 1 }, .y_axis = .{ -1, 0 } }));
    try std.testing.expectEqual([2]f32{ 10, 2 }, transforms.current().apply(.{ 2, 0 }));
    transforms.pop();
    try std.testing.expectEqual([2]f32{ 12, 0 }, transforms.current().apply(.{ 2, 0 }));
}

test "a full transform stack keeps what fits and pops what it skipped first" {
    var transforms: TransformStack = .{};
    for (0..transforms.to_window.len) |_| try std.testing.expect(transforms.push(.{ .offset = .{ 1, 0 } }));
    try std.testing.expect(!transforms.push(.{ .offset = .{ 1000, 0 } }));
    transforms.pop();
    try std.testing.expectEqual([2]f32{ 64, 0 }, transforms.current().apply(.{ 0, 0 }));
}

test "a column-major matrix carries the offset in its last column" {
    const matrix = columnMajor(.{ .x_axis = .{ 2, 3 }, .y_axis = .{ 4, 5 }, .offset = .{ 6, 7 } });
    try std.testing.expectEqualSlices(f32, &.{ 2, 3, 0, 0, 4, 5, 0, 0, 0, 0, 1, 0, 6, 7, 0, 1 }, &matrix);
}

test "outlines keep the same point count for any radius" {
    var square: Outline = .{};
    var rounded: Outline = .{};
    square.trace(.{ .width = 100, .height = 40 }, .{ .radius = .zero, .shape = .round }, .{}, 8);
    rounded.trace(.{ .width = 100, .height = 40 }, .{ .radius = .all(500), .shape = .round }, .{}, 8);
    try std.testing.expectEqual(square.count, rounded.count);
    try std.testing.expectEqual([2]f32{ 0, 0 }, square.points[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 20), rounded.points[0][1], 0.001);
}

test "a chamfer is one cut per corner, which an inset moves in at 45 degrees" {
    const bounds: zui.Rect = .{ .width = 100, .height = 40 };
    const chamfer: Corners = .{ .radius = .all(10), .shape = .chamfer };
    var outer: Outline = .{};
    var inner: Outline = .{};
    outer.trace(bounds, chamfer, .{}, 8);
    inner.trace(bounds, chamfer, .all(2), 8);
    try std.testing.expectEqual(8, outer.count);
    try std.testing.expectEqual(outer.count, inner.count);
    try std.testing.expectApproxEqAbs(@as(f32, 0), outer.points[0][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), outer.points[0][1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), outer.points[1][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), outer.points[1][1], 0.001);
    const outer_cut = outer.points[0][0] + outer.points[0][1];
    const inner_cut = inner.points[0][0] + inner.points[0][1];
    try std.testing.expectApproxEqAbs(@as(f32, 2 * std.math.sqrt2), inner_cut - outer_cut, 0.001);
    try std.testing.expectApproxEqAbs(inner_cut, inner.points[1][0] + inner.points[1][1], 0.001);
}

test "a continuous corner fills more of its corner than a round one, and meets the sides where it does" {
    const bounds: zui.Rect = .{ .width = 100, .height = 100 };
    var round: Outline = .{};
    var continuous: Outline = .{};
    round.trace(bounds, .{ .radius = .all(24), .shape = .round }, .{}, 8);
    continuous.trace(bounds, .{ .radius = .all(24), .shape = .continuous }, .{}, 8);
    try std.testing.expectEqual(round.count, continuous.count);
    for ([_]usize{ 0, 8 }) |end| {
        try std.testing.expectApproxEqAbs(round.points[end][0], continuous.points[end][0], 0.01);
        try std.testing.expectApproxEqAbs(round.points[end][1], continuous.points[end][1], 0.01);
    }
    const diagonal_reach = 24 * (1 - 1 / std.math.pow(f32, 2, 0.25));
    try std.testing.expectApproxEqAbs(diagonal_reach, continuous.points[4][0], 0.001);
    try std.testing.expect(continuous.points[4][0] < round.points[4][0]);
}

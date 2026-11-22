const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;

const EGLDisplay = *opaque {};
const EGLConfig = *opaque {};
const EGLContext = *opaque {};
const EGLSurface = *opaque {};
const EGLBoolean = c_uint;
const EGLint = i32;
const WaylandEglWindow = opaque {};

const EGL_PLATFORM_WAYLAND_KHR = 0x31D8;
const EGL_OPENGL_API = 0x30A2;
const EGL_NONE = 0x3038;
const EGL_EXTENSIONS = 0x3055;
const EGL_DRAW = 0x3059;
const EGL_SURFACE_TYPE = 0x3033;
const EGL_WINDOW_BIT = 0x0004;
const EGL_RENDERABLE_TYPE = 0x3040;
const EGL_OPENGL_BIT = 0x0008;
const EGL_RED_SIZE = 0x3024;
const EGL_GREEN_SIZE = 0x3023;
const EGL_BLUE_SIZE = 0x3022;
const EGL_ALPHA_SIZE = 0x3021;
const EGL_DEPTH_SIZE = 0x3025;
const EGL_STENCIL_SIZE = 0x3026;
const EGL_SAMPLES = 0x3031;
const EGL_SAMPLE_BUFFERS = 0x3032;
const EGL_CONTEXT_MAJOR_VERSION = 0x3098;
const EGL_CONTEXT_MINOR_VERSION = 0x30FB;
const EGL_CONTEXT_OPENGL_PROFILE_MASK = 0x30FD;
const EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT = 0x0001;

extern "EGL" fn eglGetPlatformDisplay(platform: c_uint, native_display: *anyopaque, attributes: ?[*]const isize) callconv(.c) ?EGLDisplay;
extern "EGL" fn eglInitialize(display: EGLDisplay, major: ?*EGLint, minor: ?*EGLint) callconv(.c) EGLBoolean;
extern "EGL" fn eglTerminate(display: EGLDisplay) callconv(.c) EGLBoolean;
extern "EGL" fn eglBindAPI(api: c_uint) callconv(.c) EGLBoolean;
extern "EGL" fn eglChooseConfig(display: EGLDisplay, attributes: [*]const EGLint, configs: [*]EGLConfig, capacity: EGLint, count: *EGLint) callconv(.c) EGLBoolean;
extern "EGL" fn eglGetConfigAttrib(display: EGLDisplay, config: EGLConfig, attribute: EGLint, value: *EGLint) callconv(.c) EGLBoolean;
extern "EGL" fn eglQueryString(display: EGLDisplay, name: EGLint) callconv(.c) ?[*:0]const u8;
extern "EGL" fn eglCreateContext(display: EGLDisplay, config: ?EGLConfig, share: ?EGLContext, attributes: [*]const EGLint) callconv(.c) ?EGLContext;
extern "EGL" fn eglDestroyContext(display: EGLDisplay, context: EGLContext) callconv(.c) EGLBoolean;
extern "EGL" fn eglCreatePlatformWindowSurface(display: EGLDisplay, config: EGLConfig, native_window: *anyopaque, attributes: ?[*]const isize) callconv(.c) ?EGLSurface;
extern "EGL" fn eglDestroySurface(display: EGLDisplay, surface: EGLSurface) callconv(.c) EGLBoolean;
extern "EGL" fn eglMakeCurrent(display: EGLDisplay, draw: ?EGLSurface, read: ?EGLSurface, context: ?EGLContext) callconv(.c) EGLBoolean;
extern "EGL" fn eglGetCurrentSurface(which: EGLint) callconv(.c) ?EGLSurface;
extern "EGL" fn eglSwapInterval(display: EGLDisplay, interval: EGLint) callconv(.c) EGLBoolean;
extern "EGL" fn eglSwapBuffers(display: EGLDisplay, surface: EGLSurface) callconv(.c) EGLBoolean;

extern "wayland-egl" fn wl_egl_window_create(surface: *anyopaque, width: c_int, height: c_int) callconv(.c) ?*WaylandEglWindow;
extern "wayland-egl" fn wl_egl_window_destroy(window: *WaylandEglWindow) callconv(.c) void;
extern "wayland-egl" fn wl_egl_window_resize(window: *WaylandEglWindow, width: c_int, height: c_int, dx: c_int, dy: c_int) callconv(.c) void;

/// The OpenGL 4.3 core context every window draws with, on the display of
/// the first, held until `Context.releaseDevice`.
pub const Device = struct {
    display: EGLDisplay,
    /// Of an opaque window, preferring no alpha.
    opaque_config: EGLConfig,
    /// Of a transparent window, where the display has one with 8 bits of
    /// alpha and the context was made without a configuration, so it draws
    /// into windows of either.
    alpha_config: ?EGLConfig,
    context: EGLContext,
    /// Of every window's default framebuffer: `wanted_sample_count` when
    /// the display offers it, which smooths the edges of shapes, or 1.
    sample_count: i32,
};

const wanted_sample_count = 4;

/// One Wayland surface's window surface, drawn by its device's context,
/// presenting with vsync. An opaque window's configuration has no alpha
/// where the display offers one without, since a Wayland compositor blends
/// a surface by the alpha its buffer holds, so stray alpha below 1 from
/// blended draws never shows what is behind the window. A transparent
/// window's has alpha.
pub const Context = struct {
    device: Device,
    /// The host's `wl_surface`, which finds the context for a frame.
    wayland_surface: *anyopaque,
    egl_surface: EGLSurface,
    window: *WaylandEglWindow,
    size: [2]i32,
    /// The window surface was made in the device's `alpha_config`.
    holds_alpha: bool,

    /// Makes the device on `wayland_display` and the surface's context on
    /// it, current on the calling thread; `transparent` as the `.wayland`
    /// surface says.
    pub fn init(wayland_display: *anyopaque, wayland_surface: *anyopaque, transparent: bool) error{ NoEglDisplay, NoEglConfig, NoOpenGlContext, NoWindowSurface }!Context {
        const display = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, wayland_display, null) orelse return error.NoEglDisplay;
        if (eglInitialize(display, null, null) == 0) return error.NoEglDisplay;
        errdefer _ = eglTerminate(display);
        if (eglBindAPI(EGL_OPENGL_API) == 0) return error.NoOpenGlContext;
        var sample_count: i32 = wanted_sample_count;
        const opaque_config = windowConfig(display, wanted_sample_count, .opaque_preferred) catch blk: {
            sample_count = 1;
            break :blk try windowConfig(display, 1, .opaque_preferred);
        };
        const draws_without_config = hasExtension(display, "EGL_KHR_no_config_context");
        const alpha_config: ?EGLConfig = if (draws_without_config) windowConfig(display, sample_count, .with_alpha) catch null else null;

        const context_attributes = [_]EGLint{
            EGL_CONTEXT_MAJOR_VERSION,       4,
            EGL_CONTEXT_MINOR_VERSION,       3,
            EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            EGL_NONE,
        };
        // Without a configuration of its own, the context draws into the
        // windows of both configurations.
        const context = eglCreateContext(display, if (alpha_config != null) null else opaque_config, null, &context_attributes) orelse return error.NoOpenGlContext;
        errdefer _ = eglDestroyContext(display, context);
        return initSharing(wayland_surface, .{ .display = display, .opaque_config = opaque_config, .alpha_config = alpha_config, .context = context, .sample_count = sample_count }, transparent);
    }

    /// A window surface for `wayland_surface` on `device`, another
    /// context's, made current on the calling thread. A `transparent` one
    /// holds alpha where the device has `alpha_config`, and is opaque
    /// otherwise.
    pub fn initSharing(wayland_surface: *anyopaque, device: Device, transparent: bool) error{ NoWindowSurface, NoOpenGlContext }!Context {
        if (transparent) if (device.alpha_config) |alpha_config| {
            if (initIn(wayland_surface, device, alpha_config)) |context| {
                var transparent_context = context;
                transparent_context.holds_alpha = true;
                return transparent_context;
            } else |_| {}
        };
        return initIn(wayland_surface, device, device.opaque_config);
    }

    fn initIn(wayland_surface: *anyopaque, device: Device, config: EGLConfig) error{ NoWindowSurface, NoOpenGlContext }!Context {
        const initial_size: [2]i32 = .{ 1, 1 };
        const window = wl_egl_window_create(wayland_surface, initial_size[0], initial_size[1]) orelse return error.NoWindowSurface;
        errdefer wl_egl_window_destroy(window);
        const egl_surface = eglCreatePlatformWindowSurface(device.display, config, window, null) orelse return error.NoWindowSurface;
        errdefer _ = eglDestroySurface(device.display, egl_surface);
        if (eglMakeCurrent(device.display, egl_surface, egl_surface, device.context) == 0) return error.NoOpenGlContext;
        // The interval belongs to the surface current when it is set.
        _ = eglSwapInterval(device.display, 1);
        return .{ .device = device, .wayland_surface = wayland_surface, .egl_surface = egl_surface, .window = window, .size = initial_size, .holds_alpha = false };
    }

    const Alpha = enum { opaque_preferred, with_alpha };

    /// A configuration with `sample_count` samples a pixel: for
    /// `.opaque_preferred` one without alpha where the display has one,
    /// and for `.with_alpha` one with 8 bits of it.
    fn windowConfig(display: EGLDisplay, sample_count: EGLint, alpha: Alpha) error{NoEglConfig}!EGLConfig {
        const multisampled = sample_count > 1;
        const alpha_bits: EGLint = if (alpha == .with_alpha) 8 else 0;
        const attributes = [_]EGLint{
            EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
            EGL_RED_SIZE,        8,
            EGL_GREEN_SIZE,      8,
            EGL_BLUE_SIZE,       8,
            EGL_ALPHA_SIZE,      alpha_bits,
            EGL_DEPTH_SIZE,      24,
            EGL_STENCIL_SIZE,    8,
            EGL_SAMPLE_BUFFERS,  @intFromBool(multisampled),
            EGL_SAMPLES,         if (multisampled) sample_count else 0,
            EGL_NONE,
        };
        var configs: [64]EGLConfig = undefined;
        var count: EGLint = 0;
        if (eglChooseConfig(display, &attributes, &configs, configs.len, &count) == 0 or count == 0) return error.NoEglConfig;
        const matching = configs[0..@intCast(count)];
        for (matching) |config| {
            if (configAttribute(display, config, EGL_ALPHA_SIZE) == alpha_bits and samplesOf(display, config) == sample_count) return config;
        }
        if (alpha == .with_alpha) return error.NoEglConfig;
        for (matching) |config| {
            if (samplesOf(display, config) == sample_count) return config;
        }
        return error.NoEglConfig;
    }

    fn hasExtension(display: EGLDisplay, name: []const u8) bool {
        const extensions = eglQueryString(display, EGL_EXTENSIONS) orelse return false;
        var names = std.mem.tokenizeScalar(u8, std.mem.span(extensions), ' ');
        while (names.next()) |extension| if (std.mem.eql(u8, extension, name)) return true;
        return false;
    }

    fn samplesOf(display: EGLDisplay, config: EGLConfig) EGLint {
        return @max(configAttribute(display, config, EGL_SAMPLES), 1);
    }

    fn configAttribute(display: EGLDisplay, config: EGLConfig, attribute: EGLint) EGLint {
        var value: EGLint = -1;
        return if (eglGetConfigAttrib(display, config, attribute, &value) != 0) value else -1;
    }

    /// The device, held until `releaseDevice` whichever contexts on it are
    /// freed.
    pub fn retainDevice(self: *const Context) Device {
        return self.device;
    }

    pub fn releaseDevice(device: Device) void {
        _ = eglMakeCurrent(device.display, null, null, null);
        _ = eglDestroyContext(device.display, device.context);
        _ = eglTerminate(device.display);
    }

    /// Frees the window surface. The device's context stays current
    /// without a surface, so the GPU objects of other windows can still be
    /// freed or drawn with.
    pub fn deinit(self: *Context) void {
        const device = self.device;
        if (eglGetCurrentSurface(EGL_DRAW) == self.egl_surface) {
            if (eglMakeCurrent(device.display, null, null, device.context) == 0) _ = eglMakeCurrent(device.display, null, null, null);
        }
        _ = eglDestroySurface(device.display, self.egl_surface);
        wl_egl_window_destroy(self.window);
    }

    const color_format: sg.PixelFormat = .RGBA8;
    const depth_format: sg.PixelFormat = .DEPTH_STENCIL;

    pub fn environment(self: *const Context) sg.Environment {
        return .{ .defaults = .{ .color_format = color_format, .depth_format = depth_format, .sample_count = self.device.sample_count } };
    }

    /// Draws what follows into this surface: the device's one context
    /// moves to it, when another surface had it.
    pub fn makeCurrent(self: *const Context) void {
        if (eglGetCurrentSurface(EGL_DRAW) == self.egl_surface) return;
        _ = eglMakeCurrent(self.device.display, self.egl_surface, self.egl_surface, self.device.context);
    }

    /// The surface's default framebuffer, resized to `size` in physical
    /// pixels: a Wayland surface has no size of its own until a buffer is
    /// attached, so the frame's viewport decides it.
    pub fn swapchain(self: *Context, size: [2]i32) sg.Swapchain {
        const wanted: [2]i32 = .{ @max(size[0], 1), @max(size[1], 1) };
        if (!std.meta.eql(wanted, self.size)) {
            wl_egl_window_resize(self.window, wanted[0], wanted[1], 0, 0);
            self.size = wanted;
        }
        return .{
            .width = wanted[0],
            .height = wanted[1],
            .sample_count = self.device.sample_count,
            .color_format = color_format,
            .depth_format = depth_format,
            .gl = .{ .framebuffer = 0 },
        };
    }

    /// Attaches the frame to the surface and commits it, waiting for the
    /// compositor's frame callback of the one before.
    pub fn present(self: *const Context) void {
        _ = eglSwapBuffers(self.device.display, self.egl_surface);
    }
};
